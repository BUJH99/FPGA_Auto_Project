@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "TARGET_PROJECT="
set "TB_FILTER="
set "FORCE_ALL=0"
set "NO_PAUSE=0"
set "EXPECT_TB_VALUE=0"

:parse_args
if "%~1"=="" goto args_done
if "%EXPECT_TB_VALUE%"=="1" (
    set "TB_FILTER=%~1"
    set "EXPECT_TB_VALUE=0"
) else if /i "%~1"=="--no-pause" (
    set "NO_PAUSE=1"
) else if /i "%~1"=="--all" (
    set "FORCE_ALL=1"
) else if /i "%~1"=="--tb" (
    set "EXPECT_TB_VALUE=1"
) else (
    set "ARG=%~1"
    if /i "!ARG:~0,5!"=="--tb=" (
        set "TB_FILTER=!ARG:~5!"
    ) else if not defined TARGET_PROJECT (
        set "TARGET_PROJECT=%~f1"
    ) else if not defined TB_FILTER (
        set "TB_FILTER=%~1"
    ) else (
        echo [WARNING] Ignoring extra argument: %~1
    )
)
shift
goto parse_args

:args_done
if "%EXPECT_TB_VALUE%"=="1" (
    echo [ERROR] --tb requires a value.
    goto usage_error
)
if not defined TARGET_PROJECT goto usage_error

if not exist "%TARGET_PROJECT%" (
    echo [ERROR] Target project not found: %TARGET_PROJECT%
    if "%NO_PAUSE%"=="0" pause
    exit /b 1
)

where iverilog >nul 2>nul
if errorlevel 1 (
    echo [ERROR] iverilog not found in PATH.
    echo [INFO] Install Icarus Verilog and add it to PATH.
    if "%NO_PAUSE%"=="0" pause
    exit /b 1
)

where vvp >nul 2>nul
if errorlevel 1 (
    echo [ERROR] vvp not found in PATH.
    echo [INFO] Install Icarus Verilog and add it to PATH.
    if "%NO_PAUSE%"=="0" pause
    exit /b 1
)

set "SRC_DIR=%TARGET_PROJECT%\src"
set "TB_DIR=%TARGET_PROJECT%\tb"
set "OUT_DIR=%TARGET_PROJECT%\output\iverilog"
set "VCD_DIR=%TARGET_PROJECT%\vcd"

if not exist "%SRC_DIR%" (
    echo [ERROR] src folder not found: %SRC_DIR%
    if "%NO_PAUSE%"=="0" pause
    exit /b 1
)
if not exist "%TB_DIR%" (
    echo [ERROR] tb folder not found: %TB_DIR%
    if "%NO_PAUSE%"=="0" pause
    exit /b 1
)

if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"
if not exist "%VCD_DIR%" mkdir "%VCD_DIR%"

set /a RUN_COUNT=0
set /a PASS_COUNT=0
set /a FAIL_COUNT=0
set /a SEL_COUNT=0

echo ===============================================================================
echo [Iverilog VCD] Compile and run testbenches
echo Target    : %TARGET_PROJECT%
echo VCD output: %VCD_DIR%
echo ===============================================================================

if defined TB_FILTER (
    call :resolve_tb_file "%TB_FILTER%"
    if errorlevel 1 (
        if "%NO_PAUSE%"=="0" pause
        exit /b 1
    )
    call :add_selected "!RESOLVED_TB!"
) else if "%FORCE_ALL%"=="1" (
    call :queue_all_tbs
) else (
    call :interactive_select_tbs
)

if %SEL_COUNT% EQU 0 (
    echo [WARNING] No testbench selected.
    if "%NO_PAUSE%"=="0" pause
    exit /b 1
)

for /L %%I in (1,1,%SEL_COUNT%) do (
    call :run_one "!SEL_%%I!"
)

echo.
echo [DONE] selected=%SEL_COUNT% total=%RUN_COUNT% pass=%PASS_COUNT% fail=%FAIL_COUNT%

if %FAIL_COUNT% GTR 0 (
    if "%NO_PAUSE%"=="0" pause
    exit /b 1
)

if "%NO_PAUSE%"=="0" pause
exit /b 0

:queue_all_tbs
set /a TB_COUNT=0
for %%F in ("%TB_DIR%\tb_*.v") do (
    if exist "%%~fF" (
        set /a TB_COUNT+=1
        set "TB_!TB_COUNT!=%%~fF"
    )
)
if !TB_COUNT! EQU 0 (
    echo [ERROR] No testbench files found in: %TB_DIR%\tb_*.v
    exit /b 1
)
for /L %%I in (1,1,!TB_COUNT!) do (
    call :add_selected "!TB_%%I!"
)
exit /b 0

:interactive_select_tbs
set /a TB_COUNT=0
for %%F in ("%TB_DIR%\tb_*.v") do (
    if exist "%%~fF" (
        set /a TB_COUNT+=1
        set "TB_!TB_COUNT!=%%~fF"
    )
)

if !TB_COUNT! EQU 0 (
    echo [ERROR] No testbench files found in: %TB_DIR%\tb_*.v
    exit /b 1
)

echo.
echo Select TBs to run:
for /L %%I in (1,1,!TB_COUNT!) do (
    for %%P in ("!TB_%%I!") do echo   [%%I] %%~nxP
)
echo.
echo Example input: 1 3 5
echo Option: A = all, Q = cancel

:interactive_prompt
set "TB_PICK="
set /p "TB_PICK=Select TB numbers: "
if "!TB_PICK!"=="" goto interactive_prompt
if /i "!TB_PICK!"=="Q" exit /b 1
if /i "!TB_PICK!"=="A" (
    call :queue_all_tbs
    exit /b 0
)

set "TB_PICK=!TB_PICK:,= !"
set /a SEL_COUNT=0
for %%T in (!TB_PICK!) do call :add_index "%%~T" "!TB_COUNT!"

if !SEL_COUNT! EQU 0 (
    echo [ERROR] No valid selection. Try again.
    goto interactive_prompt
)
exit /b 0

:add_index
set "IDX=%~1"
set "MAX=%~2"
echo(!IDX!| findstr /r "^[0-9][0-9]*$" >nul
if errorlevel 1 (
    echo [WARNING] Skip invalid token: !IDX!
    exit /b 0
)
if !IDX! lss 1 (
    echo [WARNING] Skip out-of-range index: !IDX!
    exit /b 0
)
if !IDX! gtr !MAX! (
    echo [WARNING] Skip out-of-range index: !IDX!
    exit /b 0
)
call :add_selected "!TB_%IDX%!"
exit /b 0

:add_selected
set "CAND=%~1"
if not defined CAND exit /b 0
set "DUP=0"
for /L %%I in (1,1,%SEL_COUNT%) do (
    if /i "!SEL_%%I!"=="!CAND!" set "DUP=1"
)
if "!DUP!"=="1" exit /b 0
set /a SEL_COUNT+=1
set "SEL_%SEL_COUNT%=%CAND%"
exit /b 0

:resolve_tb_file
set "REQ=%~1"
set "RESOLVED_TB="

if exist "%REQ%" (
    for %%I in ("%REQ%") do set "RESOLVED_TB=%%~fI"
    exit /b 0
)

if exist "%TB_DIR%\%REQ%" (
    for %%I in ("%TB_DIR%\%REQ%") do set "RESOLVED_TB=%%~fI"
    exit /b 0
)

if exist "%TB_DIR%\%REQ%.v" (
    for %%I in ("%TB_DIR%\%REQ%.v") do set "RESOLVED_TB=%%~fI"
    exit /b 0
)

echo [ERROR] TB file not found for: %REQ%
echo [INFO] Try one of:
echo [INFO]  - tb_top
echo [INFO]  - tb_top.v
echo [INFO]  - %TB_DIR%\tb_top.v
exit /b 1

:run_one
set "TB_FILE=%~1"
for %%I in ("%TB_FILE%") do (
    set "TB_STEM=%%~nI"
)
set "VVP_OUT=%OUT_DIR%\%TB_STEM%.out"
set "FILELIST=%OUT_DIR%\%TB_STEM%_files.f"

call :write_filelist "%FILELIST%" "%TB_FILE%"

echo.
echo [RUN] %TB_STEM%
iverilog -g2012 -o "%VVP_OUT%" -s "%TB_STEM%" -I "%SRC_DIR%" -I "%TB_DIR%" -f "%FILELIST%"
if errorlevel 1 (
    echo [FAIL] Compile failed: %TB_STEM%
    set /a RUN_COUNT+=1
    set /a FAIL_COUNT+=1
    exit /b 0
)

pushd "%VCD_DIR%" >nul
vvp "%VVP_OUT%"
set "RUN_RC=%errorlevel%"
popd >nul

set /a RUN_COUNT+=1
if not "%RUN_RC%"=="0" (
    echo [FAIL] Simulation failed: %TB_STEM% ^(rc=%RUN_RC%^)
    set /a FAIL_COUNT+=1
    exit /b 0
)

echo [PASS] %TB_STEM%
set /a PASS_COUNT+=1
exit /b 0

:write_filelist
set "OUT_F=%~1"
set "TB_F=%~2"
(
    for %%S in ("%SRC_DIR%\*.v") do @if exist "%%~fS" echo %%~fS
    for %%S in ("%SRC_DIR%\*.sv") do @if exist "%%~fS" echo %%~fS
    echo %TB_F%
) > "%OUT_F%"
exit /b 0

:usage_error
echo [ERROR] No target project path provided.
echo Usage: %~nx0 ^<Project_Directory^> [tb_name_or_file] [--tb ^<tb_name_or_file^>] [--all] [--no-pause]
if "%NO_PAUSE%"=="0" pause
exit /b 1
