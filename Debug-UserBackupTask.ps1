param(
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$managedMarker = '[ASUP.UserBackup.Managed]'

Write-Host "=== User Backup Task Diagnostic Tool ===" -ForegroundColor Cyan
Write-Host "Run on: $(Get-Date)" -ForegroundColor Cyan
Write-Host "Computer: $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host "User: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" -ForegroundColor Cyan
Write-Host "Windows Version: $( (Get-CimInstance Win32_OperatingSystem).Caption )" -ForegroundColor Cyan
Write-Host "`n"

$configPath = Join-Path $PSScriptRoot 'BackupConfig.json'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    Write-Error "Configuration file not found: '$configPath'"
    exit 1
}

$utf8 = New-Object System.Text.UTF8Encoding($false, $true)
$json = [System.IO.File]::ReadAllText($configPath, $utf8)
$config = $json | ConvertFrom-Json -ErrorAction Stop

$taskName = [string]$config.Task.Name
$taskPath = [string]$config.Task.Path
$managedNames = @($config.Task.ManagedNames) + @($taskName)
$launcherFileName = [string]$config.Update.LauncherFileName
$launcherPath = Join-Path $PSScriptRoot $launcherFileName

Write-Host "Configuration loaded:" -ForegroundColor Yellow
Write-Host "  Task Name: '$taskName'" -ForegroundColor Yellow
Write-Host "  Task Path: '$taskPath'" -ForegroundColor Yellow
Write-Host "  Managed Names: $($managedNames -join ', ')" -ForegroundColor Yellow
Write-Host "  Launcher Path: '$launcherPath'" -ForegroundColor Yellow
Write-Host "  Marker: '$managedMarker'" -ForegroundColor Yellow
Write-Host "`n"

# Check if task folder exists
Write-Host "=== Checking Task Scheduler Folder ===" -ForegroundColor Cyan
try {
    $schTasks = New-Object -ComObject Schedule.Service
    $schTasks.Connect()
    $rootFolder = $schTasks.GetFolder('\')
    
    # Try to navigate to the task path
    $folderPath = $taskPath.TrimEnd('\')
    if ($folderPath -eq '\') {
        $targetFolder = $rootFolder
    } else {
        $folderParts = $folderPath.Split('\', [System.StringSplitOptions]::RemoveEmptyEntries)
        $currentFolder = $rootFolder
        foreach ($part in $folderParts) {
            try {
                $currentFolder = $currentFolder.GetFolder($part)
                Write-Host "  Folder '$part' exists" -ForegroundColor Green
            } catch {
                Write-Host "  Folder '$part' does not exist" -ForegroundColor Red
                break
            }
        }
    }
} catch {
    Write-Host "  Error checking folder: $_" -ForegroundColor Red
}

Write-Host "`n=== Checking All Scheduled Tasks ===" -ForegroundColor Cyan
Import-Module ScheduledTasks -ErrorAction Stop

$allTasks = @(Get-ScheduledTask -ErrorAction Stop)
Write-Host "Total tasks found: $($allTasks.Count)" -ForegroundColor Yellow

$userIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$userSid = $userIdentity.User.Value
$userName = $userIdentity.Name
$userNameWithoutDomain = $userName
if ($userName.Contains('\')) {
    $userNameWithoutDomain = $userName.Split('\')[-1]
}

Write-Host "Current user: '$userName' (SID: $userSid, without domain: '$userNameWithoutDomain')" -ForegroundColor Yellow

$powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$expectedArguments = @(
    '-NoLogo'
    '-NoProfile'
    '-NonInteractive'
    '-WindowStyle Hidden'
    '-ExecutionPolicy Bypass'
    '-File "' + $launcherPath + '"'
    '-ConfigPath "' + $configPath + '"'
) -join ' '

Write-Host "`n=== Searching for Managed Tasks ===" -ForegroundColor Cyan
$managedTasks = @()
$candidateTasks = @()

foreach ($task in $allTasks) {
    $taskFullName = "$($task.TaskPath)$($task.TaskName)"
    $principalUser = [string]$task.Principal.UserId
    
    Write-Host "`nTask: '$taskFullName'" -ForegroundColor Cyan
    Write-Host "  State: $($task.State)" -ForegroundColor Gray
    Write-Host "  Principal.UserId: '$principalUser'" -ForegroundColor Gray
    Write-Host "  Description: '$($task.Description)'" -ForegroundColor Gray
    
    # Check ownership
    $ownedByCurrentUser = $false
    try {
        $principalSid = ([System.Security.Principal.SecurityIdentifier]::new($principalUser)).Value
        $ownedByCurrentUser = ($principalSid -eq $userSid)
    } catch {
        # Not a SID, try name comparison
        $ownedByCurrentUser = ($principalUser -ieq $userName -or $principalUser -ieq $userNameWithoutDomain)
    }
    Write-Host "  Owned by current user: $ownedByCurrentUser" -ForegroundColor $(if ($ownedByCurrentUser) { 'Green' } else { 'Red' })
    
    # Check path
    $pathMatches = ($task.TaskPath -ieq $taskPath)
    Write-Host "  Path matches: $pathMatches (actual: '$($task.TaskPath)', expected: '$taskPath')" -ForegroundColor $(if ($pathMatches) { 'Green' } else { 'Red' })
    
    # Check name
    $nameMatches = ($managedNames -contains $task.TaskName)
    Write-Host "  Name matches: $nameMatches (actual: '$($task.TaskName)')" -ForegroundColor $(if ($nameMatches) { 'Green' } else { 'Red' })
    
    # Check marker
    $markerMatches = ([string]$task.Description).Contains($managedMarker)
    Write-Host "  Marker matches: $markerMatches" -ForegroundColor $(if ($markerMatches) { 'Green' } else { 'Red' })
    
    # Check actions
    $actionMatches = $false
    foreach ($taskAction in @($task.Actions)) {
        $executeProperty = $taskAction.PSObject.Properties['Execute']
        $argumentsProperty = $taskAction.PSObject.Properties['Arguments']
        if ($null -ne $executeProperty -and $null -ne $argumentsProperty) {
            $executeMatches = ([string]$executeProperty.Value -ieq $powerShellExe)
            $argumentsMatches = ([string]$argumentsProperty.Value -eq $expectedArguments)
            if ($executeMatches -and $argumentsMatches) {
                $actionMatches = $true
                Write-Host "  Action matches: true" -ForegroundColor Green
                Write-Host "    Execute: $($executeProperty.Value)" -ForegroundColor Gray
                Write-Host "    Arguments: $($argumentsProperty.Value)" -ForegroundColor Gray
                break
            }
        }
    }
    if (-not $actionMatches) {
        Write-Host "  Action matches: false" -ForegroundColor Red
    }
    
    # Determine if this is a managed task
    $isManaged = $false
    if ($ownedByCurrentUser -and $pathMatches -and ($nameMatches -or $markerMatches -or $actionMatches)) {
        $isManaged = $true
        Write-Host "  => MANAGED TASK DETECTED" -ForegroundColor Green -BackgroundColor DarkGreen
        $managedTasks += $task
    } elseif ($pathMatches -or $nameMatches -or $markerMatches -or $actionMatches) {
        $candidateTasks += $task
        Write-Host "  => CANDIDATE TASK (some criteria match but not all)" -ForegroundColor Yellow
    } else {
        Write-Host "  => NOT a managed task" -ForegroundColor DarkGray
    }
}

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Managed tasks found: $($managedTasks.Count)" -ForegroundColor $(if ($managedTasks.Count -gt 0) { 'Green' } else { 'Red' })
foreach ($task in $managedTasks) {
    Write-Host "  - '$($task.TaskPath)$($task.TaskName)'" -ForegroundColor Green
}

Write-Host "`nCandidate tasks (some criteria match): $($candidateTasks.Count)" -ForegroundColor Yellow
foreach ($task in $candidateTasks) {
    Write-Host "  - '$($task.TaskPath)$($task.TaskName)'" -ForegroundColor Yellow
}

Write-Host "`n=== Recommendations ===" -ForegroundColor Cyan
if ($managedTasks.Count -eq 0 -and $candidateTasks.Count -gt 0) {
    Write-Host "No managed tasks found, but there are candidate tasks that partially match." -ForegroundColor Yellow
    Write-Host "Most likely issue: Task ownership check is failing." -ForegroundColor Yellow
    Write-Host "Try running: .\Register-UserBackupTask.ps1 -Diagnostic" -ForegroundColor Yellow
} elseif ($managedTasks.Count -eq 0) {
    Write-Host "No managed tasks found at all." -ForegroundColor Red
    Write-Host "Either the task wasn't created, or it's in a different path/name." -ForegroundColor Red
    Write-Host "Try running: .\Install-UserBackup.cmd" -ForegroundColor Yellow
} elseif ($managedTasks.Count -eq 1) {
    Write-Host "Perfect! Exactly one managed task found." -ForegroundColor Green
    if ($Uninstall) {
        Write-Host "To uninstall: .\Uninstall-UserBackup.cmd" -ForegroundColor Yellow
    }
} else {
    Write-Host "Multiple managed tasks found. This might cause validation errors." -ForegroundColor Red
    Write-Host "Try cleaning up with: .\Uninstall-UserBackup.cmd" -ForegroundColor Yellow
}

Write-Host "`n=== Quick Commands ===" -ForegroundColor Cyan
Write-Host "1. Install with diagnostics: .\Register-UserBackupTask.ps1 -ConfigPath .\BackupConfig.json -Diagnostic" -ForegroundColor Gray
Write-Host "2. Uninstall with diagnostics: .\Uninstall-UserBackup.ps1 -Diagnostic" -ForegroundColor Gray
Write-Host "3. Check task in scheduler: schtasks /query /tn '$taskPath$taskName' /v" -ForegroundColor Gray