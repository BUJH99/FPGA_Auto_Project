@echo off
setlocal EnableDelayedExpansion

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^> [clean-assets] [top_tb_page_count] [auto_tb_pages]
    pause
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
set "SCRIPT_DIR=%~dp0"
set "PY_TOOL=%SCRIPT_DIR%..\tools\generate_presentation.py"
set "HDL_INDEXER=%SCRIPT_DIR%..\tools\hdl_indexer.js"
set "TEMPLATE_DIR=%SCRIPT_DIR%..\Presentation"

echo ============================================================================
echo      Presentation Generator (Python + Jinja2)
echo ============================================================================
echo Target: %TARGET_PROJECT%
echo.

if not exist "%TARGET_PROJECT%\src" (
    echo [ERROR] src folder not found: %TARGET_PROJECT%\src
    pause
    exit /b 1
)

if not exist "%PY_TOOL%" (
    echo [ERROR] Tool script not found: %PY_TOOL%
    pause
    exit /b 1
)

set "PY_CMD="
where py >nul 2>nul
if !errorlevel! equ 0 (
    set "PY_CMD=py -3"
) else (
    where python >nul 2>nul
    if !errorlevel! equ 0 (
        set "PY_CMD=python"
    )
)

if not defined PY_CMD (
    echo [ERROR] Python was not found in PATH.
    pause
    exit /b 1
)

where node >nul 2>nul
if !errorlevel! equ 0 (
    if exist "%HDL_INDEXER%" (
        echo [INFO] Building HDL index cache...
        node "%HDL_INDEXER%" "%TARGET_PROJECT%" --write >nul
        if errorlevel 1 (
            echo [WARN] HDL index cache generation failed. Continuing.
        )
    )
)

%PY_CMD% -c "import jinja2" >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Jinja2 is not available for this Python.
    echo [INFO] Install with: %PY_CMD% -m pip install jinja2
    pause
    exit /b 1
)

:: ── Design Template Selection ─────────────────────────────────────────────
echo ----------------------------------------------------------------------------
echo  Design Template Selection
echo ----------------------------------------------------------------------------
echo   [1] Design 1 - Classic Brutalist  (reveal.js, dark bold borders)
echo   [2] Design 2 - Minimal Navy    (reveal.js, clean white + navy accent)
echo.
set "DESIGN_INPUT="
set /p "DESIGN_INPUT=Select design [1/2, default 1]: "
if "!DESIGN_INPUT!"=="" set "DESIGN_INPUT=1"

if "!DESIGN_INPUT!"=="1" (
    set "TEMPLATE_FILE=%TEMPLATE_DIR%\Presentation_template1.html"
    echo [INFO] Design 1 selected: Presentation_template1.html
) else if "!DESIGN_INPUT!"=="2" (
    set "TEMPLATE_FILE=%TEMPLATE_DIR%\Presentation_template2.html"
    echo [INFO] Design 2 selected: Presentation_template2.html
) else (
    echo [WARN] Invalid input. Using Design 1 by default.
    set "TEMPLATE_FILE=%TEMPLATE_DIR%\Presentation_template1.html"
)

if not exist "!TEMPLATE_FILE!" (
    echo [ERROR] Template file not found: !TEMPLATE_FILE!
    pause
    exit /b 1
)
echo.

:: ── Clean Assets ──────────────────────────────────────────────────────────
set "CLEAN_ARG="
set "CLEAN_INPUT=%~2"
if "!CLEAN_INPUT!"=="" (
    set /p "CLEAN_INPUT=Clean existing Presentation\assets before generation? [Y/N, default N]: "
)
if /i "!CLEAN_INPUT!"=="Y" set "CLEAN_ARG=--clean-assets"
if /i "!CLEAN_INPUT!"=="YES" set "CLEAN_ARG=--clean-assets"
if /i "!CLEAN_INPUT!"=="--clean-assets" set "CLEAN_ARG=--clean-assets"

set "TOP_TB_PAGE_COUNT=%~3"
if "!TOP_TB_PAGE_COUNT!"=="" (
    set /p "TOP_TB_PAGE_COUNT=TOP testbench page count [0 or more, default 0]: "
)
if "!TOP_TB_PAGE_COUNT!"=="" set "TOP_TB_PAGE_COUNT=0"

echo(!TOP_TB_PAGE_COUNT!| findstr /r "^[0-9][0-9]*$" >nul
if errorlevel 1 (
    echo [WARN] Invalid TOP testbench page count: !TOP_TB_PAGE_COUNT!
    echo [WARN] Using default value 0.
    set "TOP_TB_PAGE_COUNT=0"
)
set "TOP_TB_ARG=--top-testbench-pages !TOP_TB_PAGE_COUNT!"
echo [INFO] TOP testbench page count: !TOP_TB_PAGE_COUNT!

set "AUTO_TB_INPUT=%~4"
if "!AUTO_TB_INPUT!"=="" (
    set /p "AUTO_TB_INPUT=Insert auto-matched TB pages? [Y/N, default Y]: "
)
if "!AUTO_TB_INPUT!"=="" set "AUTO_TB_INPUT=Y"

set "AUTO_TB_ARG="
if /i "!AUTO_TB_INPUT!"=="Y" (
    echo [INFO] Auto-matched TB page insertion: ENABLED
) else if /i "!AUTO_TB_INPUT!"=="YES" (
    echo [INFO] Auto-matched TB page insertion: ENABLED
) else if /i "!AUTO_TB_INPUT!"=="N" (
    set "AUTO_TB_ARG=--disable-auto-mapped-tb-pages"
    echo [INFO] Auto-matched TB page insertion: DISABLED
) else if /i "!AUTO_TB_INPUT!"=="NO" (
    set "AUTO_TB_ARG=--disable-auto-mapped-tb-pages"
    echo [INFO] Auto-matched TB page insertion: DISABLED
) else (
    echo [WARN] Invalid auto TB insertion input: !AUTO_TB_INPUT!
    echo [WARN] Using default value Y ^(ENABLED^).
)

:: ── Run Generator ─────────────────────────────────────────────────────────
%PY_CMD% "%PY_TOOL%" --project "%TARGET_PROJECT%" --template "!TEMPLATE_FILE!" !CLEAN_ARG! !TOP_TB_ARG! !AUTO_TB_ARG!
if errorlevel 1 (
    echo.
    echo [FAILURE] Presentation generation failed.
    pause
    exit /b 1
)

echo.
echo [SUCCESS] Presentation generation completed.
pause
exit /b 0
