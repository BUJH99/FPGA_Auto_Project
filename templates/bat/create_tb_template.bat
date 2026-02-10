@echo off
setlocal
cd /d "%~dp0.."

echo ============================================================================
echo      Verilog Testbench Generator (Auto-DUT Parsing)
echo ============================================================================

if not exist "src" (
    echo [Error] 'src' directory not found at: %CD%\src
    pause
    exit /b 1
)

if not exist "tb" (
    mkdir "tb"
    echo [Info] Created 'tb' directory.
)

:: ----------------------------------------------------------------------------
:: Hybrid PowerShell Script Wrapper
:: ----------------------------------------------------------------------------
set "PS_FILE=%TEMP%\tb_gen_parsed_%RANDOM%.ps1"
set "MARKER=:POWERSHELL_SCRIPT_START"

:: Extract PowerShell script from this file
for /f "tokens=1 delims=:" %%a in ('findstr /n "^%MARKER%" "%~f0"') do set "START_LINE=%%a"
more +%START_LINE% "%~f0" > "%PS_FILE%"

:: Run PowerShell script
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_FILE%"

:: Cleanup
del "%PS_FILE%"
pause
goto :eof

:: ============================================================================
:: PowerShell Script Start
:: ============================================================================
:POWERSHELL_SCRIPT_START
$ErrorActionPreference = "Stop"

$srcDir = "src"
$tbDir = "tb"

# 1. Scan Source Files
$files = Get-ChildItem -Path $srcDir -File -Recurse -Filter "*.v" | Where-Object { $_.Name -notlike "tb_*" }
if ($files.Count -eq 0) {
    Write-Host "[Error] No source files (*.v) found in src directory (excluding tb_*)." -ForegroundColor Red
    exit 1
}

# 2. Display Menu
Write-Host "Found $($files.Count) source file(s):" -ForegroundColor Cyan
Write-Host "----------------------------------------------------------------------------"
$i = 1
foreach ($f in $files) {
    Write-Host "[$i] $($f.Name)"
    $i++
}
Write-Host "----------------------------------------------------------------------------"

# 3. User Selection
$selection = Read-Host "Select Source File Number (1-$($files.Count))"
$selection = $selection.Trim()

if ($selection -match '^\d+$') {
    $selInt = [int]$selection
    if ($selInt -lt 1 -or $selInt -gt $files.Count) {
        Write-Host "[Error] Selection out of range." -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "[Error] Invalid input (not a number)." -ForegroundColor Red
    exit 1
}

$targetFile = $files[$selInt - 1]
$modName = $targetFile.BaseName
$tbFilename = "tb_$modName.v"
$tbPath = Join-Path $tbDir $tbFilename

Write-Host "`nTarget Module: $modName" -ForegroundColor Green
Write-Host "Parsing source file: $($targetFile.FullName)..." -ForegroundColor Yellow

# =============================================================================
# AUTO-DUT PARSING LOGIC
# =============================================================================
$content = Get-Content $targetFile.FullName -Raw

# Remove Comments (Simple approach)
$content = $content -replace '//.*', '' 
$content = $content -replace '(?s)/\*.*?\*/', ''

# Extract Port Section
$ports = @()
if ($content -match 'module\s+\w+\s*#?[\s\S]*?\(([\s\S]*?)\);') {
    $portBlock = $matches[1]
    
    # Split by comma
    $rawPorts = $portBlock.Split(',')
    
    foreach ($p in $rawPorts) {
        $p = $p.Trim()
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        
        # Parse direction, type, range, name
        # Example: input wire [7:0] iData
        # Capture: (dir) (type)? (range)? (name)
        if ($p -match '(input|output|inout)\s+(?:(wire|reg|logic)\s+)?(?:(\[[^\]]+\])\s+)?(\w+)') {
            $ports += [PSCustomObject]@{
                Direction = $matches[1]
                Type = $matches[2] # can be null
                Range = $matches[3] # can be null
                Name = $matches[4]
            }
        }
    }
} else {
    Write-Host "[WARNING] Could not parse module declaration. Generated TB will be empty." -ForegroundColor Magenta
}

Write-Host "Found $($ports.Count) ports." -ForegroundColor Cyan

# =============================================================================
# GENERATE TESTBENCH CONTENT
# =============================================================================
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine('`timescale 1ns / 1ps')
[void]$sb.AppendLine('')
[void]$sb.AppendLine("module tb_$modName;")
[void]$sb.AppendLine('')
[void]$sb.AppendLine('    // ========================================================================')
[void]$sb.AppendLine('    // 1. Parameter & Signal Definition')
[void]$sb.AppendLine('    // ========================================================================')
[void]$sb.AppendLine('    localparam CLK_PERIOD = 10; // 100MHz (10ns)')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('    // Automation Variables')
[void]$sb.AppendLine('')

# Generate Reg/Wire Declarations
foreach ($p in $ports) {
    if ($p.Name -eq "iClk" -or $p.Name -eq "iRstn" -or $p.Name -eq "clk" -or $p.Name -eq "rst_n") {
        # Already handled locally or distinct treatment needed
        continue 
    }
    
    $rangeStr = if ($p.Range) { $p.Range + " " } else { "" }
    
    if ($p.Direction -eq "input") {
        [void]$sb.AppendLine("    reg $rangeStr$($p.Name);")
    } elseif ($p.Direction -eq "output") {
        [void]$sb.AppendLine("    wire $rangeStr$($p.Name);")
    } elseif ($p.Direction -eq "inout") {
        [void]$sb.AppendLine("    wire $rangeStr$($p.Name);")
    }
}

# Add default clock/reset if not in ports (or matching common names)
$hasClk = $ports | Where-Object { $_.Name -match "i?Clk|clk" }
$hasRst = $ports | Where-Object { $_.Name -match "i?Rst|rst" }

if (-not $hasClk) { [void]$sb.AppendLine('    reg iClk;') }
if (-not $hasRst) { [void]$sb.AppendLine('    reg iRstn;') }

[void]$sb.AppendLine('')
[void]$sb.AppendLine('    // ========================================================================')
[void]$sb.AppendLine('    // 2. DUT Instantiation')
[void]$sb.AppendLine('    // ========================================================================')
[void]$sb.AppendLine("    $modName uut (")

# Port Mapping
$len = $ports.Count
for ($j=0; $j -lt $len; $j++) {
    $p = $ports[$j]
    $comma = if ($j -eq $len -1) { "" } else { "," }
    
    if ($p.Name -match "i?Clk|clk") {
        [void]$sb.AppendLine("        .$($p.Name)(iClk)$comma")
    } elseif ($p.Name -match "i?Rst|rst") {
        [void]$sb.AppendLine("        .$($p.Name)(iRstn)$comma")
    } else {
        [void]$sb.AppendLine("        .$($p.Name)($($p.Name))$comma")
    }
}

[void]$sb.AppendLine('    );')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('    // ========================================================================')
[void]$sb.AppendLine('    // 3. Clock Generation')
[void]$sb.AppendLine('    // ========================================================================')
[void]$sb.AppendLine('    initial begin')
[void]$sb.AppendLine('        iClk = 0;')
[void]$sb.AppendLine('        forever #(CLK_PERIOD/2) iClk = ~iClk;')
[void]$sb.AppendLine('    end')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('    // ========================================================================')
[void]$sb.AppendLine('    // 4. Test Scenarios')
[void]$sb.AppendLine('    // ========================================================================')
[void]$sb.AppendLine('    initial begin')
[void]$sb.AppendLine('        // Initialize')
[void]$sb.AppendLine('        iRstn = 0;')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('        // Init Inputs')
foreach ($p in $ports) {
    if ($p.Direction -eq "input" -and $p.Name -notmatch "i?Clk|i?Rst|clk|rst") {
        [void]$sb.AppendLine("        $($p.Name) = 0;")
    }
}

[void]$sb.AppendLine('')
[void]$sb.AppendLine('        $dumpfile("wave.vcd");')
[void]$sb.AppendLine("        `$dumpvars(0, tb_$modName);")
[void]$sb.AppendLine('')
[void]$sb.AppendLine('        // Reset Sequence')
[void]$sb.AppendLine('        #(CLK_PERIOD * 10);')
[void]$sb.AppendLine('        iRstn = 1;')
[void]$sb.AppendLine('        #(CLK_PERIOD * 10);')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('        // --------------------------------------------------------------------')
[void]$sb.AppendLine('        // CASE N: Initial State Check')
[void]$sb.AppendLine('        // --------------------------------------------------------------------')
# Auto-generate @WAVE signals suggestion
$waveSignals = ($ports | ForEach-Object { $_.Name }) -join ", "
[void]$sb.AppendLine("        // @WAVE: iClk, iRstn, $waveSignals")
[void]$sb.AppendLine('        // @RUNTIME BEGIN : 20ns')
[void]$sb.AppendLine('        // @RUNTIME END : 120ns')

[void]$sb.AppendLine('        $display("TEST CASE N: Initial State Check");')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('        #(CLK_PERIOD * 10);')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('        $display("Simulation Finished");')
[void]$sb.AppendLine('        $finish;')
[void]$sb.AppendLine('    end')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('endmodule')

# 4. Check Overwrite
Write-Host "Creating Testbench: $tbPath ..." -ForegroundColor Green
if (Test-Path $tbPath) {
    Write-Host "`n[WARNING] $tbFilename already exists!" -ForegroundColor Yellow
    $overwrite = Read-Host "Overwrite? (y/n)"
    if ($overwrite.ToLower() -ne "y") {
        Write-Host "Cancelled." -ForegroundColor Yellow
        exit 0
    }
} else {
    # Ensure directory exists (again, just in case)
    if (-not (Test-Path $tbDir)) { New-Item -ItemType Directory -Path $tbDir | Out-Null }
}

Set-Content -Path $tbPath -Value $sb.ToString()

Write-Host "`n[SUCCESS] Created parsed template: $tbPath" -ForegroundColor Green
Write-Host "Auto-filled $($ports.Count) ports." -ForegroundColor Gray
