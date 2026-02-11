@echo off
setlocal EnableDelayedExpansion

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^>
    pause
    exit /b 1
)

set "TARGET_PROJECT=%~f1"

echo ============================================================================
echo      Verilog Documentation Generator (Centralized)
echo ============================================================================
echo Target: %TARGET_PROJECT%
echo.

if not exist "%~dp0..\tools\generate_doc.js" (
    echo [Error] Tool script not found in templates\tools.
    pause
    exit /b 1
)

:: Run Documentation Tool with target project path
node "%~dp0..\tools\generate_doc.js" "%TARGET_PROJECT%"

if errorlevel 1 (
    echo [FAILURE] Documentation generation failed.
    pause
    exit /b 1
)

echo.
echo [SUCCESS] Documentation generated for %TARGET_PROJECT%
pause
