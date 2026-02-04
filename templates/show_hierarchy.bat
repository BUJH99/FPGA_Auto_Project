@echo off
setlocal
cd /d "%~dp0"

echo -----------------------------------------------------------
echo      Verilog Hierarchy Visualizer
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

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_FILE%"

del "%PS_FILE%"
pause
goto :eof


:POWERSHELL_SCRIPT_START
# -------------------------------------------------------------------------
# PowerShell Script Content Below
# -------------------------------------------------------------------------
$srcDir = 'src';

# 1. Load all files and simple parse for Module Names
if (-not (Test-Path $srcDir)) {
    Write-Host "[Error] 'src' directory not found!" -ForegroundColor Red;
    exit;
}

$files = Get-ChildItem -Path $srcDir -Filter *.v;
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

# 4. Recursive Print Function
function Print-Hierarchy {
    param (
        [string]$moduleName,
        [string]$indent,
        [bool]$last
    )

    $fileName = $moduleFileMap[$moduleName];
    
    # Determine connector string - explicit if/else for PS 5.1 compat
    $connector = "+-- "
    if ($last) { 
        $connector = "\-- " 
    }
    
    # Print current node
    Write-Host ("{0}{1}{2} ({3})" -f $indent, $connector, $moduleName, $fileName) -ForegroundColor Green;

    $children = $dependencies[$moduleName];
    if ($children) {
        # Determine indent for children - explicit if/else
        $addIndent = "|   "
        if ($last) {
            $addIndent = "    "
        }
        $newIndent = $indent + $addIndent;
        
        for ($i=0; $i -lt $children.Count; $i++) {
            $isLastChild = ($i -eq $children.Count - 1);
            Print-Hierarchy -moduleName $children[$i] -indent $newIndent -last $isLastChild;
        }
    }
}

# 5. Output
Write-Host "`nProject Hierarchy:" -ForegroundColor Cyan;
Write-Host "==================" -ForegroundColor Cyan;

foreach ($root in $topModules) {
    if ($moduleMap.ContainsKey($root)) {
        Print-Hierarchy -moduleName $root -indent "" -last $true;
        Write-Host "";
    }
}
