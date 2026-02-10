@echo off
setlocal
cd /d "%~dp0.."

echo ===============================================================================
echo  [REPORT] Generating HTML Report from existing logs...
echo ===============================================================================

:: Check for reports directory
if not exist "output\reports" (
    echo.
    echo [ERROR] 'output\reports' directory not found.
    echo         This script parses existing Vivado reports.
    echo         Please run 'run_vivado_build_flow.bat' first to generate raw reports.
    echo.
    pause
    exit /b 1
)

:: Run the Tcl script
call vivado -mode batch -source ./tcl/generate_html_report.tcl -notrace -nojournal -log ./output/report_gen_standalone.log

if %errorlevel% neq 0 (
    echo.
    echo [ERROR] Report generation failed. Check output\report_gen_standalone.log used.
    pause
    exit /b %errorlevel%
)

echo.
echo [SUCCESS] Report generated: output\Final_Build_Report.html
echo.
pause
