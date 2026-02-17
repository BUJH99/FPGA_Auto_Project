@echo off
setlocal

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^> [--no-pause]
    pause
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
set "TOOL_SCRIPT=%~dp0..\tools\generate_one_source_report.js"
set "NO_PAUSE=0"
if /i "%~2"=="--no-pause" set "NO_PAUSE=1"

if not exist "%TOOL_SCRIPT%" (
    echo [ERROR] Missing tool script: %TOOL_SCRIPT%
    if "%NO_PAUSE%"=="0" pause
    exit /b 1
)

echo ===============================================================================
echo [Report Automation] Generate report.md from src/tb + assets
echo Target: %TARGET_PROJECT%
echo ===============================================================================

node "%TOOL_SCRIPT%" "%TARGET_PROJECT%"
if errorlevel 1 (
    echo.
    echo [FAILURE] report.md generation failed.
    if "%NO_PAUSE%"=="0" pause
    exit /b 1
)

echo.
echo [SUCCESS] Generated:
echo - %TARGET_PROJECT%\output\docs\report.md
echo - %TARGET_PROJECT%\output\docs\github.css
if "%NO_PAUSE%"=="0" pause
exit /b 0
