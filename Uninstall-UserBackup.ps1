[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath,

    [string]$InstallDirectory,
    
    [switch]$Diagnostic
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

function Resolve-AccountSid {
    param([AllowEmptyString()][string]$Identity)

    if ([string]::IsNullOrWhiteSpace($Identity)) {
        return $null
    }

    try {
        return ([System.Security.Principal.SecurityIdentifier]::new($Identity)).Value
    }
    catch {
        try {
            $account = [System.Security.Principal.NTAccount]::new($Identity)
            return $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
        }
        catch {
            return $null
        }
    }
}

function Test-AccountSid {
    param(
        [AllowEmptyString()][string]$Identity,
        [Parameter(Mandatory)][string]$ExpectedSid
    )

    $resolvedSid = Resolve-AccountSid -Identity $Identity
    return $null -ne $resolvedSid -and $resolvedSid -ieq $ExpectedSid
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
        [Parameter(Mandatory)][string]$Marker,
        [switch]$Diagnostic
    )

    $principalUser = [string]$Task.Principal.UserId
    $ownedByCurrentUser = Test-AccountSid -Identity $principalUser -ExpectedSid $CurrentUserSid
    if (-not $ownedByCurrentUser -and -not [string]::IsNullOrWhiteSpace($CurrentUserName)) {
        $currentUserNameWithoutDomain = $CurrentUserName
        if ($CurrentUserName.Contains('\')) {
            $currentUserNameWithoutDomain = $CurrentUserName.Split('\')[-1]
        }
        # fallback: compare principal directly to current user name (case-insensitive)
        $ownedByCurrentUser = $principalUser -ieq $CurrentUserName -or
            $principalUser -ieq $currentUserNameWithoutDomain
    }

    $markerMatches = ([string]$Task.Description).Contains($Marker)
    if ($markerMatches) {
        # If the task has the project marker, consider it associated regardless of owner
        if ($Diagnostic) {
            Write-Host "[Diagnostic] Task '$($task.TaskPath)$($task.TaskName)' matches marker" -ForegroundColor Green
        }
        return $true
    }

    if (-not $ownedByCurrentUser) {
        if ($Diagnostic) {
            Write-Host "[Diagnostic] Task '$($task.TaskPath)$($task.TaskName)' not owned by current user (principal: '$principalUser', current: '$CurrentUserName')" -ForegroundColor Red
        }
        return $false
    }

    $pathMatches = $TaskPaths -contains [string]$Task.TaskPath
    $nameMatches = $TaskNames -contains [string]$Task.TaskName
    
    if ($Diagnostic) {
        Write-Host "[Diagnostic] Task '$($task.TaskPath)$($task.TaskName)'" -ForegroundColor Cyan
        Write-Host "  Principal.UserId: '$principalUser'" -ForegroundColor Gray
        Write-Host "  Owned by current user: $ownedByCurrentUser" -ForegroundColor $(if ($ownedByCurrentUser) { 'Green' } else { 'Red' })
        Write-Host "  Path matches: $pathMatches (task path: '$($task.TaskPath)', allowed paths: $($TaskPaths -join ', '))" -ForegroundColor $(if ($pathMatches) { 'Green' } else { 'Red' })
        Write-Host "  Name matches: $nameMatches (task name: '$($task.TaskName)', allowed names: $($TaskNames -join ', '))" -ForegroundColor $(if ($nameMatches) { 'Green' } else { 'Red' })
        Write-Host "  Marker matches: $markerMatches (description: '$($task.Description)')" -ForegroundColor $(if ($markerMatches) { 'Green' } else { 'Red' })
    }
    
    if ($pathMatches -and $nameMatches) {
        if ($Diagnostic) {
            Write-Host "  => MATCH! Task associated with project (path and name match)" -ForegroundColor Green
        }
        return $true
    }

    $actionMatches = $false
    foreach ($taskAction in @($Task.Actions)) {
        $executeProperty = $taskAction.PSObject.Properties['Execute']
        $argumentsProperty = $taskAction.PSObject.Properties['Arguments']
        if ($null -eq $executeProperty -or $null -eq $argumentsProperty) {
            continue
        }
        if ([string]$executeProperty.Value -ine $PowerShellExe) {
            continue
        }
        foreach ($expectedArgument in $ExpectedArguments) {
            if ([string]$argumentsProperty.Value -eq $expectedArgument) {
                $actionMatches = $true
                if ($Diagnostic) {
                    Write-Host "  Action matches: true (arguments: '$($argumentsProperty.Value)')" -ForegroundColor Green
                }
                return $true
            }
        }
    }
    
    if ($Diagnostic) {
        Write-Host "  Action matches: $actionMatches" -ForegroundColor $(if ($actionMatches) { 'Green' } else { 'Red' })
        if (-not $actionMatches -and @($Task.Actions).Count -gt 0) {
            Write-Host "  Task action details:" -ForegroundColor Gray
            foreach ($taskAction in @($Task.Actions)) {
                $executeProperty = $taskAction.PSObject.Properties['Execute']
                $argumentsProperty = $taskAction.PSObject.Properties['Arguments']
                $executeValue = if ($executeProperty) { $executeProperty.Value } else { $null }
                $argumentsValue = if ($argumentsProperty) { $argumentsProperty.Value } else { $null }
                Write-Host "    Execute: $executeValue, Arguments: $argumentsValue" -ForegroundColor Gray
            }
        }
        Write-Host "  => NOT associated with project" -ForegroundColor DarkGray
    }

    return $false
}

try {
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path $PSScriptRoot 'BackupConfig.json'
    }
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

    if ([string]::IsNullOrWhiteSpace($userSid)) {
        throw 'Cannot determine current user SID. The Windows identity may be invalid or not fully resolved.'
    }
    try {
        $null = [System.Security.Principal.SecurityIdentifier]::new($userSid)
    }
    catch {
        throw "Current user SID is not valid: '$userSid'. $_"
    }

    if ([string]::IsNullOrWhiteSpace($userName)) {
        throw 'Cannot determine current user name.'
    }

    $associatedTasks = New-Object System.Collections.ArrayList
    $allTasks = @(Get-ScheduledTask -ErrorAction Stop)
    if ($Diagnostic) {
        Write-Host "[Diagnostic] Total tasks found: $($allTasks.Count)" -ForegroundColor Yellow
        Write-Host "[Diagnostic] Looking for tasks with:" -ForegroundColor Yellow
        Write-Host "[Diagnostic]   Names: $($taskNames -join ', ')" -ForegroundColor Yellow
        Write-Host "[Diagnostic]   Paths: $($taskPaths -join ', ')" -ForegroundColor Yellow
        Write-Host "[Diagnostic]   Current user: '$userName' (SID: $userSid)" -ForegroundColor Yellow
        Write-Host "[Diagnostic]   Marker: '$managedMarker'" -ForegroundColor Yellow
    }
    foreach ($task in $allTasks) {
        if (Test-TaskAssociatedWithProject `
            -Task $task `
            -TaskNames @($taskNames) `
            -TaskPaths @($taskPaths) `
            -ExpectedArguments @($expectedArguments) `
            -PowerShellExe $powerShellExe `
            -CurrentUserSid $userSid `
            -CurrentUserName $userName `
            -Marker $managedMarker `
            -Diagnostic:$Diagnostic) {
            [void]$associatedTasks.Add($task)
        }
    }
    
    if ($Diagnostic) {
        Write-Host "[Diagnostic] Total associated tasks found: $($associatedTasks.Count)" -ForegroundColor $(if ($associatedTasks.Count -gt 0) { 'Green' } else { 'Red' })
        foreach ($match in $associatedTasks) {
            Write-Host "  - '$($match.TaskPath)$($match.TaskName)'" -ForegroundColor Green
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
