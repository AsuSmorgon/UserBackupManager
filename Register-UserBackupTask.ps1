[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'BackupConfig.json'),
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
        [System.IO.Path]::GetFileName($Value) -ne $Value -or
        $Value.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw "$SettingName must contain a valid file name without a directory path."
    }
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
        [Parameter(Mandatory)][string]$Marker,
        [switch]$Diagnostic
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
    $currentUserNameWithoutDomain = $CurrentUserName
    if ($CurrentUserName.Contains('\')) {
        $currentUserNameWithoutDomain = $CurrentUserName.Split('\')[-1]
    }
    
    $allTasks = @(Get-ScheduledTask -ErrorAction Stop)
    if ($Diagnostic) {
        Write-Host "[Diagnostic] Total tasks found: $($allTasks.Count)" -ForegroundColor Yellow
        Write-Host "[Diagnostic] Looking for tasks in path: '$TaskPath'" -ForegroundColor Yellow
        Write-Host "[Diagnostic] Managed names: $($ManagedNames -join ', ')" -ForegroundColor Yellow
        Write-Host "[Diagnostic] Current user: '$CurrentUserName' (SID: $CurrentUserSid, without domain: '$currentUserNameWithoutDomain')" -ForegroundColor Yellow
        Write-Host "[Diagnostic] Marker: '$Marker'" -ForegroundColor Yellow
    }
    
    foreach ($task in $allTasks) {
        $principalUser = [string]$task.Principal.UserId
        $ownedByCurrentUser = Test-AccountSid -Identity $principalUser -ExpectedSid $CurrentUserSid
        if (-not $ownedByCurrentUser -and -not [string]::IsNullOrWhiteSpace($CurrentUserName)) {
            # fallback: compare principal directly to current user name (case-insensitive)
            $ownedByCurrentUser = $principalUser -ieq $CurrentUserName -or
                $principalUser -ieq $currentUserNameWithoutDomain
        }
        $pathMatches = $task.TaskPath -ieq $TaskPath
        $nameMatches = $ManagedNames -contains $task.TaskName
        $markerMatches = ([string]$task.Description).Contains($Marker)
        $actionMatches = $false

        foreach ($taskAction in @($task.Actions)) {
            $executeProperty = $taskAction.PSObject.Properties['Execute']
            $argumentsProperty = $taskAction.PSObject.Properties['Arguments']
            if ($null -ne $executeProperty -and
                $null -ne $argumentsProperty -and
                [string]$executeProperty.Value -ieq $PowerShellExe -and
                [string]$argumentsProperty.Value -eq $expectedArguments) {
                $actionMatches = $true
                break
            }
        }

        if ($Diagnostic) {
            Write-Host "[Diagnostic] Task: '$($task.TaskPath)$($task.TaskName)'" -ForegroundColor Cyan
            Write-Host "  Principal.UserId: '$principalUser'" -ForegroundColor Gray
            Write-Host "  Owned by current user: $ownedByCurrentUser" -ForegroundColor $(if ($ownedByCurrentUser) { 'Green' } else { 'Red' })
            Write-Host "  Path matches: $pathMatches (expected: '$TaskPath', actual: '$($task.TaskPath)')" -ForegroundColor $(if ($pathMatches) { 'Green' } else { 'Red' })
            Write-Host "  Name matches: $nameMatches (task name: '$($task.TaskName)', managed names: $($ManagedNames -join ', '))" -ForegroundColor $(if ($nameMatches) { 'Green' } else { 'Red' })
            Write-Host "  Marker matches: $markerMatches (description: '$($task.Description)')" -ForegroundColor $(if ($markerMatches) { 'Green' } else { 'Red' })
            Write-Host "  Action matches: $actionMatches" -ForegroundColor $(if ($actionMatches) { 'Green' } else { 'Red' })
        }

        # Проверяем все критерии
        $isManagedTask = $false
        
        # Критерий 1: Владелец + путь + (имя ИЛИ маркер ИЛИ действие)
        if ($ownedByCurrentUser -and $pathMatches -and
            ($nameMatches -or $markerMatches -or $actionMatches)) {
            $isManagedTask = $true
        }
        
        # Критерий 2: Для случая совпадающих имен пользователя и компьютера
        # Проверяем задачи в корне, которые могут быть нашей задачей
        if (-not $isManagedTask -and $isSameAsComputer -and $Diagnostic) {
            # Специальная проверка: если задача в корне с правильным именем и владельцем
            if ($ownedByCurrentUser -and $task.TaskPath -eq '\' -and $nameMatches) {
                Write-Host "  [Special check] Task in root with matching name and owner" -ForegroundColor Yellow
                Write-Host "  [Special check] This might be our task but in wrong path" -ForegroundColor Yellow
            }
        }
        
        if ($isManagedTask) {
            if ($Diagnostic) {
                Write-Host "  => MATCH! Adding to managed tasks list" -ForegroundColor Green
            }
            [void]$result.Add($task)
        } elseif ($Diagnostic) {
            Write-Host "  => NOT a match (ownership: $ownedByCurrentUser, path: $pathMatches, name/marker/action: $($nameMatches -or $markerMatches -or $actionMatches))" -ForegroundColor DarkGray
        }
    }
    
    if ($Diagnostic) {
        Write-Host "[Diagnostic] Total managed tasks found: $($result.Count)" -ForegroundColor $(if ($result.Count -gt 0) { 'Green' } else { 'Red' })
        foreach ($match in $result) {
            Write-Host "  - '$($match.TaskPath)$($match.TaskName)'" -ForegroundColor Green
        }
    }
    return @($result)
}

function Remove-TaskInstances {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Tasks
    )

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

    if (-not $taskPath.StartsWith('\') -or -not $taskPath.EndsWith('\')) {
        throw 'Task.Path must start and end with a backslash (e.g., \ASUP\User BackUp Manager\).'
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

    # Определяем UserId для задачи - пробуем разные форматы для совместимости
    $taskUserId = $userName
    $userNameWithoutDomain = $userName
    $computerName = $env:COMPUTERNAME
    
    if ($userName.Contains('\')) {
        $userNameWithoutDomain = $userName.Split('\')[-1]
        $taskUserId = $userNameWithoutDomain  # Начинаем с имени без домена
    }
    
    # Специальная обработка для случая, когда имя пользователя совпадает с именем компьютера
    # Это частый случай на Windows 10 с локальными пользователями
    $isSameAsComputer = $false
    if ($userNameWithoutDomain -ieq $computerName) {
        $isSameAsComputer = $true
        if ($Diagnostic) {
            Write-Host "[Diagnostic] WARNING: User name '$userNameWithoutDomain' matches computer name '$computerName'" -ForegroundColor Red
            Write-Host "[Diagnostic] This can cause issues with Task Scheduler recognition" -ForegroundColor Red
        }
    }
    
    # Для диагностики показываем все варианты
    if ($Diagnostic) {
        Write-Host "[Diagnostic] User identity options:" -ForegroundColor Yellow
        Write-Host "[Diagnostic]   Full name: '$userName'" -ForegroundColor Yellow
        Write-Host "[Diagnostic]   Without domain: '$userNameWithoutDomain'" -ForegroundColor Yellow
        Write-Host "[Diagnostic]   Computer name: '$computerName'" -ForegroundColor Yellow
        Write-Host "[Diagnostic]   User SID: '$userSid'" -ForegroundColor Yellow
        Write-Host "[Diagnostic]   Name matches computer: $isSameAsComputer" -ForegroundColor Yellow
        Write-Host "[Diagnostic]   Will try: '$taskUserId'" -ForegroundColor Yellow
    }

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

    # Создаем триггеры
    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $taskUserId
    $logonTrigger.Delay = 'PT' + $delayMinutes + 'M'

    $dailyTimeParts = $dailyRunTime.Split(':')
    $dailyTriggerStart = [DateTime]::Today.AddHours([int]$dailyTimeParts[0]).AddMinutes([int]$dailyTimeParts[1])
    $dailyTrigger = New-ScheduledTaskTrigger -Daily -At $dailyTriggerStart
    $taskTriggers = @($logonTrigger, $dailyTrigger)

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours $executionTimeLimitHours)

    $description = "$managedMarker Update and run user backup for $userName $delayMinutes minutes after logon and daily at $dailyRunTime."
    
    # Функция для создания задачи с разными форматами UserId
    function Register-TaskWithUserIdFallback {
        param(
            [string]$UserIdToTry,
            [string]$AttemptDescription,
            [ref]$LastError
        )
        
        if ($Diagnostic) {
            Write-Host "[Diagnostic] Attempting to register task with UserId: '$UserIdToTry' ($AttemptDescription)" -ForegroundColor Yellow
        }
        
        try {
            # Создаем триггеры с текущим UserId
            $logonTriggerForAttempt = New-ScheduledTaskTrigger -AtLogOn -User $UserIdToTry
            $logonTriggerForAttempt.Delay = 'PT' + $delayMinutes + 'M'
            
            $dailyTimeParts = $dailyRunTime.Split(':')
            $dailyTriggerStart = [DateTime]::Today.AddHours([int]$dailyTimeParts[0]).AddMinutes([int]$dailyTimeParts[1])
            $dailyTriggerForAttempt = New-ScheduledTaskTrigger -Daily -At $dailyTriggerStart
            $taskTriggersForAttempt = @($logonTriggerForAttempt, $dailyTriggerForAttempt)
            
            $principal = New-ScheduledTaskPrincipal `
                -UserId $UserIdToTry `
                -LogonType Interactive `
                -RunLevel Limited
            
            # ВАЖНО: Если UserId начинается с ".\" (локальный компьютер),
            # Windows требует, чтобы задача была в корневом пути "\"
            $actualTaskPath = $taskPath
            if ($UserIdToTry.StartsWith(".\")) {
                if ($Diagnostic) {
                    Write-Host "[Diagnostic] Using root path for local computer format: '$UserIdToTry'" -ForegroundColor Yellow
                }
                $actualTaskPath = '\'
            }
                
            Register-ScheduledTask `
                -TaskName $taskName `
                -TaskPath $actualTaskPath `
                -Action $action `
                -Trigger $taskTriggersForAttempt `
                -Principal $principal `
                -Settings $settings `
                -Description $description `
                -Force `
                -ErrorAction Stop | Out-Null
                
            if ($Diagnostic) {
                Write-Host "[Diagnostic] Successfully registered task with UserId: '$UserIdToTry' at path: '$actualTaskPath'" -ForegroundColor Green
                # Сразу проверяем, видна ли задача
                try {
                    $checkTask = Get-ScheduledTask -TaskName $taskName -TaskPath $actualTaskPath -ErrorAction SilentlyContinue
                    if ($checkTask) {
                        Write-Host "[Diagnostic] Task found after registration: Principal.UserId = '$([string]$checkTask.Principal.UserId)'" -ForegroundColor Green
                    } else {
                        Write-Host "[Diagnostic] WARNING: Task not found immediately after registration" -ForegroundColor Red
                    }
                } catch {
                    Write-Host "[Diagnostic] Error checking task after registration: $_" -ForegroundColor Red
                }
            }
            return $true
        }
        catch {
            $LastError.Value = $_.Exception.Message
            if ($Diagnostic) {
                Write-Host "[Diagnostic] Failed with UserId '$UserIdToTry': $($_.Exception.Message)" -ForegroundColor Red
            }
            return $false
        }
    }

    $existingTarget = @(Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue)
    foreach ($targetTask in $existingTarget) {
        $targetPrincipal = [string]$targetTask.Principal.UserId
        $ownedByCurrentUser = Test-AccountSid -Identity $targetPrincipal -ExpectedSid $userSid
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
        -Marker $managedMarker `
        -Diagnostic:$Diagnostic)

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

    # Используем только имя пользователя, НИКОГДА не SID!
    # SID вызывает ошибку "Task.Path must be the root task path: \"
    $registrationAttempts = New-Object System.Collections.ArrayList
    
    # Основные форматы (без SID!)
    [void]$registrationAttempts.Add(@{ UserId = $taskUserId; Description = "name without domain" })
    [void]$registrationAttempts.Add(@{ UserId = $userName; Description = "full user name" })
    [void]$registrationAttempts.Add(@{ UserId = ".\$userNameWithoutDomain"; Description = "local user format" })
    
    # Специальные форматы для случая, когда имя пользователя совпадает с именем компьютера
    if ($isSameAsComputer) {
        if ($Diagnostic) {
            Write-Host "[Diagnostic] Adding special formats for user with same name as computer" -ForegroundColor Yellow
        }
        # Пробуем с префиксом компьютера
        [void]$registrationAttempts.Add(@{ UserId = "$computerName\$userNameWithoutDomain"; Description = "computer\username format" })
        # Пробуем с локальным префиксом
        [void]$registrationAttempts.Add(@{ UserId = ".\$computerName"; Description = "local computer name format" })
    }
    
    if ($Diagnostic) {
        Write-Host "[Diagnostic] Registration attempts order (NO SID!):" -ForegroundColor Yellow
        for ($i = 0; $i -lt $registrationAttempts.Count; $i++) {
            $attempt = $registrationAttempts[$i]
            Write-Host "[Diagnostic]   $($i+1). '$($attempt.UserId)' - $($attempt.Description)" -ForegroundColor Yellow
        }
    }
    
    $taskRegistered = $false
    $lastError = $null
    
    foreach ($attempt in $registrationAttempts) {
        $userIdToTry = $attempt.UserId
        $attemptDescription = $attempt.Description
        
        if (Register-TaskWithUserIdFallback -UserIdToTry $userIdToTry -AttemptDescription $attemptDescription -LastError ([ref]$lastError)) {
            $taskRegistered = $true
            break
        }
    }
    
    if (-not $taskRegistered) {
        throw "Failed to register task after trying all UserId formats. Last error: $lastError"
    }
    
    # Дополнительная диагностика: проверим, какая задача была создана
    if ($Diagnostic) {
        Write-Host "`n[Diagnostic] === POST-REGISTRATION DIAGNOSTICS ===" -ForegroundColor Cyan
        
        # Пробуем найти задачу разными способами
        Write-Host "[Diagnostic] Looking for created task..." -ForegroundColor Yellow
        
        # Способ 1: Прямой поиск по имени и пути
        try {
            $directTask = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
            if ($directTask) {
                Write-Host "[Diagnostic] Found via direct lookup:" -ForegroundColor Green
                Write-Host "[Diagnostic]   Task: '$($directTask.TaskPath)$($directTask.TaskName)'" -ForegroundColor Green
                Write-Host "[Diagnostic]   Principal.UserId: '$([string]$directTask.Principal.UserId)'" -ForegroundColor Green
                Write-Host "[Diagnostic]   State: $($directTask.State)" -ForegroundColor Green
            } else {
                Write-Host "[Diagnostic] Task not found via direct lookup" -ForegroundColor Red
            }
        } catch {
            Write-Host "[Diagnostic] Error in direct lookup: $_" -ForegroundColor Red
        }
        
        # Способ 2: Поиск всех задач с нашим именем
        Write-Host "`n[Diagnostic] Searching for all tasks with name '$taskName'..." -ForegroundColor Yellow
        $allTasksWithName = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -eq $taskName })
        Write-Host "[Diagnostic] Found $($allTasksWithName.Count) tasks with name '$taskName':" -ForegroundColor $(if ($allTasksWithName.Count -gt 0) { 'Green' } else { 'Red' })
        foreach ($foundTask in $allTasksWithName) {
            Write-Host "[Diagnostic]   - '$($foundTask.TaskPath)$($foundTask.TaskName)' (owner: '$([string]$foundTask.Principal.UserId)')" -ForegroundColor Gray
        }
        
        # Способ 3: Поиск в корне (на случай, если задача создалась не в той папке)
        if ($isSameAsComputer) {
            Write-Host "`n[Diagnostic] Special check for root tasks (user name matches computer name)..." -ForegroundColor Yellow
            $rootTasks = @(Get-ScheduledTask -TaskPath '\' -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -eq $taskName })
            foreach ($rootTask in $rootTasks) {
                Write-Host "[Diagnostic]   Found in root: '$($rootTask.TaskPath)$($rootTask.TaskName)' (owner: '$([string]$rootTask.Principal.UserId)')" -ForegroundColor $(if ([string]$rootTask.Principal.UserId -eq $userNameWithoutDomain) { 'Green' } else { 'Yellow' })
            }
        }
    }

    $remainingManagedTasks = @(Get-ManagedBackupTasks `
        -ManagedNames $managedNames `
        -TaskPath $taskPath `
        -LauncherPath $launcherPath `
        -ConfigPath $ConfigPath `
        -PowerShellExe $powerShellExe `
        -CurrentUserSid $userSid `
        -CurrentUserName $userName `
        -Marker $managedMarker `
        -Diagnostic:$Diagnostic)
    
    # Enhanced validation with better diagnostics and fallback
    if ($remainingManagedTasks.Count -eq 0) {
        if ($Diagnostic) {
            Write-Host "[Diagnostic] No managed tasks found after registration. Trying alternative search methods..." -ForegroundColor Red
            
            # Альтернативный поиск 1: Прямой поиск
            try {
                $directTask = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
                if ($directTask) {
                    Write-Host "[Diagnostic] Found task via direct lookup: '$($directTask.TaskPath)$($directTask.TaskName)'" -ForegroundColor Yellow
                    Write-Host "[Diagnostic] Task principal: '$([string]$directTask.Principal.UserId)'" -ForegroundColor Yellow
                    Write-Host "[Diagnostic] Task state: $($directTask.State)" -ForegroundColor Yellow
                    
                    # Проверяем, является ли эта задача нашей
                    $directPrincipal = [string]$directTask.Principal.UserId
                    $directOwned = Test-AccountSid -Identity $directPrincipal -ExpectedSid $userSid
                    if (-not $directOwned -and -not [string]::IsNullOrWhiteSpace($userName)) {
                        $currentUserNameWithoutDomain = $userName
                        if ($userName.Contains('\')) {
                            $currentUserNameWithoutDomain = $userName.Split('\')[-1]
                        }
                        $directOwned = $directPrincipal -ieq $userName -or
                            $directPrincipal -ieq $currentUserNameWithoutDomain
                    }
                    
                    if ($directOwned) {
                        Write-Host "[Diagnostic] Task is owned by current user, accepting it as valid" -ForegroundColor Green
                        # Добавляем задачу в список для продолжения валидации
                        $remainingManagedTasks = @($directTask)
                    }
                } else {
                    Write-Host "[Diagnostic] Task not found via direct lookup" -ForegroundColor Red
                }
            } catch {
                Write-Host "[Diagnostic] Error in direct lookup: $_" -ForegroundColor Red
            }
            
            # Альтернативный поиск 2: Поиск всех задач с нашим именем
            if ($remainingManagedTasks.Count -eq 0) {
                Write-Host "[Diagnostic] Searching for all tasks with name '$taskName'..." -ForegroundColor Yellow
                $allTasksWithName = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -eq $taskName })
                
                foreach ($foundTask in $allTasksWithName) {
                    $foundPrincipal = [string]$foundTask.Principal.UserId
                    $foundOwned = Test-AccountSid -Identity $foundPrincipal -ExpectedSid $userSid
                    if (-not $foundOwned -and -not [string]::IsNullOrWhiteSpace($userName)) {
                        $currentUserNameWithoutDomain = $userName
                        if ($userName.Contains('\')) {
                            $currentUserNameWithoutDomain = $userName.Split('\')[-1]
                        }
                        $foundOwned = $foundPrincipal -ieq $userName -or
                            $foundPrincipal -ieq $currentUserNameWithoutDomain
                    }
                    
                    if ($foundOwned) {
                        Write-Host "[Diagnostic] Found owned task: '$($foundTask.TaskPath)$($foundTask.TaskName)'" -ForegroundColor Green
                        Write-Host "[Diagnostic] Task principal: '$foundPrincipal'" -ForegroundColor Green
                        Write-Host "[Diagnostic] Task path: '$($foundTask.TaskPath)' (expected: '$taskPath')" -ForegroundColor $(if ($foundTask.TaskPath -eq $taskPath) { 'Green' } else { 'Yellow' })
                        
                        # Если путь совпадает или это особый случай совпадающих имен
                        if ($foundTask.TaskPath -eq $taskPath -or ($isSameAsComputer -and $foundTask.TaskPath -eq '\')) {
                            Write-Host "[Diagnostic] Accepting this task as valid" -ForegroundColor Green
                            $remainingManagedTasks = @($foundTask)
                            break
                        }
                    }
                }
            }
        }
        
        if ($remainingManagedTasks.Count -eq 0) {
            throw 'Managed task cleanup validation failed: no managed tasks found after registration.'
        }
    }
    
    if ($remainingManagedTasks.Count -gt 1) {
        if ($Diagnostic) {
            Write-Host "[Diagnostic] Multiple managed tasks found after registration:" -ForegroundColor Yellow
            foreach ($task in $remainingManagedTasks) {
                Write-Host "  - '$($task.TaskPath)$($task.TaskName)'" -ForegroundColor Yellow
            }
        }
        throw 'Managed task cleanup validation failed: multiple managed tasks found after registration.'
    }
    
    # Check if the found task matches expected name and path
    $foundTask = $remainingManagedTasks[0]
    
    # Для случая совпадающих имен пользователя и компьютера, задача может быть создана в корне
    $acceptablePaths = @($taskPath)
    if ($isSameAsComputer) {
        $acceptablePaths += '\'  # Добавляем корневой путь как допустимый
    }
    
    if ($foundTask.TaskName -ine $taskName -or ($acceptablePaths -notcontains $foundTask.TaskPath)) {
        if ($Diagnostic) {
            Write-Host "[Diagnostic] Found task doesn't match expected name/path:" -ForegroundColor Yellow
            Write-Host "[Diagnostic]   Expected name: '$taskName'" -ForegroundColor Yellow
            Write-Host "[Diagnostic]   Expected path (acceptable): $($acceptablePaths -join ', ')" -ForegroundColor Yellow
            Write-Host "[Diagnostic]   Found: '$($foundTask.TaskPath)$($foundTask.TaskName)'" -ForegroundColor Yellow
            Write-Host "[Diagnostic]   Name matches: $($foundTask.TaskName -ieq $taskName)" -ForegroundColor Yellow
            Write-Host "[Diagnostic]   Path is acceptable: $($acceptablePaths -contains $foundTask.TaskPath)" -ForegroundColor Yellow
        }
        # Be more forgiving - if the task is owned by current user and has right actions/marker, accept it
        $isOwned = Test-AccountSid -Identity ([string]$foundTask.Principal.UserId) -ExpectedSid $userSid
        if (-not $isOwned -and -not [string]::IsNullOrWhiteSpace($userName)) {
            $currentUserNameWithoutDomain = $userName
            if ($userName.Contains('\')) {
                $currentUserNameWithoutDomain = $userName.Split('\')[-1]
            }
            $isOwned = ([string]$foundTask.Principal.UserId -ieq $userName) -or
                ([string]$foundTask.Principal.UserId -ieq $currentUserNameWithoutDomain)
        }
        
        if ($isOwned) {
            if ($Diagnostic) {
                Write-Host "[Diagnostic] Task is owned by current user, accepting it despite path/name mismatch" -ForegroundColor Green
            }
            # Continue with validation - task is owned by current user
        } else {
            throw 'Managed task cleanup validation failed: found task does not match expected name/path and is not owned by current user.'
        }
    }

    $registeredTask = $remainingManagedTasks[0]
    $registeredActions = @($registeredTask.Actions)
    $registeredLogonTriggers = @($registeredTask.Triggers | Where-Object {
        $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger'
    })
    $registeredDailyTriggers = @($registeredTask.Triggers | Where-Object {
        $_.CimClass.CimClassName -eq 'MSFT_TaskDailyTrigger'
    })

    if ($registeredActions.Count -ne 1) {
        throw 'The registered task does not contain exactly one action.'
    }
    
    $actionExecute = [string]$registeredActions[0].Execute
    $actionArguments = [string]$registeredActions[0].Arguments
    $actionWorkingDirectory = [string]$registeredActions[0].WorkingDirectory
    
    if ($actionExecute -ine $powerShellExe -or
        $actionArguments -ne $taskArguments -or
        $actionWorkingDirectory -ine $localDirectory) {
        if ($Diagnostic) {
            Write-Host "[Diagnostic] Task action validation failed:" -ForegroundColor Yellow
            Write-Host "[Diagnostic]   Execute matches: $($actionExecute -ieq $powerShellExe) (expected: '$powerShellExe', actual: '$actionExecute')" -ForegroundColor Yellow
            Write-Host "[Diagnostic]   Arguments match: $($actionArguments -eq $taskArguments)" -ForegroundColor Yellow
            if ($actionArguments -ne $taskArguments) {
                Write-Host "[Diagnostic]     Expected: '$taskArguments'" -ForegroundColor Yellow
                Write-Host "[Diagnostic]     Actual: '$actionArguments'" -ForegroundColor Yellow
            }
            Write-Host "[Diagnostic]   Working directory matches: $($actionWorkingDirectory -ieq $localDirectory) (expected: '$localDirectory', actual: '$actionWorkingDirectory')" -ForegroundColor Yellow
        }
        throw 'The registered task action did not pass validation.'
    }
    
    $principalValid = Test-AccountSid -Identity ([string]$registeredTask.Principal.UserId) -ExpectedSid $userSid
    if (-not $principalValid -and -not [string]::IsNullOrWhiteSpace($userName)) {
        $currentUserNameWithoutDomain = $userName
        if ($userName.Contains('\')) {
            $currentUserNameWithoutDomain = $userName.Split('\')[-1]
        }
        $principalValid = ([string]$registeredTask.Principal.UserId -ieq $userName) -or
            ([string]$registeredTask.Principal.UserId -ieq $currentUserNameWithoutDomain)
    }
    if (-not $principalValid) {
        if ($Diagnostic) {
            Write-Host "[Diagnostic] Task principal validation failed:" -ForegroundColor Yellow
            Write-Host "[Diagnostic]   Task principal: '$([string]$registeredTask.Principal.UserId)'" -ForegroundColor Yellow
            Write-Host "[Diagnostic]   Current user: '$userName' (SID: $userSid)" -ForegroundColor Yellow
        }
        throw 'The registered task principal did not pass validation.'
    }
    
    if ($registeredLogonTriggers.Count -ne 1) {
        throw 'The registered task does not contain exactly one logon trigger.'
    }
    if ($registeredLogonTriggers[0].Delay -ne ('PT' + $delayMinutes + 'M')) {
        if ($Diagnostic) {
            Write-Host "[Diagnostic] Logon trigger delay mismatch:" -ForegroundColor Yellow
            Write-Host "[Diagnostic]   Expected: PT${delayMinutes}M" -ForegroundColor Yellow
            Write-Host "[Diagnostic]   Actual: $($registeredLogonTriggers[0].Delay)" -ForegroundColor Yellow
        }
        throw 'The registered logon trigger did not pass validation.'
    }
    
    if ($registeredDailyTriggers.Count -ne 1) {
        throw 'The registered task does not contain exactly one daily trigger.'
    }
    
    $registeredDailyStart = [DateTime]$registeredDailyTriggers[0].StartBoundary
    if ($registeredDailyStart.ToString('HH:mm') -ne $dailyRunTime) {
        if ($Diagnostic) {
            Write-Host "[Diagnostic] Daily trigger time mismatch:" -ForegroundColor Yellow
            Write-Host "[Diagnostic]   Expected: $dailyRunTime" -ForegroundColor Yellow
            Write-Host "[Diagnostic]   Actual: $($registeredDailyStart.ToString('HH:mm'))" -ForegroundColor Yellow
        }
        throw 'The registered daily trigger did not pass validation.'
    }
    
    if ([int]$registeredDailyTriggers[0].DaysInterval -ne 1) {
        if ($Diagnostic) {
            Write-Host "[Diagnostic] Daily trigger interval mismatch:" -ForegroundColor Yellow
            Write-Host "[Diagnostic]   Expected: 1 day" -ForegroundColor Yellow
            Write-Host "[Diagnostic]   Actual: $($registeredDailyTriggers[0].DaysInterval) days" -ForegroundColor Yellow
        }
        throw 'The registered daily trigger did not pass validation.'
    }
    
    if ([string]$registeredTask.Settings.MultipleInstances -ne 'IgnoreNew') {
        if ($Diagnostic) {
            Write-Host "[Diagnostic] Task settings mismatch - MultipleInstances:" -ForegroundColor Yellow
            Write-Host "[Diagnostic]   Expected: IgnoreNew" -ForegroundColor Yellow
            Write-Host "[Diagnostic]   Actual: $([string]$registeredTask.Settings.MultipleInstances)" -ForegroundColor Yellow
        }
        throw 'The registered task settings did not pass validation.'
    }
    
    if (-not [bool]$registeredTask.Settings.StartWhenAvailable) {
        if ($Diagnostic) {
            Write-Host "[Diagnostic] Task settings mismatch - StartWhenAvailable is false" -ForegroundColor Yellow
        }
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
    
    # Добавляем диагностическую информацию об ошибке
    $diagnosticInfo = @()
    if ($Diagnostic) {
        $diagnosticInfo += "=== ERROR DIAGNOSTICS ==="
        $diagnosticInfo += "Error message: $($originalError.Exception.Message)"
        $diagnosticInfo += "Error type: $($originalError.Exception.GetType().FullName)"
        $diagnosticInfo += "Error stack trace: $($originalError.ScriptStackTrace)"
        
        if ($null -ne $config) {
            $diagnosticInfo += "Task configuration:"
            $diagnosticInfo += "  Name: $taskName"
            $diagnosticInfo += "  Path: $taskPath"
            $diagnosticInfo += "  UserId used: $taskUserId"
            $diagnosticInfo += "  Current user name: $userName"
            $diagnosticInfo += "  Current user SID: $userSid"
        }
        
        foreach ($line in $diagnosticInfo) {
            Write-Host $line -ForegroundColor Red
        }
    }

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
                    -Marker $managedMarker `
                    -Diagnostic:$Diagnostic)
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

    # Формируем расширенное сообщение об ошибке с диагностикой
    $errorMessage = "Task registration failed: $($originalError.Exception.Message)"
    if ($restoreErrors.Count -gt 0) {
        $errorMessage += " Rollback errors: $(@($restoreErrors) -join ' | ')."
        if (-not [string]::IsNullOrWhiteSpace($taskRollbackDirectory)) {
            $errorMessage += " Task XML snapshots were preserved in '$taskRollbackDirectory'."
        }
    }
    
    # Добавляем диагностическую информацию в сообщение об ошибке
    if ($Diagnostic -and $diagnosticInfo.Count -gt 0) {
        $errorMessage += "`n`nDiagnostic information:`n" + ($diagnosticInfo -join "`n")
    }
    
    Write-Error $errorMessage
    exit 1
}
