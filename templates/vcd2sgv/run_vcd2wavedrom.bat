@echo off
setlocal EnableExtensions

if "%~2"=="" (
    echo Usage: %~nx0 ^<input.vcd^> ^<output.json^> [options]
    echo Example:
    echo   %~nx0 Sensor_Uart\output\iverilog\vcd\tb_dht11_controller.vcd out.json --signals tb_dht11_controller.iRst,tb_dht11_controller.oDataValid --to-time 5000000 --html out.html
    exit /b 1
)

python "%~dp0vcd2wavedrom.py" %*
exit /b %errorlevel%
