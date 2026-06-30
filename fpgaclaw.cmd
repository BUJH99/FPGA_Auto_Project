@echo off
setlocal EnableExtensions
set "FPGA_CLAW_LAUNCH_CWD=%CD%"
set "FPGA_CLAW_REPO_ROOT=%~dp0"
for %%I in ("%FPGA_CLAW_REPO_ROOT%.") do set "FPGA_CLAW_REPO_ROOT=%%~fI"

if not exist "%FPGA_CLAW_REPO_ROOT%\MAIN.bat" (
    echo [ERROR] MAIN.bat not found under: %FPGA_CLAW_REPO_ROOT%
    endlocal
    exit /b 1
)

call "%FPGA_CLAW_REPO_ROOT%\MAIN.bat" %*
set "RC=%errorlevel%"
endlocal & exit /b %RC%
