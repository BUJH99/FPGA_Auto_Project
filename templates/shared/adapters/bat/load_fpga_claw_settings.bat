@echo off
set "FPGA_CLAW_SETTINGS_SCRIPT_DIR=%~dp0"
for %%I in ("%FPGA_CLAW_SETTINGS_SCRIPT_DIR%..\..\..") do set "FPGA_CLAW_SETTINGS_TEMPLATES_ROOT=%%~fI"
for %%I in ("%FPGA_CLAW_SETTINGS_TEMPLATES_ROOT%\..") do set "FPGA_CLAW_SETTINGS_REPO_ROOT=%%~fI"
set "FPGA_CLAW_SETTINGS_CLI=%FPGA_CLAW_SETTINGS_TEMPLATES_ROOT%\contexts\settings\adapters\cli\fpga_claw_settings_cli.js"

if not exist "%FPGA_CLAW_SETTINGS_CLI%" exit /b 0
where node >nul 2>nul
if errorlevel 1 exit /b 0

set "FPGA_CLAW_SETTINGS_TEMP=%TEMP%\fpga_claw_settings_%RANDOM%_%RANDOM%.cmd"
node "%FPGA_CLAW_SETTINGS_CLI%" --repo-root "%FPGA_CLAW_SETTINGS_REPO_ROOT%" --emit-bat > "%FPGA_CLAW_SETTINGS_TEMP%"
if errorlevel 1 (
    if exist "%FPGA_CLAW_SETTINGS_TEMP%" del /q "%FPGA_CLAW_SETTINGS_TEMP%" >nul 2>nul
    exit /b 0
)

call "%FPGA_CLAW_SETTINGS_TEMP%"
if exist "%FPGA_CLAW_SETTINGS_TEMP%" del /q "%FPGA_CLAW_SETTINGS_TEMP%" >nul 2>nul
exit /b 0
