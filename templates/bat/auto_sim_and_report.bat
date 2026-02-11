@echo off
setlocal enabledelayedexpansion

:: ============================================================================
:: Verilog FPGA Automation Pipeline
:: Usage: bat\auto_sim_and_report.bat
:: Description: Scans testbenches and runs simulation.
:: ============================================================================

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^>
    pause
    exit /b 1
)

set "WORKSPACE_ROOT=%~f1"
set "TOOLS_ROOT=%~dp0.."

echo ============================================================================
echo      Verilog Auto Simulation ^& Report
echo ============================================================================
echo Scanning for testbench files [tb_*.v] in: %WORKSPACE_ROOT%

:: 1. Scan for Testbench Files
set count=0
pushd "%WORKSPACE_ROOT%"
for /r %%F in (tb_*.v) do (
    set /a count+=1
    set "TB_FILE_!count!=%%F"
    set "TB_NAME_!count!=%%~nxF"
    set "TB_REL_!count!=%%~pF"
)
popd

if !count!==0 (
    echo [ERROR] No testbench files [tb_*.v] found in: %WORKSPACE_ROOT%
    pause
    exit /b 1
)

:: 2. Display Menu
echo.
echo Found !count! testbench(es):
echo ----------------------------------------------------------------------------
for /L %%i in (1,1,%count%) do (
    echo [%%i] !TB_NAME_%%i!   (Location: !TB_REL_%%i!)
)
echo ----------------------------------------------------------------------------

:: 3. User Selection
:PROMPT
set /p "selection=Select Testbench Number (1-%count%): "

:: Validate input
if "%selection%"=="" goto PROMPT
set /a selection_num=%selection% 2>nul
if errorlevel 1 goto PROMPT
if %selection_num% LSS 1 goto PROMPT
if %selection_num% GTR %count% goto PROMPT
set "selection=%selection_num%"

:: Get selected file path
set "TB_FILE_PATH=!TB_FILE_%selection%!"

echo.
echo ============================================================================
echo [Step 1/2] Analyzing Testbench: !TB_NAME_%selection%!
echo Path: %TB_FILE_PATH%
echo ============================================================================

:: 4. Run Parse TB (Using TOOLS_ROOT)
call node "%TOOLS_ROOT%\tools\parse_tb.js" "%TB_FILE_PATH%" "%WORKSPACE_ROOT%"
if errorlevel 1 (
    echo [FAILURE] Failed to parse testbench and generate config.
    pause
    exit /b 1
)

set "CONFIG_PATH=%WORKSPACE_ROOT%\sim_config.json"
echo Target Config: %CONFIG_PATH%

if not exist "%CONFIG_PATH%" (
    echo [ERROR] Configuration file was not generated at expected path: %CONFIG_PATH%
    echo Please check if parse_tb.js generated it in the correct project folder.
    pause
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
call node "%TOOLS_ROOT%\tools\generate_report.js" "%CONFIG_PATH%"
if errorlevel 1 (
    echo [FAILURE] Simulation or Report Generation failed.
    pause
    exit /b 1
)

echo.
echo ============================================================================
echo [SUCCESS] Automation Complete!
echo Report Directory: %WORKSPACE_ROOT%\output\
echo ============================================================================
pause
exit /b 0
