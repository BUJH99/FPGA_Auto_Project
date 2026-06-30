@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
set "SETTINGS_LOADER=%TEMPLATES_ROOT%\shared\adapters\bat\load_fpga_claw_settings.bat"
if exist "%SETTINGS_LOADER%" call "%SETTINGS_LOADER%"
set "CONSOLE_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\console_ui.bat"
set "USER_CANCEL_RC=99"

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^>
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
set "MANIFEST_CTX=%TEMPLATES_ROOT%\shared\adapters\bat\bootstrap_manifest_context.bat"
set "VIVADO_ENV_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\ensure_vivado_on_path.bat"
if exist "%MANIFEST_CTX%" (
    call "%MANIFEST_CTX%" "%TARGET_PROJECT%"
    if errorlevel 1 (
        echo [ERROR] Manifest context initialization failed.
        exit /b 1
    )
)
cd /d "%TARGET_PROJECT%"
call :resolve_project_dir "LOG_DIR" "%FPGA_CLAW_LOG_DIR%" "log"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
set "FINALIZE_LOG=%LOG_DIR%\finalize_block_design.log"
set "FINALIZE_JOU=%LOG_DIR%\finalize_block_design.jou"
call :route_vivado_artifacts

if exist "%VIVADO_ENV_HELPER%" call "%VIVADO_ENV_HELPER%" --quiet >nul 2>nul
where vivado >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] Vivado executable not found in PATH.
    echo         Check VIVADO_BIN or AMD/Xilinx default install paths.
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

call :prompt_run_or_cancel
if errorlevel %USER_CANCEL_RC% exit /b %USER_CANCEL_RC%

echo [INFO] Finalizing legacy/non-project block design export artifacts...
vivado -mode batch -source "%TEMPLATES_ROOT%\contexts\vivado\adapters\tcl\vivado_finalize_block_design.tcl" -notrace -log "%FINALIZE_LOG%" -journal "%FINALIZE_JOU%"
set "FINALIZE_RC=%errorlevel%"
call :route_vivado_artifacts
if %FINALIZE_RC% neq 0 (
    echo [ERROR] Finalize failed. Check %FINALIZE_LOG%
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b %FINALIZE_RC%
)

echo [DONE] Legacy BD export finalized. No wrapper generated.
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

:prompt_run_or_cancel
echo.
set "RUN_INPUT="
set /p "RUN_INPUT=Press Enter to continue, or Q to return to menu: "
if /i "%RUN_INPUT%"=="Q" exit /b %USER_CANCEL_RC%
exit /b 0
