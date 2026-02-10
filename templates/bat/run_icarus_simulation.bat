@echo off
setlocal
cd /d "%~dp0.."

echo -----------------------------------------------------------
echo      Icarus Verilog Simulation + WaveDrom Export
echo -----------------------------------------------------------

where iverilog >nul 2>nul
if %errorlevel% neq 0 (
    echo [Error] 'iverilog' not found. Please install Icarus Verilog.
    pause
    exit /b
)

set "PS_FILE=%TEMP%\sim_runner_%RANDOM%.ps1"
set "MARKER=:POWERSHELL_SCRIPT_START"

for /f "tokens=1 delims=:" %%a in ('findstr /n "^%MARKER%" "%~f0"') do set "START_LINE=%%a"
more +%START_LINE% "%~f0" > "%PS_FILE%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_FILE%"

del "%PS_FILE%"
goto :eof

:POWERSHELL_SCRIPT_START
$tbDir = 'tb'
$srcDir = 'src'
$outDir = 'output'

if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
if (-not (Test-Path $tbDir)) {
    Write-Host "No 'tb' directory found." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $srcDir)) {
    Write-Host "No 'src' directory found." -ForegroundColor Red
    exit 1
}

$tbFiles = Get-ChildItem -Path $tbDir -File | Where-Object { $_.Extension -in '.v', '.sv' } | Sort-Object Name
if ($tbFiles.Count -eq 0) {
    Write-Host "No testbench files found in '$tbDir'." -ForegroundColor Red
    exit 1
}

Write-Host "Select Testbench to Run:" -ForegroundColor Cyan
for ($i = 0; $i -lt $tbFiles.Count; $i++) {
    Write-Host ("[{0}] {1}" -f ($i + 1), $tbFiles[$i].Name)
}

$sel = Read-Host " >"
if (-not ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $tbFiles.Count)) {
    Write-Host "Invalid Selection" -ForegroundColor Red
    exit 1
}

$targetTB = $tbFiles[[int]$sel - 1]
$tbBase = $targetTB.BaseName
$outFile = Join-Path $outDir 'sim.out'
$simLogFile = Join-Path $outDir "$tbBase.sim.log"
$defaultVcd = Join-Path $outDir "$tbBase.vcd"
$wavedromOut = Join-Path $outDir 'wavedrom_cases.json'

Write-Host "`n[1/5] Compiling..." -ForegroundColor Yellow
$srcFiles = Get-ChildItem -Path $srcDir -File | Where-Object { $_.Extension -in '.v', '.sv' } | ForEach-Object { $_.FullName }
if ($srcFiles.Count -eq 0) {
    Write-Host "No source files found in '$srcDir'." -ForegroundColor Red
    exit 1
}

$iverilogArgs = @('-g2012', '-o', $outFile) + $srcFiles + @($targetTB.FullName)
& iverilog @iverilogArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host "Compilation Failed." -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Host "[2/5] Running Simulation..." -ForegroundColor Yellow
if (Test-Path $simLogFile) { Remove-Item $simLogFile -Force }
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$simExitCode = 0
$writer = New-Object System.IO.StreamWriter($simLogFile, $false, $utf8NoBom)
try {
    & vvp $outFile +case_meta_jsonl 2>&1 | ForEach-Object {
        $line = $_.ToString()
        Write-Host $line
        $writer.WriteLine($line)
    }
    $simExitCode = $LASTEXITCODE
} finally {
    $writer.Close()
}
if ($simExitCode -ne 0) {
    Write-Host "Simulation Failed." -ForegroundColor Red
    exit $simExitCode
}

$vcdFile = $defaultVcd
if (-not (Test-Path $vcdFile)) {
    $fallback = @(
        Get-ChildItem -Path $outDir -Filter *.vcd -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -like "$tbBase*" }
        Get-ChildItem -Path "." -Filter *.vcd -ErrorAction SilentlyContinue | Where-Object { $_.BaseName -like "$tbBase*" }
    ) | Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if ($fallback) {
        $vcdFile = $fallback.FullName
        Write-Host "[INFO] Using detected VCD: $vcdFile" -ForegroundColor Cyan
    }
}

if (-not (Test-Path $vcdFile)) {
    Write-Host "No VCD file generated ($vcdFile)." -ForegroundColor Yellow
    Write-Host "Did you include `$dumpfile and `$dumpvars in your testbench?" -ForegroundColor Gray
    exit 1
}

Write-Host "[3/5] Converting VCD to WaveDrom JSON..." -ForegroundColor Yellow
$waveCfgCandidates = @(
    (Join-Path $tbDir "$tbBase.wave.json"),
    (Join-Path $tbDir 'wave_extract_config.json')
)
$waveCfgFile = $waveCfgCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $waveCfgFile) {
    Write-Host "[INFO] Wave config not found. Skipping WaveDrom conversion." -ForegroundColor DarkYellow
} elseif (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host "[WARNING] Node.js is not available. Skipping WaveDrom conversion." -ForegroundColor DarkYellow
} elseif (-not (Test-Path 'tools\vcd_to_wavedrom.js')) {
    Write-Host "[WARNING] tools\vcd_to_wavedrom.js not found. Skipping WaveDrom conversion." -ForegroundColor DarkYellow
} else {
    $jsonlMeta = Join-Path $outDir "$tbBase`_cases.jsonl"
    $nodeArgs = @(
        'tools\vcd_to_wavedrom.js',
        '--vcd', $vcdFile,
        '--signals', $waveCfgFile,
        '--markers', $simLogFile,
        '--out', $wavedromOut
    )
    if (Test-Path $jsonlMeta) {
        $nodeArgs += @('--jsonl', $jsonlMeta)
    }

    & node @nodeArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[WARNING] WaveDrom conversion failed." -ForegroundColor DarkYellow
    } else {
        Write-Host "[SUCCESS] WaveDrom case JSON generated: $wavedromOut" -ForegroundColor Green
    }
}

Write-Host "[4/5] Opening Waveform..." -ForegroundColor Green
$gtkwFile = Join-Path $outDir "$tbBase.gtkw"
if (-not (Test-Path $gtkwFile)) {
    $gtkwSrc = Join-Path $tbDir "$tbBase.gtkw"
    if (Test-Path $gtkwSrc) { $gtkwFile = $gtkwSrc }
}

if (Get-Command gtkwave -ErrorAction SilentlyContinue) {
    if (Test-Path $gtkwFile) {
        Start-Process gtkwave -ArgumentList @($vcdFile, $gtkwFile)
    } else {
        Start-Process gtkwave -ArgumentList @($vcdFile)
    }
} else {
    Invoke-Item $vcdFile
}

Write-Host "[5/5] Regenerating Final HTML report..." -ForegroundColor Yellow
if (-not (Test-Path 'tcl\generate_html_report.tcl')) {
    Write-Host "[INFO] tcl\generate_html_report.tcl not found. Skip report generation." -ForegroundColor DarkYellow
} elseif (-not (Get-Command vivado -ErrorAction SilentlyContinue)) {
    Write-Host "[INFO] Vivado not found in PATH. Skip report generation." -ForegroundColor DarkYellow
} else {
    & vivado -mode batch -source ./tcl/generate_html_report.tcl -notrace -nojournal -log ./output/report_gen_sim.log
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[WARNING] Report generation failed. Check output\report_gen_sim.log" -ForegroundColor DarkYellow
    } else {
        Write-Host "[SUCCESS] Report generated: output\Final_Build_Report.html" -ForegroundColor Green
    }
}
