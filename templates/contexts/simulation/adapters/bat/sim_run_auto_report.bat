@echo off
setlocal enabledelayedexpansion
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
set "CONSOLE_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\console_ui.bat"
set "USER_CANCEL_RC=99"
set "PROMPT_WARNING="

:: ============================================================================
:: HDL FPGA Automation Pipeline
:: Usage: bat\sim_report_auto_run.bat
:: Description: Scans testbenches and runs simulation.
:: ============================================================================

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^>
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

set "WORKSPACE_ROOT=%~f1"
set "TOOLS_ROOT=%TEMPLATES_ROOT%"
set "LAUNCH_CWD=%CD%"
set "LOG_DIR=%WORKSPACE_ROOT%\log"
set "MANIFEST_CTX=%TEMPLATES_ROOT%\shared\adapters\bat\bootstrap_manifest_context.bat"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
call :route_vivado_artifacts "%WORKSPACE_ROOT%" "%LAUNCH_CWD%"
call :route_vivado_artifacts "%WORKSPACE_ROOT%" "%WORKSPACE_ROOT%"
call :route_vivado_artifacts "%WORKSPACE_ROOT%" "%WORKSPACE_ROOT%\work"

call "%MANIFEST_CTX%" "%WORKSPACE_ROOT%"
if errorlevel 1 (
    echo [ERROR] Manifest context initialization failed.
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

echo ============================================================================
echo      HDL Auto Simulation ^& Report
echo ============================================================================
echo Scanning testbench files from manifest list in: %WORKSPACE_ROOT%

:: 1. Scan for Testbench Files
set count=0
for /f "usebackq delims=" %%R in ("%MANIFEST_TB_LIST%") do (
    if not "%%R"=="" (
        set "TB_REL_RAW=%%R"
        set "TB_REL_WIN=!TB_REL_RAW:/=\!"
        if exist "%WORKSPACE_ROOT%\!TB_REL_WIN!" (
            set /a count+=1
            for %%A in ("%WORKSPACE_ROOT%\!TB_REL_WIN!") do (
                set "TB_FILE_!count!=%%~fA"
                set "TB_NAME_!count!=%%~nxA"
                set "TB_REL_!count!=!TB_REL_RAW!"
            )
        ) else (
            echo [WARNING] Manifest TB file missing on disk: !TB_REL_RAW!
        )
    )
)

if !count!==0 (
    echo [ERROR] No testbench files resolved from manifest in: %WORKSPACE_ROOT%
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

:: 3. User Selection
:PROMPT
call :render_tb_prompt
set /p "selection=Select Testbench Number (1-%count%): "
if /i "%selection%"=="Q" exit /b %USER_CANCEL_RC%

:: Validate input
if "%selection%"=="" (
    set "PROMPT_WARNING=[WARN] Enter a testbench number."
    goto PROMPT
)
set /a selection_num=%selection% 2>nul
if errorlevel 1 (
    set "PROMPT_WARNING=[WARN] Invalid selection: %selection%"
    goto PROMPT
)
if %selection_num% LSS 1 (
    set "PROMPT_WARNING=[WARN] Selection out of range: %selection_num%"
    goto PROMPT
)
if %selection_num% GTR %count% (
    set "PROMPT_WARNING=[WARN] Selection out of range: %selection_num%"
    goto PROMPT
)
set "selection=%selection_num%"

:: Get selected file path
set "TB_FILE_PATH=!TB_FILE_%selection%!"

echo.
echo ============================================================================
echo [Step 1/2] Analyzing Testbench: !TB_NAME_%selection%!
echo Path: %TB_FILE_PATH%
echo ============================================================================

:: 4. Run Parse TB (Using TOOLS_ROOT)
call node "%TOOLS_ROOT%\contexts\simulation\adapters\cli\sim_parse_tb_cli.js" "%TB_FILE_PATH%" "%WORKSPACE_ROOT%" --manifest-json "%MANIFEST_JSON%"
if errorlevel 1 (
    echo [FAILURE] Failed to parse testbench and generate config.
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

set "CONFIG_PATH=%WORKSPACE_ROOT%\sim_config.json"
echo Target Config: %CONFIG_PATH%

if not exist "%CONFIG_PATH%" (
    echo [ERROR] Configuration file was not generated at expected path: %CONFIG_PATH%
    echo Please check if parse_tb.js generated it in the correct project folder.
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

echo.
echo [Info] Scenario extraction rule: TEST CASE + @WAVE + @RUNTIME BEGIN:time / END:time
echo [Info] Extracted scenario windows:
for /f "usebackq delims=" %%L in (`powershell -NoProfile -Command "$cfg = Get-Content -Path '%CONFIG_PATH%' -Raw | ConvertFrom-Json; if ($cfg.scenarios.Count -eq 0) { Write-Output '[Scenario] none'; } else { $cfg.scenarios | ForEach-Object { Write-Output ('[Scenario] ' + $_.title + ', start=' + $_.start_ns + 'ns, runtime=' + $_.duration_ns + 'ns') } }"`) do (
    echo %%L
)

:: 5. Run Gen Report (Using TOOLS_ROOT)
echo.
echo ============================================================================
echo [Step 2/2] Running Simulation ^& Generating Report
echo ============================================================================
call node "%TOOLS_ROOT%\contexts\simulation\adapters\cli\sim_generate_report_cli.js" "%CONFIG_PATH%" --manifest-json "%MANIFEST_JSON%"
if errorlevel 1 (
    echo [FAILURE] Simulation or Report Generation failed.
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)
call :route_vivado_artifacts "%WORKSPACE_ROOT%" "%LAUNCH_CWD%"
call :route_vivado_artifacts "%WORKSPACE_ROOT%" "%WORKSPACE_ROOT%"
call :route_vivado_artifacts "%WORKSPACE_ROOT%" "%WORKSPACE_ROOT%\work"

echo.
echo ============================================================================
echo [SUCCESS] Automation Complete!
echo Report Directory: %WORKSPACE_ROOT%\output\
echo ============================================================================
call "%CONSOLE_HELPER%" pause_then_clear
exit /b 0

:render_tb_prompt
call "%CONSOLE_HELPER%" banner "HDL Auto Simulation & Report" "Target: %WORKSPACE_ROOT%" "Manifest-resolved testbenches: !count!"
echo Scanning testbench files from manifest list in: %WORKSPACE_ROOT%
echo.
if defined PROMPT_WARNING (
    echo %PROMPT_WARNING%
    echo.
)
set "PROMPT_WARNING="
echo Found !count! testbench(es):
echo ----------------------------------------------------------------------------
for /L %%i in (1,1,%count%) do (
    echo [%%i] !TB_NAME_%%i!   (Location: !TB_REL_%%i!)
)
echo ----------------------------------------------------------------------------
echo Option: Q = cancel
echo.
exit /b 0

:route_vivado_artifacts
set "ROUTE_TARGET=%~f1"
set "ROUTE_SCAN=%~f2"
if "%ROUTE_TARGET%"=="" exit /b 0
if "%ROUTE_SCAN%"=="" exit /b 0

set "ROUTE_LOG=%ROUTE_TARGET%\log"
if not exist "%ROUTE_LOG%" mkdir "%ROUTE_LOG%" >nul 2>&1
if not exist "%ROUTE_SCAN%" exit /b 0

pushd "%ROUTE_SCAN%" >nul 2>&1
for %%F in (vivado.log vivado.jou vivado.pb vivado.str) do (
    if exist "%%F" move /y "%%F" "%ROUTE_LOG%\" >nul 2>&1
)
for %%F in (vivado_*.backup.log vivado_*.backup.jou vivado_*.backup.str *.backup.log *.backup.jou *.backup.str) do (
    if exist "%%F" move /y "%%F" "%ROUTE_LOG%\" >nul 2>&1
)
popd >nul 2>&1
exit /b 0
