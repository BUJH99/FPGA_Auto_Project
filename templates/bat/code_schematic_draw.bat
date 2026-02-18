@echo off
setlocal EnableDelayedExpansion

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^>
    pause
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
cd /d "%TARGET_PROJECT%"
echo Target Project: %TARGET_PROJECT%

REM Check for Yosys (trying yowasp-yosys first, then yosys)
set YOSYS_CMD=yosys

where yowasp-yosys >nul 2>nul
if %errorlevel% equ 0 (
    echo [INFO] Found yowasp-yosys. Using it.
    set YOSYS_CMD=yowasp-yosys
) else (
    where yosys >nul 2>nul
    if %errorlevel% neq 0 (
        echo [ERROR] Neither 'yosys' nor 'yowasp-yosys' found in PATH.
        echo Please ensure Yosys is installed.
        pause
        exit /b 1
    )
)

set "NETLISTSVG_CMD=%~dp0..\node_modules\netlistsvg\bin\netlistsvg.js"
if not exist "%NETLISTSVG_CMD%" (
    echo [ERROR] netlistsvg not found at templates\node_modules
    echo [INFO] Run: cd templates ^&^& npm install
    pause
    exit /b 1
)

REM Dynamically find all Verilog files in src folder
set "VERILOG_FILES="
set "ALL_MODULES="
set "MODULE_COUNT=0"
set "HAS_TOP=0"
for %%f in (src\*.v) do (
    set /a MODULE_COUNT+=1
    set "MODULE_NAME=%%~nf"
    set "VERILOG_FILES=!VERILOG_FILES! src/%%~nxf"
    set "ALL_MODULES=!ALL_MODULES! !MODULE_NAME!"
    set "MODULE_!MODULE_COUNT!=!MODULE_NAME!"
    if /i "!MODULE_NAME!"=="Top" (
        set "HAS_TOP=1"
        set "TOP_MODULE_NAME=!MODULE_NAME!"
    )
)

if !MODULE_COUNT! equ 0 (
    echo [ERROR] No .v files found in src/ folder.
    pause
    exit /b 1
)

echo [INFO] Detected source files: %VERILOG_FILES%
echo.
echo ========================================================
echo  Module Selection
echo ========================================================
echo  Scanned module files in src:
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

REM Handle default
if "%USER_INPUT%"=="" (
    if "!HAS_TOP!"=="1" (
        set "USER_INPUT=!TOP_MODULE_NAME!"
    ) else (
        set "USER_INPUT=!MODULE_1!"
    )
    goto :SELECTION_DONE
)

REM Handle ALL
if /i "%USER_INPUT%"=="ALL" (
    set "USER_INPUT=%ALL_MODULES%"
    goto :SELECTION_DONE
)

if /i "%USER_INPUT%"=="!TOP_MODULE_NAME!" (
    set "USER_INPUT=!TOP_MODULE_NAME!"
    goto :SELECTION_DONE
)

REM Convert numeric selection to module names
set "SELECTED_MODULES="
set "SELECTION_OK=1"
set "SELECTION_RAW=%USER_INPUT:,= %"
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
echo [INFO] Generating schematics for: %USER_INPUT%
echo.

REM Create output/Diagram folder structure if it doesn't exist
if not exist "output" mkdir output
if not exist "output\Diagram" mkdir output\Diagram
if not exist "output\Diagram\Simple" mkdir output\Diagram\Simple
if not exist "output\Diagram\Detailed" mkdir output\Diagram\Detailed
if not exist "output\Diagram\JSON" mkdir output\Diagram\JSON
echo [INFO] Output directory structure:
echo   - output\Diagram\Simple\    (Simple box diagrams)
echo   - output\Diagram\Detailed\  (Detailed internal diagrams)
echo   - output\Diagram\JSON\      (Intermediate JSON files)
echo.

set "RUN_SCHEMATIC_PS=%~dp0..\tools\run_schematic_jobs.ps1"
if not exist "%RUN_SCHEMATIC_PS%" (
    echo [ERROR] Missing worker script: "%RUN_SCHEMATIC_PS%"
    exit /b 1
)

for %%I in ("%NETLISTSVG_CMD%") do set "NETLISTSVG_CMD=%%~fI"

set "MODULES_CSV="
set /a SELECTED_COUNT=0
for %%M in (%USER_INPUT%) do (
    set /a SELECTED_COUNT+=1
    if defined MODULES_CSV (
        set "MODULES_CSV=!MODULES_CSV!,%%M"
    ) else (
        set "MODULES_CSV=%%M"
    )
)

if !SELECTED_COUNT! lss 1 (
    echo [ERROR] No modules selected.
    exit /b 1
)

set /a AUTO_MAX_PARALLEL=%NUMBER_OF_PROCESSORS%
if !AUTO_MAX_PARALLEL! gtr !SELECTED_COUNT! set /a AUTO_MAX_PARALLEL=!SELECTED_COUNT!
if !AUTO_MAX_PARALLEL! lss 1 set /a AUTO_MAX_PARALLEL=1

set "MAX_PARALLEL=!AUTO_MAX_PARALLEL!"
if defined SCHEMATIC_MAX_JOBS (
    set "MAX_PARALLEL_INPUT=%SCHEMATIC_MAX_JOBS%"
    set "MAX_PARALLEL_INPUT=!MAX_PARALLEL_INPUT: =!"
    set "MAX_PARALLEL_SANITIZE="
    for /f "delims=0123456789" %%A in ("!MAX_PARALLEL_INPUT!") do set "MAX_PARALLEL_SANITIZE=%%A"
    if defined MAX_PARALLEL_SANITIZE (
        echo [WARN] Invalid SCHEMATIC_MAX_JOBS value: %SCHEMATIC_MAX_JOBS%
        echo [WARN] Using auto worker count: !MAX_PARALLEL!
    ) else (
        set "MAX_PARALLEL=!MAX_PARALLEL_INPUT!"
        echo [INFO] SCHEMATIC_MAX_JOBS override detected: !MAX_PARALLEL!
    )
)

echo [INFO] Selected modules: !SELECTED_COUNT!
echo [INFO] Parallel workers target: !MAX_PARALLEL!
echo [INFO] Per-module logs: output\Diagram\logs
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%RUN_SCHEMATIC_PS%" ^
    -ProjectPath "%TARGET_PROJECT%" ^
    -ModulesCsv "!MODULES_CSV!" ^
    -YosysCmd "%YOSYS_CMD%" ^
    -NetlistSvgCmd "%NETLISTSVG_CMD%" ^
    -MaxParallel "!MAX_PARALLEL!"

if errorlevel 1 (
    echo [ERROR] Schematic generation completed with errors.
    exit /b 1
)

echo [INFO] All tasks completed.
exit /b 0
