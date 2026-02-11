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

where vivado >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] Vivado executable not found in PATH.
    echo         Please add Vivado bin directory to your System PATH.
    exit /b 1
)

echo [INFO] Launching Vivado GUI with IP Integrator...
vivado -mode gui -source "%~dp0..\tcl\launch_ipi_gui.tcl" -notrace -nojournal
endlocal
