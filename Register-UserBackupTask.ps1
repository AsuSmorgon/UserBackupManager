[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'BackupConfig.json')
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
        [System.IO.Path]::GetFileName($Value) -ne $Value -or
        $Value.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw "$SettingName must contain a valid file name without a directory path."
    }
}

function Get-ManagedTaskNames {
    param([Parameter(Mandatory)]$Config)

    $names = New-Object System.Collections.ArrayList
    foreach ($configuredName in @($Config.Task.ManagedNames) + @([string]$Config.Task.Name)) {
        $name = [string]$configuredName
        Assert-SimpleFileName -Value $name -SettingName 'Task.ManagedNames/Task.Name'
        if (-not (@($names) -contains $name)) {
            [void]$names.Add($name)
        }
    }

    if ($names.Count -eq 0) {
        throw 'Task.ManagedNames must contain at least one task name.'
    }
    return @($names)
}

function Get-ManagedBackupTasks {
    param(
        [Parameter(Mandatory)][string[]]$ManagedNames,
        [Parameter(Mandatory)][string]$TaskPath,
        [Parameter(Mandatory)][string]$LauncherPath,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$PowerShellExe,
        [Parameter(Mandatory)][string]$CurrentUserSid,
        [Parameter(Mandatory)][string]$CurrentUserName,
        [Parameter(Mandatory)][string]$Marker
    )

    $expectedArguments = @(
        '-NoLogo'
        '-NoProfile'
        '-NonInteractive'
        '-WindowStyle Hidden'
        '-ExecutionPolicy Bypass'
        '-File "' + $LauncherPath + '"'
        '-ConfigPath "' + $ConfigPath + '"'
    ) -join ' '

    $result = New-Object System.Collections.ArrayList
    foreach ($task in @(Get-ScheduledTask -ErrorAction Stop)) {
        $principalUser = [string]$task.Principal.UserId
        $ownedByCurrentUser = $principalUser -ieq $CurrentUserSid -or $principalUser -ieq $CurrentUserName
        $pathMatches = $task.TaskPath -ieq $TaskPath
        $nameMatches = $ManagedNames -contains $task.TaskName
        $markerMatches = ([string]$task.Description).Contains($Marker)
        $actionMatches = $false

        foreach ($taskAction in @($task.Actions)) {
            if ([string]$taskAction.Execute -ieq $PowerShellExe -and
                [string]$taskAction.Arguments -eq $expectedArguments) {
                $actionMatches = $true
                break
            }
        }

        if ($ownedByCurrentUser -and $pathMatches -and
            ($nameMatches -or $markerMatches -or $actionMatches)) {
            [void]$result.Add($task)
        }
    }
    return @($result)
}

function Remove-TaskInstances {
    param([Parameter(Mandatory)][object[]]$Tasks)

    foreach ($task in $Tasks) {
        Unregister-ScheduledTask `
            -TaskName $task.TaskName `
            -TaskPath $task.TaskPath `
            -Confirm:$false `
            -ErrorAction Stop
    }
}

$config = $null
$cleanupStarted = $false
$taskSnapshots = New-Object System.Collections.ArrayList
$taskRollbackDirectory = $null

try {
    $ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
    $localDirectory = Split-Path -Parent $ConfigPath
    $config = Read-BackupConfig -Path $ConfigPath

    $taskName = [string]$config.Task.Name
    $taskPath = [string]$config.Task.Path
    [int]$delayMinutes = $config.Task.DelayMinutes
    $dailyRunTime = [string]$config.Task.DailyRunTime
    [int]$executionTimeLimitHours = $config.Task.ExecutionTimeLimitHours
    $managedNames = @(Get-ManagedTaskNames -Config $config)

    if ($taskPath -ne '\') {
        throw 'Task.Path must be the root task path: \.'
    }
    if ($delayMinutes -lt 1 -or $delayMinutes -gt 1440) {
        throw 'Task.DelayMinutes must be between 1 and 1440.'
    }
    if ($dailyRunTime -notmatch '^(?:[01]\d|2[0-3]):[0-5]\d$') {
        throw 'Task.DailyRunTime must use the 24-hour HH:mm format.'
    }
    if ($executionTimeLimitHours -lt 1) {
        throw 'Task.ExecutionTimeLimitHours must be greater than zero.'
    }

    $launcherFileName = [string]$config.Update.LauncherFileName
    Assert-SimpleFileName -Value $launcherFileName -SettingName 'Update.LauncherFileName'
    $launcherPath = Join-Path $localDirectory $launcherFileName
    if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
        throw "Launcher script was not found: '$launcherPath'."
    }

    $powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) {
        throw "Windows PowerShell was not found: '$powerShellExe'."
    }
    foreach ($pathValue in @($launcherPath, $ConfigPath)) {
        if ($pathValue.Contains('"')) {
            throw 'Launcher and configuration paths must not contain double quotes.'
        }
    }

    Import-Module ScheduledTasks -ErrorAction Stop
    $userIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $userSid = $userIdentity.User.Value
    $userName = $userIdentity.Name

    $taskArguments = @(
        '-NoLogo'
        '-NoProfile'
        '-NonInteractive'
        '-WindowStyle Hidden'
        '-ExecutionPolicy Bypass'
        '-File "' + $launcherPath + '"'
        '-ConfigPath "' + $ConfigPath + '"'
    ) -join ' '

    $action = New-ScheduledTaskAction `
        -Execute $powerShellExe `
        -Argument $taskArguments `
        -WorkingDirectory $localDirectory

    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $userSid
    $logonTrigger.Delay = 'PT' + $delayMinutes + 'M'

    $dailyTimeParts = $dailyRunTime.Split(':')
    $dailyTriggerStart = [DateTime]::Today.AddHours([int]$dailyTimeParts[0]).AddMinutes([int]$dailyTimeParts[1])
    $dailyTrigger = New-ScheduledTaskTrigger -Daily -At $dailyTriggerStart
    $taskTriggers = @($logonTrigger, $dailyTrigger)

    $principal = New-ScheduledTaskPrincipal `
        -UserId $userSid `
        -LogonType Interactive `
        -RunLevel Limited

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours $executionTimeLimitHours)

    $description = "$managedMarker Update and run user backup for $userName $delayMinutes minutes after logon and daily at $dailyRunTime."

    $existingTarget = @(Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue)
    foreach ($targetTask in $existingTarget) {
        $targetPrincipal = [string]$targetTask.Principal.UserId
        $ownedByCurrentUser = $targetPrincipal -ieq $userSid -or $targetPrincipal -ieq $userName
        if (-not $ownedByCurrentUser) {
            throw "Task '$taskPath$taskName' exists but is not owned by the current user backup installation."
        }
    }

    $existingManagedTasks = @(Get-ManagedBackupTasks `
        -ManagedNames $managedNames `
        -TaskPath $taskPath `
        -LauncherPath $launcherPath `
        -ConfigPath $ConfigPath `
        -PowerShellExe $powerShellExe `
        -CurrentUserSid $userSid `
        -CurrentUserName $userName `
        -Marker $managedMarker)

    if ($existingManagedTasks.Count -gt 0) {
        $taskRollbackDirectory = Join-Path $localDirectory ('.task-rollback-' + [Guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $taskRollbackDirectory -Force)
    }

    $snapshotIndex = 0
    foreach ($existingTask in $existingManagedTasks) {
        $taskXml = Export-ScheduledTask `
            -TaskName $existingTask.TaskName `
            -TaskPath $existingTask.TaskPath `
            -ErrorAction Stop
        $snapshotFileName = '{0:D3}.xml' -f $snapshotIndex
        $snapshotPath = Join-Path $taskRollbackDirectory $snapshotFileName
        [System.IO.File]::WriteAllText($snapshotPath, $taskXml, [System.Text.Encoding]::Unicode)
        [void]$taskSnapshots.Add([pscustomobject]@{
            TaskName = $existingTask.TaskName
            TaskPath = $existingTask.TaskPath
            Xml      = $taskXml
            XmlPath  = $snapshotPath
        })
        $snapshotIndex++
    }

    if ($taskSnapshots.Count -gt 0) {
        $manifest = @($taskSnapshots | Select-Object TaskName, TaskPath, XmlPath) | ConvertTo-Json -Depth 3
        [System.IO.File]::WriteAllText(
            (Join-Path $taskRollbackDirectory 'manifest.json'),
            $manifest,
            (New-Object System.Text.UTF8Encoding($false))
        )
    }

    $cleanupStarted = $true
    Remove-TaskInstances -Tasks $existingManagedTasks

    Register-ScheduledTask `
        -TaskName $taskName `
        -TaskPath $taskPath `
        -Action $action `
        -Trigger $taskTriggers `
        -Principal $principal `
        -Settings $settings `
        -Description $description `
        -Force `
        -ErrorAction Stop | Out-Null

    $remainingManagedTasks = @(Get-ManagedBackupTasks `
        -ManagedNames $managedNames `
        -TaskPath $taskPath `
        -LauncherPath $launcherPath `
        -ConfigPath $ConfigPath `
        -PowerShellExe $powerShellExe `
        -CurrentUserSid $userSid `
        -CurrentUserName $userName `
        -Marker $managedMarker)
    if ($remainingManagedTasks.Count -ne 1 -or
        $remainingManagedTasks[0].TaskName -ine $taskName -or
        $remainingManagedTasks[0].TaskPath -ine $taskPath) {
        throw 'Managed task cleanup validation failed: exactly one current task was expected.'
    }

    $registeredTask = $remainingManagedTasks[0]
    $registeredActions = @($registeredTask.Actions)
    $registeredLogonTriggers = @($registeredTask.Triggers | Where-Object {
        $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger'
    })
    $registeredDailyTriggers = @($registeredTask.Triggers | Where-Object {
        $_.CimClass.CimClassName -eq 'MSFT_TaskDailyTrigger'
    })

    if ($registeredActions.Count -ne 1 -or
        $registeredActions[0].Execute -ine $powerShellExe -or
        $registeredActions[0].Arguments -ne $taskArguments -or
        $registeredActions[0].WorkingDirectory -ine $localDirectory) {
        throw 'The registered task action did not pass validation.'
    }
    if ([string]$registeredTask.Principal.UserId -ine $userSid -and
        [string]$registeredTask.Principal.UserId -ine $userName) {
        throw 'The registered task principal did not pass validation.'
    }
    if ($registeredLogonTriggers.Count -ne 1 -or
        $registeredLogonTriggers[0].Delay -ne ('PT' + $delayMinutes + 'M')) {
        throw 'The registered logon trigger did not pass validation.'
    }
    if ($registeredDailyTriggers.Count -ne 1) {
        throw 'The registered task does not contain exactly one daily trigger.'
    }
    $registeredDailyStart = [DateTime]$registeredDailyTriggers[0].StartBoundary
    if ($registeredDailyStart.ToString('HH:mm') -ne $dailyRunTime -or
        [int]$registeredDailyTriggers[0].DaysInterval -ne 1) {
        throw 'The registered daily trigger did not pass validation.'
    }
    if ([string]$registeredTask.Settings.MultipleInstances -ne 'IgnoreNew' -or
        -not [bool]$registeredTask.Settings.StartWhenAvailable) {
        throw 'The registered task settings did not pass validation.'
    }

    if (-not [string]::IsNullOrWhiteSpace($taskRollbackDirectory) -and
        (Test-Path -LiteralPath $taskRollbackDirectory -PathType Container)) {
        Remove-Item -LiteralPath $taskRollbackDirectory -Recurse -Force
    }

    Write-Host "Scheduled task registered: $taskPath$taskName" -ForegroundColor Green
    Write-Host "Removed managed task copies: $($existingManagedTasks.Count)"
    Write-Host "Logon delay: $delayMinutes minute(s)"
    Write-Host "Daily launcher start: $dailyRunTime"
    exit 0
}
catch {
    $originalError = $_
    $restoreErrors = New-Object System.Collections.ArrayList

    if ($cleanupStarted) {
        try {
            if ($null -ne $config) {
                $rollbackNames = @(Get-ManagedTaskNames -Config $config)
                $rollbackLauncher = Join-Path (Split-Path -Parent $ConfigPath) ([string]$config.Update.LauncherFileName)
                $rollbackPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $rollbackIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
                $tasksToRemove = @(Get-ManagedBackupTasks `
                    -ManagedNames $rollbackNames `
                    -TaskPath ([string]$config.Task.Path) `
                    -LauncherPath $rollbackLauncher `
                    -ConfigPath $ConfigPath `
                    -PowerShellExe $rollbackPowerShell `
                    -CurrentUserSid $rollbackIdentity.User.Value `
                    -CurrentUserName $rollbackIdentity.Name `
                    -Marker $managedMarker)
                Remove-TaskInstances -Tasks $tasksToRemove
            }
        }
        catch {
            [void]$restoreErrors.Add("Failed to remove partial managed tasks: $($_.Exception.Message)")
        }

        foreach ($snapshot in @($taskSnapshots)) {
            try {
                Register-ScheduledTask `
                    -TaskName $snapshot.TaskName `
                    -TaskPath $snapshot.TaskPath `
                    -Xml $snapshot.Xml `
                    -Force `
                    -ErrorAction Stop | Out-Null
            }
            catch {
                [void]$restoreErrors.Add("Failed to restore '$($snapshot.TaskPath)$($snapshot.TaskName)': $($_.Exception.Message)")
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($taskRollbackDirectory) -and
        (Test-Path -LiteralPath $taskRollbackDirectory -PathType Container) -and
        ($restoreErrors.Count -eq 0 -or -not $cleanupStarted)) {
        Remove-Item -LiteralPath $taskRollbackDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($restoreErrors.Count -gt 0) {
        Write-Error ("Task registration failed: {0}. Rollback errors: {1}. Task XML snapshots were preserved in '{2}'." -f
            $originalError.Exception.Message,
            (@($restoreErrors) -join ' | '),
            $taskRollbackDirectory)
    }
    else {
        Write-Error ("Task registration failed: {0}" -f $originalError.Exception.Message)
    }
    exit 1
}
