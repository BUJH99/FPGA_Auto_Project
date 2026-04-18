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
set "MANIFEST_CTX=%TEMPLATES_ROOT%\shared\adapters\bat\bootstrap_manifest_context.bat"
set "VIVADO_ENV_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\ensure_vivado_on_path.bat"
if exist "%MANIFEST_CTX%" (
    call "%MANIFEST_CTX%" "%TARGET_PROJECT%"
    if errorlevel 1 (
        echo [ERROR] Manifest context initialization failed.
        call :maybe_pause
        exit /b 1
    )
)
cd /d "%TARGET_PROJECT%"
echo Target Project: %TARGET_PROJECT%

set "LOG_DIR=%TARGET_PROJECT%\log"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%"
set "PROGRAM_LOG=%LOG_DIR%\vivado_program.log"
set "PROGRAM_JOU=%LOG_DIR%\vivado_program.jou"
set "DISCOVERY_LOG=%LOG_DIR%\vivado_hw_discovery.log"
set "DISCOVERY_JOU=%LOG_DIR%\vivado_hw_discovery.jou"
set "HW_TARGETS_FILE=%LOG_DIR%\vivado_hw_targets.txt"
set "SELECTED_TARGET_INDEX=%FPGA_TARGET_INDEX%"
set "SELECTED_DEVICE_INDEX=%FPGA_DEVICE_INDEX%"
call :route_vivado_artifacts

set "NO_PAUSE=0"
if /i "%~2"=="--no-pause" set "NO_PAUSE=1"

echo ===========================================
echo   Vivado Batch Mode - Program Device
echo ===========================================

:: Check Vivado command availability
if exist "%VIVADO_ENV_HELPER%" call "%VIVADO_ENV_HELPER%" --quiet >nul 2>nul
where vivado >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] Vivado executable not found in PATH.
    echo         Check VIVADO_BIN or AMD/Xilinx default install paths.
    call :maybe_pause
    exit /b 1
)

call :prompt_run_or_cancel
set "PROMPT_RC=%errorlevel%"
if "%PROMPT_RC%"=="%USER_CANCEL_RC%" exit /b %USER_CANCEL_RC%

if not exist output mkdir output
call :select_hw_target
set "SELECT_TARGET_RC=%errorlevel%"
if "%SELECT_TARGET_RC%"=="%USER_CANCEL_RC%" exit /b %USER_CANCEL_RC%
if %SELECT_TARGET_RC% neq 0 (
    echo [ERROR] Hardware programming target selection failed.
    call :maybe_pause
    exit /b %SELECT_TARGET_RC%
)

echo [INFO] Programming target index !SELECTED_TARGET_INDEX!, device index !SELECTED_DEVICE_INDEX!.
set "FPGA_TARGET_INDEX=!SELECTED_TARGET_INDEX!"
set "FPGA_DEVICE_INDEX=!SELECTED_DEVICE_INDEX!"

:: Run Hardware Manager script in batch mode
call vivado -mode batch -source "%TEMPLATES_ROOT%\contexts\vivado\adapters\tcl\vivado_program_device.tcl" -notrace -log "%PROGRAM_LOG%" -journal "%PROGRAM_JOU%"
set "PROGRAM_RC=%errorlevel%"
call :route_vivado_artifacts

if %PROGRAM_RC% neq 0 (
    echo.
    echo [!] Programming Failed! Check connection or logs in %LOG_DIR%.
    call :maybe_pause
    exit /b %PROGRAM_RC%
)

echo.
echo [Done] You can close this window.
call :maybe_pause
exit /b 0

:maybe_pause
if "%NO_PAUSE%"=="1" exit /b 0
call "%CONSOLE_HELPER%" pause_then_clear
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

:select_hw_target
if exist "%HW_TARGETS_FILE%" del /q "%HW_TARGETS_FILE%" >nul 2>&1
set "PROGRAM_CANDIDATE_COUNT=0"
set "FPGA_HW_TARGETS_FILE=%HW_TARGETS_FILE%"

echo.
echo [SCAN] Detecting connected programmable hardware devices...
call vivado -mode batch -source "%TEMPLATES_ROOT%\contexts\vivado\adapters\tcl\vivado_list_hw_targets.tcl" -notrace -log "%DISCOVERY_LOG%" -journal "%DISCOVERY_JOU%"
set "DISCOVERY_RC=%errorlevel%"
call :route_vivado_artifacts

if %DISCOVERY_RC% neq 0 (
    echo [ERROR] Vivado hardware discovery failed. Check %DISCOVERY_LOG%.
    exit /b %DISCOVERY_RC%
)

if not exist "%HW_TARGETS_FILE%" (
    echo [ERROR] Hardware target list was not generated.
    exit /b 1
)

for /f "usebackq tokens=1,2,3* delims=|" %%A in ("%HW_TARGETS_FILE%") do (
    set /a PROGRAM_CANDIDATE_COUNT+=1 >nul
    set "HW_SELECTION_TARGET_%%A=%%B"
    set "HW_SELECTION_DEVICE_%%A=%%C"
    set "HW_SELECTION_LABEL_%%A=%%D"
)

if !PROGRAM_CANDIDATE_COUNT! leq 0 (
    echo [ERROR] No programmable hardware devices were detected.
    exit /b 1
)
set /a LAST_CANDIDATE_INDEX=PROGRAM_CANDIDATE_COUNT-1 >nul

if defined SELECTED_TARGET_INDEX (
    if defined SELECTED_DEVICE_INDEX (
        call :find_candidate_for_pair "!SELECTED_TARGET_INDEX!" "!SELECTED_DEVICE_INDEX!"
        if errorlevel 1 (
            echo [ERROR] FPGA_TARGET_INDEX=!SELECTED_TARGET_INDEX! and FPGA_DEVICE_INDEX=!SELECTED_DEVICE_INDEX! do not match a detected device.
            call :print_hw_targets
            exit /b 1
        )
        echo [INFO] Using preselected target/device indices !SELECTED_TARGET_INDEX!/!SELECTED_DEVICE_INDEX!.
        exit /b 0
    )
    call :find_first_candidate_for_target "!SELECTED_TARGET_INDEX!"
    if errorlevel 1 (
        echo [ERROR] FPGA_TARGET_INDEX=!SELECTED_TARGET_INDEX! is out of range.
        call :print_hw_targets
        exit /b 1
    )
    echo [INFO] Using preselected target index !SELECTED_TARGET_INDEX! from FPGA_TARGET_INDEX and defaulting to device index !SELECTED_DEVICE_INDEX!.
    exit /b 0
)

if !PROGRAM_CANDIDATE_COUNT! equ 1 (
    call :load_candidate "0"
    echo [INFO] One programmable hardware device detected. Auto-selecting index 0.
    exit /b 0
)

call :print_hw_targets

:prompt_target_index
echo.
set "SELECTED_PROGRAM_INDEX="
set /p "SELECTED_PROGRAM_INDEX=Select programmable hardware index (or Q to cancel): "
if /i "!SELECTED_PROGRAM_INDEX!"=="Q" exit /b %USER_CANCEL_RC%
call :validate_candidate_index "!SELECTED_PROGRAM_INDEX!"
if errorlevel 1 (
    echo [WARN] Invalid hardware index. Enter a number from 0 to !LAST_CANDIDATE_INDEX!.
    goto prompt_target_index
)
call :load_candidate "!SELECTED_PROGRAM_INDEX!"
exit /b 0

:print_hw_targets
echo [INFO] Multiple programmable hardware devices detected:
for /l %%I in (0,1,!LAST_CANDIDATE_INDEX!) do (
    echo   [%%I] !HW_SELECTION_LABEL_%%I!
)
exit /b 0

:validate_candidate_index
set "CANDIDATE_INDEX_CANDIDATE=%~1"
if not defined CANDIDATE_INDEX_CANDIDATE exit /b 1
echo(%CANDIDATE_INDEX_CANDIDATE%| findstr /r "^[0-9][0-9]*$" >nul
if errorlevel 1 exit /b 1
if %CANDIDATE_INDEX_CANDIDATE% geq %PROGRAM_CANDIDATE_COUNT% exit /b 1
exit /b 0

:load_candidate
set "CANDIDATE_INDEX=%~1"
call set "SELECTED_TARGET_INDEX=%%HW_SELECTION_TARGET_%CANDIDATE_INDEX%%%"
call set "SELECTED_DEVICE_INDEX=%%HW_SELECTION_DEVICE_%CANDIDATE_INDEX%%%"
exit /b 0

:find_candidate_for_pair
set "PAIR_TARGET_INDEX=%~1"
set "PAIR_DEVICE_INDEX=%~2"
set "MATCHED_CANDIDATE_INDEX="
for /l %%I in (0,1,!LAST_CANDIDATE_INDEX!) do (
    if "!HW_SELECTION_TARGET_%%I!"=="!PAIR_TARGET_INDEX!" if "!HW_SELECTION_DEVICE_%%I!"=="!PAIR_DEVICE_INDEX!" set "MATCHED_CANDIDATE_INDEX=%%I"
)
if not defined MATCHED_CANDIDATE_INDEX exit /b 1
call :load_candidate "!MATCHED_CANDIDATE_INDEX!"
exit /b 0

:find_first_candidate_for_target
set "PAIR_TARGET_INDEX=%~1"
set "MATCHED_CANDIDATE_INDEX="
for /l %%I in (0,1,!LAST_CANDIDATE_INDEX!) do (
    if "!HW_SELECTION_TARGET_%%I!"=="!PAIR_TARGET_INDEX!" if not defined MATCHED_CANDIDATE_INDEX set "MATCHED_CANDIDATE_INDEX=%%I"
)
if not defined MATCHED_CANDIDATE_INDEX exit /b 1
call :load_candidate "!MATCHED_CANDIDATE_INDEX!"
exit /b 0
