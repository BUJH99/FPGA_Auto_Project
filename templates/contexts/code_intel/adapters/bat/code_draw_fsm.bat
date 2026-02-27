@echo off
setlocal EnableDelayedExpansion
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^>
    pause
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
set "SCRIPT_DIR=%~dp0"
set "FSM_TOOL=%TEMPLATES_ROOT%\contexts\code_intel\adapters\cli\code_generate_fsm_cli.js"
set "DRAWIO_TOOL=%TEMPLATES_ROOT%\contexts\code_intel\adapters\cli\code_convert_svg_to_drawio_cli.js"
set "MANIFEST_CTX=%TEMPLATES_ROOT%\shared\adapters\bat\bootstrap_manifest_context.bat"

call "%MANIFEST_CTX%" "%TARGET_PROJECT%"
if errorlevel 1 (
    echo [ERROR] Manifest context initialization failed.
    pause
    exit /b 1
)

set "MANIFEST_TOP="
for /f "usebackq delims=" %%M in (`powershell -NoProfile -Command "$j = Get-Content -Raw -Path '%MANIFEST_JSON%' | ConvertFrom-Json; if ($j.config -and $j.config.hdl -and $j.config.hdl.top) { [string]$j.config.hdl.top }"`) do (
    if not defined MANIFEST_TOP set "MANIFEST_TOP=%%M"
)
if not defined MANIFEST_TOP set "MANIFEST_TOP=Top"

cd /d "%TARGET_PROJECT%"
echo Target Project: %TARGET_PROJECT%

if not exist "%FSM_TOOL%" (
    echo [ERROR] Missing source parser: %FSM_TOOL%
    pause
    exit /b 1
)

set "HAS_NODE=1"
where node >nul 2>nul
if %errorlevel% neq 0 (
    set "HAS_NODE=0"
)
set "HAS_DOT=1"
where dot >nul 2>nul
if %errorlevel% neq 0 (
    set "HAS_DOT=0"
)

set "VERILOG_FILES="
set "ALL_MODULES="
set "MODULE_COUNT=0"
set "HAS_TOP=0"

for /f "usebackq delims=" %%R in ("%MANIFEST_SRC_LIST%") do (
    if not "%%R"=="" (
        set "REL_SRC=%%R"
        set "REL_SRC_WIN=!REL_SRC:/=\!"
        if exist "%TARGET_PROJECT%\!REL_SRC_WIN!" (
            for %%A in ("%TARGET_PROJECT%\!REL_SRC_WIN!") do (
                if /i "%%~xA"==".v" (
                    call :register_module "%%~nA" "%%~fA" "!REL_SRC!"
                ) else if /i "%%~xA"==".sv" (
                    call :register_module "%%~nA" "%%~fA" "!REL_SRC!"
                )
            )
        )
    )
)

if !MODULE_COUNT! equ 0 (
    echo [ERROR] No .v/.sv files found in manifest-resolved src files.
    pause
    exit /b 1
)

echo [INFO] Detected source files: %VERILOG_FILES%
echo.
echo ========================================================
echo  FSM Module Selection
echo ========================================================
echo  Scanned module files in manifest-resolved source set:
for /l %%i in (1,1,!MODULE_COUNT!) do (
    echo   [%%i] !MODULE_%%i!
)
echo.

:SELECT_MODULES
echo  Input format:
echo   - Number(s): 1 3 5  ^(space/comma separated^)
echo   - ALL: generate all modules
if "!HAS_TOP!"=="1" (
    echo   - Enter: default !TOP_MODULE_NAME!
) else (
    echo   - Enter: default !MODULE_1!
)
echo.

set "USER_INPUT="
set /p "USER_INPUT=Select module number(s): "
for /f "tokens=* delims= " %%A in ("!USER_INPUT!") do set "USER_INPUT=%%~A"
set "USER_TOKEN="
for /f "tokens=1 delims= " %%A in ("!USER_INPUT!") do set "USER_TOKEN=%%~A"

if "!USER_INPUT!"=="" (
    if "!HAS_TOP!"=="1" (
        set "USER_INPUT=!TOP_MODULE_NAME!"
    ) else (
        set "USER_INPUT=!MODULE_1!"
    )
    goto :SELECTION_DONE
)

if /i "!USER_TOKEN!"=="ALL" (
    set "USER_INPUT=!ALL_MODULES!"
    goto :SELECTION_DONE
)

if "!HAS_TOP!"=="1" (
    if /i "!USER_INPUT!"=="!TOP_MODULE_NAME!" (
        set "USER_INPUT=!TOP_MODULE_NAME!"
        goto :SELECTION_DONE
    )
)

set "SELECTED_MODULES="
set "SELECTION_OK=1"
set "SELECTION_RAW=!USER_INPUT:,= !"
for %%I in (%SELECTION_RAW%) do (
    set "TOKEN=%%~I"
    set "NON_DIGIT="
    for /f "delims=0123456789" %%A in ("!TOKEN!") do set "NON_DIGIT=%%A"
    if defined NON_DIGIT (
        echo [ERROR] Invalid selection token: %%I
        set "SELECTION_OK=0"
    ) else (
        if %%I lss 1 (
            echo [ERROR] Selection out of range: %%I
            set "SELECTION_OK=0"
        ) else (
            if %%I gtr !MODULE_COUNT! (
                echo [ERROR] Selection out of range: %%I
                set "SELECTION_OK=0"
            ) else (
                set "SELECTED_MODULES=!SELECTED_MODULES! !MODULE_%%I!"
            )
        )
    )
)

if "!SELECTION_OK!"=="0" (
    echo [INFO] Please enter valid module numbers.
    echo.
    goto :SELECT_MODULES
)

if "!SELECTED_MODULES!"=="" (
    echo [ERROR] No valid module selected.
    echo.
    goto :SELECT_MODULES
)

set "USER_INPUT=!SELECTED_MODULES!"

:SELECTION_DONE
for /f "tokens=* delims= " %%A in ("%USER_INPUT%") do set "USER_INPUT=%%A"

echo.
echo [INFO] Generating FSM diagrams for: %USER_INPUT%
echo.

if not exist "output" mkdir output
if not exist "output\fsm" mkdir output\fsm
if not exist "output\fsm\svg" mkdir output\fsm\svg
if not exist "output\fsm\drawio" mkdir output\fsm\drawio

echo [INFO] Output directory structure:
echo   - output\fsm\svg\     ^(Readable FSM SVG^)
echo   - output\fsm\drawio\  ^(Converted Draw.io XML^)
if "!HAS_DOT!"=="1" (
    echo [INFO] Graphviz dot detected. Auto fallback enabled.
) else (
    echo [INFO] Graphviz dot not found. Native curved renderer will be used.
)
echo.

set /a SUCCESS_COUNT=0
set /a WARN_COUNT=0
set /a FAIL_COUNT=0

for %%M in (%USER_INPUT%) do (
    call :PROCESS_MODULE %%M
)

echo --------------------------------------------------------
echo [INFO] FSM diagram generation completed.
echo [INFO] Success: !SUCCESS_COUNT!, Warning: !WARN_COUNT!, Fail: !FAIL_COUNT!
echo --------------------------------------------------------
exit /b 0

:PROCESS_MODULE
set "MOD=%~1"
echo --------------------------------------------------------
echo  Processing FSM: !MOD!
echo --------------------------------------------------------

set "SOURCE_FILE="
for /l %%I in (1,1,!MODULE_COUNT!) do (
    if /i "!MODULE_%%I!"=="!MOD!" if not defined SOURCE_FILE set "SOURCE_FILE=!MODULE_PATH_%%I!"
)

if "!SOURCE_FILE!"=="" (
    echo [ERROR] Could not locate source for !MOD! in manifest-resolved src list.
    set /a FAIL_COUNT+=1
    echo.
    exit /b 0
)

set "SVG_FILE=output\fsm\svg\!MOD!_fsm.svg"
set "DRAWIO_FILE=output\fsm\drawio\!MOD!_fsm.drawio"

if exist "!SVG_FILE!" del /q "!SVG_FILE!" >nul 2>nul
if exist "!DRAWIO_FILE!" del /q "!DRAWIO_FILE!" >nul 2>nul

if "!HAS_NODE!"=="1" (
    echo [1/2] Parsing source-level FSM...
    node "%FSM_TOOL%" --verilog "!SOURCE_FILE!" --out "!SVG_FILE!" --module "!MOD!" --engine auto --direction both
    if !errorlevel! equ 0 (
        goto :CONVERT_DRAWIO
    )
    echo [WARN] Source-level parse failed for !MOD!.
    set /a WARN_COUNT+=1
    echo.
    exit /b 0
) else (
    echo [WARN] Node.js missing, source-level parser unavailable.
    set /a WARN_COUNT+=1
    echo.
    exit /b 0
)

:CONVERT_DRAWIO
if "!HAS_NODE!"=="0" (
    echo [INFO] Node.js missing. Skipping Draw.io conversion.
    set /a SUCCESS_COUNT+=1
    echo.
    exit /b 0
)

if not exist "%DRAWIO_TOOL%" (
    echo [INFO] %DRAWIO_TOOL% not found. Skipping Draw.io conversion.
    set /a SUCCESS_COUNT+=1
    echo.
    exit /b 0
)

echo [2/2] Converting SVG to Draw.io...
node "%DRAWIO_TOOL%" "!SVG_FILE!" "!DRAWIO_FILE!"
if !errorlevel! equ 0 if exist "!DRAWIO_FILE!" (
    echo [SUCCESS] Generated !DRAWIO_FILE!
) else (
    echo [WARN] Draw.io conversion failed for !MOD!
    set /a WARN_COUNT+=1
)

set /a SUCCESS_COUNT+=1
echo.
exit /b 0

:register_module
set /a MODULE_COUNT+=1
set "MODULE_NAME=%~1"
set "MODULE_FILE=%~f2"
set "MODULE_REL=%~3"
set "VERILOG_FILES=!VERILOG_FILES! !MODULE_REL!"
set "ALL_MODULES=!ALL_MODULES! !MODULE_NAME!"
set "MODULE_!MODULE_COUNT!=!MODULE_NAME!"
set "MODULE_PATH_!MODULE_COUNT!=!MODULE_FILE!"
if /i "!MODULE_NAME!"=="!MANIFEST_TOP!" (
    set "HAS_TOP=1"
    set "TOP_MODULE_NAME=!MODULE_NAME!"
)
exit /b 0
