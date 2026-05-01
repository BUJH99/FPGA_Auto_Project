@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
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
set "LOG_DIR=%TARGET_PROJECT%\log"
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
