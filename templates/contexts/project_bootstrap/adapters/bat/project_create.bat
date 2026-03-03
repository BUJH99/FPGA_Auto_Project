@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"

set "SYNC_BAT=%TEMPLATES_ROOT%\..\SyncProjectsToSourceProject.bat"
set "MANIFEST_TEMPLATE=%TEMPLATES_ROOT%\manifest\fpga_auto.template.yml"
set "NO_PAUSE=0"
set "SETUP_RC=0"
set "PROJECT_NAME="
set "HAS_INPUT_NAME=0"
set "HDL_EXT=v"

:PARSE_ARGS
if "%~1"=="" goto PARSE_DONE
if /i "%~1"=="--no-pause" (
    set "NO_PAUSE=1"
) else if /i "%~1"=="--hdl-ext" (
    shift
    if /i "%~1"=="sv" set "HDL_EXT=sv"
    if /i "%~1"=="v" set "HDL_EXT=v"
) else if /i "%~1"=="--hdl-ext=sv" (
    set "HDL_EXT=sv"
) else if /i "%~1"=="--hdl-ext=v" (
    set "HDL_EXT=v"
) else if not defined PROJECT_NAME (
    set "PROJECT_NAME=%~1"
    set "HAS_INPUT_NAME=1"
) else (
    echo [WARNING] Ignoring extra argument: %~1
)
shift
goto PARSE_ARGS

:PARSE_DONE
if /i not "%HDL_EXT%"=="v" if /i not "%HDL_EXT%"=="sv" set "HDL_EXT=v"

pushd "%TEMPLATES_ROOT%\.." >nul 2>nul
set "REPO_ROOT=%CD%"
popd >nul 2>nul
set "PROJECT_ROOT=%REPO_ROOT%\Project"
if not exist "%PROJECT_ROOT%" mkdir "%PROJECT_ROOT%" >nul 2>nul

if not defined PROJECT_NAME goto PROMPT
goto CREATE

:PROMPT
set /p PROJECT_NAME="Enter project name: "
if not defined PROJECT_NAME goto PROMPT

:CREATE
set "TARGET_PROJECT=%PROJECT_ROOT%\%PROJECT_NAME%"
if exist "%TARGET_PROJECT%" (
    echo [ERROR] "%TARGET_PROJECT%" already exists. Please use a different name.
    if "%HAS_INPUT_NAME%"=="1" (
        set "SETUP_RC=1"
        goto END
    )
    set "PROJECT_NAME="
    goto PROMPT
)

mkdir "%TARGET_PROJECT%" >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Failed to create project directory: %TARGET_PROJECT%
    set "SETUP_RC=1"
    goto END
)

echo [INFO] Creating standardized project directories...
if not exist "%TARGET_PROJECT%\constrs" mkdir "%TARGET_PROJECT%\constrs"
if not exist "%TARGET_PROJECT%\ip" mkdir "%TARGET_PROJECT%\ip"
if not exist "%TARGET_PROJECT%\md" mkdir "%TARGET_PROJECT%\md"
if not exist "%TARGET_PROJECT%\output" mkdir "%TARGET_PROJECT%\output"
if not exist "%TARGET_PROJECT%\output\docs" mkdir "%TARGET_PROJECT%\output\docs"
if not exist "%TARGET_PROJECT%\output\Diagram" mkdir "%TARGET_PROJECT%\output\Diagram"
if not exist "%TARGET_PROJECT%\output\Diagram\Simple" mkdir "%TARGET_PROJECT%\output\Diagram\Simple"
if not exist "%TARGET_PROJECT%\output\Diagram\Detailed" mkdir "%TARGET_PROJECT%\output\Diagram\Detailed"
if not exist "%TARGET_PROJECT%\output\Diagram\JSON" mkdir "%TARGET_PROJECT%\output\Diagram\JSON"
if not exist "%TARGET_PROJECT%\output\FINALReport" mkdir "%TARGET_PROJECT%\output\FINALReport"
if not exist "%TARGET_PROJECT%\output\fsm" mkdir "%TARGET_PROJECT%\output\fsm"
if not exist "%TARGET_PROJECT%\output\fsm\svg" mkdir "%TARGET_PROJECT%\output\fsm\svg"
if not exist "%TARGET_PROJECT%\output\fsm\drawio" mkdir "%TARGET_PROJECT%\output\fsm\drawio"
if not exist "%TARGET_PROJECT%\log" mkdir "%TARGET_PROJECT%\log"
if not exist "%TARGET_PROJECT%\report_assets" mkdir "%TARGET_PROJECT%\report_assets"
if not exist "%TARGET_PROJECT%\src" mkdir "%TARGET_PROJECT%\src"
if not exist "%TARGET_PROJECT%\skills" mkdir "%TARGET_PROJECT%\skills"
if not exist "%TARGET_PROJECT%\tb" mkdir "%TARGET_PROJECT%\tb"
if not exist "%TARGET_PROJECT%\Presentation" mkdir "%TARGET_PROJECT%\Presentation"

if not exist "%MANIFEST_TEMPLATE%" (
    echo [ERROR] Manifest template missing: %MANIFEST_TEMPLATE%
    set "SETUP_RC=1"
    goto END
)

powershell -NoProfile -Command ^
    "$tpl = Get-Content -Path '%MANIFEST_TEMPLATE%' -Raw; " ^
    "$out = $tpl.Replace('__PROJECT_NAME__', '%PROJECT_NAME%'); " ^
    "$enc = New-Object System.Text.UTF8Encoding($false); " ^
    "[System.IO.File]::WriteAllText('%TARGET_PROJECT%\fpga_auto.yml', $out, $enc);"
if errorlevel 1 (
    echo [ERROR] Failed to create fpga_auto.yml from template.
    set "SETUP_RC=1"
    goto END
)

echo.
echo ------------------------------------------------
echo [%PROJECT_NAME%] project created successfully.
echo Project root:
echo - %TARGET_PROJECT%
echo Created folders:
echo - constrs
echo - ip
echo - md
echo - output
echo - output\docs
echo - output\Diagram\Simple
echo - output\Diagram\Detailed
echo - output\Diagram\JSON
echo - output\FINALReport
echo - output\fsm\svg
echo - output\fsm\drawio
echo - log
echo - report_assets
echo - src
echo - skills
echo - tb
echo - Presentation
echo - fpga_auto.yml
echo ------------------------------------------------
echo.

if exist "%SYNC_BAT%" (
    echo [INFO] Running auto sync to SOURCE_PROJECT...
    call "%SYNC_BAT%"
    if errorlevel 1 (
        echo [WARN] Auto sync reported errors. Please check output above.
    )
)

:END
if "%NO_PAUSE%"=="1" (
    endlocal
    exit /b %SETUP_RC%
)
pause
endlocal
exit /b %SETUP_RC%
