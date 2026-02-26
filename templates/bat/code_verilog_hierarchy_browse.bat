@echo off
setlocal

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^> [--once] [--include-tb]
    pause
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
set "HDL_INDEXER=%~dp0..\tools\hdl_indexer.js"
set "BROWSE_ONCE=0"
set "INCLUDE_TB=0"

for %%A in ("%~2" "%~3" "%~4" "%~5" "%~6" "%~7" "%~8" "%~9") do (
    if /i "%%~A"=="--once" set "BROWSE_ONCE=1"
    if /i "%%~A"=="--include-tb" set "INCLUDE_TB=1"
)

cd /d "%TARGET_PROJECT%"

:: -----------------------------------------------------------------
:: Interactive Verilog/SystemVerilog Hierarchy Tool
:: -----------------------------------------------------------------
set "PS_FILE=%TEMP%\live_hierarchy_%RANDOM%.ps1"
set "MARKER=:POWERSHELL_SCRIPT_START"

for /f "tokens=1 delims=:" %%a in ('findstr /n "^%MARKER%" "%~f0"') do set "START_LINE=%%a"
more +%START_LINE% "%~f0" > "%PS_FILE%"

:: Run PowerShell
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_FILE%" "%TARGET_PROJECT%" "%HDL_INDEXER%" "%BROWSE_ONCE%" "%INCLUDE_TB%"

del "%PS_FILE%"
goto :eof


:POWERSHELL_SCRIPT_START
# -------------------------------------------------------------------------
# Interactive HDL Viewer (Verilog/SystemVerilog)
# -------------------------------------------------------------------------
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$HdlIndexerPath = "",
    [string]$BrowseOnce = "0",
    [string]$IncludeTb = "0"
)
$Host.UI.RawUI.WindowTitle = "HDL Project Navigator"
$srcDir = 'src'
$tbDir = 'tb'
$global:fileIndexMap = @{} # Index -> FullPath
$global:counter = 1

function New-DeclGroups {
    return @{
        Packages   = @()
        Interfaces = @()
        Programs   = @()
        Classes    = @()
        Checkers   = @()
    }
}

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

function Convert-IndexToHierarchyData {
    param(
        $IndexObj,
        [bool]$IncludeTb
    )

    $moduleMap = @{}
    $moduleFileMap = @{}
    $modulePathMap = @{}
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
                if (-not $modulePathMap.ContainsKey($dName)) { $modulePathMap[$dName] = $fullPath }
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
        Paths   = $modulePathMap
        SvDecls = $declGroups
        Indexer = $true
    }
}

function Get-Hierarchy {
    # 1. Reset
    $global:fileIndexMap.Clear()
    $global:counter = 1

    # 2. Source dir check
    if (-not (Test-Path $srcDir)) {
        return @{ Error = "Source directory not found" }
    }

    $includeTbEnabled = ($IncludeTb -eq "1")

    $idx = Try-LoadHdlIndex -ProjectRoot $ProjectRoot -HdlIndexerPath $HdlIndexerPath
    if ($idx -and $idx.files) {
        return (Convert-IndexToHierarchyData -IndexObj $idx -IncludeTb:$includeTbEnabled)
    }

    $searchRoots = @($srcDir)
    if ($includeTbEnabled -and (Test-Path $tbDir)) {
        $searchRoots += $tbDir
    }

    $files = @(
        foreach ($root in $searchRoots) {
            Get-ChildItem -Path $root -Recurse -File | Where-Object { $_.Extension -in ".v", ".sv", ".svh" }
        }
    ) | Sort-Object FullName

    $moduleMap = @{}
    $moduleFileMap = @{}
    $modulePathMap = @{}
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
            if (-not $modulePathMap.ContainsKey($mName)) { $modulePathMap[$mName] = $f.FullName }
        }

        foreach ($declType in $declRegexMap.Keys) {
            foreach ($declMatch in $declRegexMap[$declType].Matches($clean)) {
                $declName = [string]$declMatch.Groups[1].Value
                Add-DeclItem -DeclGroups $declGroups -FirstDeclPath $firstDeclPath -DeclType $declType -DeclName $declName -DeclPath $f.FullName
            }
        }
    }

    # 3. Build Graph
    $dependencies = @{}
    $usageCounts = @{}
    foreach ($m in $moduleMap.Keys) { $usageCounts[$m] = 0 }

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
        Paths   = $modulePathMap
        SvDecls = $declGroups
        Indexer = $false
    }
}

function Print-Node {
    param (
        $mName,
        $indent,
        $last,
        $data,
        $pathSet = $null
    )

    if (-not $pathSet) { $pathSet = @{} }
    if ($pathSet.ContainsKey($mName)) {
        $conn = "+-- "
        if ($last) { $conn = "\-- " }
        Write-Host ("{0}{1}" -f $indent, $conn) -NoNewline -ForegroundColor DarkGray
        Write-Host (" [cycle] " + $mName) -ForegroundColor Red
        return
    }

    $nextPathSet = @{}
    foreach ($k in $pathSet.Keys) { $nextPathSet[$k] = $true }
    $nextPathSet[$mName] = $true

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

        for ($i = 0; $i -lt $children.Count; $i++) {
            $isLast = ($i -eq $children.Count - 1)
            Print-Node -mName $children[$i] -indent $newIndent -last $isLast -data $data -pathSet $nextPathSet
        }
    }
}

function Print-SvDeclGroup {
    param(
        [string]$Keyword,
        [array]$Items
    )

    foreach ($entry in (@($Items) | Sort-Object Name)) {
        $idx = $global:counter
        $global:fileIndexMap[$idx] = $entry.Path
        $global:counter++
        Write-Host (" +-- ") -NoNewline -ForegroundColor DarkGray
        Write-Host ("[{0,2}] " -f $idx) -NoNewline -ForegroundColor Yellow
        Write-Host (" " + $Keyword + " " + $entry.Name) -ForegroundColor Magenta
    }
}

function Print-SvDeclList {
    param($data)

    if (-not $data.SvDecls) { return }
    $pkgs = @($data.SvDecls.Packages)
    $ifs = @($data.SvDecls.Interfaces)
    $progs = @($data.SvDecls.Programs)
    $classes = @($data.SvDecls.Classes)
    $checkers = @($data.SvDecls.Checkers)
    if (
        $pkgs.Count -eq 0 -and
        $ifs.Count -eq 0 -and
        $progs.Count -eq 0 -and
        $classes.Count -eq 0 -and
        $checkers.Count -eq 0
    ) { return }

    Write-Host ""
    Write-Host " [SV Declarations]" -ForegroundColor Yellow
    Print-SvDeclGroup -Keyword "package" -Items $pkgs
    Print-SvDeclGroup -Keyword "interface" -Items $ifs
    Print-SvDeclGroup -Keyword "program" -Items $progs
    Print-SvDeclGroup -Keyword "class" -Items $classes
    Print-SvDeclGroup -Keyword "checker" -Items $checkers
}

# --- Main Loop ---
while ($true) {
    Clear-Host
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "   HDL Project Navigator (Verilog/SystemVerilog)" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host " [Numbers] Open File  |  [ENTER] Refresh  |  [Q] Quit" -ForegroundColor White
    if ($IncludeTb -eq "1") {
        Write-Host " [Scope] src + tb (--include-tb)" -ForegroundColor DarkGray
    } else {
        Write-Host " [Scope] src only (tb hidden)" -ForegroundColor DarkGray
    }
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
        } else {
            Write-Host "No modules found."
        }
        Print-SvDeclList -data $data
    }

    Write-Host ""
    if ($BrowseOnce -eq "1") { break }

    $input = Read-Host " Command"

    if ($input -eq 'q' -or $input -eq 'Q') { break }

    if ($input -match '^\d+$') {
        $idx = [int]$input
        if ($global:fileIndexMap.ContainsKey($idx)) {
            $path = $global:fileIndexMap[$idx]
            Write-Host " >> Opening: $path" -ForegroundColor Green
            try {
                # Open with system-associated editor for this extension.
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
