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

set "LOG_DIR=%TARGET_PROJECT%\log"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
set "PROGRAM_LOG=%LOG_DIR%\vivado_program.log"
set "PROGRAM_JOU=%LOG_DIR%\vivado_program.jou"
call :route_vivado_artifacts

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
vivado -mode batch -source "%~dp0..\tcl\program_fpga_device.tcl" -notrace -log "%PROGRAM_LOG%" -journal "%PROGRAM_JOU%"
set "PROGRAM_RC=%errorlevel%"
call :route_vivado_artifacts

if %PROGRAM_RC% neq 0 (
    echo.
    echo [!] Programming Failed! Check connection or logs in %LOG_DIR%.
    call :maybe_pause
    exit /b %PROGRAM_RC%
)

echo.
echo [Done] You can close this window.
call :maybe_pause
exit /b 0

:maybe_pause
if "%NO_PAUSE%"=="1" exit /b 0
pause
exit /b 0

:route_vivado_artifacts
for %%F in (vivado.log vivado.jou vivado.pb vivado.str) do (
    if exist "%%F" move /y "%%F" "%LOG_DIR%\" >nul 2>&1
)
for %%F in (*.backup.log *.backup.jou *.backup.str) do (
    if exist "%%F" move /y "%%F" "%LOG_DIR%\" >nul 2>&1
)
exit /b 0
