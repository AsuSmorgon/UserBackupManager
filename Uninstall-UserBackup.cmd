@echo off
setlocal

set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "UNINSTALLER_SCRIPT=%~dp0Uninstall-UserBackup.ps1"
set "DEFAULT_CONFIG=%~dp0BackupConfig.json"
set "WAIT_FOR_KEY=0"
set "EXIT_CODE=0"

if "%~1"=="" set "WAIT_FOR_KEY=1"

if not exist "%POWERSHELL_EXE%" (
    echo ERROR: Windows PowerShell was not found: "%POWERSHELL_EXE%"
    set "EXIT_CODE=2"
    goto :finish
)

if not exist "%UNINSTALLER_SCRIPT%" (
    echo ERROR: Uninstaller script was not found: "%UNINSTALLER_SCRIPT%"
    set "EXIT_CODE=3"
    goto :finish
)

if "%WAIT_FOR_KEY%"=="1" (
    if not exist "%DEFAULT_CONFIG%" (
        echo ERROR: Default configuration was not found: "%DEFAULT_CONFIG%"
        set "EXIT_CODE=4"
        goto :finish
    )
    "%POWERSHELL_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%UNINSTALLER_SCRIPT%" -ConfigPath "%DEFAULT_CONFIG%"
) else (
    "%POWERSHELL_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%UNINSTALLER_SCRIPT%" %*
)
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
    echo ERROR: Uninstallation failed with exit code %EXIT_CODE%.
)

:finish
if "%WAIT_FOR_KEY%"=="1" (
    echo.
    echo Press any key to close this window...
    pause >nul
)

endlocal & exit /b %EXIT_CODE%
