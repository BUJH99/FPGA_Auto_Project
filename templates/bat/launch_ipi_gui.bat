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
set "LOG_DIR=%TARGET_PROJECT%\log"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
set "GUI_LOG=%LOG_DIR%\vivado_ipi_gui.log"
set "GUI_JOU=%LOG_DIR%\vivado_ipi_gui.jou"
call :route_vivado_artifacts

where vivado >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] Vivado executable not found in PATH.
    echo         Please add Vivado bin directory to your System PATH.
    exit /b 1
)

echo [INFO] Launching Vivado GUI with IP Integrator...
vivado -mode gui -source "%~dp0..\tcl\launch_ipi_gui.tcl" -notrace -log "%GUI_LOG%" -journal "%GUI_JOU%"
call :route_vivado_artifacts
endlocal
exit /b 0

:route_vivado_artifacts
for %%F in (vivado.log vivado.jou vivado.pb vivado.str) do (
    if exist "%%F" move /y "%%F" "%LOG_DIR%\" >nul 2>&1
)
for %%F in (*.backup.log *.backup.jou *.backup.str) do (
    if exist "%%F" move /y "%%F" "%LOG_DIR%\" >nul 2>&1
)
exit /b 0
