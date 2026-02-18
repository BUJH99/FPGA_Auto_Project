@echo off
setlocal

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^> [--include-legacy]
    pause
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
set "TOOL_SCRIPT=%~dp0..\tools\annotate_hdl_info.js"
set "NO_PAUSE=0"
set "EXTRA_ARG=%~2"

if /i "%~2"=="--no-pause" (
    set "NO_PAUSE=1"
    set "EXTRA_ARG=%~3"
) else if /i "%~3"=="--no-pause" (
    set "NO_PAUSE=1"
)

if not exist "%TOOL_SCRIPT%" (
    echo [ERROR] Missing tool script: %TOOL_SCRIPT%
    if "%NO_PAUSE%"=="0" pause
    exit /b 1
)

echo ===============================================================================
echo [Source/TB Info] Annotate HDL file headers
echo Target: %TARGET_PROJECT%
echo ===============================================================================

if /i "%EXTRA_ARG%"=="--include-legacy" (
    node "%TOOL_SCRIPT%" "%TARGET_PROJECT%" --include-legacy
) else (
    node "%TOOL_SCRIPT%" "%TARGET_PROJECT%"
)

if errorlevel 1 (
    echo.
    echo [FAILURE] HDL info annotation failed.
    if "%NO_PAUSE%"=="0" pause
    exit /b 1
)

echo.
echo [SUCCESS] Annotated src/tb files in: %TARGET_PROJECT%
if "%NO_PAUSE%"=="0" pause
exit /b 0
