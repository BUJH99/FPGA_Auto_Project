@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
set "BOT_SCRIPT=%SCRIPT_DIR%telegram_fpga_bot.py"

if not exist "%BOT_SCRIPT%" (
    echo [ERROR] Bot script not found: %BOT_SCRIPT%
    exit /b 1
)

where python >nul 2>nul
if errorlevel 1 (
    echo [ERROR] python command not found in PATH.
    echo         Install Python 3 and ensure python.exe is available.
    exit /b 1
)

echo [INFO] Starting Telegram FPGA bot...
python "%BOT_SCRIPT%"
set "RC=%errorlevel%"

echo [INFO] Bot exited with code: %RC%
if not "%RC%"=="0" (
    echo [INFO] Press any key to close...
    pause >nul
)
exit /b %RC%
