@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_NAME=%~nx0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
set "CONSOLE_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\console_ui.bat"
set "USER_CANCEL_RC=99"
set "TARGET_PROJECT="
set "NO_PAUSE=0"

:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="--no-pause" (
    set "NO_PAUSE=1"
) else if not defined TARGET_PROJECT (
    set "TARGET_PROJECT=%~f1"
) else (
    echo [WARNING] Ignoring extra argument: %~1
)
shift
goto parse_args

:args_done

if not defined TARGET_PROJECT (
    echo [ERROR] No target project path provided.
    echo Usage: %SCRIPT_NAME% ^<Project_Directory^> [--no-pause]
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)
set "FLOW_BAT=%TEMPLATES_ROOT%\contexts\vivado\adapters\bat\vivado_run_build_flow.bat"
set "MANIFEST_CTX=%TEMPLATES_ROOT%\shared\adapters\bat\bootstrap_manifest_context.bat"

if exist "%MANIFEST_CTX%" (
    call "%MANIFEST_CTX%" "%TARGET_PROJECT%"
    if errorlevel 1 (
        echo [ERROR] Manifest context initialization failed.
        exit /b 1
    )
)

if not exist "%FLOW_BAT%" (
    echo [ERROR] Missing script: %FLOW_BAT%
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

if "%NO_PAUSE%"=="0" (
    call :prompt_run_or_cancel
    if errorlevel %USER_CANCEL_RC% exit /b %USER_CANCEL_RC%
)

echo ===============================================================================
echo  [AUTO] Build ^+ Program Device
echo  Target: %TARGET_PROJECT%
echo ===============================================================================
echo.

call "%FLOW_BAT%" "%TARGET_PROJECT%" --auto-program --no-pause
set "FLOW_RC=%errorlevel%"

if "%FLOW_RC%"=="%USER_CANCEL_RC%" exit /b %USER_CANCEL_RC%

if %FLOW_RC% neq 0 (
    echo.
    echo [ERROR] Automated build/program flow failed.
    echo         Check log files under: %TARGET_PROJECT%\log
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b %FLOW_RC%
)

echo.
echo [SUCCESS] Build and device programming completed.
call "%CONSOLE_HELPER%" pause_then_clear
exit /b 0

:prompt_run_or_cancel
echo.
set "RUN_INPUT="
set /p "RUN_INPUT=Press Enter to continue, or Q to return to menu: "
if /i "%RUN_INPUT%"=="Q" exit /b %USER_CANCEL_RC%
exit /b 0
