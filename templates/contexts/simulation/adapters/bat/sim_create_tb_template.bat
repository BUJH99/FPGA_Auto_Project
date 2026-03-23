@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
set "CONSOLE_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\console_ui.bat"

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^> [--tb-ext v^|sv]
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
set "MANIFEST_CTX=%TEMPLATES_ROOT%\shared\adapters\bat\bootstrap_manifest_context.bat"
set "TB_EXT=v"
set "ARG2=%~2"
if /i "%~2"=="--tb-ext" (
    if /i "%~3"=="sv" set "TB_EXT=sv"
    if /i "%~3"=="v" set "TB_EXT=v"
) else if /i "%ARG2:~0,9%"=="--tb-ext=" (
    set "TB_EXT=%ARG2:~9%"
)
if /i not "%TB_EXT%"=="v" if /i not "%TB_EXT%"=="sv" set "TB_EXT=v"

call "%MANIFEST_CTX%" "%TARGET_PROJECT%"
if errorlevel 1 (
    echo [ERROR] Manifest context initialization failed.
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

cd /d "%TARGET_PROJECT%"

echo ============================================================================
echo      HDL Testbench Generator (Auto-DUT Parsing)
echo ============================================================================

if not exist "src" (
    echo [Error] 'src' directory not found at: %CD%\src
    call "%CONSOLE_HELPER%" pause_then_clear
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
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_FILE%" "%TB_EXT%" "%TARGET_PROJECT%" "%MANIFEST_SRC_LIST%"

:: Cleanup
del "%PS_FILE%"
call "%CONSOLE_HELPER%" pause_then_clear
goto :eof

:: ============================================================================
:: PowerShell Script Start
:: ============================================================================
:POWERSHELL_SCRIPT_START
param(
    [string]$TbExt = "v",
    [string]$ProjectRoot = "",
    [string]$ManifestSrcList = ""
)
$ErrorActionPreference = "Stop"
if ($TbExt -notin @("v", "sv")) { $TbExt = "v" }

$srcDir = "src"
$tbDir = "tb"

# 1. Scan Source Files
$files = @()
if (-not [string]::IsNullOrWhiteSpace($ManifestSrcList) -and (Test-Path $ManifestSrcList)) {
    $projRootNorm = $ProjectRoot
    if ([string]::IsNullOrWhiteSpace($projRootNorm)) {
        $projRootNorm = (Get-Location).Path
    }
    foreach ($rel in Get-Content -Path $ManifestSrcList) {
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        $candidate = Join-Path $projRootNorm ($rel -replace '/', '\')
        if (-not (Test-Path $candidate)) { continue }
        $fi = Get-Item -LiteralPath $candidate -ErrorAction SilentlyContinue
        if ($null -eq $fi -or -not $fi.PSIsContainer) {
            if ($fi.Extension -in ".v", ".sv" -and $fi.Name -notlike "tb_*") {
                $files += $fi
            }
        }
    }
    $files = @($files | Sort-Object FullName -Unique)
}

if ($files.Count -eq 0) {
    Write-Host "[Error] No source files (*.v/*.sv) found in manifest-resolved src list." -ForegroundColor Red
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
$modName = $targetFile.BaseName.Trim()
$tbFilename = "tb_$modName.$TbExt"
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

# Identify canonical TB-driven clock/reset signals (use DUT names when available)
$clkPort = $ports | Where-Object { $_.Direction -eq "input" -and $_.Name -match '^(i?Clk|clk)$|clock' } | Select-Object -First 1
$rstPort = $ports | Where-Object { $_.Direction -eq "input" -and $_.Name -match '^(i?Rst|rst)' } | Select-Object -First 1
$clockStimName = if ($clkPort) { $clkPort.Name } else { "iClk" }
$resetStimName = if ($rstPort) { $rstPort.Name } else { "iRstn" }
$resetActiveLow = ($resetStimName -match '(?i)n$')

# Generate Reg/Wire/Logic Declarations
foreach ($p in $ports) {
    $rangeStr = if ($p.Range) { $p.Range + " " } else { "" }
    
    if ($p.Direction -eq "input") {
        if ($TbExt -eq "sv") {
            [void]$sb.AppendLine("    logic $rangeStr$($p.Name);")
        } else {
            [void]$sb.AppendLine("    reg $rangeStr$($p.Name);")
        }
    } elseif ($p.Direction -eq "output") {
        if ($TbExt -eq "sv") {
            [void]$sb.AppendLine("    logic $rangeStr$($p.Name);")
        } else {
            [void]$sb.AppendLine("    wire $rangeStr$($p.Name);")
        }
    } elseif ($p.Direction -eq "inout") {
        if ($TbExt -eq "sv") {
            [void]$sb.AppendLine("    wire $rangeStr$($p.Name);")
        } else {
            [void]$sb.AppendLine("    wire $rangeStr$($p.Name);")
        }
    }
}

# Add default clock/reset if DUT does not have them
if (-not $clkPort) {
    if ($TbExt -eq "sv") { [void]$sb.AppendLine('    logic iClk;') } else { [void]$sb.AppendLine('    reg iClk;') }
}
if (-not $rstPort) {
    if ($TbExt -eq "sv") { [void]$sb.AppendLine('    logic iRstn;') } else { [void]$sb.AppendLine('    reg iRstn;') }
}

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
    
    [void]$sb.AppendLine("        .$($p.Name)($($p.Name))$comma")
}

[void]$sb.AppendLine('    );')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('    // ========================================================================')
[void]$sb.AppendLine('    // 3. Clock Generation')
[void]$sb.AppendLine('    // ========================================================================')
[void]$sb.AppendLine('    initial begin')
[void]$sb.AppendLine("        $clockStimName = 0;")
[void]$sb.AppendLine("        forever #(CLK_PERIOD/2) $clockStimName = ~$clockStimName;")
[void]$sb.AppendLine('    end')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('    // ========================================================================')
[void]$sb.AppendLine('    // 4. Test Scenarios')
[void]$sb.AppendLine('    // ========================================================================')
[void]$sb.AppendLine('    initial begin')
[void]$sb.AppendLine('        // Initialize')
[void]$sb.AppendLine(("        {0} = {1};" -f $resetStimName, ($(if ($resetActiveLow) { '0' } else { '1' }))))
[void]$sb.AppendLine('')
[void]$sb.AppendLine('        // Init Inputs')
foreach ($p in $ports) {
    if ($p.Direction -eq "input" -and $p.Name -ne $clockStimName -and $p.Name -ne $resetStimName) {
        [void]$sb.AppendLine("        $($p.Name) = 0;")
    }
}

[void]$sb.AppendLine('')
[void]$sb.AppendLine('        $dumpfile("wave.vcd");')
[void]$sb.AppendLine("        `$dumpvars(0, tb_$modName);")
[void]$sb.AppendLine('')
[void]$sb.AppendLine('        // Reset Sequence')
[void]$sb.AppendLine('        #(CLK_PERIOD * 10);')
[void]$sb.AppendLine(("        {0} = {1};" -f $resetStimName, ($(if ($resetActiveLow) { '1' } else { '0' }))))
[void]$sb.AppendLine('        #(CLK_PERIOD * 10);')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('        // --------------------------------------------------------------------')
[void]$sb.AppendLine('        // CASE N: Initial State Check')
[void]$sb.AppendLine('        // --------------------------------------------------------------------')
# Auto-generate @WAVE signals suggestion
$waveSignals = @($ports | ForEach-Object { $_.Name })
if (-not ($waveSignals -contains $clockStimName)) { $waveSignals = @($clockStimName) + $waveSignals } else { $waveSignals = @($clockStimName) + @($waveSignals | Where-Object { $_ -ne $clockStimName }) }
if (-not ($waveSignals -contains $resetStimName)) { $waveSignals = @($resetStimName) + $waveSignals } else { $waveSignals = @($clockStimName, $resetStimName) + @($waveSignals | Where-Object { $_ -ne $clockStimName -and $_ -ne $resetStimName }) }
$waveSignals = @($waveSignals | Where-Object { $_ } | Select-Object -Unique)
[void]$sb.AppendLine("        // @WAVE: $($waveSignals -join ', ')")
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
