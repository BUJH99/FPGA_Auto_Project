@echo off
setlocal
pushd %~dp0

where vivado >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] Vivado executable not found in PATH.
    echo         Please add Vivado bin directory to your System PATH.
    popd
    exit /b 1
)

echo [INFO] Launching Vivado GUI with IP Integrator...
vivado -mode gui -source ./scripts/open_ipi_gui.tcl -notrace -nojournal

popd
endlocal
