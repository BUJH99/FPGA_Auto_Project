@echo off
setlocal enabledelayedexpansion
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
set "CONSOLE_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\console_ui.bat"
set "USER_CANCEL_RC=99"

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^>
    call "%CONSOLE_HELPER%" pause_then_clear
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
set "BUILD_STAGE_STATUS=%LOG_DIR%\vivado_build_stage.status"
set "FINAL_REPORT_DIR=%TARGET_PROJECT%\output\FINALReport"
set "FINAL_REPORT_HTML=%FINAL_REPORT_DIR%\Final_Build_Report.html"
set "BUILD_SUMMARY_TOOL=%TEMPLATES_ROOT%\contexts\vivado\adapters\cli\vivado_capture_build_summary_cli.js"
set "VIVADO_STAGE_MONITOR_PS1=%TEMPLATES_ROOT%\contexts\vivado\adapters\ps1\vivado_run_with_stage_monitor.ps1"
set "BUILD_PLAN_JSON="
set "BUILD_PLAN_CMD="
set "BUILD_RC=-1"
set "RTL_RC=-1"
set "REPORT_RC=-1"
set "PROGRAM_STATUS=NOT_RUN"
set "BITSTREAM_PATH="
set "VIVADO_ENV_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\ensure_vivado_on_path.bat"

call :route_vivado_artifacts

call "%CONSOLE_HELPER%" clear
echo.
echo [START] Vivado Build Flow
echo         Target : %TARGET_PROJECT%
echo         Logs   : %LOG_DIR%
echo.

call :print_step "1/15" "Validate Vivado Environment"
echo [CHECK] Verifying Vivado Environment...
if exist "%VIVADO_ENV_HELPER%" call "%VIVADO_ENV_HELPER%" --quiet >nul 2>nul
where vivado >nul 2>nul
if %errorlevel% neq 0 (
    echo.
    echo [ERROR] Vivado executable not found in PATH.
    echo         Check VIVADO_BIN or AMD/Xilinx default install paths.
    echo.
    call :maybe_pause
    exit /b 1
)
echo      - Vivado found.
echo      - Ready to start build flow.

call :print_step "2/15" "Confirm Build Start"
if "%NO_PAUSE%"=="1" (
    echo [INFO] --no-pause enabled. Continuing without prompt.
) else (
    echo [PROMPT] Review environment check and start build.
)
call :prompt_run_or_cancel
set "PROMPT_RC=%errorlevel%"
if "%PROMPT_RC%"=="%USER_CANCEL_RC%" exit /b %USER_CANCEL_RC%
echo [INFO] Build start confirmed.
echo      - Step 2/15 complete.

call :print_step "3/15" "Prepare Output Workspace"
if not exist output mkdir output
echo [CLEAN] Resetting RTL build-local artifacts only...
if exist output\checkpoints rmdir /s /q output\checkpoints
if exist output\reports rmdir /s /q output\reports
if exist output\FINALReport rmdir /s /q output\FINALReport
if exist output\build_summary.json del /q output\build_summary.json >nul 2>&1
del /q output\*.bit >nul 2>&1
echo      - Output directory ready.
echo      - Preserved output\vivado and output\vitis workspaces.
echo      - Step 3/15 complete.

call :print_step "4/15" "Load Manifest Context"
if exist "%MANIFEST_CTX%" (
    echo [PLAN] Loading manifest context...
    call "%MANIFEST_CTX%" "%TARGET_PROJECT%"
    if errorlevel 1 (
        echo [ERROR] Manifest context initialization failed.
        call :maybe_pause
        exit /b 1
    )
    echo        - Manifest context ready.
    echo      - Step 4/15 complete.
)
if not exist "%MANIFEST_CTX%" (
    echo [INFO] Manifest bootstrap script not found. Continuing with existing environment.
    echo      - Step 4/15 complete.
)

call :print_step "5/15" "Resolve Build Plan"
echo [PLAN] Preparing Vivado build request...
call :prepare_build_plan
if errorlevel 1 (
    echo [ERROR] Vivado build plan preparation failed.
    call :maybe_pause
    exit /b 1
)
set "BITSTREAM_PATH=%TARGET_PROJECT%\output\%BUILD_TOP_MODULE%.bit"
echo [PLAN] Build plan ready.
echo        Top      : %BUILD_TOP_MODULE%
echo        Part     : %BUILD_PART_NUMBER%
echo        Strategy : %BUILD_STRATEGY%
echo        Power    : %BUILD_POWER_LIMIT_W% W
echo        Source   : %BUILD_SRC_LIST%
echo        XDC      : %BUILD_XDC_LIST%
echo      - Step 5/15 complete.

if exist "%BUILD_STAGE_STATUS%" del /q "%BUILD_STAGE_STATUS%" >nul 2>&1
echo [RUN] Launching staged Vivado build...
echo       Log: %BUILD_LOG%
echo       Stage file: %BUILD_STAGE_STATUS%
echo       Waiting for synthesis/implementation/bitstream progress...
if exist "%VIVADO_STAGE_MONITOR_PS1%" (
    call powershell -NoProfile -ExecutionPolicy Bypass -File "%VIVADO_STAGE_MONITOR_PS1%" -VivadoTcl "%TEMPLATES_ROOT%\contexts\vivado\adapters\tcl\vivado_run_build_flow.tcl" -ProjectRoot "%TARGET_PROJECT%" -SrcList "%BUILD_SRC_LIST%" -XdcList "%BUILD_XDC_LIST%" -IncList "%BUILD_INC_LIST%" -TopModule "%BUILD_TOP_MODULE%" -PartNumber "%BUILD_PART_NUMBER%" -ProjectName "%BUILD_PROJECT_NAME%" -BuildStrategy "%BUILD_STRATEGY%" -PowerLimit "%BUILD_POWER_LIMIT_W%" -BuildLog "%BUILD_LOG%" -BuildJournal "%BUILD_JOU%" -StageStatusFile "%BUILD_STAGE_STATUS%"
) else (
    echo [WARN] Stage monitor script not found. Falling back to single-step build execution.
    call vivado -mode batch -source "%TEMPLATES_ROOT%\contexts\vivado\adapters\tcl\vivado_run_build_flow.tcl" -tclargs "%TARGET_PROJECT%" "%BUILD_SRC_LIST%" "%BUILD_XDC_LIST%" "%BUILD_INC_LIST%" "%BUILD_TOP_MODULE%" "%BUILD_PART_NUMBER%" "%BUILD_PROJECT_NAME%" "%BUILD_STRATEGY%" "%BUILD_POWER_LIMIT_W%" "%BUILD_STAGE_STATUS%" -log "%BUILD_LOG%" -journal "%BUILD_JOU%" -notrace >nul 2>&1
)
set "BUILD_RC=%errorlevel%"
call :route_vivado_artifacts
if exist "%BUILD_STAGE_STATUS%" del /q "%BUILD_STAGE_STATUS%" >nul 2>&1

if %BUILD_RC% neq 0 (
    call :write_build_summary
    echo.
    echo [FAIL] Vivado build failed. rc=%BUILD_RC%
    echo        Full log: %BUILD_LOG%
    call :print_relevant_log_excerpt "%BUILD_LOG%" "Build failure excerpt"
    call :maybe_pause
    exit /b %BUILD_RC%
)
set "PROGRAM_STATUS=SKIPPED"
echo [OK] Build completed.
echo      - Steps 6/15 through 8/15 complete.

call :print_step "9/15" "Validate Build Outputs"
echo [CHECK] Verifying generated build artifacts...
echo       Build log: %BUILD_LOG%
if exist "%BITSTREAM_PATH%" (
    echo       Bitstream: %BITSTREAM_PATH%
    echo       Status: bitstream ready.
) else (
    echo [WARN] Expected bitstream not found.
    echo        Path: %BITSTREAM_PATH%
)
echo      - Step 9/15 complete.

call :print_step "10/15" "Review Build Checks"
echo [CHECK] Summarizing build QoR and warnings...
echo       Source: %BUILD_LOG%
call :print_build_checks "%BUILD_LOG%"
echo      - Step 10/15 complete.

call :print_step "11/15" "Export RTL Hierarchy"
echo [RUN] RTL hierarchy export
echo       Stage: Vivado mermaid/source hierarchy extraction
echo       Log: %RTL_HIER_LOG%
echo       Status: running...
call vivado -mode batch -source "%TEMPLATES_ROOT%\contexts\code_intel\adapters\tcl\code_export_hierarchy_mermaid.tcl" -tclargs "%TARGET_PROJECT%" "%BUILD_SRC_LIST%" -notrace -log "%RTL_HIER_LOG%" -journal "%RTL_HIER_JOU%" >nul 2>&1
set "RTL_RC=%errorlevel%"
call :route_vivado_artifacts
if %RTL_RC% neq 0 (
    echo [WARN] RTL hierarchy export failed. Log: %RTL_HIER_LOG%
    echo      - Step 11/15 completed with warnings.
) else (
    echo [OK] RTL hierarchy export completed.
    echo      - Step 11/15 complete.
)

call :print_step "12/15" "Generate Final Report"
echo [RUN] Final report generation
echo       Stage: Vivado report HTML assembly
echo       Log: %REPORT_GEN_LOG%
echo       Status: running...
call vivado -mode batch -source "%TEMPLATES_ROOT%\contexts\reporting\adapters\tcl\report_generate_html.tcl" -tclargs "%TARGET_PROJECT%" "%BUILD_SRC_LIST%" -notrace -log "%REPORT_GEN_LOG%" -journal "%REPORT_GEN_JOU%" >nul 2>&1
set "REPORT_RC=%errorlevel%"
call :route_vivado_artifacts
if %REPORT_RC% neq 0 (
    echo [WARN] Final report generation failed. Log: %REPORT_GEN_LOG%
    echo      - Step 12/15 completed with warnings.
) else (
    echo [OK] Final report generation completed.
    echo      - Step 12/15 complete.
)

call :print_step "13/15" "Verify Final Report Output"
echo [CHECK] Verifying final report artifacts...
echo       Report log: %REPORT_GEN_LOG%
if exist "%FINAL_REPORT_HTML%" (
    echo       Report generated: %FINAL_REPORT_HTML%
    echo      - Step 13/15 complete.
) else (
    echo [WARN] Final report HTML not found.
    echo      - Step 13/15 completed with warnings.
)

call :print_step "14/15" "Program FPGA Device (Optional)"
echo [PROMPT] Run FPGA device programming?

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
    set "PROGRAM_STATUS=NOT_AVAILABLE"
)

echo      - Step 14/15 complete.

call :print_step "15/15" "Finalize Build Summary"
echo [RUN] Capturing final build summary metadata...
call :write_build_summary
echo [OK] Build summary captured.
echo      - Step 15/15 complete.

echo.
echo [DONE] Vivado flow completed.
if defined BITSTREAM_PATH (
    echo        Bitstream : %BITSTREAM_PATH%
) else (
    echo        Bitstream : %CD%\output
)
echo        Report    : %FINAL_REPORT_HTML%
echo        Logs      : %LOG_DIR%
echo        Program   : %PROGRAM_STATUS%
echo.
echo Press any key to close this window...
call :maybe_pause
exit /b 0

:maybe_pause
if "%NO_PAUSE%"=="1" exit /b 0
call "%CONSOLE_HELPER%" pause_then_clear
exit /b 0

:print_step
echo.
echo ===============================================================================
echo [STEP %~1] %~2
echo ===============================================================================
exit /b 0

:prompt_run_or_cancel
if "%NO_PAUSE%"=="1" exit /b 0
echo.
set "RUN_INPUT="
set /p "RUN_INPUT=Press Enter to continue, or Q to return to menu: "
if /i "%RUN_INPUT%"=="Q" exit /b %USER_CANCEL_RC%
exit /b 0

:route_vivado_artifacts
for %%F in (vivado.log vivado.jou vivado.pb vivado.str) do (
    if exist "%%F" move /y "%%F" "%LOG_DIR%\" >nul 2>&1
)
for %%F in (*.backup.log *.backup.jou *.backup.str) do (
    if exist "%%F" move /y "%%F" "%LOG_DIR%\" >nul 2>&1
)
exit /b 0

:prepare_build_plan
if not exist "%BUILD_SUMMARY_TOOL%" exit /b 1
if not exist "%MANIFEST_JSON%" exit /b 1
set "PLAN_ARGS="
if "%AUTO_PROGRAM%"=="1" set "PLAN_ARGS=%PLAN_ARGS% --auto-program"
if "%NO_PAUSE%"=="1" set "PLAN_ARGS=%PLAN_ARGS% --no-pause"
call node "%BUILD_SUMMARY_TOOL%" --stage prepare --project "%TARGET_PROJECT%" --manifest-json "%MANIFEST_JSON%" --src-list "%MANIFEST_SRC_LIST%" --xdc-list "%MANIFEST_XDC_LIST%" --inc-list "%MANIFEST_INC_LIST%" %PLAN_ARGS% >nul
if errorlevel 1 exit /b 1
set "BUILD_PLAN_JSON=%TARGET_PROJECT%\output\vivado\build_plan.json"
set "BUILD_PLAN_CMD=%TARGET_PROJECT%\output\vivado\build_plan.cmd"
if not exist "%BUILD_PLAN_CMD%" exit /b 1
call "%BUILD_PLAN_CMD%"
exit /b 0

:write_build_summary
if not exist "%BUILD_SUMMARY_TOOL%" exit /b 0
if not exist "%MANIFEST_JSON%" exit /b 0
call node "%BUILD_SUMMARY_TOOL%" --stage capture --project "%TARGET_PROJECT%" --manifest-json "%MANIFEST_JSON%" --build-log "%BUILD_LOG%" --build-plan-json "%BUILD_PLAN_JSON%" --program-status "%PROGRAM_STATUS%" --build-rc "%BUILD_RC%" --rtl-rc "%RTL_RC%" --report-rc "%REPORT_RC%" >nul
exit /b 0

:print_build_checks
set "LOG_TO_PARSE=%~1"
if not exist "%LOG_TO_PARSE%" exit /b 0
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$log = $env:LOG_TO_PARSE;" ^
  "if (-not (Test-Path -LiteralPath $log)) { exit 0 }" ^
  "$patterns = @('CHECK: Total Power','CHECK: WNS \\(Worst Negative Slack\\)','CHECK: CDC Violations','CRITICAL WARNING');" ^
  "$lines = Get-Content -LiteralPath $log | Where-Object { $line = $_; ($patterns | Where-Object { $line -match $_ }).Count -gt 0 } | Select-Object -Last 6;" ^
  "$lines | ForEach-Object { '      - ' + $_.Trim() }"
exit /b 0

:print_relevant_log_excerpt
set "LOG_TO_PARSE=%~1"
set "LOG_SECTION_TITLE=%~2"
if not exist "%LOG_TO_PARSE%" exit /b 0
echo [DETAIL] %LOG_SECTION_TITLE%
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$log = $env:LOG_TO_PARSE;" ^
  "if (-not (Test-Path -LiteralPath $log)) { exit 0 }" ^
  "$patterns = @('CRITICAL WARNING','\\[ERROR\\]','^ERROR','ERROR:','FAIL','WNS \\(Worst Negative Slack\\)','Total Power','CDC Violations','No bitstream generated','write_bitstream');" ^
  "$lines = Get-Content -LiteralPath $log;" ^
  "$filtered = $lines | Where-Object { $line = $_; ($patterns | Where-Object { $line -match $_ }).Count -gt 0 };" ^
  "if (-not $filtered) { $filtered = $lines | Select-Object -Last 12 } else { $filtered = $filtered | Select-Object -Last 12 }" ^
  "$filtered | ForEach-Object { '      ' + $_.Trim() }"
exit /b 0
