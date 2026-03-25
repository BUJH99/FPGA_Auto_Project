@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
set "CONSOLE_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\console_ui.bat"
set "VIVADO_RESOLVER=%TEMPLATES_ROOT%\shared\adapters\bat\resolve_vivado.bat"
set "USER_CANCEL_RC=99"

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^>
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
set "TEMPLATES_DIR=%TEMPLATES_ROOT%"
set "TCL_SCRIPT=%TEMPLATES_ROOT%\contexts\simulation\adapters\tcl\sim_run_vivado.tcl"
set "SUMMARY_WRITER=%TEMPLATES_ROOT%\contexts\simulation\adapters\cli\sim_write_vivado_gui_summary_cli.js"
set "VIVADO_ROOT=%TARGET_PROJECT%\vivado_project"
set "PROJECT_LOG_DIR=%TARGET_PROJECT%\log"
set "SIM_LOG_DIR=%PROJECT_LOG_DIR%\vivado_sim"
set "CALLER_CWD=%CD%"
set "MANIFEST_CTX=%TEMPLATES_ROOT%\shared\adapters\bat\bootstrap_manifest_context.bat"

if not exist "%TCL_SCRIPT%" (
    echo [ERROR] Tcl script not found: %TCL_SCRIPT%
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

call "%MANIFEST_CTX%" "%TARGET_PROJECT%"
if errorlevel 1 (
    echo [ERROR] Manifest context initialization failed.
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)

if not exist "%VIVADO_ROOT%" mkdir "%VIVADO_ROOT%"
if not exist "%PROJECT_LOG_DIR%" mkdir "%PROJECT_LOG_DIR%"
if not exist "%SIM_LOG_DIR%" mkdir "%SIM_LOG_DIR%"

call "%VIVADO_RESOLVER%" --quiet
if errorlevel 1 (
    echo [ERROR] Vivado executable not found in PATH.
    echo         Checked PATH and common install directories, including C:\AMDDesignTools\*\Vivado\bin.
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b 1
)
if /i not "%FPGA_AUTO_VIVADO_SOURCE%"=="PATH" echo [INFO] Resolved Vivado bin: %FPGA_AUTO_VIVADO_BIN%

set "PS_FILE=%TEMP%\vivado_sim_runner_%RANDOM%.ps1"
set "MARKER=:POWERSHELL_SCRIPT_START"
for /f "tokens=1 delims=:" %%A in ('findstr /n "^%MARKER%" "%~f0"') do set "START_LINE=%%A"
more +%START_LINE% "%~f0" > "%PS_FILE%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_FILE%" "%TARGET_PROJECT%" "%TCL_SCRIPT%" "%VIVADO_ROOT%" "%SIM_LOG_DIR%" "%CALLER_CWD%" "%MANIFEST_SRC_LIST%" "%MANIFEST_TB_LIST%" "%MANIFEST_INC_LIST%" "%SUMMARY_WRITER%" "%MANIFEST_JSON%"
set "PS_RC=%errorlevel%"

del "%PS_FILE%" >nul 2>nul

if %PS_RC% equ %USER_CANCEL_RC% exit /b %USER_CANCEL_RC%
if %PS_RC% neq 0 (
    echo.
    echo [FAILURE] Vivado simulation launch failed.
    call "%CONSOLE_HELPER%" pause_then_clear
    exit /b %PS_RC%
)

echo.
echo [SUCCESS] Vivado simulation flow finished.
call "%CONSOLE_HELPER%" pause_then_clear
exit /b 0

:POWERSHELL_SCRIPT_START
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$TclScript,
    [Parameter(Mandatory = $true)][string]$VivadoRoot,
    [Parameter(Mandatory = $true)][string]$SimLogDir,
    [Parameter(Mandatory = $false)][string]$CallerCwd = "",
    [Parameter(Mandatory = $false)][string]$ManifestSrcList = "",
    [Parameter(Mandatory = $false)][string]$ManifestTbList = "",
    [Parameter(Mandatory = $false)][string]$ManifestIncList = "",
    [Parameter(Mandatory = $false)][string]$SummaryWriterPath = "",
    [Parameter(Mandatory = $false)][string]$ManifestJsonPath = ""
)

if (-not (Test-Path $VivadoRoot)) {
    New-Item -ItemType Directory -Path $VivadoRoot | Out-Null
}

if (-not (Test-Path $SimLogDir)) {
    New-Item -ItemType Directory -Path $SimLogDir | Out-Null
}

Set-Location -Path $VivadoRoot

function Move-VivadoArtifacts {
    param(
        [Parameter(Mandatory = $true)][string]$RootDir,
        [Parameter(Mandatory = $true)][string]$DstDir
    )

    foreach ($f in @("vivado.log", "vivado.jou", "vivado.pb", "vivado.str")) {
        $src = Join-Path $RootDir $f
        if (Test-Path $src) {
            Move-Item -Force $src $DstDir
        }
    }

    Get-ChildItem -Path $RootDir -Filter "*.backup.log" -File -ErrorAction SilentlyContinue | ForEach-Object {
        Move-Item -Force $_.FullName $DstDir
    }
    Get-ChildItem -Path $RootDir -Filter "*.backup.jou" -File -ErrorAction SilentlyContinue | ForEach-Object {
        Move-Item -Force $_.FullName $DstDir
    }
    Get-ChildItem -Path $RootDir -Filter "*.backup.str" -File -ErrorAction SilentlyContinue | ForEach-Object {
        Move-Item -Force $_.FullName $DstDir
    }
}

function Get-RelativePathSafe {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    try {
        $baseFull = [System.IO.Path]::GetFullPath($BasePath)
        $targetFull = [System.IO.Path]::GetFullPath($TargetPath)

        if ($targetFull.StartsWith($baseFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rel = $targetFull.Substring($baseFull.Length).TrimStart('\', '/')
            if ($rel -ne "") { return $rel }
        }

        $baseUri = New-Object System.Uri(($baseFull.TrimEnd('\', '/') + '\'))
        $targetUri = New-Object System.Uri($targetFull)
        $relativeUri = $baseUri.MakeRelativeUri($targetUri)
        return [System.Uri]::UnescapeDataString($relativeUri.ToString()).Replace('/', '\')
    } catch {
        return $TargetPath
    }
}

$folderSelection = 0
$selectedFolderName = ""
$tbSelection = 0
$tbTop = ""
$selectedRel = ""
$summaryReplayState = "not_started"
$summaryCloseDecision = ""
$vivadoLogFile = ""
$vivadoJournalFile = ""
$resolvedVivadoLogFile = ""
$resolvedVivadoJournalFile = ""
$runStartedAt = (Get-Date).ToString("o")
$folderPromptWarning = ""
$tbPromptWarning = ""

function Resolve-ExistingVivadoArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$PreferredPath,
        [Parameter(Mandatory = $false)][string[]]$FallbackPaths = @()
    )

    if (-not [string]::IsNullOrWhiteSpace($PreferredPath) -and (Test-Path -LiteralPath $PreferredPath -PathType Leaf)) {
        return (Get-Item -LiteralPath $PreferredPath).FullName
    }

    foreach ($fallback in ($FallbackPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        if (Test-Path -LiteralPath $fallback -PathType Leaf) {
            return (Get-Item -LiteralPath $fallback).FullName
        }
    }

    return $PreferredPath
}

function Refresh-VivadoArtifactPaths {
    $logFallbacks = @(
        (Join-Path $SimLogDir "vivado.log"),
        (Join-Path $VivadoRoot "vivado.log"),
        (Join-Path $ProjectRoot "vivado.log")
    )
    if (-not [string]::IsNullOrWhiteSpace($vivadoLogFile)) {
        $logFallbacks = @((Join-Path $SimLogDir ([System.IO.Path]::GetFileName($vivadoLogFile)))) + $logFallbacks
    }
    if (-not [string]::IsNullOrWhiteSpace($CallerCwd)) {
        $logFallbacks += @(Join-Path $CallerCwd "vivado.log")
    }
    $script:resolvedVivadoLogFile = Resolve-ExistingVivadoArtifact -PreferredPath $vivadoLogFile -FallbackPaths $logFallbacks

    $journalFallbacks = @(
        (Join-Path $SimLogDir "vivado.jou"),
        (Join-Path $VivadoRoot "vivado.jou"),
        (Join-Path $ProjectRoot "vivado.jou")
    )
    if (-not [string]::IsNullOrWhiteSpace($vivadoJournalFile)) {
        $journalFallbacks = @((Join-Path $SimLogDir ([System.IO.Path]::GetFileName($vivadoJournalFile)))) + $journalFallbacks
    }
    if (-not [string]::IsNullOrWhiteSpace($CallerCwd)) {
        $journalFallbacks += @(Join-Path $CallerCwd "vivado.jou")
    }
    $script:resolvedVivadoJournalFile = Resolve-ExistingVivadoArtifact -PreferredPath $vivadoJournalFile -FallbackPaths $journalFallbacks
}

function Invoke-VivadoSummaryWriter {
    param(
        [Parameter(Mandatory = $true)][string]$Status
    )

    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { return }
    if ([string]::IsNullOrWhiteSpace($SummaryWriterPath) -or -not (Test-Path $SummaryWriterPath)) { return }
    Refresh-VivadoArtifactPaths

    $writerArgs = @(
        $SummaryWriterPath,
        "--project-root", $ProjectRoot,
        "--status", $Status,
        "--started-at", $runStartedAt,
        "--finished-at", (Get-Date).ToString("o")
    )

    if (-not [string]::IsNullOrWhiteSpace($ManifestJsonPath)) {
        $writerArgs += @("--manifest-json", $ManifestJsonPath)
    }
    if ($folderSelection -gt 0) {
        $writerArgs += @("--folder-idx", [string]$folderSelection)
    }
    if (-not [string]::IsNullOrWhiteSpace($selectedFolderName)) {
        $writerArgs += @("--folder-name", $selectedFolderName)
    }
    if ($tbSelection -gt 0) {
        $writerArgs += @("--tb-idx", [string]$tbSelection)
    }
    if (-not [string]::IsNullOrWhiteSpace($tbTop)) {
        $writerArgs += @("--tb-name", $tbTop)
    }
    if (-not [string]::IsNullOrWhiteSpace($selectedRel)) {
        $writerArgs += @("--tb-file", $selectedRel)
    }
    if (-not [string]::IsNullOrWhiteSpace($summaryReplayState)) {
        $writerArgs += @("--replay-state", $summaryReplayState)
    }
    if (-not [string]::IsNullOrWhiteSpace($summaryCloseDecision)) {
        $writerArgs += @("--close-decision", $summaryCloseDecision)
    }
    if (-not [string]::IsNullOrWhiteSpace($resolvedVivadoLogFile)) {
        $writerArgs += @("--vivado-log-path", $resolvedVivadoLogFile)
    }
    if (-not [string]::IsNullOrWhiteSpace($resolvedVivadoJournalFile)) {
        $writerArgs += @("--vivado-journal-path", $resolvedVivadoJournalFile)
    }
    if (-not [string]::IsNullOrWhiteSpace($resolvedVivadoLogFile)) {
        Write-Host ("[INFO] Resolved Vivado log file: {0}" -f $resolvedVivadoLogFile) -ForegroundColor Green
    }
    if (-not [string]::IsNullOrWhiteSpace($resolvedVivadoJournalFile)) {
        Write-Host ("[INFO] Resolved Vivado journal : {0}" -f $resolvedVivadoJournalFile) -ForegroundColor Green
    }

    & node @writerArgs
    $writerRc = $LASTEXITCODE
    if ($writerRc -ne 0) {
        Write-Host ("[WARN] Failed to update Vivado run summary (rc={0})." -f $writerRc) -ForegroundColor DarkYellow
    }
}

Move-VivadoArtifacts -RootDir $VivadoRoot -DstDir $SimLogDir
Move-VivadoArtifacts -RootDir $ProjectRoot -DstDir $SimLogDir
if (-not [string]::IsNullOrWhiteSpace($CallerCwd)) {
    Move-VivadoArtifacts -RootDir $CallerCwd -DstDir $SimLogDir
}

$tbFiles = @()
if (-not [string]::IsNullOrWhiteSpace($ManifestTbList) -and (Test-Path $ManifestTbList)) {
    foreach ($rel in Get-Content -Path $ManifestTbList) {
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        $candidate = Join-Path $ProjectRoot ($rel -replace '/', '\')
        if (-not (Test-Path $candidate)) { continue }
        $fi = Get-Item -LiteralPath $candidate -ErrorAction SilentlyContinue
        if ($null -eq $fi -or $fi.PSIsContainer) { continue }
        if ($fi.Extension -in ".v", ".sv") {
            $tbFiles += $fi
        }
    }
    $tbFiles = @($tbFiles | Sort-Object FullName -Unique)
}

if ($tbFiles.Count -eq 0) {
    Write-Host "[ERROR] No testbench files resolved from manifest." -ForegroundColor Red
    Invoke-VivadoSummaryWriter -Status "fail"
    exit 1
}

function Get-TbTopCandidate {
    param([string]$TbFilePath)

    try {
        $raw = Get-Content -Path $TbFilePath -Raw
    } catch {
        return ""
    }

    $clean = [regex]::Replace($raw, "/\*[\s\S]*?\*/", "")
    $clean = [regex]::Replace($clean, "//.*$", "", [System.Text.RegularExpressions.RegexOptions]::Multiline)

    # Support module/program declarations with optional automatic/static lifetime.
    $m = [regex]::Match(
        $clean,
        "\b(?:module|program)\s+(?:(?:automatic|static)\s+)?([A-Za-z_][A-Za-z0-9_$]*)\b",
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if ($m.Success) {
        return $m.Groups[1].Value
    }

    return ""
}

$tbEntries = @(
    foreach ($tbFile in $tbFiles) {
        $folderFull = Split-Path -Path $tbFile.FullName -Parent
        $folderRel = Get-RelativePathSafe -BasePath $ProjectRoot -TargetPath $folderFull
        if ([string]::IsNullOrWhiteSpace($folderRel)) { $folderRel = "tb" }

        $fileRel = Get-RelativePathSafe -BasePath $ProjectRoot -TargetPath $tbFile.FullName
        $topCandidate = Get-TbTopCandidate -TbFilePath $tbFile.FullName

        [pscustomobject]@{
            File          = $tbFile
            FolderDisplay = $folderRel.Replace('\', '/')
            FileDisplay   = $fileRel.Replace('\', '/')
            TopCandidate  = $topCandidate
            HasTop        = -not [string]::IsNullOrWhiteSpace($topCandidate)
        }
    }
)

$folderEntries = @(
    $tbEntries |
        Group-Object FolderDisplay |
        Sort-Object Name |
        ForEach-Object {
            [pscustomobject]@{
                Name    = $_.Name
                Entries = @($_.Group | Sort-Object FileDisplay)
            }
        }
)

function Show-TbFolderMenu {
    param(
        [Parameter(Mandatory = $true)][object[]]$Folders,
        [Parameter(Mandatory = $false)][string]$WarningText = ""
    )

    Clear-Host
    Write-Host "-----------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "      Vivado GUI Simulation Launcher" -ForegroundColor Cyan
    Write-Host "-----------------------------------------------------------" -ForegroundColor Cyan
    Write-Host ""
    if (-not [string]::IsNullOrWhiteSpace($WarningText)) {
        Write-Host $WarningText -ForegroundColor DarkYellow
        Write-Host ""
    }
    Write-Host "Select TB Folder:" -ForegroundColor Yellow
    Write-Host "[INFO] Enter Q to return to menu." -ForegroundColor DarkGray

    for ($i = 0; $i -lt $Folders.Count; $i++) {
        $folder = $Folders[$i]
        Write-Host ("[{0}] {1} ({2} files)" -f ($i + 1), $folder.Name, $folder.Entries.Count)
    }
}

$folderSelection = 0
while ($true) {
    Show-TbFolderMenu -Folders $folderEntries -WarningText $folderPromptWarning
    $folderPromptWarning = ""
    $folderRaw = Read-Host " Folder >"
    if ($folderRaw -match '^(?i)q$') {
        Invoke-VivadoSummaryWriter -Status "cancelled"
        exit 99
    }
    if ($folderRaw -notmatch "^\d+$") {
        $folderPromptWarning = "[WARN] Enter a valid folder number."
        continue
    }
    $folderSelection = [int]$folderRaw
    if ($folderSelection -lt 1 -or $folderSelection -gt $folderEntries.Count) {
        $folderPromptWarning = "[WARN] Folder selection out of range."
        continue
    }
    break
}

$selectedFolder = $folderEntries[$folderSelection - 1]
$selectedFolderName = [string]$selectedFolder.Name
$selectedFolderFiles = @($selectedFolder.Entries)
$topFolderFiles = @($selectedFolderFiles | Where-Object { $_.HasTop })
$tbSelectList = $topFolderFiles

if ($tbSelectList.Count -eq 0) {
    $tbPromptWarning = ("[WARN] No module/program top candidate found in folder '{0}'. Showing HDL files as fallback." -f $selectedFolder.Name)
    $tbSelectList = $selectedFolderFiles
}

function Show-TbFileMenu {
    param(
        [Parameter(Mandatory = $true)][string]$FolderName,
        [Parameter(Mandatory = $true)][object[]]$Entries,
        [Parameter(Mandatory = $false)][string]$WarningText = ""
    )

    Clear-Host
    Write-Host "-----------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "      Vivado GUI Simulation Launcher" -ForegroundColor Cyan
    Write-Host "-----------------------------------------------------------" -ForegroundColor Cyan
    Write-Host ""
    Write-Host ("Selected folder: {0}" -f $FolderName) -ForegroundColor Green
    if (-not [string]::IsNullOrWhiteSpace($WarningText)) {
        Write-Host $WarningText -ForegroundColor DarkYellow
        Write-Host ""
    }
    Write-Host "Select Testbench Top Source:" -ForegroundColor Yellow
    Write-Host "[INFO] Enter Q to return to menu." -ForegroundColor DarkGray

    for ($i = 0; $i -lt $Entries.Count; $i++) {
        $entry = $Entries[$i]
        if ($entry.HasTop) {
            Write-Host ("[{0}] {1}  (top: {2})" -f ($i + 1), $entry.FileDisplay, $entry.TopCandidate)
        } else {
            $fallbackTop = [System.IO.Path]::GetFileNameWithoutExtension($entry.File.Name)
            Write-Host ("[{0}] {1}  (top fallback: {2})" -f ($i + 1), $entry.FileDisplay, $fallbackTop)
        }
    }
}

$tbSelection = 0
while ($true) {
    Show-TbFileMenu -FolderName $selectedFolder.Name -Entries $tbSelectList -WarningText $tbPromptWarning
    $tbPromptWarning = ""
    $tbRaw = Read-Host " TB file >"
    if ($tbRaw -match '^(?i)q$') {
        Invoke-VivadoSummaryWriter -Status "cancelled"
        exit 99
    }
    if ($tbRaw -notmatch "^\d+$") {
        $tbPromptWarning = "[WARN] Enter a valid TB file number."
        continue
    }
    $tbSelection = [int]$tbRaw
    if ($tbSelection -lt 1 -or $tbSelection -gt $tbSelectList.Count) {
        $tbPromptWarning = "[WARN] TB file selection out of range."
        continue
    }
    break
}

$selectedEntry = $tbSelectList[$tbSelection - 1]
$selectedTb = $selectedEntry.File
$tbTop = [string]$selectedEntry.TopCandidate
if ([string]::IsNullOrWhiteSpace($tbTop)) {
    $tbTop = [System.IO.Path]::GetFileNameWithoutExtension($selectedTb.Name)
    Write-Host ("[WARN] Using filename-based top fallback: {0}" -f $tbTop) -ForegroundColor DarkYellow
}
$selectedRel = $selectedEntry.FileDisplay
$simMoreOptions = "-testplusarg TESTNAME=all"
$selectedTbLogDir = $selectedTb.DirectoryName
if (-not (Test-Path $selectedTbLogDir)) {
    New-Item -ItemType Directory -Path $selectedTbLogDir -Force | Out-Null
}
$SimLogDir = $selectedTbLogDir
$tbLogStem = [System.IO.Path]::GetFileNameWithoutExtension($selectedTb.Name)
$tbLogStemSafe = [regex]::Replace($tbLogStem, "[^A-Za-z0-9_.-]", "_")
if ([string]::IsNullOrWhiteSpace($tbLogStemSafe)) {
    $tbLogStemSafe = "tb"
}
$vivadoLogFile = Join-Path $SimLogDir ("vivado_sim_" + $tbLogStemSafe + ".log")
$vivadoJournalFile = Join-Path $SimLogDir ("vivado_sim_" + $tbLogStemSafe + ".jou")

# Re-route any existing vivado artifacts to the selected TB log directory.
Move-VivadoArtifacts -RootDir $VivadoRoot -DstDir $SimLogDir
Move-VivadoArtifacts -RootDir $ProjectRoot -DstDir $SimLogDir
if (-not [string]::IsNullOrWhiteSpace($CallerCwd)) {
    Move-VivadoArtifacts -RootDir $CallerCwd -DstDir $SimLogDir
}

Write-Host ""
Write-Host ("[INFO] Selected TB file : {0}" -f $selectedRel) -ForegroundColor Green
Write-Host ("[INFO] Simulation top   : {0}" -f $tbTop) -ForegroundColor Green
Write-Host ("[INFO] TB compile scope : {0}" -f $selectedTb.DirectoryName) -ForegroundColor Green
Write-Host ("[INFO] xsim.more_options: {0}" -f $simMoreOptions) -ForegroundColor Green
Write-Host "[INFO] Launching Vivado GUI and simulation..." -ForegroundColor Green
Write-Host ("[INFO] Vivado workspace : {0}" -f $VivadoRoot) -ForegroundColor Green
Write-Host ("[INFO] Vivado log file  : {0}" -f $vivadoLogFile) -ForegroundColor Green
Write-Host ("[INFO] Vivado journal   : {0}" -f $vivadoJournalFile) -ForegroundColor Green

$vivadoArgs = @(
    "-mode", "gui",
    "-source", $TclScript,
    "-log", $vivadoLogFile,
    "-journal", $vivadoJournalFile,
    "-notrace",
    "-tclargs", $ProjectRoot, $tbTop, $VivadoRoot, $ManifestSrcList, $ManifestTbList, $ManifestIncList, $selectedTb.FullName, $simMoreOptions
)

$rc = 1
try {
    $summaryReplayState = "running"
    & vivado @vivadoArgs
    $rc = $LASTEXITCODE
} catch {
    Write-Host ("[ERROR] Failed to start Vivado process: {0}" -f $_.Exception.Message) -ForegroundColor Red
    $summaryReplayState = "launch_failed"
    Invoke-VivadoSummaryWriter -Status "fail"
    exit 1
}

if ($summaryReplayState -eq "running") {
    if ($rc -eq 0) {
        $summaryReplayState = "completed"
    } elseif ($rc -eq 99) {
        $summaryReplayState = "cancelled"
    } else {
        $summaryReplayState = "process_exited"
    }
}
Move-VivadoArtifacts -RootDir $VivadoRoot -DstDir $SimLogDir
Move-VivadoArtifacts -RootDir $ProjectRoot -DstDir $SimLogDir
if (-not [string]::IsNullOrWhiteSpace($CallerCwd)) {
    Move-VivadoArtifacts -RootDir $CallerCwd -DstDir $SimLogDir
}
$summaryStatus = "fail"
if ($rc -eq 0) {
    $summaryStatus = "success"
} elseif ($rc -eq 99) {
    $summaryStatus = "cancelled"
}
Invoke-VivadoSummaryWriter -Status $summaryStatus
exit $rc
