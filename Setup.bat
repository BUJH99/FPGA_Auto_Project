@echo off
setlocal

:PROMPT
set /p ProjectName="Enter project name: "

if "%ProjectName%"=="" goto PROMPT

if exist "%ProjectName%" (
    echo [ERROR] "%ProjectName%" already exists. Please use a different name.
    goto PROMPT
)

mkdir "%ProjectName%"
mkdir "%ProjectName%\constrs"
mkdir "%ProjectName%\output"
mkdir "%ProjectName%\src"
mkdir "%ProjectName%\tb"
mkdir "%ProjectName%\ip"
mkdir "%ProjectName%\md"
mkdir "%ProjectName%\skills"
mkdir "%ProjectName%\bat"
mkdir "%ProjectName%\tcl"
mkdir "%ProjectName%\tools"

set "TEMPLATE_DIR=%~dp0templates"

if exist "%TEMPLATE_DIR%\bat" (
    xcopy /e /i /y "%TEMPLATE_DIR%\bat" "%ProjectName%\bat" >nul
)
if exist "%TEMPLATE_DIR%\tcl" (
    xcopy /e /i /y "%TEMPLATE_DIR%\tcl" "%ProjectName%\tcl" >nul
)
if exist "%TEMPLATE_DIR%\tools" (
    xcopy /e /i /y "%TEMPLATE_DIR%\tools" "%ProjectName%\tools" >nul
)
if exist "%TEMPLATE_DIR%\report_assets" (
    xcopy /e /i /y "%TEMPLATE_DIR%\report_assets" "%ProjectName%\report_assets" >nul
)
if exist "%TEMPLATE_DIR%\package.json" (
    copy /y "%TEMPLATE_DIR%\package.json" "%ProjectName%\package.json" >nul
)
if exist "%TEMPLATE_DIR%\node_modules\xml2js" (
    xcopy /e /i /y "%TEMPLATE_DIR%\node_modules\xml2js" "%ProjectName%\node_modules\xml2js" >nul
)
if exist "%TEMPLATE_DIR%\node_modules\sax" (
    xcopy /e /i /y "%TEMPLATE_DIR%\node_modules\sax" "%ProjectName%\node_modules\sax" >nul
)
if exist "%TEMPLATE_DIR%\node_modules\xmlbuilder" (
    xcopy /e /i /y "%TEMPLATE_DIR%\node_modules\xmlbuilder" "%ProjectName%\node_modules\xmlbuilder" >nul
)
if exist "%TEMPLATE_DIR%\MAIN.bat" (
    copy /y "%TEMPLATE_DIR%\MAIN.bat" "%ProjectName%\MAIN.bat" >nul
)
if exist "%TEMPLATE_DIR%\AGENTS.md" (
    copy /y "%TEMPLATE_DIR%\AGENTS.md" "%ProjectName%\AGENTS.md" >nul
)
if exist "%TEMPLATE_DIR%\tb" (
    xcopy /e /i /y "%TEMPLATE_DIR%\tb" "%ProjectName%\tb" >nul
)
if exist "%TEMPLATE_DIR%\ip" (
    xcopy /e /i /y "%TEMPLATE_DIR%\ip" "%ProjectName%\ip" >nul
)
if exist "%TEMPLATE_DIR%\md" (
    xcopy /e /i /y "%TEMPLATE_DIR%\md" "%ProjectName%\md" >nul
)
if exist "%TEMPLATE_DIR%\skills" (
    xcopy /e /i /y "%TEMPLATE_DIR%\skills" "%ProjectName%\skills" >nul
)

echo.
echo ------------------------------------------------
echo [%ProjectName%] project folders created.
echo ------------------------------------------------
if exist "%ProjectName%\package.json" (
    echo [INFO] Block diagram automation dependencies:
    echo        Run npm install once inside "%ProjectName%"
)
if exist "%ProjectName%\node_modules\xml2js" (
    echo [INFO] Copied local svg2drawio dependencies:
    echo        node_modules\xml2js, sax, xmlbuilder
)
if exist "%ProjectName%\bat\run_vivado_build_flow.bat" (
    echo [INFO] Main build script:
    echo        "%ProjectName%\bat\run_vivado_build_flow.bat"
)
if exist "%ProjectName%\MAIN.bat" (
    echo [INFO] Launcher script:
    echo        "%ProjectName%\MAIN.bat"
)
if exist "%ProjectName%\AGENTS.md" (
    echo [INFO] Agent rule file:
    echo        "%ProjectName%\AGENTS.md"
)
pause
endlocal
