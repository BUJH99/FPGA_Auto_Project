@echo off
setlocal

:PROMPT
set /p ProjectName="Enter project name: "

if "%ProjectName%"=="" goto PROMPT

mkdir "%ProjectName%"
mkdir "%ProjectName%\constrs"
mkdir "%ProjectName%\output"
mkdir "%ProjectName%\scripts"
mkdir "%ProjectName%\src"
mkdir "%ProjectName%\tb"
mkdir "%ProjectName%\ip"

set "TEMPLATE_DIR=%~dp0templates"

if exist "%TEMPLATE_DIR%\scripts" (
    xcopy /e /i /y "%TEMPLATE_DIR%\scripts" "%ProjectName%\scripts" >nul
)
if exist "%TEMPLATE_DIR%\autorun.bat" (
    copy /y "%TEMPLATE_DIR%\autorun.bat" "%ProjectName%\autorun.bat" >nul
)
if exist "%TEMPLATE_DIR%\program_device.bat" (
    copy /y "%TEMPLATE_DIR%\program_device.bat" "%ProjectName%\program_device.bat" >nul
)
if exist "%TEMPLATE_DIR%\sim_icarus.bat" (
    copy /y "%TEMPLATE_DIR%\sim_icarus.bat" "%ProjectName%\sim_icarus.bat" >nul
)
if exist "%TEMPLATE_DIR%\draw_schematic.bat" (
    copy /y "%TEMPLATE_DIR%\draw_schematic.bat" "%ProjectName%\draw_schematic.bat" >nul
)
if exist "%TEMPLATE_DIR%\generate_simple_svg.ps1" (
    copy /y "%TEMPLATE_DIR%\generate_simple_svg.ps1" "%ProjectName%\generate_simple_svg.ps1" >nul
)
if exist "%TEMPLATE_DIR%\process_schematic.ps1" (
    copy /y "%TEMPLATE_DIR%\process_schematic.ps1" "%ProjectName%\process_schematic.ps1" >nul
)
if exist "%TEMPLATE_DIR%\svg2drawio.js" (
    copy /y "%TEMPLATE_DIR%\svg2drawio.js" "%ProjectName%\svg2drawio.js" >nul
)
if exist "%TEMPLATE_DIR%\skin.svg" (
    copy /y "%TEMPLATE_DIR%\skin.svg" "%ProjectName%\skin.svg" >nul
)
if exist "%TEMPLATE_DIR%\package.json" (
    copy /y "%TEMPLATE_DIR%\package.json" "%ProjectName%\package.json" >nul
)
if exist "%TEMPLATE_DIR%\create_module.bat" (
    copy /y "%TEMPLATE_DIR%\create_module.bat" "%ProjectName%\create_module.bat" >nul
)
if exist "%TEMPLATE_DIR%\create_tb.bat" (
    copy /y "%TEMPLATE_DIR%\create_tb.bat" "%ProjectName%\create_tb.bat" >nul
)
if exist "%TEMPLATE_DIR%\live_hierarchy.bat" (
    copy /y "%TEMPLATE_DIR%\live_hierarchy.bat" "%ProjectName%\live_hierarchy.bat" >nul
)
if exist "%TEMPLATE_DIR%\show_hierarchy.bat" (
    copy /y "%TEMPLATE_DIR%\show_hierarchy.bat" "%ProjectName%\show_hierarchy.bat" >nul
)
if exist "%TEMPLATE_DIR%\open_ipi_gui.bat" (
    copy /y "%TEMPLATE_DIR%\open_ipi_gui.bat" "%ProjectName%\open_ipi_gui.bat" >nul
)
if exist "%TEMPLATE_DIR%\finalize_bd.bat" (
    copy /y "%TEMPLATE_DIR%\finalize_bd.bat" "%ProjectName%\finalize_bd.bat" >nul
)
if exist "%TEMPLATE_DIR%\retarget_ip.bat" (
    copy /y "%TEMPLATE_DIR%\retarget_ip.bat" "%ProjectName%\retarget_ip.bat" >nul
)
if exist "%TEMPLATE_DIR%\build_config.tcl" (
    copy /y "%TEMPLATE_DIR%\build_config.tcl" "%ProjectName%\build_config.tcl" >nul
)
if exist "%TEMPLATE_DIR%\tb" (
    xcopy /e /i /y "%TEMPLATE_DIR%\tb" "%ProjectName%\tb" >nul
)
if exist "%TEMPLATE_DIR%\ip" (
    xcopy /e /i /y "%TEMPLATE_DIR%\ip" "%ProjectName%\ip" >nul
)

echo.
echo ------------------------------------------------
echo [%ProjectName%] project folders created.
echo ------------------------------------------------
if exist "%ProjectName%\package.json" (
    echo [INFO] Block diagram automation dependencies:
    echo        Run npm install once inside %ProjectName%
)
pause
endlocal
