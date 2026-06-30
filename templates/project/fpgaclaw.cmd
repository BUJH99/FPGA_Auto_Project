@echo off
setlocal EnableExtensions
set "FPGA_CLAW_LAUNCH_CWD=%CD%"
set "FPGA_CLAW_PROJECT_DIR=%~dp0"
for %%I in ("%FPGA_CLAW_PROJECT_DIR%.") do set "FPGA_CLAW_PROJECT_DIR=%%~fI"

if not exist "%FPGA_CLAW_PROJECT_DIR%\fpga_auto.yml" (
    echo [ERROR] This launcher must be placed in an FPGAClaw project root.
    echo [ERROR] Missing: %FPGA_CLAW_PROJECT_DIR%\fpga_auto.yml
    endlocal
    exit /b 1
)

if not exist "%FPGA_CLAW_PROJECT_DIR%\src" (
    echo [ERROR] This launcher must be placed in an FPGAClaw project root.
    echo [ERROR] Missing: %FPGA_CLAW_PROJECT_DIR%\src
    endlocal
    exit /b 1
)

for %%I in ("%FPGA_CLAW_PROJECT_DIR%\..") do set "PROJECT_ROOT=%%~fI"
for %%I in ("%FPGA_CLAW_PROJECT_DIR%") do set "FPGA_CLAW_PROJECT_NAME=%%~nxI"
set "TARGET_PROJECT_ABS=%FPGA_CLAW_PROJECT_DIR%"
set "TARGET_PROJECT=..\Project\%FPGA_CLAW_PROJECT_NAME%"

set "FPGA_CLAW_LAUNCH_REPO="
if defined FPGA_CLAW_REPO_ROOT if exist "%FPGA_CLAW_REPO_ROOT%\MAIN.bat" set "FPGA_CLAW_LAUNCH_REPO=%FPGA_CLAW_REPO_ROOT%"
if not defined FPGA_CLAW_LAUNCH_REPO (
    for %%I in ("%FPGA_CLAW_PROJECT_DIR%\..\FPGA_Auto_Project") do if exist "%%~fI\MAIN.bat" set "FPGA_CLAW_LAUNCH_REPO=%%~fI"
)
if not defined FPGA_CLAW_LAUNCH_REPO (
    set "FPGA_CLAW_EMBEDDED_REPO=__FPGA_CLAW_REPO_ROOT__"
    if exist "%FPGA_CLAW_EMBEDDED_REPO%\MAIN.bat" set "FPGA_CLAW_LAUNCH_REPO=%FPGA_CLAW_EMBEDDED_REPO%"
)

if not defined FPGA_CLAW_LAUNCH_REPO (
    echo [ERROR] FPGAClaw automation repo was not found.
    echo [ERROR] Set FPGA_CLAW_REPO_ROOT or refresh this launcher with MAIN.bat ^> [U] Upgrade.
    endlocal
    exit /b 1
)

set "FPGA_CLAW_REPO_ROOT=%FPGA_CLAW_LAUNCH_REPO%"
call "%FPGA_CLAW_LAUNCH_REPO%\MAIN.bat" %*
set "RC=%errorlevel%"
endlocal & exit /b %RC%
