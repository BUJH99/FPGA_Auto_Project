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
set "REPORT_HTML=%TARGET_PROJECT%\output\Final_Build_Report.html"
set "REPORT_LOG=%TARGET_PROJECT%\output\report_gen_standalone.log"

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

:: Run the Tcl script (force project root path)
call vivado -mode batch -source "%~dp0..\tcl\generate_html_report.tcl" -tclargs "%TARGET_PROJECT%" -notrace -nojournal -log ./output/report_gen_standalone.log

if %errorlevel% neq 0 (
    echo.
    echo [ERROR] Report generation failed. Check "%REPORT_LOG%".
    pause
    exit /b %errorlevel%
)

echo.
echo [SUCCESS] Report generated: %REPORT_HTML%
echo.
pause
