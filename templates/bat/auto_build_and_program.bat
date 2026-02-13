@echo off
setlocal

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^>
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
set "FLOW_BAT=%~dp0run_vivado_build_flow.bat"

if not exist "%FLOW_BAT%" (
    echo [ERROR] Missing script: %FLOW_BAT%
    exit /b 1
)

echo ===============================================================================
echo  [AUTO] Build ^+ Program Device
echo  Target: %TARGET_PROJECT%
echo ===============================================================================
echo.

call "%FLOW_BAT%" "%TARGET_PROJECT%" --auto-program --no-pause
set "FLOW_RC=%errorlevel%"

if %FLOW_RC% neq 0 (
    echo.
    echo [ERROR] Automated build/program flow failed.
    echo         Check log files under: %TARGET_PROJECT%\log
    exit /b %FLOW_RC%
)

echo.
echo [SUCCESS] Build and device programming completed.
exit /b 0
