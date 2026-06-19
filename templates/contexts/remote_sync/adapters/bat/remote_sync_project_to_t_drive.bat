@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
set "CONSOLE_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\console_ui.bat"

set "TARGET_PROJECT="
set "REMOTE_PROJECT_ROOT="
set "DRY_RUN=0"
set "ROBOCOPY_THREADS=16"
if defined FPGA_AUTO_REMOTE_SYNC_THREADS set "ROBOCOPY_THREADS=%FPGA_AUTO_REMOTE_SYNC_THREADS%"
echo(%ROBOCOPY_THREADS%| findstr /r "^[1-9][0-9]*$" >nul
if errorlevel 1 set "ROBOCOPY_THREADS=16"
if %ROBOCOPY_THREADS% gtr 128 set "ROBOCOPY_THREADS=128"
set "ROBOCOPY_FLAGS=/MIR /MT:%ROBOCOPY_THREADS% /R:1 /W:1 /XJ /COPY:DAT /DCOPY:DAT /NP"
set "FAILED_COUNT=0"
set "SYNCED_COUNT=0"
set "SKIPPED_COUNT=0"
set "MAX_ROBOCOPY_RC=0"

:PARSE_ARGS
if "%~1"=="" goto PARSE_DONE
if /i "%~1"=="--dry-run" goto PARSE_DRY_RUN
if /i "%~1"=="--dest" goto PARSE_DEST
if not defined TARGET_PROJECT (
    set "TARGET_PROJECT=%~f1"
) else if not defined REMOTE_PROJECT_ROOT (
    set "REMOTE_PROJECT_ROOT=%~f1"
) else (
    echo [WARN] Ignoring extra argument: %~1
)
shift
goto PARSE_ARGS

:PARSE_DRY_RUN
set "DRY_RUN=1"
shift
goto PARSE_ARGS

:PARSE_DEST
shift
if "%~1"=="" (
    call :FAIL "--dest requires a destination project root." 2
    exit /b !ERRORLEVEL!
)
set "REMOTE_PROJECT_ROOT=%~1"
shift
goto PARSE_ARGS

:PARSE_DONE
if not defined TARGET_PROJECT (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^> [Destination_Project_Root]
    echo        %~nx0 ^<Project_Directory^> --dest T:\Project
    call :MAYBE_PAUSE
    exit /b 1
)

if not exist "%TARGET_PROJECT%\" (
    call :FAIL "Project directory not found: %TARGET_PROJECT%" 1
    exit /b !ERRORLEVEL!
)
if not exist "%TARGET_PROJECT%\src\" (
    call :FAIL "Invalid managed project. Missing src\: %TARGET_PROJECT%" 1
    exit /b !ERRORLEVEL!
)
if not exist "%TARGET_PROJECT%\fpga_auto.yml" (
    call :FAIL "Invalid managed project. Missing fpga_auto.yml: %TARGET_PROJECT%" 1
    exit /b !ERRORLEVEL!
)

for %%I in ("%TARGET_PROJECT%") do (
    set "TARGET_PROJECT=%%~fI"
    set "PROJECT_NAME=%%~nxI"
)

if not defined REMOTE_PROJECT_ROOT (
    if defined FPGA_AUTO_REMOTE_PROJECT_ROOT (
        set "REMOTE_PROJECT_ROOT=%FPGA_AUTO_REMOTE_PROJECT_ROOT%"
    ) else (
        set "REMOTE_PROJECT_ROOT=T:\Project"
    )
)

for %%I in ("%REMOTE_PROJECT_ROOT%") do set "REMOTE_PROJECT_ROOT=%%~fI"
set "DEST_PROJECT=%REMOTE_PROJECT_ROOT%\%PROJECT_NAME%"
for %%I in ("%DEST_PROJECT%") do set "DEST_PROJECT=%%~fI"

if /i "%DEST_PROJECT%"=="%TARGET_PROJECT%" (
    call :FAIL "Destination resolves to the same directory as source." 1
    exit /b !ERRORLEVEL!
)

echo [INFO] Source project : %TARGET_PROJECT%
echo [INFO] Destination    : %DEST_PROJECT%
echo [INFO] Sync scope     : src, tb
echo [INFO] Copy threads   : %ROBOCOPY_THREADS%
echo [INFO] Sync mode      : robocopy %ROBOCOPY_FLAGS%
if "%DRY_RUN%"=="1" echo [INFO] Dry run enabled. No files will be copied.
echo.

if not exist "%REMOTE_PROJECT_ROOT%\" (
    if "%DRY_RUN%"=="1" goto SKIP_CREATE_DEST_ROOT
    echo [INFO] Creating destination root: %REMOTE_PROJECT_ROOT%
    mkdir "%REMOTE_PROJECT_ROOT%" >nul 2>nul
    if errorlevel 1 (
        call :FAIL "Failed to create destination root: %REMOTE_PROJECT_ROOT%" 1
        exit /b !ERRORLEVEL!
    )
)

:SKIP_CREATE_DEST_ROOT
call :SYNC_PROJECT_DIR "src"
call :SYNC_PROJECT_DIR "tb"

:SYNC_DONE
if !FAILED_COUNT! gtr 0 (
    echo.
    echo [ERROR] Remote project sync failed. failed=!FAILED_COUNT! max_rc=!MAX_ROBOCOPY_RC!
    call :MAYBE_PAUSE
    exit /b !MAX_ROBOCOPY_RC!
)

echo.
echo [DONE] Remote project sync completed. synced=!SYNCED_COUNT! skipped=!SKIPPED_COUNT! max_rc=!MAX_ROBOCOPY_RC!
call :MAYBE_PAUSE
exit /b 0

:SYNC_PROJECT_DIR
set "SYNC_NAME=%~1"
set "SYNC_SRC=%TARGET_PROJECT%\%SYNC_NAME%"
set "SYNC_DEST=%DEST_PROJECT%\%SYNC_NAME%"

if not exist "%SYNC_SRC%\" (
    set /a SKIPPED_COUNT+=1
    echo [WARN] Skipping missing source folder: %SYNC_SRC%
    exit /b 0
)

echo [SYNC] %SYNC_NAME%  -^>  %SYNC_DEST%
if "%DRY_RUN%"=="1" (
    robocopy "%SYNC_SRC%" "%SYNC_DEST%" %ROBOCOPY_FLAGS% /L
) else (
    robocopy "%SYNC_SRC%" "%SYNC_DEST%" %ROBOCOPY_FLAGS%
)
set "ROBOCOPY_RC=!ERRORLEVEL!"
if !ROBOCOPY_RC! gtr !MAX_ROBOCOPY_RC! set "MAX_ROBOCOPY_RC=!ROBOCOPY_RC!"
if !ROBOCOPY_RC! geq 8 (
    set /a FAILED_COUNT+=1
    echo [ERROR] Failed to sync %SYNC_NAME%. robocopy rc=!ROBOCOPY_RC!
) else (
    set /a SYNCED_COUNT+=1
)
exit /b 0

:FAIL
echo [ERROR] %~1
call :MAYBE_PAUSE
exit /b %~2

:MAYBE_PAUSE
if exist "%CONSOLE_HELPER%" call "%CONSOLE_HELPER%" pause_then_clear
exit /b 0
