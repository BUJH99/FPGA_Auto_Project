@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "CMD=%~1"
if not defined CMD exit /b 1

if /i "%CMD%"=="clear" goto clear
if /i "%CMD%"=="banner" goto banner
if /i "%CMD%"=="header" goto header
if /i "%CMD%"=="pause_then_clear" goto pause_then_clear

echo [ERROR] Unknown console_ui command: %CMD%
exit /b 1

:clear
cls
exit /b 0

:banner
cls
goto header_body

:header
goto header_body

:header_body
set "LINE==============================================================================="
echo !LINE!
if not "%~2"=="" echo  %~2
if not "%~3"=="" echo  %~3
if not "%~4"=="" echo  %~4
echo !LINE!
exit /b 0

:pause_then_clear
if /i "%FPGA_AUTO_PARENT_MENU%"=="1" exit /b 0
if /i "%FPGA_AUTO_NO_PAUSE%"=="1" exit /b 0
if /i "%NO_PAUSE%"=="1" exit /b 0
if not "%~2"=="" echo %~2
pause
cls
exit /b 0
