@echo off
setlocal EnableDelayedExpansion
cd /d "%~dp0"
title FPGA Automation - MAIN
set "SETUP_BAT=%CD%\templates\bat\setup_project.bat"

:: Define ESC character for ANSI colors
for /F %%a in ('echo prompt $E ^| cmd') do set "ESC=%%a"

:: Define Colors
set "Red=%ESC%[91m"
set "Green=%ESC%[92m"
set "Yellow=%ESC%[93m"
set "Blue=%ESC%[94m"
set "Cyan=%ESC%[96m"
set "White=%ESC%[97m"
set "Reset=%ESC%[0m"
set "Gray=%ESC%[90m"

:MASTER_MENU
cls
echo.
echo %Cyan%===============================================================================%Reset%
echo  %Green%FPGA Automation MASTER Menu%Reset%
echo %Cyan%===============================================================================%Reset%
echo.

:: Scan for project directories (exclude system ones, templates, etc)
set "PROJ_COUNT=0"
echo Available Projects:
for /d %%D in (*) do (
    set "DIR_NAME=%%D"
    REM Skip non-project directories
    if /i not "!DIR_NAME!"=="templates" (
        if /i not "!DIR_NAME!"==".git" (
            if /i not "!DIR_NAME!"==".agent" (
                if /i not "!DIR_NAME!"=="tools" (
                    if exist "%%D\src" (
                        set /a PROJ_COUNT+=1
                        set "PROJ_!PROJ_COUNT!=%%D"
                        echo   %White%[!PROJ_COUNT!] %%D%Reset%
                    )
                )
            )
        )
    )
)

if !PROJ_COUNT! equ 0 goto :NO_PROJECT_MENU
goto :PROJECT_SELECT_MENU

:NO_PROJECT_MENU
echo.
echo %Red%[No Projects Found]%Reset%
echo No valid project folder detected.
echo.
echo   %White%[S] Setup New Project%Reset%
echo   %Red%[Q] Quit%Reset%
echo.

set "NO_PROJ_INPUT="
set /p "NO_PROJ_INPUT=%Cyan%No project found. Run setup now? (S/Q, default S): %Reset%"
if "!NO_PROJ_INPUT!"=="" set "NO_PROJ_INPUT=S"

if /i "!NO_PROJ_INPUT!"=="Q" goto :EXIT
if /i "!NO_PROJ_INPUT!"=="S" (
    if not exist "!SETUP_BAT!" (
        echo.
        echo %Red%[ERROR] Setup script not found: !SETUP_BAT!%Reset%
        echo.
        pause
        goto :EXIT
    )
    call "!SETUP_BAT!"
    goto :MASTER_MENU
)
goto :NO_PROJECT_MENU

:PROJECT_SELECT_MENU

echo.
echo   %White%[S] Setup New Project%Reset%
echo   %Red%[Q] Quit%Reset%
echo.

set "PROJ_INPUT="
set /p "PROJ_INPUT=%Cyan%Select Project (Number) or Option: %Reset%"

if /i "!PROJ_INPUT!"=="Q" goto :EXIT
if /i "!PROJ_INPUT!"=="S" (
    if not exist "!SETUP_BAT!" (
        echo.
        echo %Red%[ERROR] Setup script not found: !SETUP_BAT!%Reset%
        echo.
        pause
        goto :MASTER_MENU
    )
    call "!SETUP_BAT!"
    goto :MASTER_MENU
)

if "!PROJ_INPUT!"=="" goto :MASTER_MENU

echo(!PROJ_INPUT!| findstr /r "^[0-9][0-9]*$" >nul
if errorlevel 1 (
    if exist "!PROJ_INPUT!" (
        :: Direct name input matches folder?
         set "TARGET_PROJECT=!PROJ_INPUT!"
         goto :PROJECT_MENU
    )
    goto :MASTER_MENU
)

if !PROJ_INPUT! lss 1 goto :MASTER_MENU
if !PROJ_INPUT! gtr !PROJ_COUNT! goto :MASTER_MENU

set "TARGET_PROJECT=!PROJ_%PROJ_INPUT%!"

:PROJECT_MENU
cls
echo.
echo %Cyan%===============================================================================%Reset%
echo  %Green%Project: !TARGET_PROJECT!%Reset%
echo %Cyan%===============================================================================%Reset%
echo.

echo %Yellow%[ Code ^& Schematic Generation ]%Reset%
call :ADD_MENU_ITEM 1 "code_schematic_draw.bat" "Draw Schematic"
call :ADD_MENU_ITEM 2 "code_verilog_hierarchy_browse.bat" "Browse Verilog Hierarchy"
call :ADD_MENU_ITEM 3 "code_verilog_hierarchy_print.bat" "Print Verilog Hierarchy"
call :ADD_MENU_ITEM 4 "code_fsm_draw.bat" "Draw FSM"
call :ADD_MENU_ITEM 5 "code_presentation_generate.bat" "Generate Presentation"
echo.

echo %Yellow%[ Simulation ]%Reset%
call :ADD_MENU_ITEM 6 "sim_vivado_run.bat" "Run Vivado Simulation"
call :ADD_MENU_ITEM 7 "sim_report_auto_run.bat" "Auto Sim + Report"
call :ADD_MENU_ITEM 8 "sim_iverilog_vcd_run.bat" "Run Iverilog VCD (Select TB)"
call :ADD_MENU_ITEM 9 "sim_vcd_svg_run.bat" "Generate SVG from VCD (Select)"
echo.

echo %Yellow%[ Report Automation ^(One Source^) ]%Reset%
call :ADD_MENU_ITEM 10 "report_hdl_info_annotate.bat" "Annotate HDL Info"
call :ADD_MENU_ITEM 11 "report_waveform_folders_prepare.bat" "Prepare Waveform Folders"
call :ADD_MENU_ITEM 12 "report_markdown_generate.bat" "Generate Report Markdown"
call :ADD_MENU_ITEM 13 "report_markdown_to_docx.bat" "Build Report from Markdown"
echo.

echo %Yellow%[ Legacy Report ^(Vivado HTML / Old Docs^) ]%Reset%
call :ADD_MENU_ITEM 14 "legacy_report_generate.bat" "Legacy Report Generator"
call :ADD_MENU_ITEM 15 "legacy_docs_generate.bat" "Legacy Docs Generator"
echo.

echo %Yellow%[ Vivado Flow ^& FPGA ]%Reset%
call :ADD_MENU_ITEM 16 "vivado_ipi_gui_launch.bat" "Launch Vivado IPI GUI"
call :ADD_MENU_ITEM 17 "vivado_build_flow_run.bat" "Run Vivado Build Flow"
call :ADD_MENU_ITEM 18 "vivado_block_design_finalize.bat" "Finalize Block Design"
call :ADD_MENU_ITEM 19 "vivado_ip_retarget_part.bat" "Retarget IP to Part"
call :ADD_MENU_ITEM 20 "vivado_fpga_program.bat" "Program FPGA Device"
call :ADD_MENU_ITEM 21 "vivado_build_and_program_auto.bat" "Auto Build + Program"
echo.

echo   %Blue%[B] Back to Project Selection%Reset%
echo   %Red%[Q] Quit%Reset%
echo.

set "USER_INPUT="
set /p "USER_INPUT=%Cyan%Select number to run (or B/Q): %Reset%"

if /i "!USER_INPUT!"=="Q" goto :EXIT
if /i "!USER_INPUT!"=="B" goto :MASTER_MENU
if "!USER_INPUT!"=="" goto :PROJECT_MENU

:: Validate input is a number
echo(!USER_INPUT!| findstr /r "^[0-9][0-9]*$" >nul
if errorlevel 1 (
    echo.
    echo %Red%[ERROR] Invalid input: !USER_INPUT!%Reset%
    timeout /t 1 >nul
    goto :PROJECT_MENU
)

:: Get target filename from array
call set "TARGET_NAME=%%CMD_!USER_INPUT!%%"

if "!TARGET_NAME!"=="" (
    echo.
    echo %Red%[ERROR] Invalid selection: !USER_INPUT!%Reset%
    timeout /t 1 >nul
    goto :PROJECT_MENU
)

set "TARGET_BAT=%CD%\templates\bat\!TARGET_NAME!"

if not exist "!TARGET_BAT!" (
    echo.
    echo %Red%[ERROR] Template script not found: !TARGET_BAT!%Reset%
    pause
    goto :PROJECT_MENU
)

echo.
echo %Green%[RUN] !TARGET_NAME! (Target: !TARGET_PROJECT!)%Reset%
echo %Cyan%===============================================================================%Reset%
cmd /c ""!TARGET_BAT!" "%CD%\!TARGET_PROJECT!""
echo %Cyan%===============================================================================%Reset%
echo %Green%[DONE] !TARGET_NAME!%Reset%
echo.
pause
goto :PROJECT_MENU

:ADD_MENU_ITEM
set "IDX=%~1"
set "FILE=%~2"
set "LABEL=%~3"
set "CMD_!IDX!=!FILE!"
if not defined LABEL set "LABEL=!FILE!"
if !IDX! lss 10 ( set "PAD= " ) else ( set "PAD=" )

if exist "templates\bat\!FILE!" (
    echo   %Gray%!PAD!%Reset%%White%!IDX!. !LABEL!%Reset% %Gray%[!FILE!]%Reset%
) else (
    echo   %Red%!PAD!!IDX!. !LABEL! ^(Missing: !FILE!^)%Reset%
)
exit /b

:EXIT
echo.
echo %Gray%MAIN.bat closed.%Reset%
endlocal
exit /b 0
