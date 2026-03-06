@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
set "USER_CANCEL_RC=99"

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^>
    pause
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
set "MANIFEST_CTX=%TEMPLATES_ROOT%\shared\adapters\bat\bootstrap_manifest_context.bat"
if exist "%MANIFEST_CTX%" (
    call "%MANIFEST_CTX%" "%TARGET_PROJECT%"
    if errorlevel 1 (
        echo [ERROR] Manifest context initialization failed.
        pause
        exit /b 1
    )
)
cd /d "%TARGET_PROJECT%"
set "REPORT_DIR=%TARGET_PROJECT%\output\FINALReport"
set "REPORT_HTML=%REPORT_DIR%\Final_Build_Report.html"
set "LOG_DIR=%TARGET_PROJECT%\log"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
set "REPORT_LOG=%LOG_DIR%\report_gen_standalone.log"
set "REPORT_JOU=%LOG_DIR%\report_gen_standalone.jou"
call :route_vivado_artifacts

echo [LEGACY] This script is for Vivado build-report HTML parsing flow.
echo [LEGACY] One Source report automation scripts (10~13) were removed.
echo [LEGACY] Use this legacy script for Vivado report HTML generation.
echo.

echo ===============================================================================
echo  [REPORT] Generating HTML Report from existing logs...
echo ===============================================================================

:: Check for reports directory
if not exist "output\reports" (
    echo.
    echo [ERROR] 'output\reports' directory not found.
    echo         This script parses existing Vivado reports.
    echo         Please run 'vivado_build_flow_run.bat' first to generate raw reports.
    echo.
    pause
    exit /b 1
)

call :prompt_run_or_cancel
if %errorlevel% equ %USER_CANCEL_RC% exit /b %USER_CANCEL_RC%

:: Run the Tcl script (force project root path)
call vivado -mode batch -source "%TEMPLATES_ROOT%\contexts\reporting\adapters\tcl\report_generate_html.tcl" -tclargs "%TARGET_PROJECT%" "%MANIFEST_SRC_LIST%" -notrace -log "%REPORT_LOG%" -journal "%REPORT_JOU%"
set "REPORT_RC=%errorlevel%"
call :route_vivado_artifacts

if %REPORT_RC% neq 0 (
    echo.
    echo [ERROR] Report generation failed. Check "%REPORT_LOG%".
    pause
    exit /b %REPORT_RC%
)

echo.
echo [SUCCESS] Report generated: %REPORT_HTML%
echo.
pause
exit /b 0

:route_vivado_artifacts
for %%F in (vivado.log vivado.jou vivado.pb vivado.str) do (
    if exist "%%F" move /y "%%F" "%LOG_DIR%\" >nul 2>&1
)
for %%F in (*.backup.log *.backup.jou *.backup.str) do (
    if exist "%%F" move /y "%%F" "%LOG_DIR%\" >nul 2>&1
)
exit /b 0

:prompt_run_or_cancel
echo.
set "RUN_INPUT="
set /p "RUN_INPUT=Press Enter to continue, or Q to return to menu: "
if /i "%RUN_INPUT%"=="Q" exit /b %USER_CANCEL_RC%
exit /b 0
