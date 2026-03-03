@echo off
setlocal EnableDelayedExpansion
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^> [clean-assets] [top_tb_page_count] [auto_tb_pages]
    pause
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
set "SCRIPT_DIR=%~dp0"
set "PY_TOOL=%TEMPLATES_ROOT%\contexts\reporting\adapters\python\report_generate_presentation.py"
set "HDL_INDEXER=%TEMPLATES_ROOT%\contexts\code_intel\adapters\cli\code_index_hdl_cli.js"
set "TEMPLATE_FILE=%TEMPLATES_ROOT%\contexts\reporting\slidedev\presentation_design1.md.j2"
set "SLIDEV_CLI=%TEMPLATES_ROOT%\node_modules\.bin\slidev.cmd"
set "RUNTIME_DIR=%TEMPLATES_ROOT%\node_modules\.cache\fpga_auto_slidev_runtime"
set "MANIFEST_CTX=%TEMPLATES_ROOT%\shared\adapters\bat\bootstrap_manifest_context.bat"

if exist "%MANIFEST_CTX%" (
    call "%MANIFEST_CTX%" "%TARGET_PROJECT%"
    if errorlevel 1 (
        echo [ERROR] Manifest context initialization failed.
        pause
        exit /b 1
    )
)

echo ============================================================================
echo      Slidev Presentation Generator (Python + Jinja2 + Slidev)
echo ============================================================================
echo Target: %TARGET_PROJECT%
echo.

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

call :require_command node "Node.js"
if errorlevel 1 (
    pause
    exit /b 1
)

call :require_command npm "npm"
if errorlevel 1 (
    pause
    exit /b 1
)

call :ensure_slidev_cli
if errorlevel 1 (
    pause
    exit /b 1
)

if exist "%HDL_INDEXER%" (
    echo [INFO] Building HDL index cache...
    node "%HDL_INDEXER%" "%TARGET_PROJECT%" --write >nul
    if errorlevel 1 (
        echo [WARN] HDL index cache generation failed. Continuing.
    )
)

%PY_CMD% -c "import jinja2" >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Jinja2 is not available for this Python.
    echo [INFO] Install with: %PY_CMD% -m pip install jinja2
    pause
    exit /b 1
)

if not exist "!TEMPLATE_FILE!" (
    echo [ERROR] Template file not found: !TEMPLATE_FILE!
    pause
    exit /b 1
)
echo [INFO] Slide design: Design1 ^(fixed^)
echo.

rem ---- Clean Assets --------------------------------------------------------
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

rem ---- Run Generator -------------------------------------------------------
for %%I in ("%TARGET_PROJECT%") do (
    set "PROJECT_NAME=%%~nI"
    set "PRESENTATION_DIR=%%~fI\Presentation"
)

set "TS="
for /f %%T in ('powershell -NoProfile -Command "(Get-Date).ToString(\"yyyyMMdd_HHmmss\")"') do set "TS=%%T"
if "!TS!"=="" (
    echo [ERROR] Failed to create timestamp string.
    pause
    exit /b 1
)

set "OUT_BASE=slidev_!PROJECT_NAME!_!TS!"
set "OUTPUT_MD=!PRESENTATION_DIR!\!OUT_BASE!.md"
set "OUTPUT_JSON=!PRESENTATION_DIR!\!OUT_BASE!.json"
set "OUTPUT_DIR=!PRESENTATION_DIR!\!OUT_BASE!"
set "PROJECT_SLUG=!PROJECT_NAME: =_!"
set "RUNTIME_ENTRY=!RUNTIME_DIR!\build_!PROJECT_SLUG!_!TS!.md"

%PY_CMD% "%PY_TOOL%" --project "%TARGET_PROJECT%" --manifest-json "%MANIFEST_JSON%" --template "!TEMPLATE_FILE!" --output-md "!OUTPUT_MD!" --output-json "!OUTPUT_JSON!" --output-dir "!OUTPUT_DIR!" !CLEAN_ARG! !TOP_TB_ARG! !AUTO_TB_ARG!
if errorlevel 1 (
    echo.
    echo [FAILURE] Slidev source generation failed.
    pause
    exit /b 1
)

call :prepare_runtime_bridge_entry "!OUTPUT_MD!" "!RUNTIME_ENTRY!"
if errorlevel 1 (
    echo.
    echo [FAILURE] Runtime bridge entry preparation failed.
    pause
    exit /b 1
)

echo.
echo [INFO] Building Slidev static output...
echo [INFO] Source markdown: !OUTPUT_MD!
echo [INFO] Runtime entry: !RUNTIME_ENTRY!
pushd "%TEMPLATES_ROOT%" >nul
call "!SLIDEV_CLI!" build "!RUNTIME_ENTRY!" --out "!OUTPUT_DIR!" --base ./
set "SLIDEV_RC=!errorlevel!"
popd >nul
if not "!SLIDEV_RC!"=="0" (
    echo [FAILURE] Slidev build failed.
    pause
    exit /b 1
)

echo [SUCCESS] Slidev presentation generation completed.
echo [INFO] Markdown: !OUTPUT_MD!
echo [INFO] JSON: !OUTPUT_JSON!
echo [INFO] Static HTML: !OUTPUT_DIR!\index.html
pause
exit /b 0

:prepare_runtime_bridge_entry
set "BRIDGE_SOURCE_MD=%~f1"
set "BRIDGE_TARGET_MD=%~f2"

if "!BRIDGE_SOURCE_MD!"=="" (
    echo [ERROR] Runtime bridge source markdown path is empty.
    exit /b 1
)
if "!BRIDGE_TARGET_MD!"=="" (
    echo [ERROR] Runtime bridge target markdown path is empty.
    exit /b 1
)
if not exist "!BRIDGE_SOURCE_MD!" (
    echo [ERROR] Runtime bridge source markdown not found: !BRIDGE_SOURCE_MD!
    exit /b 1
)

for %%I in ("!BRIDGE_TARGET_MD!") do set "BRIDGE_TARGET_DIR=%%~dpI"
if not exist "!BRIDGE_TARGET_DIR!" (
    mkdir "!BRIDGE_TARGET_DIR!" >nul 2>nul
    if errorlevel 1 (
        echo [ERROR] Failed to create runtime bridge directory: !BRIDGE_TARGET_DIR!
        exit /b 1
    )
)

set "PS_BRIDGE_SOURCE=!BRIDGE_SOURCE_MD!"
set "PS_BRIDGE_TARGET=!BRIDGE_TARGET_MD!"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $src=$env:PS_BRIDGE_SOURCE; $out=$env:PS_BRIDGE_TARGET; $raw=Get-Content -LiteralPath $src -Raw; $fm=''; if ($raw -match '^(?s)---\r?\n(.*?)\r?\n---\r?\n?') { $fm=$Matches[1].Trim(\"`r\",\"`n\") }; $srcNorm=$src -replace '\\','/'; $lines=New-Object System.Collections.Generic.List[string]; $lines.Add('---'); if ($fm) { $lines.AddRange(($fm -split \"`r?`n\")) }; $lines.Add('---'); $lines.Add(''); $lines.Add('---'); $lines.Add(('src: \"{0}\"' -f $srcNorm)); $lines.Add('---'); $text=[string]::Join(\"`r`n\", $lines); $utf8NoBom=New-Object System.Text.UTF8Encoding($false); [System.IO.File]::WriteAllText($out, $text, $utf8NoBom);"
if errorlevel 1 (
    echo [ERROR] Failed to prepare runtime bridge entry: !BRIDGE_TARGET_MD!
    exit /b 1
)

call :sync_runtime_components "!BRIDGE_SOURCE_MD!"
if errorlevel 1 (
    exit /b 1
)

exit /b 0

:sync_runtime_components
set "SYNC_SOURCE_MD=%~f1"
if "!SYNC_SOURCE_MD!"=="" (
    echo [ERROR] Runtime component sync source markdown path is empty.
    exit /b 1
)
for %%I in ("!SYNC_SOURCE_MD!") do set "SYNC_SOURCE_DIR=%%~dpI"
set "SYNC_SOURCE_COMPONENTS=!SYNC_SOURCE_DIR!components"
set "SYNC_RUNTIME_COMPONENTS=%RUNTIME_DIR%\components"

if exist "!SYNC_RUNTIME_COMPONENTS!\" (
    rmdir /s /q "!SYNC_RUNTIME_COMPONENTS!" >nul 2>nul
)

if not exist "!SYNC_SOURCE_COMPONENTS!\" (
    mkdir "!SYNC_RUNTIME_COMPONENTS!" >nul 2>nul
    echo [INFO] No local components directory found: !SYNC_SOURCE_COMPONENTS!
    echo [INFO] Runtime components cache was reset.
    exit /b 0
)

robocopy "!SYNC_SOURCE_COMPONENTS!" "!SYNC_RUNTIME_COMPONENTS!" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP >nul
set "ROBOCOPY_RC=!errorlevel!"
if !ROBOCOPY_RC! GEQ 8 (
    echo [ERROR] Failed to sync runtime components.
    echo [ERROR] Source: !SYNC_SOURCE_COMPONENTS!
    echo [ERROR] Target: !SYNC_RUNTIME_COMPONENTS!
    exit /b 1
)
echo [INFO] Synced runtime components: !SYNC_SOURCE_COMPONENTS!
exit /b 0

:require_command
where %~1 >nul 2>nul
if errorlevel 1 (
    echo [ERROR] %~2 was not found in PATH.
    exit /b 1
)
exit /b 0

:ensure_slidev_cli
if exist "%SLIDEV_CLI%" (
    exit /b 0
)
echo [WARN] Slidev CLI was not found: %SLIDEV_CLI%
call :install_template_dependencies
if errorlevel 1 (
    exit /b 1
)
if not exist "%SLIDEV_CLI%" (
    echo [ERROR] Slidev CLI is still missing after npm install.
    echo [INFO] Try manually: cd /d "%TEMPLATES_ROOT%" ^&^& npm install
    exit /b 1
)
echo [INFO] Slidev CLI is ready.
exit /b 0

:install_template_dependencies
echo [INFO] Installing template npm dependencies...
pushd "%TEMPLATES_ROOT%" >nul
call npm install
set "NPM_INSTALL_RC=!errorlevel!"
popd >nul
if not "!NPM_INSTALL_RC!"=="0" (
    echo [ERROR] npm install failed in templates root.
    exit /b 1
)
exit /b 0
