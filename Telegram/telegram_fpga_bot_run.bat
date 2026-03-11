@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
set "BOT_SCRIPT=%SCRIPT_DIR%telegram_fpga_bot.py"

if not exist "%BOT_SCRIPT%" (
    echo [ERROR] Bot script not found: %BOT_SCRIPT%
    exit /b 1
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
    pause >nul
)
exit /b %RC%
