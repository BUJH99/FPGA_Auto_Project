@echo off
setlocal EnableDelayedExpansion
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
set "CONSOLE_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\console_ui.bat"
set "USER_CANCEL_RC=99"

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^> [--no-pause]
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
set "NO_PAUSE=0"
set "MANIFEST_CTX=%TEMPLATES_ROOT%\shared\adapters\bat\bootstrap_manifest_context.bat"
set "BUILD_SUMMARY_TOOL=%TEMPLATES_ROOT%\contexts\vivado\adapters\cli\vivado_capture_build_summary_cli.js"
set "VIVADO_ENV_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\ensure_vivado_on_path.bat"

shift /1
:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="--no-pause" (
    set "NO_PAUSE=1"
    shift /1
    goto parse_args
)
echo [ERROR] Unknown argument: %~1
exit /b 1
:args_done

if exist "%CONSOLE_HELPER%" call "%CONSOLE_HELPER%" clear
if exist "%MANIFEST_CTX%" (
    call "%MANIFEST_CTX%" "%TARGET_PROJECT%"
    if errorlevel 1 (
        echo [ERROR] Manifest context initialization failed.
        call :maybe_pause
        exit /b 1
    )
) else (
    echo [ERROR] Manifest bootstrap script not found: %MANIFEST_CTX%
    call :maybe_pause
    exit /b 1
)

call :prepare_build_plan
if errorlevel 1 (
    echo [ERROR] Vivado IP Integrator build plan preparation failed.
    call :maybe_pause
    exit /b 1
)

cd /d "%TARGET_PROJECT%"
set "LOG_DIR=%TARGET_PROJECT%\log"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
set "BUILD_LOG=%LOG_DIR%\vivado_ip_integrator_build.log"
set "BUILD_JOU=%LOG_DIR%\vivado_ip_integrator_build.jou"
set "IPI_PROJECT_NAME=%BUILD_PROJECT_NAME%_ipi"
set "IPI_XPR=%TARGET_PROJECT%\output\vivado\%IPI_PROJECT_NAME%\%IPI_PROJECT_NAME%.xpr"
call :route_vivado_artifacts

if not exist "%IPI_XPR%" (
    echo [ERROR] IP Integrator Vivado project not found:
    echo         %IPI_XPR%
    echo.
    echo [ACTION] Run menu 29, edit/save the block design in Vivado GUI, then run menu 30.
    echo          29. Open IP Integrator GUI from Current Sources
    echo          30. Build IP Integrator Project + Bitstream
    call :maybe_pause
    exit /b 1
)

if exist "%VIVADO_ENV_HELPER%" call "%VIVADO_ENV_HELPER%" --quiet >nul 2>nul
where vivado >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] Vivado executable not found in PATH.
    echo         Check VIVADO_BIN or AMD/Xilinx default install paths.
    call :maybe_pause
    exit /b 1
)

echo [RUN] Building saved IP Integrator project...
echo       Project : %IPI_XPR%
echo       Log     : %BUILD_LOG%
echo       XSA     : Not exported here. Use menu 22 after bitstream generation.
echo.
vivado -mode batch -source "%TEMPLATES_ROOT%\contexts\vivado\adapters\tcl\vivado_build_ip_integrator_flow.tcl" -notrace -log "%BUILD_LOG%" -journal "%BUILD_JOU%" -tclargs "%TARGET_PROJECT%" "%IPI_XPR%" "%BUILD_TOP_MODULE%" "%BUILD_PART_NUMBER%"
set "BUILD_RC=%errorlevel%"
call :route_vivado_artifacts

if not "%BUILD_RC%"=="0" (
    echo [FAIL] IP Integrator build failed. rc=%BUILD_RC%
    echo        Full log: %BUILD_LOG%
    call :maybe_pause
    exit /b %BUILD_RC%
)

echo [DONE] IP Integrator bitstream build completed.
echo        Bitstream remains under:
echo        %TARGET_PROJECT%\output\vivado\%IPI_PROJECT_NAME%\%IPI_PROJECT_NAME%.runs\impl_1
echo.
echo [NEXT] Use menu 22. Export XSA from Vivado when you are ready for Vitis.
call :maybe_pause
exit /b 0

:maybe_pause
if "%NO_PAUSE%"=="1" exit /b 0
call "%CONSOLE_HELPER%" pause_then_clear
exit /b 0

:route_vivado_artifacts
for %%F in (vivado.log vivado.jou vivado.pb vivado.str) do (
    if exist "%%F" move /y "%%F" "%LOG_DIR%\" >nul 2>&1
)
for %%F in (*.backup.log *.backup.jou *.backup.str) do (
    if exist "%%F" move /y "%%F" "%LOG_DIR%\" >nul 2>&1
)
exit /b 0

:prepare_build_plan
if not exist "%BUILD_SUMMARY_TOOL%" (
    echo [ERROR] Vivado build helper not found: %BUILD_SUMMARY_TOOL%
    exit /b 1
)
if not exist "%MANIFEST_JSON%" (
    echo [ERROR] Manifest JSON not found: %MANIFEST_JSON%
    exit /b 1
)
call node "%BUILD_SUMMARY_TOOL%" --stage prepare --project "%TARGET_PROJECT%" --manifest-json "%MANIFEST_JSON%" --src-list "%MANIFEST_SRC_LIST%" --xdc-list "%MANIFEST_XDC_LIST%" --inc-list "%MANIFEST_INC_LIST%" --no-pause >nul
if errorlevel 1 exit /b 1
set "BUILD_PLAN_CMD=%TARGET_PROJECT%\output\vivado\build_plan.cmd"
if not exist "%BUILD_PLAN_CMD%" (
    echo [ERROR] IP Integrator build plan command file not found: %BUILD_PLAN_CMD%
    exit /b 1
)
call "%BUILD_PLAN_CMD%"
exit /b 0
