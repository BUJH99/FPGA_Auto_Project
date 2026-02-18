@echo off
setlocal EnableExtensions

set "TARGET_PROJECT="
set "NO_PAUSE=0"
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\") do set "TEMPLATE_ROOT=%%~fI"

:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="--no-pause" (
    set "NO_PAUSE=1"
) else if not defined TARGET_PROJECT (
    set "TARGET_PROJECT=%~f1"
) else (
    echo [WARNING] Ignoring extra argument: %~1
)
shift
goto parse_args

:args_done
if not defined TARGET_PROJECT (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^> [--no-pause]
    if "%NO_PAUSE%"=="0" pause
    exit /b 1
)

if not exist "%TARGET_PROJECT%" (
    echo [ERROR] Target project not found: %TARGET_PROJECT%
    if "%NO_PAUSE%"=="0" pause
    exit /b 1
)

cd /d "%TARGET_PROJECT%" || (
    echo [ERROR] Failed to enter target project: %TARGET_PROJECT%
    if "%NO_PAUSE%"=="0" pause
    exit /b 1
)

set "DOCS_DIR=%TARGET_PROJECT%\output\docs"
if not exist "%DOCS_DIR%" mkdir "%DOCS_DIR%"

set "REPORT_MD=%DOCS_DIR%\report.md"
set "REPORT_MD_LEGACY=%TARGET_PROJECT%\report.md"
set "CSS_FILE=%DOCS_DIR%\github.css"
set "CSS_FILE_LEGACY=%TARGET_PROJECT%\github.css"
set "REPORT_HTML=%DOCS_DIR%\report.html"
set "REPORT_DOCX=%DOCS_DIR%\report.docx"
set "PANDOC_RESOURCE_PATH=%TARGET_PROJECT%;%DOCS_DIR%"
set "DOCX_STYLE_POST=%TEMPLATE_ROOT%tools\postprocess_docx_style.ps1"
set "MD_PREP_SCRIPT=%TEMPLATE_ROOT%tools\prepare_report_markdown.ps1"
set "REPORT_MD_WORK=%REPORT_MD%"
set "TEMP_REPORT_MD="
for %%I in ("%TARGET_PROJECT%") do set "PROJECT_NAME=%%~nI"

if not exist "%REPORT_MD%" (
    if exist "%REPORT_MD_LEGACY%" (
        set "REPORT_MD=%REPORT_MD_LEGACY%"
        echo [INFO] Using legacy report source: %REPORT_MD_LEGACY%
    ) else (
        echo [ERROR] report.md not found.
        echo [INFO] Checked:
        echo [INFO] - %DOCS_DIR%\report.md
        echo [INFO] - %TARGET_PROJECT%\report.md
        echo [INFO] Run this first:
        echo [INFO] templates\bat\report_markdown_generate.bat %TARGET_PROJECT%
        if "%NO_PAUSE%"=="0" pause
        exit /b 1
    )
)

if not exist "%CSS_FILE%" (
    if exist "%CSS_FILE_LEGACY%" (
        set "CSS_FILE=%CSS_FILE_LEGACY%"
        echo [INFO] Using legacy CSS source: %CSS_FILE_LEGACY%
    ) else (
        set "CSS_FILE="
    )
)

echo ===============================================================================
echo [Report Automation] Build HTML/DOCX from report.md
echo Source: %REPORT_MD%
echo ===============================================================================

set "PANDOC_CMD="
call :RESOLVE_PANDOC
if not defined PANDOC_CMD (
    echo [INFO] pandoc not found. Trying automatic installation...
    call :INSTALL_PANDOC
    call :RESOLVE_PANDOC
)

if not defined PANDOC_CMD (
    echo [WARNING] pandoc not available. Skip HTML/DOCX generation.
    call :CLEANUP_TEMP_REPORT
    if "%NO_PAUSE%"=="0" pause
    exit /b 0
)

set "HTML_EMBED_OPT=--embed-resources"
call :RESOLVE_PANDOC_EMBED_OPT
call :PREPARE_REPORT_MD

if defined CSS_FILE (
    "%PANDOC_CMD%" "%REPORT_MD_WORK%" -s --toc --toc-depth=3 %HTML_EMBED_OPT% --resource-path="%PANDOC_RESOURCE_PATH%" -c "%CSS_FILE%" -o "%REPORT_HTML%"
) else (
    echo [WARNING] github.css not found. Building HTML without CSS.
    "%PANDOC_CMD%" "%REPORT_MD_WORK%" -s --toc --toc-depth=3 %HTML_EMBED_OPT% --resource-path="%PANDOC_RESOURCE_PATH%" -o "%REPORT_HTML%"
)

if errorlevel 1 (
    echo [WARNING] pandoc HTML conversion failed.
) else (
    echo [SUCCESS] report HTML: %REPORT_HTML%
)

"%PANDOC_CMD%" "%REPORT_MD_WORK%" -s --toc --toc-depth=3 --resource-path="%PANDOC_RESOURCE_PATH%" -o "%REPORT_DOCX%"
if errorlevel 1 (
    echo [WARNING] pandoc Word conversion failed.
) else (
    if exist "%DOCX_STYLE_POST%" (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%DOCX_STYLE_POST%" -DocxPath "%REPORT_DOCX%"
        if errorlevel 1 (
            echo [WARNING] DOCX style post-process failed. Keeping generated DOCX as-is.
        ) else (
            echo [INFO] DOCX style normalized ^(10~12pt range + Malgun Gothic^).
        )
    ) else (
        echo [WARNING] DOCX style post-process script not found: %DOCX_STYLE_POST%
    )
    echo [SUCCESS] report DOCX: %REPORT_DOCX%
)

echo.
echo [DONE] Report build finished.
call :CLEANUP_TEMP_REPORT
if "%NO_PAUSE%"=="0" pause
exit /b 0

:RESOLVE_PANDOC
set "PANDOC_CMD="
for /f "delims=" %%F in ('where pandoc.exe 2^>nul') do (
    set "PANDOC_CMD=%%F"
    exit /b 0
)
for /f "delims=" %%F in ('where pandoc 2^>nul') do (
    set "PANDOC_CMD=%%F"
    exit /b 0
)

if exist "%ProgramFiles%\Pandoc\pandoc.exe" (
    set "PANDOC_CMD=%ProgramFiles%\Pandoc\pandoc.exe"
    exit /b 0
)

if defined LOCALAPPDATA (
    if exist "%LOCALAPPDATA%\Pandoc\pandoc.exe" (
        set "PANDOC_CMD=%LOCALAPPDATA%\Pandoc\pandoc.exe"
        exit /b 0
    )
    for /f "delims=" %%F in ('where /r "%LOCALAPPDATA%\Microsoft\WinGet\Packages" pandoc.exe 2^>nul') do (
        set "PANDOC_CMD=%%F"
        exit /b 0
    )
)
exit /b 0

:INSTALL_PANDOC
where winget >nul 2>nul
if not errorlevel 1 (
    echo [INFO] Installing pandoc with winget...
    call winget install --id JohnMacFarlane.Pandoc -e --accept-source-agreements --accept-package-agreements --silent --scope user
    if errorlevel 1 (
        echo [INFO] winget user-scope failed. Retrying without scope...
        call winget install --id JohnMacFarlane.Pandoc -e --accept-source-agreements --accept-package-agreements --silent
    )
    if not errorlevel 1 exit /b 0
)

where choco >nul 2>nul
if not errorlevel 1 (
    echo [INFO] Installing pandoc with choco...
    call choco install pandoc -y
    if not errorlevel 1 exit /b 0
)

where scoop >nul 2>nul
if not errorlevel 1 (
    echo [INFO] Installing pandoc with scoop...
    call scoop install pandoc
    if not errorlevel 1 exit /b 0
)

echo [WARNING] Automatic pandoc install failed.
exit /b 1

:RESOLVE_PANDOC_EMBED_OPT
"%PANDOC_CMD%" --help 2>nul | findstr /i /c:"--embed-resources" >nul
if not errorlevel 1 exit /b 0

"%PANDOC_CMD%" --help 2>nul | findstr /i /c:"--self-contained" >nul
if not errorlevel 1 (
    set "HTML_EMBED_OPT=--self-contained"
    echo [INFO] pandoc compatibility: using --self-contained for HTML embedding.
    exit /b 0
)

set "HTML_EMBED_OPT="
echo [WARNING] pandoc does not support embed option. HTML may reference external assets.
exit /b 0

:PREPARE_REPORT_MD
set "REPORT_MD_WORK=%REPORT_MD%"
set "TEMP_REPORT_MD=%TEMP%\report_for_pandoc_%RANDOM%_%RANDOM%.md"
if not exist "%MD_PREP_SCRIPT%" (
    echo [WARNING] Markdown preprocess script not found: %MD_PREP_SCRIPT%
    set "TEMP_REPORT_MD="
    exit /b 0
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%MD_PREP_SCRIPT%" -InputPath "%REPORT_MD%" -OutputPath "%TEMP_REPORT_MD%" -ProjectName "%PROJECT_NAME%"
if errorlevel 1 (
    echo [WARNING] Markdown preprocess failed. Using original source: %REPORT_MD%
    call :CLEANUP_TEMP_REPORT
    set "REPORT_MD_WORK=%REPORT_MD%"
    exit /b 0
)

set "REPORT_MD_WORK=%TEMP_REPORT_MD%"
echo [INFO] Using prepared report source: %REPORT_MD_WORK%
exit /b 0

:CLEANUP_TEMP_REPORT
if defined TEMP_REPORT_MD (
    if exist "%TEMP_REPORT_MD%" del /f /q "%TEMP_REPORT_MD%" >nul 2>&1
)
set "TEMP_REPORT_MD="
exit /b 0
