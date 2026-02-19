@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "TARGET_PROJECT="
set "NO_PAUSE=0"
set "PY_ARGS="

:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="--no-pause" (
    set "NO_PAUSE=1"
) else if not defined TARGET_PROJECT (
    set "TARGET_PROJECT=%~f1"
) else (
    set "PY_ARGS=!PY_ARGS! %~1"
)
shift
goto parse_args

:args_done
if not defined TARGET_PROJECT (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^> [--step N] [--max-signals N] [--html^|--no-html] [--no-pause]
    if "%NO_PAUSE%"=="0" pause
    exit /b 1
)

if not exist "%TARGET_PROJECT%" (
    echo [ERROR] Target project not found: %TARGET_PROJECT%
    if "%NO_PAUSE%"=="0" pause
    exit /b 1
)

for %%I in ("%TARGET_PROJECT%\..") do set "REPO_ROOT=%%~fI"
set "PY_SCRIPT=%REPO_ROOT%\vcd2sgv\vcd2wavedrom_interactive.py"

if not exist "%PY_SCRIPT%" (
    echo [ERROR] Interactive WaveDrom tool not found: %PY_SCRIPT%
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
echo [VCD -^> WaveDrom] Interactive VCD mode
echo Target : %TARGET_PROJECT%
echo Tool   : %PY_SCRIPT%
if not "%PY_ARGS%"=="" echo Args   :%PY_ARGS%
echo ===============================================================================
echo.

python "%PY_SCRIPT%" "%TARGET_PROJECT%" %PY_ARGS%
set "RC=%errorlevel%"

if not "%RC%"=="0" (
    echo.
    echo [FAIL] WaveDrom generation failed ^(rc=%RC%^)
    if "%NO_PAUSE%"=="0" pause
    exit /b %RC%
)

echo.
echo [DONE] WaveDrom generation completed.
if "%NO_PAUSE%"=="0" pause
exit /b 0
