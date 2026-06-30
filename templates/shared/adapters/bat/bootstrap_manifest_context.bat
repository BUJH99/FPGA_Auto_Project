@echo off

if "%~1"=="" (
    echo [ERROR][manifest_usage] _manifest_context: missing target project path.
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
set "SCRIPT_DIR=%~dp0"
set "MANIFEST_TOOL=%SCRIPT_DIR%..\..\..\contexts\manifest\adapters\cli\manifest_resolve_cli.js"
set "MANIFEST_FILE=%TARGET_PROJECT%\fpga_auto.yml"
set "MANIFEST_JSON="
set "MANIFEST_SRC_LIST="
set "MANIFEST_TB_LIST="
set "MANIFEST_INC_LIST="
set "MANIFEST_XDC_LIST="
set "MANIFEST_MODE=1"

if not exist "%TARGET_PROJECT%" (
    echo [ERROR][project_not_found] _manifest_context: project not found: %TARGET_PROJECT%
    exit /b 1
)

where node >nul 2>nul
if errorlevel 1 (
    echo [ERROR][node_missing] _manifest_context: Node.js is required.
    exit /b 1
)

if not exist "%MANIFEST_TOOL%" (
    echo [ERROR][manifest_tool_missing] _manifest_context: manifest tool not found: %MANIFEST_TOOL%
    exit /b 1
)

set "MANIFEST_OUTPUT_ROOT=%FPGA_CLAW_OUTPUT_DIR%"
if not defined MANIFEST_OUTPUT_ROOT set "MANIFEST_OUTPUT_ROOT=output"
if "%MANIFEST_OUTPUT_ROOT:~1,1%"==":" (
    set "MANIFEST_OUT_DIR=%MANIFEST_OUTPUT_ROOT%\manifest"
) else if "%MANIFEST_OUTPUT_ROOT:~0,1%"=="\" (
    set "MANIFEST_OUT_DIR=%MANIFEST_OUTPUT_ROOT%\manifest"
) else (
    set "MANIFEST_OUT_DIR=%TARGET_PROJECT%\%MANIFEST_OUTPUT_ROOT%\manifest"
)
if not exist "%MANIFEST_OUT_DIR%" mkdir "%MANIFEST_OUT_DIR%" >nul 2>nul

set "MANIFEST_JSON=%MANIFEST_OUT_DIR%\manifest_resolved.json"
set "MANIFEST_SRC_LIST=%MANIFEST_OUT_DIR%\manifest_src_files.lst"
set "MANIFEST_TB_LIST=%MANIFEST_OUT_DIR%\manifest_tb_files.lst"
set "MANIFEST_INC_LIST=%MANIFEST_OUT_DIR%\manifest_inc_dirs.lst"
set "MANIFEST_XDC_LIST=%MANIFEST_OUT_DIR%\manifest_xdc_files.lst"

call node "%MANIFEST_TOOL%" --project "%TARGET_PROJECT%" --write "%MANIFEST_JSON%" --emit-lists "%MANIFEST_OUT_DIR%"
if errorlevel 1 (
    echo [ERROR][manifest_resolution_failed] _manifest_context: manifest resolution failed. Ensure %MANIFEST_FILE% exists and is valid.
    exit /b 1
)

call :require_file "%MANIFEST_JSON%" "manifest_json_missing"
if errorlevel 1 exit /b 1
call :require_file "%MANIFEST_SRC_LIST%" "manifest_src_list_missing"
if errorlevel 1 exit /b 1
call :require_file "%MANIFEST_TB_LIST%" "manifest_tb_list_missing"
if errorlevel 1 exit /b 1
call :require_file "%MANIFEST_INC_LIST%" "manifest_inc_list_missing"
if errorlevel 1 exit /b 1
call :require_file "%MANIFEST_XDC_LIST%" "manifest_xdc_list_missing"
if errorlevel 1 exit /b 1

exit /b 0

:require_file
set "REQ_FILE=%~1"
set "REQ_CODE=%~2"
if exist "%REQ_FILE%" exit /b 0
echo [ERROR][%REQ_CODE%] _manifest_context: expected file not found: %REQ_FILE%
exit /b 1
