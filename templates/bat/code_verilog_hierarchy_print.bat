@echo off
setlocal

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^> [--include-tb]
    pause
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
set "HDL_INDEXER=%~dp0..\tools\hdl_indexer.js"
set "INCLUDE_TB=0"
for %%A in ("%~2" "%~3" "%~4" "%~5" "%~6" "%~7" "%~8" "%~9") do (
    if /i "%%~A"=="--include-tb" set "INCLUDE_TB=1"
)
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
:: Extract embedded PowerShell script to temp file
:: -----------------------------------------------------------------
set "PS_FILE=%TEMP%\hierarchy_gen_%RANDOM%.ps1"
set "MARKER=:POWERSHELL_SCRIPT_START"

for /f "tokens=1 delims=:" %%a in ('findstr /n "^%MARKER%" "%~f0"') do set "START_LINE=%%a"
more +%START_LINE% "%~f0" > "%PS_FILE%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_FILE%" "%TARGET_PROJECT%" "%HDL_INDEXER%" "%INCLUDE_TB%"

del "%PS_FILE%"
pause
goto :eof


:POWERSHELL_SCRIPT_START
# -------------------------------------------------------------------------
# PowerShell Script Content Below
# -------------------------------------------------------------------------
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$HdlIndexerPath = "",
    [string]$IncludeTb = "0"
)
$srcDir = 'src'
$tbDir = 'tb'
$includeTbEnabled = ($IncludeTb -eq "1")

function New-DeclGroups {
    return @{
        Packages   = @()
        Interfaces = @()
        Programs   = @()
        Classes    = @()
        Checkers   = @()
    }
}

function Add-DeclItem {
    param(
        [hashtable]$DeclGroups,
        [hashtable]$FirstDeclPath,
        [string]$DeclType,
        [string]$DeclName,
        [string]$DeclPath
    )

    $key = "$DeclType::$DeclName"
    if ($FirstDeclPath.ContainsKey($key)) { return }
    $FirstDeclPath[$key] = $DeclPath

    $item = [pscustomobject]@{
        Name = $DeclName
        Path = $DeclPath
    }

    switch ($DeclType) {
        "package"   { $DeclGroups.Packages += $item }
        "interface" { $DeclGroups.Interfaces += $item }
        "program"   { $DeclGroups.Programs += $item }
        "class"     { $DeclGroups.Classes += $item }
        "checker"   { $DeclGroups.Checkers += $item }
    }
}

function Select-TopModules {
    param(
        [hashtable]$UsageCounts,
        [array]$ModuleNames
    )

    $topModules = @($UsageCounts.Keys | Where-Object { $UsageCounts[$_] -eq 0 } | Sort-Object)
    if ($topModules.Count -eq 0) {
        $topModules = @($ModuleNames | Sort-Object)
    }

    $preferredTop = @($topModules | Where-Object { $_ -ieq "Top" })
    if ($preferredTop.Count -gt 0) {
        return @($preferredTop[0])
    }
    return $topModules
}

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
        [hashtable]$dependencies,
        [hashtable]$pathSet = $null
    )

    if (-not $pathSet) { $pathSet = @{} }
    if ($pathSet.ContainsKey($moduleName)) {
        $connector = "+-- "
        if ($last) { $connector = "\-- " }
        Write-Host ("{0}{1}[cycle] {2}" -f $indent, $connector, $moduleName) -ForegroundColor Red
        return
    }

    $nextPathSet = @{}
    foreach ($k in $pathSet.Keys) { $nextPathSet[$k] = $true }
    $nextPathSet[$moduleName] = $true

    $fileName = $moduleFileMap[$moduleName]
    $connector = "+-- "
    if ($last) { $connector = "\-- " }
    Write-Host ("{0}{1}{2} ({3})" -f $indent, $connector, $moduleName, $fileName) -ForegroundColor Green

    $children = $dependencies[$moduleName]
    if ($children) {
        $addIndent = "|   "
        if ($last) { $addIndent = "    " }
        $newIndent = $indent + $addIndent
        for ($i = 0; $i -lt $children.Count; $i++) {
            $isLastChild = ($i -eq $children.Count - 1)
            Print-Hierarchy -moduleName $children[$i] -indent $newIndent -last $isLastChild -moduleFileMap $moduleFileMap -dependencies $dependencies -pathSet $nextPathSet
        }
    }
}

function Convert-IndexToHierarchyData {
    param(
        $IndexObj,
        [bool]$IncludeTb
    )

    $moduleMap = @{}
    $moduleFileMap = @{}
    $declGroups = New-DeclGroups
    $firstDeclPath = @{}

    foreach ($f in $IndexObj.files) {
        $role = [string]$f.role
        if (-not $IncludeTb -and $role -eq "tb") { continue }

        $fullPath = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $f.path))
        foreach ($decl in $f.declarations) {
            $dType = [string]$decl.type
            $dName = [string]$decl.name

            if ($dType -eq "module") {
                if (-not $moduleMap.ContainsKey($dName)) { $moduleMap[$dName] = "" }
                if (-not $moduleFileMap.ContainsKey($dName)) { $moduleFileMap[$dName] = [System.IO.Path]::GetFileName($f.path) }
                continue
            }

            Add-DeclItem -DeclGroups $declGroups -FirstDeclPath $firstDeclPath -DeclType $dType -DeclName $dName -DeclPath $fullPath
        }
    }

    $dependencies = @{}
    $usageCounts = @{}
    foreach ($m in $moduleMap.Keys) { $usageCounts[$m] = 0 }

    if ($IndexObj.graph -and $IndexObj.graph.moduleInstances) {
        foreach ($prop in $IndexObj.graph.moduleInstances.PSObject.Properties) {
            $parent = [string]$prop.Name
            if (-not $moduleMap.ContainsKey($parent)) { continue }

            $deps = @()
            foreach ($child in $prop.Value) {
                $childName = [string]$child
                if (-not $moduleMap.ContainsKey($childName)) { continue }
                if ($childName -eq $parent) { continue }
                if ($deps -contains $childName) { continue }
                $deps += $childName
                $usageCounts[$childName]++
            }
            $dependencies[$parent] = $deps
        }
    }

    foreach ($m in $moduleMap.Keys) {
        if (-not $dependencies.ContainsKey($m)) { $dependencies[$m] = @() }
    }

    $topModules = Select-TopModules -UsageCounts $usageCounts -ModuleNames @($moduleMap.Keys)

    return @{
        Top     = $topModules
        Deps    = $dependencies
        Files   = $moduleFileMap
        SvDecls = $declGroups
        Indexer = $true
    }
}

function Build-FallbackHierarchyData {
    param([bool]$IncludeTb)

    $searchRoots = @($srcDir)
    if ($IncludeTb -and (Test-Path $tbDir)) {
        $searchRoots += $tbDir
    }

    $files = @(
        foreach ($root in $searchRoots) {
            Get-ChildItem -Path $root -Recurse -File | Where-Object { $_.Extension -in ".v", ".sv", ".svh" }
        }
    ) | Sort-Object FullName

    $moduleMap = @{}      # ModuleName -> FileContent
    $moduleFileMap = @{}  # ModuleName -> FileName
    $declGroups = New-DeclGroups
    $firstDeclPath = @{}

    $moduleDeclRegex = [regex]'(?im)\bmodule\s+(?:automatic\s+|static\s+)?([A-Za-z_][A-Za-z0-9_$]*)\b'
    $declRegexMap = @{
        package   = [regex]'(?im)\bpackage\s+([A-Za-z_][A-Za-z0-9_$]*)\b'
        interface = [regex]'(?im)\binterface\s+([A-Za-z_][A-Za-z0-9_$]*)\b'
        program   = [regex]'(?im)\bprogram\s+(?:automatic\s+|static\s+)?([A-Za-z_][A-Za-z0-9_$]*)\b'
        class     = [regex]'(?im)\bclass\s+(?:automatic\s+|static\s+)?([A-Za-z_][A-Za-z0-9_$]*)\b'
        checker   = [regex]'(?im)\bchecker\s+([A-Za-z_][A-Za-z0-9_$]*)\b'
    }

    foreach ($f in $files) {
        $content = Get-Content $f.FullName -Raw
        $clean = $content -replace '(?s)/\*.*?\*/', '' -replace '//.*', ''

        foreach ($match in $moduleDeclRegex.Matches($clean)) {
            $mName = [string]$match.Groups[1].Value
            if (-not $moduleMap.ContainsKey($mName)) { $moduleMap[$mName] = $clean }
            if (-not $moduleFileMap.ContainsKey($mName)) { $moduleFileMap[$mName] = $f.Name }
        }

        foreach ($declType in $declRegexMap.Keys) {
            foreach ($declMatch in $declRegexMap[$declType].Matches($clean)) {
                $declName = [string]$declMatch.Groups[1].Value
                Add-DeclItem -DeclGroups $declGroups -FirstDeclPath $firstDeclPath -DeclType $declType -DeclName $declName -DeclPath $f.FullName
            }
        }
    }

    # Build dependency graph
    $dependencies = @{}
    $usageCounts = @{}
    foreach ($m in $moduleMap.Keys) {
        $usageCounts[$m] = 0
    }

    foreach ($parent in $moduleMap.Keys) {
        $content = $moduleMap[$parent]
        $children = @()

        foreach ($candidate in $moduleMap.Keys) {
            if ($parent -eq $candidate) { continue }
            $escapedCandidate = [regex]::Escape($candidate)
            if ($content -match "\b$escapedCandidate\b\s*(?:#\s*\([\s\S]*?\)\s*)?([A-Za-z_][A-Za-z0-9_$]*)\s*\(") {
                if ($children -contains $candidate) { continue }
                $children += $candidate
                $usageCounts[$candidate]++
            }
        }
        $dependencies[$parent] = $children
    }

    $topModules = Select-TopModules -UsageCounts $usageCounts -ModuleNames @($moduleMap.Keys)

    return @{
        Top     = $topModules
        Deps    = $dependencies
        Files   = $moduleFileMap
        SvDecls = $declGroups
        Indexer = $false
    }
}

function Print-SvDeclarations {
    param($declGroups)

    $pkgs = @($declGroups.Packages)
    $ifs = @($declGroups.Interfaces)
    $progs = @($declGroups.Programs)
    $classes = @($declGroups.Classes)
    $checkers = @($declGroups.Checkers)

    if (
        $pkgs.Count -eq 0 -and
        $ifs.Count -eq 0 -and
        $progs.Count -eq 0 -and
        $classes.Count -eq 0 -and
        $checkers.Count -eq 0
    ) { return }

    Write-Host "SV Declarations:" -ForegroundColor Cyan
    Write-Host "================" -ForegroundColor Cyan
    if ($pkgs.Count -gt 0) {
        Write-Host "Packages:" -ForegroundColor Yellow
        foreach ($p in ($pkgs | Sort-Object Name)) { Write-Host ("  - " + $p.Name) -ForegroundColor Gray }
    }
    if ($ifs.Count -gt 0) {
        Write-Host "Interfaces:" -ForegroundColor Yellow
        foreach ($i in ($ifs | Sort-Object Name)) { Write-Host ("  - " + $i.Name) -ForegroundColor Gray }
    }
    if ($progs.Count -gt 0) {
        Write-Host "Programs:" -ForegroundColor Yellow
        foreach ($p in ($progs | Sort-Object Name)) { Write-Host ("  - " + $p.Name) -ForegroundColor Gray }
    }
    if ($classes.Count -gt 0) {
        Write-Host "Classes:" -ForegroundColor Yellow
        foreach ($c in ($classes | Sort-Object Name)) { Write-Host ("  - " + $c.Name) -ForegroundColor Gray }
    }
    if ($checkers.Count -gt 0) {
        Write-Host "Checkers:" -ForegroundColor Yellow
        foreach ($c in ($checkers | Sort-Object Name)) { Write-Host ("  - " + $c.Name) -ForegroundColor Gray }
    }
}

$scopeText = "src only (tb hidden)"
if ($includeTbEnabled) { $scopeText = "src + tb (--include-tb)" }
Write-Host ("[Scope] " + $scopeText) -ForegroundColor DarkGray

$hdlIndex = Try-LoadHdlIndex -ProjectRoot $ProjectRoot -HdlIndexerPath $HdlIndexerPath
if ($hdlIndex -and $hdlIndex.declarations -and $hdlIndex.graph) {
    $data = Convert-IndexToHierarchyData -IndexObj $hdlIndex -IncludeTb:$includeTbEnabled

    Write-Host "`nProject Hierarchy (AST/Indexer):" -ForegroundColor Cyan
    Write-Host "=============================" -ForegroundColor Cyan
    foreach ($root in $data.Top) {
        if ($data.Files.ContainsKey($root)) {
            Print-Hierarchy -moduleName $root -indent "" -last $true -moduleFileMap $data.Files -dependencies $data.Deps
            Write-Host ""
        }
    }
    if ($data.Top.Count -eq 0) {
        Write-Host "No modules found." -ForegroundColor Red
        Write-Host ""
    }
    Print-SvDeclarations -declGroups $data.SvDecls
    exit
}

if (-not (Test-Path $srcDir)) {
    Write-Host "[Error] 'src' directory not found!" -ForegroundColor Red
    exit
}

$fallback = Build-FallbackHierarchyData -IncludeTb:$includeTbEnabled

Write-Host "`nProject Hierarchy:" -ForegroundColor Cyan
Write-Host "==================" -ForegroundColor Cyan

foreach ($root in $fallback.Top) {
    if ($fallback.Files.ContainsKey($root)) {
        Print-Hierarchy -moduleName $root -indent "" -last $true -moduleFileMap $fallback.Files -dependencies $fallback.Deps
        Write-Host ""
    }
}

if ($fallback.Top.Count -eq 0) {
    Write-Host "No modules found." -ForegroundColor Red
    Write-Host ""
}

Print-SvDeclarations -declGroups $fallback.SvDecls
