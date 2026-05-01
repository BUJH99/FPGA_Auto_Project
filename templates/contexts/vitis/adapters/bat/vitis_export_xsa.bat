@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
set "CONSOLE_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\console_ui.bat"
set "MANIFEST_CTX=%TEMPLATES_ROOT%\shared\adapters\bat\bootstrap_manifest_context.bat"
set "VIVADO_ENV_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\ensure_vivado_on_path.bat"
set "VITIS_PLAN_CLI=%TEMPLATES_ROOT%\contexts\vitis\adapters\cli\vitis_plan_cli.js"
set "VITIS_SUMMARY_CLI=%TEMPLATES_ROOT%\contexts\vitis\adapters\cli\vitis_summary_cli.js"
set "VITIS_SELECT_HELPER=%TEMPLATES_ROOT%\contexts\vitis\adapters\bat\vitis_select_helper.bat"
set "VITIS_STEP=export_xsa"
set "NO_PAUSE=0"
set "SELECTED_BIT="

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^> [bit_name^|--bit path]
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
if /i "%~1"=="--bit" (
    set "SELECTED_BIT=%~2"
    shift /1
    shift /1
    goto parse_args
)
if /i "%~1"=="--bitstream" (
    set "SELECTED_BIT=%~2"
    shift /1
    shift /1
    goto parse_args
)
if not defined SELECTED_BIT set "SELECTED_BIT=%~1"
shift /1
goto parse_args
:args_done
if exist "%CONSOLE_HELPER%" call "%CONSOLE_HELPER%" clear
if not exist "%TARGET_PROJECT%" (
    echo [ERROR] Project path not found: %TARGET_PROJECT%
    exit /b 1
)

if exist "%MANIFEST_CTX%" (
    call "%MANIFEST_CTX%" "%TARGET_PROJECT%"
    if errorlevel 1 exit /b 1
) else (
    echo [ERROR] Manifest bootstrap helper not found: %MANIFEST_CTX%
    exit /b 1
)

if exist "%VIVADO_ENV_HELPER%" call "%VIVADO_ENV_HELPER%" --quiet >nul 2>nul
where vivado >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Vivado executable not found in PATH.
    exit /b 1
)

if not defined SELECTED_BIT if not "%NO_PAUSE%"=="1" if exist "%VITIS_SELECT_HELPER%" (
    call "%VITIS_SELECT_HELPER%" bit "%TARGET_PROJECT%" SELECTED_BIT
    if errorlevel 1 exit /b !errorlevel!
)

call :prepare_plan
if errorlevel 1 exit /b 1
call :check_vivado_project_for_bitstream
if errorlevel 1 exit /b 1

echo [RUN] Exporting XSA from existing Vivado bitstream...
echo [INFO] Bitstream: %VITIS_XSA_BIT_PATH%
echo [INFO] Vivado project: %VITIS_XSA_VIVADO_PROJECT%
echo [INFO] Implementation run: %VITIS_XSA_IMPL_RUN%
call vivado -mode batch -source "%TEMPLATES_ROOT%\contexts\vitis\adapters\tcl\vivado_export_xsa.tcl" -notrace -log "%VITIS_LOG_PATH%" -journal "%VITIS_JOURNAL_PATH%" -tclargs "%TARGET_PROJECT%" "%VITIS_XSA_PATH%" "%VITIS_XSA_BIT_PATH%" "%VITIS_XSA_VIVADO_PROJECT%" "%VITIS_XSA_IMPL_RUN%" "%VITIS_XSA_INCLUDE_BITSTREAM%" "%VITIS_XSA_FIXED%"
set "ACTION_RC=%errorlevel%"

if "%ACTION_RC%"=="0" if "%VITIS_XSA_VALIDATE%"=="1" (
    echo [RUN] Validating exported XSA...
    call vivado -mode batch -notrace -log "%TARGET_PROJECT%\log\vitis\export_xsa_validate.log" -journal "%TARGET_PROJECT%\log\vitis\export_xsa_validate.jou" -source "%TEMPLATES_ROOT%\contexts\vitis\adapters\tcl\vivado_validate_xsa.tcl" -tclargs "%VITIS_XSA_PATH%"
    set "ACTION_RC=!errorlevel!"
)

call :write_summary "%ACTION_RC%"
exit /b %ACTION_RC%

:prepare_plan
if defined SELECTED_BIT (
    call node "%VITIS_PLAN_CLI%" --project "%TARGET_PROJECT%" --manifest-json "%MANIFEST_JSON%" --step "%VITIS_STEP%" --bit "%SELECTED_BIT%" >nul
) else (
    call node "%VITIS_PLAN_CLI%" --project "%TARGET_PROJECT%" --manifest-json "%MANIFEST_JSON%" --step "%VITIS_STEP%" >nul
)
if errorlevel 1 (
    echo [ERROR] Vitis plan generation failed.
    exit /b 1
)
set "VITIS_PLAN_CMD=%TARGET_PROJECT%\output\vitis\plan\%VITIS_STEP%_plan.cmd"
if not exist "%VITIS_PLAN_CMD%" (
    echo [ERROR] Vitis plan command file missing: %VITIS_PLAN_CMD%
    exit /b 1
)
call "%VITIS_PLAN_CMD%"
exit /b 0

:check_vivado_project_for_bitstream
if not defined VITIS_XSA_BIT_PATH exit /b 0
if not exist "%VITIS_XSA_BIT_PATH%" exit /b 0
if not defined VITIS_XSA_VIVADO_PROJECT (
    echo [ERROR] A bitstream was found, but no Vivado project ^(.xpr^) is associated with it.
    echo         Bitstream: %VITIS_XSA_BIT_PATH%
    echo.
    echo [ACTION] First run IP Integrator GUI creation/editing and the IP Integrator build:
    echo          29. Open IP Integrator GUI from Current Sources
    echo          30. Build IP Integrator Project + Bitstream
    echo.
    echo [INFO] Existing XSA export logic requires the saved .xpr plus the completed implementation run.
    exit /b 1
)
if not exist "%VITIS_XSA_VIVADO_PROJECT%" (
    echo [ERROR] A bitstream was found, but the associated Vivado project ^(.xpr^) is missing.
    echo         Bitstream: %VITIS_XSA_BIT_PATH%
    echo         Expected .xpr: %VITIS_XSA_VIVADO_PROJECT%
    echo.
    echo [ACTION] First run IP Integrator GUI creation/editing and the IP Integrator build:
    echo          29. Open IP Integrator GUI from Current Sources
    echo          30. Build IP Integrator Project + Bitstream
    echo.
    echo [INFO] Existing XSA export logic requires the saved .xpr plus the completed implementation run.
    exit /b 1
)
exit /b 0

:write_summary
set "SUMMARY_RC=%~1"
set "SUMMARY_STATUS=ok"
if not "%SUMMARY_RC%"=="0" set "SUMMARY_STATUS=failed"
call node "%VITIS_SUMMARY_CLI%" --project "%TARGET_PROJECT%" --manifest-json "%MANIFEST_JSON%" --step "%VITIS_STEP%" --plan-json "%VITIS_PLAN_JSON%" --result-json "%VITIS_RESULT_JSON%" --summary-json "%VITIS_SUMMARY_JSON%" --log "%VITIS_LOG_PATH%" --rc "%SUMMARY_RC%" --status "%SUMMARY_STATUS%" >nul
exit /b 0
