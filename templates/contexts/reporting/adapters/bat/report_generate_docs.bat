@echo off
setlocal EnableDelayedExpansion
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

if exist "%MANIFEST_CTX%" (
    call "%MANIFEST_CTX%" "%TARGET_PROJECT%"
    if errorlevel 1 (
        echo [ERROR] Manifest context initialization failed.
        call "%CONSOLE_HELPER%" pause_then_clear
        exit /b 1
    )
)

echo [INFO] report_generate_docs.bat runs the standalone documentation generator.
echo [INFO] One Source report automation scripts (10~13) were removed.
echo [INFO] This docs flow uses the heuristic documentation parser.
echo.

echo ============================================================================
echo      HDL Documentation Generator (Verilog/SystemVerilog)
echo ============================================================================
echo Target: %TARGET_PROJECT%
echo.

if not exist "%TEMPLATES_ROOT%\contexts\reporting\adapters\cli\report_generate_doc_cli.js" (
    echo [Error] Tool script not found in canonical reporting context.
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

call :prompt_run_or_cancel
if errorlevel %USER_CANCEL_RC% exit /b %USER_CANCEL_RC%

:: Run Documentation Tool with strict manifest context
node "%TEMPLATES_ROOT%\contexts\reporting\adapters\cli\report_generate_doc_cli.js" "%TARGET_PROJECT%" --manifest-json "%MANIFEST_JSON%"

if errorlevel 1 (
    echo [FAILURE] Documentation generation failed.
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

echo.
echo [SUCCESS] Documentation generated for %TARGET_PROJECT%
call "%CONSOLE_HELPER%" pause_then_clear
exit /b 0

:prompt_run_or_cancel
echo.
set "RUN_INPUT="
set /p "RUN_INPUT=Press Enter to continue, or Q to return to menu: "
if /i "%RUN_INPUT%"=="Q" exit /b %USER_CANCEL_RC%
exit /b 0
