[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'BackupConfig.json'),

    [string]$InstallDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$managedMarker = '[ASUP.UserBackup.Managed]'

function Read-BackupConfig {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file was not found: '$Path'."
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $json = [System.IO.File]::ReadAllText($Path, $utf8)
    return ($json | ConvertFrom-Json -ErrorAction Stop)
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

function Add-UniqueString {
    param(
        [System.Collections.ArrayList]$List,
        [Parameter(Mandatory)][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }
    foreach ($existingValue in @($List)) {
        if ([string]$existingValue -ieq $Value) {
            return
        }
    }
    [void]$List.Add($Value)
}

function Add-ConfigMetadata {
    param(
        [Parameter(Mandatory)]$Config,
        [System.Collections.ArrayList]$TaskNames,
        [System.Collections.ArrayList]$TaskPaths,
        [System.Collections.ArrayList]$LauncherFileNames,
        [System.Collections.ArrayList]$ConfigFileNames
    )

    $managedNamesProperty = $Config.Task.PSObject.Properties['ManagedNames']
    if ($null -ne $managedNamesProperty) {
        foreach ($taskName in @($managedNamesProperty.Value)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$taskName)) {
                Add-UniqueString -List $TaskNames -Value ([string]$taskName)
            }
        }
    }

    $taskNameProperty = $Config.Task.PSObject.Properties['Name']
    if ($null -ne $taskNameProperty -and
        -not [string]::IsNullOrWhiteSpace([string]$taskNameProperty.Value)) {
        Add-UniqueString -List $TaskNames -Value ([string]$taskNameProperty.Value)
    }

    $taskPathProperty = $Config.Task.PSObject.Properties['Path']
    $taskPath = '\'
    if ($null -ne $taskPathProperty -and
        -not [string]::IsNullOrWhiteSpace([string]$taskPathProperty.Value)) {
        $taskPath = [string]$taskPathProperty.Value
    }
    Add-UniqueString -List $TaskPaths -Value $taskPath

    $launcherProperty = $Config.Update.PSObject.Properties['LauncherFileName']
    $configProperty = $Config.Update.PSObject.Properties['ConfigFileName']
    if ($null -eq $launcherProperty -or $null -eq $configProperty) {
        throw 'Update.LauncherFileName or Update.ConfigFileName is missing.'
    }
    $launcherFileName = [string]$launcherProperty.Value
    $configFileName = [string]$configProperty.Value
    Assert-SimpleFileName -Value $launcherFileName -SettingName 'Update.LauncherFileName'
    Assert-SimpleFileName -Value $configFileName -SettingName 'Update.ConfigFileName'
    Add-UniqueString -List $LauncherFileNames -Value $launcherFileName
    Add-UniqueString -List $ConfigFileNames -Value $configFileName
}

function Test-TaskAssociatedWithProject {
    param(
        [Parameter(Mandatory)]$Task,
        [Parameter(Mandatory)][string[]]$TaskNames,
        [Parameter(Mandatory)][string[]]$TaskPaths,
        [Parameter(Mandatory)][string[]]$ExpectedArguments,
        [Parameter(Mandatory)][string]$PowerShellExe,
        [Parameter(Mandatory)][string]$CurrentUserSid,
        [Parameter(Mandatory)][string]$CurrentUserName,
        [Parameter(Mandatory)][string]$Marker
    )

    $principalUser = [string]$Task.Principal.UserId
    $ownedByCurrentUser = $principalUser -ieq $CurrentUserSid -or
        $principalUser -ieq $CurrentUserName
    if (-not $ownedByCurrentUser) {
        return $false
    }

    $markerMatches = ([string]$Task.Description).Contains($Marker)
    if ($markerMatches) {
        return $true
    }

    $pathMatches = $TaskPaths -contains [string]$Task.TaskPath
    $nameMatches = $TaskNames -contains [string]$Task.TaskName
    if ($pathMatches -and $nameMatches) {
        return $true
    }

    foreach ($taskAction in @($Task.Actions)) {
        if ([string]$taskAction.Execute -ine $PowerShellExe) {
            continue
        }
        foreach ($expectedArgument in $ExpectedArguments) {
            if ([string]$taskAction.Arguments -eq $expectedArgument) {
                return $true
            }
        }
    }

    return $false
}

try {
    $ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
    $sourceConfig = Read-BackupConfig -Path $ConfigPath

    $localAppDataRoot = [System.IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($InstallDirectory)) {
        $localSubdirectory = [string]$sourceConfig.Install.LocalSubdirectory
        if ([string]::IsNullOrWhiteSpace($localSubdirectory) -or
            [System.IO.Path]::IsPathRooted($localSubdirectory)) {
            throw 'Install.LocalSubdirectory must be a non-empty relative path.'
        }
        $InstallDirectory = Join-Path $localAppDataRoot $localSubdirectory
    }

    $InstallDirectory = [System.IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
    $localAppDataPrefix = $localAppDataRoot + '\'
    if ($InstallDirectory -ieq $localAppDataRoot -or
        -not ($InstallDirectory + '\').StartsWith(
            $localAppDataPrefix,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw "Refusing to remove a directory outside LOCALAPPDATA: '$InstallDirectory'."
    }

    $taskNames = New-Object System.Collections.ArrayList
    $taskPaths = New-Object System.Collections.ArrayList
    $launcherFileNames = New-Object System.Collections.ArrayList
    $configFileNames = New-Object System.Collections.ArrayList
    Add-ConfigMetadata `
        -Config $sourceConfig `
        -TaskNames $taskNames `
        -TaskPaths $taskPaths `
        -LauncherFileNames $launcherFileNames `
        -ConfigFileNames $configFileNames

    $candidateInstalledConfigNames = New-Object System.Collections.ArrayList
    foreach ($configFileName in @($configFileNames)) {
        Add-UniqueString -List $candidateInstalledConfigNames -Value ([string]$configFileName)
    }
    Add-UniqueString -List $candidateInstalledConfigNames -Value 'BackupConfig.json'

    foreach ($installedConfigName in @($candidateInstalledConfigNames)) {
        $installedConfigPath = Join-Path $InstallDirectory ([string]$installedConfigName)
        if (-not (Test-Path -LiteralPath $installedConfigPath -PathType Leaf)) {
            continue
        }
        try {
            $installedConfig = Read-BackupConfig -Path $installedConfigPath
            Add-ConfigMetadata `
                -Config $installedConfig `
                -TaskNames $taskNames `
                -TaskPaths $taskPaths `
                -LauncherFileNames $launcherFileNames `
                -ConfigFileNames $configFileNames
        }
        catch {
            Write-Warning "Installed configuration could not be read and will be ignored: $($_.Exception.Message)"
        }
    }

    $powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) {
        throw "Windows PowerShell was not found: '$powerShellExe'."
    }

    $expectedArguments = New-Object System.Collections.ArrayList
    foreach ($launcherFileName in @($launcherFileNames)) {
        $launcherPath = Join-Path $InstallDirectory ([string]$launcherFileName)
        foreach ($configFileName in @($configFileNames)) {
            $installedConfigPath = Join-Path $InstallDirectory ([string]$configFileName)
            $arguments = @(
                '-NoLogo'
                '-NoProfile'
                '-NonInteractive'
                '-WindowStyle Hidden'
                '-ExecutionPolicy Bypass'
                '-File "' + $launcherPath + '"'
                '-ConfigPath "' + $installedConfigPath + '"'
            ) -join ' '
            Add-UniqueString -List $expectedArguments -Value $arguments
        }
    }

    Import-Module ScheduledTasks -ErrorAction Stop
    $userIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $userSid = $userIdentity.User.Value
    $userName = $userIdentity.Name

    $associatedTasks = New-Object System.Collections.ArrayList
    foreach ($task in @(Get-ScheduledTask -ErrorAction Stop)) {
        if (Test-TaskAssociatedWithProject `
            -Task $task `
            -TaskNames @($taskNames) `
            -TaskPaths @($taskPaths) `
            -ExpectedArguments @($expectedArguments) `
            -PowerShellExe $powerShellExe `
            -CurrentUserSid $userSid `
            -CurrentUserName $userName `
            -Marker $managedMarker) {
            [void]$associatedTasks.Add($task)
        }
    }

    $taskRemovalErrors = New-Object System.Collections.ArrayList
    foreach ($task in @($associatedTasks)) {
        $taskIdentity = "$($task.TaskPath)$($task.TaskName)"
        try {
            if ([string]$task.State -eq 'Running' -and
                $PSCmdlet.ShouldProcess($taskIdentity, 'Stop scheduled task')) {
                Stop-ScheduledTask `
                    -TaskName $task.TaskName `
                    -TaskPath $task.TaskPath `
                    -ErrorAction Stop
            }
            if ($PSCmdlet.ShouldProcess($taskIdentity, 'Unregister scheduled task')) {
                Unregister-ScheduledTask `
                    -TaskName $task.TaskName `
                    -TaskPath $task.TaskPath `
                    -Confirm:$false `
                    -ErrorAction Stop
            }
        }
        catch {
            [void]$taskRemovalErrors.Add("${taskIdentity}: $($_.Exception.Message)")
        }
    }

    if ($taskRemovalErrors.Count -gt 0) {
        throw ("One or more associated scheduled tasks could not be removed. Local files were preserved: {0}" -f
            (@($taskRemovalErrors) -join ' | '))
    }

    if (Test-Path -LiteralPath $InstallDirectory) {
        if (-not (Test-Path -LiteralPath $InstallDirectory -PathType Container)) {
            throw "Installation path exists but is not a directory: '$InstallDirectory'."
        }
        if ($PSCmdlet.ShouldProcess($InstallDirectory, 'Remove local application files')) {
            Remove-Item -LiteralPath $InstallDirectory -Recurse -Force -ErrorAction Stop
        }
    }

    if ($WhatIfPreference) {
        Write-Host 'Uninstallation preview completed. No changes were made.' -ForegroundColor Yellow
    }
    else {
        Write-Host 'Uninstallation completed.' -ForegroundColor Green
    }
    Write-Host "Associated scheduled tasks found: $($associatedTasks.Count)"
    Write-Host "Local installation directory: $InstallDirectory"
    Write-Host 'Backup archives were not removed.'
    exit 0
}
catch {
    Write-Error ("Uninstallation failed: {0}" -f $_.Exception.Message)
    exit 1
}
