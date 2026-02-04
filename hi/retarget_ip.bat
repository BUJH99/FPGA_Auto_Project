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

echo [INFO] Retargeting IP to build_config.tcl part...
vivado -mode batch -source ./scripts/retarget_ip.tcl -notrace -nojournal -log ./output/retarget_ip.log
if %errorlevel% neq 0 (
    echo [ERROR] Retarget IP failed. Check output/retarget_ip.log
    popd
    exit /b %errorlevel%
)

echo [DONE] IP retarget complete.
popd
endlocal
