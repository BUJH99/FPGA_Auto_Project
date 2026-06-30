@echo off
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
for %%I in ("%TEMPLATES_ROOT%\..") do set "REPO_ROOT=%%~fI"
set "SETTINGS_CLI=%TEMPLATES_ROOT%\contexts\settings\adapters\cli\fpga_claw_settings_cli.js"

if not exist "%SETTINGS_CLI%" (
    echo [ERROR] Settings CLI not found: %SETTINGS_CLI%
    exit /b 1
)

where node >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Node.js is required for FPGAClaw Settings.
    exit /b 1
)

node "%SETTINGS_CLI%" --repo-root "%REPO_ROOT%" --tui
exit /b %errorlevel%
