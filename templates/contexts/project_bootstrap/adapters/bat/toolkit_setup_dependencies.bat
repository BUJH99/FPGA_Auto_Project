@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
for %%I in ("%TEMPLATES_ROOT%\..") do set "REPO_ROOT=%%~fI"
set "CONSOLE_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\console_ui.bat"

set "AUTO_YES=0"
set "NO_PAUSE=0"
set "CHECK_ONLY=0"
set "NO_PATH_SETX=0"
set "INSTALL_SCOPE=user"
set "VIVADO_BIN="

set "EXIT_CODE=0"
set "MISSING_COUNT=0"
set "INSTALL_FAILED=0"
set "EXEC_TOOL_FAILURE=0"
set "PATH_SETX_FAILED=0"
set "NEED_WINGET=0"
set "PY_LAUNCHER="

for /f %%I in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "TS=%%I"
if not defined TS set "TS=00000000_000000"

set "LOG_DIR=%TEMPLATES_ROOT%\output\setup"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" >nul 2>nul
set "LOG_FILE=%LOG_DIR%\toolkit_setup_%TS%.log"
set "MISSING_FILE=%TEMP%\fpga_toolkit_missing_%TS%.txt"
set "PATH_CANDIDATES_FILE=%TEMP%\fpga_toolkit_path_candidates_%TS%.txt"

break > "%LOG_FILE%"
break > "%MISSING_FILE%"
break > "%PATH_CANDIDATES_FILE%"

call :parse_args %*
if not "%EXIT_CODE%"=="0" goto finish

if "%CHECK_ONLY%"=="1" set "NO_PATH_SETX=1"

call :log "==============================================================================="
call :log "[START] Toolkit dependency setup"
call :log "[INFO] Repo root: %REPO_ROOT%"
call :log "[INFO] Templates root: %TEMPLATES_ROOT%"
call :log "[INFO] Log file: %LOG_FILE%"
call :log "[INFO] Options: check_only=%CHECK_ONLY%, no_path_setx=%NO_PATH_SETX%, scope=%INSTALL_SCOPE%"
if defined VIVADO_BIN call :log "[INFO] User-provided Vivado bin: %VIVADO_BIN%"

if "%CHECK_ONLY%"=="0" if "%AUTO_YES%"=="0" (
    choice /C YN /N /M "Proceed with automatic dependency installation? [Y/N]: "
    if errorlevel 2 (
        call :log "[ERROR] Setup cancelled by user."
        set "EXIT_CODE=5"
        goto finish
    )
)

call :detect_missing_tools

if "%CHECK_ONLY%"=="0" (
    if "%NEED_WINGET%"=="1" (
        call :cmd_exists winget
        if errorlevel 1 (
            call :log "[ERROR] winget is required for automatic installation but was not found."
            set "EXEC_TOOL_FAILURE=1"
        ) else (
            call :log "[CHECK] winget is available."
            winget source list >>"%LOG_FILE%" 2>&1
            if errorlevel 1 call :log "[WARN] winget source check returned non-zero."
        )
    )

    if "%EXEC_TOOL_FAILURE%"=="0" (
        if "%NEED_NODE%"=="1" (
            call :install_winget_package "OpenJS.NodeJS.LTS" "Node.js LTS"
        )
        if "%NEED_PYTHON%"=="1" (
            call :install_winget_package "Python.Python.3.13" "Python 3.13"
        )
        if "%NEED_ICARUS%"=="1" (
            call :install_winget_package "Icarus.Verilog" "Icarus Verilog"
        )
    )
) else (
    call :log "[INFO] Check-only mode: package installation skipped."
)

call :resolve_py_launcher

if "%CHECK_ONLY%"=="0" (
    if defined PY_LAUNCHER (
        call :log "[INSTALL] Upgrading pip and Python packages (jinja2, yowasp-yosys)..."
        call :run_py -m pip install --upgrade pip >>"%LOG_FILE%" 2>&1
        if errorlevel 1 (
            call :log "[WARN] pip upgrade failed."
            set "INSTALL_FAILED=1"
        )
        call :run_py -m pip install --upgrade jinja2 yowasp-yosys >>"%LOG_FILE%" 2>&1
        if errorlevel 1 (
            call :log "[WARN] Python package installation failed."
            set "INSTALL_FAILED=1"
        )
    ) else (
        call :log "[WARN] Python launcher unavailable; skipped Python package installation."
        set "INSTALL_FAILED=1"
    )

    call :cmd_exists npm
    if errorlevel 1 (
        call :log "[WARN] npm not found; skipped templates npm install."
        set "INSTALL_FAILED=1"
    ) else (
        call :log "[INSTALL] Running npm install in templates/..."
        pushd "%TEMPLATES_ROOT%" >nul 2>&1
        call npm install >>"%LOG_FILE%" 2>&1
        set "NPM_INSTALL_RC=!errorlevel!"
        popd >nul 2>&1
        if not "!NPM_INSTALL_RC!"=="0" (
            call :log "[WARN] npm install failed in templates."
            set "INSTALL_FAILED=1"
        )
    )
) else (
    call :log "[INFO] Check-only mode: pip/npm installation skipped."
)

call :resolve_py_launcher
call :collect_path_candidates
call :persist_user_path
if "%PATH_SETX_FAILED%"=="1" (
    set "EXIT_CODE=4"
    goto verify_and_finish
)
call :apply_session_path_candidates

:verify_and_finish
call :final_verification

if "%EXIT_CODE%"=="0" (
    if "%EXEC_TOOL_FAILURE%"=="1" (
        set "EXIT_CODE=5"
    ) else if "%MISSING_COUNT%" GTR "0" (
        if "%CHECK_ONLY%"=="1" (
            set "EXIT_CODE=5"
        ) else (
            set "EXIT_CODE=3"
        )
    )
)

if "%EXIT_CODE%"=="0" (
    call :log "[SUCCESS] Toolkit dependency setup completed successfully."
    call :log "[INFO] Open a new terminal so persisted PATH changes are reflected everywhere."
) else (
    call :log "[FAIL] Toolkit dependency setup completed with issues. rc=%EXIT_CODE%"
    if "%MISSING_COUNT%" GTR "0" (
        call :log "[INFO] Missing dependencies summary:"
        for /f "usebackq tokens=1* delims=|" %%A in ("%MISSING_FILE%") do (
            call :log "  - %%A"
            if not "%%B"=="" call :log "    fix: %%B"
        )
    )
)

:finish
if exist "%PATH_CANDIDATES_FILE%" del /q "%PATH_CANDIDATES_FILE%" >nul 2>&1
if exist "%MISSING_FILE%" del /q "%MISSING_FILE%" >nul 2>&1
call :log "[DONE] setup_toolkit rc=%EXIT_CODE%"
if "%NO_PAUSE%"=="0" call "%CONSOLE_HELPER%" pause_then_clear
endlocal & exit /b %EXIT_CODE%

:parse_args
if "%~1"=="" exit /b 0
:parse_args_loop
if "%~1"=="" exit /b 0
if /i "%~1"=="--yes" (
    set "AUTO_YES=1"
    shift
    goto parse_args_loop
)
if /i "%~1"=="--no-pause" (
    set "NO_PAUSE=1"
    shift
    goto parse_args_loop
)
if /i "%~1"=="--check-only" (
    set "CHECK_ONLY=1"
    shift
    goto parse_args_loop
)
if /i "%~1"=="--no-path-setx" (
    set "NO_PATH_SETX=1"
    shift
    goto parse_args_loop
)
if /i "%~1"=="--vivado-bin" (
    if "%~2"=="" (
        call :usage
        set "EXIT_CODE=2"
        exit /b 0
    )
    for %%I in ("%~2") do set "VIVADO_BIN=%%~fI"
    shift
    shift
    goto parse_args_loop
)
if /i "%~1"=="--scope" (
    if "%~2"=="" (
        call :usage
        set "EXIT_CODE=2"
        exit /b 0
    )
    if /i "%~2"=="user" (
        set "INSTALL_SCOPE=user"
    ) else if /i "%~2"=="machine" (
        set "INSTALL_SCOPE=machine"
    ) else (
        call :usage
        set "EXIT_CODE=2"
        exit /b 0
    )
    shift
    shift
    goto parse_args_loop
)

call :usage
set "EXIT_CODE=2"
exit /b 0

:usage
echo Usage: %~nx0 [--yes] [--no-pause] [--check-only] [--no-path-setx] [--vivado-bin ^<abs_path^>] [--scope user^|machine]
echo.
echo Options:
echo   --yes           Auto-approve prompts
echo   --no-pause      Exit without pause
echo   --check-only    Verify only, no package install
echo   --no-path-setx  Skip persistent PATH update
echo   --vivado-bin    Add Vivado bin directory to PATH candidate list
echo   --scope         winget install scope (default: user)
exit /b 0

:log
set "MSG=%~1"
echo %MSG%
>>"%LOG_FILE%" echo %MSG%
exit /b 0

:cmd_exists
where %~1 >nul 2>nul
exit /b %errorlevel%

:detect_missing_tools
set "NEED_NODE=0"
set "NEED_PYTHON=0"
set "NEED_ICARUS=0"

call :cmd_exists node
if errorlevel 1 set "NEED_NODE=1"
call :cmd_exists npm
if errorlevel 1 set "NEED_NODE=1"
call :cmd_exists python
if errorlevel 1 set "NEED_PYTHON=1"
call :cmd_exists iverilog
if errorlevel 1 set "NEED_ICARUS=1"
call :cmd_exists vvp
if errorlevel 1 set "NEED_ICARUS=1"

if "%CHECK_ONLY%"=="0" (
    if "%NEED_NODE%"=="1" set "NEED_WINGET=1"
    if "%NEED_PYTHON%"=="1" set "NEED_WINGET=1"
    if "%NEED_ICARUS%"=="1" set "NEED_WINGET=1"
)

call :log "[CHECK] Missing pre-install status: NEED_NODE=%NEED_NODE%, NEED_PYTHON=%NEED_PYTHON%, NEED_ICARUS=%NEED_ICARUS%"
exit /b 0

:install_winget_package
set "PKG_ID=%~1"
set "PKG_LABEL=%~2"
call :log "[INSTALL] %PKG_LABEL% via winget (%PKG_ID%)"
winget install --id "%PKG_ID%" --exact --accept-package-agreements --accept-source-agreements --silent --scope %INSTALL_SCOPE% >>"%LOG_FILE%" 2>&1
if errorlevel 1 (
    call :log "[WARN] winget install failed: %PKG_LABEL%"
    set "INSTALL_FAILED=1"
) else (
    call :log "[INFO] winget install completed: %PKG_LABEL%"
)
exit /b 0

:resolve_py_launcher
set "PY_LAUNCHER="
call :cmd_exists py
if not errorlevel 1 set "PY_LAUNCHER=py -3"
if not defined PY_LAUNCHER (
    call :cmd_exists python
    if not errorlevel 1 set "PY_LAUNCHER=python"
)
if defined PY_LAUNCHER (
    call :log "[CHECK] Python launcher: %PY_LAUNCHER%"
) else (
    call :log "[WARN] Python launcher not found."
)
exit /b 0

:run_py
if not defined PY_LAUNCHER exit /b 1
if /i "%PY_LAUNCHER%"=="python" (
    python %*
) else (
    py -3 %*
)
exit /b %errorlevel%

:add_path_candidate
set "CAND=%~1"
if "%CAND%"=="" exit /b 0
if not exist "%CAND%" exit /b 0
if "%CAND:~-1%"=="\" set "CAND=%CAND:~0,-1%"
findstr /x /c:"%CAND%" "%PATH_CANDIDATES_FILE%" >nul 2>nul
if not errorlevel 1 exit /b 0
>>"%PATH_CANDIDATES_FILE%" echo %CAND%
exit /b 0

:add_candidates_from_command
for /f "delims=" %%P in ('where %~1 2^>nul') do (
    for %%D in ("%%~dpP.") do call :add_path_candidate "%%~fD"
)
exit /b 0

:collect_path_candidates
call :add_candidates_from_command node
call :add_candidates_from_command npm
call :add_candidates_from_command py
call :add_candidates_from_command python
call :add_candidates_from_command iverilog
call :add_candidates_from_command vvp
call :add_candidates_from_command yowasp-yosys

if exist "C:\Program Files\nodejs\node.exe" call :add_path_candidate "C:\Program Files\nodejs"
if exist "%LOCALAPPDATA%\Programs\Python\Python313\python.exe" call :add_path_candidate "%LOCALAPPDATA%\Programs\Python\Python313"
if exist "%LOCALAPPDATA%\Programs\Python\Python313\Scripts\yowasp-yosys.exe" call :add_path_candidate "%LOCALAPPDATA%\Programs\Python\Python313\Scripts"
if exist "C:\Program Files\Icarus Verilog\bin\iverilog.exe" call :add_path_candidate "C:\Program Files\Icarus Verilog\bin"

if defined PY_LAUNCHER (
    if /i "%PY_LAUNCHER%"=="python" (
        for /f "usebackq delims=" %%P in (`python -c "import sysconfig; print(sysconfig.get_path('scripts'))" 2^>nul`) do call :add_path_candidate "%%~fP"
    ) else (
        for /f "usebackq delims=" %%P in (`py -3 -c "import sysconfig; print(sysconfig.get_path('scripts'))" 2^>nul`) do call :add_path_candidate "%%~fP"
    )
)

if defined VIVADO_BIN (
    if exist "%VIVADO_BIN%\vivado.bat" (
        call :add_path_candidate "%VIVADO_BIN%"
    ) else (
        call :log "[WARN] --vivado-bin path does not contain vivado.bat: %VIVADO_BIN%"
    )
)
call :add_default_vivado_candidates

call :log "[CHECK] PATH candidate directories:"
for /f "usebackq delims=" %%D in ("%PATH_CANDIDATES_FILE%") do call :log "  - %%D"
exit /b 0

:add_default_vivado_candidates
if not defined SystemDrive set "SystemDrive=C:"
call :add_latest_amd_vivado_candidate "%SystemDrive%\AMDDesignTools"
call :add_latest_xilinx_vivado_candidate "%SystemDrive%\Xilinx\Vivado"
exit /b 0

:add_latest_amd_vivado_candidate
set "ROOT=%~1"
if not exist "%ROOT%" exit /b 0
for /f "delims=" %%V in ('dir /b /ad /o-n "%ROOT%" 2^>nul') do (
    if exist "%ROOT%\%%V\Vivado\bin\vivado.bat" (
        call :add_path_candidate "%ROOT%\%%V\Vivado\bin"
        exit /b 0
    )
)
exit /b 0

:add_latest_xilinx_vivado_candidate
set "ROOT=%~1"
if not exist "%ROOT%" exit /b 0
for /f "delims=" %%V in ('dir /b /ad /o-n "%ROOT%" 2^>nul') do (
    if exist "%ROOT%\%%V\bin\vivado.bat" (
        call :add_path_candidate "%ROOT%\%%V\bin"
        exit /b 0
    )
)
exit /b 0

:persist_user_path
set "TOOLKIT_HOME=%USERPROFILE%\.fpga_toolkit"
set "BACKUP_DIR=%TOOLKIT_HOME%\backups"
if not exist "%BACKUP_DIR%" mkdir "%BACKUP_DIR%" >nul 2>&1
set "BACKUP_FILE=%BACKUP_DIR%\path_user_%TS%.txt"
set "RESTORE_BAT=%BACKUP_DIR%\restore_user_path_%TS%.bat"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$ErrorActionPreference = 'Stop'; " ^
    "$p = [Environment]::GetEnvironmentVariable('Path','User'); " ^
    "if ($null -eq $p) { $p = '' }; " ^
    "$dir = Split-Path -Parent '%BACKUP_FILE%'; " ^
    "if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }; " ^
    "[System.IO.File]::WriteAllText('%BACKUP_FILE%', $p, [System.Text.Encoding]::UTF8)" >>"%LOG_FILE%" 2>&1
if errorlevel 1 call :log "[WARN] Failed to write PATH backup file."

> "%RESTORE_BAT%" echo @echo off
>>"%RESTORE_BAT%" echo setlocal
>>"%RESTORE_BAT%" echo powershell -NoProfile -Command "$p = Get-Content -Raw -LiteralPath '%BACKUP_FILE%'; if ($null -eq $p) { $p = '' }; setx PATH $p ^| Out-Null; if ($LASTEXITCODE -ne 0) { exit 1 }"
>>"%RESTORE_BAT%" echo if errorlevel 1 ^(
>>"%RESTORE_BAT%" echo   echo [ERROR] Failed to restore PATH.
>>"%RESTORE_BAT%" echo   exit /b 1
>>"%RESTORE_BAT%" echo ^)
>>"%RESTORE_BAT%" echo echo [DONE] User PATH restored from backup.
>>"%RESTORE_BAT%" echo pause
>>"%RESTORE_BAT%" echo endlocal
>>"%RESTORE_BAT%" echo exit /b 0

if "%NO_PATH_SETX%"=="1" (
    call :log "[INFO] Persistent PATH update disabled (--no-path-setx or check-only)."
) else (
    if "%AUTO_YES%"=="0" (
        choice /C YN /N /M "Apply persistent User PATH update with setx? [Y/N]: "
        if errorlevel 2 (
            call :log "[INFO] User skipped persistent PATH update."
            set "NO_PATH_SETX=1"
        )
    )
)

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$ErrorActionPreference = 'Stop'; " ^
    "$userPath = [Environment]::GetEnvironmentVariable('Path','User'); " ^
    "if ($null -eq $userPath) { $userPath = '' }; " ^
    "$candidates = @(); " ^
    "if (Test-Path -LiteralPath '%PATH_CANDIDATES_FILE%') { $candidates = Get-Content -LiteralPath '%PATH_CANDIDATES_FILE%' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } }; " ^
    "$all = @(); if ($userPath -ne '') { $all += $userPath -split ';' }; $all += $candidates; " ^
    "$seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase); " ^
    "$mergedList = New-Object 'System.Collections.Generic.List[string]'; " ^
    "foreach ($entry in $all) { if ([string]::IsNullOrWhiteSpace($entry)) { continue }; $norm = $entry.Trim().TrimEnd('\'); if ($seen.Add($norm)) { $null = $mergedList.Add($norm) } }; " ^
    "$merged = [string]::Join(';', $mergedList); " ^
    "if ('%NO_PATH_SETX%' -ne '1' -and $merged.Length -gt 0) { setx PATH $merged | Out-Null; if ($LASTEXITCODE -ne 0) { exit 41 } }" >>"%LOG_FILE%" 2>&1
set "PS_RC=%errorlevel%"

if "%PS_RC%"=="41" (
    call :log "[ERROR] setx PATH update failed."
    set "PATH_SETX_FAILED=1"
    exit /b 0
)
if not "%PS_RC%"=="0" (
    call :log "[WARN] PATH backup/merge script returned rc=%PS_RC%"
)

call :log "[INFO] PATH backup file: %BACKUP_FILE%"
call :log "[INFO] PATH restore script: %RESTORE_BAT%"
exit /b 0

:apply_session_path_candidates
for /f "usebackq delims=" %%D in ("%PATH_CANDIDATES_FILE%") do call :append_session_path "%%~D"
exit /b 0

:append_session_path
set "DIR_CAND=%~1"
if "%DIR_CAND%"=="" exit /b 0
if not exist "%DIR_CAND%" exit /b 0
echo ;!PATH!; | findstr /I /C:";%DIR_CAND%;" >nul 2>&1
if errorlevel 1 set "PATH=!PATH!;%DIR_CAND%"
exit /b 0

:record_missing
set /a MISSING_COUNT+=1
>>"%MISSING_FILE%" echo %~1^|%~2
exit /b 0

:final_verification
call :log "[VERIFY] Running final dependency checks..."

call :cmd_exists node
if errorlevel 1 call :record_missing "node" "winget install --id OpenJS.NodeJS.LTS --exact --accept-package-agreements --accept-source-agreements"
call :cmd_exists npm
if errorlevel 1 call :record_missing "npm" "winget install --id OpenJS.NodeJS.LTS --exact --accept-package-agreements --accept-source-agreements"
call :cmd_exists python
if errorlevel 1 call :record_missing "python" "winget install --id Python.Python.3.13 --exact --accept-package-agreements --accept-source-agreements"

call :resolve_py_launcher
if not defined PY_LAUNCHER (
    call :record_missing "python-launcher" "Install Python 3.13 and reopen terminal"
) else (
    call :run_py -c "import jinja2" >>"%LOG_FILE%" 2>&1
    if errorlevel 1 call :record_missing "jinja2" "%PY_LAUNCHER% -m pip install --upgrade jinja2"
)

call :cmd_exists iverilog
if errorlevel 1 call :record_missing "iverilog" "winget install --id Icarus.Verilog --exact --accept-package-agreements --accept-source-agreements"
call :cmd_exists vvp
if errorlevel 1 call :record_missing "vvp" "winget install --id Icarus.Verilog --exact --accept-package-agreements --accept-source-agreements"
call :cmd_exists yowasp-yosys
if errorlevel 1 (
    if defined PY_LAUNCHER (
        call :record_missing "yowasp-yosys" "%PY_LAUNCHER% -m pip install --upgrade yowasp-yosys"
    ) else (
        call :record_missing "yowasp-yosys" "Install Python first, then pip install yowasp-yosys"
    )
)

call :cmd_exists vivado
if errorlevel 1 (
    call :log "[WARN] Vivado is not found in PATH. Install Vivado manually."
    if not defined VIVADO_BIN call :log "[INFO] You can pass --vivado-bin \"C:\\AMDDesignTools\\2025.2\\Vivado\\bin\""
)

for %%C in (node npm py python iverilog vvp yowasp-yosys vivado) do where %%C >>"%LOG_FILE%" 2>&1

call :cmd_exists npm
if not errorlevel 1 (
    pushd "%TEMPLATES_ROOT%" >nul 2>&1
    call npm ls --depth=0 >>"%LOG_FILE%" 2>&1
    set "NPM_LS_RC=!errorlevel!"
    popd >nul 2>&1
    if not "!NPM_LS_RC!"=="0" call :log "[WARN] npm ls --depth=0 returned non-zero (see log)."
)

if defined PY_LAUNCHER (
    call :run_py -m pip show jinja2 >>"%LOG_FILE%" 2>&1
)

call :cmd_exists node
if not errorlevel 1 (
    node "%TEMPLATES_ROOT%\contexts\manifest\adapters\cli\manifest_resolve_cli.js" --selftest >>"%LOG_FILE%" 2>&1
    if errorlevel 1 call :log "[WARN] Manifest selftest failed (see log)."
)

if "%MISSING_COUNT%"=="0" (
    call :log "[VERIFY] Required dependencies are satisfied."
) else (
    call :log "[VERIFY] Missing required dependencies detected: %MISSING_COUNT%"
)
exit /b 0
