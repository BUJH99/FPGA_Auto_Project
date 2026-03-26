@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..\..") do set "REPO_ROOT=%%~fI"
cd /d "%REPO_ROOT%"
title RISC-V Timing Verification

set "PROJECT_ROOT=%REPO_ROOT%\Project"
set "DEFAULT_VIVADO_BAT=C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat"
set "USER_CANCEL_RC=99"

call :resolve_python
if errorlevel 1 goto :FAIL
call :resolve_vivado_bat
if errorlevel 1 goto :FAIL
call :status "Python and Vivado launchers resolved"

set "TARGET_INPUT=%~1"
set "RUN_MODE=%~2"
set "FOCUS_FILTER_INPUT=%~3"

:SELECT_PROJECT
if defined TARGET_INPUT goto :NORMALIZE_PROJECT
call :prompt_project_selection TARGET_INPUT
if errorlevel 1 goto :CANCEL

:NORMALIZE_PROJECT
call :resolve_project_root "%TARGET_INPUT%" TARGET_PROJECT
if not errorlevel 1 goto :PROJECT_READY

echo.
echo [ERROR] Invalid project folder: "%TARGET_INPUT%"
echo         Select a folder under Project\* that contains:
echo         - fpga_auto.yml
echo         - src\
echo         - tools\timing_analysis_profile.json
echo.
if not "%~1"=="" goto :FAIL
set "TARGET_INPUT="
goto :SELECT_PROJECT

:PROJECT_READY
call :clear_screen
set "PROFILE_JSON=%TARGET_PROJECT%\tools\timing_analysis_profile.json"
call :status "Selected project: %TARGET_PROJECT%"

call :json_value "%PROFILE_JSON%" "analysis_mode" ANALYSIS_MODE
if errorlevel 1 (
    echo.
    echo [ERROR] Failed to read analysis_mode from "%PROFILE_JSON%"
    goto :FAIL
)

call :json_value "%PROFILE_JSON%" "default_report_path" REPORT_RELATIVE
if errorlevel 1 set "REPORT_RELATIVE=TIMING_REPORT.md"
call :resolve_md_report_path "%TARGET_PROJECT%" "%REPORT_RELATIVE%" REPORT_PATH
if errorlevel 1 (
    echo.
    echo [ERROR] Failed to resolve markdown report path under "%TARGET_PROJECT%\md"
    goto :FAIL
)

if /I "%ANALYSIS_MODE%"=="single_cycle" (
    set "RUN_SCRIPT=%TARGET_PROJECT%\tools\generate_single_cycle_perf_report.py"
    set "COLLECTOR_TCL=%TARGET_PROJECT%\tools\single_cycle_perf_collect.tcl"
    set "REUSE_FLAG=--reuse-existing"
    set "FLOW_NAME=Single-cycle timing verification"
    set "REPORT_ARG_NAME=--report-path"
    call :json_value "%PROFILE_JSON%" "default_output_dir" OUTPUT_RELATIVE
    if errorlevel 1 set "OUTPUT_RELATIVE=.analysis\single_cycle_perf"
) else if /I "%ANALYSIS_MODE%"=="pipeline_perf" (
    set "RUN_SCRIPT=%TARGET_PROJECT%\tools\generate_pipeline_perf_report.py"
    set "COLLECTOR_TCL=%TARGET_PROJECT%\tools\pipeline_perf_collect.tcl"
    set "REUSE_FLAG=--skip-vivado"
    set "FLOW_NAME=Pipeline timing verification"
    set "REPORT_ARG_NAME=--report"
    call :json_value "%PROFILE_JSON%" "default_output_root" OUTPUT_RELATIVE
    if errorlevel 1 set "OUTPUT_RELATIVE=.analysis\pipeline_perf"
) else (
    echo.
    echo [ERROR] Unsupported analysis_mode "%ANALYSIS_MODE%"
    goto :FAIL
)

if not exist "%RUN_SCRIPT%" (
    echo.
    echo [ERROR] Python entrypoint not found: "%RUN_SCRIPT%"
    goto :FAIL
)

if not exist "%COLLECTOR_TCL%" (
    echo.
    echo [ERROR] Tcl collector not found: "%COLLECTOR_TCL%"
    goto :FAIL
)

if not defined RUN_MODE (
call :prompt_run_mode RUN_MODE
    if errorlevel 1 goto :CANCEL
)

call :normalize_run_mode "%RUN_MODE%" "%ANALYSIS_MODE%" RUN_MODE_NORMALIZED
if errorlevel 1 (
    echo.
    echo [ERROR] Invalid run mode "%RUN_MODE%"
    if /I "%ANALYSIS_MODE%"=="pipeline_perf" (
        echo         Use 1/full, 2/reuse, 3/base, 4/focus, 5/focus-partial, or 6/pipeline-only.
    ) else (
        echo         Use 1/full for Vivado+Tcl+report, or 2/reuse for report-only reuse.
    )
    goto :FAIL
)
call :status "Loaded analysis profile and markdown report location"

set "RUN_ARGS="
set "RUN_LABEL=Vivado + Tcl + report"
if /I "%RUN_MODE_NORMALIZED%"=="reuse" (
    set "RUN_ARGS=%REUSE_FLAG%"
    set "RUN_LABEL=Reuse existing artifacts + regenerate report"
)
if /I "%RUN_MODE_NORMALIZED%"=="base" (
    set "RUN_ARGS=--skip-instruction-focus"
    set "RUN_LABEL=Base comparison only ^(single-cycle + 5-stage, skip instruction-focus rerun^)"
)
if /I "%RUN_MODE_NORMALIZED%"=="focus" (
    set "RUN_ARGS=--focus-only"
    set "RUN_LABEL=Instruction-focus only ^(reuse base artifacts, rerun all classes/mnemonics^)"
)
if /I "%RUN_MODE_NORMALIZED%"=="focus_partial" (
    if not defined FOCUS_FILTER_INPUT (
        call :prompt_focus_filter FOCUS_FILTER_INPUT
        if errorlevel 1 goto :CANCEL
    )
    set "RUN_ARGS=--focus-only --focus-filter=""%FOCUS_FILTER_INPUT%"""
    set "RUN_LABEL=Partial instruction-focus only"
)
if /I "%RUN_MODE_NORMALIZED%"=="pipeline_only" (
    set "RUN_ARGS=--pipeline-only --skip-instruction-focus"
    set "RUN_LABEL=5-stage only ^(pipeline build only, no single-cycle rebuild, no instruction-focus rerun^)"
)
set "RUN_ARGS=%RUN_ARGS% %REPORT_ARG_NAME%=""%REPORT_PATH%"""
call :status "Run mode prepared: %RUN_LABEL%"

call :clear_screen
echo.
echo ===============================================================
echo RISC-V TIMING VERIFICATION
echo ===============================================================
echo Project Folder : "%TARGET_PROJECT%"
echo Analysis Mode  : %FLOW_NAME%
echo Python Script  : "%RUN_SCRIPT%"
echo Tcl Collector  : "%COLLECTOR_TCL%"
echo Artifact Root  : "%TARGET_PROJECT%\%OUTPUT_RELATIVE%"
echo Report Path    : "%REPORT_PATH%"
echo Run Mode       : %RUN_LABEL%
if defined FOCUS_FILTER_INPUT (
    echo Focus Filter   : %FOCUS_FILTER_INPUT%
)
if /I not "%RUN_MODE_NORMALIZED%"=="reuse" (
    if defined VIVADO_BAT (
        echo Vivado Bat    : "%VIVADO_BAT%"
    ) else (
        echo Vivado Bat    : "%DEFAULT_VIVADO_BAT%"
    )
)
echo ===============================================================
echo.

call :status "Launching timing analysis Python flow"
"%PYTHON_EXE%" %PYTHON_FLAGS% "%RUN_SCRIPT%" %RUN_ARGS%
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" (
    echo.
    echo [ERROR] Timing verification failed with exit code %EXIT_CODE%.
    goto :FAIL
)

echo.
call :status "Timing report generated successfully"
echo [DONE] Timing report generated successfully.
echo        "%REPORT_PATH%"
echo.
call :pause_if_interactive
exit /b 0

:resolve_python
where py >nul 2>&1
if not errorlevel 1 (
    set "PYTHON_EXE=py"
    set "PYTHON_FLAGS=-3"
    exit /b 0
)
where python >nul 2>&1
if not errorlevel 1 (
    set "PYTHON_EXE=python"
    set "PYTHON_FLAGS="
    exit /b 0
)
echo.
echo [ERROR] Python launcher not found. Install Python or make py.exe available.
exit /b 1

:resolve_vivado_bat
set "RESOLVED_VIVADO_BAT="
for /f "usebackq delims=" %%I in (`powershell.exe -NoProfile -Command "$candidates = @('C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat', 'C:\AMDDesignTools\2025.1\Vivado\bin\vivado.bat', 'C:\Xilinx\Vivado\2025.2\bin\vivado.bat', 'C:\Xilinx\Vivado\2025.1\bin\vivado.bat', 'C:\Xilinx\Vivado\2024.2\bin\vivado.bat', 'C:\Xilinx\Vivado\2024.1\bin\vivado.bat'); if ($env:VIVADO_BAT -and (Test-Path -LiteralPath $env:VIVADO_BAT)) { [Console]::Write($env:VIVADO_BAT); exit 0 }; foreach ($candidate in $candidates) { if (Test-Path -LiteralPath $candidate) { [Console]::Write($candidate); exit 0 } }; $cmd = Get-Command vivado.bat -ErrorAction SilentlyContinue; if (-not $cmd) { $cmd = Get-Command vivado -ErrorAction SilentlyContinue }; if ($cmd) { [Console]::Write($cmd.Source); exit 0 }; [Console]::Write('C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat')"` ) do set "RESOLVED_VIVADO_BAT=%%I"
if not defined RESOLVED_VIVADO_BAT (
    echo.
    echo [ERROR] Failed to resolve Vivado launcher path.
    exit /b 1
)
set "VIVADO_BAT=%RESOLVED_VIVADO_BAT%"
exit /b 0

:status
echo [INFO] %~1
exit /b 0

:clear_screen
cls
exit /b 0

:prompt_project_selection
set "%~1="
call :scan_timing_projects

:PROJECT_SELECTION_PROMPT
call :clear_screen
echo.
echo ===============================================================
echo Available RISC-V Timing Projects
echo ===============================================================
if %TIMING_PROJECT_COUNT% gtr 0 (
    for /L %%N in (1,1,%TIMING_PROJECT_COUNT%) do call echo   [%%N] %%TIMING_PROJECT_LABEL_%%N%%
    echo.
    echo   [B] Browse for another folder
    echo   [Q] Cancel
    echo.
    set "PROJECT_PICK_INPUT="
    set /p "PROJECT_PICK_INPUT=Select timing project (Number/Name/Path/B/Q): "
) else (
    echo [INFO] No valid timing projects found under "%PROJECT_ROOT%".
    echo        Requirements:
    echo        - fpga_auto.yml
    echo        - src\
    echo        - tools\timing_analysis_profile.json
    echo.
    echo   [B] Browse for a project folder
    echo   [Q] Cancel
    echo.
    set "PROJECT_PICK_INPUT="
    set /p "PROJECT_PICK_INPUT=Select timing project (Path/B/Q): "
)
if not defined PROJECT_PICK_INPUT goto :PROJECT_SELECTION_PROMPT
if /I "%PROJECT_PICK_INPUT%"=="Q" exit /b 1
if /I "%PROJECT_PICK_INPUT%"=="B" (
    call :pick_folder PROJECT_PICK_BROWSED
    if errorlevel 1 goto :PROJECT_SELECTION_PROMPT
    set "%~1=%PROJECT_PICK_BROWSED%"
    exit /b 0
)

if %TIMING_PROJECT_COUNT% gtr 0 (
    set "PROJECT_PICK_RESOLVED="
    call :resolve_numeric_project_selection "%PROJECT_PICK_INPUT%" PROJECT_PICK_RESOLVED
    if not errorlevel 1 (
        call set "%~1=%%PROJECT_PICK_RESOLVED%%"
        exit /b 0
    )
)

set "PROJECT_PICK_RESOLVED="
call :coerce_project_input "%PROJECT_PICK_INPUT%" PROJECT_PICK_RESOLVED
set "%~1=%PROJECT_PICK_RESOLVED%"
exit /b 0

:resolve_md_report_path
set "%~3="
set "REPORT_DIR=%~f1\md"
if not exist "%REPORT_DIR%\" mkdir "%REPORT_DIR%" >nul 2>&1
if not exist "%REPORT_DIR%\" exit /b 1
for %%I in ("%~2") do set "REPORT_FILENAME=%%~nxI"
if not defined REPORT_FILENAME set "REPORT_FILENAME=TIMING_REPORT.md"
set "%~3=%REPORT_DIR%\%REPORT_FILENAME%"
set "REPORT_DIR="
set "REPORT_FILENAME="
exit /b 0

:resolve_numeric_project_selection
set "%~2="
set "PROJECT_PICK_NUMERIC=%~1"
set "PROJECT_PICK_NUMERIC=%PROJECT_PICK_NUMERIC: =%"
echo(%PROJECT_PICK_NUMERIC%| findstr /r "^[0-9][0-9]*$" >nul
if errorlevel 1 exit /b 1
if %PROJECT_PICK_NUMERIC% lss 1 exit /b 1
if %PROJECT_PICK_NUMERIC% gtr %TIMING_PROJECT_COUNT% exit /b 1
call set "%~2=%%TIMING_PROJECT_PATH_%PROJECT_PICK_NUMERIC%%%"
exit /b 0

:scan_timing_projects
for /f "delims=" %%V in ('set TIMING_PROJECT_PATH_ 2^>nul') do set "%%V="
for /f "delims=" %%V in ('set TIMING_PROJECT_LABEL_ 2^>nul') do set "%%V="
set "TIMING_PROJECT_COUNT=0"
if not exist "%PROJECT_ROOT%\" exit /b 0
for /d %%D in ("%PROJECT_ROOT%\*") do (
    if exist "%%~fD\fpga_auto.yml" (
        if exist "%%~fD\src" (
            if exist "%%~fD\tools\timing_analysis_profile.json" (
                call set /a TIMING_PROJECT_COUNT+=1
                call set "TIMING_PROJECT_PATH_%%TIMING_PROJECT_COUNT%%=%%~fD"
                call set "TIMING_PROJECT_LABEL_%%TIMING_PROJECT_COUNT%%=Project\%%~nxD"
            )
        )
    )
)
exit /b 0

:coerce_project_input
set "%~2=%~1"
if exist "%PROJECT_ROOT%\%~1" (
    for %%I in ("%PROJECT_ROOT%\%~1") do set "%~2=%%~fI"
    exit /b 0
)
if exist "%~1" (
    for %%I in ("%~1") do set "%~2=%%~fI"
    exit /b 0
)
exit /b 0

:pick_folder
set "%~1="
for /f "usebackq delims=" %%I in (`powershell.exe -NoProfile -STA -Command "Add-Type -AssemblyName System.Windows.Forms; $dlg = New-Object System.Windows.Forms.FolderBrowserDialog; $dlg.Description = 'Select a RISC-V timing project folder'; $dlg.ShowNewFolderButton = $false; if (Test-Path -LiteralPath $env:PROJECT_ROOT) { $dlg.SelectedPath = $env:PROJECT_ROOT }; if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { [Console]::Write($dlg.SelectedPath) }"`) do set "%~1=%%I"
if defined %~1 exit /b 0
echo.
echo [INFO] Folder selection canceled.
exit /b 1

:resolve_project_root
set "%~2="
set "RAW_TARGET_PATH=%~1"
for /f "usebackq delims=" %%I in (`powershell.exe -NoProfile -Command "$item = $null; try { $item = Get-Item -LiteralPath $env:RAW_TARGET_PATH -ErrorAction Stop } catch { exit 2 }; if (-not $item.PSIsContainer) { $item = $item.Directory }; while ($item) { $manifest = Join-Path $item.FullName 'fpga_auto.yml'; $src = Join-Path $item.FullName 'src'; $analysisProfile = Join-Path $item.FullName 'tools\\timing_analysis_profile.json'; if ((Test-Path -LiteralPath $manifest) -and (Test-Path -LiteralPath $src) -and (Test-Path -LiteralPath $analysisProfile)) { [Console]::Write($item.FullName); exit 0 }; $item = $item.Parent }; exit 3"`) do set "%~2=%%I"
if defined %~2 exit /b 0
exit /b 1

:json_value
set "%~3="
set "JSON_QUERY_PATH=%~1"
set "JSON_QUERY_KEY=%~2"
for /f "usebackq delims=" %%I in (`powershell.exe -NoProfile -Command "$cfg = Get-Content -LiteralPath $env:JSON_QUERY_PATH -Raw | ConvertFrom-Json; $value = $cfg.($env:JSON_QUERY_KEY); if ($null -ne $value) { [Console]::Write([string]$value) }"`) do set "%~3=%%I"
if defined %~3 exit /b 0
exit /b 1

:prompt_run_mode
call :clear_screen
echo.
if /I "%ANALYSIS_MODE%"=="pipeline_perf" (
    echo [1] Full timing run ^(single-cycle + pipeline + instruction-focus + report^)
    echo [2] Reuse existing artifacts and regenerate report only
    echo [3] Base comparison only ^(single-cycle + pipeline, skip instruction-focus rerun^)
    echo [4] Instruction-focus only ^(reuse base artifacts, rerun all classes/mnemonics^)
    echo [5] Partial instruction-focus only ^(reuse base artifacts, rerun selected focuses^)
    echo [6] 5-stage only ^(pipeline build only, no single-cycle rebuild, no instruction-focus rerun^)
) else (
    echo [1] Full timing run ^(Vivado + Tcl collector + report^)
    echo [2] Reuse existing artifacts and regenerate report only
)
set "RUN_MODE_INPUT="
set /p "RUN_MODE_INPUT=Select mode [1]: "
if not defined RUN_MODE_INPUT set "RUN_MODE_INPUT=1"
set "%~1=%RUN_MODE_INPUT%"
exit /b 0

:normalize_run_mode
set "%~3="
if /I "%~1"=="1" set "%~3=full"
if /I "%~1"=="full" set "%~3=full"
if /I "%~1"=="f" set "%~3=full"
if /I "%~1"=="2" set "%~3=reuse"
if /I "%~1"=="reuse" set "%~3=reuse"
if /I "%~1"=="r" set "%~3=reuse"
if /I "%~2"=="pipeline_perf" (
    if /I "%~1"=="3" set "%~3=base"
    if /I "%~1"=="base" set "%~3=base"
    if /I "%~1"=="b" set "%~3=base"
    if /I "%~1"=="4" set "%~3=focus"
    if /I "%~1"=="focus" set "%~3=focus"
    if /I "%~1"=="focus-only" set "%~3=focus"
    if /I "%~1"=="fo" set "%~3=focus"
    if /I "%~1"=="5" set "%~3=focus_partial"
    if /I "%~1"=="focus_partial" set "%~3=focus_partial"
    if /I "%~1"=="focus-partial" set "%~3=focus_partial"
    if /I "%~1"=="partial" set "%~3=focus_partial"
    if /I "%~1"=="fp" set "%~3=focus_partial"
    if /I "%~1"=="6" set "%~3=pipeline_only"
    if /I "%~1"=="pipeline" set "%~3=pipeline_only"
    if /I "%~1"=="pipeline_only" set "%~3=pipeline_only"
    if /I "%~1"=="pipeline-only" set "%~3=pipeline_only"
    if /I "%~1"=="po" set "%~3=pipeline_only"
)
if defined %~3 exit /b 0
exit /b 1

:prompt_focus_filter
call :clear_screen
echo.
echo Enter a comma-separated focus filter.
echo   Example 1: addi,lw,jalr
echo   Example 2: class:load,mnemonic:jalr
set "FOCUS_FILTER_PROMPT="
set /p "FOCUS_FILTER_PROMPT=Focus filter: "
if not defined FOCUS_FILTER_PROMPT (
    echo.
    echo [INFO] Focus filter was left empty.
    exit /b 1
)
set "%~1=%FOCUS_FILTER_PROMPT%"
exit /b 0

:pause_if_interactive
if /I "%NO_PAUSE%"=="1" exit /b 0
if /I "%CI%"=="true" exit /b 0
if /I "%FPGA_AUTO_PARENT_MENU%"=="1" exit /b 0
pause
exit /b 0

:CANCEL
echo.
echo [INFO] Timing verification canceled.
echo.
exit /b %USER_CANCEL_RC%

:FAIL
echo.
call :pause_if_interactive
exit /b 1
