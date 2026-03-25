@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
set "CONSOLE_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\console_ui.bat"
set "VIVADO_RESOLVER=%TEMPLATES_ROOT%\shared\adapters\bat\resolve_vivado.bat"

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^>
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
set "MANIFEST_CTX=%TEMPLATES_ROOT%\shared\adapters\bat\bootstrap_manifest_context.bat"
set "BUILD_SUMMARY_TOOL=%TEMPLATES_ROOT%\contexts\vivado\adapters\cli\vivado_capture_build_summary_cli.js"
if exist "%MANIFEST_CTX%" (
    call "%MANIFEST_CTX%" "%TARGET_PROJECT%"
    if errorlevel 1 (
        echo [ERROR] Manifest context initialization failed.
        exit /b 1
    )
)

call :prepare_gui_plan
if errorlevel 1 (
    echo [ERROR] Vivado GUI launch plan preparation failed.
    exit /b 1
)

if /i not "%BUILD_TOP_MODULE%"=="TOP" (
    echo [INFO] Overriding GUI top module to TOP.
    set "BUILD_TOP_MODULE=TOP"
)

cd /d "%TARGET_PROJECT%"
set "LOG_DIR=%TARGET_PROJECT%\log"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
set "GUI_LOG=%LOG_DIR%\vivado_ipi_gui.log"
set "GUI_JOU=%LOG_DIR%\vivado_ipi_gui.jou"
call :route_vivado_artifacts

call "%VIVADO_RESOLVER%" --quiet
if errorlevel 1 (
    echo [ERROR] Vivado executable not found in PATH.
    echo         Checked PATH and common install directories, including C:\AMDDesignTools\*\Vivado\bin.
    echo         Please add Vivado bin directory to your System PATH.
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)
if /i not "%FPGA_AUTO_VIVADO_SOURCE%"=="PATH" echo [INFO] Resolved Vivado bin: %FPGA_AUTO_VIVADO_BIN%

echo [INFO] Launching Vivado GUI with selected project sources...
echo        Top      : %BUILD_TOP_MODULE%
echo        Part     : %BUILD_PART_NUMBER%
echo        Project  : %BUILD_PROJECT_NAME%
echo        Sources  : %MANIFEST_SRC_LIST%
echo        Includes : %MANIFEST_INC_LIST%
vivado -mode gui -source "%TEMPLATES_ROOT%\contexts\vivado\adapters\tcl\vivado_open_project_gui.tcl" -tclargs "%TARGET_PROJECT%" "%MANIFEST_SRC_LIST%" "%MANIFEST_TB_LIST%" "%MANIFEST_XDC_LIST%" "%MANIFEST_INC_LIST%" "%BUILD_TOP_MODULE%" "%BUILD_PART_NUMBER%" "%BUILD_PROJECT_NAME%" -notrace -log "%GUI_LOG%" -journal "%GUI_JOU%"
call :route_vivado_artifacts
call "%CONSOLE_HELPER%" pause_then_clear
endlocal
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
set "BUILD_PLAN_CMD=%TARGET_PROJECT%\output\vivado\build_plan.cmd"
if not exist "%BUILD_PLAN_CMD%" (
    echo [ERROR] GUI launch plan command file not found: %BUILD_PLAN_CMD%
    exit /b 1
)
call "%BUILD_PLAN_CMD%"
exit /b 0
