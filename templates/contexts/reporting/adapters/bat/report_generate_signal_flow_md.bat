@echo off
setlocal EnableDelayedExpansion
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^>
    if not defined NO_PAUSE pause
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
set "SCRIPT_DIR=%~dp0"
set "TOOL_SCRIPT=%TEMPLATES_ROOT%\contexts\reporting\adapters\cli\report_generate_signal_flow_cli.js"
set "MANIFEST_CTX=%TEMPLATES_ROOT%\shared\adapters\bat\bootstrap_manifest_context.bat"

echo ============================================================================
echo      Signal Flow Markdown Generator
echo ============================================================================
echo Target: %TARGET_PROJECT%
echo.

if not exist "%TOOL_SCRIPT%" (
    echo [ERROR] Tool script not found: %TOOL_SCRIPT%
    if not defined NO_PAUSE pause
    exit /b 1
)

where node >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Node.js is not installed or not in PATH.
    if not defined NO_PAUSE pause
    exit /b 1
)

call "%MANIFEST_CTX%" "%TARGET_PROJECT%"
if errorlevel 1 (
    echo [ERROR] Manifest context initialization failed.
    if not defined NO_PAUSE pause
    exit /b 1
)

cd /d "%TARGET_PROJECT%"

set "MODULE_COUNT=0"
set "DEFAULT_TOP="

for /f "usebackq delims=" %%R in ("%MANIFEST_SRC_LIST%") do (
    if not "%%R"=="" (
        set "REL_SRC=%%R"
        set "REL_SRC_WIN=!REL_SRC:/=\!"
        if exist "%TARGET_PROJECT%\!REL_SRC_WIN!" (
            for %%A in ("%TARGET_PROJECT%\!REL_SRC_WIN!") do (
                if /i "%%~xA"==".v" (
                    set /a MODULE_COUNT+=1
                    set "MOD_NAME=%%~nA"
                    if !MODULE_COUNT! equ 1 set "DEFAULT_TOP=!MOD_NAME!"
                    if /i "!MOD_NAME!"=="TOP" set "DEFAULT_TOP=TOP"
                    set "MODULE_REL_!MODULE_COUNT!=!REL_SRC!"
                ) else if /i "%%~xA"==".sv" (
                    set /a MODULE_COUNT+=1
                    set "MOD_NAME=%%~nA"
                    if !MODULE_COUNT! equ 1 set "DEFAULT_TOP=!MOD_NAME!"
                    if /i "!MOD_NAME!"=="TOP" set "DEFAULT_TOP=TOP"
                    set "MODULE_REL_!MODULE_COUNT!=!REL_SRC!"
                )
            )
        )
    )
)

if !MODULE_COUNT! equ 0 (
    echo [ERROR] No Verilog source files found in manifest-resolved src list.
    if not defined NO_PAUSE pause
    exit /b 1
)

echo [INFO] Detected modules from src file names:
for /l %%I in (1,1,!MODULE_COUNT!) do (
    call set "REL_FILE=%%MODULE_REL_%%I%%"
    for %%A in ("!REL_FILE!") do echo   - %%~nA
)
echo.

if "!DEFAULT_TOP!"=="" set "DEFAULT_TOP=TOP"

set "TOP_MODULE=%~3"
if "!TOP_MODULE!"=="" (
    set /p "TOP_MODULE=Top module [default: !DEFAULT_TOP!]: "
    if "!TOP_MODULE!"=="" set "TOP_MODULE=!DEFAULT_TOP!"
)

set "SIG_LIST_FILE=%TEMP%\signal_list_%RANDOM%_%RANDOM%.txt"
node "%TOOL_SCRIPT%" --project "%TARGET_PROJECT%" --manifest-json "%MANIFEST_JSON%" --top "!TOP_MODULE!" --list-signals --list-signals-raw > "%SIG_LIST_FILE%"
if errorlevel 1 (
    if exist "%SIG_LIST_FILE%" del /q "%SIG_LIST_FILE%" >nul 2>nul
    echo [ERROR] Failed to scan signals for module: !TOP_MODULE!
    if not defined NO_PAUSE pause
    exit /b 1
)

set "SIG_COUNT=0"
for /f "usebackq tokens=1,2 delims=|" %%A in ("%SIG_LIST_FILE%") do (
    if not "%%~A"=="" (
        set /a SIG_COUNT+=1
        set "SIG_NAME_!SIG_COUNT!=%%~A"
        set "SIG_KIND_!SIG_COUNT!=%%~B"
    )
)
if exist "%SIG_LIST_FILE%" del /q "%SIG_LIST_FILE%" >nul 2>nul

if !SIG_COUNT! equ 0 (
    echo [ERROR] No signals found in module: !TOP_MODULE!
    if not defined NO_PAUSE pause
    exit /b 1
)

echo.
echo [INFO] Scanned signals in module !TOP_MODULE!:
for /l %%I in (1,1,!SIG_COUNT!) do (
    call set "TMP_NAME=%%SIG_NAME_%%I%%"
    call set "TMP_KIND=%%SIG_KIND_%%I%%"
    echo   [%%I] !TMP_NAME! ^(!TMP_KIND!^)
)
echo.
echo [INFO] Selection format:
echo   - ALL
echo   - Number list: 1,2,3
echo   - Signal names: wEcho,wTrigger

set "SIGNAL_INPUT=%~2"
:ASK_SIGNAL_SELECT
if "!SIGNAL_INPUT!"=="" (
    set /p "SIGNAL_INPUT=Signal selection (required): "
)
if "!SIGNAL_INPUT!"=="" (
    echo [ERROR] Signal selection cannot be empty.
    goto :ASK_SIGNAL_SELECT
)

set "SELECT_COUNT=0"
set "SELECT_ERR=0"
set "SELECTION_RAW=!SIGNAL_INPUT:,= !"

if /i "!SIGNAL_INPUT!"=="ALL" (
    for /l %%I in (1,1,!SIG_COUNT!) do (
        call set "SEL_NAME=%%SIG_NAME_%%I%%"
        set /a SELECT_COUNT+=1
        call set "SELECT_!SELECT_COUNT!=%%SEL_NAME%%"
    )
) else (
    for %%T in (!SELECTION_RAW!) do (
        set "TOKEN=%%~T"
        if not "!TOKEN!"=="" (
            echo(!TOKEN!| findstr /r "^[0-9][0-9]*$" >nul
            if not errorlevel 1 (
                if !TOKEN! lss 1 (
                    echo [ERROR] Selection out of range: !TOKEN!
                    set "SELECT_ERR=1"
                ) else if !TOKEN! gtr !SIG_COUNT! (
                    echo [ERROR] Selection out of range: !TOKEN!
                    set "SELECT_ERR=1"
                ) else (
                    set "SEL_NAME="
                    call set "SEL_NAME=%%SIG_NAME_!TOKEN!%%"
                    if not defined SEL_NAME (
                        echo [ERROR] Invalid selection index: !TOKEN!
                        set "SELECT_ERR=1"
                    ) else (
                        set /a SELECT_COUNT+=1
                        call set "SELECT_!SELECT_COUNT!=%%SEL_NAME%%"
                    )
                )
            ) else (
                set "MATCH_NAME="
                for /l %%I in (1,1,!SIG_COUNT!) do (
                    call set "CAND_NAME=%%SIG_NAME_%%I%%"
                    if /i "!TOKEN!"=="!CAND_NAME!" set "MATCH_NAME=!CAND_NAME!"
                )
                if not defined MATCH_NAME (
                    echo [ERROR] Unknown signal token: !TOKEN!
                    set "SELECT_ERR=1"
                ) else (
                    set /a SELECT_COUNT+=1
                    call set "SELECT_!SELECT_COUNT!=%%MATCH_NAME%%"
                )
            )
        )
    )
)

if "!SELECT_ERR!"=="1" (
    echo.
    echo [INFO] Please enter a valid selection again.
    set "SIGNAL_INPUT="
    goto :ASK_SIGNAL_SELECT
)

if !SELECT_COUNT! equ 0 (
    echo [ERROR] No valid signal selected.
    set "SIGNAL_INPUT="
    goto :ASK_SIGNAL_SELECT
)

echo.
echo [INFO] Selected signals:
for /l %%I in (1,1,!SELECT_COUNT!) do (
    call echo   - %%SELECT_%%I%%
)

set "TRACE_DEPTH=%~4"
if "!TRACE_DEPTH!"=="" (
    set /p "TRACE_DEPTH=Trace depth [default: 4, or MAX]: "
    if "!TRACE_DEPTH!"=="" set "TRACE_DEPTH=4"
)

if /i "!TRACE_DEPTH!"=="MAX" goto :TRACE_DEPTH_OK

echo(!TRACE_DEPTH!| findstr /r "^[0-9][0-9]*$" >nul
if errorlevel 1 (
    echo [ERROR] Trace depth must be numeric or MAX.
    if not defined NO_PAUSE pause
    exit /b 1
)
:TRACE_DEPTH_OK

echo.
set /a SUCCESS_COUNT=0
set /a FAIL_COUNT=0

for /l %%I in (1,1,!SELECT_COUNT!) do (
    call set "CUR_SIG=%%SELECT_%%I%%"
    echo [RUN %%I/!SELECT_COUNT!] Analyzing !CUR_SIG! ...
    node "%TOOL_SCRIPT%" --project "%TARGET_PROJECT%" --manifest-json "%MANIFEST_JSON%" --top "!TOP_MODULE!" --signal "!CUR_SIG!" --depth "!TRACE_DEPTH!"
    if errorlevel 1 (
        echo [FAIL] !CUR_SIG!
        set /a FAIL_COUNT+=1
    ) else (
        set /a SUCCESS_COUNT+=1
    )
    echo.
)

echo ============================================================================
echo [DONE] Signal flow markdown generation finished.
echo [INFO] Success: !SUCCESS_COUNT!, Fail: !FAIL_COUNT!
echo ============================================================================

if !FAIL_COUNT! gtr 0 (
    if not defined NO_PAUSE pause
    exit /b 1
)

if not defined NO_PAUSE pause
exit /b 0
