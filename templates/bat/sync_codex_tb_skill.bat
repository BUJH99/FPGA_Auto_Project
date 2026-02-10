@echo off
setlocal
cd /d "%~dp0.."

echo -----------------------------------------------------------
echo      Sync Project Skills to Local Codex Home
echo -----------------------------------------------------------

set "PS_FILE=%TEMP%\sync_codex_skills_%RANDOM%.ps1"
set "MARKER=:POWERSHELL_SCRIPT_START"

for /f "tokens=1 delims=:" %%a in ('findstr /n "^%MARKER%" "%~f0"') do set "START_LINE=%%a"
more +%START_LINE% "%~f0" > "%PS_FILE%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_FILE%"
set "RET=%errorlevel%"

del "%PS_FILE%"
exit /b %RET%

:POWERSHELL_SCRIPT_START
$codexHome = Join-Path $env:USERPROFILE '.codex'
$dstRoot = Join-Path $codexHome 'skills'
$srcRoot = 'skills'

if (-not (Test-Path $srcRoot)) {
    Write-Host "[ERROR] Source skills directory not found: $srcRoot" -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Path $dstRoot -Force | Out-Null

$skillDirs = Get-ChildItem -Path $srcRoot -Directory | Where-Object { $_.Name -notmatch '^\.' }
if ($skillDirs.Count -eq 0) {
    Write-Host "[ERROR] No project skills found under: $srcRoot" -ForegroundColor Red
    exit 1
}

foreach ($skillDir in $skillDirs) {
    $dstSkillDir = Join-Path $dstRoot $skillDir.Name
    New-Item -ItemType Directory -Path $dstSkillDir -Force | Out-Null
    Copy-Item -Path (Join-Path $skillDir.FullName '*') -Destination $dstSkillDir -Recurse -Force
    Write-Host ("[SYNC] " + $skillDir.Name + " -> " + $dstSkillDir) -ForegroundColor Cyan
}

# Keep TB standard reference aligned for tb-waveform-standard
$tbStdSrc = Join-Path 'md' 'TB_TESTBENCH_STANDARD.md'
$tbStdDst = Join-Path $dstRoot 'tb-waveform-standard\references\TB_TESTBENCH_STANDARD.md'
if (Test-Path $tbStdSrc) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $tbStdDst) -Force | Out-Null
    Copy-Item -Path $tbStdSrc -Destination $tbStdDst -Force
    Write-Host "[SYNC] TB standard reference refreshed." -ForegroundColor Cyan
}

Write-Host "[SUCCESS] Project skills synced to local Codex home." -ForegroundColor Green
Write-Host ("[INFO] Location: " + $dstRoot) -ForegroundColor Cyan
exit 0
