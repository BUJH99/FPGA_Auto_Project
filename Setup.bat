@echo off
setlocal

:PROMPT
set /p ProjectName="Enter project name: "

if "%ProjectName%"=="" goto PROMPT

if exist "%ProjectName%" (
    echo [ERROR] "%ProjectName%" already exists. Please use a different name.
    goto PROMPT
)

mkdir "%ProjectName%"

echo [INFO] Creating standardized project directories...
if not exist "%ProjectName%\constrs" mkdir "%ProjectName%\constrs"
if not exist "%ProjectName%\Diagram" mkdir "%ProjectName%\Diagram"
if not exist "%ProjectName%\ip" mkdir "%ProjectName%\ip"
if not exist "%ProjectName%\md" mkdir "%ProjectName%\md"
if not exist "%ProjectName%\output" mkdir "%ProjectName%\output"
if not exist "%ProjectName%\report_assets" mkdir "%ProjectName%\report_assets"
if not exist "%ProjectName%\src" mkdir "%ProjectName%\src"
if not exist "%ProjectName%\skills" mkdir "%ProjectName%\skills"
if not exist "%ProjectName%\tb" mkdir "%ProjectName%\tb"

echo.
echo ------------------------------------------------
echo [%ProjectName%] project created successfully.
echo Created folders:
echo - constrs
echo - Diagram
echo - ip
echo - md
echo - output
echo - report_assets
echo - src
echo - skills
echo - tb
echo ------------------------------------------------

pause
endlocal
