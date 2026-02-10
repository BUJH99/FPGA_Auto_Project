@echo off
setlocal
pushd "%~dp0.."

where vivado >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] Vivado executable not found in PATH.
    echo         Please add Vivado bin directory to your System PATH.
    popd
    exit /b 1
)

echo [INFO] Finalizing block design and exported artifacts...
vivado -mode batch -source ./tcl/finalize_block_design.tcl -notrace -nojournal -log ./output/finalize_block_design.log
if %errorlevel% neq 0 (
    echo [ERROR] Finalize failed. Check output/finalize_block_design.log
    popd
    exit /b %errorlevel%
)

echo [DONE] BD finalized. No wrapper generated.
popd
endlocal
