@echo off
setlocal
cd /d "%~dp0"

echo -----------------------------------------------------------
echo      Verilog Testbench Generator (Enhanced +)
echo -----------------------------------------------------------

:: Check for src directory
if not exist "src" (
    echo [Error] 'src' directory not found!
    echo Please make sure you are in the project root.
    pause
    exit /b
)

:: Create tb directory if needed
if not exist "tb" (
    mkdir "tb"
    echo [Info] Created 'tb' directory.
)

:: -----------------------------------------------------------------
:: Extract the embedded PowerShell script to a temporary file
:: -----------------------------------------------------------------
set "PS_FILE=%TEMP%\tb_gen_script_%RANDOM%.ps1"
set "MARKER=:POWERSHELL_SCRIPT_START"

:: Find the line number of the marker
for /f "tokens=1 delims=:" %%a in ('findstr /n "^%MARKER%" "%~f0"') do set "START_LINE=%%a"

:: Extract content after the marker
more +%START_LINE% "%~f0" > "%PS_FILE%"

:: Run the PowerShell script
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_FILE%"

:: Clean up
del "%PS_FILE%"
pause
goto :eof


:POWERSHELL_SCRIPT_START
$srcDir = 'src';
$tbDir = 'tb';

# 1. List Files
$files = Get-ChildItem -Path $srcDir -Filter *.v | Sort-Object Name;
if ($files.Count -eq 0) {
    Write-Host 'No .v files found in src directory.' -ForegroundColor Red;
    exit;
}

Write-Host 'Available Files:' -ForegroundColor Cyan;
for ($i=0; $i -lt $files.Count; $i++) {
    Write-Host ('[{0}] {1}' -f ($i+1), $files[$i].Name);
}

# 2. Select File
$selection = Read-Host 'Select file number';

# Validate Input
if ($selection -match '^\d+$' -and [int]$selection -ge 1 -and [int]$selection -le $files.Count) {
    $targetFile = $files[[int]$selection - 1];
    $targetPath = $targetFile.FullName;
    $moduleName = $targetFile.BaseName; 
    
    Write-Host ('Generating TB for: ' + $targetFile.Name) -ForegroundColor Green;

    # 3. Read and Parse File
    $content = Get-Content $targetPath -Raw;
    
    # Remove comments (Simple C-style and Verilog-style)
    $cleanContent = $content -replace '(?s)/\*.*?\*/', '' -replace '//.*', '';

    # Regular Expression to match Module definition
    # Captures: 1=ModuleName, 2=Parameters(Optional), 3=Ports
    if ($cleanContent -match 'module\s+(\w+)\s*(?:#\s*\(([\s\S]*?)\))?\s*\(([\s\S]*?)\)\s*;') {
        $moduleName = $matches[1];
        $paramBlock = $matches[2];
        $portBlock  = $matches[3];
        
        # --- Parse Parameters ---
        $params = @();
        if ($paramBlock) {
             # Split by comma
             $rawParams = $portBlock -split ',' 
             # Re-split param block specifically
             $rawParams = $paramBlock -split ',';
             foreach ($p in $rawParams) {
                 # Pattern: parameter NAME = VALUE or just NAME = VALUE
                 # We simply look for Assignment "Name = Value"
                 if ($p -match '(\w+)\s*=\s*(.*)') {
                     $pName = $matches[1];
                     $pValue = $matches[2].Trim();
                     $params += @{ Name=$pName; Value=$pValue };
                 }
             }
        }

        # --- Parse Ports ---
        $rawPorts = $portBlock -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' };

        $inputs = @();
        $outputs = @();
        
        foreach ($portDecl in $rawPorts) {
            # Setup defaults
            $dir = '';
            $width = '';
            $name = '';
            
            # Normalize spaces
            $p = $portDecl -replace '\s+', ' ';
            
            # Check Direction
            if ($p -match '\binput\b') { $dir = 'input'; }
            elseif ($p -match '\boutput\b') { $dir = 'output'; }
            elseif ($p -match '\binout\b') { $dir = 'inout'; }
            
            # Check Width [n:m]
            if ($p -match '\[.*?\]') {
                $width = $matches[0];
                $p = $p.Replace($width, '');
            }
            
            # Extract Name
            if ($p -match '(\w+)$') {
                $name = $matches[1];
            }

            if ($name -ne '') {
                if ($dir -eq 'input') {
                    $inputs += @{ Name=$name; Width=$width };
                } elseif ($dir -eq 'output') {
                    $outputs += @{ Name=$name; Width=$width };
                } elseif ($dir -eq 'inout') {
                    $outputs += @{ Name=$name; Width=$width }; 
                }
            }
        }

        # 4. Generate TB Content
        $tbFile = Join-Path $tbDir ('tb_' + $targetFile.Name);
        $sb = [System.Text.StringBuilder]::new();

        [void]$sb.AppendLine('`timescale 1ns / 1ps');
        [void]$sb.AppendLine('');
        [void]$sb.AppendLine('module tb_' + $moduleName + ';');
        [void]$sb.AppendLine('');

        # --- Parameters ---
        if ($params.Count -gt 0) {
            [void]$sb.AppendLine('    // Parameters');
            foreach ($param in $params) {
                [void]$sb.AppendLine('    localparam ' + $param.Name + ' = ' + $param.Value + ';');
            }
            [void]$sb.AppendLine('');
        }

        [void]$sb.AppendLine('    // Inputs');
        foreach ($inp in $inputs) {
            $decl = if ($inp.Width -ne '') { "    reg " + $inp.Width + " " + $inp.Name + ";" } else { "    reg " + $inp.Name + ";" };
            [void]$sb.AppendLine($decl);
        }
        [void]$sb.AppendLine('');
        [void]$sb.AppendLine('    // Outputs');
        foreach ($outp in $outputs) {
             $decl = if ($outp.Width -ne '') { "    wire " + $outp.Width + " " + $outp.Name + ";" } else { "    wire " + $outp.Name + ";" };
             [void]$sb.AppendLine($decl);
        }
        [void]$sb.AppendLine('');

        [void]$sb.AppendLine('    // Instantiate the Unit Under Test (UUT)');
        [void]$sb.Append('    ' + $moduleName);
        
        # Add Parameter Instantiation if exists
        if ($params.Count -gt 0) {
            [void]$sb.Append(' #(');
            for ($i=0; $i -lt $params.Count; $i++) {
                 $comma = if ($i -lt $params.Count - 1) { ',' } else { '' };
                 [void]$sb.Append('.' + $params[$i].Name + '(' + $params[$i].Name + ')' + $comma);
            }
            [void]$sb.Append(')');
        }

        [void]$sb.AppendLine(' uut (');
        
        $allPorts = $inputs + $outputs;
        for ($k=0; $k -lt $allPorts.Count; $k++) {
            $pName = $allPorts[$k].Name;
            $comma = if ($k -lt $allPorts.Count - 1) { ',' } else { '' };
            [void]$sb.AppendLine('        .' + $pName + '(' + $pName + ')' + $comma);
        }
        [void]$sb.AppendLine('    );');
        [void]$sb.AppendLine('');

        # Clock Generation
        foreach ($inp in $inputs) {
            if ($inp.Name -match 'clk' -or $inp.Name -match 'clock') {
                [void]$sb.AppendLine('    // Clock generation');
                [void]$sb.AppendLine('    initial begin');
                [void]$sb.AppendLine('        ' + $inp.Name + ' = 0;');
                [void]$sb.AppendLine('        forever #5 ' + $inp.Name + ' = ~' + $inp.Name + '; // 100MHz equivalent');
                [void]$sb.AppendLine('    end');
                [void]$sb.AppendLine('');
            }
        }

        # Initial Block for Stimulus & Monitor & Dump
        [void]$sb.AppendLine('    initial begin');
        [void]$sb.AppendLine('        $dumpfile("tb_' + $moduleName + '.vcd");');
        [void]$sb.AppendLine('        $dumpvars(0, tb_' + $moduleName + ');');
        [void]$sb.AppendLine('        ');
        
        # Build Monitor String
        $monStr = 'Time: %t';
        $monVars = '$time';
        $cnt = 0;
        foreach ($p in ($inputs + $outputs)) {
             if ($cnt -lt 5) { # Limit to first 5 signals to avoid massive lines
                 $monStr += ' | ' + $p.Name + ': %h';
                 $monVars += ', ' + $p.Name;
                 $cnt++;
             }
        }
        [void]$sb.AppendLine('        $monitor("' + $monStr + '", ' + $monVars + ');');
        [void]$sb.AppendLine('');
        [void]$sb.AppendLine('        // Initialize Inputs');
        foreach ($inp in $inputs) {
            if ($inp.Name -notmatch 'clk' -and $inp.Name -notmatch 'clock') {
                [void]$sb.AppendLine('        ' + $inp.Name + ' = 0;');
            }
        }
        [void]$sb.AppendLine('');
        [void]$sb.AppendLine('        // Wait 100 ns for global reset to finish');
        [void]$sb.AppendLine('        #100;');
        
        # Reset Logic
        foreach ($inp in $inputs) {
            if ($inp.Name -match 'reset' -or $inp.Name -match 'rst') {
                    [void]$sb.AppendLine('        // Reset Pulse');
                    [void]$sb.AppendLine('        ' + $inp.Name + ' = 1;');
                    [void]$sb.AppendLine('        #20;');
                    [void]$sb.AppendLine('        ' + $inp.Name + ' = 0;');
            }
        }
        
        [void]$sb.AppendLine('        // TODO: Add more stimulus here');
        [void]$sb.AppendLine('        #1000;');
        [void]$sb.AppendLine('        $finish;');
        [void]$sb.AppendLine('    end');
        [void]$sb.AppendLine('');
        [void]$sb.AppendLine('endmodule');

        # Write File
        Set-Content -Path $tbFile -Value $sb.ToString();
        Write-Host ('Successfully created: ' + $tbFile) -ForegroundColor Yellow;

        # Open in IDE
        Write-Host "Opening file..." -ForegroundColor Cyan
        try { Invoke-Item $tbFile } catch { }

    } else {
        Write-Host 'Could not parse module definition or ports.' -ForegroundColor Red;
    }

} else {
    Write-Host 'Invalid selection.' -ForegroundColor Red;
}
