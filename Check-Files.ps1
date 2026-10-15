# Проверка файлов для копирования при установке
Write-Host "=== Проверка файлов для установки ===" -ForegroundColor Cyan

$requiredFiles = @(
    "Backup-UserData.ps1",
    "Launcher-UserBackup.ps1", 
    "Register-UserBackupTask.ps1",
    "BackupConfig.json",
    "LocalDirectoriesToBackup.lst"
)

$additionalFiles = @(
    "Uninstall-UserBackup.ps1",
    "Uninstall-UserBackup.cmd", 
    "Install-UserBackup.cmd",
    "README.md",
    "Debug-UserBackupTask.ps1"
)

Write-Host "`nОбязательные файлы:" -ForegroundColor Yellow
foreach ($file in $requiredFiles) {
    $exists = Test-Path $file
    $color = if ($exists) { "Green" } else { "Red" }
    Write-Host "  $(if ($exists) { '✓' } else { '✗' }) $file" -ForegroundColor $color
}

Write-Host "`nДополнительные файлы:" -ForegroundColor Yellow
foreach ($file in $additionalFiles) {
    $exists = Test-Path $file
    $color = if ($exists) { "Green" } else { "Yellow" }
    Write-Host "  $(if ($exists) { '✓' } else { '⚠' }) $file" -ForegroundColor $color
}

Write-Host "`nВсего файлов для копирования: $(($requiredFiles + $additionalFiles | Where-Object { Test-Path $_ }).Count)" -ForegroundColor Cyan

# Проверка уникальности имен
Write-Host "`n=== Проверка уникальности имен файлов ===" -ForegroundColor Cyan
$allFiles = $requiredFiles + $additionalFiles
$lowercaseNames = $allFiles | ForEach-Object { $_.ToLowerInvariant() }
$uniqueNames = $lowercaseNames | Sort-Object -Unique

if ($uniqueNames.Count -eq $allFiles.Count) {
    Write-Host "✓ Все имена файлов уникальны" -ForegroundColor Green
} else {
    Write-Host "✗ Обнаружены повторяющиеся имена файлов!" -ForegroundColor Red
    $duplicates = $lowercaseNames | Group-Object | Where-Object { $_.Count -gt 1 }
    foreach ($dup in $duplicates) {
        Write-Host "  - $($dup.Name): $($dup.Count) раз(а)" -ForegroundColor Red
    }
}

Write-Host "`n=== Путь установки ===" -ForegroundColor Cyan
Write-Host "Файлы будут скопированы в:" -ForegroundColor Yellow
Write-Host "%LOCALAPPDATA%\ASUP\UserBackup\" -ForegroundColor Gray

Write-Host "`n=== Проверка завершена ===" -ForegroundColor Green