@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
set "CONSOLE_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\console_ui.bat"
set "MANIFEST_CTX=%TEMPLATES_ROOT%\shared\adapters\bat\bootstrap_manifest_context.bat"
set "VITIS_ENV_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\ensure_vitis_on_path.bat"
set "VITIS_SELECT_HELPER=%TEMPLATES_ROOT%\contexts\vitis\adapters\bat\vitis_select_helper.bat"
set "VITIS_PLAN_CLI=%TEMPLATES_ROOT%\contexts\vitis\adapters\cli\vitis_plan_cli.js"
set "VITIS_SUMMARY_CLI=%TEMPLATES_ROOT%\contexts\vitis\adapters\cli\vitis_summary_cli.js"
set "VITIS_MANIFEST_SYNC_CLI=%TEMPLATES_ROOT%\contexts\vitis\adapters\cli\vitis_manifest_sync_cli.js"
set "VITIS_STEP=create_application"
set "NO_PAUSE=0"
set "SELECTED_PLATFORM="
set "SELECTED_APPS="
set "ALL_APPS=0"

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^> [--platform path] [--app new_application_name]
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
shift /1
:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="--no-pause" (
    set "NO_PAUSE=1"
    shift /1
    goto parse_args
)
if /i "%~1"=="--platform" (
    set "SELECTED_PLATFORM=%~2"
    shift /1
    shift /1
    goto parse_args
)
if /i "%~1"=="--app" (
    set "SELECTED_APPS=%~2"
    shift /1
    shift /1
    goto parse_args
)
if /i "%~1"=="--apps" (
    set "SELECTED_APPS=%~2"
    shift /1
    shift /1
    goto parse_args
)
if /i "%~1"=="--all-apps" (
    set "ALL_APPS=1"
    shift /1
    goto parse_args
)
if not defined SELECTED_APPS set "SELECTED_APPS=%~1"
shift /1
goto parse_args
:args_done
if exist "%CONSOLE_HELPER%" call "%CONSOLE_HELPER%" clear

if exist "%MANIFEST_CTX%" (
    call "%MANIFEST_CTX%" "%TARGET_PROJECT%"
    if errorlevel 1 exit /b 1
) else (
    echo [ERROR] Manifest bootstrap helper not found: %MANIFEST_CTX%
    exit /b 1
)

if exist "%VITIS_ENV_HELPER%" call "%VITIS_ENV_HELPER%" --quiet >nul 2>nul
where vitis >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Vitis executable not found in PATH.
    exit /b 1
)

if not defined SELECTED_PLATFORM if not "%NO_PAUSE%"=="1" if exist "%VITIS_SELECT_HELPER%" (
    call "%VITIS_SELECT_HELPER%" platform "%TARGET_PROJECT%" SELECTED_PLATFORM
    if errorlevel 1 exit /b !errorlevel!
)
if not defined SELECTED_APPS if "%ALL_APPS%"=="0" if not "%NO_PAUSE%"=="1" (
    call :prompt_new_application_name
    if errorlevel 1 exit /b !errorlevel!
)

call :prepare_plan
if errorlevel 1 exit /b 1

echo [RUN] Creating Vitis application...
call vitis -s "%TEMPLATES_ROOT%\contexts\vitis\adapters\python\vitis_create_application.py" --plan "%VITIS_PLAN_JSON%" --result "%VITIS_RESULT_JSON%"
set "ACTION_RC=%errorlevel%"
if "!ACTION_RC!"=="0" (
    call node "%VITIS_MANIFEST_SYNC_CLI%" --project "%TARGET_PROJECT%" --plan-json "%VITIS_PLAN_JSON%" --result-json "%VITIS_RESULT_JSON%" >nul
    set "ACTION_RC=!errorlevel!"
)
call :write_summary "%ACTION_RC%"
exit /b %ACTION_RC%

:prepare_plan
set "PLAN_ARGS="
if defined SELECTED_PLATFORM set "PLAN_ARGS=!PLAN_ARGS! --platform ^"!SELECTED_PLATFORM!^""
if "%ALL_APPS%"=="1" set "PLAN_ARGS=!PLAN_ARGS! --all-apps"
if defined SELECTED_APPS set "PLAN_ARGS=!PLAN_ARGS! --app ^"!SELECTED_APPS!^""
call node "%VITIS_PLAN_CLI%" --project "%TARGET_PROJECT%" --manifest-json "%MANIFEST_JSON%" --step "%VITIS_STEP%" !PLAN_ARGS! >nul
if errorlevel 1 exit /b 1
set "VITIS_PLAN_CMD=%TARGET_PROJECT%\output\vitis\plan\%VITIS_STEP%_plan.cmd"
if not exist "%VITIS_PLAN_CMD%" exit /b 1
call "%VITIS_PLAN_CMD%"
exit /b 0

:prompt_new_application_name
echo.
echo Create a new Vitis application component from the selected platform.
set "SELECTED_APPS="
set /p "SELECTED_APPS=New application component name (B=back, Q=cancel): "
if /i "!SELECTED_APPS!"=="B" (
    echo [INFO] Returning to Vitis menu.
    exit /b 99
)
if /i "!SELECTED_APPS!"=="Q" (
    echo [INFO] User cancelled Vitis application creation.
    exit /b 99
)
if "!SELECTED_APPS!"=="" (
    echo [ERROR] Application component name is required.
    exit /b 99
)
exit /b 0

:write_summary
set "SUMMARY_RC=%~1"
set "SUMMARY_STATUS=ok"
if not "%SUMMARY_RC%"=="0" set "SUMMARY_STATUS=failed"
call node "%VITIS_SUMMARY_CLI%" --project "%TARGET_PROJECT%" --manifest-json "%MANIFEST_JSON%" --step "%VITIS_STEP%" --plan-json "%VITIS_PLAN_JSON%" --result-json "%VITIS_RESULT_JSON%" --summary-json "%VITIS_SUMMARY_JSON%" --log "%VITIS_LOG_PATH%" --rc "%SUMMARY_RC%" --status "%SUMMARY_STATUS%" >nul
exit /b 0
