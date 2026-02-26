@echo off
setlocal
set "SYNC_BAT=%~dp0..\..\SyncProjectsToSourceProject.bat"
set "PRESENTATION_TEMPLATE_DIR=%~dp0..\Presentation"
set "NO_PAUSE=0"
set "SETUP_RC=0"
set "ProjectName=%~1"
set "HDL_EXT=v"

if /i "%~2"=="--no-pause" set "NO_PAUSE=1"
if /i "%~3"=="--no-pause" set "NO_PAUSE=1"
if /i "%~4"=="--no-pause" set "NO_PAUSE=1"
if /i "%~5"=="--no-pause" set "NO_PAUSE=1"
if /i "%~1"=="--no-pause" (
    set "ProjectName="
    set "NO_PAUSE=1"
)
set "ARG2=%~2"
set "ARG3=%~3"
set "ARG4=%~4"
if /i "%~2"=="--hdl-ext" (
    if /i "%~3"=="sv" set "HDL_EXT=sv"
    if /i "%~3"=="v" set "HDL_EXT=v"
) else if /i "%ARG2:~0,10%"=="--hdl-ext=" (
    set "HDL_EXT=%ARG2:~10%"
)
if /i "%~3"=="--hdl-ext" (
    if /i "%~4"=="sv" set "HDL_EXT=sv"
    if /i "%~4"=="v" set "HDL_EXT=v"
) else if /i "%ARG3:~0,10%"=="--hdl-ext=" (
    set "HDL_EXT=%ARG3:~10%"
)
if /i "%~4"=="--hdl-ext" (
    if /i "%~5"=="sv" set "HDL_EXT=sv"
    if /i "%~5"=="v" set "HDL_EXT=v"
) else if /i "%ARG4:~0,10%"=="--hdl-ext=" (
    set "HDL_EXT=%ARG4:~10%"
)
if /i not "%HDL_EXT%"=="v" if /i not "%HDL_EXT%"=="sv" set "HDL_EXT=v"

if "%ProjectName%"=="" goto PROMPT
goto CREATE

:PROMPT
set /p ProjectName="Enter project name: "
if "%ProjectName%"=="" goto PROMPT

:CREATE
if exist "%ProjectName%" (
    echo [ERROR] "%ProjectName%" already exists. Please use a different name.
    if not "%~1"=="" (
        set "SETUP_RC=1"
        goto END
    )
    goto PROMPT
)

mkdir "%ProjectName%"

echo [INFO] Creating standardized project directories...
if not exist "%ProjectName%\constrs" mkdir "%ProjectName%\constrs"
if not exist "%ProjectName%\ip" mkdir "%ProjectName%\ip"
if not exist "%ProjectName%\md" mkdir "%ProjectName%\md"
if not exist "%ProjectName%\output" mkdir "%ProjectName%\output"
if not exist "%ProjectName%\output\docs" mkdir "%ProjectName%\output\docs"
if not exist "%ProjectName%\output\Diagram" mkdir "%ProjectName%\output\Diagram"
if not exist "%ProjectName%\output\Diagram\Simple" mkdir "%ProjectName%\output\Diagram\Simple"
if not exist "%ProjectName%\output\Diagram\Detailed" mkdir "%ProjectName%\output\Diagram\Detailed"
if not exist "%ProjectName%\output\Diagram\JSON" mkdir "%ProjectName%\output\Diagram\JSON"
if not exist "%ProjectName%\output\FINALReport" mkdir "%ProjectName%\output\FINALReport"
if not exist "%ProjectName%\output\fsm" mkdir "%ProjectName%\output\fsm"
if not exist "%ProjectName%\output\fsm\svg" mkdir "%ProjectName%\output\fsm\svg"
if not exist "%ProjectName%\output\fsm\drawio" mkdir "%ProjectName%\output\fsm\drawio"
if not exist "%ProjectName%\log" mkdir "%ProjectName%\log"
if not exist "%ProjectName%\report_assets" mkdir "%ProjectName%\report_assets"
if not exist "%ProjectName%\src" mkdir "%ProjectName%\src"
if not exist "%ProjectName%\skills" mkdir "%ProjectName%\skills"
if not exist "%ProjectName%\tb" mkdir "%ProjectName%\tb"
if exist "%PRESENTATION_TEMPLATE_DIR%\" (
    xcopy "%PRESENTATION_TEMPLATE_DIR%" "%ProjectName%\Presentation\" /E /I /Y >nul
)

echo.
echo ------------------------------------------------
echo [%ProjectName%] project created successfully.
echo Created folders:
echo - constrs
echo - ip
echo - md
echo - output
echo - output\docs
echo - output\Diagram\Simple
echo - output\Diagram\Detailed
echo - output\Diagram\JSON
echo - output\FINALReport
echo - output\fsm\svg
echo - output\fsm\drawio
echo - log
echo - report_assets
echo - src
echo - skills
echo - tb
if exist "%PRESENTATION_TEMPLATE_DIR%\" (
    echo - Presentation
)
echo ------------------------------------------------
echo.

if exist "%SYNC_BAT%" (
    echo [INFO] Running auto sync to SOURCE_PROJECT...
    call "%SYNC_BAT%"
    if errorlevel 1 (
        echo [WARN] Auto sync reported errors. Please check output above.
    )
)

:END
if "%NO_PAUSE%"=="1" (
    endlocal
    exit /b %SETUP_RC%
)
pause
endlocal
exit /b %SETUP_RC%
