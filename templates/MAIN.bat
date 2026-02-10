@echo off
setlocal EnableDelayedExpansion
cd /d "%~dp0"
title FPGA Automation - MAIN

:MENU
cls
echo.
echo ===============================================================================
echo  FPGA Automation MAIN Menu
echo ===============================================================================
echo.

if not exist ".\bat" (
    echo [ERROR] bat folder not found: "%CD%\bat"
    echo.
    echo Press any key to exit...
    pause >nul
    goto :EXIT
)

set "COUNT=0"
for /f "delims=" %%F in ('dir /b /a-d ".\bat\*.bat" 2^>nul') do (
    if /i not "%%~nxF"=="sync_codex_tb_skill.bat" (
        set /a COUNT+=1
        set "BAT_!COUNT!=%%F"
    )
)

if !COUNT! equ 0 (
    echo [ERROR] No batch files found in ".\bat"
    echo.
    echo Press any key to exit...
    pause >nul
    goto :EXIT
)

echo Available scripts:
for /l %%I in (1,1,!COUNT!) do (
    echo   [%%I] !BAT_%%I!
)
echo.
echo   [Q] Quit
echo.

set "USER_INPUT="
set /p "USER_INPUT=Select number to run (or Q): "

if /i "!USER_INPUT!"=="Q" goto :EXIT
if "!USER_INPUT!"=="" goto :MENU

echo(!USER_INPUT!| findstr /r "^[0-9][0-9]*$" >nul
if errorlevel 1 (
    echo.
    echo [ERROR] Invalid input: !USER_INPUT!
    timeout /t 1 >nul
    goto :MENU
)

if !USER_INPUT! lss 1 (
    echo.
    echo [ERROR] Selection out of range.
    timeout /t 1 >nul
    goto :MENU
)
if !USER_INPUT! gtr !COUNT! (
    echo.
    echo [ERROR] Selection out of range.
    timeout /t 1 >nul
    goto :MENU
)

set "TARGET_NAME=!BAT_%USER_INPUT%!"
set "TARGET_BAT=%CD%\bat\!TARGET_NAME!"

echo.
echo [RUN] !TARGET_NAME!
echo ===============================================================================
cmd /c ""!TARGET_BAT!""
set "RET_CODE=!errorlevel!"
echo ===============================================================================
echo [DONE] !TARGET_NAME! ^(exit code: !RET_CODE!^)
echo.
pause
goto :MENU

:EXIT
echo.
echo MAIN.bat closed.
endlocal
exit /b 0
