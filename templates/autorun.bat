@echo off
setlocal enabledelayedexpansion
title Vivado Automation Flow

:: =================================================================
:: Vivado 원클릭 자동화 배치 파일 (With Auto-Reporting)
:: =================================================================

cls
echo.
echo ===============================================================================
echo  [START] Vivado Automation Flow
echo ===============================================================================
echo.

:: 1. Vivado 실행 파일 확인
echo [CHECK] Verifying Vivado Environment...
where vivado >nul 2>nul
if %errorlevel% neq 0 (
    echo.
    echo [ERROR] Vivado executable not found in PATH.
    echo         Please add Vivado bin directory to your System PATH.
    echo.
    pause
    exit /b 1
)
echo      - Vivado found.

:: 2. 출력 디렉토리 정리
if exist output (
    echo [CLEAN] Cleaning up previous output directory...
    rmdir /s /q output
)
mkdir output
echo      - Output directory ready.

:: 3. Vivado Batch Mode 실행 (Synthesis & Implementation)
echo.
echo ===============================================================================
echo  [EXEC] Running Vivado Batch Mode... 
echo         (Please wait. Check log for details.)
echo ===============================================================================
echo.

:: Build Script 실행
call vivado -mode batch -source ./scripts/run_full_flow.tcl -log ./output/vivado_full_build.log -nojournal -notrace

:: 4. 종료 상태 확인
if %errorlevel% neq 0 (
    echo.
    echo ###############################################################################
    echo #                                                                             #
    echo #                          [FAIL] BUILD FAILED                                #
    echo #                                                                             #
    echo ###############################################################################
    echo.
    echo [ERROR] Please check the log file: output/vivado_full_build.log
    echo.
    pause
    exit /b %errorlevel%
)

:: 5. RTL 계층 구조 추출 (Schematic Level)
echo.
echo ===============================================================================
echo  [INFO] Extracting Schematic Hierarchy (RTL Analysis)...
echo ===============================================================================
echo.

:: 합성 전 순수 RTL 계층 구조를 뽑아냅니다.
call vivado -mode batch -source ./scripts/export_rtl_hierarchy.tcl -notrace -nojournal -log ./output/rtl_hier.log

:: 6. 보고서 자동 생성
echo.
echo ===============================================================================
echo  [REPORT] Generating Final Build Report...
echo ===============================================================================
echo.

call vivado -mode batch -source ./scripts/generate_report.tcl -notrace -nojournal -log ./output/report_gen.log

if exist output\Final_Build_Report.html (
    echo      - Report generated: output\Final_Build_Report.html
) else (
    echo      - [WARNING] Failed to generate report.
)

:: 7. 성공 메시지
echo.
echo ###############################################################################
echo #                                                                             #
echo #               Bitstream generation completed                                #
echo #                                                                             #
echo ###############################################################################
echo.
echo [INFO] Bitstream location: %CD%\output
echo [INFO] Build Report      : %CD%\output\Final_Build_Report.html
echo.

:: 8. 디바이스 프로그래밍 선택 (자동 종료 방지)
echo ===============================================================================
echo  [ACTION REQUIRED]
echo ===============================================================================

:ASK_PROGRAM
echo.
set /p user_input="Do you want to run 'program_device.bat' to program FPGA? (Y/N): "

if /i "%user_input%"=="Y" goto RUN_PROGRAM
if /i "%user_input%"=="N" goto FINISH
:: 잘못된 입력 시 다시 질문
goto ASK_PROGRAM

:RUN_PROGRAM
echo.
if exist program_device.bat (
    echo [EXEC] Launching program_device.bat...
    echo.
    call program_device.bat
) else (
    echo [ERROR] 'program_device.bat' not found in the current directory.
)

:FINISH
echo.
echo ===============================================================================
echo  All tasks completed. Press any key to close this window...
echo ===============================================================================
pause >nul
