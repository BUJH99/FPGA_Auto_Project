@echo off
setlocal
cd /d "%~dp0"

:: -----------------------------------------------------------------
:: Interactive Verilog Hierarchy Tool
:: -----------------------------------------------------------------
set "PS_FILE=%TEMP%\live_hierarchy_%RANDOM%.ps1"
set "MARKER=:POWERSHELL_SCRIPT_START"

for /f "tokens=1 delims=:" %%a in ('findstr /n "^%MARKER%" "%~f0"') do set "START_LINE=%%a"
more +%START_LINE% "%~f0" > "%PS_FILE%"

:: Run PowerShell
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_FILE%"

del "%PS_FILE%"
goto :eof


:POWERSHELL_SCRIPT_START
# -------------------------------------------------------------------------
# Interactive Verilog Viewer
# -------------------------------------------------------------------------
$Host.UI.RawUI.WindowTitle = "Verilog Project Navigator"
$srcDir = 'src';
$global:fileIndexMap = @{} # Index -> FullPath
$global:counter = 1

function Get-Hierarchy {
    # 1. Reset
    $global:fileIndexMap.Clear()
    $global:counter = 1
    
    # 2. Load files
    if (-not (Test-Path $srcDir)) {
        return @{ Error = "Source directory not found" }
    }
    
    $files = Get-ChildItem -Path $srcDir -Filter *.v;
    $moduleMap = @{}
    $moduleFileMap = @{}
    $modulePathMap = @{}

    foreach ($f in $files) {
        $content = Get-Content $f.FullName -Raw;
        $clean = $content -replace '(?s)/\*.*?\*/', '' -replace '//.*', '';
        if ($clean -match '\bmodule\s+(\w+)') {
            $mName = $matches[1];
            $moduleMap[$mName] = $clean;
            $moduleFileMap[$mName] = $f.Name;
            $modulePathMap[$mName] = $f.FullName;
        }
    }

    # 3. Build Graph
    $dependencies = @{}
    $usageCounts = @{}
    foreach ($m in $moduleMap.Keys) { if (-not $usageCounts[$m]) { $usageCounts[$m] = 0 } }

    foreach ($parent in $moduleMap.Keys) {
        $content = $moduleMap[$parent];
        $children = @();
        foreach ($candidate in $moduleMap.Keys) {
            if ($parent -eq $candidate) { continue; }
            if ($content -match "\b$candidate\b\s+(?:#[\s\S]*?)?(\w+)\s*\(") {
                 $children += $candidate;
                 $usageCounts[$candidate]++;
            }
        }
        $dependencies[$parent] = $children;
    }

    # 4. Find Top
    $topModules = @();
    foreach ($m in $usageCounts.Keys) { if ($usageCounts[$m] -eq 0) { $topModules += $m } }
    if ($topModules.Count -eq 0) { $topModules = $moduleMap.Keys }
    elseif ($topModules.Contains("Top")) { $topModules = @("Top") }

    return @{
        Top = $topModules;
        Deps = $dependencies;
        Files = $moduleFileMap;
        Paths = $modulePathMap;
    }
}

function Print-Node {
    param ($mName, $indent, $last, $data)
    
    $fName = $data.Files[$mName]
    $fPath = $data.Paths[$mName]
    
    # Register Index
    $idx = $global:counter
    $global:fileIndexMap[$idx] = $fPath
    $global:counter++

    # Connector
    $conn = "+-- "
    if ($last) { $conn = "\-- " }

    # Colorize
    Write-Host ("{0}{1}" -f $indent, $conn) -NoNewline -ForegroundColor DarkGray
    Write-Host ("[{0,2}] " -f $idx) -NoNewline -ForegroundColor Yellow
    Write-Host (" " + $mName) -NoNewline -ForegroundColor Cyan
    Write-Host (" ({0})" -f $fName) -ForegroundColor Gray

    # Children
    $children = $data.Deps[$mName]
    if ($children) {
        $addIndent = "|   "
        if ($last) { $addIndent = "    " }
        $newIndent = $indent + $addIndent
        
        for ($i=0; $i -lt $children.Count; $i++) {
            $isLast = ($i -eq $children.Count - 1)
            Print-Node -mName $children[$i] -indent $newIndent -last $isLast -data $data
        }
    }
}

# --- Main Loop ---
while ($true) {
    Clear-Host
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "   Verilog Project Navigator" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host " [Numbers] Open File  |  [ENTER] Refresh  |  [Q] Quit" -ForegroundColor White
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray

    $data = Get-Hierarchy
    if ($data.Error) {
        Write-Host $data.Error -ForegroundColor Red
    } else {
        if ($data.Top.Count -gt 0) {
            foreach ($root in $data.Top) {
                Print-Node -mName $root -indent "" -last $true -data $data
            }
        } else {
             Write-Host "No modules found."
        }
    }
    
    Write-Host ""
    $input = Read-Host " Command"
    
    if ($input -eq 'q' -or $input -eq 'Q') { break; }
    
    if ($input -match '^\d+$') {
        $idx = [int]$input
        if ($global:fileIndexMap.ContainsKey($idx)) {
            $path = $global:fileIndexMap[$idx]
            Write-Host " >> Opening: $path" -ForegroundColor Green
            try {
                # [Fix] Use Invoke-Item to rely on System Default Editor
                # This will open in your current editor IF the file type (.v) is associated with it.
                Invoke-Item $path
            } catch {
                Write-Host "Error opening file." -ForegroundColor Red
            }
            Start-Sleep -Milliseconds 200
        } else {
            Write-Host "Invalid Index." -ForegroundColor Red
            Start-Sleep -Milliseconds 500
        }
    }
}
