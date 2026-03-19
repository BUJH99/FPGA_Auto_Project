@echo off
setlocal EnableDelayedExpansion
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
set "CONSOLE_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\console_ui.bat"

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^> [--hdl-ext v^|sv]
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
set "MANIFEST_CTX=%TEMPLATES_ROOT%\shared\adapters\bat\bootstrap_manifest_context.bat"
set "HDL_EXT=v"
set "ARG2=%~2"
if /i "%~2"=="--hdl-ext" (
    if /i "%~3"=="sv" set "HDL_EXT=sv"
    if /i "%~3"=="v" set "HDL_EXT=v"
) else if /i "!ARG2:~0,10!"=="--hdl-ext=" (
    set "HDL_EXT=!ARG2:~10!"
)
if /i not "%HDL_EXT%"=="v" if /i not "%HDL_EXT%"=="sv" set "HDL_EXT=v"

call "%MANIFEST_CTX%" "%TARGET_PROJECT%"
if errorlevel 1 (
    echo [ERROR] Manifest context initialization failed.
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

cd /d "%TARGET_PROJECT%"
echo Target Project: %TARGET_PROJECT%

echo -----------------------------------------------------------
echo      HDL Module Generator (Verilog/SystemVerilog)
echo -----------------------------------------------------------

:: Run PowerShell
set "PS_FILE=%TEMP%\create_mod_%RANDOM%.ps1"
set "CREATED_FILE_MARKER=%TEMP%\created_module_%RANDOM%_%RANDOM%.txt"
set "MARKER=:POWERSHELL_SCRIPT_START"
if exist "%CREATED_FILE_MARKER%" del /q "%CREATED_FILE_MARKER%" >nul 2>nul

for /f "tokens=1 delims=:" %%a in ('findstr /n "^%MARKER%" "%~f0"') do set "START_LINE=%%a"
more +%START_LINE% "%~f0" > "%PS_FILE%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_FILE%" "%HDL_EXT%" "%CREATED_FILE_MARKER%"
set "PS_RC=%errorlevel%"

del "%PS_FILE%"
if %PS_RC% neq 0 exit /b %PS_RC%

call :warn_manifest_glob_miss
if exist "%CREATED_FILE_MARKER%" del /q "%CREATED_FILE_MARKER%" >nul 2>nul
goto :eof

:warn_manifest_glob_miss
set "CREATED_FILE="
for /f "usebackq delims=" %%F in ("%CREATED_FILE_MARKER%") do (
    if not defined CREATED_FILE set "CREATED_FILE=%%~fF"
)
if not defined CREATED_FILE exit /b 0

call "%MANIFEST_CTX%" "%TARGET_PROJECT%" >nul
if errorlevel 1 exit /b 0

set "IN_MANIFEST=0"
for /f "usebackq delims=" %%R in ("%MANIFEST_SRC_LIST%") do (
    if not "%%R"=="" (
        set "REL=%%R"
        set "REL_WIN=!REL:/=\!"
        for %%A in ("%TARGET_PROJECT%\!REL_WIN!") do (
            if /i "%%~fA"=="%CREATED_FILE%" set "IN_MANIFEST=1"
        )
    )
)

if "%IN_MANIFEST%"=="0" (
    echo [WARNING] Generated file is not matched by hdl.src_globs.
    echo [WARNING] Update fpga_auto.yml if this file should be part of the build.
)
exit /b 0

:POWERSHELL_SCRIPT_START
param(
    [string]$HdlExt = "v",
    [string]$CreatedPathFile = ""
)
$srcDir = 'src';
if (-not (Test-Path $srcDir)) { New-Item -ItemType Directory -Path $srcDir | Out-Null }
if ($HdlExt -notin @("v", "sv")) { $HdlExt = "v" }

Write-Host "Enter Module Name (e.g. MyCounter):" -ForegroundColor Cyan
$mName = Read-Host " >"
$mName = $mName.Trim()

if ([string]::IsNullOrWhiteSpace($mName)) {
    Write-Host "Name cannot be empty." -ForegroundColor Red
    exit
}

$fileName = "$srcDir\$mName.$HdlExt"
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
    if ($name -match '(?i)^io[A-Z0-9_]' -or $name -match '(?i)\binout\b') { $dir = "inout" }
    elseif ($name -match '(?i)^o[A-Z0-9_]' -or $name -match '(?i)^o_' -or $name -match '(?i)_out$') { $dir = "output" }
    elseif ($name -match '(?i)^i[A-Z0-9_]') { $dir = "input" }
    
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
[void]$sb.AppendLine('/*')
[void]$sb.AppendLine('[MODULE_INFO_START]')
[void]$sb.AppendLine("Name: $mName")
[void]$sb.AppendLine("Role: RTL module implementing $mName")
[void]$sb.AppendLine('Summary:')
[void]$sb.AppendLine('  - Generated by code_verilog_module_generate.bat')
[void]$sb.AppendLine('  - Fill behavior/FSM description before review')
[void]$sb.AppendLine('[MODULE_INFO_END]')
[void]$sb.AppendLine('*/')
[void]$sb.AppendLine('')
[void]$sb.AppendLine("module $mName (")

for ($i=0; $i -lt $ports.Count; $i++) {
    $p = $ports[$i]
    $comma = if ($i -lt $ports.Count - 1) { "," } else { "" }
    
    $decl = "    $($p.Dir)"
    if ($HdlExt -eq "sv") {
        if ($p.Dir -eq "inout") {
            $decl += " wire"
        } else {
            $decl += " logic"
        }
    } else {
        if ($p.Dir -eq "output") { $decl += " reg" } # Make outputs reg for convenience
    }
    if ($p.Width -ne "") { $decl += " $($p.Width)" }
    $decl += " $($p.Name)$comma"
    
    [void]$sb.AppendLine($decl)
}
[void]$sb.AppendLine(');')
[void]$sb.AppendLine('')
[void]$sb.AppendLine("    // Internal Signals")
[void]$sb.AppendLine('')

$clockPort = $null
$resetPort = $null
$isActiveLowReset = $false
foreach ($p in $ports) {
    if ($p.Dir -eq "input" -and -not $clockPort -and ($p.Name -match '(?i)(^i?clk$|clock|clk_|^iClk)')) {
        $clockPort = $p.Name
    }
    if ($p.Dir -eq "input" -and -not $resetPort -and ($p.Name -match '(?i)(^i?rst|reset|rstn$|iRstn$)')) {
        $resetPort = $p.Name
        # Check for active-low reset pattern (ends with 'n' like iRstn, rstn)
        if ($p.Name -match '(?i)n$') {
            $isActiveLowReset = $true
        }
    }
}

if ($clockPort) {
    if ($resetPort) {
        if ($isActiveLowReset) {
            # Active-low reset (iRstn style)
            if ($HdlExt -eq "sv") {
                [void]$sb.AppendLine("    always_ff @(posedge $clockPort or negedge $resetPort) begin")
            } else {
                [void]$sb.AppendLine("    always @(posedge $clockPort or negedge $resetPort) begin")
            }
            [void]$sb.AppendLine("        if (!$resetPort) begin")
        } else {
            # Active-high reset (iRst style)
            if ($HdlExt -eq "sv") {
                [void]$sb.AppendLine("    always_ff @(posedge $clockPort or posedge $resetPort) begin")
            } else {
                [void]$sb.AppendLine("    always @(posedge $clockPort or posedge $resetPort) begin")
            }
            [void]$sb.AppendLine("        if ($resetPort) begin")
        }
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
    } else {
        if ($HdlExt -eq "sv") {
            [void]$sb.AppendLine("    always_ff @(posedge $clockPort) begin")
        } else {
            [void]$sb.AppendLine("    always @(posedge $clockPort) begin")
        }
        [void]$sb.AppendLine("        // Sequential Logic")
        [void]$sb.AppendLine("    end")
    }
} else {
    if ($HdlExt -eq "sv") {
        [void]$sb.AppendLine("    always_comb begin")
    } else {
        [void]$sb.AppendLine("    always @* begin")
    }
    foreach ($p in $ports) {
        if ($p.Dir -eq "output") {
            [void]$sb.AppendLine("        $($p.Name) = 0;")
        }
    }
    [void]$sb.AppendLine("        // Combinational Logic")
    [void]$sb.AppendLine("    end")
}
[void]$sb.AppendLine('')
[void]$sb.AppendLine('endmodule')

Set-Content -Path $fileName -Value $sb.ToString()
if (-not [string]::IsNullOrWhiteSpace($CreatedPathFile)) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($CreatedPathFile, (Resolve-Path $fileName).Path, $enc)
}
Write-Host "Created: $fileName" -ForegroundColor Green

# Open in Editor
if (Get-Command "code" -ErrorAction SilentlyContinue) {
    code -r $fileName
} else {
    Invoke-Item $fileName
}
