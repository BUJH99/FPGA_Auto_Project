@echo off
setlocal enabledelayedexpansion
title Vivado Automation Flow

cls
echo.
echo ===============================================================================
echo  [START] Vivado Automation Flow
echo ===============================================================================
echo.

echo [CHECK] Verifying Vivado Environment...
where vivado >nul 2>nul
if %errorlevel% neq 0 (
    echo.
    echo [ERROR] Vivado executable not found in PATH.
    echo         Please add Vivado bin directory to your System PATH.
    echo.
    pause
    exit /b 1
)
echo      - Vivado found.

if exist output (
    echo [CLEAN] Cleaning up previous output directory...
    rmdir /s /q output
)
mkdir output
echo      - Output directory ready.

echo.
echo ===============================================================================
echo  [EXEC] Running Vivado Batch Build (Synthesis/Implementation/Bitstream)...
echo         (Please wait. Check log for details.)
echo ===============================================================================
echo.

call vivado -mode batch -source ./scripts/run_full_flow.tcl -log ./output/vivado_full_build.log -nojournal -notrace

if %errorlevel% neq 0 (
    echo.
    echo ###############################################################################
    echo #                                                                             #
    echo #                          [FAIL] BUILD FAILED                                #
    echo #                                                                             #
    echo ###############################################################################
    echo.
    echo [ERROR] Please check the log file: output/vivado_full_build.log
    echo.
    pause
    exit /b %errorlevel%
)

set "PROGRAM_STATUS=SKIPPED"
echo.
echo ===============================================================================
echo  [EXEC] Auto Programming FPGA Device (immediately after build)...
echo ===============================================================================
echo.

if exist program_device.bat (
    call program_device.bat
    if !errorlevel! neq 0 (
        echo [WARNING] program_device.bat failed. Continuing to report/diagram steps.
        set "PROGRAM_STATUS=FAILED"
    ) else (
        echo [INFO] Device programming completed.
        set "PROGRAM_STATUS=SUCCESS"
    )
) else (
    echo [WARNING] program_device.bat not found. Skipping device programming.
)

echo.
echo ===============================================================================
echo  [INFO] Extracting RTL Hierarchy (diagram/report source data)...
echo ===============================================================================
echo.

call vivado -mode batch -source ./scripts/export_rtl_hierarchy.tcl -notrace -nojournal -log ./output/rtl_hier.log
if %errorlevel% neq 0 (
    echo [WARNING] RTL hierarchy extraction failed. Check output/rtl_hier.log
)

echo.
echo ===============================================================================
echo  [REPORT] Generating Final Build Report...
echo ===============================================================================
echo.

call vivado -mode batch -source ./scripts/generate_report.tcl -notrace -nojournal -log ./output/report_gen.log
if %errorlevel% neq 0 (
    echo [WARNING] Report generation script returned an error.
)

if exist output\Final_Build_Report.html (
    echo      - Report generated: output\Final_Build_Report.html
) else (
    echo      - [WARNING] Failed to generate report.
)

echo.
echo ###############################################################################
echo #                                                                             #
echo #                       Automation Flow Completed                             #
echo #                                                                             #
echo ###############################################################################
echo.
echo [INFO] Bitstream location: %CD%\output
echo [INFO] Build Report      : %CD%\output\Final_Build_Report.html
echo [INFO] Program Device    : %PROGRAM_STATUS%
echo.
echo ===============================================================================
echo  All tasks completed. Press any key to close this window...
echo ===============================================================================
pause >nul
