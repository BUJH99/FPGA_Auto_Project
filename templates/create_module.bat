@echo off
setlocal
cd /d "%~dp0"

echo -----------------------------------------------------------
echo      Verilog Module Generator
echo -----------------------------------------------------------

:: Run PowerShell
set "PS_FILE=%TEMP%\create_mod_%RANDOM%.ps1"
set "MARKER=:POWERSHELL_SCRIPT_START"

for /f "tokens=1 delims=:" %%a in ('findstr /n "^%MARKER%" "%~f0"') do set "START_LINE=%%a"
more +%START_LINE% "%~f0" > "%PS_FILE%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_FILE%"

del "%PS_FILE%"
goto :eof

:POWERSHELL_SCRIPT_START
$srcDir = 'src';
if (-not (Test-Path $srcDir)) { New-Item -ItemType Directory -Path $srcDir | Out-Null }

Write-Host "Enter Module Name (e.g. MyCounter):" -ForegroundColor Cyan
$mName = Read-Host " >"

if ([string]::IsNullOrWhiteSpace($mName)) {
    Write-Host "Name cannot be empty." -ForegroundColor Red
    exit
}

$fileName = "$srcDir\$mName.v"
if (Test-Path $fileName) {
    Write-Host "File already exists!" -ForegroundColor Red
    exit
}

Write-Host "Enter Ports (format: name width, comma separated)" -ForegroundColor Cyan
Write-Host "Example: clk, rst, data_in [7:0], count_out [3:0]" -ForegroundColor Gray
$rawPorts = Read-Host " >"

# --- Parse Ports ---
$ports = @()

# Use regex to find "name" and optional "[width]"
# Patterns: "clk", "rst", "bus [7:0]"
# We split by comma first
$tokens = $rawPorts -split ','
foreach ($t in $tokens) {
    $t = $t.Trim()
    if ($t -eq "") { continue }
    
    $width = ""
    $name = $t
    
    # Check width
    if ($t -match '\[.*?\]') {
        $width = $matches[0]
        $name = $t.Replace($width, "").Trim()
    }
    
    # Guess Direction (Convention)
    $dir = "input"
    if ($name -match '^o_' -or $name -match '_out$') { $dir = "output" }
    elseif ($name -match 'inout') { $dir = "inout" }
    
    # Special: clk, rst are inputs
    if ($name -match 'clk' -or $name -match 'rst' -or $name -match 'reset') { $dir = "input" }

    # For output, usually we want 'output reg' if we use it in always block, 
    # but for safety let's stick to wire/reg separation or just output.
    # Let's use 'output reg' by default for convenience in always blocks? 
    # Actually 'output' is wire by default, but let's make it 'output'
    
    $ports += @{ Name=$name; Width=$width; Dir=$dir }
}

# --- Generate Code ---
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine('`timescale 1ns / 1ps')
[void]$sb.AppendLine('')
[void]$sb.AppendLine("module $mName (")

for ($i=0; $i -lt $ports.Count; $i++) {
    $p = $ports[$i]
    $comma = if ($i -lt $ports.Count - 1) { "," } else { "" }
    
    $decl = "    $($p.Dir)"
    if ($p.Dir -eq "output") { $decl += " reg" } # Make outputs reg for convenience
    if ($p.Width -ne "") { $decl += " $($p.Width)" }
    $decl += " $($p.Name)$comma"
    
    [void]$sb.AppendLine($decl)
}
[void]$sb.AppendLine(');')
[void]$sb.AppendLine('')
[void]$sb.AppendLine("    // Internal Signals")
[void]$sb.AppendLine('')
[void]$sb.AppendLine("    always @(posedge clk or posedge reset) begin")
[void]$sb.AppendLine("        if (reset) begin")
[void]$sb.AppendLine("            // Reset Logic")
foreach ($p in $ports) {
    if ($p.Dir -eq "output") {
         [void]$sb.AppendLine("            $($p.Name) <= 0;")
    }
}
[void]$sb.AppendLine("        end else begin")
[void]$sb.AppendLine("            // Main Logic")
[void]$sb.AppendLine("        end")
[void]$sb.AppendLine("    end")
[void]$sb.AppendLine('')
[void]$sb.AppendLine('endmodule')

Set-Content -Path $fileName -Value $sb.ToString()
Write-Host "Created: $fileName" -ForegroundColor Green

# Open in Editor
if (Get-Command "code" -ErrorAction SilentlyContinue) {
    code -r $fileName
} else {
    Invoke-Item $fileName
}
