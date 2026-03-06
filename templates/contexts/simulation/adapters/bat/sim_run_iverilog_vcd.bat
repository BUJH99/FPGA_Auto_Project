@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
set "USER_CANCEL_RC=99"

set "TARGET_PROJECT="
set "TB_FILTER="
set "FORCE_ALL=0"
set "NO_PAUSE=0"
set "EXPECT_TB_VALUE=0"
set "SCRIPT_DIR=%~dp0"
set "MANIFEST_CTX=%TEMPLATES_ROOT%\shared\adapters\bat\bootstrap_manifest_context.bat"
set "MANIFEST_FILE=fpga_auto.yml"
set "MANIFEST_JSON="
set "MANIFEST_SRC_LIST="
set "MANIFEST_TB_LIST="
set "MANIFEST_INC_LIST="

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

if not exist "%OUT_DIR%" mkdir "%OUT_DIR%" >nul 2>nul
if not exist "%VCD_DIR%" mkdir "%VCD_DIR%" >nul 2>nul

call "%MANIFEST_CTX%" "%TARGET_PROJECT%"
if errorlevel 1 (
    echo [ERROR] Manifest context initialization failed.
    if "%NO_PAUSE%"=="0" pause
    exit /b 1
)

set /a RUN_COUNT=0
set /a PASS_COUNT=0
set /a FAIL_COUNT=0
set /a SEL_COUNT=0

echo ===============================================================================
echo [Iverilog VCD] Compile and run testbenches
echo Target    : %TARGET_PROJECT%
echo VCD output: %VCD_DIR%
echo Mode      : manifest ^(%MANIFEST_FILE%^)
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
    set "SELECT_RC=!errorlevel!"
    if "!SELECT_RC!"=="%USER_CANCEL_RC%" exit /b %USER_CANCEL_RC%
    if not "!SELECT_RC!"=="0" (
        if "%NO_PAUSE%"=="0" pause
        exit /b !SELECT_RC!
    )
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
call :populate_tb_candidates
if errorlevel 1 exit /b 1
for /L %%I in (1,1,!TB_COUNT!) do (
    call :add_selected "!TB_%%I!"
)
exit /b 0

:interactive_select_tbs
call :populate_tb_candidates
if errorlevel 1 exit /b 1

echo.
echo Select TBs to run:
for /L %%I in (1,1,!TB_COUNT!) do (
    echo   [%%I] !TB_REL_%%I!
)
echo.
echo Example input: 1 3 5
echo Option: A = all, Q = cancel

:interactive_prompt
set "TB_PICK="
set /p "TB_PICK=Select TB numbers: "
if "!TB_PICK!"=="" goto interactive_prompt
if /i "!TB_PICK!"=="Q" exit /b %USER_CANCEL_RC%
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

call :populate_tb_candidates_manifest
if errorlevel 1 exit /b 1

if exist "%REQ%" (
    for %%I in ("%REQ%") do set "RESOLVED_TB=%%~fI"
)

if not defined RESOLVED_TB if exist "%TARGET_PROJECT%\%REQ%" (
    for %%I in ("%TARGET_PROJECT%\%REQ%") do set "RESOLVED_TB=%%~fI"
)
if not defined RESOLVED_TB if exist "%TB_DIR%\%REQ%" (
    for %%I in ("%TB_DIR%\%REQ%") do set "RESOLVED_TB=%%~fI"
)

if not defined RESOLVED_TB if exist "%TARGET_PROJECT%\%REQ%.v" (
    for %%I in ("%TARGET_PROJECT%\%REQ%.v") do set "RESOLVED_TB=%%~fI"
)
if not defined RESOLVED_TB if exist "%TARGET_PROJECT%\%REQ%.sv" (
    for %%I in ("%TARGET_PROJECT%\%REQ%.sv") do set "RESOLVED_TB=%%~fI"
)
if not defined RESOLVED_TB if exist "%TB_DIR%\%REQ%.v" (
    for %%I in ("%TB_DIR%\%REQ%.v") do set "RESOLVED_TB=%%~fI"
)
if not defined RESOLVED_TB if exist "%TB_DIR%\%REQ%.sv" (
    for %%I in ("%TB_DIR%\%REQ%.sv") do set "RESOLVED_TB=%%~fI"
)

if not defined RESOLVED_TB (
    for /L %%I in (1,1,!TB_COUNT!) do (
        if /i "!TB_REL_%%I!"=="%REQ%" set "RESOLVED_TB=!TB_%%I!"
        if /i "!TB_REL_WIN_%%I!"=="%REQ%" set "RESOLVED_TB=!TB_%%I!"
        if /i "!TB_NAME_%%I!"=="%REQ%" set "RESOLVED_TB=!TB_%%I!"
        if /i "!TB_STEM_%%I!"=="%REQ%" set "RESOLVED_TB=!TB_%%I!"
    )
)

if not defined RESOLVED_TB (
    echo [ERROR] TB file not found for: %REQ%
    echo [INFO] Try one of:
    echo [INFO]  - tb_top
    echo [INFO]  - tb_top.v
    echo [INFO]  - tb_top.sv
    echo [INFO]  - %TB_DIR%\tb_top.v / %TB_DIR%\tb_top.sv
    exit /b 1
)

call :assert_tb_allowed_manifest "%RESOLVED_TB%"
if errorlevel 1 exit /b 1

exit /b 0

:run_one
set "TB_FILE=%~1"
for %%I in ("%TB_FILE%") do (
    set "TB_STEM=%%~nI"
)
call :detect_tb_top "%TB_FILE%"
if not defined TB_TOP set "TB_TOP=%TB_STEM%"
set "VVP_OUT=%OUT_DIR%\%TB_STEM%.out"
set "FILELIST=%OUT_DIR%\%TB_STEM%_files.f"

call :write_filelist "%FILELIST%" "%TB_FILE%"

echo.
echo [RUN] %TB_STEM% ^(top=%TB_TOP%^)
call :run_manifest_compile "%VVP_OUT%" "%TB_TOP%" "%FILELIST%"
set "COMPILE_RC=%errorlevel%"
if not "%COMPILE_RC%"=="0" (
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

:detect_tb_top
set "TB_TOP="
set "TB_PARSE_FILE=%~1"
for /f "usebackq delims=" %%M in (`powershell -NoProfile -Command "$p='%TB_PARSE_FILE%'; if (-not (Test-Path $p)) { exit 0 }; $txt=[IO.File]::ReadAllText($p); $txt=[regex]::Replace($txt,'/\*.*?\*/',' ','Singleline'); $txt=[regex]::Replace($txt,'//.*?$',' ','Multiline'); $m=[regex]::Match($txt,'(?im)^\s*(?:module|program)\s+(?:(?:automatic|static)\s+)?([A-Za-z_][A-Za-z0-9_$]*)\b'); if ($m.Success) { $m.Groups[1].Value }"` ) do (
    if not defined TB_TOP set "TB_TOP=%%M"
)
if defined TB_TOP (
    exit /b 0
)
echo [WARNING] Could not infer TB top from file. Fallback to filename stem.
exit /b 0

:write_filelist
set "OUT_F=%~1"
set "TB_F=%~2"
call :write_filelist_manifest "%OUT_F%"
exit /b %errorlevel%

:write_filelist_manifest
set "OUT_F=%~1"
if not exist "%MANIFEST_SRC_LIST%" (
    echo [ERROR] Manifest src list not found: %MANIFEST_SRC_LIST%
    exit /b 1
)
if not exist "%MANIFEST_TB_LIST%" (
    echo [ERROR] Manifest tb list not found: %MANIFEST_TB_LIST%
    exit /b 1
)
(
    for /f "usebackq delims=" %%S in ("%MANIFEST_SRC_LIST%") do (
        if not "%%S"=="" echo %%S
    )
    for /f "usebackq delims=" %%T in ("%MANIFEST_TB_LIST%") do (
        if not "%%T"=="" echo %%T
    )
) > "%OUT_F%"
exit /b 0

:run_manifest_compile
set "M_VVP_OUT=%~1"
set "M_TB_TOP=%~2"
set "M_FILELIST=%~3"
powershell -NoProfile -Command ^
  "$argsList = @('-g2012','-o','%M_VVP_OUT%','-s','%M_TB_TOP%','-f','%M_FILELIST%'); " ^
  "if (Test-Path '%MANIFEST_INC_LIST%') { " ^
  "  $incRel = Get-Content -Path '%MANIFEST_INC_LIST%'; " ^
  "  foreach ($rel in $incRel) { " ^
  "    if ($null -ne $rel -and $rel.Trim() -ne '') { " ^
  "      $incAbs = Join-Path '%TARGET_PROJECT%' ($rel -replace '/', '\\'); " ^
  "      $argsList += '-I'; " ^
  "      $argsList += $incAbs; " ^
  "    } " ^
  "  } " ^
  "} " ^
  "Push-Location '%TARGET_PROJECT%'; " ^
  "& iverilog @argsList; " ^
  "$rc = $LASTEXITCODE; " ^
  "Pop-Location; " ^
  "exit $rc;"
exit /b %errorlevel%

:populate_tb_candidates
call :populate_tb_candidates_manifest
exit /b %errorlevel%

:populate_tb_candidates_manifest
set /a TB_COUNT=0
if not exist "%MANIFEST_TB_LIST%" (
    echo [ERROR] Manifest TB list not found: %MANIFEST_TB_LIST%
    exit /b 1
)
for /f "usebackq delims=" %%R in ("%MANIFEST_TB_LIST%") do (
    if not "%%R"=="" (
        set "TB_REL_RAW=%%R"
        set "TB_REL_WIN=!TB_REL_RAW:/=\!"
        if exist "%TARGET_PROJECT%\!TB_REL_WIN!" (
            set /a TB_COUNT+=1
            for %%A in ("%TARGET_PROJECT%\!TB_REL_WIN!") do (
                set "TB_!TB_COUNT!=%%~fA"
                set "TB_NAME_!TB_COUNT!=%%~nxA"
                set "TB_STEM_!TB_COUNT!=%%~nA"
                set "TB_REL_!TB_COUNT!=!TB_REL_RAW!"
                set "TB_REL_WIN_!TB_COUNT!=!TB_REL_WIN!"
            )
        ) else (
            echo [WARNING] Manifest TB file missing on disk: !TB_REL_RAW!
        )
    )
)
if !TB_COUNT! EQU 0 (
    echo [ERROR] Manifest resolved no testbench files.
    exit /b 1
)
exit /b 0

:assert_tb_allowed_manifest
set "TB_CAND=%~f1"
set "MANIFEST_TB_OK=0"
for /L %%I in (1,1,%TB_COUNT%) do (
    if /i "!TB_%%I!"=="%TB_CAND%" set "MANIFEST_TB_OK=1"
)
if "%MANIFEST_TB_OK%"=="1" exit /b 0
echo [ERROR] Selected TB is not declared by manifest: %TB_CAND%
echo [INFO] Declare it in hdl.tb_globs of %MANIFEST_FILE%.
exit /b 1

:usage_error
echo [ERROR] No target project path provided.
echo Usage: %~nx0 ^<Project_Directory^> [tb_name_or_file] [--tb ^<tb_name_or_file^>] [--all] [--no-pause]
if "%NO_PAUSE%"=="0" pause
exit /b 1
