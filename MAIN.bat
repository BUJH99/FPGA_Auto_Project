@echo off
setlocal EnableDelayedExpansion
cd /d "%~dp0"
title FPGAClaw
set "TEMPLATES_ROOT=%CD%\templates"
set "SETTINGS_LOADER=%TEMPLATES_ROOT%\shared\adapters\bat\load_fpga_claw_settings.bat"
if exist "%SETTINGS_LOADER%" call "%SETTINGS_LOADER%"
if not defined TEMPLATES_ROOT set "TEMPLATES_ROOT=%CD%\templates"
set "SETTINGS_LOADER=%TEMPLATES_ROOT%\shared\adapters\bat\load_fpga_claw_settings.bat"
set "SETUP_BAT=%TEMPLATES_ROOT%\contexts\project_bootstrap\adapters\bat\project_create.bat"
set "UPGRADE_BAT=%TEMPLATES_ROOT%\contexts\project_bootstrap\adapters\bat\project_upgrade_existing.bat"
set "SETTINGS_BAT=%TEMPLATES_ROOT%\contexts\settings\adapters\bat\fpga_claw_settings.bat"
set "CONSOLE_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\console_ui.bat"
set "PROJECT_ROOT_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\resolve_managed_project_root.bat"

if not defined PROJECT_ROOT if exist "%PROJECT_ROOT_HELPER%" call "%PROJECT_ROOT_HELPER%" "%CD%"
if defined FPGA_AUTO_PROJECT_ROOT if not defined PROJECT_ROOT (
    set "PROJECT_ROOT=%FPGA_AUTO_PROJECT_ROOT%"
)
if not defined PROJECT_ROOT (
    for %%I in ("%CD%\..") do set "PROJECT_ROOT=%%~fI\Project"
)

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
set "Lime=%ESC%[38;5;118m"
set "NeonBlue=%ESC%[38;5;81m"
set "Border=%ESC%[38;5;245m"
set "Amber=%ESC%[38;5;227m"
set "USER_CANCEL_RC=99"

:MASTER_MENU
mode con: cols=122 lines=46 >nul 2>&1
call "%CONSOLE_HELPER%" clear
call :SCAN_MANAGED_PROJECTS
call :DETECT_VIVADO_VERSION
if !PROJ_COUNT! equ 0 (
    set "DASH_TARGET_DISPLAY=unknown"
    call :DRAW_CLAW_DASHBOARD
    goto :NO_PROJECT_MENU
)

call :APPLY_PREFERRED_PROJECT
if not defined TARGET_PROJECT_ABS (
    set "TARGET_PROJECT_ABS=!PROJ_PATH_1!"
    set "TARGET_PROJECT=!PROJ_LABEL_1!"
)
call :LOAD_PROJECT_CARD "!TARGET_PROJECT_ABS!"
call :DRAW_CLAW_DASHBOARD

set "DASH_INPUT="
echo.
set /p "DASH_INPUT=fpga_auto > "

if "!DASH_INPUT!"=="" goto :PROJECT_MENU
if /i "!DASH_INPUT!"=="H" goto :DASH_HELP_PAGE
if /i "!DASH_INPUT!"=="HELP" goto :DASH_HELP_PAGE
if /i "!DASH_INPUT!"=="?" goto :DASH_HELP_PAGE
if /i "!DASH_INPUT!"=="S" (
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
if /i "!DASH_INPUT!"=="U" (
    call :RUN_PROJECT_UPGRADE ""
    goto :MASTER_MENU
)
if /i "!DASH_INPUT!"=="G" goto :SETTINGS_MENU
if /i "!DASH_INPUT!"=="SETTINGS" goto :SETTINGS_MENU
if /i "!DASH_INPUT!"=="C" goto :CUSTOMBAT_MENU
if /i "!DASH_INPUT!"=="B" goto :MASTER_MENU
if /i "!DASH_INPUT!"=="Q" goto :EXIT
if /i "!DASH_INPUT!"=="QUIT" goto :EXIT
if /i "!DASH_INPUT!"=="EXIT" goto :EXIT
if /i "!DASH_INPUT!"=="MENU" goto :PROJECT_MENU
if /i "!DASH_INPUT!"=="PROJECTS" goto :PROJECT_SELECT_MENU
if /i "!DASH_INPUT!"=="LS" goto :PROJECT_SELECT_MENU

echo(!DASH_INPUT!| findstr /r "^[0-9][0-9]*$" >nul
if not errorlevel 1 (
    if !DASH_INPUT! geq 1 if !DASH_INPUT! leq !PROJ_COUNT! (
        set "TARGET_PROJECT_ABS=!PROJ_PATH_%DASH_INPUT%!"
        set "TARGET_PROJECT=!PROJ_LABEL_%DASH_INPUT%!"
        call :SAVE_LAST_PROJECT "!PROJ_NAME_%DASH_INPUT%!"
        goto :MASTER_MENU
    )
)

goto :DASH_HELP_PAGE

:SCAN_MANAGED_PROJECTS
set "PROJ_COUNT=0"
if exist "%PROJECT_ROOT%\" (
    for /d %%D in ("%PROJECT_ROOT%\*") do (
        if exist "%%~fD\src" (
            if exist "%%~fD\fpga_auto.yml" (
                set /a PROJ_COUNT+=1
                set "PROJ_PATH_!PROJ_COUNT!=%%~fD"
                set "PROJ_LABEL_!PROJ_COUNT!=..\Project\%%~nxD"
                set "PROJ_NAME_!PROJ_COUNT!=%%~nxD"
            )
        )
    )
)
exit /b 0

:APPLY_PREFERRED_PROJECT
if defined TARGET_PROJECT_ABS exit /b 0
set "PREFERRED_PROJECT="
if defined FPGA_CLAW_DEFAULT_PROJECT if not "!FPGA_CLAW_DEFAULT_PROJECT!"=="" set "PREFERRED_PROJECT=!FPGA_CLAW_DEFAULT_PROJECT!"
if not defined PREFERRED_PROJECT if "!FPGA_CLAW_REMEMBER_LAST_PROJECT!"=="1" if defined FPGA_CLAW_LAST_PROJECT if not "!FPGA_CLAW_LAST_PROJECT!"=="" set "PREFERRED_PROJECT=!FPGA_CLAW_LAST_PROJECT!"
if not defined PREFERRED_PROJECT exit /b 0
for /L %%N in (1,1,!PROJ_COUNT!) do (
    if /i "!PROJ_NAME_%%N!"=="!PREFERRED_PROJECT!" (
        set "TARGET_PROJECT_ABS=!PROJ_PATH_%%N!"
        set "TARGET_PROJECT=!PROJ_LABEL_%%N!"
    )
    if /i "!PROJ_LABEL_%%N!"=="!PREFERRED_PROJECT!" (
        set "TARGET_PROJECT_ABS=!PROJ_PATH_%%N!"
        set "TARGET_PROJECT=!PROJ_LABEL_%%N!"
    )
    if /i "!PROJ_PATH_%%N!"=="!PREFERRED_PROJECT!" (
        set "TARGET_PROJECT_ABS=!PROJ_PATH_%%N!"
        set "TARGET_PROJECT=!PROJ_LABEL_%%N!"
    )
)
exit /b 0

:SAVE_LAST_PROJECT
if not "!FPGA_CLAW_REMEMBER_LAST_PROJECT!"=="1" exit /b 0
if "%~1"=="" exit /b 0
set "SETTINGS_CLI=%TEMPLATES_ROOT%\contexts\settings\adapters\cli\fpga_claw_settings_cli.js"
if not exist "!SETTINGS_CLI!" exit /b 0
where node >nul 2>nul
if errorlevel 1 exit /b 0
node "!SETTINGS_CLI!" --repo-root "%CD%" --set user.last_project "%~1" --no-backup >nul 2>nul
exit /b 0

:DETECT_VIVADO_VERSION
set "DASH_VIVADO_DISPLAY=Vivado unknown"
if defined VIVADO_BIN call :SET_VIVADO_DISPLAY_FROM_ROOT "%VIVADO_BIN%"
if /i not "!DASH_VIVADO_DISPLAY!"=="Vivado unknown" exit /b 0
if defined XILINX_VIVADO call :SET_VIVADO_DISPLAY_FROM_ROOT "%XILINX_VIVADO%"
if /i not "!DASH_VIVADO_DISPLAY!"=="Vivado unknown" exit /b 0
for /d %%D in ("C:\AMDDesignTools\*\Vivado") do if /i "!DASH_VIVADO_DISPLAY!"=="Vivado unknown" call :SET_VIVADO_DISPLAY_FROM_ROOT "%%~fD"
for /d %%D in ("C:\Xilinx\Vivado\*") do if /i "!DASH_VIVADO_DISPLAY!"=="Vivado unknown" call :SET_VIVADO_DISPLAY_FROM_ROOT "%%~fD"
exit /b 0

:SET_VIVADO_DISPLAY_FROM_ROOT
set "DASH_VIVADO_ROOT=%~f1"
set "DASH_VIVADO_VERSION="
for %%I in ("%DASH_VIVADO_ROOT%") do set "DASH_VIVADO_VERSION=%%~nxI"
if /i "!DASH_VIVADO_VERSION!"=="Vivado" (
    for %%I in ("%DASH_VIVADO_ROOT%\..") do set "DASH_VIVADO_VERSION=%%~nxI"
)
if not "!DASH_VIVADO_VERSION!"=="" set "DASH_VIVADO_DISPLAY=Vivado !DASH_VIVADO_VERSION!"
exit /b 0

:LOAD_PROJECT_CARD
for %%I in ("%~1") do set "DASH_PROJECT_NAME=%%~nxI"
set "DASH_PROJECT_NAME_LOCK="
set "DASH_TARGET_PART=xczu3eg-sbva484-1-i"
set "DASH_TARGET_BOARD=Ultra96v2"
if exist "%~1\fpga_auto.yml" (
    for /f "usebackq tokens=1,* delims=:" %%A in ("%~1\fpga_auto.yml") do (
        set "DASH_YAML_KEY=%%~A"
        set "DASH_YAML_VAL=%%~B"
        set "DASH_YAML_KEY=!DASH_YAML_KEY: =!"
        set "DASH_YAML_KEY=!DASH_YAML_KEY:"=!"
        for /f "tokens=* delims= " %%V in ("!DASH_YAML_VAL!") do set "DASH_YAML_VAL=%%~V"
        set "DASH_YAML_VAL=!DASH_YAML_VAL:"=!"
        if /i "!DASH_YAML_KEY!"=="name" if not defined DASH_PROJECT_NAME_LOCK if not "!DASH_YAML_VAL!"=="" (
            set "DASH_PROJECT_NAME=!DASH_YAML_VAL!"
            set "DASH_PROJECT_NAME_LOCK=1"
        )
        if /i "!DASH_YAML_KEY!"=="part" if not "!DASH_YAML_VAL!"=="" set "DASH_TARGET_PART=!DASH_YAML_VAL!"
        if /i "!DASH_YAML_KEY!"=="board" if not "!DASH_YAML_VAL!"=="" set "DASH_TARGET_BOARD=!DASH_YAML_VAL!"
    )
)
if defined FPGA_CLAW_PART if not "!FPGA_CLAW_PART!"=="" set "DASH_TARGET_PART=!FPGA_CLAW_PART!"
if defined FPGA_CLAW_DEFAULT_BOARD if not "!FPGA_CLAW_DEFAULT_BOARD!"=="" set "DASH_TARGET_BOARD=!FPGA_CLAW_DEFAULT_BOARD!"
if defined DASH_TARGET_BOARD (
    set "DASH_TARGET_DISPLAY=!DASH_TARGET_BOARD!"
) else (
    set "DASH_TARGET_DISPLAY=!DASH_TARGET_PART!"
    if /i "!DASH_TARGET_DISPLAY:~0,2!"=="xc" if not "!DASH_TARGET_DISPLAY:~7!"=="" set "DASH_TARGET_DISPLAY=!DASH_TARGET_DISPLAY:~0,7!"
)
exit /b 0

:DRAW_CLAW_DASHBOARD
if not defined DASH_TARGET_DISPLAY set "DASH_TARGET_DISPLAY=Ultra96v2"
echo.
echo %Lime%      ______  ______  ______   ______   ______  __        ______  __       __            %White%     //   //   //%Reset%
echo %Lime%     / ____/ / __  / / ____/  / ____/  / ____/ / /       / __  / / /  _   / /           %White%    //   //   //%Reset%
echo %Lime%    / /_    / /_/ / / / __   / /_     / /     / /       / /_/ / / /  / /  / /            %White%   //   //   //%Reset%
echo %Lime%   / __/   / ____/ / /_/ /  / __/    / /     / /       / __  / / /  / /  / /             %White%  //   //   //%Reset%
echo %Lime%  / /     / /      / ___/  / /____  / /____ / /____   / / / / / /__/ /__/ /              %White% //   //   //%Reset%
echo %Lime% /_/     /_/      /_/     /_____/  /_____/ /_____/  /_/ /_/  \____/\____/               %White%//   //   //%Reset%
echo.
echo %Border%  ------------------%Reset%    %White%T C L   A U T O M A T I O N%Reset%    %Border%------------------------------%Reset%
echo.
echo %Border%        +----------------------------------------------------------------+%Reset%
echo %Border%        ^|%Reset% %White%^>_%Reset%  %NeonBlue%v1.0.0%Reset%    %Border%^|%Reset%    %NeonBlue%Tcl 8.6%Reset%    %Border%^|%Reset%    %NeonBlue%%DASH_VIVADO_DISPLAY%%Reset%                 %Border%^|%Reset%
echo %Border%        +----------------------------------------------------------------+%Reset%
echo.
echo %Border%  +-------------------------------------------------------------------------+%Reset%
echo %Border%  ^|%Reset% %Lime%[ ] Project INFO%Reset%                                                        %Border%^|%Reset%
echo %Border%  ^|                                                                         ^|%Reset%
echo %Border%  ^|%Reset%      %NeonBlue%[chip]%Reset%   %NeonBlue%project%Reset%      %White%:%Reset%   %White%%DASH_PROJECT_NAME%%Reset%                              %Border%^|%Reset%
echo %Border%  ^|%Reset%      %NeonBlue%[aim ]%Reset%   %NeonBlue%target%Reset%       %White%:%Reset%   %White%%DASH_TARGET_DISPLAY%%Reset%                                %Border%^|%Reset%
echo %Border%  +-------------------------------------------------------------------------+%Reset%
echo.
echo %Border%  +----------------------------------------------------------------------------------------+%Reset%
echo %Border%  ^|%Reset% %Amber%PROJECT FOLDERS%Reset%  %Gray%(type number to select, Enter for selected project)%Reset%                 %Border%^|%Reset%
call :DRAW_PROJECT_PICKER
echo %Border%  +----------------------------------------------------------------------------------------+%Reset%
echo.
echo %Border%  +----------------------------------------------------------------------------------------+%Reset%
echo %Border%  ^|%Reset% %Amber%SHORTCUTS%Reset%                                                                           %Border%^|%Reset%
echo %Border%  ^|%Reset%  %Lime%[H]%Reset% Help        %Lime%[S]%Reset% Setup New Project      %Lime%[U]%Reset% Upgrade Projects      %Lime%[Q]%Reset% Quit       %Border%^|%Reset%
echo %Border%  ^|%Reset%  %Lime%[G]%Reset% Settings    %Lime%[C]%Reset% CUSTOMBAT              %Lime%[1..N]%Reset% Select Project      %Lime%[Enter]%Reset% Menu   %Border%^|%Reset%
echo %Border%  +----------------------------------------------------------------------------------------+%Reset%
echo.
exit /b 0

:DASH_HELP_PAGE
mode con: cols=122 lines=42 >nul 2>&1
call "%CONSOLE_HELPER%" clear
echo.
echo %Cyan%===============================================================================%Reset%
echo  %Green%FPGAClaw Help%Reset%   %White%Selected Project:%Reset% %Lime%!DASH_PROJECT_NAME!%Reset%   %White%Target:%Reset% %NeonBlue%!DASH_TARGET_DISPLAY!%Reset%
echo %Cyan%===============================================================================%Reset%
echo.
echo %Amber%[ First Screen Shortcuts ]%Reset%
echo   %Lime%1..N%Reset%    Select a project folder on the first screen.
echo   %Lime%Enter%Reset%   Open the full command menu for the selected project.
echo   %Lime%H%Reset%       Show this help page.
echo   %Lime%S%Reset%       Setup a new managed project.
echo   %Lime%U%Reset%       Upgrade existing project structures.
echo   %Lime%G%Reset%       Open FPGAClaw Settings.
echo   %Lime%C%Reset%       Open CUSTOMBAT menu.
echo   %Lime%Q%Reset%       Quit MAIN.bat.
echo.
echo %Amber%[ Full Command Menu Overview ]%Reset%
echo   %NeonBlue%Code / Visual%Reset%    1 Schematic   2 Hierarchy   3 FSM   4 Presentation
echo   %NeonBlue%Simulation%Reset%       5 Vivado Sim  6 Auto Report 7 Iverilog 8 VCD SVG 9 WaveDrom
echo                    19 TB Scaffold 20 Vivado Sim NO GUI
echo   %NeonBlue%Reports%Reset%          10 HTML Report 11 Docs 18 Open Latest Presentation
echo   %NeonBlue%Vivado / FPGA%Reset%    12 Open GUI 13 Build 14 Finalize BD 15 Retarget IP
echo                    16 Program FPGA 17 Build+Program 29 IP Integrator GUI 30 IPI Build
echo   %NeonBlue%Health / Sync%Reset%    21 Toolkit Doctor 31 Remote Sync
echo   %NeonBlue%Vitis%Reset%            22 Export XSA 23 Platform 24 App 25 Build Platform
echo                    26 Build App 27 Run App 28 Full Vitis Flow
echo.
echo %Amber%[ Typical Flow ]%Reset%
echo   1. Pick a project number on the first screen.
echo   2. Press Enter to open its command menu.
echo   3. Run a numbered command, or use B inside that menu to return.
echo.
echo %Gray%Press Enter to open the selected project menu, B to return, Q to quit.%Reset%
set "HELP_INPUT="
echo.
set /p "HELP_INPUT=help > "
if /i "!HELP_INPUT!"=="Q" goto :EXIT
if /i "!HELP_INPUT!"=="QUIT" goto :EXIT
if /i "!HELP_INPUT!"=="B" goto :MASTER_MENU
if "!HELP_INPUT!"=="" goto :PROJECT_MENU
goto :MASTER_MENU

:DRAW_PROJECT_PICKER
if !PROJ_COUNT! equ 0 (
    echo %Border%  ^|%Reset%   No valid project folders found under %PROJECT_ROOT%
    exit /b 0
)
for /L %%N in (1,2,!PROJ_COUNT!) do (
    call :MAKE_PROJECT_CELL %%N DASH_LEFT_CELL
    set /a DASH_RIGHT_INDEX=%%N+1
    if !DASH_RIGHT_INDEX! leq !PROJ_COUNT! (
        call :MAKE_PROJECT_CELL !DASH_RIGHT_INDEX! DASH_RIGHT_CELL
    ) else (
        set "DASH_RIGHT_CELL=                                      "
    )
    echo %Border%  ^|%Reset%  !DASH_LEFT_CELL!  !DASH_RIGHT_CELL!  %Border%^|%Reset%
)
exit /b 0

:MAKE_PROJECT_CELL
set "DASH_CELL_INDEX=%~1"
set "DASH_CELL_OUT=%~2"
call set "DASH_CELL_PATH=%%PROJ_PATH_%DASH_CELL_INDEX%%%"
call set "DASH_CELL_NAME=%%PROJ_NAME_%DASH_CELL_INDEX%%%"
set "DASH_CELL_MARK= "
if /i "!DASH_CELL_PATH!"=="!TARGET_PROJECT_ABS!" set "DASH_CELL_MARK=>"
set "DASH_CELL_TEXT=!DASH_CELL_MARK! [!DASH_CELL_INDEX!] !DASH_CELL_NAME!"
set "DASH_CELL_TEXT=!DASH_CELL_TEXT!                                      "
set "DASH_CELL_TEXT=!DASH_CELL_TEXT:~0,38!"
set "%DASH_CELL_OUT%=!DASH_CELL_TEXT!"
exit /b 0

:NO_PROJECT_MENU
echo.
echo %Red%[No Projects Found]%Reset%
echo No valid project folder detected under:
echo   %PROJECT_ROOT%
echo.
echo   %White%[S] Setup New Project%Reset%
echo   %White%[U] Upgrade Existing Projects%Reset%
echo   %White%[G] Settings%Reset%
echo   %Yellow%[C] CUSTOMBAT%Reset%
echo   %Red%[Q] Quit%Reset%
echo.

set "NO_PROJ_INPUT="
set /p "NO_PROJ_INPUT=%Cyan%No project found. Run setup or upgrade? (S/U/G/C/Q, default S): %Reset%"
if "!NO_PROJ_INPUT!"=="" set "NO_PROJ_INPUT=S"

if /i "!NO_PROJ_INPUT!"=="Q" goto :EXIT
if /i "!NO_PROJ_INPUT!"=="G" goto :SETTINGS_MENU
if /i "!NO_PROJ_INPUT!"=="C" goto :CUSTOMBAT_MENU
if /i "!NO_PROJ_INPUT!"=="U" (
    call :RUN_PROJECT_UPGRADE ""
    goto :MASTER_MENU
)
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
call "%CONSOLE_HELPER%" clear
echo.
echo %Cyan%===============================================================================%Reset%
echo  %Green%FPGA Automation Project Selection%Reset%
echo %Cyan%===============================================================================%Reset%
echo.
echo Available Projects:
for /L %%N in (1,1,!PROJ_COUNT!) do (
    echo   %White%[%%N] !PROJ_LABEL_%%N!%Reset%
)
echo.
echo   %White%[S] Setup New Project%Reset%
echo   %White%[U] Upgrade Existing Projects%Reset%
echo   %White%[G] Settings%Reset%
echo   %Yellow%[C] CUSTOMBAT%Reset%
echo   %Red%[Q] Quit%Reset%
echo.

set "PROJ_INPUT="
set /p "PROJ_INPUT=%Cyan%Select Project (Number) or Option: %Reset%"

if /i "!PROJ_INPUT!"=="Q" goto :EXIT
if /i "!PROJ_INPUT!"=="G" goto :SETTINGS_MENU
if /i "!PROJ_INPUT!"=="C" goto :CUSTOMBAT_MENU
if /i "!PROJ_INPUT!"=="U" (
    call :RUN_PROJECT_UPGRADE ""
    goto :MASTER_MENU
)
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
        call :SAVE_LAST_PROJECT "!PROJ_INPUT!"
        goto :PROJECT_MENU
    )
    goto :MASTER_MENU
)

if !PROJ_INPUT! lss 1 goto :MASTER_MENU
if !PROJ_INPUT! gtr !PROJ_COUNT! goto :MASTER_MENU

set "TARGET_PROJECT_ABS=!PROJ_PATH_%PROJ_INPUT%!"
set "TARGET_PROJECT=!PROJ_LABEL_%PROJ_INPUT%!"
call :SAVE_LAST_PROJECT "!PROJ_NAME_%PROJ_INPUT%!"
goto :PROJECT_MENU

:SETTINGS_MENU
if not exist "!SETTINGS_BAT!" (
    echo.
    echo %Red%[ERROR] Settings script not found: !SETTINGS_BAT!%Reset%
    echo.
    call "%CONSOLE_HELPER%" pause_then_clear
    goto :MASTER_MENU
)
call "!SETTINGS_BAT!"
if exist "!SETTINGS_LOADER!" call "!SETTINGS_LOADER!"
set "SETTINGS_LOADER=%TEMPLATES_ROOT%\shared\adapters\bat\load_fpga_claw_settings.bat"
set "SETUP_BAT=%TEMPLATES_ROOT%\contexts\project_bootstrap\adapters\bat\project_create.bat"
set "UPGRADE_BAT=%TEMPLATES_ROOT%\contexts\project_bootstrap\adapters\bat\project_upgrade_existing.bat"
set "SETTINGS_BAT=%TEMPLATES_ROOT%\contexts\settings\adapters\bat\fpga_claw_settings.bat"
set "CONSOLE_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\console_ui.bat"
set "PROJECT_ROOT_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\resolve_managed_project_root.bat"
goto :MASTER_MENU

:PROJECT_MENU
mode con: cols=120 lines=36 >nul 2>&1
call "%CONSOLE_HELPER%" clear
echo %Green%Project:%Reset% !TARGET_PROJECT!

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
set "CMD_12=contexts\vivado\adapters\bat\vivado_open_project_gui.bat"
set "CMD_13=contexts\vivado\adapters\bat\vivado_run_build_flow.bat"
set "CMD_14=contexts\vivado\adapters\bat\vivado_finalize_block_design.bat"
set "CMD_15=contexts\vivado\adapters\bat\vivado_retarget_ip_part.bat"
set "CMD_16=contexts\vivado\adapters\bat\vivado_program_fpga.bat"
set "CMD_17=contexts\vivado\adapters\bat\vivado_run_build_and_program.bat"
set "CMD_29=contexts\vivado\adapters\bat\vivado_open_ip_integrator_gui.bat"
set "CMD_30=contexts\vivado\adapters\bat\vivado_build_ip_integrator_flow.bat"
set "CMD_22=contexts\vitis\adapters\bat\vitis_export_xsa.bat"
set "CMD_23=contexts\vitis\adapters\bat\vitis_create_platform.bat"
set "CMD_24=contexts\vitis\adapters\bat\vitis_create_application.bat"
set "CMD_25=contexts\vitis\adapters\bat\vitis_build_platform.bat"
set "CMD_26=contexts\vitis\adapters\bat\vitis_build_application.bat"
set "CMD_27=contexts\vitis\adapters\bat\vitis_run_application.bat"
set "CMD_28=contexts\vitis\adapters\bat\vitis_run_full_flow.bat"
set "CMD_31=contexts\remote_sync\adapters\bat\remote_sync_project_to_t_drive.bat"

if defined PROJECT_MENU_AUTO_RUN (
    set "USER_INPUT=!PROJECT_MENU_AUTO_RUN!"
    set "PROJECT_MENU_AUTO_RUN="
    goto :PROJECT_MENU_DISPATCH
)

echo %Cyan%===============================================================================%Reset%
echo %Yellow%[ Code / Visual ]%Reset%
echo   1  Draw Schematic              2  Browse HDL Hierarchy
echo   3  Draw FSM                    4  Generate Presentation
echo.
echo %Yellow%[ Simulation ]%Reset%
echo   5  Vivado Simulation           6  Auto Sim + Report
echo   7  Iverilog VCD                8  VCD to SVG
echo   9  VCD to WaveDrom            19  Create DUT TB Scaffold
echo  20  NO GUI Vivado Simulation
echo.
echo %Yellow%[ Reports ]%Reset%
echo  10  Report Generator           11  Docs Generator
echo  18  Open Latest Presentation HTML
echo.
echo %Yellow%[ Vivado / FPGA ]%Reset%
echo  12  Open Vivado GUI            13  Run RTL Build Flow
echo  14  Finalize Block Design      15  Retarget IP to Part
echo  16  Program FPGA Device        17  Auto Build + Program
echo  29  Open IP Integrator GUI     30  Build IP Integrator Bitstream
echo.
echo %Yellow%[ Health / Sync / Vitis ]%Reset%
echo  21  Toolkit Doctor             31  Sync This Project to T Drive
echo  22  Export XSA                 23  Create Vitis Platform
echo  24  Create Vitis App           25  Build Vitis Platform
echo  26  Build Vitis App            27  Run Vitis App
echo  28  Full Vitis Flow
echo %Cyan%===============================================================================%Reset%
echo [U] Upgrade This Project   [C] CUSTOMBAT   [B] Back to Project Selection   [H] Help   [Q] Quit
echo.

set "USER_INPUT="
set /p "USER_INPUT=Command > "

:PROJECT_MENU_DISPATCH
if /i "!USER_INPUT!"=="Q" goto :EXIT
if /i "!USER_INPUT!"=="C" goto :CUSTOMBAT_MENU
if /i "!USER_INPUT!"=="B" goto :MASTER_MENU
if /i "!USER_INPUT!"=="H" goto :DASH_HELP_PAGE
if /i "!USER_INPUT!"=="HELP" goto :DASH_HELP_PAGE
if /i "!USER_INPUT!"=="U" (
    call :RUN_PROJECT_UPGRADE "!TARGET_PROJECT_ABS!"
    goto :PROJECT_MENU
)
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

set "TARGET_BAT=%TEMPLATES_ROOT%\!TARGET_NAME!"

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

:RUN_PROJECT_UPGRADE
set "UPGRADE_TARGET="
if not "%~1"=="" for %%I in ("%~1") do set "UPGRADE_TARGET=%%~fI"
if not exist "!UPGRADE_BAT!" (
    echo.
    echo %Red%[ERROR] Upgrade script not found: !UPGRADE_BAT!%Reset%
    echo.
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)
call "%CONSOLE_HELPER%" clear
if defined UPGRADE_TARGET goto :RUN_PROJECT_UPGRADE_TARGET
echo %Green%[RUN] Upgrade Existing Project Structures%Reset%
echo %Cyan%===============================================================================%Reset%
set "FPGA_AUTO_PARENT_MENU=1"
cmd /c ""!UPGRADE_BAT!" --no-pause"
goto :RUN_PROJECT_UPGRADE_DONE

:RUN_PROJECT_UPGRADE_TARGET
echo %Green%[RUN] Upgrade Project Structure - Target: !UPGRADE_TARGET!%Reset%
echo %Cyan%===============================================================================%Reset%
set "FPGA_AUTO_PARENT_MENU=1"
cmd /c ""!UPGRADE_BAT!" --no-pause "!UPGRADE_TARGET!""

:RUN_PROJECT_UPGRADE_DONE
set "UPGRADE_RC=!errorlevel!"
set "FPGA_AUTO_PARENT_MENU="
echo %Cyan%===============================================================================%Reset%
if not "!UPGRADE_RC!"=="0" (
    echo %Red%[FAIL] Project upgrade exited with code !UPGRADE_RC!%Reset%
) else (
    echo %Green%[DONE] Project upgrade completed.%Reset%
)
echo.
call "%CONSOLE_HELPER%" pause_then_clear
exit /b !UPGRADE_RC!

:CUSTOMBAT_MENU
mode con: cols=120 lines=40 >nul 2>&1
call "%CONSOLE_HELPER%" clear
echo %Cyan%===============================================================================%Reset%
echo  %Green%FPGA Automation CUSTOMBAT Menu%Reset%
echo %Cyan%===============================================================================%Reset%
echo.

set "CUSTOMBAT_COUNT=1"
set "CUSTOMBAT_FILE_1=templates\contexts\timing_verification\adapters\bat\timing_run_riscv_verification.bat"
set "CUSTOMBAT_LABEL_1=RISC-V Timing Verification"

echo %Yellow%[ Custom BAT Entrypoints ]%Reset%
echo   1. !CUSTOMBAT_LABEL_1! [!CUSTOMBAT_FILE_1!]
echo.
echo %Blue%[B] Back%Reset%   %Red%[Q] Quit%Reset%
echo.

set "CUSTOMBAT_INPUT="
set /p "CUSTOMBAT_INPUT=%Cyan%Select custom BAT to run (or B/Q): %Reset%"

if /i "!CUSTOMBAT_INPUT!"=="Q" goto :EXIT
if /i "!CUSTOMBAT_INPUT!"=="B" goto :MASTER_MENU
if "!CUSTOMBAT_INPUT!"=="" goto :CUSTOMBAT_MENU

echo(!CUSTOMBAT_INPUT!| findstr /r "^[0-9][0-9]*$" >nul
if errorlevel 1 (
    echo.
    echo %Red%[ERROR] Invalid input: !CUSTOMBAT_INPUT!%Reset%
    timeout /t 1 >nul
    goto :CUSTOMBAT_MENU
)

if !CUSTOMBAT_INPUT! lss 1 goto :CUSTOMBAT_MENU
if !CUSTOMBAT_INPUT! gtr !CUSTOMBAT_COUNT! goto :CUSTOMBAT_MENU

call set "CUSTOMBAT_FILE=%%CUSTOMBAT_FILE_!CUSTOMBAT_INPUT!%%"
call set "CUSTOMBAT_LABEL=%%CUSTOMBAT_LABEL_!CUSTOMBAT_INPUT!%%"
set "CUSTOMBAT_PATH=%CD%\!CUSTOMBAT_FILE!"

if not exist "!CUSTOMBAT_PATH!" (
    echo.
    echo %Red%[ERROR] Custom BAT not found: !CUSTOMBAT_PATH!%Reset%
    call "%CONSOLE_HELPER%" pause_then_clear
    goto :CUSTOMBAT_MENU
)

call "%CONSOLE_HELPER%" clear
echo %Green%[RUN] !CUSTOMBAT_LABEL! [!CUSTOMBAT_FILE!]%Reset%
echo %Cyan%===============================================================================%Reset%
set "FPGA_AUTO_PARENT_MENU=1"
cmd /c ""!CUSTOMBAT_PATH!""
set "CHILD_RC=!errorlevel!"
set "FPGA_AUTO_PARENT_MENU="
echo %Cyan%===============================================================================%Reset%
if "!CHILD_RC!"=="%USER_CANCEL_RC%" goto :CUSTOMBAT_MENU
if not "!CHILD_RC!"=="0" (
    echo %Red%[FAIL] !CUSTOMBAT_LABEL! exited with code !CHILD_RC!%Reset%
    echo.
    call "%CONSOLE_HELPER%" pause_then_clear
    goto :CUSTOMBAT_MENU
)
echo %Green%[DONE] !CUSTOMBAT_LABEL!%Reset%
echo.
call "%CONSOLE_HELPER%" pause_then_clear
goto :CUSTOMBAT_MENU

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
set "TMP_REL=!TARGET_PROJECT_ABS:%PROJECT_ROOT%\=!"
if not "!TMP_REL!"=="!TARGET_PROJECT_ABS!" (
    if "!TMP_REL:~0,1!"=="\" set "TMP_REL=!TMP_REL:~1!"
    set "TARGET_PROJECT=..\Project"
    if not "!TMP_REL!"=="" set "TARGET_PROJECT=..\Project\!TMP_REL!"
)
exit /b 0

:EXIT
echo.
echo %Gray%MAIN.bat closed.%Reset%
endlocal
exit /b 0
