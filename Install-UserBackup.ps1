[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'BackupConfig.json'),
    [switch]$Diagnostic
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-BackupConfig {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file was not found: '$Path'."
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $json = [System.IO.File]::ReadAllText($Path, $utf8)
    return ($json | ConvertFrom-Json -ErrorAction Stop)
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
        throw "PowerShell syntax validation failed for '$Path': $details"
    }
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

$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
$config = Read-BackupConfig -Path $ConfigPath

$workerFileName = [string]$config.Update.WorkerFileName
$launcherFileName = [string]$config.Update.LauncherFileName
$taskRegistrarFileName = [string]$config.Update.TaskRegistrarFileName
$configFileName = [string]$config.Update.ConfigFileName
$launcherLogFileName = [string]$config.Logging.LauncherFileName
$localDirectoriesListFileName = 'LocalDirectoriesToBackup.lst'
Assert-SimpleFileName -Value $workerFileName -SettingName 'Update.WorkerFileName'
Assert-SimpleFileName -Value $launcherFileName -SettingName 'Update.LauncherFileName'
Assert-SimpleFileName -Value $taskRegistrarFileName -SettingName 'Update.TaskRegistrarFileName'
Assert-SimpleFileName -Value $configFileName -SettingName 'Update.ConfigFileName'
Assert-SimpleFileName -Value $launcherLogFileName -SettingName 'Logging.LauncherFileName'

$artifactNames = @(
    $workerFileName,
    $launcherFileName,
    $taskRegistrarFileName,
    $configFileName,
    $launcherLogFileName,
    $localDirectoriesListFileName
)

# Добавляем имена дополнительных файлов для проверки уникальности
$additionalFileNames = @(
    'Uninstall-UserBackup.ps1',
    'Uninstall-UserBackup.cmd',
    'Install-UserBackup.cmd',
    'README.md',
    'Debug-UserBackupTask.ps1'
)

$allArtifactNames = @($artifactNames) + @($additionalFileNames)
$uniqueArtifactNames = @($allArtifactNames | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
if ($uniqueArtifactNames.Count -ne $allArtifactNames.Count) {
    throw 'Worker, launcher, task registrar, configuration, launcher log, local directory list and additional file names must be unique.'
}

$sourceWorker = Join-Path $PSScriptRoot $workerFileName
$sourceLauncher = Join-Path $PSScriptRoot $launcherFileName
$sourceTaskRegistrar = Join-Path $PSScriptRoot $taskRegistrarFileName
$sourceLocalDirectoriesList = Join-Path $PSScriptRoot $localDirectoriesListFileName
foreach ($sourceScript in @($sourceWorker, $sourceLauncher, $sourceTaskRegistrar)) {
    if (-not (Test-Path -LiteralPath $sourceScript -PathType Leaf)) {
        throw "Required script was not found: '$sourceScript'."
    }
    Assert-PowerShellSyntax -Path $sourceScript
}

$localSubdirectory = [string]$config.Install.LocalSubdirectory
if ([string]::IsNullOrWhiteSpace($localSubdirectory) -or
    [System.IO.Path]::IsPathRooted($localSubdirectory)) {
    throw 'Install.LocalSubdirectory must be a non-empty relative path.'
}

$localAppDataRoot = [System.IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\') + '\'
$installDirectory = [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA $localSubdirectory))
if (-not ($installDirectory.TrimEnd('\') + '\').StartsWith(
    $localAppDataRoot,
    [System.StringComparison]::OrdinalIgnoreCase
)) {
    throw 'The configured installation directory is outside LOCALAPPDATA.'
}

$powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) {
    throw "Windows PowerShell was not found: '$powerShellExe'."
}

if (-not (Test-Path -LiteralPath $installDirectory -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $installDirectory -Force)
}

$installedWorker = Join-Path $installDirectory $workerFileName
$installedLauncher = Join-Path $installDirectory $launcherFileName
$installedTaskRegistrar = Join-Path $installDirectory $taskRegistrarFileName
$installedConfig = Join-Path $installDirectory $configFileName
$installedLocalDirectoriesList = Join-Path $installDirectory $localDirectoriesListFileName

$deploymentItems = New-Object System.Collections.ArrayList
[void]$deploymentItems.Add([pscustomobject]@{ Source = $sourceWorker; Destination = $installedWorker })
[void]$deploymentItems.Add([pscustomobject]@{ Source = $sourceLauncher; Destination = $installedLauncher })
[void]$deploymentItems.Add([pscustomobject]@{ Source = $sourceTaskRegistrar; Destination = $installedTaskRegistrar })
[void]$deploymentItems.Add([pscustomobject]@{ Source = $ConfigPath; Destination = $installedConfig })

# Добавляем дополнительные файлы для копирования
$additionalFiles = @(
    'Uninstall-UserBackup.ps1',
    'Uninstall-UserBackup.cmd',
    'Install-UserBackup.cmd',
    'README.md',
    'Debug-UserBackupTask.ps1'
)

foreach ($additionalFile in $additionalFiles) {
    $sourceAdditionalFile = Join-Path $PSScriptRoot $additionalFile
    $installedAdditionalFile = Join-Path $installDirectory $additionalFile
    
    if (Test-Path -LiteralPath $sourceAdditionalFile -PathType Leaf) {
        [void]$deploymentItems.Add([pscustomobject]@{
            Source = $sourceAdditionalFile
            Destination = $installedAdditionalFile
        })
        if ($Diagnostic) {
            Write-Host "[Diagnostic] Will copy additional file: '$additionalFile'" -ForegroundColor Green
        }
    }
    elseif ($Diagnostic) {
        Write-Host "[Diagnostic] Additional file not found: '$additionalFile'" -ForegroundColor Yellow
    }
}

if (Test-Path -LiteralPath $installedLocalDirectoriesList) {
    if (-not (Test-Path -LiteralPath $installedLocalDirectoriesList -PathType Leaf)) {
        throw "Local directory list path exists but is not a file: '$installedLocalDirectoriesList'."
    }
}
else {
    if (-not (Test-Path -LiteralPath $sourceLocalDirectoriesList -PathType Leaf)) {
        throw "Initial local directory list was not found: '$sourceLocalDirectoriesList'."
    }
    [void]$deploymentItems.Add([pscustomobject]@{
        Source      = $sourceLocalDirectoriesList
        Destination = $installedLocalDirectoriesList
    })
}
$installId = [Guid]::NewGuid().ToString('N')
$deploymentState = New-Object System.Collections.ArrayList
$deploymentCommitted = $false
$rollbackCompleted = $false

try {
    foreach ($deploymentItem in $deploymentItems) {
        $hadExistingFile = Test-Path -LiteralPath $deploymentItem.Destination -PathType Leaf
        $rollbackPath = $deploymentItem.Destination + '.' + $installId + '.rollback'
        if ($hadExistingFile) {
            Copy-Item -LiteralPath $deploymentItem.Destination -Destination $rollbackPath -Force
        }
        [void]$deploymentState.Add([pscustomobject]@{
            Destination     = $deploymentItem.Destination
            RollbackPath    = $rollbackPath
            HadExistingFile = $hadExistingFile
        })
        Copy-Item -LiteralPath $deploymentItem.Source -Destination $deploymentItem.Destination -Force
    }

    # Формируем аргументы для запуска регистратора
    $taskRegistrarArgs = @("-ConfigPath", "`"$installedConfig`"")
    if ($Diagnostic) {
        $taskRegistrarArgs += "-Diagnostic"
    }
    
    # Правильный вызов PowerShell с аргументами
    & $powerShellExe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installedTaskRegistrar @taskRegistrarArgs
    $taskRegistrarExitCode = $LASTEXITCODE
    if ($taskRegistrarExitCode -ne 0) {
        # Получаем информацию о системе для диагностики
        $systemInfo = @{
            ComputerName = $env:COMPUTERNAME
            UserName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            OSVersion = (Get-CimInstance Win32_OperatingSystem).Caption
            PowerShellVersion = $PSVersionTable.PSVersion.ToString()
            DateTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
        
        $errorDetails = "Task registrar failed with exit code $taskRegistrarExitCode.`n"
        $errorDetails += "System information:`n"
        foreach ($key in $systemInfo.Keys) {
            $errorDetails += "  $key : $($systemInfo[$key])`n"
        }
        $errorDetails += "Task registrar path: $installedTaskRegistrar`n"
        $errorDetails += "Config path: $installedConfig"
        
        throw $errorDetails
    }

    $deploymentCommitted = $true
}
catch {
    $originalError = $_
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
    if (-not $rollbackCompleted) {
        throw ("Installation failed: {0}. File rollback errors: {1}. Rollback files were preserved." -f
            $originalError.Exception.Message,
            (@($rollbackErrors) -join ' | '))
    }
    throw $originalError
}
finally {
    if ($deploymentCommitted -or $rollbackCompleted) {
        foreach ($state in @($deploymentState)) {
            Remove-Item -LiteralPath $state.RollbackPath -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host 'Installation completed.' -ForegroundColor Green
Write-Host "Task: $($config.Task.Path)$($config.Task.Name)"
Write-Host "Start delay after logon: $($config.Task.DelayMinutes) minute(s)"
Write-Host "Daily launcher start: $($config.Task.DailyRunTime)"
Write-Host "Installed directory: $installDirectory"
Write-Host "Launcher: $installedLauncher"
Write-Host "Task registrar: $installedTaskRegistrar"
Write-Host "Configuration: $installedConfig"
Write-Host "Local directory list: $installedLocalDirectoriesList"
