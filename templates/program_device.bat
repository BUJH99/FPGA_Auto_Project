@echo off
setlocal

echo ===========================================
echo   Vivado Batch Mode - Program Device
echo ===========================================

:: Vivado 실행 경로 확인
where vivado >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] Vivado executable not found in PATH.
    pause
    exit /b 1
)

:: Hardware Manager 스크립트 실행
:: -mode batch: GUI 없음
:: -notrace: 잡다한 로그 숨김 (깔끔하게 보기 위함)
vivado -mode batch -source ./scripts/program_fpga.tcl -notrace -log ./output/vivado_program.log -nojournal

if %errorlevel% neq 0 (
    echo.
    echo [!] Programming Failed! Check connection or logs.
    pause
    exit /b %errorlevel%
)

echo.
echo [Done] You can close this window.
pause