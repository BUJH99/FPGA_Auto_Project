@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..") do set "TEMPLATES_ROOT=%%~fI"

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^> [--manifest-json path] [--write path] [--json]
    exit /b 1
)

set "PROJECT_ROOT=%~f1"
shift

where node >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Node.js is required.
    exit /b 1
)

call node "%TEMPLATES_ROOT%\shared\adapters\cli\toolkit_doctor_cli.js" --project "%PROJECT_ROOT%" %*
exit /b %errorlevel%
