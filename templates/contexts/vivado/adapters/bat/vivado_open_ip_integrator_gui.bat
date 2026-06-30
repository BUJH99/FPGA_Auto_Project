@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
set "SETTINGS_LOADER=%TEMPLATES_ROOT%\shared\adapters\bat\load_fpga_claw_settings.bat"
if exist "%SETTINGS_LOADER%" call "%SETTINGS_LOADER%"
set "CONSOLE_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\console_ui.bat"

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^>
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
call :resolve_project_dir "LOG_DIR" "%FPGA_CLAW_LOG_DIR%" "log"
call :resolve_project_dir "OUTPUT_DIR" "%FPGA_CLAW_OUTPUT_DIR%" "output"
set "MANIFEST_CTX=%TEMPLATES_ROOT%\shared\adapters\bat\bootstrap_manifest_context.bat"
set "BUILD_SUMMARY_TOOL=%TEMPLATES_ROOT%\contexts\vivado\adapters\cli\vivado_capture_build_summary_cli.js"
set "VIVADO_ENV_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\ensure_vivado_on_path.bat"

if exist "%MANIFEST_CTX%" (
    call "%MANIFEST_CTX%" "%TARGET_PROJECT%"
    if errorlevel 1 (
        echo [ERROR] Manifest context initialization failed.
        exit /b 1
    )
) else (
    echo [ERROR] Manifest bootstrap script not found: %MANIFEST_CTX%
    exit /b 1
)

call :prepare_gui_plan
if errorlevel 1 (
    echo [ERROR] Vivado IP Integrator launch plan preparation failed.
    exit /b 1
)

cd /d "%TARGET_PROJECT%"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
set "GUI_LOG=%LOG_DIR%\vivado_ip_integrator_gui.log"
set "GUI_JOU=%LOG_DIR%\vivado_ip_integrator_gui.jou"
set "IPI_PROJECT_NAME=%BUILD_PROJECT_NAME%_ipi"
set "IPI_PROJECT_PATH=%OUTPUT_DIR%\vivado\%IPI_PROJECT_NAME%\%IPI_PROJECT_NAME%.xpr"
call :route_vivado_artifacts

if exist "%VIVADO_ENV_HELPER%" call "%VIVADO_ENV_HELPER%" --quiet >nul 2>nul
where vivado >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] Vivado executable not found in PATH.
    echo         Check VIVADO_BIN or AMD/Xilinx default install paths.
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

echo [INFO] Launching Vivado IP Integrator GUI from current manifest sources...
echo        Top      : %BUILD_TOP_MODULE%
echo        Part     : %BUILD_PART_NUMBER%
if defined BUILD_BOARD_PART echo        Board    : %BUILD_BOARD_PART%
echo        Project  : %IPI_PROJECT_PATH%
echo        Sources  : %MANIFEST_SRC_LIST%
echo        Includes : %MANIFEST_INC_LIST%
echo.
echo [INFO] The block design will be opened for manual IP editing.
echo        No IP blocks or BD automation will be created beyond an empty design_1 when needed.
vivado -mode gui -source "%TEMPLATES_ROOT%\contexts\vivado\adapters\tcl\vivado_open_ip_integrator_gui.tcl" -notrace -log "%GUI_LOG%" -journal "%GUI_JOU%" -tclargs "%TARGET_PROJECT%" "%MANIFEST_SRC_LIST%" "%MANIFEST_TB_LIST%" "%MANIFEST_XDC_LIST%" "%MANIFEST_INC_LIST%" "%BUILD_TOP_MODULE%" "%BUILD_PART_NUMBER%" "%BUILD_PROJECT_NAME%" "%BUILD_BOARD_PART%"
call :route_vivado_artifacts
call "%CONSOLE_HELPER%" pause_then_clear
endlocal
exit /b 0

:resolve_project_dir
set "RESOLVE_OUT=%~1"
set "RESOLVE_VALUE=%~2"
set "RESOLVE_FALLBACK=%~3"
if not defined RESOLVE_FALLBACK set "RESOLVE_FALLBACK=output"
if not defined RESOLVE_VALUE set "RESOLVE_VALUE=%RESOLVE_FALLBACK%"
if "%RESOLVE_VALUE:~1,1%"==":" (
    set "%RESOLVE_OUT%=%RESOLVE_VALUE%"
) else if "%RESOLVE_VALUE:~0,1%"=="\" (
    set "%RESOLVE_OUT%=%RESOLVE_VALUE%"
) else (
    set "%RESOLVE_OUT%=%TARGET_PROJECT%\%RESOLVE_VALUE%"
)
exit /b 0

:route_vivado_artifacts
for %%F in (vivado.log vivado.jou vivado.pb vivado.str) do (
    if exist "%%F" move /y "%%F" "%LOG_DIR%\" >nul 2>&1
)
for %%F in (*.backup.log *.backup.jou *.backup.str) do (
    if exist "%%F" move /y "%%F" "%LOG_DIR%\" >nul 2>&1
)
exit /b 0

:prepare_gui_plan
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
set "BUILD_PLAN_CMD=%OUTPUT_DIR%\vivado\build_plan.cmd"
if not exist "%BUILD_PLAN_CMD%" (
    echo [ERROR] IP Integrator launch plan command file not found: %BUILD_PLAN_CMD%
    exit /b 1
)
call "%BUILD_PLAN_CMD%"
exit /b 0
