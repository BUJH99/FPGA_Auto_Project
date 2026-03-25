@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "QUIET=0"

:parse_args
if "%~1"=="" goto start
if /i "%~1"=="--quiet" set "QUIET=1"
shift
goto parse_args

:start
set "FOUND_BIN="
set "FOUND_SOURCE="
set "NORMALIZED_CANDIDATE="
set "UPDATED_PATH=%PATH%"

call :resolve_from_path
if not defined FOUND_BIN call :try_candidate "%FPGA_AUTO_VIVADO_BIN%" "ENV:FPGA_AUTO_VIVADO_BIN"
if not defined FOUND_BIN call :try_candidate "%VIVADO_BIN%" "ENV:VIVADO_BIN"
if not defined FOUND_BIN call :try_candidate "%XILINX_VIVADO%" "ENV:XILINX_VIVADO"
if not defined FOUND_BIN call :scan_vendor_root "C:\AMDDesignTools" "SCAN:C:\AMDDesignTools"
if not defined FOUND_BIN call :scan_vendor_root "C:\Xilinx\Vivado" "SCAN:C:\Xilinx\Vivado"
if not defined FOUND_BIN call :scan_vendor_root "C:\Program Files\Xilinx\Vivado" "SCAN:C:\Program Files\Xilinx\Vivado"

if not defined FOUND_BIN (
    endlocal & set "FPGA_AUTO_VIVADO_BIN=" & set "FPGA_AUTO_VIVADO_SOURCE=" & exit /b 1
)

echo(;!PATH!; | findstr /I /C:";!FOUND_BIN!;" >nul 2>nul
if errorlevel 1 set "UPDATED_PATH=!FOUND_BIN!;!PATH!"

if "!QUIET!"=="0" if /i not "!FOUND_SOURCE!"=="PATH" echo [INFO] Resolved Vivado bin: !FOUND_BIN!

endlocal & set "FPGA_AUTO_VIVADO_BIN=%FOUND_BIN%" & set "FPGA_AUTO_VIVADO_SOURCE=%FOUND_SOURCE%" & set "PATH=%UPDATED_PATH%" & exit /b 0

:resolve_from_path
for /f "delims=" %%P in ('where vivado 2^>nul') do (
    for %%I in ("%%~fP") do set "FOUND_BIN=%%~dpI"
    if defined FOUND_BIN (
        if "!FOUND_BIN:~-1!"=="\" set "FOUND_BIN=!FOUND_BIN:~0,-1!"
        set "FOUND_SOURCE=PATH"
        exit /b 0
    )
)
exit /b 1

:scan_vendor_root
set "SCAN_ROOT=%~1"
set "SCAN_SOURCE=%~2"
if not defined SCAN_ROOT exit /b 1
if not exist "%SCAN_ROOT%" exit /b 1

call :try_candidate "%SCAN_ROOT%" "%SCAN_SOURCE%"
if defined FOUND_BIN exit /b 0

for /f "delims=" %%D in ('dir /b /ad /o-n "%SCAN_ROOT%\*" 2^>nul') do (
    call :try_candidate "%SCAN_ROOT%\%%D" "%SCAN_SOURCE%"
    if defined FOUND_BIN exit /b 0
)
exit /b 1

:try_candidate
set "TRY_SOURCE=%~2"
call :normalize_candidate "%~1"
if errorlevel 1 exit /b 1
set "FOUND_BIN=%NORMALIZED_CANDIDATE%"
set "FOUND_SOURCE=%TRY_SOURCE%"
exit /b 0

:normalize_candidate
set "NORMALIZED_CANDIDATE="
set "CANDIDATE=%~1"
if not defined CANDIDATE exit /b 1
if "!CANDIDATE:~-1!"=="\" set "CANDIDATE=!CANDIDATE:~0,-1!"

if /i "%~nx1"=="vivado.bat" if exist "%~1" (
    for %%I in ("%~1") do set "NORMALIZED_CANDIDATE=%%~dpI"
    if defined NORMALIZED_CANDIDATE if "!NORMALIZED_CANDIDATE:~-1!"=="\" set "NORMALIZED_CANDIDATE=!NORMALIZED_CANDIDATE:~0,-1!"
    exit /b 0
)

if exist "!CANDIDATE!\vivado.bat" (
    set "NORMALIZED_CANDIDATE=!CANDIDATE!"
    exit /b 0
)
if exist "!CANDIDATE!\bin\vivado.bat" (
    set "NORMALIZED_CANDIDATE=!CANDIDATE!\bin"
    exit /b 0
)
if exist "!CANDIDATE!\Vivado\bin\vivado.bat" (
    set "NORMALIZED_CANDIDATE=!CANDIDATE!\Vivado\bin"
    exit /b 0
)
exit /b 1
