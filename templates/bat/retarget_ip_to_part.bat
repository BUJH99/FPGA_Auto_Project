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

echo [INFO] Retargeting IP to project_build_config.tcl part...
vivado -mode batch -source "%~dp0..\tcl\retarget_ip_to_part.tcl" -notrace -nojournal -log ./output/retarget_ip_to_part.log
if %errorlevel% neq 0 (
    echo [ERROR] Retarget IP failed. Check output/retarget_ip_to_part.log
    exit /b %errorlevel%
)

echo [DONE] IP retarget complete.
endlocal
