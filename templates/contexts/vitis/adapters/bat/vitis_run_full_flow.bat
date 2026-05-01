@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
set "CONSOLE_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\console_ui.bat"
set "MANIFEST_CTX=%TEMPLATES_ROOT%\shared\adapters\bat\bootstrap_manifest_context.bat"
set "VIVADO_ENV_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\ensure_vivado_on_path.bat"
set "VITIS_ENV_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\ensure_vitis_on_path.bat"
set "VITIS_PLAN_CLI=%TEMPLATES_ROOT%\contexts\vitis\adapters\cli\vitis_plan_cli.js"
set "VITIS_SUMMARY_CLI=%TEMPLATES_ROOT%\contexts\vitis\adapters\cli\vitis_summary_cli.js"
set "VITIS_STEP=full_flow"
set "APP_ARGS="
set "RUN_REQUESTED=0"
set "NO_PAUSE=0"
set "SELECTED_APPS="
set "ALL_APPS=0"

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^> [--app name^|--apps a,b^|--all-apps] [--run]
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
if /i "%~1"=="--run" (
    set "RUN_REQUESTED=1"
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

if not defined SELECTED_APPS if "%ALL_APPS%"=="0" if not "%NO_PAUSE%"=="1" (
    set "ALLOW_MULTI=1"
    if "%RUN_REQUESTED%"=="1" set "ALLOW_MULTI=0"
    call "%TEMPLATES_ROOT%\contexts\vitis\adapters\bat\vitis_select_helper.bat" apps "%TARGET_PROJECT%" "%MANIFEST_JSON%" !ALLOW_MULTI! SELECTED_APPS
    if errorlevel 1 exit /b !errorlevel!
    if /i "!SELECTED_APPS!"=="__ALL__" (
        set "ALL_APPS=1"
        set "SELECTED_APPS="
    )
)
if "%ALL_APPS%"=="1" (
    set "APP_ARGS=--all-apps"
) else if defined SELECTED_APPS (
    set "APP_ARGS=--apps ^"!SELECTED_APPS!^""
)

if exist "%VIVADO_ENV_HELPER%" call "%VIVADO_ENV_HELPER%" --quiet >nul 2>nul
if exist "%VITIS_ENV_HELPER%" call "%VITIS_ENV_HELPER%" --quiet >nul 2>nul
where vivado >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Vivado executable not found in PATH.
    exit /b 1
)
where vitis >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Vitis executable not found in PATH.
    exit /b 1
)

call :prepare_plan
if errorlevel 1 exit /b 1
if "%VITIS_RUN_AUTO%"=="1" set "RUN_REQUESTED=1"

call "%TEMPLATES_ROOT%\contexts\vitis\adapters\bat\vitis_export_xsa.bat" "%TARGET_PROJECT%" --no-pause
if errorlevel 1 goto flow_failed
call "%TEMPLATES_ROOT%\contexts\vitis\adapters\bat\vitis_create_platform.bat" "%TARGET_PROJECT%" --no-pause
if errorlevel 1 goto flow_failed
call "%TEMPLATES_ROOT%\contexts\vitis\adapters\bat\vitis_build_platform.bat" "%TARGET_PROJECT%" --no-pause
if errorlevel 1 goto flow_failed
call "%TEMPLATES_ROOT%\contexts\vitis\adapters\bat\vitis_create_application.bat" "%TARGET_PROJECT%" %APP_ARGS% --no-pause
if errorlevel 1 goto flow_failed
call "%TEMPLATES_ROOT%\contexts\vitis\adapters\bat\vitis_build_application.bat" "%TARGET_PROJECT%" %APP_ARGS% --no-pause
if errorlevel 1 goto flow_failed

if "%RUN_REQUESTED%"=="1" (
    call "%TEMPLATES_ROOT%\contexts\vitis\adapters\bat\vitis_run_application.bat" "%TARGET_PROJECT%" %APP_ARGS% --no-pause
    if errorlevel 1 goto flow_failed
) else (
    echo [INFO] Skipping hardware run. Pass --run or set vitis.run.auto: true to run the application.
)

set "ACTION_RC=0"
call :write_summary "%ACTION_RC%"
exit /b 0

:flow_failed
set "ACTION_RC=%errorlevel%"
call :write_summary "%ACTION_RC%"
exit /b %ACTION_RC%

:prepare_plan
set "RUN_ARG="
if "%RUN_REQUESTED%"=="1" set "RUN_ARG=--run"
call node "%VITIS_PLAN_CLI%" --project "%TARGET_PROJECT%" --manifest-json "%MANIFEST_JSON%" --step "%VITIS_STEP%" %APP_ARGS% %RUN_ARG% >nul
if errorlevel 1 exit /b 1
set "VITIS_PLAN_CMD=%TARGET_PROJECT%\output\vitis\plan\%VITIS_STEP%_plan.cmd"
if not exist "%VITIS_PLAN_CMD%" exit /b 1
call "%VITIS_PLAN_CMD%"
exit /b 0

:write_summary
set "SUMMARY_RC=%~1"
set "SUMMARY_STATUS=ok"
if not "%SUMMARY_RC%"=="0" set "SUMMARY_STATUS=failed"
call node "%VITIS_SUMMARY_CLI%" --project "%TARGET_PROJECT%" --manifest-json "%MANIFEST_JSON%" --step "%VITIS_STEP%" --plan-json "%VITIS_PLAN_JSON%" --result-json "%VITIS_RESULT_JSON%" --summary-json "%VITIS_SUMMARY_JSON%" --log "%VITIS_LOG_PATH%" --rc "%SUMMARY_RC%" --status "%SUMMARY_STATUS%" >nul
exit /b 0
