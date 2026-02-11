@echo off
setlocal

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^>
    pause
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
cd /d "%TARGET_PROJECT%"
echo Target Project: %TARGET_PROJECT%

set "NO_PAUSE=0"
if /i "%~2"=="--no-pause" set "NO_PAUSE=1"

echo ===========================================
echo   Vivado Batch Mode - Program Device
echo ===========================================

:: Check Vivado command availability
where vivado >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] Vivado executable not found in PATH.
    call :maybe_pause
    exit /b 1
)

if not exist output mkdir output

:: Run Hardware Manager script in batch mode
vivado -mode batch -source "%~dp0..\tcl\program_fpga_device.tcl" -notrace -log ./output/vivado_program.log -nojournal

if %errorlevel% neq 0 (
    echo.
    echo [!] Programming Failed! Check connection or logs.
    call :maybe_pause
    exit /b %errorlevel%
)

echo.
echo [Done] You can close this window.
call :maybe_pause
exit /b 0

:maybe_pause
if "%NO_PAUSE%"=="1" exit /b 0
pause
exit /b 0
