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
mode con: cols=120 lines=40 >nul 2>&1
cls
echo %Green%Project: !TARGET_PROJECT!%Reset%

set "CMD_1=code_schematic_draw.bat"
set "CMD_2=code_verilog_hierarchy_browse.bat"
set "CMD_3=code_fsm_draw.bat"
set "CMD_4=code_presentation_generate.bat"
set "CMD_5=sim_vivado_run.bat"
set "CMD_6=sim_report_auto_run.bat"
set "CMD_7=sim_iverilog_vcd_run.bat"
set "CMD_8=sim_vcd_svg_run.bat"
set "CMD_9=sim_vcd_wavedrom_run.bat"
set "CMD_10=legacy_report_generate.bat"
set "CMD_11=legacy_docs_generate.bat"
set "CMD_12=vivado_ipi_gui_launch.bat"
set "CMD_13=vivado_build_flow_run.bat"
set "CMD_14=vivado_block_design_finalize.bat"
set "CMD_15=vivado_ip_retarget_part.bat"
set "CMD_16=vivado_fpga_program.bat"
set "CMD_17=vivado_build_and_program_auto.bat"

echo %Yellow%[ Code ^& Schematic Generation ]%Reset%
echo   1. Draw Schematic [!CMD_1!]
echo   2. Browse HDL Hierarchy [!CMD_2!]
echo   3. Draw FSM [!CMD_3!]
echo   4. Generate Presentation [!CMD_4!]
echo.

echo %Yellow%[ Simulation ]%Reset%
echo   5. Run Vivado Simulation [!CMD_5!]
echo   6. Auto Sim + Report [!CMD_6!]
echo   7. Run Iverilog VCD (Select TB) [!CMD_7!]
echo   8. Generate SVG from VCD (Select) [!CMD_8!]
echo   9. Generate WaveDrom from VCD (Select) [!CMD_9!]
echo.

echo %Yellow%[Report ^(Vivado HTML / Docs^) ]%Reset%
echo  10. Report Generator [!CMD_10!]
echo  11. Legacy Docs Generator [!CMD_11!]
echo.

echo %Yellow%[ Vivado Flow ^& FPGA ]%Reset%
echo  12. Launch Vivado IPI GUI [!CMD_12!]
echo  13. Run Vivado Build Flow [!CMD_13!]
echo  14. Finalize Block Design [!CMD_14!]
echo  15. Retarget IP to Part [!CMD_15!]
echo  16. Program FPGA Device [!CMD_16!]
echo  17. Auto Build + Program [!CMD_17!]
echo.
echo %Blue%[B] Back to Project Selection%Reset%   %Red%[Q] Quit%Reset%

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
set "TARGET_PROJECT_ABS=%CD%\!TARGET_PROJECT!"

if not exist "!TARGET_BAT!" (
    echo.
    echo %Red%[ERROR] Template script not found: !TARGET_BAT!%Reset%
    pause
    goto :PROJECT_MENU
)

echo.
echo %Green%[RUN] !TARGET_NAME! (Target: !TARGET_PROJECT!)%Reset%
echo %Cyan%===============================================================================%Reset%
cmd /c ""!TARGET_BAT!" "!TARGET_PROJECT_ABS!""
call :ROUTE_VIVADO_ARTIFACTS "!TARGET_PROJECT_ABS!" "%CD%"
call :ROUTE_VIVADO_ARTIFACTS "!TARGET_PROJECT_ABS!" "!TARGET_PROJECT_ABS!"
call :ROUTE_VIVADO_ARTIFACTS "!TARGET_PROJECT_ABS!" "!TARGET_PROJECT_ABS!\work"
echo %Cyan%===============================================================================%Reset%
echo %Green%[DONE] !TARGET_NAME!%Reset%
echo.
pause
goto :PROJECT_MENU

:ROUTE_VIVADO_ARTIFACTS
set "ROUTE_PROJECT=%~f1"
set "ROUTE_SCAN_ROOT=%~f2"
if "%ROUTE_PROJECT%"=="" exit /b 0
if "%ROUTE_SCAN_ROOT%"=="" exit /b 0
if not exist "%ROUTE_SCAN_ROOT%" exit /b 0

set "ROUTE_LOG_DIR=%ROUTE_PROJECT%\log"
if not exist "%ROUTE_LOG_DIR%" mkdir "%ROUTE_LOG_DIR%" >nul 2>&1

pushd "%ROUTE_SCAN_ROOT%" >nul 2>&1
for %%F in (vivado.log vivado.jou vivado.pb vivado.str) do (
    if exist "%%F" move /y "%%F" "%ROUTE_LOG_DIR%\" >nul 2>&1
)
for %%F in (vivado_*.backup.log vivado_*.backup.jou vivado_*.backup.str *.backup.log *.backup.jou *.backup.str) do (
    if exist "%%F" move /y "%%F" "%ROUTE_LOG_DIR%\" >nul 2>&1
)
popd >nul 2>&1
exit /b 0

:EXIT
echo.
echo %Gray%MAIN.bat closed.%Reset%
endlocal
exit /b 0
