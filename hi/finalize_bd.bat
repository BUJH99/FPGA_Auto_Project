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

echo [INFO] Finalizing block design and wrapper...
vivado -mode batch -source ./scripts/finalize_bd.tcl -notrace -nojournal -log ./output/finalize_bd.log
if %errorlevel% neq 0 (
    echo [ERROR] Finalize failed. Check output/finalize_bd.log
    popd
    exit /b %errorlevel%
)

echo [DONE] BD finalized. No wrapper generated.
popd
endlocal
