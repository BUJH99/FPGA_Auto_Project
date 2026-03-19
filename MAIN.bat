@echo off
setlocal EnableDelayedExpansion
cd /d "%~dp0"
title FPGA Automation - MAIN
set "SETUP_BAT=%CD%\templates\contexts\project_bootstrap\adapters\bat\project_create.bat"
set "PROJECT_ROOT=%CD%\Project"
set "CONSOLE_HELPER=%CD%\templates\shared\adapters\bat\console_ui.bat"

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
set "USER_CANCEL_RC=99"

:MASTER_MENU
call "%CONSOLE_HELPER%" clear
echo.
echo %Cyan%===============================================================================%Reset%
echo  %Green%FPGA Automation MASTER Menu%Reset%
echo %Cyan%===============================================================================%Reset%
echo.

:: Scan only Project/* directories (manifest-only policy)
set "PROJ_COUNT=0"
echo Available Projects:
if exist "%PROJECT_ROOT%\" (
    for /d %%D in ("%PROJECT_ROOT%\*") do (
        if exist "%%~fD\src" (
            if exist "%%~fD\fpga_auto.yml" (
                set /a PROJ_COUNT+=1
                set "PROJ_PATH_!PROJ_COUNT!=%%~fD"
                set "PROJ_LABEL_!PROJ_COUNT!=Project\%%~nxD"
                echo   %White%[!PROJ_COUNT!] Project\%%~nxD%Reset%
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
        call "%CONSOLE_HELPER%" pause_then_clear
        goto :EXIT
    )
    set "FPGA_AUTO_PARENT_MENU=1"
    call "!SETUP_BAT!"
    set "FPGA_AUTO_PARENT_MENU="
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
        call "%CONSOLE_HELPER%" pause_then_clear
        goto :MASTER_MENU
    )
    set "FPGA_AUTO_PARENT_MENU=1"
    call "!SETUP_BAT!"
    set "FPGA_AUTO_PARENT_MENU="
    goto :MASTER_MENU
)

if "!PROJ_INPUT!"=="" goto :MASTER_MENU

echo(!PROJ_INPUT!| findstr /r "^[0-9][0-9]*$" >nul
if errorlevel 1 (
    set "TARGET_PROJECT_ABS="
    if exist "%PROJECT_ROOT%\!PROJ_INPUT!\fpga_auto.yml" (
        for %%I in ("%PROJECT_ROOT%\!PROJ_INPUT!") do set "TARGET_PROJECT_ABS=%%~fI"
    )
    if defined TARGET_PROJECT_ABS if exist "!TARGET_PROJECT_ABS!\src" if exist "!TARGET_PROJECT_ABS!\fpga_auto.yml" (
        call :SET_PROJECT_LABEL "!TARGET_PROJECT_ABS!"
        goto :PROJECT_MENU
    )
    goto :MASTER_MENU
)

if !PROJ_INPUT! lss 1 goto :MASTER_MENU
if !PROJ_INPUT! gtr !PROJ_COUNT! goto :MASTER_MENU

set "TARGET_PROJECT_ABS=!PROJ_PATH_%PROJ_INPUT%!"
set "TARGET_PROJECT=!PROJ_LABEL_%PROJ_INPUT%!"

:PROJECT_MENU
mode con: cols=120 lines=40 >nul 2>&1
call "%CONSOLE_HELPER%" clear
echo %Green%Project: !TARGET_PROJECT!%Reset%

set "CMD_1=contexts\code_intel\adapters\bat\code_draw_schematic.bat"
set "CMD_2=contexts\code_intel\adapters\bat\code_browse_hierarchy.bat"
set "CMD_3=contexts\code_intel\adapters\bat\code_draw_fsm.bat"
set "CMD_4=contexts\reporting\adapters\bat\report_generate_presentation.bat"
set "CMD_5=contexts\simulation\adapters\bat\sim_run_vivado.bat"
set "CMD_6=contexts\simulation\adapters\bat\sim_run_auto_report.bat"
set "CMD_7=contexts\simulation\adapters\bat\sim_run_iverilog_vcd.bat"
set "CMD_8=contexts\simulation\adapters\bat\sim_convert_vcd_svg.bat"
set "CMD_9=contexts\simulation\adapters\bat\sim_convert_vcd_wavedrom.bat"
set "CMD_19=contexts\simulation\adapters\bat\sim_create_dut_tb_scaffold.bat"
set "CMD_20=contexts\simulation\adapters\bat\sim_run_vivado_nogui.bat"
set "CMD_21=shared\adapters\bat\toolkit_doctor.bat"
set "CMD_10=contexts\reporting\adapters\bat\report_generate_legacy_html.bat"
set "CMD_11=contexts\reporting\adapters\bat\report_generate_docs.bat"
set "CMD_18=contexts\reporting\adapters\bat\report_open_latest_presentation_html.bat"
set "CMD_12=contexts\vivado\adapters\bat\vivado_launch_ipi_gui.bat"
set "CMD_13=contexts\vivado\adapters\bat\vivado_run_build_flow.bat"
set "CMD_14=contexts\vivado\adapters\bat\vivado_finalize_block_design.bat"
set "CMD_15=contexts\vivado\adapters\bat\vivado_retarget_ip_part.bat"
set "CMD_16=contexts\vivado\adapters\bat\vivado_program_fpga.bat"
set "CMD_17=contexts\vivado\adapters\bat\vivado_run_build_and_program.bat"

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
echo  19. Create DUT TB Scaffold [!CMD_19!]
echo  20. NO GUI Run Vivado Simulation [!CMD_20!]
echo.

echo %Yellow%[Report ^(Vivado HTML / Docs^) ]%Reset%
echo  10. Report Generator [!CMD_10!]
echo  11. Docs Generator [!CMD_11!]
echo  18. Open Latest Presentation HTML [!CMD_18!]
echo.

echo %Yellow%[ Vivado Flow ^& FPGA ]%Reset%
echo  12. Launch Vivado IPI GUI [!CMD_12!]
echo  13. Run Vivado Build Flow [!CMD_13!]
echo  14. Finalize Block Design [!CMD_14!]
echo  15. Retarget IP to Part [!CMD_15!]
echo  16. Program FPGA Device [!CMD_16!]
echo  17. Auto Build + Program [!CMD_17!]
echo.
echo %Yellow%[ Project Health ]%Reset%
echo  21. Toolkit Doctor [!CMD_21!]
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

set "TARGET_BAT=%CD%\templates\!TARGET_NAME!"

if not exist "!TARGET_BAT!" (
    echo.
    echo %Red%[ERROR] Template script not found: !TARGET_BAT!%Reset%
    call "%CONSOLE_HELPER%" pause_then_clear
    goto :PROJECT_MENU
)

call "%CONSOLE_HELPER%" clear
echo %Green%[RUN] !TARGET_NAME! (Target: !TARGET_PROJECT!)%Reset%
echo %Cyan%===============================================================================%Reset%
set "FPGA_AUTO_PARENT_MENU=1"
cmd /c ""!TARGET_BAT!" "!TARGET_PROJECT_ABS!""
set "CHILD_RC=!errorlevel!"
set "FPGA_AUTO_PARENT_MENU="
call :ROUTE_VIVADO_ARTIFACTS "!TARGET_PROJECT_ABS!" "%CD%"
call :ROUTE_VIVADO_ARTIFACTS "!TARGET_PROJECT_ABS!" "!TARGET_PROJECT_ABS!"
call :ROUTE_VIVADO_ARTIFACTS "!TARGET_PROJECT_ABS!" "!TARGET_PROJECT_ABS!\work"
if "!CHILD_RC!"=="%USER_CANCEL_RC%" goto :PROJECT_MENU
echo %Cyan%===============================================================================%Reset%
if not "!CHILD_RC!"=="0" (
    echo %Red%[FAIL] !TARGET_NAME! exited with code !CHILD_RC!%Reset%
    echo.
    call "%CONSOLE_HELPER%" pause_then_clear
    goto :PROJECT_MENU
)
echo %Green%[DONE] !TARGET_NAME!%Reset%
echo.
call "%CONSOLE_HELPER%" pause_then_clear
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

:SET_PROJECT_LABEL
set "TARGET_PROJECT_ABS=%~f1"
set "TARGET_PROJECT=%TARGET_PROJECT_ABS%"
set "TMP_REL=!TARGET_PROJECT_ABS:%CD%\=!"
if not "!TMP_REL!"=="!TARGET_PROJECT_ABS!" (
    if "!TMP_REL:~0,1!"=="\" set "TMP_REL=!TMP_REL:~1!"
    if not "!TMP_REL!"=="" set "TARGET_PROJECT=!TMP_REL!"
)
exit /b 0

:EXIT
echo.
echo %Gray%MAIN.bat closed.%Reset%
endlocal
exit /b 0
