@echo off
setlocal EnableDelayedExpansion
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
for %%I in ("%TEMPLATES_ROOT%\..") do set "REPO_ROOT=%%~fI"
set "SLIDEV_CLI=%TEMPLATES_ROOT%\node_modules\.bin\slidev.cmd"
set "TARGET_PROJECT=%~f1"
set "PRESENTATION_DIR=%TARGET_PROJECT%\Presentation"
set "RUNTIME_DIR=%TEMPLATES_ROOT%\node_modules\.cache\fpga_auto_slidev_runtime"

if "%TARGET_PROJECT%"=="" (
    echo [ERROR] Target project path is required.
    echo Usage: %~nx0 ^<Project_Directory^>
    pause
    exit /b 1
)

echo ============================================================================
echo      Slidev Viewer Launcher (One-Click)
echo ============================================================================
echo Target Project: %TARGET_PROJECT%
echo.

call :validate_target_project
if errorlevel 1 (
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

call :select_entry_mode
if errorlevel 1 (
    pause
    exit /b 1
)

for %%I in ("%TARGET_PROJECT%") do set "PROJECT_NAME=%%~nI"
set "PROJECT_SLUG=!PROJECT_NAME: =_!"
set "RUNTIME_ENTRY=%RUNTIME_DIR%\open_!PROJECT_SLUG!.md"
call :prepare_runtime_bridge_entry "!SELECTED_MD!" "!RUNTIME_ENTRY!"
if errorlevel 1 (
    pause
    exit /b 1
)

call :find_available_port
if errorlevel 1 (
    pause
    exit /b 1
)

echo.
echo [INFO] Source markdown: !SELECTED_MD!
echo [INFO] Runtime entry: !RUNTIME_ENTRY!
echo [INFO] Selected port: !SLIDEV_PORT!
echo [INFO] Open URL after startup: http://localhost:!SLIDEV_PORT!/
echo.

pushd "%REPO_ROOT%" >nul
call "%SLIDEV_CLI%" "!RUNTIME_ENTRY!" --port !SLIDEV_PORT!
set "RUN_RC=!errorlevel!"
popd >nul
exit /b !RUN_RC!

:validate_target_project
if not exist "%TARGET_PROJECT%\" (
    echo [ERROR] Target project not found: %TARGET_PROJECT%
    exit /b 1
)
if not exist "%PRESENTATION_DIR%\" (
    echo [ERROR] Presentation directory not found: %PRESENTATION_DIR%
    echo [INFO] Run report_generate_presentation.bat first.
    exit /b 1
)
exit /b 0

:select_entry_mode
echo --------------------------------------------------------------------------
echo Markdown Source Selection
echo --------------------------------------------------------------------------
echo   [1] Open most recently generated slidev_*.md in this project
echo   [2] Select markdown file from this project's Presentation folder
echo.
set "MODE_INPUT="
set /p "MODE_INPUT=Select mode [1/2, default 1]: "
if "!MODE_INPUT!"=="" set "MODE_INPUT=1"

if "!MODE_INPUT!"=="1" (
    call :pick_latest_md_in_project
    exit /b !errorlevel!
)
if "!MODE_INPUT!"=="2" (
    call :select_md_in_project
    exit /b !errorlevel!
)

echo [ERROR] Invalid mode: !MODE_INPUT!
exit /b 1

:pick_latest_md_in_project
set "SELECTED_MD="
for /f "usebackq delims=" %%F in (`powershell -NoProfile -Command "$dir='%PRESENTATION_DIR%'; $f = Get-ChildItem -Path $dir -File -Filter 'slidev_*.md' | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if ($f) { $f.FullName }"`) do (
    set "SELECTED_MD=%%F"
)

if not defined SELECTED_MD (
    echo [ERROR] No generated slidev_*.md found in "%PRESENTATION_DIR%".
    echo [INFO] Run report_generate_presentation.bat first.
    exit /b 1
)
exit /b 0

:select_md_in_project
echo.
echo Available Markdown Files: %PRESENTATION_DIR%
set "MD_COUNT=0"
for /f "delims=" %%F in ('dir "%PRESENTATION_DIR%\*.md" /b /a-d /o:-d 2^>nul') do (
    set /a MD_COUNT+=1
    set "MD_FILE_!MD_COUNT!=%%F"
    echo   [!MD_COUNT!] %%F
)

if !MD_COUNT! LEQ 0 (
    echo [ERROR] No markdown file found in "%PRESENTATION_DIR%".
    exit /b 1
)

echo.
set "MD_INPUT="
set /p "MD_INPUT=Select markdown index [default 1]: "
if "!MD_INPUT!"=="" set "MD_INPUT=1"

echo(!MD_INPUT!| findstr /r "^[0-9][0-9]*$" >nul
if errorlevel 1 (
    echo [ERROR] Invalid markdown index: !MD_INPUT!
    exit /b 1
)
if !MD_INPUT! LSS 1 (
    echo [ERROR] Markdown index out of range: !MD_INPUT!
    exit /b 1
)
if !MD_INPUT! GTR !MD_COUNT! (
    echo [ERROR] Markdown index out of range: !MD_INPUT!
    exit /b 1
)

set "SELECTED_MD=%PRESENTATION_DIR%\!MD_FILE_%MD_INPUT%!"
exit /b 0

:find_available_port
set /a SLIDEV_PORT=3030

:port_loop
set "PORT_BUSY="
for /f "delims=" %%L in ('netstat -ano ^| findstr /C:":!SLIDEV_PORT!" ^| findstr /I "LISTENING"') do (
    set "PORT_BUSY=1"
)

if defined PORT_BUSY (
    set /a SLIDEV_PORT+=1
    if !SLIDEV_PORT! GTR 3999 (
        echo [ERROR] Could not find an available port between 3030 and 3999.
        exit /b 1
    )
    goto :port_loop
)
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
