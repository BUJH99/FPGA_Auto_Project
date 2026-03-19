@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
set "CONSOLE_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\console_ui.bat"

set "NO_PAUSE=0"
set "INFER_GLOBS=0"
if /i "%~1"=="--no-pause" set "NO_PAUSE=1"
if /i "%~1"=="--infer-globs" set "INFER_GLOBS=1"
if /i "%~2"=="--no-pause" set "NO_PAUSE=1"
if /i "%~2"=="--infer-globs" set "INFER_GLOBS=1"

for %%I in ("%TEMPLATES_ROOT%\..") do set "REPO_ROOT=%%~fI"
set "MIGRATE_TOOL=%TEMPLATES_ROOT%\contexts\project_bootstrap\adapters\cli\project_migrate_legacy_cli.js"

if not exist "%MIGRATE_TOOL%" (
    echo [ERROR] Migration tool not found: %MIGRATE_TOOL%
    if "%NO_PAUSE%"=="0" call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

where node >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Node.js is required.
    if "%NO_PAUSE%"=="0" call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

pushd "%REPO_ROOT%" >nul 2>nul
if "%INFER_GLOBS%"=="1" (
    node "%MIGRATE_TOOL%" --repo "%REPO_ROOT%" --infer-globs
) else (
    node "%MIGRATE_TOOL%" --repo "%REPO_ROOT%"
)
set "RC=%errorlevel%"
popd >nul 2>nul

if not "%RC%"=="0" (
    echo [ERROR] Migration finished with failures. rc=%RC%
) else (
    echo [DONE] Migration completed successfully.
)

if "%NO_PAUSE%"=="0" call "%CONSOLE_HELPER%" pause_then_clear
exit /b %RC%
