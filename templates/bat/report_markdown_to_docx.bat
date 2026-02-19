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
set "REPORT_DOCX_TARGET=%DOCS_DIR%\report.docx"
set "REPORT_DOCX=%REPORT_DOCX_TARGET%"
set "PANDOC_RESOURCE_PATH=%TARGET_PROJECT%;%DOCS_DIR%"
set "DOCX_STYLE_POST=%TEMPLATE_ROOT%tools\postprocess_docx_style.ps1"
set "MD_PREP_SCRIPT=%TEMPLATE_ROOT%tools\prepare_report_markdown.ps1"
set "SVG_CONVERT_SCRIPT=%TEMPLATE_ROOT%tools\convert_svg_to_png.ps1"
set "REFERENCE_DOC=%TEMPLATE_ROOT%docx\reference.docx"
set "REPORT_MD_WORK=%REPORT_MD%"
set "REPORT_MD_WORK_DOCX=%REPORT_MD%"
set "TEMP_REPORT_MD="
set "TEMP_REPORT_MD_DOCX="
set "PANDOC_COMMON_OPTS=-s --from=gfm --toc --toc-depth=3 --syntax-highlighting=pygments"
set "PANDOC_DOCX_OPTS=-s --from=markdown+pipe_tables+fenced_code_blocks+fenced_divs+footnotes+link_attributes --toc --toc-depth=3 --syntax-highlighting=pygments"
set "DOCX_REFERENCE_OPT="
set "DOCX_CODEBLOCK_TABLE_ARGS="
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
echo [INFO] Applying professional styling and syntax highlighting...
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
call :PREPARE_REPORT_MD_DOCX_SAFE
call :RESOLVE_DOCX_OUTPUT_PATH
if exist "%REFERENCE_DOC%" (
    set "DOCX_REFERENCE_OPT=--reference-doc=""%REFERENCE_DOC%"""
    echo [INFO] Using reference DOCX: %REFERENCE_DOC%
) else (
    echo [INFO] reference.docx not found. Using pandoc default DOCX template.
)
if /i "%REPORT_DOCX_CODE_TABLE%"=="1" (
    set "DOCX_CODEBLOCK_TABLE_ARGS=-EnableCodeBlockTable"
    echo [INFO] Code block 1x1 table conversion: enabled by REPORT_DOCX_CODE_TABLE=1
) else (
    echo [INFO] Code block 1x1 table conversion: disabled ^(set REPORT_DOCX_CODE_TABLE=1 to enable^)
)

rem ── SVG → PNG conversion for DOCX (inline) ────────────────────────────────
set "SVG_NODE_SCRIPT=%TEMPLATE_ROOT%tools\svg_to_png_node.js"
set "TEMP_SVG_PNG_MD=%TEMP%\report_docx_pngsvg_%RANDOM%_%RANDOM%.md"
set "SVG_PNG_OK=0"
where node >nul 2>&1
if not errorlevel 1 (
    if exist "%SVG_NODE_SCRIPT%" (
        echo [INFO] SVG^→PNG: Using Node.js + @resvg/resvg-js converter...
        node "%SVG_NODE_SCRIPT%" --batch-md "%REPORT_MD_WORK_DOCX%" --output-md "%TEMP_SVG_PNG_MD%" --project-root "%TARGET_PROJECT%"
        if not errorlevel 1 set "SVG_PNG_OK=1"
    )
)
if "%SVG_PNG_OK%"=="0" (
    if exist "%SVG_CONVERT_SCRIPT%" (
        echo [INFO] SVG^→PNG: Using PowerShell fallback converter...
        powershell -NoProfile -ExecutionPolicy Bypass -File "%SVG_CONVERT_SCRIPT%" -InputPath "%REPORT_MD_WORK_DOCX%" -OutputPath "%TEMP_SVG_PNG_MD%" -ProjectRoot "%TARGET_PROJECT%"
        if not errorlevel 1 set "SVG_PNG_OK=1"
    )
)
if "%SVG_PNG_OK%"=="1" (
    if exist "%TEMP_SVG_PNG_MD%" (
        echo [INFO] SVG^→PNG: Using PNG-embedded markdown for DOCX.
        set "REPORT_MD_WORK_DOCX=%TEMP_SVG_PNG_MD%"
        if defined TEMP_REPORT_MD_DOCX (
            del /f /q "%TEMP_REPORT_MD_DOCX%" >nul 2>&1
        )
        set "TEMP_REPORT_MD_DOCX=%TEMP_SVG_PNG_MD%"
    )
) else (
    echo [INFO] SVG^→PNG: Skipped ^(no converter or failed^). SVGs will appear as links in DOCX.
    if exist "%TEMP_SVG_PNG_MD%" del /f /q "%TEMP_SVG_PNG_MD%" >nul 2>&1
)
set "PANDOC_RESOURCE_PATH=%TARGET_PROJECT%;%DOCS_DIR%;%TARGET_PROJECT%\output"

if defined CSS_FILE (
    "%PANDOC_CMD%" "%REPORT_MD_WORK%" %PANDOC_COMMON_OPTS% %HTML_EMBED_OPT% --resource-path="%PANDOC_RESOURCE_PATH%" -c "%CSS_FILE%" -o "%REPORT_HTML%"
) else (
    echo [WARNING] github.css not found. Building HTML without CSS.
    "%PANDOC_CMD%" "%REPORT_MD_WORK%" %PANDOC_COMMON_OPTS% %HTML_EMBED_OPT% --resource-path="%PANDOC_RESOURCE_PATH%" -o "%REPORT_HTML%"
)

if errorlevel 1 (
    echo [WARNING] pandoc HTML conversion failed.
) else (
    echo [SUCCESS] report HTML: %REPORT_HTML%
)

"%PANDOC_CMD%" "%REPORT_MD_WORK_DOCX%" %PANDOC_DOCX_OPTS% --resource-path="%PANDOC_RESOURCE_PATH%" %DOCX_REFERENCE_OPT% -o "%REPORT_DOCX%"
if errorlevel 1 (
    echo [ERROR] pandoc Word conversion failed.
    call :CLEANUP_TEMP_REPORT
    if "%NO_PAUSE%"=="0" pause
    exit /b 1
) else (
    if exist "%DOCX_STYLE_POST%" (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%DOCX_STYLE_POST%" -DocxPath "%REPORT_DOCX%" %DOCX_CODEBLOCK_TABLE_ARGS%
        if errorlevel 1 (
            echo [WARNING] DOCX style post-process failed. Keeping generated DOCX as-is.
        ) else (
            echo [INFO] DOCX style normalized ^(Navy Blue Headings + Malgun Gothic^).
        )
    ) else (
        echo [WARNING] DOCX style post-process script not found: %DOCX_STYLE_POST%
    )
    echo [SUCCESS] report DOCX: %REPORT_DOCX%
)
call :CLEANUP_TEMP_REPORT
if "%NO_PAUSE%"=="0" pause
exit /b 0

:RESOLVE_PANDOC
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

:PREPARE_REPORT_MD_DOCX_SAFE
rem NOTE: SVG image stripping is now handled by the SVG→PNG conversion step.
rem       This step just creates a working copy for pandoc processing.
set "REPORT_MD_WORK_DOCX=%REPORT_MD_WORK%"
set "TEMP_REPORT_MD_DOCX=%TEMP%\report_for_pandoc_docx_%RANDOM%_%RANDOM%.md"
copy /Y "%REPORT_MD_WORK%" "%TEMP_REPORT_MD_DOCX%" >nul 2>&1
if errorlevel 1 (
    echo [WARNING] DOCX working copy failed. Using base prepared source.
    if exist "%TEMP_REPORT_MD_DOCX%" del /f /q "%TEMP_REPORT_MD_DOCX%" >nul 2>&1
    set "TEMP_REPORT_MD_DOCX="
    set "REPORT_MD_WORK_DOCX=%REPORT_MD_WORK%"
    exit /b 0
)
set "REPORT_MD_WORK_DOCX=%TEMP_REPORT_MD_DOCX%"
exit /b 0

:RESOLVE_DOCX_OUTPUT_PATH
set "REPORT_DOCX=%REPORT_DOCX_TARGET%"
if not exist "%REPORT_DOCX_TARGET%" exit /b 0

powershell -NoProfile -ExecutionPolicy Bypass -Command "$p='%REPORT_DOCX_TARGET%'; try { $fs=[System.IO.File]::Open($p,[System.IO.FileMode]::Open,[System.IO.FileAccess]::ReadWrite,[System.IO.FileShare]::None); $fs.Close(); exit 0 } catch { exit 1 }"
if not errorlevel 1 exit /b 0

for /f %%I in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "(Get-Date).ToString(\"yyyyMMdd_HHmmss\")"') do set "DOCX_TS=%%I"
set "REPORT_DOCX=%DOCS_DIR%\report_%DOCX_TS%.docx"
echo [WARNING] report.docx is locked. Writing DOCX to: %REPORT_DOCX%
exit /b 0

:CLEANUP_TEMP_REPORT
if defined TEMP_REPORT_MD (
    if exist "%TEMP_REPORT_MD%" del /f /q "%TEMP_REPORT_MD%" >nul 2>&1
)
set "TEMP_REPORT_MD="
if defined TEMP_REPORT_MD_DOCX (
    if exist "%TEMP_REPORT_MD_DOCX%" del /f /q "%TEMP_REPORT_MD_DOCX%" >nul 2>&1
)
set "TEMP_REPORT_MD_DOCX="
exit /b 0
