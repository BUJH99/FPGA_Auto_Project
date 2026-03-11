@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^> [--once] [--include-tb ^| --tb-only]
    pause
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
set "HDL_INDEXER=%TEMPLATES_ROOT%\contexts\code_intel\adapters\cli\code_index_hdl_cli.js"
set "SUMMARY_WRITER=%TEMPLATES_ROOT%\contexts\code_intel\adapters\cli\code_write_hierarchy_summary_cli.js"
set "MANIFEST_CTX=%TEMPLATES_ROOT%\shared\adapters\bat\bootstrap_manifest_context.bat"
set "BROWSE_ONCE=0"
set "INCLUDE_TB=0"
set "TB_ONLY=0"
set "SCOPE_SPECIFIED=0"

for %%A in ("%~2" "%~3" "%~4" "%~5" "%~6" "%~7" "%~8" "%~9") do (
    if /i "%%~A"=="--once" set "BROWSE_ONCE=1"
    if /i "%%~A"=="--include-tb" (
        set "INCLUDE_TB=1"
        set "SCOPE_SPECIFIED=1"
    )
    if /i "%%~A"=="--tb-only" (
        set "INCLUDE_TB=1"
        set "TB_ONLY=1"
        set "SCOPE_SPECIFIED=1"
    )
)

if exist "%MANIFEST_CTX%" (
    call "%MANIFEST_CTX%" "%TARGET_PROJECT%"
    if errorlevel 1 (
        echo [ERROR] Manifest context initialization failed.
        pause
        exit /b 1
    )
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
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_FILE%" "%TARGET_PROJECT%" "%HDL_INDEXER%" "%BROWSE_ONCE%" "%INCLUDE_TB%" "%TB_ONLY%" "%SCOPE_SPECIFIED%" "%SUMMARY_WRITER%" "%MANIFEST_JSON%"
set "PS_RC=%errorlevel%"

del "%PS_FILE%"
exit /b %PS_RC%


:POWERSHELL_SCRIPT_START
# -------------------------------------------------------------------------
# Interactive HDL Viewer (Verilog/SystemVerilog)
# -------------------------------------------------------------------------
param(
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$HdlIndexerPath = "",
    [string]$BrowseOnce = "0",
    [string]$IncludeTb = "0",
    [string]$TbOnly = "0",
    [string]$ScopeSpecified = "0",
    [string]$SummaryWriterPath = "",
    [string]$ManifestJsonPath = ""
)
$Host.UI.RawUI.WindowTitle = "HDL Project Navigator"
$srcDir = 'src'
$tbDir = 'tb'
$global:fileIndexMap = @{} # Index -> Target metadata
$global:fileTextCache = @{} # Path -> comment-stripped text
$global:declLineCache = @{} # type::name::path -> line number
$global:antigravityCommand = Get-Command antigravity -ErrorAction SilentlyContinue
$global:counter = 1
$selectedTbFolderKey = ""
$selectedTbFolderDisplay = ""
$userCancelRc = 99
$quitRequested = $false
$runStartedAt = (Get-Date).ToString("o")

$hierarchyLogDir = Join-Path $ProjectRoot "log\hierarchy"
New-Item -Path $hierarchyLogDir -ItemType Directory -Force | Out-Null
$hierarchyLogFile = Join-Path $hierarchyLogDir ("hierarchy_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss_fff"))
$hierarchyTranscriptActive = $false

function Get-HierarchyScopeName {
    if ($TbOnly -eq "1") { return "tb_only" }
    if ($IncludeTb -eq "1") { return "include_tb" }
    return "src"
}

function Invoke-HierarchySummaryWriter {
    param(
        [Parameter(Mandatory = $true)][string]$Status
    )

    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { return }
    if ([string]::IsNullOrWhiteSpace($SummaryWriterPath) -or -not (Test-Path $SummaryWriterPath)) { return }

    $writerArgs = @(
        $SummaryWriterPath,
        "--project-root", $ProjectRoot,
        "--status", $Status,
        "--log-path", $hierarchyLogFile,
        "--scope", (Get-HierarchyScopeName),
        "--started-at", $runStartedAt,
        "--finished-at", (Get-Date).ToString("o")
    )

    if (-not [string]::IsNullOrWhiteSpace($ManifestJsonPath)) {
        $writerArgs += @("--manifest-json", $ManifestJsonPath)
    }
    if (-not [string]::IsNullOrWhiteSpace($selectedTbFolderDisplay)) {
        $writerArgs += @("--tb-folder", $selectedTbFolderDisplay)
    }

    & node @writerArgs
    $writerRc = $LASTEXITCODE
    if ($writerRc -ne 0) {
        Write-Host ("[WARN] Failed to update hierarchy run summary (rc={0})." -f $writerRc) -ForegroundColor DarkYellow
    }
}

if ($BrowseOnce -ne "1" -and $ScopeSpecified -ne "1") {
    Write-Host ""
    Write-Host "[Hierarchy Scope]" -ForegroundColor Yellow
    Write-Host "  [1] src only (tb hidden)"
    Write-Host "  [3] tb only"
    $scopeSel = Read-Host " Select scope (1 or 3, default 1)"
    $scopeSel = [string]$scopeSel
    $scopeSel = $scopeSel.Trim().Trim('"', "'")
    switch ($scopeSel.ToLowerInvariant()) {
        "3" {
            $IncludeTb = "1"
            $TbOnly = "1"
        }
        "1" {
            $IncludeTb = "0"
            $TbOnly = "0"
        }
        "src" {
            $IncludeTb = "0"
            $TbOnly = "0"
        }
        "tb" {
            $IncludeTb = "1"
            $TbOnly = "1"
        }
        "tb-only" {
            $IncludeTb = "1"
            $TbOnly = "1"
        }
        "tbonly" {
            $IncludeTb = "1"
            $TbOnly = "1"
        }
        "q" {
            Invoke-HierarchySummaryWriter -Status "cancelled"
            exit $userCancelRc
        }
        "quit" {
            Invoke-HierarchySummaryWriter -Status "cancelled"
            exit $userCancelRc
        }
        "cancel" {
            Invoke-HierarchySummaryWriter -Status "cancelled"
            exit $userCancelRc
        }
        "" {
            $IncludeTb = "0"
            $TbOnly = "0"
        }
        default {
            Write-Host " [WARN] Invalid scope '$scopeSel'. Using default: src only." -ForegroundColor DarkYellow
            $IncludeTb = "0"
            $TbOnly = "0"
        }
    }
}

Write-Host ("[INFO] Hierarchy logs    : {0}" -f $hierarchyLogDir)
Write-Host ("[INFO] Hierarchy log file: {0}" -f $hierarchyLogFile)
try {
    Start-Transcript -Path $hierarchyLogFile -Force | Out-Null
    $hierarchyTranscriptActive = $true
    Write-Host ("[INFO] Hierarchy log file: {0}" -f $hierarchyLogFile)
} catch {
    Write-Host ("[WARN] Failed to start hierarchy transcript: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
}

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
        Type = $DeclType
        Line = (Get-DeclLine -DeclType $DeclType -DeclName $DeclName -DeclPath $DeclPath)
    }

    switch ($DeclType) {
        "package"   { $DeclGroups.Packages += $item }
        "interface" { $DeclGroups.Interfaces += $item }
        "program"   { $DeclGroups.Programs += $item }
        "class"     { $DeclGroups.Classes += $item }
        "checker"   { $DeclGroups.Checkers += $item }
    }
}

function Get-DeclRegex {
    param([string]$DeclType)
    switch ($DeclType) {
        "module"    { return [regex]'(?im)\bmodule\s+(?:automatic\s+|static\s+)?([A-Za-z_][A-Za-z0-9_$]*)\b' }
        "package"   { return [regex]'(?im)\bpackage\s+([A-Za-z_][A-Za-z0-9_$]*)\b' }
        "interface" { return [regex]'(?im)\binterface\s+([A-Za-z_][A-Za-z0-9_$]*)\b' }
        "program"   { return [regex]'(?im)\bprogram\s+(?:automatic\s+|static\s+)?([A-Za-z_][A-Za-z0-9_$]*)\b' }
        "class"     { return [regex]'(?im)\bclass\s+(?:automatic\s+|static\s+)?([A-Za-z_][A-Za-z0-9_$]*)\b' }
        "checker"   { return [regex]'(?im)\bchecker\s+([A-Za-z_][A-Za-z0-9_$]*)\b' }
        default     { return $null }
    }
}

function Get-FileTextStrippedCached {
    param([string]$Path)
    if ($global:fileTextCache.ContainsKey($Path)) {
        return [string]$global:fileTextCache[$Path]
    }
    if (-not (Test-Path $Path)) { return "" }
    try {
        $raw = Get-Content -Path $Path -Raw
        $clean = [regex]::Replace($raw, "/\*[\s\S]*?\*/", {
            param($m)
            return ($m.Value -replace "[^\r\n]", " ")
        })
        $clean = [regex]::Replace($clean, "//.*$", "", [System.Text.RegularExpressions.RegexOptions]::Multiline)
        $global:fileTextCache[$Path] = $clean
        return $clean
    } catch {
        return ""
    }
}

function Get-DeclLine {
    param(
        [string]$DeclType,
        [string]$DeclName,
        [string]$DeclPath
    )

    $cacheKey = "$DeclType::$DeclName::$DeclPath"
    if ($global:declLineCache.ContainsKey($cacheKey)) {
        return [int]$global:declLineCache[$cacheKey]
    }

    $re = Get-DeclRegex -DeclType $DeclType
    if (-not $re) {
        $global:declLineCache[$cacheKey] = 0
        return 0
    }

    $text = Get-FileTextStrippedCached -Path $DeclPath
    if ([string]::IsNullOrEmpty($text)) {
        $global:declLineCache[$cacheKey] = 0
        return 0
    }

    foreach ($m in $re.Matches($text)) {
        if ([string]$m.Groups[1].Value -ceq $DeclName) {
            $line = [regex]::Matches($text.Substring(0, $m.Index), "`n").Count + 1
            $global:declLineCache[$cacheKey] = $line
            return $line
        }
    }

    $global:declLineCache[$cacheKey] = 0
    return 0
}

function Open-IndexedTarget {
    param($Target)

    if (-not $Target) { return }

    $path = ""
    $line = 0

    if ($Target -is [string]) {
        $path = $Target
    } else {
        $path = [string]$Target.Path
        if ($Target.PSObject.Properties.Name -contains "Line") {
            $line = [int]$Target.Line
        }
    }

    if ([string]::IsNullOrWhiteSpace($path)) {
        Write-Host "Error opening file." -ForegroundColor Red
        return
    }

    if (-not (Test-Path $path)) {
        Write-Host "Error opening file: path not found." -ForegroundColor Red
        return
    }

    if ($global:antigravityCommand) {
        if ($line -gt 0) {
            Write-Host (" >> Opening declaration in Antigravity: {0}:{1}" -f $path, $line) -ForegroundColor Green
            try {
                & $global:antigravityCommand.Source -r -g "$path`:$line" | Out-Null
                return
            } catch {
                Write-Host " >> Antigravity goto failed. Using file open fallback." -ForegroundColor DarkYellow
            }
        } else {
            Write-Host (" >> Opening file in Antigravity: {0}" -f $path) -ForegroundColor Green
            try {
                & $global:antigravityCommand.Source -r "$path" | Out-Null
                return
            } catch {
                Write-Host " >> Antigravity open failed. Using file open fallback." -ForegroundColor DarkYellow
            }
        }
    } elseif ($line -gt 0) {
        Write-Host (" >> Antigravity not found. Opening file fallback: {0}" -f $path) -ForegroundColor DarkYellow
        try {
            Invoke-Item $path
            return
        } catch {}
    }

    if ($line -gt 0) {
        Write-Host (" >> Opening declaration (fallback): {0}:{1}" -f $path, $line) -ForegroundColor Green
    } else {
        Write-Host (" >> Opening file (fallback): {0}" -f $path) -ForegroundColor Green
    }
    try {
        Invoke-Item $path
    } catch {
        Write-Host "Error opening file." -ForegroundColor Red
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

function Get-DisplayRelativePath {
    param(
        [string]$BasePath,
        [string]$TargetPath
    )

    try {
        if ([string]::IsNullOrWhiteSpace($TargetPath)) { return $TargetPath }
        $baseFull = [System.IO.Path]::GetFullPath($BasePath)
        $targetFull = [System.IO.Path]::GetFullPath($TargetPath)

        if ($targetFull.StartsWith($baseFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rel = $targetFull.Substring($baseFull.Length).TrimStart('\', '/')
            if (-not [string]::IsNullOrWhiteSpace($rel)) {
                return $rel.Replace('\', '/')
            }
        }

        $baseUri = New-Object System.Uri(($baseFull.TrimEnd('\', '/') + '\'))
        $targetUri = New-Object System.Uri($targetFull)
        $relativeUri = $baseUri.MakeRelativeUri($targetUri)
        return [System.Uri]::UnescapeDataString($relativeUri.ToString()).Replace('\', '/')
    } catch {
        return $TargetPath
    }
}

function Get-IndexedFileScope {
    param(
        [string]$Role,
        [string]$RelPath
    )

    $normPath = [string]$RelPath
    if (-not [string]::IsNullOrWhiteSpace($normPath)) {
        $normPath = $normPath.Replace('\', '/')
        $normPath = $normPath.TrimStart('.').TrimStart('/')

        if ($normPath -imatch '^tb(?:/|$)') { return "tb" }
        if ($normPath -imatch '^src(?:/|$)') { return "src" }
        if ($normPath -imatch '^include(?:/|$)') { return "shared" }
        if ($normPath -imatch '^inc(?:/|$)') { return "shared" }
    }

    if ($Role -eq "tb") { return "tb" }
    if ($Role -eq "rtl") { return "src" }
    return "shared"
}

function Should-IncludeIndexedFile {
    param(
        [string]$FileScope,
        [bool]$IncludeTb,
        [bool]$TbOnly
    )

    if ($TbOnly) {
        return $FileScope -in @("tb", "shared")
    }
    if ($IncludeTb) {
        return $true
    }
    return $FileScope -in @("src", "shared")
}

function New-BrowseTarget {
    param(
        [string]$Path,
        [int]$Line = 0,
        [string]$Kind,
        [string]$Label,
        [string]$FolderKey = ""
    )

    $idx = $global:counter
    $global:fileIndexMap[$idx] = [pscustomobject]@{
        Path      = $Path
        Line      = $Line
        Kind      = $Kind
        Label     = $Label
        FolderKey = $FolderKey
    }
    $global:counter++
    return $idx
}

function Get-TbFolderKeyFromRelativePath {
    param([string]$RelPath)

    $norm = [string]$RelPath
    if ([string]::IsNullOrWhiteSpace($norm)) { return "" }
    $norm = $norm.Replace('\', '/')
    $norm = [regex]::Replace($norm, '^[./]+', '')
    if ($norm -notmatch '^tb(?:/|$)') { return "" }

    $parts = @($norm -split '/')
    if ($parts.Count -lt 2 -or [string]::IsNullOrWhiteSpace($parts[1])) {
        return "tb"
    }

    return ("tb/" + $parts[1])
}

function New-TbFolderEntry {
    param([string]$FolderKey)

    $folderRelWin = $FolderKey.Replace('/', '\')
    return [pscustomobject]@{
        Key     = $FolderKey
        Display = $FolderKey
        Leaf    = (Split-Path -Path $folderRelWin -Leaf)
        Path    = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $folderRelWin))
    }
}

function Add-TbFolderEntry {
    param(
        [hashtable]$FolderMap,
        [string]$FolderKey
    )

    if ([string]::IsNullOrWhiteSpace($FolderKey)) { return }
    if ($FolderMap.ContainsKey($FolderKey)) { return }
    $FolderMap[$FolderKey] = New-TbFolderEntry -FolderKey $FolderKey
}

function Get-TbFolderEntriesFromIndex {
    param($IndexObj)

    $folderMap = @{}
    foreach ($f in $IndexObj.files) {
        $scope = Get-IndexedFileScope -Role ([string]$f.role) -RelPath ([string]$f.path)
        if ($scope -ne "tb") { continue }
        Add-TbFolderEntry -FolderMap $folderMap -FolderKey (Get-TbFolderKeyFromRelativePath -RelPath ([string]$f.path))
    }

    return @($folderMap.Values | Sort-Object Display)
}

function Get-TbFolderEntriesFallback {
    $folderMap = @{}
    if (-not (Test-Path $tbDir)) { return @() }

    $tbFiles = @(
        Get-ChildItem -Path $tbDir -Recurse -File |
            Where-Object { $_.Extension -in ".v", ".sv" }
    ) | Sort-Object FullName

    foreach ($tbFile in $tbFiles) {
        $relPath = Get-DisplayRelativePath -BasePath $ProjectRoot -TargetPath $tbFile.FullName
        Add-TbFolderEntry -FolderMap $folderMap -FolderKey (Get-TbFolderKeyFromRelativePath -RelPath $relPath)
    }

    return @($folderMap.Values | Sort-Object Display)
}

function Add-RtlModuleEntry {
    param(
        [hashtable]$ModuleMap,
        [string]$ModuleName,
        [string]$ModulePath,
        [string]$RelPath
    )

    if ([string]::IsNullOrWhiteSpace($ModuleName)) { return }
    if ([string]::IsNullOrWhiteSpace($ModulePath)) { return }
    if ($ModuleMap.ContainsKey($ModuleName)) { return }

    $ModuleMap[$ModuleName] = [pscustomobject]@{
        Name    = $ModuleName
        Path    = $ModulePath
        RelPath = ([string]$RelPath).Replace('\', '/')
        Line    = (Get-DeclLine -DeclType "module" -DeclName $ModuleName -DeclPath $ModulePath)
    }
}

function Get-RtlModuleCatalogFromIndex {
    param($IndexObj)

    $moduleMap = @{}
    foreach ($f in $IndexObj.files) {
        $scope = Get-IndexedFileScope -Role ([string]$f.role) -RelPath ([string]$f.path)
        if ($scope -ne "src") { continue }

        $fullPath = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot ([string]$f.path)))
        foreach ($decl in $f.declarations) {
            if ([string]$decl.type -ne "module") { continue }
            Add-RtlModuleEntry -ModuleMap $moduleMap -ModuleName ([string]$decl.name) -ModulePath $fullPath -RelPath ([string]$f.path)
        }
    }

    return $moduleMap
}

function Get-RtlModuleCatalogFallback {
    $moduleMap = @{}
    if (-not (Test-Path $srcDir)) { return $moduleMap }

    $srcFiles = @(
        Get-ChildItem -Path $srcDir -Recurse -File |
            Where-Object { $_.Extension -in ".v", ".sv", ".svh" }
    ) | Sort-Object FullName

    $moduleRegex = Get-DeclRegex -DeclType "module"
    foreach ($srcFile in $srcFiles) {
        $text = Get-FileTextStrippedCached -Path $srcFile.FullName
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $relPath = Get-DisplayRelativePath -BasePath $ProjectRoot -TargetPath $srcFile.FullName

        foreach ($match in $moduleRegex.Matches($text)) {
            Add-RtlModuleEntry -ModuleMap $moduleMap -ModuleName ([string]$match.Groups[1].Value) -ModulePath $srcFile.FullName -RelPath $relPath
        }
    }

    return $moduleMap
}

function Get-TbOnlyHierarchyData {
    param($IndexObj = $null)

    if ($IndexObj -and $IndexObj.files) {
        return @{
            TbFolders  = @(Get-TbFolderEntriesFromIndex -IndexObj $IndexObj)
            RtlModules = (Get-RtlModuleCatalogFromIndex -IndexObj $IndexObj)
            Indexer    = $true
            TbOnly     = $true
        }
    }

    return @{
        TbFolders  = @(Get-TbFolderEntriesFallback)
        RtlModules = (Get-RtlModuleCatalogFallback)
        Indexer    = $false
        TbOnly     = $true
    }
}

function Get-TbFolderSourceFiles {
    param(
        [string]$FolderPath,
        [bool]$Recursive = $false
    )

    if ([string]::IsNullOrWhiteSpace($FolderPath) -or -not (Test-Path $FolderPath)) {
        return @()
    }

    if ($Recursive) {
        return @(
            Get-ChildItem -Path $FolderPath -Recurse -File |
                Where-Object { $_.Extension -in ".v", ".sv" }
        ) | Sort-Object FullName
    }

    return @(
        Get-ChildItem -Path $FolderPath -File |
            Where-Object { $_.Extension -in ".v", ".sv" }
    ) | Sort-Object FullName
}

function Get-TbTopEntriesForFolder {
    param([string]$FolderPath)

    $sourceFiles = @(Get-TbFolderSourceFiles -FolderPath $FolderPath -Recursive:$false)
    if ($sourceFiles.Count -eq 0) {
        $sourceFiles = @(Get-TbFolderSourceFiles -FolderPath $FolderPath -Recursive:$true)
    }

    $topEntries = @()
    foreach ($sourceFile in $sourceFiles) {
        $text = Get-FileTextStrippedCached -Path $sourceFile.FullName
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        $matches = @()
        foreach ($declType in @("module", "program")) {
            $re = Get-DeclRegex -DeclType $declType
            foreach ($match in $re.Matches($text)) {
                $matches += [pscustomobject]@{
                    Type   = $declType
                    Name   = [string]$match.Groups[1].Value
                    Offset = [int]$match.Index
                    Line   = [regex]::Matches($text.Substring(0, $match.Index), "`n").Count + 1
                }
            }
        }

        foreach ($entry in @($matches | Sort-Object Offset, Type, Name)) {
            $topEntries += [pscustomobject]@{
                Type    = $entry.Type
                Name    = $entry.Name
                Path    = $sourceFile.FullName
                RelPath = Get-DisplayRelativePath -BasePath $ProjectRoot -TargetPath $sourceFile.FullName
                Line    = [int]$entry.Line
            }
        }
    }

    return @($topEntries | Sort-Object RelPath, Line, Name)
}

function Get-DeclBlockText {
    param(
        [string]$DeclType,
        [string]$DeclName,
        [string]$DeclPath
    )

    $text = Get-FileTextStrippedCached -Path $DeclPath
    if ([string]::IsNullOrWhiteSpace($text)) { return "" }

    $escapedName = [regex]::Escape($DeclName)
    $pattern = ""
    switch ($DeclType) {
        "module"  { $pattern = "(?ims)\bmodule\s+(?:automatic\s+|static\s+)?$escapedName\b[\s\S]*?\bendmodule\b" }
        "program" { $pattern = "(?ims)\bprogram\s+(?:automatic\s+|static\s+)?$escapedName\b[\s\S]*?\bendprogram\b" }
        default   { return $text }
    }

    $match = [regex]::Match($text, $pattern)
    if ($match.Success) {
        return [string]$match.Value
    }

    return $text
}

function Get-DirectDutEntriesForTop {
    param(
        $TopEntry,
        [hashtable]$RtlModules
    )

    if (-not $TopEntry -or -not $RtlModules -or $RtlModules.Count -eq 0) {
        return @()
    }

    $blockText = Get-DeclBlockText -DeclType ([string]$TopEntry.Type) -DeclName ([string]$TopEntry.Name) -DeclPath ([string]$TopEntry.Path)
    if ([string]::IsNullOrWhiteSpace($blockText)) { return @() }

    $children = @()
    $seen = @{}
    foreach ($moduleName in @($RtlModules.Keys | Sort-Object)) {
        $escapedName = [regex]::Escape($moduleName)
        $pattern = "\b$escapedName\b\s*(?:#\s*\([\s\S]*?\)\s*)?([A-Za-z_][A-Za-z0-9_$]*)\s*\("
        if (-not [regex]::IsMatch($blockText, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            continue
        }

        if ($seen.ContainsKey($moduleName)) { continue }
        $seen[$moduleName] = $true
        $children += $RtlModules[$moduleName]
    }

    return @($children | Sort-Object Name)
}

function Get-TbFolderSvDeclarations {
    param([string]$FolderPath)

    if ([string]::IsNullOrWhiteSpace($FolderPath) -or -not (Test-Path $FolderPath)) {
        return @()
    }

    $declEntries = @()
    $declTypes = @("package", "interface", "program", "class", "checker")
    $svFiles = @(
        Get-ChildItem -Path $FolderPath -Recurse -File |
            Where-Object { $_.Extension -in ".sv", ".svh" }
    ) | Sort-Object FullName

    foreach ($svFile in $svFiles) {
        $text = Get-FileTextStrippedCached -Path $svFile.FullName
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        $relFile = (Get-DisplayRelativePath -BasePath $FolderPath -TargetPath $svFile.FullName).Replace('\', '/')
        $relDir = [System.IO.Path]::GetDirectoryName($relFile)
        if ($null -eq $relDir -or $relDir -eq ".") { $relDir = "" }
        $relDir = ([string]$relDir).Replace('\', '/')

        $matches = @()
        foreach ($declType in $declTypes) {
            $re = Get-DeclRegex -DeclType $declType
            foreach ($match in $re.Matches($text)) {
                $matches += [pscustomobject]@{
                    Type   = $declType
                    Name   = [string]$match.Groups[1].Value
                    Offset = [int]$match.Index
                    Line   = [regex]::Matches($text.Substring(0, $match.Index), "`n").Count + 1
                }
            }
        }

        foreach ($entry in @($matches | Sort-Object Offset, Type, Name)) {
            $declEntries += [pscustomobject]@{
                Type        = $entry.Type
                Name        = $entry.Name
                Path        = $svFile.FullName
                Line        = [int]$entry.Line
                RelFile     = $relFile
                RelDir      = $relDir
                Offset      = [int]$entry.Offset
                FolderParts = @($(if ([string]::IsNullOrWhiteSpace($relDir)) { @() } else { $relDir -split '/' }))
            }
        }
    }

    return @($declEntries | Sort-Object RelDir, RelFile, Offset, Type, Name)
}

function New-TbDeclTreeNode {
    param(
        [string]$Name,
        [string]$RelativePath
    )

    return [pscustomobject]@{
        Name         = $Name
        RelativePath = $RelativePath
        Children     = @{}
        Declarations = @()
    }
}

function Build-TbDeclTree {
    param([array]$Entries)

    $root = New-TbDeclTreeNode -Name "" -RelativePath ""
    foreach ($entry in @($Entries)) {
        $node = $root
        foreach ($part in @($entry.FolderParts)) {
            if ([string]::IsNullOrWhiteSpace($part)) { continue }
            $childRelPath = if ([string]::IsNullOrWhiteSpace([string]$node.RelativePath)) {
                $part
            } else {
                ([string]$node.RelativePath + "/" + $part)
            }
            if (-not $node.Children.ContainsKey($part)) {
                $node.Children[$part] = New-TbDeclTreeNode -Name $part -RelativePath $childRelPath
            }
            $node = $node.Children[$part]
        }

        $node.Declarations += $entry
    }

    return $root
}

function Convert-IndexToHierarchyData {
    param(
        $IndexObj,
        [bool]$IncludeTb,
        [bool]$TbOnly
    )

    $moduleMap = @{}
    $moduleFileMap = @{}
    $modulePathMap = @{}
    $declGroups = New-DeclGroups
    $firstDeclPath = @{}

    foreach ($f in $IndexObj.files) {
        $role = [string]$f.role
        $relPath = [string]$f.path
        $fileScope = Get-IndexedFileScope -Role $role -RelPath $relPath
        if (-not (Should-IncludeIndexedFile -FileScope $fileScope -IncludeTb:$IncludeTb -TbOnly:$TbOnly)) {
            continue
        }

        $fullPath = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $f.path))
        foreach ($decl in $f.declarations) {
            $dType = [string]$decl.type
            $dName = [string]$decl.name

            if ($dType -eq "module") {
                if (-not $moduleMap.ContainsKey($dName)) { $moduleMap[$dName] = "" }
                if (-not $moduleFileMap.ContainsKey($dName)) {
                    $moduleFileMap[$dName] = ([string]$f.path).Replace('\', '/')
                }
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
    $global:fileTextCache.Clear()
    $global:declLineCache.Clear()
    $global:counter = 1

    $includeTbEnabled = ($IncludeTb -eq "1")
    $tbOnlyEnabled = ($TbOnly -eq "1")

    # 2. Scope dir check
    if ($tbOnlyEnabled) {
        if (-not (Test-Path $tbDir)) {
            return @{ Error = "TB directory not found" }
        }
    } else {
        if (-not (Test-Path $srcDir)) {
            return @{ Error = "Source directory not found" }
        }
    }

    $idx = Try-LoadHdlIndex -ProjectRoot $ProjectRoot -HdlIndexerPath $HdlIndexerPath
    if ($tbOnlyEnabled) {
        return (Get-TbOnlyHierarchyData -IndexObj $idx)
    }

    if ($idx -and $idx.files) {
        return (Convert-IndexToHierarchyData -IndexObj $idx -IncludeTb:$includeTbEnabled -TbOnly:$tbOnlyEnabled)
    }

    $searchRoots = @()
    $sharedRoots = @("include", "inc")

    foreach ($sharedRoot in $sharedRoots) {
        if ((Test-Path $sharedRoot) -and -not ($searchRoots -contains $sharedRoot)) {
            $searchRoots += $sharedRoot
        }
    }

    if ($tbOnlyEnabled) {
        if (-not ($searchRoots -contains $tbDir)) {
            $searchRoots += $tbDir
        }
    } else {
        if (-not ($searchRoots -contains $srcDir)) {
            $searchRoots += $srcDir
        }
        if ($includeTbEnabled -and (Test-Path $tbDir)) {
            if (-not ($searchRoots -contains $tbDir)) {
                $searchRoots += $tbDir
            }
        }
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
            if (-not $moduleFileMap.ContainsKey($mName)) {
                $moduleFileMap[$mName] = Get-DisplayRelativePath -BasePath $ProjectRoot -TargetPath $f.FullName
            }
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

function Get-HierarchyLevelColor {
    param([int]$Depth = 0)

    $palette = @(
        "Red",
        "Green",
        "Blue",
        "Yellow",
        "Magenta",
        "Cyan",
        "White",
        "Gray"
    )

    if ($Depth -lt 0) { $Depth = 0 }
    if ($Depth -ge $palette.Count) {
        return $palette[$palette.Count - 1]
    }
    return $palette[$Depth]
}

function Print-Node {
    param (
        $mName,
        $indent,
        $last,
        $data,
        $pathSet = $null,
        [int]$Depth = 0
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
    $global:fileIndexMap[$idx] = [pscustomobject]@{
        Path  = $fPath
        Line  = 0
        Kind  = "module"
        Label = $mName
    }
    $global:counter++

    # Connector
    $conn = "+-- "
    if ($last) { $conn = "\-- " }

    $nodeColor = Get-HierarchyLevelColor -Depth $Depth

    # Colorize
    Write-Host ("{0}{1}" -f $indent, $conn) -NoNewline -ForegroundColor DarkGray
    Write-Host ("[{0,2}] " -f $idx) -NoNewline -ForegroundColor Yellow
    Write-Host (" " + $mName) -NoNewline -ForegroundColor $nodeColor
    Write-Host (" ({0})" -f $fName) -ForegroundColor Gray

    # Children
    $children = $data.Deps[$mName]
    if ($children) {
        $addIndent = "|   "
        if ($last) { $addIndent = "    " }
        $newIndent = $indent + $addIndent

        for ($i = 0; $i -lt $children.Count; $i++) {
            $isLast = ($i -eq $children.Count - 1)
            Print-Node -mName $children[$i] -indent $newIndent -last $isLast -data $data -pathSet $nextPathSet -Depth ($Depth + 1)
        }
    }
}

function Print-TbFolderList {
    param($data)

    $folders = @($data.TbFolders)
    if ($folders.Count -eq 0) {
        Write-Host "No TB folders found."
        return
    }

    Write-Host " [TB Folders]" -ForegroundColor Yellow
    for ($i = 0; $i -lt $folders.Count; $i++) {
        $folder = $folders[$i]
        $isLast = ($i -eq $folders.Count - 1)
        $conn = "+-- "
        if ($isLast) { $conn = "\-- " }

        $idx = New-BrowseTarget -Path ([string]$folder.Path) -Line 0 -Kind "tb-folder" -Label ([string]$folder.Display) -FolderKey ([string]$folder.Key)

        Write-Host $conn -NoNewline -ForegroundColor DarkGray
        Write-Host ("[{0,2}] " -f $idx) -NoNewline -ForegroundColor Yellow
        Write-Host (" " + $folder.Display) -ForegroundColor Cyan
    }
}

function Print-TbDutEntry {
    param(
        $Entry,
        [string]$Indent,
        [bool]$Last
    )

    $conn = "+-- "
    if ($Last) { $conn = "\-- " }

    $idx = New-BrowseTarget -Path ([string]$Entry.Path) -Line ([int]$Entry.Line) -Kind "module" -Label ([string]$Entry.Name)

    Write-Host ("{0}{1}" -f $Indent, $conn) -NoNewline -ForegroundColor DarkGray
    Write-Host ("[{0,2}] " -f $idx) -NoNewline -ForegroundColor Yellow
    Write-Host (" " + $Entry.Name) -NoNewline -ForegroundColor Cyan
    Write-Host (" ({0})" -f $Entry.RelPath) -ForegroundColor Gray
}

function Print-TbTopEntry {
    param(
        $TopEntry,
        [array]$DutEntries,
        [string]$Indent = "",
        [bool]$Last = $true
    )

    $conn = "+-- "
    if ($Last) { $conn = "\-- " }

    $label = if ([string]$TopEntry.Type -ieq "program") {
        "program " + [string]$TopEntry.Name
    } else {
        [string]$TopEntry.Name
    }

    $idx = New-BrowseTarget -Path ([string]$TopEntry.Path) -Line ([int]$TopEntry.Line) -Kind ([string]$TopEntry.Type) -Label $label

    Write-Host ("{0}{1}" -f $Indent, $conn) -NoNewline -ForegroundColor DarkGray
    Write-Host ("[{0,2}] " -f $idx) -NoNewline -ForegroundColor Yellow
    Write-Host (" " + $label) -NoNewline -ForegroundColor Cyan
    Write-Host (" ({0})" -f $TopEntry.RelPath) -ForegroundColor Gray

    $dutRows = @($DutEntries)
    if ($dutRows.Count -eq 0) { return }

    $childIndent = $Indent + $(if ($Last) { "    " } else { "|   " })
    for ($i = 0; $i -lt $dutRows.Count; $i++) {
        Print-TbDutEntry -Entry $dutRows[$i] -Indent $childIndent -Last ($i -eq $dutRows.Count - 1)
    }
}

function Print-TbDeclEntry {
    param(
        $Entry,
        [string]$Indent,
        [bool]$Last
    )

    $conn = "+-- "
    if ($Last) { $conn = "\-- " }

    $idx = New-BrowseTarget -Path ([string]$Entry.Path) -Line ([int]$Entry.Line) -Kind "decl" -Label ([string]($Entry.Type + " " + $Entry.Name))

    Write-Host ("{0}{1}" -f $Indent, $conn) -NoNewline -ForegroundColor DarkGray
    Write-Host ("[{0,2}] " -f $idx) -NoNewline -ForegroundColor Yellow
    Write-Host (" {0} {1}" -f $Entry.Type, $Entry.Name) -NoNewline -ForegroundColor Magenta
    Write-Host (" ({0})" -f $Entry.RelFile) -ForegroundColor Gray
}

function Print-TbDeclContainer {
    param(
        $Node,
        [string]$Label,
        [string]$Indent,
        [bool]$Last
    )

    $conn = "+-- "
    if ($Last) { $conn = "\-- " }

    Write-Host ("{0}{1}" -f $Indent, $conn) -NoNewline -ForegroundColor DarkGray
    Write-Host ("[{0}]" -f $Label) -ForegroundColor Cyan

    $childIndent = $Indent + $(if ($Last) { "    " } else { "|   " })
    $items = @()
    foreach ($decl in @($Node.Declarations | Sort-Object RelFile, Offset, Type, Name)) {
        $items += [pscustomobject]@{
            Kind  = "decl"
            Value = $decl
        }
    }
    foreach ($childName in @($Node.Children.Keys | Sort-Object)) {
        $items += [pscustomobject]@{
            Kind  = "folder"
            Value = $Node.Children[$childName]
        }
    }

    for ($i = 0; $i -lt $items.Count; $i++) {
        $item = $items[$i]
        $isLastItem = ($i -eq $items.Count - 1)
        if ($item.Kind -eq "decl") {
            Print-TbDeclEntry -Entry $item.Value -Indent $childIndent -Last $isLastItem
        } else {
            Print-TbDeclContainer -Node $item.Value -Label ([string]$item.Value.Name) -Indent $childIndent -Last $isLastItem
        }
    }
}

function Print-TbDeclarationTree {
    param([array]$DeclEntries)

    $entries = @($DeclEntries)
    if ($entries.Count -eq 0) { return }

    $root = Build-TbDeclTree -Entries $entries

    Write-Host ""
    Write-Host " [SV Declarations]" -ForegroundColor Yellow

    $items = @()
    if (@($root.Declarations).Count -gt 0) {
        $rootNode = New-TbDeclTreeNode -Name "root" -RelativePath ""
        $rootNode.Declarations = @($root.Declarations)
        $items += [pscustomobject]@{
            Kind  = "folder"
            Value = $rootNode
        }
    }
    foreach ($childName in @($root.Children.Keys | Sort-Object)) {
        $items += [pscustomobject]@{
            Kind  = "folder"
            Value = $root.Children[$childName]
        }
    }

    for ($i = 0; $i -lt $items.Count; $i++) {
        Print-TbDeclContainer -Node $items[$i].Value -Label ([string]$items[$i].Value.Name) -Indent "" -Last ($i -eq $items.Count - 1)
    }
}

function Print-TbFolderDetail {
    param(
        $Folder,
        [hashtable]$RtlModules
    )

    Write-Host (" [TB Folder] {0}" -f $Folder.Display) -ForegroundColor Yellow
    Write-Host ""

    $topEntries = @(Get-TbTopEntriesForFolder -FolderPath ([string]$Folder.Path))
    if ($topEntries.Count -eq 0) {
        Write-Host "No TB top modules/programs found."
    } else {
        for ($i = 0; $i -lt $topEntries.Count; $i++) {
            $topEntry = $topEntries[$i]
            $dutEntries = @(Get-DirectDutEntriesForTop -TopEntry $topEntry -RtlModules $RtlModules)
            Print-TbTopEntry -TopEntry $topEntry -DutEntries $dutEntries -Indent "" -Last ($i -eq $topEntries.Count - 1)
        }
    }

    $declEntries = @(Get-TbFolderSvDeclarations -FolderPath ([string]$Folder.Path))
    Print-TbDeclarationTree -DeclEntries $declEntries
}

function Print-SvDeclGroup {
    param(
        [string]$Keyword,
        [array]$Items
    )

    foreach ($entry in (@($Items) | Sort-Object Name)) {
        $idx = $global:counter
        $global:fileIndexMap[$idx] = [pscustomobject]@{
            Path  = $entry.Path
            Line  = [int]$entry.Line
            Kind  = "decl"
            Label = ($Keyword + " " + $entry.Name)
        }
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
try {
while ($true) {
    Clear-Host
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "   HDL Project Navigator (Verilog/SystemVerilog)" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green

    $tbOnlyEnabled = ($TbOnly -eq "1")
    if ($tbOnlyEnabled) {
        if ([string]::IsNullOrWhiteSpace($selectedTbFolderKey)) {
            Write-Host " [Numbers] Open Folder  |  [S1/S3] Scope  |  [ENTER] Refresh  |  [Q] Quit" -ForegroundColor White
        } else {
            Write-Host " [Numbers] Open File  |  [B] Back  |  [S1/S3] Scope  |  [ENTER] Refresh  |  [Q] Quit" -ForegroundColor White
        }
    } else {
        Write-Host " [Numbers] Open File  |  [S1/S3] Scope  |  [ENTER] Refresh  |  [Q] Quit" -ForegroundColor White
    }

    if ($TbOnly -eq "1") {
        Write-Host " [Scope] tb only (--tb-only)" -ForegroundColor DarkGray
    } elseif ($IncludeTb -eq "1") {
        Write-Host " [Scope] src + tb (--include-tb)" -ForegroundColor DarkGray
    } else {
        Write-Host " [Scope] src only (tb hidden)" -ForegroundColor DarkGray
    }
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray

    $data = Get-Hierarchy
    if ($data.Error) {
        $selectedTbFolderKey = ""
        $selectedTbFolderDisplay = ""
        Write-Host $data.Error -ForegroundColor Red
    } else {
        if ($data.Indexer) {
            Write-Host " [Indexer] hdl_indexer.js active" -ForegroundColor DarkGray
            Write-Host ""
        }

        if ($tbOnlyEnabled) {
            $selectedTbFolder = $null
            if (-not [string]::IsNullOrWhiteSpace($selectedTbFolderKey)) {
                $selectedTbFolder = @($data.TbFolders | Where-Object { $_.Key -eq $selectedTbFolderKey } | Select-Object -First 1)
            }
            if (-not $selectedTbFolder) {
                $selectedTbFolderKey = ""
                $selectedTbFolderDisplay = ""
            }

            if ($BrowseOnce -eq "1") {
                $tbFolders = @($data.TbFolders)
                if ($tbFolders.Count -eq 0) {
                    Write-Host "No TB folders found."
                } else {
                    for ($i = 0; $i -lt $tbFolders.Count; $i++) {
                        if ($i -gt 0) {
                            Write-Host ""
                            Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray
                        }
                        Print-TbFolderDetail -Folder $tbFolders[$i] -RtlModules $data.RtlModules
                    }
                }
            } elseif ([string]::IsNullOrWhiteSpace($selectedTbFolderKey)) {
                Print-TbFolderList -data $data
            } else {
                Print-TbFolderDetail -Folder $selectedTbFolder[0] -RtlModules $data.RtlModules
            }
        } else {
            if ($data.Top.Count -gt 0) {
                foreach ($root in $data.Top) {
                    Print-Node -mName $root -indent "" -last $true -data $data
                }
            } else {
                Write-Host "No modules found."
            }
            Print-SvDeclList -data $data
        }
    }

    Write-Host ""
    if ($BrowseOnce -eq "1") { break }

    $input = Read-Host " Command"
    $inputTrimmed = [string]$input
    $inputTrimmed = $inputTrimmed.Trim()
    $inputUpper = $inputTrimmed.ToUpperInvariant()

    if ($inputUpper -eq 'Q') {
        $quitRequested = $true
        break
    }

    if ($tbOnlyEnabled -and -not [string]::IsNullOrWhiteSpace($selectedTbFolderKey) -and $inputUpper -eq 'B') {
        $selectedTbFolderKey = ""
        $selectedTbFolderDisplay = ""
        continue
    }

    if ($inputUpper -eq 'S1') {
        $IncludeTb = "0"
        $TbOnly = "0"
        $selectedTbFolderKey = ""
        $selectedTbFolderDisplay = ""
        continue
    }
    if ($inputUpper -eq 'S3') {
        $IncludeTb = "1"
        $TbOnly = "1"
        $selectedTbFolderKey = ""
        $selectedTbFolderDisplay = ""
        continue
    }

    if ($inputTrimmed -match '^\d+$') {
        $idx = [int]$inputTrimmed
        if ($global:fileIndexMap.ContainsKey($idx)) {
            $target = $global:fileIndexMap[$idx]
            if ([string]$target.Kind -eq "tb-folder") {
                $selectedTbFolderKey = [string]$target.FolderKey
                $selectedTbFolderDisplay = [string]$target.Label
                continue
            }

            Open-IndexedTarget -Target $target
            Start-Sleep -Milliseconds 200
        } else {
            Write-Host "Invalid Index." -ForegroundColor Red
            Start-Sleep -Milliseconds 500
        }
    }
}
}
finally {
    if ($hierarchyTranscriptActive) {
        try {
            Stop-Transcript | Out-Null
        } catch {
        }
    }
}

$summaryStatus = "success"
if ($quitRequested) {
    $summaryStatus = "cancelled"
}
Invoke-HierarchySummaryWriter -Status $summaryStatus
if ($quitRequested) {
    exit $userCancelRc
}
