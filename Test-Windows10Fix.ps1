# Тестовый скрипт для проверки исправлений Windows 10
param(
    [switch]$Cleanup
)

Write-Host "=== Тестирование исправлений для Windows 10 ===" -ForegroundColor Cyan
Write-Host "Дата: $(Get-Date)" -ForegroundColor Cyan
Write-Host "Компьютер: $env:COMPUTERNAME" -ForegroundColor Cyan
Write-Host "Пользователь: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" -ForegroundColor Cyan
Write-Host "ОС: $((Get-CimInstance Win32_OperatingSystem).Caption)" -ForegroundColor Cyan
Write-Host "PowerShell: $($PSVersionTable.PSVersion)" -ForegroundColor Cyan
Write-Host ""

# Проверяем текущего пользователя
$currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$userName = $currentIdentity.Name
$userSid = $currentIdentity.User.Value

Write-Host "Информация о пользователе:" -ForegroundColor Yellow
Write-Host "  Полное имя: '$userName'" -ForegroundColor Yellow
Write-Host "  SID: '$userSid'" -ForegroundColor Yellow

if ($userName.Contains('\')) {
    $domain = $userName.Split('\')[0]
    $nameWithoutDomain = $userName.Split('\')[1]
    Write-Host "  Домен: '$domain'" -ForegroundColor Yellow
    Write-Host "  Имя без домена: '$nameWithoutDomain'" -ForegroundColor Yellow
    Write-Host "  Локальный формат: '.\$nameWithoutDomain'" -ForegroundColor Yellow
} else {
    Write-Host "  Локальный формат: '.\$userName'" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Проверка планировщика задач ===" -ForegroundColor Cyan

# Проверяем, доступен ли модуль ScheduledTasks
try {
    Import-Module ScheduledTasks -ErrorAction Stop
    Write-Host "Модуль ScheduledTasks загружен успешно" -ForegroundColor Green
} catch {
    Write-Host "Ошибка загрузки модуля ScheduledTasks: $_" -ForegroundColor Red
    exit 1
}

# Проверяем, можем ли мы создать простую задачу для теста
Write-Host "`nПроверка создания тестовой задачи..." -ForegroundColor Yellow

$testTaskName = "Test-UserBackupManager-Windows10"
$testTaskPath = "\ASUP\User BackUp Manager\"

# Удаляем тестовую задачу, если она существует
try {
    $existingTestTask = Get-ScheduledTask -TaskName $testTaskName -TaskPath $testTaskPath -ErrorAction SilentlyContinue
    if ($existingTestTask) {
        if ($Cleanup) {
            Write-Host "Удаляем существующую тестовую задачу..." -ForegroundColor Yellow
            Unregister-ScheduledTask -TaskName $testTaskName -TaskPath $testTaskPath -Confirm:$false -ErrorAction Stop
            Write-Host "Тестовая задача удалена" -ForegroundColor Green
        } else {
            Write-Host "Тестовая задача уже существует: '$testTaskPath$testTaskName'" -ForegroundColor Yellow
        }
    }
} catch {
    Write-Host "Ошибка при проверке тестовой задачи: $_" -ForegroundColor Red
}

# Проверяем разные форматы UserId
Write-Host "`n=== Тестирование разных форматов UserId ===" -ForegroundColor Cyan

$userIdFormats = @()

if ($userName.Contains('\')) {
    $nameWithoutDomain = $userName.Split('\')[1]
    $userIdFormats += @{ Format = "Имя без домена"; Value = $nameWithoutDomain }
    $userIdFormats += @{ Format = "Полное имя"; Value = $userName }
    $userIdFormats += @{ Format = "Локальный формат"; Value = ".\$nameWithoutDomain" }
} else {
    $userIdFormats += @{ Format = "Имя пользователя"; Value = $userName }
    $userIdFormats += @{ Format = "Локальный формат"; Value = ".\$userName" }
}

$userIdFormats += @{ Format = "SID пользователя"; Value = $userSid }

foreach ($format in $userIdFormats) {
    Write-Host "`nТестируем формат: $($format.Format) = '$($format.Value)'" -ForegroundColor Yellow
    
    try {
        # Пробуем создать principal
        $principal = New-ScheduledTaskPrincipal `
            -UserId $format.Value `
            -LogonType Interactive `
            -RunLevel Limited `
            -ErrorAction Stop
            
        Write-Host "  ✓ Principal создан успешно" -ForegroundColor Green
        
        # Пробуем создать простую задачу
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-Command `"Write-Host 'Test'`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $format.Value
        
        $task = Register-ScheduledTask `
            -TaskName $testTaskName `
            -TaskPath $testTaskPath `
            -Action $action `
            -Trigger $trigger `
            -Principal $principal `
            -Description "Тестовая задача для проверки формата UserId" `
            -Force `
            -ErrorAction Stop
            
        Write-Host "  ✓ Задача создана успешно" -ForegroundColor Green
        
        # Удаляем тестовую задачу
        Unregister-ScheduledTask -TaskName $testTaskName -TaskPath $testTaskPath -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "  ✓ Тестовая задача удалена" -ForegroundColor Green
        
    } catch {
        Write-Host "  ✗ Ошибка: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host "`n=== Рекомендации ===" -ForegroundColor Cyan
Write-Host "1. Запустите установку с диагностикой:" -ForegroundColor White
Write-Host "   .\Register-UserBackupTask.ps1 -ConfigPath .\BackupConfig.json -Diagnostic" -ForegroundColor Gray
Write-Host ""
Write-Host "2. Если проблема с UserId, попробуйте:" -ForegroundColor White
Write-Host "   - Проверить имя пользователя в планировщике" -ForegroundColor Gray
Write-Host "   - Использовать локальный формат '.\ИмяПользователя'" -ForegroundColor Gray
Write-Host "   - Использовать полное имя 'Домен\ИмяПользователя'" -ForegroundColor Gray
Write-Host ""
Write-Host "3. Для очистки тестовых задач:" -ForegroundColor White
Write-Host "   .\Test-Windows10Fix.ps1 -Cleanup" -ForegroundColor Gray

Write-Host "`n=== Заключение ===" -ForegroundColor Cyan
Write-Host "Обновленный скрипт Register-UserBackupTask.ps1 теперь пробует несколько форматов UserId:" -ForegroundColor White
Write-Host "1. Имя без домена" -ForegroundColor Gray
Write-Host "2. Полное имя (если есть домен)" -ForegroundColor Gray
Write-Host "3. Локальный формат (.\ИмяПользователя)" -ForegroundColor Gray
Write-Host "4. SID пользователя" -ForegroundColor Gray
Write-Host ""
Write-Host "Также добавлена расширенная диагностика ошибок." -ForegroundColor White
