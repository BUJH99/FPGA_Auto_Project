@echo off
setlocal EnableExtensions
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..") do set "TEMPLATES_ROOT=%%~fI"

if "%~1"=="" (
    echo [ERROR][doctor_usage] toolkit_doctor: missing target project path.
    echo Usage: %~nx0 ^<Project_Directory^> [--manifest-json path] [--write path] [--json]
    exit /b 1
)

set "PROJECT_ROOT=%~f1"
shift
set "FORWARD_ARGS="

:collect_args
if "%~1"=="" goto run_doctor
set "FORWARD_ARGS=%FORWARD_ARGS% "%~1""
shift
goto collect_args

:run_doctor
where node >nul 2>nul
if errorlevel 1 (
    echo [ERROR][node_missing] toolkit_doctor: Node.js is required.
    exit /b 1
)

call node "%TEMPLATES_ROOT%\shared\adapters\cli\toolkit_doctor_cli.js" --project "%PROJECT_ROOT%" %FORWARD_ARGS%
exit /b %errorlevel%
