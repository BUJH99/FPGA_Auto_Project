@echo off
setlocal

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^>
    pause
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
set "HDL_INDEXER=%~dp0..\tools\hdl_indexer.js"
set "BROWSE_ONCE=0"
if /i "%~2"=="--once" set "BROWSE_ONCE=1"
if /i "%~3"=="--once" set "BROWSE_ONCE=1"
cd /d "%TARGET_PROJECT%"

:: -----------------------------------------------------------------
:: Interactive Verilog Hierarchy Tool
:: -----------------------------------------------------------------
set "PS_FILE=%TEMP%\live_hierarchy_%RANDOM%.ps1"
set "MARKER=:POWERSHELL_SCRIPT_START"

for /f "tokens=1 delims=:" %%a in ('findstr /n "^%MARKER%" "%~f0"') do set "START_LINE=%%a"
more +%START_LINE% "%~f0" > "%PS_FILE%"

:: Run PowerShell
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_FILE%" "%TARGET_PROJECT%" "%HDL_INDEXER%" "%BROWSE_ONCE%"

del "%PS_FILE%"
goto :eof


:POWERSHELL_SCRIPT_START
# -------------------------------------------------------------------------
# Interactive HDL Viewer (Verilog/SystemVerilog)
# -------------------------------------------------------------------------
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$HdlIndexerPath = "",
    [string]$BrowseOnce = "0"
)
$Host.UI.RawUI.WindowTitle = "HDL Project Navigator"
$srcDir = 'src';
$global:fileIndexMap = @{} # Index -> FullPath
$global:counter = 1

function Try-LoadHdlIndex {
    param(
        [string]$ProjectRoot,
        [string]$HdlIndexerPath
    )
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { return $null }
    if ([string]::IsNullOrWhiteSpace($HdlIndexerPath) -or -not (Test-Path $HdlIndexerPath)) { return $null }
    try {
        $json = & node $HdlIndexerPath $ProjectRoot --pretty 2>$null
        if (-not $json) { return $null }
        return ($json -join "`n") | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Convert-IndexToHierarchyData {
    param($IndexObj)

    $moduleMap = @{}
    $moduleFileMap = @{}
    $modulePathMap = @{}
    $declGroups = @{ Packages=@(); Interfaces=@() }
    $firstDeclPath = @{}

    foreach ($f in $IndexObj.files) {
        foreach ($decl in $f.declarations) {
            $dType = [string]$decl.type
            $dName = [string]$decl.name
            if (-not $firstDeclPath.ContainsKey("$dType::$dName")) {
                $firstDeclPath["$dType::$dName"] = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $f.path))
            }
            if ($dType -eq "module") {
                if (-not $moduleMap.ContainsKey($dName)) { $moduleMap[$dName] = "" }
                if (-not $moduleFileMap.ContainsKey($dName)) { $moduleFileMap[$dName] = [System.IO.Path]::GetFileName($f.path) }
                if (-not $modulePathMap.ContainsKey($dName)) { $modulePathMap[$dName] = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $f.path)) }
            } elseif ($dType -eq "package") {
                $declGroups.Packages += [pscustomobject]@{ Name = $dName; Path = $firstDeclPath["$dType::$dName"] }
            } elseif ($dType -eq "interface") {
                $declGroups.Interfaces += [pscustomobject]@{ Name = $dName; Path = $firstDeclPath["$dType::$dName"] }
            }
        }
    }

    $dependencies = @{}
    $usageCounts = @{}
    foreach ($m in $moduleMap.Keys) { $usageCounts[$m] = 0 }
    foreach ($prop in $IndexObj.graph.moduleInstances.PSObject.Properties) {
        $deps = @()
        foreach ($child in $prop.Value) {
            $deps += [string]$child
            if ($usageCounts.ContainsKey([string]$child)) { $usageCounts[[string]$child]++ }
        }
        $dependencies[$prop.Name] = $deps
    }
    foreach ($m in $moduleMap.Keys) {
        if (-not $dependencies.ContainsKey($m)) { $dependencies[$m] = @() }
    }

    $topModules = @($usageCounts.Keys | Where-Object { $usageCounts[$_] -eq 0 } | Sort-Object)
    if ($topModules.Count -eq 0) { $topModules = @($moduleMap.Keys | Sort-Object) }
    elseif ($topModules -contains "Top") { $topModules = @("Top") }

    return @{
        Top   = $topModules
        Deps  = $dependencies
        Files = $moduleFileMap
        Paths = $modulePathMap
        SvDecls = $declGroups
        Indexer = $true
    }
}

function Get-Hierarchy {
    # 1. Reset
    $global:fileIndexMap.Clear()
    $global:counter = 1
    
    # 2. Load files
    if (-not (Test-Path $srcDir)) {
        return @{ Error = "Source directory not found" }
    }
    
    $idx = Try-LoadHdlIndex -ProjectRoot $ProjectRoot -HdlIndexerPath $HdlIndexerPath
    if ($idx -and $idx.files) {
        return (Convert-IndexToHierarchyData -IndexObj $idx)
    }

    $files = Get-ChildItem -Path $srcDir -Recurse -File | Where-Object { $_.Extension -in ".v", ".sv" } | Sort-Object FullName;
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
        SvDecls = @{ Packages=@(); Interfaces=@() };
        Indexer = $false;
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

function Print-SvDeclList {
    param($data)

    if (-not $data.SvDecls) { return }
    $pkgs = @($data.SvDecls.Packages)
    $ifs  = @($data.SvDecls.Interfaces)
    if ($pkgs.Count -eq 0 -and $ifs.Count -eq 0) { return }

    Write-Host ""
    Write-Host " [SV Declarations]" -ForegroundColor Yellow

    foreach ($pkg in $pkgs) {
        $idx = $global:counter
        $global:fileIndexMap[$idx] = $pkg.Path
        $global:counter++
        Write-Host (" +-- ") -NoNewline -ForegroundColor DarkGray
        Write-Host ("[{0,2}] " -f $idx) -NoNewline -ForegroundColor Yellow
        Write-Host (" package " + $pkg.Name) -ForegroundColor Magenta
    }
    foreach ($ifc in $ifs) {
        $idx = $global:counter
        $global:fileIndexMap[$idx] = $ifc.Path
        $global:counter++
        Write-Host (" +-- ") -NoNewline -ForegroundColor DarkGray
        Write-Host ("[{0,2}] " -f $idx) -NoNewline -ForegroundColor Yellow
        Write-Host (" interface " + $ifc.Name) -ForegroundColor Magenta
    }
}

# --- Main Loop ---
while ($true) {
    Clear-Host
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "   HDL Project Navigator (Verilog/SystemVerilog)" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host " [Numbers] Open File  |  [ENTER] Refresh  |  [Q] Quit" -ForegroundColor White
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray

    $data = Get-Hierarchy
    if ($data.Error) {
        Write-Host $data.Error -ForegroundColor Red
    } else {
        if ($data.Indexer) {
            Write-Host " [Indexer] hdl_indexer.js active" -ForegroundColor DarkGray
            Write-Host ""
        }
        if ($data.Top.Count -gt 0) {
            foreach ($root in $data.Top) {
                Print-Node -mName $root -indent "" -last $true -data $data
            }
            Print-SvDeclList -data $data
        } else {
             Write-Host "No modules found."
        }
    }
    
    Write-Host ""
    if ($BrowseOnce -eq "1") { break }

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
