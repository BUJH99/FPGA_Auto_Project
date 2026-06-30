@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..") do set "REPO_ROOT=%%~fI"
set "BOT_SCRIPT=%SCRIPT_DIR%telegram_fpga_bot.py"
set "SETTINGS_LOADER=%REPO_ROOT%\templates\shared\adapters\bat\load_fpga_claw_settings.bat"
if exist "%SETTINGS_LOADER%" call "%SETTINGS_LOADER%"
if not defined TEMPLATES_ROOT set "TEMPLATES_ROOT=%REPO_ROOT%\templates"
set "CONSOLE_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\console_ui.bat"

if not exist "%BOT_SCRIPT%" (
    echo [ERROR] Bot script not found: %BOT_SCRIPT%
    exit /b 1
)

if not "%TELEGRAM_FPGA_CLAW_ENABLED%"=="1" (
    echo [INFO] Telegram is disabled in FPGAClaw Settings.
    echo        Set telegram.enabled=true in fpga_claw.local.yml or open MAIN.bat ^> [G] Settings.
    exit /b 0
)

set "PYTHON_CMD="
py -3 -c "import sys" >nul 2>nul
if not errorlevel 1 set "PYTHON_CMD=py -3"
if not defined PYTHON_CMD (
    where python >nul 2>nul
    if not errorlevel 1 set "PYTHON_CMD=python"
)
if not defined PYTHON_CMD (
    where python3 >nul 2>nul
    if not errorlevel 1 set "PYTHON_CMD=python3"
)
if not defined PYTHON_CMD (
    echo [ERROR] Python 3 launcher not found in PATH.
    echo         Tried: py -3, python, python3
    exit /b 1
)

echo [INFO] Starting Telegram FPGA bot...
call %PYTHON_CMD% "%BOT_SCRIPT%"
set "RC=%errorlevel%"

echo [INFO] Bot exited with code: %RC%
if not "%RC%"=="0" (
    echo [INFO] Press any key to close...
    call "%CONSOLE_HELPER%" pause_then_clear
)
exit /b %RC%
