@echo off
setlocal EnableDelayedExpansion
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
set "USER_CANCEL_RC=99"

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^> [clean-assets]
    pause
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
set "PY_TOOL=%TEMPLATES_ROOT%\contexts\reporting\adapters\python\report_generate_presentation.py"
set "TEMPLATE_FILE=%TEMPLATES_ROOT%\contexts\reporting\presentation\presentation_module_verification_template.html.j2"
set "MANIFEST_CTX=%TEMPLATES_ROOT%\shared\adapters\bat\bootstrap_manifest_context.bat"

if exist "%MANIFEST_CTX%" (
    call "%MANIFEST_CTX%" "%TARGET_PROJECT%"
    if errorlevel 1 (
        echo [ERROR] Manifest context initialization failed.
        pause
        exit /b 1
    )
)

echo ============================================================================
echo      HTML Presentation Generator (Python + Jinja2)
echo ============================================================================
echo Target: %TARGET_PROJECT%
echo.

if not exist "%PY_TOOL%" (
    echo [ERROR] Tool script not found: %PY_TOOL%
    pause
    exit /b 1
)

if not exist "%TEMPLATE_FILE%" (
    echo [ERROR] Template file not found: %TEMPLATE_FILE%
    pause
    exit /b 1
)

set "PY_CMD="
where py >nul 2>nul
if !errorlevel! equ 0 (
    set "PY_CMD=py -3"
) else (
    where python >nul 2>nul
    if !errorlevel! equ 0 (
        set "PY_CMD=python"
    )
)

if not defined PY_CMD (
    echo [ERROR] Python was not found in PATH.
    pause
    exit /b 1
)

%PY_CMD% -c "import jinja2" >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Jinja2 is not available for this Python.
    echo [INFO] Install with: %PY_CMD% -m pip install jinja2
    pause
    exit /b 1
)

set "CLEAN_ARG="
set "CLEAN_INPUT=%~2"
if "!CLEAN_INPUT!"=="" (
    set /p "CLEAN_INPUT=Clean existing Presentation\assets before generation? [Y/N/Q, default N]: "
)
if /i "!CLEAN_INPUT!"=="Q" exit /b %USER_CANCEL_RC%
if /i "!CLEAN_INPUT!"=="Y" set "CLEAN_ARG=--clean-assets"
if /i "!CLEAN_INPUT!"=="YES" set "CLEAN_ARG=--clean-assets"
if /i "!CLEAN_INPUT!"=="--clean-assets" set "CLEAN_ARG=--clean-assets"

for %%I in ("%TARGET_PROJECT%") do set "PRESENTATION_DIR=%%~fI\Presentation"
set "TS="
for /f %%T in ('powershell -NoProfile -Command "(Get-Date).ToString(\"yyyyMMdd_HHmmss\")"') do set "TS=%%T"
if "!TS!"=="" (
    echo [ERROR] Failed to create timestamp string.
    pause
    exit /b 1
)
for %%I in ("%TARGET_PROJECT%") do set "PROJECT_NAME=%%~nI"
set "OUTPUT_HTML=!PRESENTATION_DIR!\presentation_!PROJECT_NAME!_!TS!.html"

%PY_CMD% "%PY_TOOL%" --project "%TARGET_PROJECT%" --manifest-json "%MANIFEST_JSON%" --template "%TEMPLATE_FILE%" --output-html "!OUTPUT_HTML!" !CLEAN_ARG!
if errorlevel 1 (
    echo.
    echo [FAILURE] HTML presentation generation failed.
    pause
    exit /b 1
)

echo.
echo [SUCCESS] Presentation generation completed.
echo [INFO] HTML: !OUTPUT_HTML!
pause
exit /b 0
