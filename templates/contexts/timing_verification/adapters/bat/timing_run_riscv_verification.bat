@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..\..") do set "REPO_ROOT=%%~fI"
set "PROJECT_ROOT_HELPER=%REPO_ROOT%\templates\shared\adapters\bat\resolve_managed_project_root.bat"
cd /d "%REPO_ROOT%"
title RISC-V Timing Verification

if exist "%PROJECT_ROOT_HELPER%" call "%PROJECT_ROOT_HELPER%" "%REPO_ROOT%"
if defined FPGA_AUTO_PROJECT_ROOT (
    set "PROJECT_ROOT=%FPGA_AUTO_PROJECT_ROOT%"
) else (
    for %%I in ("%REPO_ROOT%\..") do set "PROJECT_ROOT=%%~fI\Project"
)
set "USER_CANCEL_RC=99"

call :resolve_python
if errorlevel 1 goto :FAIL
call :resolve_vivado_bat
if errorlevel 1 goto :FAIL
call :configure_pythonpath
call :status "Python and Vivado launchers resolved"

set "TARGET_INPUT=%~1"
set "RUN_MODE=%~2"
set "RUN_MODE_SOURCE="
if defined RUN_MODE set "RUN_MODE_SOURCE=provided"
set "PROGRAM_INPUT="
set "FOCUS_FILTER_INPUT="
call :parse_optional_args PROGRAM_INPUT FOCUS_FILTER_INPUT %3 %4 %5 %6 %7 %8 %9
if errorlevel 1 goto :FAIL

:SELECT_PROJECT
if defined TARGET_INPUT goto :NORMALIZE_PROJECT
call :prompt_project_selection TARGET_INPUT
if errorlevel 1 goto :CANCEL

:NORMALIZE_PROJECT
call :resolve_project_root "%TARGET_INPUT%" TARGET_PROJECT
if not errorlevel 1 goto :PROJECT_READY

echo.
echo [ERROR] Invalid project folder: "%TARGET_INPUT%"
echo         Select a folder under "%PROJECT_ROOT%\*" that contains:
echo         - fpga_auto.yml
echo         - src\
echo         - tools\timing\timing_analysis_profile.json
echo.
if not "%~1"=="" goto :FAIL
set "TARGET_INPUT="
goto :SELECT_PROJECT

:PROJECT_READY
call :clear_screen
call :resolve_profile_path "%TARGET_PROJECT%" PROFILE_JSON
if errorlevel 1 goto :FAIL
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
    set "RUN_SCRIPT=%TARGET_PROJECT%\tools\timing\generate_pipeline_perf_report.py"
    set "COLLECTOR_TCL=%TARGET_PROJECT%\tools\timing\pipeline_perf_collect.tcl"
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

if /I "%ANALYSIS_MODE%"=="pipeline_perf" (
    set "PROGRAM_INPUT=%PROGRAM_INPUT:"=%"
    if "%PROGRAM_INPUT%"==" " set "PROGRAM_INPUT="
    if not defined PROGRAM_INPUT set "PROGRAM_INPUT=full_coverage"
    if "%PROGRAM_INPUT%"=="" set "PROGRAM_INPUT=full_coverage"
    call :normalize_program_selection "%PROGRAM_INPUT%" PROGRAM_NORMALIZED PROGRAM_LABEL
    if errorlevel 1 (
        echo.
        echo [ERROR] Invalid timing program "%PROGRAM_INPUT%"
        echo         Use `full_coverage` or `bubble_sort`.
        goto :FAIL
    )
) else if /I "%ANALYSIS_MODE%"=="single_cycle" (
    set "PROGRAM_INPUT=%PROGRAM_INPUT:"=%"
    if "%PROGRAM_INPUT%"==" " set "PROGRAM_INPUT="
    if not defined PROGRAM_INPUT set "PROGRAM_INPUT=full_coverage"
    if "%PROGRAM_INPUT%"=="" set "PROGRAM_INPUT=full_coverage"
    call :normalize_program_selection "%PROGRAM_INPUT%" PROGRAM_NORMALIZED PROGRAM_LABEL
    if errorlevel 1 (
        echo.
        echo [ERROR] Invalid timing program "%PROGRAM_INPUT%"
        echo         Use `full_coverage` or `bubble_sort`.
        goto :FAIL
    )
)

set "ARTIFACT_ROOT_DISPLAY=%TARGET_PROJECT%\%OUTPUT_RELATIVE%"
if defined PROGRAM_NORMALIZED (
    set "ARTIFACT_ROOT_DISPLAY=%TARGET_PROJECT%\%OUTPUT_RELATIVE%\programs\%PROGRAM_NORMALIZED%"
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

:RESOLVE_RUN_MODE
if not defined RUN_MODE (
    call :prompt_run_mode RUN_MODE
    if errorlevel 1 goto :CANCEL
    set "RUN_MODE_SOURCE=prompt"
)

call :normalize_run_mode "%RUN_MODE%" "%ANALYSIS_MODE%" RUN_MODE_NORMALIZED
if errorlevel 1 (
    echo.
    echo [ERROR] Invalid run mode "%RUN_MODE%"
    if /I "%RUN_MODE_SOURCE%"=="prompt" (
        if /I "%ANALYSIS_MODE%"=="pipeline_perf" (
            echo         Use 1, 2, 3, 4, 5, or 6 from the menu.
        ) else (
            echo         Use 1, 2, or 3 from the menu.
        )
    ) else if /I "%ANALYSIS_MODE%"=="pipeline_perf" (
        echo         Use 1/full, 2/reuse, 3/base, 4/focus, 5/focus-partial, 6/pipeline-only, 7/program, or 8/soc_perf.
    ) else (
        echo         Use 1/full, 2/reuse, or 3/program.
    )
    goto :FAIL
)
if /I "%RUN_MODE_NORMALIZED%"=="program_select" (
    call :prompt_program_selection "%PROGRAM_NORMALIZED%" PROGRAM_INPUT PROGRAM_NORMALIZED PROGRAM_LABEL
    set "RUN_MODE="
    if not errorlevel 1 (
        set "ARTIFACT_ROOT_DISPLAY=%TARGET_PROJECT%\%OUTPUT_RELATIVE%\programs\%PROGRAM_NORMALIZED%"
    )
    goto :RESOLVE_RUN_MODE
)
call :status "Loaded analysis profile and markdown report location"

set "RUN_ARGS="
set "RUN_LABEL=Vivado + Tcl + report"
set "RUN_REFRESH_ALL=0"
if /I "%RUN_MODE_NORMALIZED%"=="single_full_coverage" (
    set "PROGRAM_NORMALIZED=full_coverage"
    set "PROGRAM_LABEL=Full Coverage.mem"
)
if /I "%RUN_MODE_NORMALIZED%"=="single_bubble_sort" (
    set "PROGRAM_NORMALIZED=bubble_sort"
    set "PROGRAM_LABEL=Bubble Sort.mem"
)
if /I "%RUN_MODE_NORMALIZED%"=="pipeline_full_coverage" (
    set "PROGRAM_NORMALIZED=full_coverage"
    set "PROGRAM_LABEL=Full Coverage.mem"
    set "RUN_ARGS=--pipeline-only --skip-instruction-focus"
    set "RUN_LABEL=Pipeline only ^(5-stage build + report^)"
)
if /I "%RUN_MODE_NORMALIZED%"=="focus_full_coverage" (
    set "PROGRAM_NORMALIZED=full_coverage"
    set "PROGRAM_LABEL=Full Coverage.mem"
    set "RUN_ARGS=--focus-only"
    set "RUN_LABEL=Instruction-focus only ^(reuse base artifacts, rerun all classes/mnemonics^)"
)
if /I "%RUN_MODE_NORMALIZED%"=="pipeline_bubble_sort" (
    set "PROGRAM_NORMALIZED=bubble_sort"
    set "PROGRAM_LABEL=Bubble Sort.mem"
    set "RUN_ARGS=--pipeline-only --skip-instruction-focus"
    set "RUN_LABEL=Pipeline only ^(5-stage build + report^)"
)
if /I "%RUN_MODE_NORMALIZED%"=="focus_bubble_sort" (
    set "PROGRAM_NORMALIZED=bubble_sort"
    set "PROGRAM_LABEL=Bubble Sort.mem"
    set "RUN_ARGS=--focus-only"
    set "RUN_LABEL=Instruction-focus only ^(reuse base artifacts, rerun all classes/mnemonics^)"
)
if /I "%RUN_MODE_NORMALIZED%"=="report_refresh_all" (
    set "RUN_REFRESH_ALL=1"
    set "RUN_LABEL=Report refresh only ^(reuse existing artifacts for all timing program images^)"
)
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
if /I "%RUN_MODE_NORMALIZED%"=="soc_perf" (
    set "PROGRAM_NORMALIZED=full_coverage"
    set "PROGRAM_LABEL=Full Coverage.mem"
    set "RUN_ARGS=--pipeline-only --skip-instruction-focus --include-soc-perf --soc-scenario=soc_perf --soc-profile=demo_fast_io"
    set "RUN_LABEL=SoCPerf + Pipeline Report"
)
set "ARTIFACT_ROOT_DISPLAY=%TARGET_PROJECT%\%OUTPUT_RELATIVE%"
if /I "%RUN_REFRESH_ALL%"=="1" (
    set "ARTIFACT_ROOT_DISPLAY=%TARGET_PROJECT%\%OUTPUT_RELATIVE%\programs"
) else if defined PROGRAM_NORMALIZED (
    set "ARTIFACT_ROOT_DISPLAY=%TARGET_PROJECT%\%OUTPUT_RELATIVE%\programs\%PROGRAM_NORMALIZED%"
)
if /I "%RUN_MODE_NORMALIZED%"=="soc_perf" (
    set "ARTIFACT_ROOT_DISPLAY=%TARGET_PROJECT%\%OUTPUT_RELATIVE%\soc_perf"
)
if /I not "%RUN_REFRESH_ALL%"=="1" if defined PROGRAM_NORMALIZED (
    set "RUN_ARGS=%RUN_ARGS% --program=""%PROGRAM_NORMALIZED%"""
)
if /I not "%RUN_REFRESH_ALL%"=="1" set "RUN_ARGS=%RUN_ARGS% %REPORT_ARG_NAME%=""%REPORT_PATH%"""
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
echo Artifact Root  : "%ARTIFACT_ROOT_DISPLAY%"
echo Report Path    : "%REPORT_PATH%"
echo Run Mode       : %RUN_LABEL%
if /I "%RUN_REFRESH_ALL%"=="1" (
    echo Program Scope  : Full Coverage.mem + Bubble Sort.mem
) else if defined PROGRAM_LABEL (
    echo Program Image  : %PROGRAM_LABEL%
)
if defined FOCUS_FILTER_INPUT (
    echo Focus Filter   : %FOCUS_FILTER_INPUT%
)
if /I "%RUN_MODE_NORMALIZED%"=="soc_perf" (
    echo SoCPerf Scope  : soc_perf / demo_fast_io
)
if /I not "%RUN_MODE_NORMALIZED%"=="reuse" if /I not "%RUN_REFRESH_ALL%"=="1" (
    if defined VIVADO_BAT (
        echo Vivado Bat    : "%VIVADO_BAT%"
    )
)
echo ===============================================================
echo.

call :status "Launching timing analysis Python flow"
if /I "%RUN_REFRESH_ALL%"=="1" (
    call :run_report_refresh_all
) else (
    "%PYTHON_EXE%" %PYTHON_FLAGS% "%RUN_SCRIPT%" %RUN_ARGS%
)
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
for /f "usebackq delims=" %%I in (`powershell.exe -NoProfile -Command "if ($env:VIVADO_BAT -and (Test-Path -LiteralPath $env:VIVADO_BAT)) { [Console]::Write($env:VIVADO_BAT); exit 0 }; $cmd = Get-Command vivado.bat -ErrorAction SilentlyContinue; if (-not $cmd) { $cmd = Get-Command vivado -ErrorAction SilentlyContinue }; if ($cmd) { [Console]::Write($cmd.Source); exit 0 }; exit 1"` ) do set "RESOLVED_VIVADO_BAT=%%I"
if not defined RESOLVED_VIVADO_BAT (
    echo.
    echo [ERROR] Failed to resolve Vivado launcher. Set VIVADO_BAT or add vivado.bat to PATH.
    exit /b 1
)
set "VIVADO_BAT=%RESOLVED_VIVADO_BAT%"
exit /b 0

:configure_pythonpath
if defined PYTHONPATH (
    set "PYTHONPATH=%REPO_ROOT%;%PYTHONPATH%"
) else (
    set "PYTHONPATH=%REPO_ROOT%"
)
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
    echo        - tools\timing\timing_analysis_profile.json
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
            call :has_timing_profile "%%~fD"
            if not errorlevel 1 (
                call set /a TIMING_PROJECT_COUNT+=1
                call set "TIMING_PROJECT_PATH_%%TIMING_PROJECT_COUNT%%=%%~fD"
                call set "TIMING_PROJECT_LABEL_%%TIMING_PROJECT_COUNT%%=..\Project\%%~nxD"
            )
        )
    )
)
exit /b 0

:has_timing_profile
if exist "%~1\tools\timing\timing_analysis_profile.json" exit /b 0
exit /b 1

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
for /f "usebackq delims=" %%I in (`powershell.exe -NoProfile -Command "$item = $null; try { $item = Get-Item -LiteralPath $env:RAW_TARGET_PATH -ErrorAction Stop } catch { exit 2 }; if (-not $item.PSIsContainer) { $item = $item.Directory }; while ($item) { $manifest = Join-Path $item.FullName 'fpga_auto.yml'; $src = Join-Path $item.FullName 'src'; $analysisProfile = Join-Path $item.FullName 'tools\\timing\\timing_analysis_profile.json'; if ((Test-Path -LiteralPath $manifest) -and (Test-Path -LiteralPath $src) -and (Test-Path -LiteralPath $analysisProfile)) { [Console]::Write($item.FullName); exit 0 }; $item = $item.Parent }; exit 3"`) do set "%~2=%%I"
if defined %~2 exit /b 0
exit /b 1

:resolve_profile_path
set "%~2="
if exist "%~1\tools\timing\timing_analysis_profile.json" (
    set "%~2=%~1\tools\timing\timing_analysis_profile.json"
    exit /b 0
)
echo.
echo [ERROR] Missing timing profile under "%~1\tools\timing".
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
    echo [1] Pipeline - FullCoverage
    echo [2] Instruction - FullCoverage
    echo [3] Pipeline - BubbleSort
    echo [4] Instruction - BubbleSort
    echo [5] Report refresh only ^(use when 1-4 failed and you only need report regeneration^)
    echo [6] SoCPerf + Pipeline Report
) else (
    echo [1] FullCoverage
    echo [2] BubbleSort
    echo [3] Report refresh only ^(use when 1-2 failed and you only need report regeneration^)
)
set "RUN_MODE_INPUT="
set /p "RUN_MODE_INPUT=Select mode [1]: "
if not defined RUN_MODE_INPUT set "RUN_MODE_INPUT=1"
set "%~1=%RUN_MODE_INPUT%"
exit /b 0

:normalize_run_mode
set "%~3="
if /I "%RUN_MODE_SOURCE%"=="prompt" (
    if /I "%~2"=="pipeline_perf" (
        if /I "%~1"=="1" set "%~3=pipeline_full_coverage"
        if /I "%~1"=="2" set "%~3=focus_full_coverage"
        if /I "%~1"=="3" set "%~3=pipeline_bubble_sort"
        if /I "%~1"=="4" set "%~3=focus_bubble_sort"
        if /I "%~1"=="5" set "%~3=report_refresh_all"
        if /I "%~1"=="6" set "%~3=soc_perf"
    )
    if /I "%~2"=="single_cycle" (
        if /I "%~1"=="1" set "%~3=single_full_coverage"
        if /I "%~1"=="2" set "%~3=single_bubble_sort"
        if /I "%~1"=="3" set "%~3=report_refresh_all"
    )
)
if /I not "%RUN_MODE_SOURCE%"=="prompt" (
    if /I "%~1"=="1" set "%~3=full"
    if /I "%~1"=="2" set "%~3=reuse"
)
if /I "%~1"=="full" set "%~3=full"
if /I "%~1"=="f" set "%~3=full"
if /I "%~1"=="reuse" set "%~3=reuse"
if /I "%~1"=="r" set "%~3=reuse"
if /I "%~1"=="single_full_coverage" set "%~3=single_full_coverage"
if /I "%~1"=="single-full-coverage" set "%~3=single_full_coverage"
if /I "%~1"=="single_bubble_sort" set "%~3=single_bubble_sort"
if /I "%~1"=="single-bubble-sort" set "%~3=single_bubble_sort"
if /I "%~1"=="pipeline_full_coverage" set "%~3=pipeline_full_coverage"
if /I "%~1"=="pipeline-full-coverage" set "%~3=pipeline_full_coverage"
if /I "%~1"=="focus_full_coverage" set "%~3=focus_full_coverage"
if /I "%~1"=="focus-full-coverage" set "%~3=focus_full_coverage"
if /I "%~1"=="pipeline_bubble_sort" set "%~3=pipeline_bubble_sort"
if /I "%~1"=="pipeline-bubble-sort" set "%~3=pipeline_bubble_sort"
if /I "%~1"=="focus_bubble_sort" set "%~3=focus_bubble_sort"
if /I "%~1"=="focus-bubble-sort" set "%~3=focus_bubble_sort"
if /I "%~1"=="report_refresh_all" set "%~3=report_refresh_all"
if /I "%~1"=="report-refresh-all" set "%~3=report_refresh_all"
if /I "%~1"=="refresh_all" set "%~3=report_refresh_all"
if /I "%~1"=="refresh-all" set "%~3=report_refresh_all"
if /I "%~1"=="program" set "%~3=program_select"
if /I "%~1"=="program-select" set "%~3=program_select"
if /I "%~1"=="ps" set "%~3=program_select"
if /I "%~2"=="pipeline_perf" (
    if /I not "%RUN_MODE_SOURCE%"=="prompt" if /I "%~1"=="3" set "%~3=base"
    if /I "%~1"=="base" set "%~3=base"
    if /I "%~1"=="b" set "%~3=base"
    if /I not "%RUN_MODE_SOURCE%"=="prompt" if /I "%~1"=="4" set "%~3=focus"
    if /I "%~1"=="focus" set "%~3=focus"
    if /I "%~1"=="focus-only" set "%~3=focus"
    if /I "%~1"=="fo" set "%~3=focus"
    if /I not "%RUN_MODE_SOURCE%"=="prompt" if /I "%~1"=="5" set "%~3=focus_partial"
    if /I "%~1"=="focus_partial" set "%~3=focus_partial"
    if /I "%~1"=="focus-partial" set "%~3=focus_partial"
    if /I "%~1"=="partial" set "%~3=focus_partial"
    if /I "%~1"=="fp" set "%~3=focus_partial"
    if /I not "%RUN_MODE_SOURCE%"=="prompt" if /I "%~1"=="6" set "%~3=pipeline_only"
    if /I "%~1"=="pipeline" set "%~3=pipeline_only"
    if /I "%~1"=="pipeline_only" set "%~3=pipeline_only"
    if /I "%~1"=="pipeline-only" set "%~3=pipeline_only"
    if /I "%~1"=="po" set "%~3=pipeline_only"
    if /I not "%RUN_MODE_SOURCE%"=="prompt" if /I "%~1"=="7" set "%~3=program_select"
    if /I not "%RUN_MODE_SOURCE%"=="prompt" if /I "%~1"=="8" set "%~3=soc_perf"
    if /I "%~1"=="soc_perf" set "%~3=soc_perf"
    if /I "%~1"=="soc-perf" set "%~3=soc_perf"
    if /I "%~1"=="pipeline_soc_perf" set "%~3=soc_perf"
    if /I "%~1"=="pipeline-soc-perf" set "%~3=soc_perf"
    if /I "%~1"=="sp" set "%~3=soc_perf"
)
if /I "%~2"=="single_cycle" (
    if /I not "%RUN_MODE_SOURCE%"=="prompt" if /I "%~1"=="3" set "%~3=program_select"
)
if defined %~3 exit /b 0
exit /b 1

:prompt_program_selection
set "PROGRAM_PICK_CURRENT_LABEL=Full Coverage.mem"
if /I "%~1"=="bubble_sort" set "PROGRAM_PICK_CURRENT_LABEL=Bubble Sort.mem"
call :clear_screen
echo.
echo ===============================================================
echo Timing Program Image Selection
echo ===============================================================
echo Current program image: %PROGRAM_PICK_CURRENT_LABEL%
echo.
echo [1] Full Coverage.mem
echo [2] Bubble Sort.mem
echo [Q] Cancel
echo.
choice /c 12Q /n /m "Select program [1/2/Q]: "
if errorlevel 3 exit /b 1
if errorlevel 2 (
    set "%~2=bubble_sort"
    set "%~3=bubble_sort"
    set "%~4=Bubble Sort.mem"
    set "PROGRAM_PICK_CURRENT_LABEL="
    exit /b 0
)
if errorlevel 1 (
    set "%~2=full_coverage"
    set "%~3=full_coverage"
    set "%~4=Full Coverage.mem"
    set "PROGRAM_PICK_CURRENT_LABEL="
    exit /b 0
)
set "PROGRAM_PICK_CURRENT_LABEL="
exit /b 1

:normalize_program_selection
set "%~2="
set "%~3="
if "%~1"=="" (
    set "%~2=full_coverage"
    set "%~3=Full Coverage.mem"
    exit /b 0
)
if /I "%~1"=="full_coverage" (
    set "%~2=full_coverage"
    set "%~3=Full Coverage.mem"
    exit /b 0
)
if /I "%~1"=="full coverage" (
    set "%~2=full_coverage"
    set "%~3=Full Coverage.mem"
    exit /b 0
)
if /I "%~1"=="Full Coverage.mem" (
    set "%~2=full_coverage"
    set "%~3=Full Coverage.mem"
    exit /b 0
)
if /I "%~1"=="bubble_sort" (
    set "%~2=bubble_sort"
    set "%~3=Bubble Sort.mem"
    exit /b 0
)
if /I "%~1"=="bubble sort" (
    set "%~2=bubble_sort"
    set "%~3=Bubble Sort.mem"
    exit /b 0
)
if /I "%~1"=="Bubble Sort.mem" (
    set "%~2=bubble_sort"
    set "%~3=Bubble Sort.mem"
    exit /b 0
)
exit /b 1

:parse_optional_args
set "%~1="
set "%~2="
set "PARSE_PROGRAM_VAR=%~1"
set "PARSE_FOCUS_VAR=%~2"
shift
shift
set "PARSE_PROGRAM_VALUE="
set "PARSE_FOCUS_VALUE="

:PARSE_OPTIONAL_ARGS_LOOP
if "%~1"=="" goto :PARSE_OPTIONAL_ARGS_DONE
set "PARSE_TOKEN=%~1"
if /I "%~1"=="--program" (
    if "%~2"=="" exit /b 1
    set "PARSE_PROGRAM_VALUE=%~2"
    shift
    shift
    goto :PARSE_OPTIONAL_ARGS_LOOP
)
echo(%PARSE_TOKEN%| findstr /b /i "--program=" >nul
if not errorlevel 1 (
    set "PARSE_PROGRAM_VALUE=%PARSE_TOKEN:~10%"
    shift
    goto :PARSE_OPTIONAL_ARGS_LOOP
)
if not defined PARSE_FOCUS_VALUE (
    set "PARSE_FOCUS_VALUE=%PARSE_TOKEN%"
) else (
    set "PARSE_FOCUS_VALUE=%PARSE_FOCUS_VALUE% %PARSE_TOKEN%"
)
shift
goto :PARSE_OPTIONAL_ARGS_LOOP

:PARSE_OPTIONAL_ARGS_DONE
call set "%PARSE_PROGRAM_VAR%=%%PARSE_PROGRAM_VALUE%%"
call set "%PARSE_FOCUS_VAR%=%%PARSE_FOCUS_VALUE%%"
set "PARSE_PROGRAM_VAR="
set "PARSE_FOCUS_VAR="
set "PARSE_PROGRAM_VALUE="
set "PARSE_FOCUS_VALUE="
set "PARSE_TOKEN="
exit /b 0

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

:run_report_refresh_all
set "RUN_REFRESH_COMMAND_RC=0"
for %%P in (full_coverage bubble_sort) do (
    call :status "Refreshing report data for %%P"
    if /I "%ANALYSIS_MODE%"=="pipeline_perf" (
        "%PYTHON_EXE%" %PYTHON_FLAGS% "%RUN_SCRIPT%" --skip-vivado --program="%%P" %REPORT_ARG_NAME%="%REPORT_PATH%"
    ) else (
        "%PYTHON_EXE%" %PYTHON_FLAGS% "%RUN_SCRIPT%" --reuse-existing --program="%%P" %REPORT_ARG_NAME%="%REPORT_PATH%"
    )
    if errorlevel 1 (
        set "RUN_REFRESH_COMMAND_RC=1"
        goto :RUN_REPORT_REFRESH_ALL_DONE
    )
)

:RUN_REPORT_REFRESH_ALL_DONE
exit /b %RUN_REFRESH_COMMAND_RC%

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
