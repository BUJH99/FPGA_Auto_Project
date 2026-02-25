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
cd /d "%TARGET_PROJECT%"

echo -----------------------------------------------------------
echo      HDL Hierarchy Visualizer (Verilog/SystemVerilog)
echo -----------------------------------------------------------

:: Check for src directory
if not exist "src" (
    echo [Error] 'src' directory not found!
    pause
    exit /b
)

:: -----------------------------------------------------------------
:: Robust Method: Extract the embedded PowerShell script to a temp file
:: -----------------------------------------------------------------
set "PS_FILE=%TEMP%\hierarchy_gen_%RANDOM%.ps1"
set "MARKER=:POWERSHELL_SCRIPT_START"

for /f "tokens=1 delims=:" %%a in ('findstr /n "^%MARKER%" "%~f0"') do set "START_LINE=%%a"
more +%START_LINE% "%~f0" > "%PS_FILE%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_FILE%" "%TARGET_PROJECT%" "%HDL_INDEXER%"

del "%PS_FILE%"
pause
goto :eof


:POWERSHELL_SCRIPT_START
# -------------------------------------------------------------------------
# PowerShell Script Content Below
# -------------------------------------------------------------------------
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$HdlIndexerPath = ""
)
$srcDir = 'src';

function Try-LoadHdlIndex {
    param(
        [string]$ProjectRoot,
        [string]$HdlIndexerPath
    )

    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { return $null }
    if ([string]::IsNullOrWhiteSpace($HdlIndexerPath)) { return $null }
    if (-not (Test-Path $HdlIndexerPath)) { return $null }

    try {
        $json = & node $HdlIndexerPath $ProjectRoot --pretty 2>$null
        if (-not $json) { return $null }
        return ($json -join "`n") | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Print-Hierarchy {
    param (
        [string]$moduleName,
        [string]$indent,
        [bool]$last,
        [hashtable]$moduleFileMap,
        [hashtable]$dependencies
    )

    $fileName = $moduleFileMap[$moduleName]
    $connector = "+-- "
    if ($last) { $connector = "\-- " }
    Write-Host ("{0}{1}{2} ({3})" -f $indent, $connector, $moduleName, $fileName) -ForegroundColor Green

    $children = $dependencies[$moduleName]
    if ($children) {
        $addIndent = "|   "
        if ($last) { $addIndent = "    " }
        $newIndent = $indent + $addIndent
        for ($i=0; $i -lt $children.Count; $i++) {
            $isLastChild = ($i -eq $children.Count - 1)
            Print-Hierarchy -moduleName $children[$i] -indent $newIndent -last $isLastChild -moduleFileMap $moduleFileMap -dependencies $dependencies
        }
    }
}

$hdlIndex = Try-LoadHdlIndex -ProjectRoot $ProjectRoot -HdlIndexerPath $HdlIndexerPath
if ($hdlIndex -and $hdlIndex.declarations -and $hdlIndex.graph) {
    $moduleFileMap = @{}
    foreach ($f in $hdlIndex.files) {
        foreach ($decl in $f.declarations) {
            if ($decl.type -eq "module" -and -not $moduleFileMap.ContainsKey($decl.name)) {
                $moduleFileMap[$decl.name] = [System.IO.Path]::GetFileName($f.path)
            }
        }
    }

    $dependencies = @{}
    foreach ($prop in $hdlIndex.graph.moduleInstances.PSObject.Properties) {
        $deps = @()
        foreach ($child in $prop.Value) { $deps += [string]$child }
        $dependencies[$prop.Name] = $deps
    }

    $usageCounts = @{}
    foreach ($m in $moduleFileMap.Keys) { $usageCounts[$m] = 0 }
    foreach ($parent in $dependencies.Keys) {
        foreach ($ch in $dependencies[$parent]) {
            if ($usageCounts.ContainsKey($ch)) { $usageCounts[$ch]++ }
        }
    }
    $topModules = @($usageCounts.Keys | Where-Object { $usageCounts[$_] -eq 0 } | Sort-Object)
    if ($topModules.Count -eq 0) { $topModules = @($moduleFileMap.Keys | Sort-Object) }
    elseif ($topModules -contains "Top") { $topModules = @("Top") }

    Write-Host "`nProject Hierarchy (AST/Indexer):" -ForegroundColor Cyan
    Write-Host "=============================" -ForegroundColor Cyan
    foreach ($root in $topModules) {
        if ($moduleFileMap.ContainsKey($root)) {
            Print-Hierarchy -moduleName $root -indent "" -last $true -moduleFileMap $moduleFileMap -dependencies $dependencies
            Write-Host ""
        }
    }

    $pkgNames = @()
    foreach ($n in $hdlIndex.declarations.packages) { $pkgNames += [string]$n }
    $ifNames = @()
    foreach ($n in $hdlIndex.declarations.interfaces) { $ifNames += [string]$n }
    if ($pkgNames.Count -gt 0 -or $ifNames.Count -gt 0) {
        Write-Host "SV Declarations:" -ForegroundColor Cyan
        Write-Host "================" -ForegroundColor Cyan
        if ($pkgNames.Count -gt 0) {
            Write-Host "Packages:" -ForegroundColor Yellow
            foreach ($p in ($pkgNames | Sort-Object)) { Write-Host ("  - " + $p) -ForegroundColor Gray }
        }
        if ($ifNames.Count -gt 0) {
            Write-Host "Interfaces:" -ForegroundColor Yellow
            foreach ($i in ($ifNames | Sort-Object)) { Write-Host ("  - " + $i) -ForegroundColor Gray }
        }
    }
    exit
}

# 1. Load all files and simple parse for Module Names
if (-not (Test-Path $srcDir)) {
    Write-Host "[Error] 'src' directory not found!" -ForegroundColor Red;
    exit;
}

$files = Get-ChildItem -Path $srcDir -Recurse -File | Where-Object { $_.Extension -in ".v", ".sv" } | Sort-Object FullName;
$moduleMap = @{}      # ModuleName -> FileContent
$moduleFileMap = @{}  # ModuleName -> FileName

foreach ($f in $files) {
    $content = Get-Content $f.FullName -Raw;
    # Clean comments (C-style /*...*/ and Verilog-style //...)
    $clean = $content -replace '(?s)/\*.*?\*/', '' -replace '//.*', '';
    
    # regex to find 'module Name'
    if ($clean -match '\bmodule\s+(\w+)') {
        $mName = $matches[1];
        $moduleMap[$mName] = $clean;
        $moduleFileMap[$mName] = $f.Name;
    }
}

# 2. Build Dependency Graph
$dependencies = @{}
$usageCounts = @{}

# Initialize usage counts
foreach ($m in $moduleMap.Keys) {
    if (-not $usageCounts.ContainsKey($m)) { $usageCounts[$m] = 0; }
}

foreach ($parent in $moduleMap.Keys) {
    $content = $moduleMap[$parent];
    $children = @();

    # Check for usage of other known modules inside this parent
    foreach ($candidate in $moduleMap.Keys) {
        if ($parent -eq $candidate) { continue; } 

        # Heuristic match
        if ($content -match "\b$candidate\b\s+(?:#[\s\S]*?)?(\w+)\s*\(") {
             $children += $candidate;
             $usageCounts[$candidate]++;
        }
    }
    $dependencies[$parent] = $children;
}

# 3. Find Top Module
$topModules = @();
foreach ($m in $usageCounts.Keys) {
    if ($usageCounts[$m] -eq 0) {
        $topModules += $m;
    }
}

if ($topModules.Count -eq 0) { 
    $topModules = $moduleMap.Keys; 
} 
elseif ($topModules.Contains("Top")) {
    $topModules = @("Top"); 
}

# 5. Output
Write-Host "`nProject Hierarchy:" -ForegroundColor Cyan;
Write-Host "==================" -ForegroundColor Cyan;

foreach ($root in $topModules) {
    if ($moduleMap.ContainsKey($root)) {
        Print-Hierarchy -moduleName $root -indent "" -last $true -moduleFileMap $moduleFileMap -dependencies $dependencies;
        Write-Host "";
    }
}
