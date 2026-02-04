@echo off
setlocal
cd /d "%~dp0"

echo -----------------------------------------------------------
echo      Icarus Verilog Simulator (Enhanced)
echo -----------------------------------------------------------

:: Check Dependencies
where iverilog >nul 2>nul
if %errorlevel% neq 0 (
    echo [Error] 'iverilog' not found. Please install Icarus Verilog.
    pause
    exit /b
)

:: Run PowerShell Menu
set "PS_FILE=%TEMP%\sim_runner_%RANDOM%.ps1"
set "MARKER=:POWERSHELL_SCRIPT_START"

for /f "tokens=1 delims=:" %%a in ('findstr /n "^%MARKER%" "%~f0"') do set "START_LINE=%%a"
more +%START_LINE% "%~f0" > "%PS_FILE%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_FILE%"

del "%PS_FILE%"
goto :eof

:POWERSHELL_SCRIPT_START
$tbDir = 'tb';
$srcDir = 'src';
$outDir = 'output';

if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
if (-not (Test-Path $tbDir)) { 
    Write-Host "No 'tb' directory found." -ForegroundColor Red
    exit
}

# 1. List TB Files
$files = Get-ChildItem -Path $tbDir -Filter *.v | Sort-Object Name;
if ($files.Count -eq 0) {
    Write-Host "No testbench files found in '$tbDir'." -ForegroundColor Red
    exit
}

Write-Host "Select Testbench to Run:" -ForegroundColor Cyan
for ($i=0; $i -lt $files.Count; $i++) {
    Write-Host ("[{0}] {1}" -f ($i+1), $files[$i].Name)
}

$sel = Read-Host " >"
if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $files.Count) {
    $targetTB = $files[[int]$sel - 1]
    
    # 2. Compile
    Write-Host "`n[1/3] Compiling..." -ForegroundColor Yellow
    $outFile = "$outDir\sim.out"
    
    # Compile: src/*.v + selected_tb.v
    # Using 'cmd /c' to properly execute iverilog if it's a batch wrapper or exe
    $cmd = "iverilog -g2012 -o ""$outFile"" ""$srcDir\*.v"" ""$($targetTB.FullName)"""
    Invoke-Expression $cmd
    
    if (-not $?) {
        Write-Host "Compilation Failed." -ForegroundColor Red
        exit
    }
    
    # 3. Running
    Write-Host "[2/3] Running Simulation..." -ForegroundColor Yellow
    $vcdFile = "$outDir\$($targetTB.BaseName).vcd"
    
    # Run vvp (silently catch output if needed, or let it stream)
    # Note: The TB must have $dumpfile specified. If create_tb.bat was used, it has it.
    
    $runCmd = "vvp ""$outFile"""
    # If the TB doesn't have $dumpfile, we can force VCD output via wrapper? 
    # But standard way is $dumpfile inside code.
    
    Invoke-Expression $runCmd
    
    # 4. Open Waveform
    Write-Host "[3/3] Opening Waveform..." -ForegroundColor Green
    
    # Check if VCD was actually created
    if (Test-Path $vcdFile) {
        
        # Look for GTKWave save file (.gtkw) which might save signal setup
        $gtkwFile = "$outDir\$($targetTB.BaseName).gtkw"
        if (-not (Test-Path $gtkwFile)) {
             # Check if there is one in tb folder source?
             $gtkwSrc = "$tbDir\$($targetTB.BaseName).gtkw"
             if (Test-Path $gtkwSrc) { $gtkwFile = $gtkwSrc }
        }

        if (Get-Command "gtkwave" -ErrorAction SilentlyContinue) {
            if (Test-Path $gtkwFile) {
                Start-Process "gtkwave" -ArgumentList """$vcdFile"" ""$gtkwFile"""
            } else {
                Start-Process "gtkwave" -ArgumentList """$vcdFile"""
            }
        } else {
            # Fallback
            Invoke-Item $vcdFile
        }
    } else {
        Write-Host "No VCD file generated ($vcdFile)." -ForegroundColor Yellow
        Write-Host "Did you include `$dumpfile and `$dumpvars in your testbench?" -ForegroundColor Gray
    }
    
} else {
    Write-Host "Invalid Selection" -ForegroundColor Red
}
