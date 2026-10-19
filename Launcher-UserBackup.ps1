[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'BackupConfig.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:LauncherVersion = '2026.09.15.1'
$script:LocalDirectoriesListFileName = 'LocalDirectoriesToBackup.lst'

function Read-BackupConfig {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file was not found: '$Path'."
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $json = [System.IO.File]::ReadAllText($Path, $utf8)
    return ($json | ConvertFrom-Json -ErrorAction Stop)
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
            # A notification failure must not hide the original launcher failure.
        }
    }
}

function Initialize-LauncherLog {
    param(
        [Parameter(Mandatory)][string]$LocalDirectory,
        [Parameter(Mandatory)]$Config
    )

    $logFileName = [string]$Config.Logging.LauncherFileName
    if ([string]::IsNullOrWhiteSpace($logFileName) -or
        [System.IO.Path]::GetFileName($logFileName) -ne $logFileName) {
        throw 'Logging.LauncherFileName must contain a file name without a directory path.'
    }

    $script:LauncherLogPath = Join-Path $LocalDirectory $logFileName
    $script:LauncherLogStem = [System.IO.Path]::GetFileNameWithoutExtension($logFileName)
    $script:LauncherLogExtension = [System.IO.Path]::GetExtension($logFileName)
    $script:LauncherMaxLogBytes = [long]$Config.Logging.MaxFileSizeMB * 1MB
    $script:LauncherLogFilesToKeep = [int]$Config.Logging.FilesToKeep
    $script:LauncherUtf8Encoding = New-Object System.Text.UTF8Encoding($false)
}

function Remove-OldLauncherLogs {
    $pattern = $script:LauncherLogStem + '.*' + $script:LauncherLogExtension
    $rotatedLogsToKeep = [Math]::Max(0, $script:LauncherLogFilesToKeep - 1)
    $oldLogs = @(
        Get-ChildItem -LiteralPath (Split-Path -Parent $script:LauncherLogPath) -Filter $pattern -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -Skip $rotatedLogsToKeep
    )
    foreach ($oldLog in $oldLogs) {
        Remove-Item -LiteralPath $oldLog.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Move-CurrentLauncherLogToArchive {
    if (-not (Test-Path -LiteralPath $script:LauncherLogPath -PathType Leaf)) {
        return
    }
    $currentLog = Get-Item -LiteralPath $script:LauncherLogPath
    if ($currentLog.Length -eq 0) {
        return
    }

    $rotationStamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $rotatedName = $script:LauncherLogStem + '.' + $rotationStamp + $script:LauncherLogExtension
    $rotatedPath = Join-Path (Split-Path -Parent $script:LauncherLogPath) $rotatedName
    Move-Item -LiteralPath $script:LauncherLogPath -Destination $rotatedPath -Force
}

function Write-LauncherLog {
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )

    if ($Message.Length -gt 200000) {
        $Message = $Message.Substring(0, 200000) + ' ... [entry truncated]'
    }
    $line = '{0} [{1}] {2}{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message, [Environment]::NewLine
    $lineBytes = $script:LauncherUtf8Encoding.GetByteCount($line)

    if (Test-Path -LiteralPath $script:LauncherLogPath -PathType Leaf) {
        $currentLength = (Get-Item -LiteralPath $script:LauncherLogPath).Length
        if (($currentLength + $lineBytes) -gt $script:LauncherMaxLogBytes) {
            Move-CurrentLauncherLogToArchive
            Remove-OldLauncherLogs
        }
    }
    [System.IO.File]::AppendAllText($script:LauncherLogPath, $line, $script:LauncherUtf8Encoding)
}

function Add-LauncherLogSessionSeparator {
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'WARN', 'ERROR')][string]$FirstLevel,
        [Parameter(Mandatory)][string]$FirstMessage
    )

    $separator = [Environment]::NewLine
    $separatorBytes = $script:LauncherUtf8Encoding.GetByteCount($separator)
    $previewLine = '{0} [{1}] {2}{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $FirstLevel, $FirstMessage, [Environment]::NewLine
    $requiredBytes = $separatorBytes + $script:LauncherUtf8Encoding.GetByteCount($previewLine)

    if (Test-Path -LiteralPath $script:LauncherLogPath -PathType Leaf) {
        $currentLength = (Get-Item -LiteralPath $script:LauncherLogPath).Length
        if (($currentLength + $requiredBytes) -gt $script:LauncherMaxLogBytes) {
            Move-CurrentLauncherLogToArchive
            Remove-OldLauncherLogs
        }
    }

    [System.IO.File]::AppendAllText($script:LauncherLogPath, $separator, $script:LauncherUtf8Encoding)
}

function Test-IsNetworkUnavailableError {
    param([Parameter(Mandatory)]$ErrorObject)

    $exception = $null
    if ($ErrorObject -is [System.Management.Automation.ErrorRecord]) {
        $exception = $ErrorObject.Exception
    }
    elseif ($ErrorObject -is [System.Exception]) {
        $exception = $ErrorObject
    }

    $networkErrorCodes = @(53, 64, 67, 121, 1203, 1231, 1232, 2250)
    while ($null -ne $exception) {
        $win32ErrorCode = $exception.HResult -band 0xFFFF
        if ($networkErrorCodes -contains $win32ErrorCode) {
            return $true
        }
        $exception = $exception.InnerException
    }
    return $false
}

function Test-NetworkPathAvailable {
    param([Parameter(Mandatory)][string]$Path)

    try {
        return [bool](Test-Path -LiteralPath $Path -PathType Container -ErrorAction Stop)
    }
    catch {
        return $false
    }
}

function Assert-PowerShellSyntax {
    param([Parameter(Mandatory)][string]$Path)

    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$parseErrors
    )

    if ($parseErrors.Count -gt 0) {
        $details = ($parseErrors | ForEach-Object { $_.Message }) -join '; '
        throw "PowerShell script '$Path' contains syntax errors: $details"
    }
}

function Test-FilesEqual {
    param(
        [Parameter(Mandatory)][string]$FirstPath,
        [Parameter(Mandatory)][string]$SecondPath
    )

    if (-not (Test-Path -LiteralPath $FirstPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $SecondPath -PathType Leaf)) {
        return $false
    }

    $firstFile = Get-Item -LiteralPath $FirstPath
    $secondFile = Get-Item -LiteralPath $SecondPath
    if ($firstFile.Length -ne $secondFile.Length) {
        return $false
    }

    $firstHash = (Get-FileHash -LiteralPath $FirstPath -Algorithm SHA256).Hash
    $secondHash = (Get-FileHash -LiteralPath $SecondPath -Algorithm SHA256).Hash
    return $firstHash -eq $secondHash
}

function Assert-SimpleFileName {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$SettingName
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or
        [System.IO.Path]::GetFileName($Value) -ne $Value) {
        throw "$SettingName must contain a file name without a directory path."
    }
}

function Assert-BackupConfig {
    param([Parameter(Mandatory)]$Config)

    Assert-SimpleFileName -Value ([string]$Config.Update.WorkerFileName) -SettingName 'Update.WorkerFileName'
    Assert-SimpleFileName -Value ([string]$Config.Update.LauncherFileName) -SettingName 'Update.LauncherFileName'
    Assert-SimpleFileName -Value ([string]$Config.Update.TaskRegistrarFileName) -SettingName 'Update.TaskRegistrarFileName'
    Assert-SimpleFileName -Value ([string]$Config.Update.ConfigFileName) -SettingName 'Update.ConfigFileName'
    Assert-SimpleFileName -Value ([string]$Config.Logging.LauncherFileName) -SettingName 'Logging.LauncherFileName'

    $artifactNames = @(
        [string]$Config.Update.WorkerFileName,
        [string]$Config.Update.LauncherFileName,
        [string]$Config.Update.TaskRegistrarFileName,
        [string]$Config.Update.ConfigFileName,
        [string]$Config.Logging.LauncherFileName,
        $script:LocalDirectoriesListFileName
    )
    $uniqueArtifactNames = @($artifactNames | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    if ($uniqueArtifactNames.Count -ne $artifactNames.Count) {
        throw 'Worker, launcher, task registrar, configuration, launcher log and local directory list file names must be unique.'
    }

    $requiredStrings = @(
        [string]$Config.Install.LocalSubdirectory,
        [string]$Config.Task.Name,
        [string]$Config.Task.Path,
        [string]$Config.Task.DailyRunTime,
        [string]$Config.Update.NetworkPath,
        [string]$Config.Backup.RootPath,
        [string]$Config.Backup.ScheduleMode
    )
    foreach ($requiredString in $requiredStrings) {
        if ([string]::IsNullOrWhiteSpace($requiredString)) {
            throw 'A required configuration string is empty.'
        }
    }

    [int]$delayMinutes = $Config.Task.DelayMinutes
    [string]$dailyRunTime = $Config.Task.DailyRunTime
    [int]$executionLimitHours = $Config.Task.ExecutionTimeLimitHours
    [int]$copiesToKeep = $Config.Backup.CopiesToKeep
    [int]$maxSourceSizeMB = $Config.Backup.MaxSourceSizeMB
    [int]$safetyReserveMB = $Config.Backup.SafetyReserveMB
    [int]$maxLogSizeMB = $Config.Logging.MaxFileSizeMB
    [int]$logFilesToKeep = $Config.Logging.FilesToKeep
    if ($delayMinutes -lt 1 -or $delayMinutes -gt 1440 -or
        $executionLimitHours -lt 1 -or $copiesToKeep -lt 1 -or
        $maxSourceSizeMB -lt 1 -or $safetyReserveMB -lt 0 -or
        $maxLogSizeMB -lt 1 -or $logFilesToKeep -lt 1) {
        throw 'One or more numeric configuration values are outside the supported range.'
    }

    if (-not [string]$Config.Task.Path.StartsWith('\') -or -not [string]$Config.Task.Path.EndsWith('\')) {
        throw 'Task.Path must start and end with a backslash (e.g., \ASUP\User BackUp Manager\).'
    }
    $managedTaskNames = @($Config.Task.ManagedNames)
    if ($managedTaskNames.Count -eq 0) {
        throw 'Task.ManagedNames must contain at least one task name.'
    }
    foreach ($managedTaskName in $managedTaskNames) {
        if ([string]::IsNullOrWhiteSpace([string]$managedTaskName)) {
            throw 'Task.ManagedNames contains an empty task name.'
        }
    }

    if ($dailyRunTime -notmatch '^(?:[01]\d|2[0-3]):[0-5]\d$') {
        throw 'Task.DailyRunTime must use the 24-hour HH:mm format.'
    }

    $scheduleMode = [string]$Config.Backup.ScheduleMode
    if ($scheduleMode -ieq 'Weekly') {
        [void][Enum]::Parse([System.DayOfWeek], [string]$Config.Backup.WeeklyDay, $true)
    }
    elseif ($scheduleMode -ine 'Daily') {
        throw "Unsupported Backup.ScheduleMode: '$scheduleMode'."
    }

    $sources = @($Config.Backup.Sources)
    if ($sources.Count -eq 0) {
        throw 'Backup.Sources must contain at least one source.'
    }
    foreach ($source in $sources) {
        if ([string]::IsNullOrWhiteSpace([string]$source.Name) -or
            [string]::IsNullOrWhiteSpace([string]$source.DisplayName) -or
            [string]::IsNullOrWhiteSpace([string]$source.KnownFolder)) {
            throw 'Every backup source must define Name, DisplayName and KnownFolder.'
        }
        [void][Enum]::Parse([Environment+SpecialFolder], [string]$source.KnownFolder, $true)
    }

    $messageNames = @(
        'CopyButtonText',
        'CloseButtonText',
        'LowSpaceTitle',
        'LowSpaceText',
        'SourceTooLargeTitle',
        'SourceTooLargeText',
        'BackupErrorTitle',
        'BackupErrorText',
        'UpdateWarningTitle',
        'UpdateWarningText',
        'LauncherErrorTitle',
        'LauncherErrorText'
    )
    foreach ($messageName in $messageNames) {
        $messageProperty = $Config.Messages.PSObject.Properties[$messageName]
        if ($null -eq $messageProperty -or [string]::IsNullOrWhiteSpace([string]$messageProperty.Value)) {
            throw "Required GUI message is missing: Messages.$messageName."
        }
    }
}

$config = $null
$tempConfigPath = $null
$tempWorkerPath = $null
$tempTaskRegistrarPath = $null

try {
    $ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
    $localDirectory = Split-Path -Parent $ConfigPath
    $config = Read-BackupConfig -Path $ConfigPath
    Assert-BackupConfig -Config $config
    Initialize-LauncherLog -LocalDirectory $localDirectory -Config $config
    Remove-OldLauncherLogs
    $launcherStartMessage = "Launcher started. Version=$script:LauncherVersion."
    Add-LauncherLogSessionSeparator -FirstLevel INFO -FirstMessage $launcherStartMessage
    Write-LauncherLog -Level INFO -Message $launcherStartMessage

    $networkPath = [string]$config.Update.NetworkPath
    $configFileName = [string]$config.Update.ConfigFileName
    $currentConfigFileName = [System.IO.Path]::GetFileName($ConfigPath)
    $currentLauncherFileName = [System.IO.Path]::GetFileName($PSCommandPath)
    $updateError = $null
    $networkUnavailable = $false

    try {
        if (-not (Test-NetworkPathAvailable -Path $networkPath)) {
            $networkUnavailable = $true
            throw "Network update folder is not available: '$networkPath'."
        }

        $updateId = [Guid]::NewGuid().ToString('N')
        $networkConfigPath = Join-Path $networkPath $configFileName
        $tempConfigPath = Join-Path $localDirectory ($configFileName + '.' + $updateId + '.update')
        Copy-Item -LiteralPath $networkConfigPath -Destination $tempConfigPath -Force
        $updatedConfig = Read-BackupConfig -Path $tempConfigPath
        Assert-BackupConfig -Config $updatedConfig

        # LauncherFileName теперь можно менять, так как лаунчер обновляется
        # ConfigFileName можно менять, так как конфигурация обновляется

        $workerFileName = [string]$updatedConfig.Update.WorkerFileName
        $networkWorkerPath = Join-Path $networkPath $workerFileName
        $tempWorkerPath = Join-Path $localDirectory ($workerFileName + '.' + $updateId + '.update')
        Copy-Item -LiteralPath $networkWorkerPath -Destination $tempWorkerPath -Force
        Assert-PowerShellSyntax -Path $tempWorkerPath

        $taskRegistrarFileName = [string]$updatedConfig.Update.TaskRegistrarFileName
        $networkTaskRegistrarPath = Join-Path $networkPath $taskRegistrarFileName
        $tempTaskRegistrarPath = Join-Path $localDirectory ($taskRegistrarFileName + '.' + $updateId + '.update')
        Copy-Item -LiteralPath $networkTaskRegistrarPath -Destination $tempTaskRegistrarPath -Force
        Assert-PowerShellSyntax -Path $tempTaskRegistrarPath

        # Загружаем и проверяем лаунчер из сети
        $launcherFileName = [string]$updatedConfig.Update.LauncherFileName
        $networkLauncherPath = Join-Path $networkPath $launcherFileName
        $tempLauncherPath = Join-Path $localDirectory ($launcherFileName + '.' + $updateId + '.update')
        Copy-Item -LiteralPath $networkLauncherPath -Destination $tempLauncherPath -Force
        Assert-PowerShellSyntax -Path $tempLauncherPath

        # Загружаем список локальных директорий из сети
        $localDirsListFileName = $script:LocalDirectoriesListFileName
        $networkLocalDirsPath = Join-Path $networkPath $localDirsListFileName
        $tempLocalDirsPath = Join-Path $localDirectory ($localDirsListFileName + '.' + $updateId + '.update')
        if (Test-Path -LiteralPath $networkLocalDirsPath -PathType Leaf) {
            Copy-Item -LiteralPath $networkLocalDirsPath -Destination $tempLocalDirsPath -Force
        } else {
            # Если файла нет в сети, создаем пустой временный файл
            [System.IO.File]::WriteAllText($tempLocalDirsPath, '', [System.Text.Encoding]::UTF8)
        }

        # Загружаем список локальных директорий из сети
        $localDirsListFileName = $script:LocalDirectoriesListFileName
        $networkLocalDirsPath = Join-Path $networkPath $localDirsListFileName
        $tempLocalDirsPath = Join-Path $localDirectory ($localDirsListFileName + '.' + $updateId + '.update')
        if (Test-Path -LiteralPath $networkLocalDirsPath -PathType Leaf) {
            Copy-Item -LiteralPath $networkLocalDirsPath -Destination $tempLocalDirsPath -Force
        } else {
            # Если файла нет в сети, создаем пустой временный файл
            [System.IO.File]::WriteAllText($tempLocalDirsPath, '', [System.Text.Encoding]::UTF8)
        }

        # Загружаем установочные скрипты из сети
        $installScripts = @(
            'Install-UserBackup.ps1',
            'Uninstall-UserBackup.ps1'
        )
        
        $tempScriptPaths = @{}
        
        foreach ($scriptName in $installScripts) {
            $networkScriptPath = Join-Path $networkPath $scriptName
            $tempScriptPath = Join-Path $localDirectory ($scriptName + '.' + $updateId + '.update')
            $localScriptPath = Join-Path $localDirectory $scriptName
            
            if (Test-Path -LiteralPath $networkScriptPath -PathType Leaf) {
                Copy-Item -LiteralPath $networkScriptPath -Destination $tempScriptPath -Force
                Assert-PowerShellSyntax -Path $tempScriptPath
                $tempScriptPaths[$scriptName] = $tempScriptPath
            }
        }

        $localWorkerPath = Join-Path $localDirectory $workerFileName
        $localTaskRegistrarPath = Join-Path $localDirectory $taskRegistrarFileName
        $localLauncherPath = Join-Path $localDirectory $launcherFileName
        $localDirsListPath = Join-Path $localDirectory $localDirsListFileName
        $localInstallPath = Join-Path $localDirectory 'Install-UserBackup.ps1'
        $localUninstallPath = Join-Path $localDirectory 'Uninstall-UserBackup.ps1'
        
        # Все файлы для обновления
        $updateItems = @(
            [pscustomobject]@{ Source = $tempConfigPath; Destination = $ConfigPath },
            [pscustomobject]@{ Source = $tempWorkerPath; Destination = $localWorkerPath },
            [pscustomobject]@{ Source = $tempTaskRegistrarPath; Destination = $localTaskRegistrarPath },
            [pscustomobject]@{ Source = $tempLocalDirsPath; Destination = $localDirsListPath }
        )
        
        # Добавляем установочные скрипты, если они были загружены
        if ($tempScriptPaths.ContainsKey('Install-UserBackup.ps1')) {
            $updateItems += [pscustomobject]@{ Source = $tempScriptPaths['Install-UserBackup.ps1']; Destination = $localInstallPath }
        }
        if ($tempScriptPaths.ContainsKey('Uninstall-UserBackup.ps1')) {
            $updateItems += [pscustomobject]@{ Source = $tempScriptPaths['Uninstall-UserBackup.ps1']; Destination = $localUninstallPath }
        }
        
        # Лаунчер обновляем в последнюю очередь
        $updateItems += [pscustomobject]@{ Source = $tempLauncherPath; Destination = $localLauncherPath }

        $hasActualUpdate = $false
        foreach ($updateItem in $updateItems) {
            if (-not (Test-FilesEqual -FirstPath $updateItem.Source -SecondPath $updateItem.Destination)) {
                $hasActualUpdate = $true
                break
            }
        }

        if (-not $hasActualUpdate) {
            Write-LauncherLog -Level INFO -Message "Network files are unchanged: '$networkPath'."
        }
        else {
            $deploymentState = New-Object System.Collections.ArrayList
            $deploymentCommitted = $false
            $rollbackCompleted = $false

            try {
                foreach ($updateItem in $updateItems) {
                    $hadExistingFile = Test-Path -LiteralPath $updateItem.Destination -PathType Leaf
                    $rollbackPath = $updateItem.Destination + '.' + $updateId + '.rollback'
                    if ($hadExistingFile) {
                        Copy-Item -LiteralPath $updateItem.Destination -Destination $rollbackPath -Force
                    }
                    [void]$deploymentState.Add([pscustomobject]@{
                        Destination     = $updateItem.Destination
                        RollbackPath    = $rollbackPath
                        HadExistingFile = $hadExistingFile
                    })
                    Copy-Item -LiteralPath $updateItem.Source -Destination $updateItem.Destination -Force
                }

                $config = Read-BackupConfig -Path $ConfigPath
                Assert-BackupConfig -Config $config
                Initialize-LauncherLog -LocalDirectory $localDirectory -Config $config

                $registrationPowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                if (-not (Test-Path -LiteralPath $registrationPowerShellExe -PathType Leaf)) {
                    throw "Windows PowerShell was not found: '$registrationPowerShellExe'."
                }
                & $registrationPowerShellExe `
                    -NoLogo `
                    -NoProfile `
                    -NonInteractive `
                    -WindowStyle Hidden `
                    -ExecutionPolicy Bypass `
                    -File $localTaskRegistrarPath `
                    -ConfigPath $ConfigPath
                $taskRegistrarExitCode = $LASTEXITCODE
                if ($taskRegistrarExitCode -ne 0) {
                    throw "Task registrar failed with exit code $taskRegistrarExitCode."
                }

                $deploymentCommitted = $true
            }
            catch {
                $deploymentError = $_
                $rollbackErrors = New-Object System.Collections.ArrayList

                for ($index = $deploymentState.Count - 1; $index -ge 0; $index--) {
                    $state = $deploymentState[$index]
                    try {
                        if ($state.HadExistingFile -and
                            (Test-Path -LiteralPath $state.RollbackPath -PathType Leaf)) {
                            Copy-Item -LiteralPath $state.RollbackPath -Destination $state.Destination -Force
                        }
                        elseif (-not $state.HadExistingFile -and
                            (Test-Path -LiteralPath $state.Destination -PathType Leaf)) {
                            Remove-Item -LiteralPath $state.Destination -Force
                        }
                    }
                    catch {
                        [void]$rollbackErrors.Add("$($state.Destination): $($_.Exception.Message)")
                    }
                }

                $rollbackCompleted = ($rollbackErrors.Count -eq 0)
                if ($rollbackCompleted -and (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
                    $config = Read-BackupConfig -Path $ConfigPath
                    Assert-BackupConfig -Config $config
                    Initialize-LauncherLog -LocalDirectory $localDirectory -Config $config
                }
                if (-not $rollbackCompleted) {
                    throw ("Update failed: {0}. File rollback errors: {1}. Rollback files were preserved." -f
                        $deploymentError.Exception.Message,
                        (@($rollbackErrors) -join ' | '))
                }
                throw $deploymentError
            }
            finally {
                if ($deploymentCommitted -or $rollbackCompleted) {
                    foreach ($state in @($deploymentState)) {
                        Remove-Item -LiteralPath $state.RollbackPath -Force -ErrorAction SilentlyContinue
                    }
                }
            }

            try {
                $updatedFiles = @('configuration', 'worker', 'task registrar', 'local directories list')
                if ($tempScriptPaths.ContainsKey('Install-UserBackup.ps1')) {
                    $updatedFiles += 'installer'
                }
                if ($tempScriptPaths.ContainsKey('Uninstall-UserBackup.ps1')) {
                    $updatedFiles += 'uninstaller'
                }
                $updatedFiles += 'launcher'
                
                $filesList = $updatedFiles -join ', '
                Write-LauncherLog -Level INFO -Message "Update completed successfully from '$networkPath'. Updated files: $filesList."
            }
            catch {
                # Logging after commit must not roll back a valid update.
            }
        }
    }
    catch {
        $updateError = $_
        if ((Test-IsNetworkUnavailableError -ErrorObject $updateError) -or
            -not (Test-NetworkPathAvailable -Path $networkPath)) {
            $networkUnavailable = $true
        }
    }
    finally {
        foreach ($temporaryPath in @($tempConfigPath, $tempWorkerPath, $tempTaskRegistrarPath)) {
            if (-not [string]::IsNullOrWhiteSpace($temporaryPath) -and
                (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if ($null -ne $updateError) {
        try {
            Write-LauncherLog -Level ERROR -Message ("Update failed: {0}" -f $updateError.Exception.ToString())
        }
        catch {
            # A logging failure must not block the local worker fallback.
        }

        $showUpdateWarning = (-not $networkUnavailable) -and [bool]$config.Update.ShowWarningOnFailure
        if ($showUpdateWarning) {
            $warningText = [string]$config.Messages.UpdateWarningText -f $updateError.Exception.Message
            Show-UserMessage `
                -Title ([string]$config.Messages.UpdateWarningTitle) `
                -Text $warningText `
                -CopyButtonText ([string]$config.Messages.CopyButtonText) `
                -CloseButtonText ([string]$config.Messages.CloseButtonText)
        }
        if (-not [bool]$config.Update.ContinueOnFailure) {
            exit 4
        }
    }

    $workerPath = Join-Path $localDirectory ([string]$config.Update.WorkerFileName)
    if (-not (Test-Path -LiteralPath $workerPath -PathType Leaf)) {
        throw "Local worker script was not found: '$workerPath'."
    }
    Assert-PowerShellSyntax -Path $workerPath

    $powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) {
        throw "Windows PowerShell was not found: '$powerShellExe'."
    }

    & $powerShellExe `
        -NoLogo `
        -NoProfile `
        -NonInteractive `
        -WindowStyle Hidden `
        -ExecutionPolicy Bypass `
        -File $workerPath `
        -ConfigPath $ConfigPath

    $workerExitCode = $LASTEXITCODE
    if ($workerExitCode -eq 10) {
        $errorText = [string]$config.Messages.LauncherErrorText -f 'The worker could not load its configuration.'
        Show-UserMessage `
            -Title ([string]$config.Messages.LauncherErrorTitle) `
            -Text $errorText `
            -CopyButtonText ([string]$config.Messages.CopyButtonText) `
            -CloseButtonText ([string]$config.Messages.CloseButtonText)
    }
    exit $workerExitCode
}
catch {
    try { Write-LauncherLog -Level ERROR -Message $_.Exception.ToString() } catch { }

    if ($null -ne $config -and $null -ne $config.Messages) {
        $errorText = [string]$config.Messages.LauncherErrorText -f $_.Exception.Message
        Show-UserMessage `
            -Title ([string]$config.Messages.LauncherErrorTitle) `
            -Text $errorText `
            -CopyButtonText ([string]$config.Messages.CopyButtonText) `
            -CloseButtonText ([string]$config.Messages.CloseButtonText)
    }
    else {
        Write-Error $_.Exception.Message
    }
    exit 1
}
