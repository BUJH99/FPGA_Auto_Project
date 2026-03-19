@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
set "CANONICAL_BAT=%SCRIPT_DIR%templates\contexts\project_bootstrap\adapters\bat\toolkit_setup_dependencies.bat"
set "CONSOLE_HELPER=%SCRIPT_DIR%templates\shared\adapters\bat\console_ui.bat"

if not exist "%CANONICAL_BAT%" (
    echo [ERROR] Canonical setup script not found: %CANONICAL_BAT%
    if "%~1"=="--no-pause" (
        endlocal
        exit /b 1
    )
    call "%CONSOLE_HELPER%" pause_then_clear
    endlocal
    exit /b 1
)

call "%CANONICAL_BAT%" %*
set "RC=%errorlevel%"
endlocal & exit /b %RC%
