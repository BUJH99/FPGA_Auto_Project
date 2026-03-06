@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
set "USER_CANCEL_RC=99"

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^>
    pause
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
set "TEMPLATES_DIR=%TEMPLATES_ROOT%"
set "TCL_SCRIPT=%TEMPLATES_ROOT%\contexts\simulation\adapters\tcl\sim_run_vivado.tcl"
set "VIVADO_ROOT=%TARGET_PROJECT%\vivado_project"
set "PROJECT_LOG_DIR=%TARGET_PROJECT%\log"
set "SIM_LOG_DIR=%PROJECT_LOG_DIR%\vivado_sim"
set "CALLER_CWD=%CD%"
set "MANIFEST_CTX=%TEMPLATES_ROOT%\shared\adapters\bat\bootstrap_manifest_context.bat"

if not exist "%TCL_SCRIPT%" (
    echo [ERROR] Tcl script not found: %TCL_SCRIPT%
    pause
    exit /b 1
)

call "%MANIFEST_CTX%" "%TARGET_PROJECT%"
if errorlevel 1 (
    echo [ERROR] Manifest context initialization failed.
    pause
    exit /b 1
)

if not exist "%VIVADO_ROOT%" mkdir "%VIVADO_ROOT%"
if not exist "%PROJECT_LOG_DIR%" mkdir "%PROJECT_LOG_DIR%"
if not exist "%SIM_LOG_DIR%" mkdir "%SIM_LOG_DIR%"

where vivado >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] Vivado executable not found in PATH.
    pause
    exit /b 1
)

set "PS_FILE=%TEMP%\vivado_sim_runner_%RANDOM%.ps1"
set "MARKER=:POWERSHELL_SCRIPT_START"
for /f "tokens=1 delims=:" %%A in ('findstr /n "^%MARKER%" "%~f0"') do set "START_LINE=%%A"
more +%START_LINE% "%~f0" > "%PS_FILE%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_FILE%" "%TARGET_PROJECT%" "%TCL_SCRIPT%" "%VIVADO_ROOT%" "%SIM_LOG_DIR%" "%CALLER_CWD%" "%MANIFEST_SRC_LIST%" "%MANIFEST_TB_LIST%" "%MANIFEST_INC_LIST%"
set "PS_RC=%errorlevel%"

del "%PS_FILE%" >nul 2>nul

if %PS_RC% equ %USER_CANCEL_RC% exit /b %USER_CANCEL_RC%
if %PS_RC% neq 0 (
    echo.
    echo [FAILURE] Vivado simulation launch failed.
    pause
    exit /b %PS_RC%
)

echo.
echo [SUCCESS] Vivado simulation flow finished.
pause
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
    [Parameter(Mandatory = $false)][string]$ManifestIncList = ""
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

Write-Host "-----------------------------------------------------------" -ForegroundColor Cyan
Write-Host "      Vivado GUI Simulation Launcher" -ForegroundColor Cyan
Write-Host "-----------------------------------------------------------" -ForegroundColor Cyan
Write-Host ""
Write-Host "Select TB Folder:" -ForegroundColor Yellow
Write-Host "[INFO] Enter Q to return to menu." -ForegroundColor DarkGray

for ($i = 0; $i -lt $folderEntries.Count; $i++) {
    $folder = $folderEntries[$i]
    Write-Host ("[{0}] {1} ({2} files)" -f ($i + 1), $folder.Name, $folder.Entries.Count)
}

$folderSelection = 0
while ($true) {
    $folderRaw = Read-Host " Folder >"
    if ($folderRaw -match '^(?i)q$') {
        exit 99
    }
    if ($folderRaw -notmatch "^\d+$") {
        Write-Host "[WARN] Enter a valid folder number." -ForegroundColor DarkYellow
        continue
    }
    $folderSelection = [int]$folderRaw
    if ($folderSelection -lt 1 -or $folderSelection -gt $folderEntries.Count) {
        Write-Host "[WARN] Folder selection out of range." -ForegroundColor DarkYellow
        continue
    }
    break
}

$selectedFolder = $folderEntries[$folderSelection - 1]
$selectedFolderFiles = @($selectedFolder.Entries)
$topFolderFiles = @($selectedFolderFiles | Where-Object { $_.HasTop })
$tbSelectList = $topFolderFiles

if ($tbSelectList.Count -eq 0) {
    Write-Host ""
    Write-Host ("[WARN] No module/program top candidate found in folder '{0}'. Showing HDL files as fallback." -f $selectedFolder.Name) -ForegroundColor DarkYellow
    $tbSelectList = $selectedFolderFiles
}

Write-Host ""
Write-Host ("Selected folder: {0}" -f $selectedFolder.Name) -ForegroundColor Green
Write-Host "Select Testbench Top Source:" -ForegroundColor Yellow
Write-Host "[INFO] Enter Q to return to menu." -ForegroundColor DarkGray

for ($i = 0; $i -lt $tbSelectList.Count; $i++) {
    $entry = $tbSelectList[$i]
    if ($entry.HasTop) {
        Write-Host ("[{0}] {1}  (top: {2})" -f ($i + 1), $entry.FileDisplay, $entry.TopCandidate)
    } else {
        $fallbackTop = [System.IO.Path]::GetFileNameWithoutExtension($entry.File.Name)
        Write-Host ("[{0}] {1}  (top fallback: {2})" -f ($i + 1), $entry.FileDisplay, $fallbackTop)
    }
}

$tbSelection = 0
while ($true) {
    $tbRaw = Read-Host " TB file >"
    if ($tbRaw -match '^(?i)q$') {
        exit 99
    }
    if ($tbRaw -notmatch "^\d+$") {
        Write-Host "[WARN] Enter a valid TB file number." -ForegroundColor DarkYellow
        continue
    }
    $tbSelection = [int]$tbRaw
    if ($tbSelection -lt 1 -or $tbSelection -gt $tbSelectList.Count) {
        Write-Host "[WARN] TB file selection out of range." -ForegroundColor DarkYellow
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

$promptSessionId = [Guid]::NewGuid().ToString("N")
$promptIpcDir = Join-Path $SimLogDir ("close_prompt_" + $promptSessionId)
$promptRequestFile = Join-Path $promptIpcDir "request.flag"
$promptCloseFile = Join-Path $promptIpcDir "close.flag"
$promptKeepFile = Join-Path $promptIpcDir "keep.flag"
$promptArgMarker = "__PROMPT_IPC__"
New-Item -ItemType Directory -Path $promptIpcDir -Force | Out-Null

Write-Host ""
Write-Host ("[INFO] Selected TB file : {0}" -f $selectedRel) -ForegroundColor Green
Write-Host ("[INFO] Simulation top   : {0}" -f $tbTop) -ForegroundColor Green
Write-Host ("[INFO] TB compile scope : {0}" -f $selectedTb.DirectoryName) -ForegroundColor Green
Write-Host ("[INFO] xsim.more_options: {0}" -f $simMoreOptions) -ForegroundColor Green
Write-Host "[INFO] After run all completes, this terminal will ask whether to close Vivado GUI." -ForegroundColor Green
Write-Host "[INFO] Launching Vivado GUI and simulation..." -ForegroundColor Green
Write-Host ("[INFO] Vivado workspace : {0}" -f $VivadoRoot) -ForegroundColor Green
Write-Host ("[INFO] Vivado log file  : {0}" -f $vivadoLogFile) -ForegroundColor Green
Write-Host ("[INFO] Vivado journal   : {0}" -f $vivadoJournalFile) -ForegroundColor Green

$vivadoArgs = @(
    "-mode", "gui",
    "-source", $TclScript,
    "-tclargs", $ProjectRoot, $tbTop, $VivadoRoot, $ManifestSrcList, $ManifestTbList, $ManifestIncList, $selectedTb.FullName, $simMoreOptions, $promptArgMarker, $promptRequestFile, $promptCloseFile, $promptKeepFile,
    "-log", $vivadoLogFile,
    "-journal", $vivadoJournalFile,
    "-notrace"
)

$vivadoProc = $null
try {
    $vivadoProc = Start-Process -FilePath "vivado" -ArgumentList $vivadoArgs -WorkingDirectory $VivadoRoot -NoNewWindow -PassThru
} catch {
    Write-Host ("[ERROR] Failed to start Vivado process: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Remove-Item -Path $promptIpcDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

$askedClosePrompt = $false
while ($true) {
    if ($vivadoProc.HasExited) {
        break
    }

    if ((-not $askedClosePrompt) -and (Test-Path $promptRequestFile)) {
        $askedClosePrompt = $true
        $closeNow = $false
        while ($true) {
            $closeRaw = Read-Host " Auto replay completed. Close Vivado GUI now? (y/N) >"
            if ([string]::IsNullOrWhiteSpace($closeRaw)) {
                $closeNow = $false
                break
            }

            $closeNorm = $closeRaw.Trim().ToLower()
            if ($closeNorm -in @("y", "yes", "1")) {
                $closeNow = $true
                break
            }
            if ($closeNorm -in @("n", "no", "0")) {
                $closeNow = $false
                break
            }

            Write-Host "[WARN] Enter y or n." -ForegroundColor DarkYellow
        }

        if ($closeNow) {
            New-Item -ItemType File -Path $promptCloseFile -Force | Out-Null
            Write-Host "[INFO] Close request sent to Vivado." -ForegroundColor Green
        } else {
            New-Item -ItemType File -Path $promptKeepFile -Force | Out-Null
            Write-Host "[INFO] Keeping Vivado GUI open by user choice." -ForegroundColor Green
        }
    }

    Start-Sleep -Milliseconds 250
    $vivadoProc.Refresh()
}

$rc = $vivadoProc.ExitCode
Remove-Item -Path $promptIpcDir -Recurse -Force -ErrorAction SilentlyContinue
Move-VivadoArtifacts -RootDir $VivadoRoot -DstDir $SimLogDir
Move-VivadoArtifacts -RootDir $ProjectRoot -DstDir $SimLogDir
if (-not [string]::IsNullOrWhiteSpace($CallerCwd)) {
    Move-VivadoArtifacts -RootDir $CallerCwd -DstDir $SimLogDir
}
exit $rc
