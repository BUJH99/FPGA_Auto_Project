@echo off
if "%~1"=="" (
    set "FPGA_AUTO_ROOT_INPUT=%CD%"
) else (
    set "FPGA_AUTO_ROOT_INPUT=%~1"
)

for %%I in ("%FPGA_AUTO_ROOT_INPUT%") do set "FPGA_AUTO_REPO_ROOT=%%~fI"
for %%I in ("%FPGA_AUTO_REPO_ROOT%\..") do set "FPGA_AUTO_PARENT_ROOT=%%~fI"
set "FPGA_AUTO_PROJECT_ROOT=%FPGA_AUTO_PARENT_ROOT%\Project"
exit /b 0
