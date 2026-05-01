@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "QUIET=0"
if /i "%~1"=="--quiet" set "QUIET=1"
if not defined SystemDrive set "SystemDrive=C:"

set "FOUND_BIN="

call :try_candidate "%VITIS_BIN%"
if not errorlevel 1 goto success

call :probe_amd_vitis "%SystemDrive%\AMDDesignTools"
if not errorlevel 1 goto success

call :probe_xilinx_vitis "%SystemDrive%\Xilinx\Vitis"
if not errorlevel 1 goto success

call :capture_existing_vitis
if not errorlevel 1 goto success

endlocal & exit /b 1

:success
endlocal & set "PATH=%PATH%" & set "RESOLVED_VITIS_BIN=%FOUND_BIN%" & chcp 65001 >nul 2>nul & exit /b 0

:capture_existing_vitis
where vitis >nul 2>nul
if errorlevel 1 exit /b 1
for /f "delims=" %%P in ('where vitis 2^>nul') do (
    if not defined FOUND_BIN (
        for %%D in ("%%~dpP.") do set "FOUND_BIN=%%~fD"
    )
)
if defined FOUND_BIN exit /b 0
exit /b 1

:try_candidate
set "CAND=%~1"
if not defined CAND exit /b 1
if "%CAND:~-1%"=="\" set "CAND=%CAND:~0,-1%"
if not exist "%CAND%\vitis.bat" if not exist "%CAND%\vitis.exe" exit /b 1
call :prepend_path "%CAND%"
where vitis >nul 2>nul
if errorlevel 1 exit /b 1
set "FOUND_BIN=%CAND%"
if "%QUIET%"=="0" echo [INFO] Added Vitis bin to PATH: %CAND%
exit /b 0

:probe_amd_vitis
set "ROOT=%~1"
if not exist "%ROOT%" exit /b 1
for /f "delims=" %%V in ('dir /b /ad /o-n "%ROOT%" 2^>nul') do (
    if exist "%ROOT%\%%V\Vitis\bin\vitis.bat" (
        call :try_candidate "%ROOT%\%%V\Vitis\bin"
        if not errorlevel 1 exit /b 0
    )
)
exit /b 1

:probe_xilinx_vitis
set "ROOT=%~1"
if not exist "%ROOT%" exit /b 1
for /f "delims=" %%V in ('dir /b /ad /o-n "%ROOT%" 2^>nul') do (
    if exist "%ROOT%\%%V\bin\vitis.bat" (
        call :try_candidate "%ROOT%\%%V\bin"
        if not errorlevel 1 exit /b 0
    )
)
exit /b 1

:prepend_path
set "DIR_CAND=%~1"
if not defined DIR_CAND exit /b 1
if not exist "%DIR_CAND%" exit /b 1
echo ;!PATH!; | findstr /I /C:";%DIR_CAND%;" >nul 2>nul
if errorlevel 1 set "PATH=%DIR_CAND%;!PATH!"
exit /b 0
