[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'BackupConfig.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:LocalDirectoriesListFileName = 'LocalDirectoriesToBackup.lst'
Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop

function Read-BackupConfig {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file was not found: '$Path'."
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $json = [System.IO.File]::ReadAllText($Path, $utf8)
    return ($json | ConvertFrom-Json -ErrorAction Stop)
}

function ConvertTo-SafeFileName {
    param([Parameter(Mandatory)][string]$Value)

    $invalidCharacters = [System.IO.Path]::GetInvalidFileNameChars()
    $result = foreach ($character in $Value.ToCharArray()) {
        if ($invalidCharacters -contains $character) { '_' } else { $character }
    }

    $safeValue = (-join $result).Trim()
    if ([string]::IsNullOrWhiteSpace($safeValue)) {
        throw "The value '$Value' cannot be converted to a file name."
    }
    return $safeValue
}

function Get-NormalizedFullPath {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $rootPath = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Length -gt $rootPath.Length) {
        return $fullPath.TrimEnd('\', '/')
    }
    return $rootPath
}

function Test-IsSameOrChildPath {
    param(
        [Parameter(Mandatory)][string]$ParentPath,
        [Parameter(Mandatory)][string]$CandidatePath
    )

    $normalizedParent = Get-NormalizedFullPath -Path $ParentPath
    $normalizedCandidate = Get-NormalizedFullPath -Path $CandidatePath
    if ($normalizedCandidate.Equals($normalizedParent, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $parentPrefix = $normalizedParent.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    return $normalizedCandidate.StartsWith($parentPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-ShortPathHash {
    param([Parameter(Mandatory)][string]$Path)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())
        $hashBytes = $sha256.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hashBytes).Replace('-', '').Substring(0, 8))
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-LocalDirectorySources {
    param(
        [Parameter(Mandatory)][string]$ListPath,
        [Parameter(Mandatory)][hashtable]$ExistingSourceNames,
        [Parameter(Mandatory)][string]$BackupRootPath
    )

    if (-not (Test-Path -LiteralPath $ListPath -PathType Leaf)) {
        return @()
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $lines = [System.IO.File]::ReadAllLines($ListPath, $utf8)
    if ($lines.Count -lt 2 -or $lines[1].Trim() -ine 'True') {
        return @()
    }

    $userProfilePath = Get-NormalizedFullPath -Path $env:USERPROFILE
    $normalizedBackupRoot = Get-NormalizedFullPath -Path $BackupRootPath
    $seenPaths = @{}
    $result = New-Object System.Collections.ArrayList

    for ($lineIndex = 2; $lineIndex -lt $lines.Count; $lineIndex++) {
        $entry = $lines[$lineIndex].Trim()
        if ([string]::IsNullOrWhiteSpace($entry) -or $entry.StartsWith('::')) {
            continue
        }
        if ($entry.Length -ge 2 -and
            (($entry.StartsWith('"') -and $entry.EndsWith('"')) -or
             ($entry.StartsWith("'") -and $entry.EndsWith("'")))) {
            $entry = $entry.Substring(1, $entry.Length - 2).Trim()
        }
        if ([string]::IsNullOrWhiteSpace($entry)) {
            continue
        }
        if ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($entry)) {
            throw "Local directory list line $($lineIndex + 1) contains wildcard characters: '$entry'."
        }

        $expandedEntry = [Environment]::ExpandEnvironmentVariables($entry)
        if ([System.IO.Path]::IsPathRooted($expandedEntry)) {
            if ($expandedEntry -notmatch '^[A-Za-z]:[\\/]') {
                throw "Local directory list line $($lineIndex + 1) is not a local drive path: '$entry'."
            }
            $fullPath = Get-NormalizedFullPath -Path $expandedEntry
        }
        else {
            $fullPath = Get-NormalizedFullPath -Path (Join-Path $userProfilePath $expandedEntry)
            if (-not (Test-IsSameOrChildPath -ParentPath $userProfilePath -CandidatePath $fullPath)) {
                throw "Relative local directory escapes the user profile at line $($lineIndex + 1): '$entry'."
            }
        }

        $pathKey = $fullPath.ToLowerInvariant()
        if ($seenPaths.ContainsKey($pathKey)) {
            throw "Duplicate local directory in list: '$fullPath'."
        }
        $seenPaths[$pathKey] = $true

        if ((Test-IsSameOrChildPath -ParentPath $normalizedBackupRoot -CandidatePath $fullPath) -or
            (Test-IsSameOrChildPath -ParentPath $fullPath -CandidatePath $normalizedBackupRoot)) {
            throw "Local directory overlaps the backup root and cannot be archived: '$fullPath'."
        }

        $sourceLeaf = [System.IO.Path]::GetFileName($fullPath.TrimEnd('\', '/'))
        if ([string]::IsNullOrWhiteSpace($sourceLeaf)) {
            $driveRoot = [System.IO.Path]::GetPathRoot($fullPath)
            $sourceLeaf = 'Drive_' + $driveRoot.Substring(0, 1)
        }
        $baseSourceName = ConvertTo-SafeFileName -Value $sourceLeaf
        $sourceName = $baseSourceName
        if ($ExistingSourceNames.ContainsKey($sourceName.ToLowerInvariant())) {
            $sourceName = $baseSourceName + '_' + (Get-ShortPathHash -Path $fullPath)
        }
        $suffix = 2
        while ($ExistingSourceNames.ContainsKey($sourceName.ToLowerInvariant())) {
            $sourceName = $baseSourceName + '_' + (Get-ShortPathHash -Path $fullPath) + '_' + $suffix
            $suffix++
        }
        $ExistingSourceNames[$sourceName.ToLowerInvariant()] = $true

        [void]$result.Add([pscustomobject]@{
            Name        = $sourceName
            DisplayName = $fullPath
            Kind        = 'LocalPath'
            KnownFolder = $null
            Path        = $fullPath
        })
    }

    return @($result)
}

function Show-UserMessage {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$CopyButtonText,
        [Parameter(Mandatory)][string]$CloseButtonText
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop

        $form = New-Object System.Windows.Forms.Form
        $form.Text = $Title
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $form.ClientSize = New-Object System.Drawing.Size(700, 320)
        $form.MinimumSize = New-Object System.Drawing.Size(560, 280)
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
        $form.MaximizeBox = $false
        $form.ShowInTaskbar = $true
        $form.TopMost = $true

        $textBox = New-Object System.Windows.Forms.TextBox
        $textBox.Multiline = $true
        $textBox.ReadOnly = $true
        $textBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
        $textBox.WordWrap = $true
        $textBox.BackColor = [System.Drawing.SystemColors]::Window
        $textBox.Text = $Text
        $textBox.Location = New-Object System.Drawing.Point(12, 12)
        $textBox.Size = New-Object System.Drawing.Size(676, 250)
        $textBox.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor
            [System.Windows.Forms.AnchorStyles]::Bottom -bor
            [System.Windows.Forms.AnchorStyles]::Left -bor
            [System.Windows.Forms.AnchorStyles]::Right

        $copyButton = New-Object System.Windows.Forms.Button
        $copyButton.Text = $CopyButtonText
        $copyButton.Size = New-Object System.Drawing.Size(120, 32)
        $copyButton.Location = New-Object System.Drawing.Point(436, 276)
        $copyButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
        $copyButton.Add_Click({
            if (-not [string]::IsNullOrEmpty($textBox.Text)) {
                [System.Windows.Forms.Clipboard]::SetText($textBox.Text)
            }
        })

        $closeButton = New-Object System.Windows.Forms.Button
        $closeButton.Text = $CloseButtonText
        $closeButton.Size = New-Object System.Drawing.Size(120, 32)
        $closeButton.Location = New-Object System.Drawing.Point(568, 276)
        $closeButton.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
        $closeButton.Add_Click({ $form.Close() })

        $form.AcceptButton = $closeButton
        $form.CancelButton = $closeButton
        [void]$form.Controls.Add($textBox)
        [void]$form.Controls.Add($copyButton)
        [void]$form.Controls.Add($closeButton)
        [void]$form.ShowDialog()
        $form.Dispose()
        return
    }
    catch {
        try {
            $messageCommand = Join-Path $env:SystemRoot 'System32\msg.exe'
            if (Test-Path -LiteralPath $messageCommand) {
                & $messageCommand $env:USERNAME /TIME:120 $Text | Out-Null
            }
        }
        catch {
            # A notification failure must not hide the original backup failure.
        }
    }
}

function Remove-OldLogFiles {
    $rotatedLogPattern = $script:LogStem + '.*.log'
    $rotatedLogsToKeep = [Math]::Max(0, $script:LogFilesToKeep - 1)

    $oldLogs = @(
        Get-ChildItem -LiteralPath $script:UserBackupPath -Filter $rotatedLogPattern -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -Skip $rotatedLogsToKeep
    )

    foreach ($oldLog in $oldLogs) {
        Remove-Item -LiteralPath $oldLog.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Move-CurrentLogToArchive {
    if (-not (Test-Path -LiteralPath $script:LogPath -PathType Leaf)) {
        return
    }

    $currentLog = Get-Item -LiteralPath $script:LogPath
    if ($currentLog.Length -eq 0) {
        return
    }

    $rotationStamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $rotatedLogPath = Join-Path $script:UserBackupPath ($script:LogStem + '.' + $rotationStamp + '.log')
    Move-Item -LiteralPath $script:LogPath -Destination $rotatedLogPath -Force
}

function Write-Log {
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )

    if ($Message.Length -gt 200000) {
        $Message = $Message.Substring(0, 200000) + ' ... [entry truncated]'
    }

    $line = '{0} [{1}] {2}{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message, [Environment]::NewLine
    $lineBytes = $script:Utf8Encoding.GetByteCount($line)

    if (Test-Path -LiteralPath $script:LogPath -PathType Leaf) {
        $currentLength = (Get-Item -LiteralPath $script:LogPath).Length
        if (($currentLength + $lineBytes) -gt $script:MaxLogBytes) {
            Move-CurrentLogToArchive
            Remove-OldLogFiles
        }
    }

    [System.IO.File]::AppendAllText($script:LogPath, $line, $script:Utf8Encoding)
}

function Add-LogSessionSeparator {
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'WARN', 'ERROR')][string]$FirstLevel,
        [Parameter(Mandatory)][string]$FirstMessage
    )

    $separator = [Environment]::NewLine
    $separatorBytes = $script:Utf8Encoding.GetByteCount($separator)
    $previewLine = '{0} [{1}] {2}{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $FirstLevel, $FirstMessage, [Environment]::NewLine
    $requiredBytes = $separatorBytes + $script:Utf8Encoding.GetByteCount($previewLine)

    if (Test-Path -LiteralPath $script:LogPath -PathType Leaf) {
        $currentLength = (Get-Item -LiteralPath $script:LogPath).Length
        if (($currentLength + $requiredBytes) -gt $script:MaxLogBytes) {
            Move-CurrentLogToArchive
            Remove-OldLogFiles
        }
    }

    [System.IO.File]::AppendAllText($script:LogPath, $separator, $script:Utf8Encoding)
}

function Test-FileExcluded {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$RelativePath,
        [AllowNull()][object[]]$Masks
    )

    foreach ($maskValue in @($Masks)) {
        $mask = [string]$maskValue
        if ([string]::IsNullOrWhiteSpace($mask)) {
            continue
        }
        if ($FileName -like $mask -or $RelativePath -like $mask) {
            return $true
        }
    }
    return $false
}

function New-SourceManifest {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$SourceName,
        [AllowNull()][object[]]$ExcludeMasks
    )

    $entries = New-Object System.Collections.ArrayList
    $separatorCharacters = [char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $rootPath = [System.IO.Path]::GetFullPath($SourcePath).TrimEnd($separatorCharacters)
    $rootInfo = Get-Item -LiteralPath $rootPath
    [long]$totalBytes = 0

    [void]$entries.Add([pscustomobject]@{
        IsDirectory = $true
        FullPath    = $rootPath
        EntryName   = $SourceName + '/'
        LastWrite   = $rootInfo.LastWriteTime
    })

    $directories = New-Object 'System.Collections.Generic.Stack[string]'
    $directories.Push($rootPath)

    while ($directories.Count -gt 0) {
        $currentDirectory = $directories.Pop()

        foreach ($directoryPath in [System.IO.Directory]::GetDirectories($currentDirectory)) {
            $directoryInfo = New-Object System.IO.DirectoryInfo($directoryPath)
            $relativePath = $directoryInfo.FullName.Substring($rootPath.Length).TrimStart($separatorCharacters)
            $entryName = ($SourceName + '/' + $relativePath.Replace('\', '/')).TrimEnd('/') + '/'

            if (($directoryInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Write-Log -Level WARN -Message "Skipped reparse point: $($directoryInfo.FullName)"
                continue
            }

            [void]$entries.Add([pscustomobject]@{
                IsDirectory = $true
                FullPath    = $directoryInfo.FullName
                EntryName   = $entryName
                LastWrite   = $directoryInfo.LastWriteTime
            })
            $directories.Push($directoryInfo.FullName)
        }

        foreach ($filePath in [System.IO.Directory]::GetFiles($currentDirectory)) {
            $fileInfo = New-Object System.IO.FileInfo($filePath)
            $relativePath = $fileInfo.FullName.Substring($rootPath.Length).TrimStart($separatorCharacters)
            if (Test-FileExcluded -FileName $fileInfo.Name -RelativePath $relativePath -Masks $ExcludeMasks) {
                continue
            }

            [void]$entries.Add([pscustomobject]@{
                IsDirectory = $false
                FullPath    = $fileInfo.FullName
                EntryName   = $SourceName + '/' + $relativePath.Replace('\', '/')
                LastWrite   = $fileInfo.LastWriteTime
            })
            $totalBytes += [long]$fileInfo.Length
        }
    }

    return [pscustomobject]@{
        Entries    = @($entries)
        TotalBytes = $totalBytes
    }
}

function Set-ZipEntryTime {
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][datetime]$LastWriteTime
    )

    if ($LastWriteTime.Year -ge 1980 -and $LastWriteTime.Year -le 2107) {
        $Entry.LastWriteTime = [DateTimeOffset]$LastWriteTime
    }
}

function New-ZipFromManifest {
    param(
        [Parameter(Mandatory)][object[]]$Manifest,
        [Parameter(Mandatory)][string]$PartialPath
    )

    $archiveStream = $null
    $zipArchive = $null

    try {
        $archiveStream = [System.IO.File]::Open(
            $PartialPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        $zipArchive = New-Object System.IO.Compression.ZipArchive(
            $archiveStream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $false
        )

        foreach ($item in $Manifest) {
            if ($item.IsDirectory) {
                $entry = $zipArchive.CreateEntry($item.EntryName)
                Set-ZipEntryTime -Entry $entry -LastWriteTime $item.LastWrite
                continue
            }

            $entry = $zipArchive.CreateEntry(
                $item.EntryName,
                [System.IO.Compression.CompressionLevel]::Optimal
            )
            Set-ZipEntryTime -Entry $entry -LastWriteTime $item.LastWrite

            $entryStream = $null
            $sourceStream = $null
            try {
                $entryStream = $entry.Open()
                $shareMode = [System.IO.FileShare]([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
                $sourceStream = [System.IO.File]::Open(
                    $item.FullPath,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read,
                    $shareMode
                )
                $sourceStream.CopyTo($entryStream)
            }
            finally {
                if ($null -ne $sourceStream) { $sourceStream.Dispose() }
                if ($null -ne $entryStream) { $entryStream.Dispose() }
            }
        }
    }
    finally {
        if ($null -ne $zipArchive) { $zipArchive.Dispose() }
        if ($null -ne $archiveStream) { $archiveStream.Dispose() }
    }
}

function Test-ArchiveExistsForDate {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$DateStamp,
        [Parameter(Mandatory)][string]$SourceName
    )

    if (-not (Test-Path -LiteralPath $TargetPath -PathType Container)) {
        return $false
    }

    $escapedSource = [regex]::Escape($SourceName)
    $namePattern = '^' + [regex]::Escape($DateStamp) + '_\d{6}_' + $escapedSource + '\.zip$'
    $matchingArchives = @(
        Get-ChildItem -LiteralPath $TargetPath -Filter ($DateStamp + '_*_' + $SourceName + '.zip') -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $namePattern }
    )

    foreach ($archiveFile in $matchingArchives) {
        $archiveStream = $null
        $zipArchive = $null
        try {
            $archiveStream = [System.IO.File]::Open(
                $archiveFile.FullName,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::Read
            )
            $zipArchive = New-Object System.IO.Compression.ZipArchive(
                $archiveStream,
                [System.IO.Compression.ZipArchiveMode]::Read,
                $false
            )
            $sourceEntryPrefix = $SourceName + '/'
            $sourceEntry = @($zipArchive.Entries | Where-Object {
                $_.FullName -eq $sourceEntryPrefix -or $_.FullName.StartsWith($sourceEntryPrefix)
            } | Select-Object -First 1)
            if ($sourceEntry.Count -gt 0) {
                return $true
            }
        }
        catch {
            # A corrupt archive is not accepted as a completed backup.
        }
        finally {
            if ($null -ne $zipArchive) { $zipArchive.Dispose() }
            if ($null -ne $archiveStream) { $archiveStream.Dispose() }
        }
    }

    return $false
}

function Remove-OldArchives {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$SourceName,
        [Parameter(Mandatory)][int]$CopiesToKeep
    )

    $escapedSource = [regex]::Escape($SourceName)
    $namePattern = '^\d{8}_\d{6}_' + $escapedSource + '\.zip$'
    $oldArchives = @(
        Get-ChildItem -LiteralPath $TargetPath -Filter ('*_' + $SourceName + '.zip') -File |
            Where-Object { $_.Name -match $namePattern } |
            Sort-Object Name -Descending |
            Select-Object -Skip $CopiesToKeep
    )

    foreach ($oldArchive in $oldArchives) {
        Write-Log -Level INFO -Message "Removing old archive: $($oldArchive.Name)"
        Remove-Item -LiteralPath $oldArchive.FullName -Force
    }
}

$config = $null
$pendingArchives = New-Object System.Collections.ArrayList
$createdArchivePaths = New-Object System.Collections.ArrayList
$archivesPublished = $false

try {
    $ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
    $config = Read-BackupConfig -Path $ConfigPath

    [int]$copiesToKeep = $config.Backup.CopiesToKeep
    [int]$maxSourceSizeMB = $config.Backup.MaxSourceSizeMB
    [int]$safetyReserveMB = $config.Backup.SafetyReserveMB
    [int]$maxLogSizeMB = $config.Logging.MaxFileSizeMB
    [int]$logFilesToKeep = $config.Logging.FilesToKeep
    if ($copiesToKeep -lt 1 -or $maxSourceSizeMB -lt 1 -or $safetyReserveMB -lt 0 -or
        $maxLogSizeMB -lt 1 -or $logFilesToKeep -lt 1) {
        throw 'One or more numeric configuration values are outside the supported range.'
    }

    $sourceDefinitions = @($config.Backup.Sources)
    if ($sourceDefinitions.Count -eq 0) {
        throw 'No backup sources are configured.'
    }

    $resolvedSources = New-Object System.Collections.ArrayList
    $sourceNames = @{}
    foreach ($sourceDefinition in $sourceDefinitions) {
        $safeSourceName = ConvertTo-SafeFileName -Value ([string]$sourceDefinition.Name)
        if ($sourceNames.ContainsKey($safeSourceName.ToLowerInvariant())) {
            throw "Duplicate backup source name: '$safeSourceName'."
        }
        $sourceNames[$safeSourceName.ToLowerInvariant()] = $true
        [void]$resolvedSources.Add([pscustomobject]@{
            Name        = $safeSourceName
            DisplayName = [string]$sourceDefinition.DisplayName
            Kind        = 'KnownFolder'
            KnownFolder = [string]$sourceDefinition.KnownFolder
            Path        = $null
        })
    }

    $runTime = Get-Date
    $scheduleMode = [string]$config.Backup.ScheduleMode
    if ($scheduleMode -ieq 'Weekly') {
        $weeklyDay = [System.DayOfWeek][Enum]::Parse(
            [System.DayOfWeek],
            [string]$config.Backup.WeeklyDay,
            $true
        )
        if ($runTime.DayOfWeek -ne $weeklyDay) {
            exit 0
        }
    }
    elseif ($scheduleMode -ine 'Daily') {
        throw "Unsupported ScheduleMode: '$scheduleMode'."
    }

    $backupRootPath = [System.IO.Path]::GetFullPath([string]$config.Backup.RootPath)
    $localDirectoriesListPath = Join-Path (Split-Path -Parent $ConfigPath) $script:LocalDirectoriesListFileName
    $localDirectorySources = @(Get-LocalDirectorySources `
        -ListPath $localDirectoriesListPath `
        -ExistingSourceNames $sourceNames `
        -BackupRootPath $backupRootPath)
    foreach ($localDirectorySource in $localDirectorySources) {
        [void]$resolvedSources.Add($localDirectorySource)
    }

    $safeUserName = ConvertTo-SafeFileName -Value $env:USERNAME
    $script:UserBackupPath = Join-Path $backupRootPath $safeUserName
    $dateStamp = $runTime.ToString('yyyyMMdd')

    $allArchivesExist = $true
    foreach ($source in $resolvedSources) {
        if (-not (Test-ArchiveExistsForDate -TargetPath $script:UserBackupPath -DateStamp $dateStamp -SourceName $source.Name)) {
            $allArchivesExist = $false
            break
        }
    }
    if ($allArchivesExist) {
        exit 0
    }

    $backupDriveRoot = [System.IO.Path]::GetPathRoot($backupRootPath)
    if ([string]::IsNullOrWhiteSpace($backupDriveRoot)) {
        throw "Unable to resolve a drive for '$backupRootPath'."
    }
    $driveInfo = New-Object System.IO.DriveInfo($backupDriveRoot)
    if (-not $driveInfo.IsReady) {
        throw "Drive '$backupDriveRoot' is not ready."
    }

    if (-not (Test-Path -LiteralPath $backupRootPath -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $backupRootPath -Force)
    }
    if ([bool]$config.Backup.HideRootFolder) {
        $rootItem = Get-Item -LiteralPath $backupRootPath -Force
        $rootItem.Attributes = $rootItem.Attributes -bor [System.IO.FileAttributes]::Hidden
    }
    if (-not (Test-Path -LiteralPath $script:UserBackupPath -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $script:UserBackupPath -Force)
    }

    $script:LogStem = 'UserBackup'
    $script:LogPath = Join-Path $script:UserBackupPath ($script:LogStem + '.log')
    $script:MaxLogBytes = [long]$maxLogSizeMB * 1MB
    $script:LogFilesToKeep = $logFilesToKeep
    $script:Utf8Encoding = New-Object System.Text.UTF8Encoding($false)

    if ((Test-Path -LiteralPath $script:LogPath -PathType Leaf) -and
        ((Get-Item -LiteralPath $script:LogPath).Length -ge $script:MaxLogBytes)) {
        Move-CurrentLogToArchive
    }
    Remove-OldLogFiles
    $sessionStartMessage = "Starting backup for user '$env:USERNAME' in '$scheduleMode' mode."
    Add-LogSessionSeparator -FirstLevel INFO -FirstMessage $sessionStartMessage
    Write-Log -Level INFO -Message $sessionStartMessage

    $excludeMasks = @($config.Backup.ExcludeMasks)
    $sourceManifests = New-Object System.Collections.ArrayList
    [long]$totalSourceBytes = 0

    foreach ($source in $resolvedSources) {
        if ($source.Kind -eq 'LocalPath') {
            $sourcePath = [string]$source.Path
        }
        else {
            $knownFolder = [Environment+SpecialFolder][Enum]::Parse(
                [Environment+SpecialFolder],
                $source.KnownFolder,
                $true
            )
            $sourcePath = [Environment]::GetFolderPath($knownFolder)
        }
        if ([string]::IsNullOrWhiteSpace($sourcePath) -or
            -not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
            throw "Source folder '$($source.Name)' was not found: '$sourcePath'."
        }

        Write-Log -Level INFO -Message "Building manifest for '$($source.Name)' from '$sourcePath'."
        $manifestResult = New-SourceManifest `
            -SourcePath $sourcePath `
            -SourceName $source.Name `
            -ExcludeMasks $excludeMasks

        $sourceSizeMB = [double]$manifestResult.TotalBytes / 1MB
        Write-Log -Level INFO -Message ("Source '{0}' size after exclusions: {1:N2} MB." -f $source.Name, $sourceSizeMB)

        if ([long]$manifestResult.TotalBytes -gt ([long]$maxSourceSizeMB * 1MB)) {
            $warningText = [string]$config.Messages.SourceTooLargeText -f
                $source.DisplayName,
                $sourceSizeMB,
                $maxSourceSizeMB
            Write-Log -Level ERROR -Message $warningText
            Show-UserMessage `
                -Title ([string]$config.Messages.SourceTooLargeTitle) `
                -Text $warningText `
                -CopyButtonText ([string]$config.Messages.CopyButtonText) `
                -CloseButtonText ([string]$config.Messages.CloseButtonText)
            exit 3
        }

        [void]$sourceManifests.Add([pscustomobject]@{
            Source      = $source
            SourcePath  = $sourcePath
            Manifest    = @($manifestResult.Entries)
            TotalBytes  = [long]$manifestResult.TotalBytes
        })
        $totalSourceBytes += [long]$manifestResult.TotalBytes
    }

    $driveInfo = New-Object System.IO.DriveInfo($backupDriveRoot)
    $requiredSpace = [long][Math]::Ceiling($totalSourceBytes * 1.02) + ([long]$safetyReserveMB * 1MB)
    $driveName = $driveInfo.Name.TrimEnd('\')
    Write-Log -Level INFO -Message ("Total source size: {0:N0} bytes; free space: {1:N0} bytes." -f $totalSourceBytes, $driveInfo.AvailableFreeSpace)

    if ($driveInfo.AvailableFreeSpace -lt $requiredSpace) {
        $lowSpaceText = [string]$config.Messages.LowSpaceText -f $driveName
        Write-Log -Level ERROR -Message $lowSpaceText
        Show-UserMessage `
            -Title ([string]$config.Messages.LowSpaceTitle) `
            -Text $lowSpaceText `
            -CopyButtonText ([string]$config.Messages.CopyButtonText) `
            -CloseButtonText ([string]$config.Messages.CloseButtonText)
        exit 2
    }

    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    $archiveTimestamp = $runTime.ToString('yyyyMMdd_HHmmss')

    foreach ($sourceManifest in $sourceManifests) {
        $archiveName = $archiveTimestamp + '_' + $sourceManifest.Source.Name + '.zip'
        $archivePath = Join-Path $script:UserBackupPath $archiveName
        [void]$pendingArchives.Add([pscustomobject]@{
            SourceName  = $sourceManifest.Source.Name
            FinalPath   = $archivePath
            PartialPath = $archivePath + '.partial'
            Manifest    = @($sourceManifest.Manifest)
        })
    }

    $stalePartials = @(
        Get-ChildItem -LiteralPath $script:UserBackupPath -Filter '*.zip.partial' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddDays(-1) }
    )
    foreach ($stalePartial in $stalePartials) {
        Remove-Item -LiteralPath $stalePartial.FullName -Force -ErrorAction SilentlyContinue
    }

    foreach ($pendingArchive in $pendingArchives) {
        Write-Log -Level INFO -Message "Creating archive '$($pendingArchive.FinalPath)'."
        New-ZipFromManifest -Manifest $pendingArchive.Manifest -PartialPath $pendingArchive.PartialPath
    }
    foreach ($pendingArchive in $pendingArchives) {
        Move-Item -LiteralPath $pendingArchive.PartialPath -Destination $pendingArchive.FinalPath
        [void]$createdArchivePaths.Add($pendingArchive.FinalPath)
    }
    $archivesPublished = $true

    foreach ($source in $resolvedSources) {
        Remove-OldArchives `
            -TargetPath $script:UserBackupPath `
            -SourceName $source.Name `
            -CopiesToKeep $copiesToKeep
    }

    Write-Log -Level INFO -Message "Backup completed successfully. Created $($createdArchivePaths.Count) archive(s)."
    exit 0
}
catch {
    foreach ($pendingArchive in @($pendingArchives)) {
        if (Test-Path -LiteralPath $pendingArchive.PartialPath -PathType Leaf) {
            Remove-Item -LiteralPath $pendingArchive.PartialPath -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $archivesPublished) {
        foreach ($createdArchivePath in @($createdArchivePaths)) {
            if (Test-Path -LiteralPath $createdArchivePath -PathType Leaf) {
                Remove-Item -LiteralPath $createdArchivePath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    try { Write-Log -Level ERROR -Message $_.Exception.ToString() } catch { }

    if ($null -ne $config -and $null -ne $config.Messages) {
        $errorText = [string]$config.Messages.BackupErrorText -f $_.Exception.Message
        Show-UserMessage `
            -Title ([string]$config.Messages.BackupErrorTitle) `
            -Text $errorText `
            -CopyButtonText ([string]$config.Messages.CopyButtonText) `
            -CloseButtonText ([string]$config.Messages.CloseButtonText)
        exit 1
    }

    Write-Error $_.Exception.Message
    exit 10
}
