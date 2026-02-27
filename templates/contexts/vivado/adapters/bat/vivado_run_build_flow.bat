@echo off
setlocal enabledelayedexpansion
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^>
    pause
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
set "AUTO_PROGRAM=0"
set "NO_PAUSE=0"
set "MANIFEST_CTX=%TEMPLATES_ROOT%\shared\adapters\bat\bootstrap_manifest_context.bat"
for %%A in ("%~2" "%~3" "%~4") do (
    if /i "%%~A"=="--auto-program" set "AUTO_PROGRAM=1"
    if /i "%%~A"=="--no-pause" set "NO_PAUSE=1"
)

cd /d "%TARGET_PROJECT%"
title Vivado Automation Flow - %TARGET_PROJECT%

set "LOG_DIR=%TARGET_PROJECT%\log"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"

set "BUILD_LOG=%LOG_DIR%\vivado_full_build.log"
set "BUILD_JOU=%LOG_DIR%\vivado_full_build.jou"
set "RTL_HIER_LOG=%LOG_DIR%\rtl_hier.log"
set "RTL_HIER_JOU=%LOG_DIR%\rtl_hier.jou"
set "REPORT_GEN_LOG=%LOG_DIR%\report_gen.log"
set "REPORT_GEN_JOU=%LOG_DIR%\report_gen.jou"
set "FINAL_REPORT_DIR=%TARGET_PROJECT%\output\FINALReport"
set "FINAL_REPORT_HTML=%FINAL_REPORT_DIR%\Final_Build_Report.html"

call :route_vivado_artifacts

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
    call :maybe_pause
    exit /b 1
)
echo      - Vivado found.

if exist output (
    echo [CLEAN] Cleaning up previous output directory...
    rmdir /s /q output
)
mkdir output
echo      - Output directory ready.

if exist "%MANIFEST_CTX%" (
    call "%MANIFEST_CTX%" "%TARGET_PROJECT%"
    if errorlevel 1 (
        echo [ERROR] Manifest context initialization failed.
        call :maybe_pause
        exit /b 1
    )
)

echo.
echo ===============================================================================
echo  [EXEC] Running Vivado Batch Build (Synthesis/Implementation/Bitstream)...
echo         (Please wait. Check log for details.)
echo ===============================================================================
echo.

call vivado -mode batch -source "%TEMPLATES_ROOT%\contexts\vivado\adapters\tcl\vivado_run_build_flow.tcl" -tclargs "%TARGET_PROJECT%" "%MANIFEST_SRC_LIST%" "%MANIFEST_XDC_LIST%" "%MANIFEST_INC_LIST%" -log "%BUILD_LOG%" -journal "%BUILD_JOU%" -notrace
set "BUILD_RC=%errorlevel%"
call :route_vivado_artifacts

if %BUILD_RC% neq 0 (
    echo.
    echo ###############################################################################
    echo #                                                                             #
    echo #                          [FAIL] BUILD FAILED                                #
    echo #                                                                             #
    echo ###############################################################################
    echo.
    echo [ERROR] Please check the log file: %BUILD_LOG%
    echo.
    call :maybe_pause
    exit /b %BUILD_RC%
)

set "PROGRAM_STATUS=SKIPPED"

echo.
echo ===============================================================================
echo  [INFO] Extracting RTL Hierarchy (diagram/report source data)...
echo ===============================================================================
echo.

call vivado -mode batch -source "%TEMPLATES_ROOT%\contexts\code_intel\adapters\tcl\code_export_hierarchy_mermaid.tcl" -tclargs "%TARGET_PROJECT%" "%MANIFEST_SRC_LIST%" -notrace -log "%RTL_HIER_LOG%" -journal "%RTL_HIER_JOU%"
set "RTL_RC=%errorlevel%"
call :route_vivado_artifacts
if %RTL_RC% neq 0 (
    echo [WARNING] RTL hierarchy extraction failed. Check %RTL_HIER_LOG%
)

echo.
echo ===============================================================================
echo  [REPORT] Generating Final Build Report...
echo ===============================================================================
echo.

call vivado -mode batch -source "%TEMPLATES_ROOT%\contexts\reporting\adapters\tcl\report_generate_html.tcl" -tclargs "%TARGET_PROJECT%" "%MANIFEST_SRC_LIST%" -notrace -log "%REPORT_GEN_LOG%" -journal "%REPORT_GEN_JOU%"
set "REPORT_RC=%errorlevel%"
call :route_vivado_artifacts
if %REPORT_RC% neq 0 (
    echo [WARNING] Report generation script returned an error.
)

if exist "%FINAL_REPORT_HTML%" (
    echo      - Report generated: %FINAL_REPORT_HTML%
) else (
    echo      - [WARNING] Failed to generate report.
)

echo.
echo ===============================================================================
echo  [PROMPT] Run FPGA Device Programming?
echo ===============================================================================
echo.

if exist "%TEMPLATES_ROOT%\contexts\vivado\adapters\bat\vivado_program_fpga.bat" (
    if "%AUTO_PROGRAM%"=="1" (
        echo [INFO] Auto program mode enabled. Running vivado_fpga_program.bat...
        call "%TEMPLATES_ROOT%\contexts\vivado\adapters\bat\vivado_program_fpga.bat" "%TARGET_PROJECT%" --no-pause
        if !errorlevel! neq 0 (
            echo [WARNING] vivado_fpga_program.bat failed.
            set "PROGRAM_STATUS=FAILED"
        ) else (
            echo [INFO] Device programming completed.
            set "PROGRAM_STATUS=SUCCESS"
        )
    ) else (
        choice /C YN /N /M "Run vivado_fpga_program.bat now? [Y/N]: "
        if errorlevel 2 (
            echo [INFO] Device programming skipped by user.
            set "PROGRAM_STATUS=SKIPPED_BY_USER"
        ) else (
            call "%TEMPLATES_ROOT%\contexts\vivado\adapters\bat\vivado_program_fpga.bat" "%TARGET_PROJECT%" --no-pause
            if !errorlevel! neq 0 (
                echo [WARNING] vivado_fpga_program.bat failed.
                set "PROGRAM_STATUS=FAILED"
            ) else (
                echo [INFO] Device programming completed.
                set "PROGRAM_STATUS=SUCCESS"
            )
        )
    )
) else (
    echo [WARNING] vivado_program_fpga.bat not found in canonical Vivado context path.
)

echo.
echo ###############################################################################
echo #                                                                             #
echo #                       Automation Flow Completed                             #
echo #                                                                             #
echo ###############################################################################
echo.
echo [INFO] Bitstream location: %CD%\output
echo [INFO] Build Report      : %FINAL_REPORT_HTML%
echo [INFO] Vivado Logs       : %LOG_DIR%
echo [INFO] Program Device    : %PROGRAM_STATUS%
echo.
echo ===============================================================================
echo  All tasks completed. Press any key to close this window...
echo ===============================================================================
call :maybe_pause
exit /b 0

:maybe_pause
if "%NO_PAUSE%"=="1" exit /b 0
pause >nul
exit /b 0

:route_vivado_artifacts
for %%F in (vivado.log vivado.jou vivado.pb vivado.str) do (
    if exist "%%F" move /y "%%F" "%LOG_DIR%\" >nul 2>&1
)
for %%F in (*.backup.log *.backup.jou *.backup.str) do (
    if exist "%%F" move /y "%%F" "%LOG_DIR%\" >nul 2>&1
)
exit /b 0
