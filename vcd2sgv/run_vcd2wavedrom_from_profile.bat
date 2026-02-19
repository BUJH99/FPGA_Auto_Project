@echo off
setlocal EnableExtensions

if "%~1"=="" (
    echo Usage: %~nx0 ^<project_dir^> [options]
    echo Example:
    echo   %~nx0 Sensor_Uart --all --step 20000
    echo   %~nx0 Sensor_Uart --profiles tb_control_unit,tb_button_sync
    exit /b 1
)

python "%~dp0vcd2wavedrom_from_profile.py" %*
exit /b %errorlevel%
