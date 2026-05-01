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
set "VITIS_STEP=create_platform"
set "NO_PAUSE=0"
set "SELECTED_XSA="

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^> [xsa_name^|--xsa path]
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
if /i "%~1"=="--xsa" (
    set "SELECTED_XSA=%~2"
    shift /1
    shift /1
    goto parse_args
)
if /i "%~1"=="--xsa-path" (
    set "SELECTED_XSA=%~2"
    shift /1
    shift /1
    goto parse_args
)
if not defined SELECTED_XSA set "SELECTED_XSA=%~1"
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

if not defined SELECTED_XSA if not "%NO_PAUSE%"=="1" if exist "%VITIS_SELECT_HELPER%" (
    call "%VITIS_SELECT_HELPER%" xsa "%TARGET_PROJECT%" SELECTED_XSA
    if errorlevel 1 exit /b !errorlevel!
)

call :prepare_plan
if errorlevel 1 exit /b 1

echo [RUN] Creating Vitis platform...
call vitis -s "%TEMPLATES_ROOT%\contexts\vitis\adapters\python\vitis_create_platform.py" --plan "%VITIS_PLAN_JSON%" --result "%VITIS_RESULT_JSON%"
set "ACTION_RC=%errorlevel%"
call :write_summary "%ACTION_RC%"
exit /b %ACTION_RC%

:prepare_plan
if defined SELECTED_XSA (
    call node "%VITIS_PLAN_CLI%" --project "%TARGET_PROJECT%" --manifest-json "%MANIFEST_JSON%" --step "%VITIS_STEP%" --xsa "%SELECTED_XSA%" >nul
) else (
    call node "%VITIS_PLAN_CLI%" --project "%TARGET_PROJECT%" --manifest-json "%MANIFEST_JSON%" --step "%VITIS_STEP%" >nul
)
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
