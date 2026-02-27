@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"

set "TARGET_PROJECT="
set "NO_PAUSE=0"

:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="--no-pause" (
    set "NO_PAUSE=1"
) else if not defined TARGET_PROJECT (
    set "TARGET_PROJECT=%~f1"
) else (
    echo [WARNING] Ignoring extra argument: %~1
)
shift
goto parse_args

:args_done
if not defined TARGET_PROJECT (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^> [--no-pause]
    if "%NO_PAUSE%"=="0" pause
    exit /b 1
)

if not exist "%TARGET_PROJECT%" (
    echo [ERROR] Target project not found: %TARGET_PROJECT%
    if "%NO_PAUSE%"=="0" pause
    exit /b 1
)

set "MANIFEST_CTX=%TEMPLATES_ROOT%\shared\adapters\bat\bootstrap_manifest_context.bat"
if exist "%MANIFEST_CTX%" (
    call "%MANIFEST_CTX%" "%TARGET_PROJECT%"
    if errorlevel 1 (
        echo [ERROR] Manifest context initialization failed.
        if "%NO_PAUSE%"=="0" pause
        exit /b 1
    )
)

for %%I in ("%TEMPLATES_ROOT%\..") do set "REPO_ROOT=%%~fI"
set "PY_SCRIPT=%REPO_ROOT%\templates\vcd2sgv\vcd2svg_interactive.py"

if not exist "%PY_SCRIPT%" (
    echo [ERROR] Interactive SVG tool not found: %PY_SCRIPT%
    if "%NO_PAUSE%"=="0" pause
    exit /b 1
)

where python >nul 2>nul
if errorlevel 1 (
    echo [ERROR] python not found in PATH.
    if "%NO_PAUSE%"=="0" pause
    exit /b 1
)

echo ===============================================================================
echo [VCD -^> SVG] Interactive mode
echo Target : %TARGET_PROJECT%
echo Tool   : %PY_SCRIPT%
echo ===============================================================================
echo.

python "%PY_SCRIPT%" "%TARGET_PROJECT%"
set "RC=%errorlevel%"

if not "%RC%"=="0" (
    echo.
    echo [FAIL] SVG generation failed ^(rc=%RC%^)
    if "%NO_PAUSE%"=="0" pause
    exit /b %RC%
)

echo.
echo [DONE] Interactive SVG generation completed.
if "%NO_PAUSE%"=="0" pause
exit /b 0
