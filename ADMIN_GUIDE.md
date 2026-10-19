# Руководство администратора - User Backup Manager

## 🎯 Обзор для администраторов

User Backup Manager — это корпоративное решение для автоматического резервного копирования пользовательских данных. Система предназначена для централизованного управления резервным копированием в масштабах организации.

## 🏗️ Архитектура развертывания

### Топология развертывания

```
Центральный сервер (FS-01)
├── 📁 \\FS-01\Scripts\UserBackupManager\
│   ├── Backup-UserData.ps1
│   ├── Register-UserBackupTask.ps1
│   ├── Launcher-UserBackup.ps1
│   ├── BackupConfig.json
│   └── ...
│
└── Клиентские компьютеры
    ├── %LOCALAPPDATA%\ASUP\UserBackup\ (локальные файлы)
    └── Планировщик заданий (задачи резервного копирования)
```

### Компоненты системы

| Компонент | Назначение | Расположение |
|-----------|------------|--------------|
| **Сетевая папка** | Центральное хранилище скриптов | `\\FS-01\Scripts\UserBackupManager\` |
| **Локальная установка** | Файлы пользователя | `%LOCALAPPDATA%\ASUP\UserBackup\` |
| **Задачи планировщика** | Автоматический запуск | Windows Task Scheduler |
| **Целевая папка** | Архивы резервных копий | `D:\_BackUp_\` (настраивается) |

## 📋 Подготовка к развертыванию

### 1. Подготовка сетевой папки

```powershell
# Создание сетевой папки
New-Item -Path "\\FS-01\Scripts\UserBackupManager" -ItemType Directory

# Настройка прав доступа
$acl = Get-Acl "\\FS-01\Scripts\UserBackupManager"
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule("Domain Users", "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.SetAccessRule($rule)
Set-Acl -Path "\\FS-01\Scripts\UserBackupManager" -AclObject $acl
```

### 2. Наполнение сетевой папки

Скопируйте в сетевую папку следующие файлы:
- `Backup-UserData.ps1`
- `Register-UserBackupTask.ps1`
- `Launcher-UserBackup.ps1`
- `BackupConfig.json`
- `LocalDirectoriesToBackup.lst`
- `Install-UserBackup.ps1`
- `Uninstall-UserBackup.ps1`

### 3. Конфигурация прав

**Рекомендуемые права**:
- **Чтение**: Все пользователи домена
- **Запись**: Только администраторы АСУП
- **Изменение**: Только администраторы АСУП

## 🔧 Массовое развертывание

### Метод 1: Групповые политики (GPO)

```xml
<!-- Пример GPO для развертывания через Startup Script -->
<Startup>
    <Script>
        <Command>\\FS-01\Scripts\UserBackupManager\Install-UserBackup.cmd</Command>
        <Parameters>-ConfigPath "\\FS-01\Scripts\UserBackupManager\BackupConfig.json"</Parameters>
    </Script>
</Startup>
```

### Метод 2: PowerShell скрипт развертывания

```powershell
# deploy-backup.ps1 - Скрипт массового развертывания
$computers = Get-ADComputer -Filter * | Select-Object -ExpandProperty Name

foreach ($computer in $computers) {
    try {
        $session = New-PSSession -ComputerName $computer
        Invoke-Command -Session $session -ScriptBlock {
            # Скачивание и установка
            $installPath = "\\FS-01\Scripts\UserBackupManager\Install-UserBackup.ps1"
            $configPath = "\\FS-01\Scripts\UserBackupManager\BackupConfig.json"
            
            powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
                -File $installPath -ConfigPath $configPath
        }
        Remove-PSSession $session
        Write-Host "Успешно: $computer" -ForegroundColor Green
    } catch {
        Write-Host "Ошибка: $computer - $_" -ForegroundColor Red
    }
}
```

### Метод 3: SCCM/Microsoft Endpoint Manager

1. Создайте пакет приложения
2. Используйте `Install-UserBackup.cmd` как команду установки
3. Настройте обнаружение по наличию файла `%LOCALAPPDATA%\ASUP\UserBackup\Launcher-UserBackup.ps1`

## ⚙️ Конфигурация для предприятия

### Пример конфигурации для корпоративной среды

```json
{
  "Task": {
    "Name": "Corporate User Backup",
    "Path": "\\ASUP\\Corporate Backups\\",
    "ManagedNames": ["Corporate User Backup", "User Backup"],
    "DelayMinutes": 5,
    "DailyRunTime": "20:00",
    "ExecutionTimeLimitHours": 8
  },
  "Update": {
    "NetworkPath": "\\\\FS-01\\Scripts\\UserBackupManager\\",
    "ContinueOnFailure": true,
    "ShowWarningOnFailure": false
  },
  "Backup": {
    "RootPath": "E:\\CorporateBackups\\UserData",
    "HideRootFolder": true,
    "CopiesToKeep": 7,
    "MaxSourceSizeMB": 1024,
    "ScheduleMode": "Daily",
    "SafetyReserveMB": 1024,
    "ExcludeMasks": [
      "*.tmp", "*.temp", "~$*", "*.log",
      "Cache\\*", "Temp\\*", "AppData\\Local\\Temp\\*"
    ]
  }
}
```

### Рекомендации по конфигурации

#### Для рабочих станций
- `DelayMinutes`: 3-5 минут (чтобы не мешать запуску системы)
- `DailyRunTime`: 20:00-22:00 (после рабочего дня)
- `CopiesToKeep`: 5-7 (неделя работы)

#### Для серверов терминалов
- `DelayMinutes`: 15 минут (учет множественных входов)
- `DailyRunTime`: 03:00 (ночное время минимальной нагрузки)
- `MaxSourceSizeMB`: 2048 или выше

## 🔄 Процесс обновления

### Жизненный цикл обновлений

```
Разработка → Тестирование → Сетевая папка → Автоматическое обновление клиентов
```

### Протокол выпуска обновлений

1. **Разработка и тестирование**
   - Тестирование в изолированной среде
   - Проверка обратной совместимости

2. **Подготовка релиза**
   ```powershell
   # Создание контрольной суммы для проверки
   Get-FileHash -Path "\\FS-01\Scripts\UserBackupManager\*.ps1" -Algorithm SHA256 | Export-Csv -Path "hashes.csv"
   ```

3. **Развертывание в сетевую папку**
   - Копирование файлов в сетевую папку
   - Проверка прав доступа

4. **Мониторинг обновления**
   - Мониторинг журналов на клиентах
   - Отслеживание ошибок обновления

### Принудительное обновление

```powershell
# Скрипт принудительного обновления для всех компьютеров
Invoke-Command -ComputerName (Get-ADComputer -Filter *).Name -ScriptBlock {
    $launcherPath = "$env:LOCALAPPDATA\ASUP\UserBackup\Launcher-UserBackup.ps1"
    if (Test-Path $launcherPath) {
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $launcherPath
    }
} -ThrottleLimit 10
```

## 📊 Мониторинг и отчетность

### Ключевые метрики для мониторинга

```powershell
# Скрипт сбора статистики
$computers = Get-ADComputer -Filter *

$report = foreach ($computer in $computers) {
    $session = New-PSSession -ComputerName $computer -ErrorAction SilentlyContinue
    if ($session) {
        $data = Invoke-Command -Session $session -ScriptBlock {
            $backupPath = "D:\_BackUp_"
            $userFolders = if (Test-Path $backupPath) {
                (Get-ChildItem $backupPath -Directory).Count
            } else { 0 }
            
            $totalSize = if (Test-Path $backupPath) {
                (Get-ChildItem $backupPath -Recurse -File | Measure-Object -Property Length -Sum).Sum / 1GB
            } else { 0 }
            
            [PSCustomObject]@{
                Computer = $env:COMPUTERNAME
                BackupFolderExists = Test-Path $backupPath
                UserFoldersCount = $userFolders
                TotalSizeGB = [math]::Round($totalSize, 2)
                LastBackup = if ($userFolders -gt 0) {
                    (Get-ChildItem $backupPath -Recurse -File *.zip | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
                } else { $null }
            }
        }
        Remove-PSSession $session
        $data
    }
}

$report | Export-Csv -Path "BackupReport_$(Get-Date -Format 'yyyyMMdd').csv" -NoTypeInformation
```

### Панель мониторинга (PowerShell)

```powershell
# Простая панель мониторинга
function Show-BackupDashboard {
    $computers = Get-ADComputer -Filter * | Select-Object -First 10
    
    Write-Host "`n=== ПАНЕЛЬ МОНИТОРИНГА РЕЗЕРВНОГО КОПИРОВАНИЯ ===" -ForegroundColor Cyan
    Write-Host "Общее количество компьютеров: $($computers.Count)`n"
    
    $online = 0
    $withBackup = 0
    
    foreach ($computer in $computers) {
        $ping = Test-Connection -ComputerName $computer -Count 1 -Quiet
        if ($ping) {
            $online++
            
            $session = New-PSSession -ComputerName $computer -ErrorAction SilentlyContinue
            if ($session) {
                $hasBackup = Invoke-Command -Session $session -ScriptBlock {
                    Test-Path "D:\_BackUp_"
                }
                Remove-PSSession $session
                
                if ($hasBackup) {
                    $withBackup++
                    Write-Host "✅ $computer - Резервное копирование настроено" -ForegroundColor Green
                } else {
                    Write-Host "⚠️  $computer - Папка резервного копирования не найдена" -ForegroundColor Yellow
                }
            }
        } else {
            Write-Host "❌ $computer - Оффлайн" -ForegroundColor Red
        }
    }
    
    Write-Host "`n=== СТАТИСТИКА ===" -ForegroundColor Cyan
    Write-Host "Онлайн компьютеров: $online/$($computers.Count)"
    Write-Host "С настроенным резервным копированием: $withBackup/$online"
}
```

## 🛡️ Безопасность и соответствие требованиям

### Требования безопасности

1. **Контроль доступа**
   - Сетевая папка: только чтение для пользователей
   - Архивы: доступ только для владельца и администраторов

2. **Аудит**
   - Включить аудит доступа к сетевой папке
   - Вести журнал изменений конфигурации

3. **Резервное копирование самих архивов**
   ```powershell
   # Скрипт архивации архивов на ленточный накопитель
   $backupRoot = "D:\_BackUp_"
   $tapeDrive = "\\TapeServer\Backup\"
   
   Robocopy $backupRoot "$tapeDrive\UserBackups_$(Get-Date -Format 'yyyyMMdd')" /MIR /R:3 /W:10 /LOG+:BackupToTape.log
   ```

### Соответствие требованиям

#### GDPR/ФЗ-152
- Архивы содержат персональные данные
- Обеспечьте шифрование при необходимости
- Установите политики хранения

#### Корпоративные политики
- Согласуйте время резервного копирования с графиком работы
- Установите квоты на дисковое пространство
- Определите процедуру восстановления данных

## 🚨 Аварийное восстановление

### Восстановление после сбоя

#### Сценарий 1: Потеря сетевой папки
```powershell
# Восстановление сетевой папки из резервной копии
Restore-Item -Path "\\BackupServer\ScriptsBackup\UserBackupManager" -Destination "\\FS-01\Scripts\UserBackupManager"
```

#### Сценарий 2: Повреждение локальных файлов
```powershell
# Скрипт восстановления локальных файлов
$localPath = "$env:LOCALAPPDATA\ASUP\UserBackup"
$networkPath = "\\FS-01\Scripts\UserBackupManager"

if (Test-Path $networkPath) {
    Remove-Item $localPath -Recurse -Force -ErrorAction SilentlyContinue
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$networkPath\Install-UserBackup.ps1"
}
```

#### Сценарий 3: Восстановление данных пользователя
```powershell
# Скрипт восстановления из архива
function Restore-UserBackup {
    param(
        [string]$User,
        [string]$BackupDate,
        [string]$Source
    )
    
    $backupFile = "D:\_BackUp_\$User\${BackupDate}_${Source}.zip"
    $destination = "C:\Users\$User\Restored\$Source"
    
    if (Test-Path $backupFile) {
        Expand-Archive -Path $backupFile -DestinationPath $destination -Force
        Write-Host "Восстановлено: $backupFile -> $destination" -ForegroundColor Green
    } else {
        Write-Host "Архив не найден: $backupFile" -ForegroundColor Red
    }
}
```

## 📈 Оптимизация производительности

### Рекомендации по производительности

1. **Распределение нагрузки**
   - Используйте разные `DailyRunTime` для разных отделов
   - Настройте `DelayMinutes` для RDS-серверов

2. **Оптимизация дискового ввода-вывода**
   ```powershell
   # Мониторинг производительности резервного копирования
   Get-Counter "\Process(powershell)\IO Data Bytes/sec" -Continuous -SampleInterval 5
   ```

3. **Сетевые оптимизации**
   - Используйте DFS для распределения нагрузки
   - Настройте QoS для трафика резервного копирования

### Планирование емкости

| Параметр | Формула расчета | Пример |
|----------|----------------|---------|
| **Ежедневный прирост** | `Пользователи × Средний размер × Коэффициент изменения` | `100 × 100MB × 0.1 = 1GB/день` |
| **Годовая потребность** | `Ежедневный прирост × 250 рабочих дней` | `1GB × 250 = 250GB/год` |
| **Общая емкость** | `Годовая потребность × CopiesToKeep × Резерв` | `250GB × 2 × 1.2 = 600GB` |

## 🔄 Миграция и модернизация

### Миграция на новую версию

```powershell
# Скрипт миграции с сохранением пользовательских настроек
$oldConfig = Get-Content "C:\OldBackup\config.json" | ConvertFrom-Json
$newConfig = Get-Content "\\FS-01\Scripts\UserBackupManager\BackupConfig.json" | ConvertFrom-Json

# Сохранение пользовательских настроек
$newConfig.Backup.RootPath = $oldConfig.Backup.RootPath
$newConfig.Task.DailyRunTime = $oldConfig.Task.DailyRunTime

$newConfig | ConvertTo-Json -Depth 10 | Set-Content "\\FS-01\Scripts\UserBackupManager\BackupConfig.json"
```

### Обновление инфраструктуры

1. **Переход на новую сетевую папку**
   ```powershell
   # Поэтапное обновление пути в конфигурации
   $computers = Get-ADComputer -Filter "OperatingSystem -like '*Windows 10*'"
   
   Invoke-Command -ComputerName $computers.Name -ScriptBlock {
       $configPath = "$env:LOCALAPPDATA\ASUP\UserBackup\BackupConfig.json"
       $config = Get-Content $configPath | ConvertFrom-Json
       $config.Update.NetworkPath = "\\FS-02\Scripts\UserBackupManager\"
       $config | ConvertTo-Json -Depth 10 | Set-Content $configPath
   }
   ```

## 📞 Поддержка и эскалация

### Уровни поддержки

| Уровень | Ответственные | Время реакции | Инструменты |
|---------|--------------|---------------|-------------|
| **1 уровень** | Help Desk | 4 часа | Журналы, базовые скрипты |
| **2 уровень** | Администраторы | 2 часа | Диагностические скрипты |
| **3 уровень** | Разработчики АСУП | 1 день | Исходный код, детальная диагностика |

### Процедура эскалации

1. **Сбор информации**
   - Имя пользователя и компьютер
   - Время возникновения проблемы
   - Журналы (`Launcher.log`, `UserBackup.log`)
   - Состояние задачи планировщика

2. **Базовая диагностика**
   ```powershell
   # Стандартный диагностический скрипт
   .\Debug-UserBackupTask.ps1 -ComputerName $problemComputer -ExportReport
   ```

3. **Эскалация**
   - Приложить собранную информацию
   - Указать предпринятые действия
   - Оценить влияние на бизнес-процессы

---

## 📋 Чек-лист развертывания

### Перед развертыванием
- [ ] Проверка сетевой инфраструктуры
- [ ] Настройка сетевой папки с правильными правами
- [ ] Тестирование в пилотной группе
- [ ] Обучение службы поддержки

### Во время развертывания
- [ ] Поэтапное развертывание по отделам
- [ ] Мониторинг журналов на ошибки
- [ ] Сбор обратной связи от пользователей

### После развертывания
- [ ] Регулярный мониторинг использования дискового пространства
- [ ] Плановое обновление скриптов
- [ ] Аудит безопасности
- [ ] Обновление документации

---

*Данное руководство должно регулярно обновляться в соответствии с изменениями в системе и инфраструктуре.*

*Версия руководства: 2.0*
*Последнее обновление: 19 октября 2026 г.*