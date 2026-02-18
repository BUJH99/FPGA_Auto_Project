@echo off
setlocal EnableDelayedExpansion

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^> [--modules=module1,module2] [--no-pause]
    pause
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
set "TOOL_SCRIPT=%~dp0..\tools\generate_one_source_report.js"
set "PREPARE_WAVE_BAT=%~dp0report_waveform_folders_prepare.bat"
set "NO_PAUSE=0"
set "MODULES_ARG="

shift
:PARSE_ARGS
if "%~1"=="" goto :ARGS_DONE
if /i "%~1"=="--no-pause" (
    set "NO_PAUSE=1"
    shift
    goto :PARSE_ARGS
)
if /i "%~1"=="--modules" goto :HANDLE_MODULES_VALUE
set "ARG=%~1"
if /i "!ARG:~0,10!"=="--modules=" (
    set "MODULES_ARG=%~1"
    shift
    goto :PARSE_ARGS
)
echo [WARN] Unknown argument ignored: %~1
shift
goto :PARSE_ARGS

:HANDLE_MODULES_VALUE
shift
if "%~1"=="" (
    echo [WARN] --modules provided without module list. Ignored.
    goto :ARGS_DONE
)
set "MODULES_ARG=--modules=%~1"
shift
goto :PARSE_ARGS

:ARGS_DONE
if not exist "%TOOL_SCRIPT%" (
    echo [ERROR] Missing tool script: %TOOL_SCRIPT%
    if "%NO_PAUSE%"=="0" pause
    exit /b 1
)

if not defined MODULES_ARG if "%NO_PAUSE%"=="0" (
    call :PROMPT_MODULE_SELECTION
    if errorlevel 1 (
        if "%NO_PAUSE%"=="0" pause
        exit /b 1
    )
)

echo ===============================================================================
echo [Report Automation] Generate report.md from src/tb + assets
echo Target: %TARGET_PROJECT%
if defined MODULES_ARG (
    echo Modules: !MODULES_ARG:~10!
) else (
    echo Modules: ALL
)
echo ===============================================================================

if exist "%PREPARE_WAVE_BAT%" (
    echo.
    echo [INFO] Preparing waveform module folders...
    if defined MODULES_ARG (
        call "%PREPARE_WAVE_BAT%" "%TARGET_PROJECT%" "!MODULES_ARG!" --no-pause
    ) else (
        call "%PREPARE_WAVE_BAT%" "%TARGET_PROJECT%" --no-pause
    )
    if errorlevel 1 (
        echo [WARN] Waveform folder preparation failed. Continue report generation.
    )
) else (
    echo [WARN] Waveform prepare script not found: %PREPARE_WAVE_BAT%
)

if defined MODULES_ARG (
    node "%TOOL_SCRIPT%" "%TARGET_PROJECT%" "!MODULES_ARG!"
) else (
    node "%TOOL_SCRIPT%" "%TARGET_PROJECT%"
)
if errorlevel 1 (
    echo.
    echo [FAILURE] report.md generation failed.
    if "%NO_PAUSE%"=="0" pause
    exit /b 1
)

echo.
echo [SUCCESS] Generated:
echo - %TARGET_PROJECT%\output\docs\report.md
echo - %TARGET_PROJECT%\output\docs\github.css
if "%NO_PAUSE%"=="0" pause
exit /b 0

:PROMPT_MODULE_SELECTION
set "MOD_COUNT=0"
for /f "usebackq delims=" %%M in (`node "%TOOL_SCRIPT%" "%TARGET_PROJECT%" --list-modules 2^>nul`) do (
    if not "%%M"=="" (
        set /a MOD_COUNT+=1
        set "MOD_NAME_!MOD_COUNT!=%%M"
    )
)

if !MOD_COUNT! LEQ 0 (
    echo [ERROR] No modules found under: %TARGET_PROJECT%\src
    exit /b 1
)

:SELECT_MODULES
echo.
echo Available modules:
echo [0] ALL
for /L %%I in (1,1,!MOD_COUNT!) do (
    echo [%%I] !MOD_NAME_%%I!
)
echo.
set "MODULE_PICK="
set /p "MODULE_PICK=Select modules ^(e.g. 1,3^)^: "
if "!MODULE_PICK!"=="" set "MODULE_PICK=0"

if "!MODULE_PICK!"=="0" (
    set "MODULES_ARG="
    exit /b 0
)

set "PICK_LIST=!MODULE_PICK:,= !"
set "SEL_MODULES="
set "INVALID_PICK=0"
set "SELECT_ALL=0"
for /L %%I in (1,1,!MOD_COUNT!) do set "SEL_IDX_%%I="

for %%I in (!PICK_LIST!) do (
    echo(%%I| findstr /r "^[0-9][0-9]*$" >nul
    if errorlevel 1 (
        set "INVALID_PICK=1"
    ) else (
        if %%I EQU 0 (
            set "SELECT_ALL=1"
        ) else (
            if %%I LSS 1 set "INVALID_PICK=1"
            if %%I GTR !MOD_COUNT! set "INVALID_PICK=1"
            if !INVALID_PICK! EQU 0 (
                if not defined SEL_IDX_%%I (
                    set "SEL_IDX_%%I=1"
                    if defined SEL_MODULES (
                        set "SEL_MODULES=!SEL_MODULES!,!MOD_NAME_%%I!"
                    ) else (
                        set "SEL_MODULES=!MOD_NAME_%%I!"
                    )
                )
            )
        )
    )
)

if !INVALID_PICK! EQU 1 (
    echo [ERROR] Invalid selection. Please use listed numbers only.
    goto :SELECT_MODULES
)

if !SELECT_ALL! EQU 1 (
    set "MODULES_ARG="
    exit /b 0
)

if not defined SEL_MODULES (
    echo [ERROR] No valid modules selected.
    goto :SELECT_MODULES
)

set "MODULES_ARG=--modules=!SEL_MODULES!"
exit /b 0
