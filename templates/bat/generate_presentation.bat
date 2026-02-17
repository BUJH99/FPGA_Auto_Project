@echo off
setlocal EnableDelayedExpansion

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^>
    pause
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
set "SCRIPT_DIR=%~dp0"
set "PY_TOOL=%SCRIPT_DIR%..\tools\generate_presentation.py"

echo ============================================================================
echo      Presentation Generator (Python + Jinja2)
echo ============================================================================
echo Target: %TARGET_PROJECT%
echo.

if not exist "%TARGET_PROJECT%\src" (
    echo [ERROR] src folder not found: %TARGET_PROJECT%\src
    pause
    exit /b 1
)

if not exist "%PY_TOOL%" (
    echo [ERROR] Tool script not found: %PY_TOOL%
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
    set /p "CLEAN_INPUT=Clean existing Presentation\assets before generation? [Y/N, default N]: "
)
if /i "!CLEAN_INPUT!"=="Y" set "CLEAN_ARG=--clean-assets"
if /i "!CLEAN_INPUT!"=="YES" set "CLEAN_ARG=--clean-assets"
if /i "!CLEAN_INPUT!"=="--clean-assets" set "CLEAN_ARG=--clean-assets"

%PY_CMD% "%PY_TOOL%" --project "%TARGET_PROJECT%" !CLEAN_ARG!
if errorlevel 1 (
    echo.
    echo [FAILURE] Presentation generation failed.
    pause
    exit /b 1
)

echo.
echo [SUCCESS] Presentation generation completed.
pause
exit /b 0
