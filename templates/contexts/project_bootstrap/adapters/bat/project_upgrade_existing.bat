@echo off
setlocal EnableExtensions
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
set "CONSOLE_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\console_ui.bat"
set "PROJECT_ROOT_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\resolve_managed_project_root.bat"

set "NO_PAUSE=0"
set "DRY_RUN=0"
set "PROJECT_SELECTOR="

:PARSE_ARGS
if "%~1"=="" goto PARSE_DONE
if /i "%~1"=="--no-pause" goto PARSE_NO_PAUSE
if /i "%~1"=="--dry-run" goto PARSE_DRY_RUN
if /i "%~1"=="--project" goto PARSE_PROJECT
if defined PROJECT_SELECTOR goto PARSE_EXTRA_ARG
set "PROJECT_SELECTOR=%~1"
shift
goto PARSE_ARGS

:PARSE_NO_PAUSE
set "NO_PAUSE=1"
shift
goto PARSE_ARGS

:PARSE_DRY_RUN
set "DRY_RUN=1"
shift
goto PARSE_ARGS

:PARSE_PROJECT
shift
if not "%~1"=="" goto PARSE_PROJECT_VALUE
echo [ERROR] --project requires a value.
exit /b 2

:PARSE_PROJECT_VALUE
set "PROJECT_SELECTOR=%~1"
shift
goto PARSE_ARGS

:PARSE_EXTRA_ARG
echo [WARNING] Ignoring extra argument: %~1
shift
goto PARSE_ARGS

:PARSE_DONE
for %%I in ("%TEMPLATES_ROOT%\..") do set "REPO_ROOT=%%~fI"
set "UPGRADE_TOOL=%TEMPLATES_ROOT%\contexts\project_bootstrap\adapters\cli\project_upgrade_cli.js"
if exist "%PROJECT_ROOT_HELPER%" call "%PROJECT_ROOT_HELPER%" "%REPO_ROOT%"
if defined FPGA_AUTO_PROJECT_ROOT (
    set "PROJECT_ROOT=%FPGA_AUTO_PROJECT_ROOT%"
) else (
    for %%I in ("%REPO_ROOT%\..") do set "PROJECT_ROOT=%%~fI\Project"
)

if not exist "%UPGRADE_TOOL%" (
    echo [ERROR] Upgrade tool not found: %UPGRADE_TOOL%
    if "%NO_PAUSE%"=="0" call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

where node >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Node.js is required.
    if "%NO_PAUSE%"=="0" call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

echo [INFO] Project root: %PROJECT_ROOT%
if defined PROJECT_SELECTOR echo [INFO] Target project: %PROJECT_SELECTOR%
if "%DRY_RUN%"=="1" echo [INFO] Dry run enabled. No project files will be modified.

pushd "%REPO_ROOT%" >nul 2>nul
if "%DRY_RUN%"=="1" goto RUN_DRY_RUN
if defined PROJECT_SELECTOR goto RUN_TARGET
node "%UPGRADE_TOOL%" --repo "%REPO_ROOT%" --project-root "%PROJECT_ROOT%"
set "RC=%errorlevel%"
goto RUN_DONE

:RUN_TARGET
node "%UPGRADE_TOOL%" --repo "%REPO_ROOT%" --project-root "%PROJECT_ROOT%" --project "%PROJECT_SELECTOR%"
set "RC=%errorlevel%"
goto RUN_DONE

:RUN_DRY_RUN
if defined PROJECT_SELECTOR goto RUN_DRY_RUN_TARGET
node "%UPGRADE_TOOL%" --repo "%REPO_ROOT%" --project-root "%PROJECT_ROOT%" --dry-run
set "RC=%errorlevel%"
goto RUN_DONE

:RUN_DRY_RUN_TARGET
node "%UPGRADE_TOOL%" --repo "%REPO_ROOT%" --project-root "%PROJECT_ROOT%" --project "%PROJECT_SELECTOR%" --dry-run
set "RC=%errorlevel%"

:RUN_DONE
popd >nul 2>nul

if not "%RC%"=="0" (
    echo [ERROR] Project upgrade finished with failures. rc=%RC%
) else (
    echo [DONE] Project upgrade completed successfully.
)

if "%NO_PAUSE%"=="0" call "%CONSOLE_HELPER%" pause_then_clear
exit /b %RC%
