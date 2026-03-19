@echo off
setlocal EnableDelayedExpansion
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
set "CONSOLE_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\console_ui.bat"
set "USER_CANCEL_RC=99"

if "%~1"=="" (
    echo [ERROR] Target project path is required.
    echo Usage: %~nx0 ^<Project_Directory^>
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
set "PRESENTATION_DIR=%TARGET_PROJECT%\Presentation"

if not exist "%TARGET_PROJECT%\" (
    echo [ERROR] Target project not found: %TARGET_PROJECT%
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

if not exist "%PRESENTATION_DIR%\" (
    echo [ERROR] Presentation directory not found: %PRESENTATION_DIR%
    echo [INFO] Run report_generate_presentation.bat first.
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

set "TARGET_HTML="
for /f "usebackq delims=" %%F in (`powershell -NoProfile -Command "$dir='%PRESENTATION_DIR%'; $f = Get-ChildItem -Path $dir -File -Filter 'presentation_*.html' | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if (-not $f) { $f = Get-ChildItem -Path $dir -File -Filter '*.html' | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }; if ($f) { $f.FullName }"`) do (
    set "TARGET_HTML=%%F"
)

if not defined TARGET_HTML (
    echo [ERROR] No presentation HTML file found in: %PRESENTATION_DIR%
    echo [INFO] Run report_generate_presentation.bat first.
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

call :prompt_run_or_cancel
if errorlevel %USER_CANCEL_RC% exit /b %USER_CANCEL_RC%

echo [INFO] Opening: !TARGET_HTML!
start "" "!TARGET_HTML!"
call "%CONSOLE_HELPER%" pause_then_clear
exit /b 0

:prompt_run_or_cancel
echo.
set "RUN_INPUT="
set /p "RUN_INPUT=Press Enter to continue, or Q to return to menu: "
if /i "%RUN_INPUT%"=="Q" exit /b %USER_CANCEL_RC%
exit /b 0
