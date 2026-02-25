Param(
  [Parameter(Mandatory = $true)]
  [string]$ProjectPath,

  [Parameter(Mandatory = $true)]
  [string]$ModulesCsv,

  [Parameter(Mandatory = $true)]
  [string]$YosysCmd,

  [Parameter(Mandatory = $true)]
  [string]$NetlistSvgCmd,

  [int]$MaxParallel = 0
)

$ErrorActionPreference = "Stop"

$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$processSchematicScript = Join-Path $toolsDir "process_schematic.ps1"
$generateSimpleSvgScript = Join-Path $toolsDir "generate_simple_svg.ps1"
$svg2drawioScript = Join-Path $toolsDir "svg2drawio.js"
$skinPath = Join-Path $toolsDir "skin.svg"

$modules = $ModulesCsv -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
if ($modules.Count -eq 0) {
  Write-Host "[ERROR] No module selected."
  exit 1
}

Set-Location $ProjectPath

function Get-ProjectRelativePath {
  param([string]$BasePath, [string]$TargetPath)
  try {
    $resolved = Resolve-Path -LiteralPath $TargetPath -Relative
    if ($resolved -is [array]) { $resolved = $resolved[0] }
    $resolved = [string]$resolved
    if ($resolved.StartsWith(".\")) { $resolved = $resolved.Substring(2) }
    return $resolved.Replace('\', '/')
  }
  catch {
    $base = [IO.Path]::GetFullPath($BasePath)
    $target = [IO.Path]::GetFullPath($TargetPath)
    if ($target.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
      return $target.Substring($base.Length).TrimStart('\','/').Replace('\','/')
    }
    return $TargetPath.Replace('\','/')
  }
}

$srcDir = Join-Path $ProjectPath "src"
if (-not (Test-Path $srcDir)) {
  Write-Host "[ERROR] src/ folder not found in project."
  exit 1
}

$srcFiles = Get-ChildItem -Path $srcDir -Recurse -File | Where-Object { $_.Extension -in ".v", ".sv" } | Sort-Object FullName
if ($srcFiles.Count -eq 0) {
  Write-Host "[ERROR] No .v/.sv files found in src/."
  exit 1
}

$verilogFiles = $srcFiles | ForEach-Object {
  $rel = Get-ProjectRelativePath -BasePath $ProjectPath -TargetPath $_.FullName
  $rel
}
$headerRoots = @($srcDir, (Join-Path $ProjectPath "include"), (Join-Path $ProjectPath "inc")) | Where-Object { Test-Path $_ }
$includeDirs = @()
foreach ($root in $headerRoots) {
  $includeDirs += Get-ChildItem -Path $root -Recurse -File | Where-Object { $_.Extension -in ".svh", ".vh" } | Select-Object -ExpandProperty DirectoryName -Unique
}
$includeDirs = @($includeDirs | Select-Object -Unique)
if ($includeDirs.Count -eq 0) { $includeDirs = @() }

$moduleToSource = @{}
foreach ($src in $srcFiles) {
  $content = Get-Content -Path $src.FullName -Raw
  $moduleMatches = [regex]::Matches($content, "(?im)^\s*module\s+([a-zA-Z_]\w*)\b")
  foreach ($m in $moduleMatches) {
    $name = $m.Groups[1].Value
    if (-not $moduleToSource.ContainsKey($name)) {
      $moduleToSource[$name] = Get-ProjectRelativePath -BasePath $ProjectPath -TargetPath $src.FullName
    }
  }
}

$missingModules = @()
$moduleInfoList = @()
foreach ($module in $modules) {
  if ($moduleToSource.ContainsKey($module)) {
    $moduleInfoList += [pscustomobject]@{
      Module = $module
      SourceFile = $moduleToSource[$module]
    }
  }
  else {
    Write-Host "[ERROR] Could not find source file for module $module"
    $missingModules += $module
  }
}

if ($moduleInfoList.Count -eq 0) {
  Write-Host "[ERROR] No valid modules to process."
  exit 1
}

$selectedCount = $moduleInfoList.Count
if ($MaxParallel -le 0) {
  $MaxParallel = [Math]::Max(1, [Math]::Min([Environment]::ProcessorCount, $selectedCount))
}
else {
  $MaxParallel = [Math]::Max(1, [Math]::Min($MaxParallel, $selectedCount))
}

$logDir = Join-Path $ProjectPath "output\Diagram\logs"
if (-not (Test-Path $logDir)) {
  New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

Write-Host "[INFO] Selected modules: $selectedCount"
Write-Host "[INFO] Parallel workers: $MaxParallel"
Write-Host "[INFO] Log directory: $logDir"
Write-Host ""

$moduleWorker = {
  param(
    [string]$ProjectPath,
    [string]$Module,
    [string]$SourceFile,
    [string[]]$VerilogFiles,
    [string]$YosysCmd,
    [string]$NetlistSvgCmd,
    [string]$ProcessSchematicScript,
    [string]$GenerateSimpleSvgScript,
    [string]$Svg2DrawioScript,
    [string]$SkinPath,
    [string]$LogDir,
    [string[]]$IncludeDirs
  )

  $ErrorActionPreference = "Stop"
  Set-Location $ProjectPath

  $logFileFinal = Join-Path $LogDir ($Module + ".log")
  $logFile = Join-Path $LogDir ("{0}_{1}.log" -f $Module, (Get-Date -Format "yyyyMMdd_HHmmss_fff"))

  function Write-Log {
    param([string]$Message)
    $stamp = Get-Date -Format "HH:mm:ss"
    Add-Content -Path $logFile -Value ("[{0}] {1}" -f $stamp, $Message)
  }

  function Append-Output {
    param([object[]]$Lines)
    if (-not $Lines) {
      return
    }
    foreach ($line in $Lines) {
      Add-Content -Path $logFile -Value ("    " + [string]$line)
    }
  }

  function Invoke-ExternalCommand {
    param(
      [string]$Label,
      [string]$Command,
      [string[]]$Arguments
    )

    try {
      $global:LASTEXITCODE = 0
      $tmpCombined = [System.IO.Path]::GetTempFileName()
      try {
        # Redirect all native command output to a temp file, then append once.
        & $Command @Arguments *> $tmpCombined
        $exitCode = $LASTEXITCODE
        if (Test-Path $tmpCombined) {
          Append-Output (Get-Content -Path $tmpCombined)
        }
      }
      finally {
        if (Test-Path $tmpCombined) { Remove-Item -Path $tmpCombined -Force -ErrorAction SilentlyContinue }
      }
      if ($exitCode -ne 0) {
        Write-Log ("[ERROR] {0} failed (exit code: {1})" -f $Label, $exitCode)
        return $false
      }
      return $true
    }
    catch {
      Write-Log ("[ERROR] {0} execution failed: {1}" -f $Label, $_.Exception.Message)
      return $false
    }
  }

  function Sanitize-SvgTextNodes {
    param(
      [string]$SvgPath
    )

    if (-not (Test-Path $SvgPath)) {
      return $false
    }

    try {
      $rawSvg = Get-Content -Path $SvgPath -Raw -Encoding UTF8
      $sanitizedSvg = [regex]::Replace(
        $rawSvg,
        '(?s)(<text\b[^>]*>)(.*?)(</text>)',
        {
          param($m)
          $open = $m.Groups[1].Value
          $body = $m.Groups[2].Value
          $close = $m.Groups[3].Value

          # Escape raw special chars while preserving existing entities.
          $body = [regex]::Replace($body, '&(?!#\d+;|#x[0-9A-Fa-f]+;|[A-Za-z][A-Za-z0-9]+;)', '&amp;')
          $body = $body -replace '<', '&lt;'

          return "$open$body$close"
        }
      )

      if ($sanitizedSvg -ne $rawSvg) {
        Set-Content -Path $SvgPath -Value $sanitizedSvg -Encoding UTF8
        Write-Log "[INFO] Sanitized SVG text nodes: $SvgPath"
      }
      return $true
    }
    catch {
      Write-Log ("[WARN] SVG sanitization failed for {0}: {1}" -f $SvgPath, $_.Exception.Message)
      return $false
    }
  }

  $moduleSuccess = $true

  Write-Log "--------------------------------------------------------"
  Write-Log " Processing Module: $Module"
  Write-Log "--------------------------------------------------------"
  Write-Log "[INFO] Found $Module in $SourceFile"

  $sourcePath = Join-Path $ProjectPath $SourceFile
  $hasSubmodules = 0
  $sourceLines = Get-Content -Path $sourcePath
  foreach ($line in $sourceLines) {
    if ($line -match '^\s*[a-zA-Z_]\w+\s+[a-zA-Z_]\w+\s*\(' -and $line -notmatch '^\s*(module|function|task|input|output|inout|wire|reg|logic|assign|always|initial|localparam|parameter|generate|if|else|for|case|begin|end)\b') {
      $hasSubmodules = 1
      break
    }
  }

  if ($hasSubmodules -eq 1) {
    Write-Log "[INFO] Module $Module has sub-modules - generating detailed and simple versions"
  }
  else {
    Write-Log "[INFO] Module $Module is a leaf module - generating detailed and simple versions"
  }

  $jsonFile = "output/Diagram/JSON/output_$Module.json"
  $skinGenerated = "output/Diagram/JSON/skin_$Module.svg"
  $svgDetailed = "output/Diagram/Detailed/${Module}_detailed.svg"
  $drawioDetailed = "output/Diagram/Detailed/${Module}_detailed.drawio"
  $svgSimple = "output/Diagram/Simple/$Module.svg"
  $drawioSimple = "output/Diagram/Simple/$Module.drawio"

  Write-Log "[INFO] Generating detailed diagram..."
  if (Test-Path $jsonFile) {
    Remove-Item -Path $jsonFile -Force -ErrorAction SilentlyContinue
  }

  $quotedVerilogFiles = $VerilogFiles | ForEach-Object { '"' + $_ + '"' }
  $quotedIncludeDirs = $IncludeDirs | ForEach-Object { '-I "' + ($_.Replace('\','/')) + '"' }
  $yosysScript = "read_verilog -sv $($quotedIncludeDirs -join ' ') $($quotedVerilogFiles -join ' '); hierarchy -top $Module; proc; opt; write_json `"$jsonFile`""
  $yosysOk = Invoke-ExternalCommand -Label "Yosys synthesis for $Module" -Command $YosysCmd -Arguments @("-p", $yosysScript)
  if (-not $yosysOk) {
    $moduleSuccess = $false
  }
  else {
    Write-Log "[INFO] Cleaning JSON..."
    $cleanOk = Invoke-ExternalCommand -Label "JSON cleanup for $Module" -Command "powershell" -Arguments @(
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      $ProcessSchematicScript,
      "-JsonPath",
      $jsonFile,
      "-SkinPath",
      $skinGenerated
    )
    if (-not $cleanOk) {
      $moduleSuccess = $false
    }

    Write-Log "[INFO] Generating detailed SVG..."
    if (Test-Path $svgDetailed) {
      Remove-Item -Path $svgDetailed -Force -ErrorAction SilentlyContinue
    }

    $selectedSkin = $SkinPath
    if (Test-Path $skinGenerated) {
      $selectedSkin = $skinGenerated
    }
    else {
      Write-Log ("[WARN] Generated skin not found for {0}, fallback to default skin: {1}" -f $Module, $SkinPath)
    }

    $netlistOk = Invoke-ExternalCommand -Label "netlistsvg for $Module" -Command "node" -Arguments @($NetlistSvgCmd, $jsonFile, "--skin", $selectedSkin, "-o", $svgDetailed)
    if (-not $netlistOk) {
      $moduleSuccess = $false
    }
    elseif (Test-Path $svgDetailed) {
      Write-Log "[SUCCESS] Generated $svgDetailed"
      [void](Sanitize-SvgTextNodes -SvgPath $svgDetailed)
      Write-Log "[INFO] Converting detailed to Draw.io..."
      $detailedDrawioOk = Invoke-ExternalCommand -Label "Detailed Draw.io conversion for $Module" -Command "node" -Arguments @($Svg2DrawioScript, $svgDetailed, $drawioDetailed)
      if ($detailedDrawioOk) {
        if (Test-Path $drawioDetailed) {
          Write-Log "[SUCCESS] Generated $drawioDetailed"
        }
        else {
          Write-Log "[WARN] Detailed Draw.io conversion output missing for $Module"
        }
      }
      else {
        Write-Log "[WARN] Detailed Draw.io conversion failed for $Module"
      }
    }
    else {
      Write-Log "[ERROR] Failed to generate detailed SVG for $Module"
      $moduleSuccess = $false
    }
  }

  Write-Log "[INFO] Generating simple diagram..."
  if (Test-Path $svgSimple) {
    Remove-Item -Path $svgSimple -Force -ErrorAction SilentlyContinue
  }

  $simpleSvgOk = Invoke-ExternalCommand -Label "Simple SVG generation for $Module" -Command "powershell" -Arguments @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $GenerateSimpleSvgScript,
    "-VerilogFile",
    $SourceFile,
    "-OutputSvg",
    $svgSimple
  )
  if (-not $simpleSvgOk) {
    $moduleSuccess = $false
  }

  if (Test-Path $svgSimple) {
    Write-Log "[SUCCESS] Generated $svgSimple"
    [void](Sanitize-SvgTextNodes -SvgPath $svgSimple)
    Write-Log "[INFO] Converting simple to Draw.io..."
    $simpleDrawioOk = Invoke-ExternalCommand -Label "Simple Draw.io conversion for $Module" -Command "node" -Arguments @($Svg2DrawioScript, $svgSimple, $drawioSimple)
    if ($simpleDrawioOk) {
      if (Test-Path $drawioSimple) {
        Write-Log "[SUCCESS] Generated $drawioSimple"
      }
      else {
        Write-Log "[WARN] Simple Draw.io conversion output missing for $Module"
      }
    }
    else {
      Write-Log "[WARN] Simple Draw.io conversion failed for $Module"
    }
  }
  else {
    Write-Log "[ERROR] Failed to generate simple SVG for $Module"
    $moduleSuccess = $false
  }

  if ($moduleSuccess) {
    Write-Log "[INFO] Module $Module completed."
  }
  else {
    Write-Log "[INFO] Module $Module completed with errors."
  }

  $reportedLogFile = $logFile
  try {
    Copy-Item -Path $logFile -Destination $logFileFinal -Force -ErrorAction Stop
    $reportedLogFile = $logFileFinal
  }
  catch {
    # Keep unique per-run log when TOP.log is locked by another process.
    $reportedLogFile = $logFile
  }

  [pscustomobject]@{
    Module = $Module
    Success = $moduleSuccess
    LogFile = $reportedLogFile
  }
}

$queue = [System.Collections.Generic.Queue[object]]::new()
foreach ($moduleInfo in $moduleInfoList) {
  $queue.Enqueue($moduleInfo)
}

$runningJobs = @()
$results = @()

while ($queue.Count -gt 0 -or $runningJobs.Count -gt 0) {
  while ($queue.Count -gt 0 -and $runningJobs.Count -lt $MaxParallel) {
    $item = $queue.Dequeue()
    $jobName = "schematic_" + $item.Module
    $job = Start-Job -Name $jobName -ScriptBlock $moduleWorker -ArgumentList @(
      $ProjectPath,
      $item.Module,
      $item.SourceFile,
      $verilogFiles,
      $YosysCmd,
      $NetlistSvgCmd,
      $processSchematicScript,
      $generateSimpleSvgScript,
      $svg2drawioScript,
      $skinPath,
      $logDir,
      $includeDirs
    )
    $runningJobs += $job
    Write-Host ("[INFO] Started module: {0} (running: {1}/{2})" -f $item.Module, $runningJobs.Count, $MaxParallel)
  }

  if ($runningJobs.Count -eq 0) {
    continue
  }

  $finishedJob = Wait-Job -Job $runningJobs -Any -Timeout 1
  if (-not $finishedJob) {
    continue
  }

  $doneJobs = @($runningJobs | Where-Object { $_.State -ne "Running" })
  foreach ($job in $doneJobs) {
    $moduleResult = $null
    try {
      $received = Receive-Job -Job $job -ErrorAction SilentlyContinue
      $moduleResult = $received |
        Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties["Module"] } |
        Select-Object -Last 1
    }
    catch {
      $moduleResult = $null
    }

    if (-not $moduleResult) {
      $moduleName = $job.Name -replace "^schematic_", ""
      $jobReason = $null
      if ($job.ChildJobs -and $job.ChildJobs.Count -gt 0) {
        $jobReason = $job.ChildJobs[0].JobStateInfo.Reason
      }
      if ($jobReason) {
        Write-Host ("[ERROR] Job exception for {0}: {1}" -f $moduleName, $jobReason.Message)
      }
      if ($job.ChildJobs -and $job.ChildJobs.Count -gt 0 -and $job.ChildJobs[0].Error.Count -gt 0) {
        foreach ($err in $job.ChildJobs[0].Error) {
          Write-Host ("[ERROR] Job stream error for {0}: {1}" -f $moduleName, $err.ToString())
        }
      }
      $moduleResult = [pscustomobject]@{
        Module = $moduleName
        Success = $false
        LogFile = (Join-Path $logDir ($moduleName + ".log"))
      }
    }

    $results += $moduleResult
    if ($moduleResult.Success) {
      Write-Host ("[SUCCESS] Completed: {0}" -f $moduleResult.Module)
    }
    else {
      Write-Host ("[ERROR] Failed: {0} (log: {1})" -f $moduleResult.Module, $moduleResult.LogFile)
    }

    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue | Out-Null
    $runningJobs = @($runningJobs | Where-Object { $_.Id -ne $job.Id })
  }
}

$failedModules = @()
if ($missingModules.Count -gt 0) {
  $failedModules += $missingModules
}
$failedModules += ($results | Where-Object { -not $_.Success } | ForEach-Object { $_.Module })
$failedModules = $failedModules | Sort-Object -Unique

Write-Host ""
if ($failedModules.Count -gt 0) {
  Write-Host ("[ERROR] Completed with failures: {0}" -f ($failedModules -join ", "))
  Write-Host ("[INFO] Check logs in: {0}" -f $logDir)
  exit 1
}

Write-Host "[INFO] All module jobs completed successfully."
Write-Host ("[INFO] Logs saved in: {0}" -f $logDir)
exit 0
