@echo off
setlocal

if "%~1"=="" (
    echo [ERROR] No target project path provided.
    echo Usage: %~nx0 ^<Project_Directory^>
    pause
    exit /b 1
)

set "TARGET_PROJECT=%~f1"
set "TEMPLATES_DIR=%~dp0.."
set "TCL_SCRIPT=%TEMPLATES_DIR%\tcl\run_vivado_simulation.tcl"
set "VIVADO_ROOT=%TARGET_PROJECT%\vivado_project"
set "SIM_LOG_DIR=%VIVADO_ROOT%\vivado_sim_log"

if not exist "%TARGET_PROJECT%\src" (
    echo [ERROR] src directory not found: %TARGET_PROJECT%\src
    pause
    exit /b 1
)

if not exist "%TARGET_PROJECT%\tb" (
    echo [ERROR] tb directory not found: %TARGET_PROJECT%\tb
    pause
    exit /b 1
)

if not exist "%TCL_SCRIPT%" (
    echo [ERROR] Tcl script not found: %TCL_SCRIPT%
    pause
    exit /b 1
)

if not exist "%VIVADO_ROOT%" mkdir "%VIVADO_ROOT%"
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

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_FILE%" "%TARGET_PROJECT%" "%TCL_SCRIPT%" "%VIVADO_ROOT%" "%SIM_LOG_DIR%"
set "PS_RC=%errorlevel%"

del "%PS_FILE%" >nul 2>nul

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
    [Parameter(Mandatory = $true)][string]$SimLogDir
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

$tbRoot = Join-Path $ProjectRoot "tb"
$tbFiles = Get-ChildItem -Path $tbRoot -Recurse -File |
    Where-Object { $_.Extension -in ".v", ".sv" } |
    Sort-Object FullName

if ($tbFiles.Count -eq 0) {
    Write-Host "[ERROR] No testbench files found in $tbRoot" -ForegroundColor Red
    exit 1
}

Write-Host "-----------------------------------------------------------" -ForegroundColor Cyan
Write-Host "      Vivado GUI Simulation Launcher" -ForegroundColor Cyan
Write-Host "-----------------------------------------------------------" -ForegroundColor Cyan
Write-Host ""
Write-Host "Select Testbench Top Source:" -ForegroundColor Yellow

for ($i = 0; $i -lt $tbFiles.Count; $i++) {
    $rel = Get-RelativePathSafe -BasePath $ProjectRoot -TargetPath $tbFiles[$i].FullName
    Write-Host ("[{0}] {1}" -f ($i + 1), $rel)
}

$selectionRaw = Read-Host " >"
if (-not ($selectionRaw -match "^\d+$")) {
    Write-Host "[ERROR] Invalid selection." -ForegroundColor Red
    exit 1
}

$selection = [int]$selectionRaw
if ($selection -lt 1 -or $selection -gt $tbFiles.Count) {
    Write-Host "[ERROR] Selection out of range." -ForegroundColor Red
    exit 1
}

$selectedTb = $tbFiles[$selection - 1]

function Get-TbTopModuleName {
    param([string]$TbFilePath)

    $raw = Get-Content -Path $TbFilePath -Raw
    $clean = [regex]::Replace($raw, "/\*[\s\S]*?\*/", "")
    $clean = [regex]::Replace($clean, "//.*$", "", [System.Text.RegularExpressions.RegexOptions]::Multiline)

    # Support SystemVerilog lifetime qualifiers and program testbench tops.
    $m = [regex]::Match(
        $clean,
        "\b(?:module|program)\s+(?:(?:automatic|static)\s+)?([A-Za-z_][A-Za-z0-9_$]*)\b",
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    if ($m.Success) {
        return $m.Groups[1].Value
    }

    return [System.IO.Path]::GetFileNameWithoutExtension($TbFilePath)
}

$tbTop = Get-TbTopModuleName -TbFilePath $selectedTb.FullName
$selectedRel = Get-RelativePathSafe -BasePath $ProjectRoot -TargetPath $selectedTb.FullName

Write-Host ""
Write-Host ("[INFO] Selected TB file : {0}" -f $selectedRel) -ForegroundColor Green
Write-Host ("[INFO] Simulation top   : {0}" -f $tbTop) -ForegroundColor Green
Write-Host "[INFO] Launching Vivado GUI and simulation..." -ForegroundColor Green
Write-Host ("[INFO] Vivado workspace : {0}" -f $VivadoRoot) -ForegroundColor Green
Write-Host ("[INFO] Vivado logs      : {0}" -f $SimLogDir) -ForegroundColor Green

$vivadoArgs = @(
    "-mode", "gui",
    "-source", $TclScript,
    "-tclargs", $ProjectRoot, $tbTop, $VivadoRoot,
    "-log", (Join-Path $SimLogDir "vivado_sim.log"),
    "-journal", (Join-Path $SimLogDir "vivado_sim.jou"),
    "-notrace"
)

& vivado @vivadoArgs
$rc = $LASTEXITCODE
Move-VivadoArtifacts -RootDir $VivadoRoot -DstDir $SimLogDir
Move-VivadoArtifacts -RootDir $ProjectRoot -DstDir $SimLogDir
exit $rc
