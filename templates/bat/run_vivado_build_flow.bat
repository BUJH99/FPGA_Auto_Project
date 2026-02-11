@echo off
setlocal enabledelayedexpansion

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^>
    pause
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
cd /d "%TARGET_PROJECT%"
title Vivado Automation Flow - %TARGET_PROJECT%

cls
echo.
echo ===============================================================================
echo  [START] Vivado Automation Flow
echo  Target: %TARGET_PROJECT%
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

call vivado -mode batch -source "%~dp0..\tcl\run_vivado_build_flow.tcl" -log ./output/vivado_full_build.log -nojournal -notrace

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
echo  [INFO] Extracting RTL Hierarchy (diagram/report source data)...
echo ===============================================================================
echo.

call vivado -mode batch -source "%~dp0..\tcl\export_rtl_hierarchy_mermaid.tcl" -notrace -nojournal -log ./output/rtl_hier.log
if %errorlevel% neq 0 (
    echo [WARNING] RTL hierarchy extraction failed. Check output/rtl_hier.log
)

echo.
echo ===============================================================================
echo  [REPORT] Generating Final Build Report...
echo ===============================================================================
echo.

call vivado -mode batch -source "%~dp0..\tcl\generate_html_report.tcl" -tclargs "%TARGET_PROJECT%" -notrace -nojournal -log ./output/report_gen.log
if %errorlevel% neq 0 (
    echo [WARNING] Report generation script returned an error.
)

if exist output\Final_Build_Report.html (
    echo      - Report generated: %TARGET_PROJECT%\output\Final_Build_Report.html
) else (
    echo      - [WARNING] Failed to generate report.
)

echo.
echo ===============================================================================
echo  [PROMPT] Run FPGA Device Programming?
echo ===============================================================================
echo.

if exist "%~dp0program_fpga_device.bat" (
    choice /C YN /N /M "Run program_fpga_device.bat now? [Y/N]: "
    if errorlevel 2 (
        echo [INFO] Device programming skipped by user.
        set "PROGRAM_STATUS=SKIPPED_BY_USER"
    ) else (
        call "%~dp0program_fpga_device.bat" "%TARGET_PROJECT%" --no-pause
        if !errorlevel! neq 0 (
            echo [WARNING] program_fpga_device.bat failed.
            set "PROGRAM_STATUS=FAILED"
        ) else (
            echo [INFO] Device programming completed.
            set "PROGRAM_STATUS=SUCCESS"
        )
    )
) else (
    echo [WARNING] program_fpga_device.bat not found in templates.
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
