@echo off
setlocal EnableDelayedExpansion
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^>
    pause
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
set "MANIFEST_CTX=%TEMPLATES_ROOT%\shared\adapters\bat\bootstrap_manifest_context.bat"

if exist "%MANIFEST_CTX%" (
    call "%MANIFEST_CTX%" "%TARGET_PROJECT%"
    if errorlevel 1 (
        echo [ERROR] Manifest context initialization failed.
        pause
        exit /b 1
    )
)

echo [LEGACY] legacy_docs_generate.bat uses the old documentation generator.
echo [LEGACY] One Source report automation scripts (10~13) were removed.
echo [LEGACY] This script remains available as standalone legacy docs flow.
echo.

echo ============================================================================
echo      HDL Documentation Generator (Verilog/SystemVerilog)
echo ============================================================================
echo Target: %TARGET_PROJECT%
echo.

if not exist "%TEMPLATES_ROOT%\contexts\reporting\adapters\cli\report_generate_doc_cli.js" (
    echo [Error] Tool script not found in canonical reporting context.
    pause
    exit /b 1
)

:: Run Documentation Tool with strict manifest context
node "%TEMPLATES_ROOT%\contexts\reporting\adapters\cli\report_generate_doc_cli.js" "%TARGET_PROJECT%" --manifest-json "%MANIFEST_JSON%"

if errorlevel 1 (
    echo [FAILURE] Documentation generation failed.
    pause
    exit /b 1
)

echo.
echo [SUCCESS] Documentation generated for %TARGET_PROJECT%
pause
