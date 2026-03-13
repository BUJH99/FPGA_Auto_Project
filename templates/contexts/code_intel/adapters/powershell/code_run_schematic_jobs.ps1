Param(
  [Parameter(Mandatory = $true)]
  [string]$ProjectPath,

  [string]$ModulesCsv = "",

  [string]$YosysCmd = "",

  [string]$Frontend = "auto",

  [string]$YosysPlugin = "slang",

  [string]$NetlistSvgCmd = "",

  [int]$MaxParallel = 0,

  [switch]$ListModulesOnly,

  [string]$HdlIndexerPath = "",

  [string]$ManifestJson = "",

  [string]$ManifestSrcList = "",

  [string]$ManifestIncList = ""
)

$ErrorActionPreference = "Stop"

$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$contextRoot = [System.IO.Path]::GetFullPath((Join-Path $toolsDir "..\.."))
$processSchematicScript = Join-Path $toolsDir "code_process_schematic.ps1"
$generateSimpleSvgScript = Join-Path $toolsDir "code_generate_simple_svg.ps1"
$svg2drawioScript = Join-Path (Join-Path $contextRoot "adapters") "cli\code_convert_svg_to_drawio_cli.js"
$skinPath = Join-Path $contextRoot "assets\diagram_skin.svg"

$modules = @()
if (-not $ListModulesOnly) {
  $modules = $ModulesCsv -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
  if ($modules.Count -eq 0) {
    Write-Host "[ERROR] No module selected."
    exit 1
  }

  if ([string]::IsNullOrWhiteSpace($YosysCmd) -or [string]::IsNullOrWhiteSpace($NetlistSvgCmd)) {
    Write-Host "[ERROR] Missing required tool command(s): YosysCmd/NetlistSvgCmd"
    exit 1
  }
}

Set-Location $ProjectPath

if (-not [string]::IsNullOrWhiteSpace($ManifestJson) -and -not (Test-Path $ManifestJson)) {
  Write-Host "[ERROR] Manifest JSON not found: $ManifestJson"
  exit 1
}

function Invoke-YosysProbe {
  param(
    [string]$YosysCmd,
    [string]$PluginName = "",
    [string]$Script = ""
  )

  try {
    $global:LASTEXITCODE = 0
    $tmpCombined = [System.IO.Path]::GetTempFileName()
    try {
      $args = @("-Q")
      if (-not [string]::IsNullOrWhiteSpace($PluginName)) {
        $args += @("-m", $PluginName)
      }
      $args += @("-p", $Script)
      & $YosysCmd @args *> $tmpCombined
      $exitCode = $LASTEXITCODE
      $output = @()
      if (Test-Path $tmpCombined) {
        $output = @(Get-Content -Path $tmpCombined)
      }
    }
    finally {
      if (Test-Path $tmpCombined) {
        Remove-Item -Path $tmpCombined -Force -ErrorAction SilentlyContinue
      }
    }
  }
  catch {
    return [pscustomobject]@{
      Success = $false
      ExitCode = -1
      Output = @($_.Exception.Message)
    }
  }

  return [pscustomobject]@{
    Success = ($exitCode -eq 0)
    ExitCode = $exitCode
    Output = @($output)
  }
}

function Get-YosysReadSlangMode {
  param(
    [string]$YosysCmd,
    [string]$PluginName = ""
  )

  $builtinProbe = Invoke-YosysProbe -YosysCmd $YosysCmd -Script "help read_slang"
  if ($builtinProbe.Success) {
    $builtinText = ($builtinProbe.Output -join "`n")
    if ($builtinText -notmatch "No such command or cell type: read_slang" -and $builtinText -match "\bread_slang\b") {
      return "builtin"
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($PluginName)) {
    $pluginProbe = Invoke-YosysProbe -YosysCmd $YosysCmd -PluginName $PluginName -Script "help read_slang"
    if ($pluginProbe.Success) {
      $pluginText = ($pluginProbe.Output -join "`n")
      if ($pluginText -notmatch "No such command or cell type: read_slang" -and $pluginText -match "\bread_slang\b") {
        return "plugin"
      }
    }
  }

  return ""
}

function Get-YosysVersionText {
  param([string]$YosysCmd)

  try {
    $global:LASTEXITCODE = 0
    $tmpCombined = [System.IO.Path]::GetTempFileName()
    try {
      & $YosysCmd "-V" *> $tmpCombined
      $exitCode = $LASTEXITCODE
      $output = @()
      if (Test-Path $tmpCombined) {
        $output = @(Get-Content -Path $tmpCombined)
      }
    }
    finally {
      if (Test-Path $tmpCombined) {
        Remove-Item -Path $tmpCombined -Force -ErrorAction SilentlyContinue
      }
    }
  }
  catch {
    return ""
  }

  if ($exitCode -ne 0) {
    return ""
  }

  return (($output -join " ").Trim())
}

function Test-IsYowaspYosys {
  param([string]$YosysCmd)

  if ([string]::IsNullOrWhiteSpace($YosysCmd)) {
    return $false
  }

  $fileName = [System.IO.Path]::GetFileName($YosysCmd)
  if ([string]::IsNullOrWhiteSpace($fileName)) {
    return $false
  }

  return $fileName.Trim().ToLowerInvariant().StartsWith("yowasp-yosys")
}

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

function Strip-HdlComments {
  param([string]$Text)
  if ($null -eq $Text) { return "" }
  $clean = [regex]::Replace($Text, "/\*[\s\S]*?\*/", "")
  $clean = [regex]::Replace($clean, "//.*$", "", [System.Text.RegularExpressions.RegexOptions]::Multiline)
  return $clean
}

function Try-LoadModuleEntriesFromIndexer {
  param(
    [string]$ProjectPath,
    [string]$HdlIndexerPath,
    [string]$ManifestJson = ""
  )

  $entries = @()
  if ([string]::IsNullOrWhiteSpace($HdlIndexerPath)) { return $entries }
  if (-not (Test-Path $HdlIndexerPath)) { return $entries }
  if (-not (Get-Command node -ErrorAction SilentlyContinue)) { return $entries }

  try {
    $cmdArgs = @($HdlIndexerPath, $ProjectPath, "--pretty")
    if (-not [string]::IsNullOrWhiteSpace($ManifestJson)) {
      $cmdArgs += @("--manifest-json", $ManifestJson)
    }
    $json = & node @cmdArgs 2>$null
    if (-not $json) { return $entries }
    $idx = ($json -join "`n") | ConvertFrom-Json
    if (-not $idx.files) { return $entries }

    $seen = @{}
    foreach ($f in $idx.files) {
      $role = [string]$f.role
      if ($role -eq "tb") { continue }

      $fileRel = [string]$f.path
      if ([string]::IsNullOrWhiteSpace($fileRel)) { continue }
      $fileRel = $fileRel.Replace('\', '/')

      foreach ($decl in $f.declarations) {
        if ([string]$decl.type -ne "module") { continue }
        $name = [string]$decl.name
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $key = $name.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $entries += [pscustomobject]@{
          Name = $name
          SourceFile = $fileRel
        }
      }
    }
  }
  catch {
    return @()
  }

  return @($entries)
}

function Get-ModuleEntriesFromSource {
  param(
    [array]$SourceFiles,
    [string]$ProjectPath
  )

  $entries = @()
  $seen = @{}
  $moduleDeclRegex = [regex]'(?im)\bmodule\s+(?:automatic\s+|static\s+)?([A-Za-z_][A-Za-z0-9_$]*)\b'

  foreach ($src in $SourceFiles) {
    $raw = Get-Content -Path $src.FullName -Raw
    $clean = Strip-HdlComments -Text $raw
    foreach ($m in $moduleDeclRegex.Matches($clean)) {
      $name = [string]$m.Groups[1].Value
      if ([string]::IsNullOrWhiteSpace($name)) { continue }
      $key = $name.ToLowerInvariant()
      if ($seen.ContainsKey($key)) { continue }
      $seen[$key] = $true
      $entries += [pscustomobject]@{
        Name = $name
        SourceFile = (Get-ProjectRelativePath -BasePath $ProjectPath -TargetPath $src.FullName)
      }
    }
  }

  return @($entries)
}

function Read-ManifestEntries {
  param(
    [string]$ListFilePath,
    [string]$Label,
    [bool]$AllowEmpty = $false
  )

  if ([string]::IsNullOrWhiteSpace($ListFilePath)) {
    Write-Host "[ERROR] Missing manifest list path: $Label"
    exit 1
  }
  if (-not (Test-Path $ListFilePath)) {
    Write-Host "[ERROR] Manifest list not found: $ListFilePath"
    exit 1
  }

  $rows = @(
    Get-Content -Path $ListFilePath |
      ForEach-Object { [string]$_ } |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ -ne "" }
  )

  if ((-not $AllowEmpty) -and $rows.Count -eq 0) {
    Write-Host "[ERROR] Manifest list is empty: $Label"
    exit 1
  }

  return @($rows | Select-Object -Unique)
}

$srcEntries = Read-ManifestEntries -ListFilePath $ManifestSrcList -Label "manifest src list" -AllowEmpty:$false
$srcFiles = @()
foreach ($entry in $srcEntries) {
  $candidate = $entry
  if ([System.IO.Path]::IsPathRooted($candidate) -eq $false) {
    $candidate = Join-Path $ProjectPath ($entry -replace '/', '\\')
  }
  if (-not (Test-Path $candidate)) {
    Write-Host "[ERROR] Manifest source file missing on disk: $entry"
    exit 1
  }
  $fi = Get-Item -LiteralPath $candidate -ErrorAction SilentlyContinue
  if ($null -eq $fi -or $fi.PSIsContainer) { continue }
  if ($fi.Extension -in ".v", ".sv") {
    $srcFiles += $fi
  }
}
$srcFiles = @($srcFiles | Sort-Object FullName -Unique)
if ($srcFiles.Count -eq 0) {
  Write-Host "[ERROR] Manifest resolved no Verilog/SystemVerilog source files."
  exit 1
}

$packageDeclRegex = [regex]'(?im)^\s*package\s+[A-Za-z_][A-Za-z0-9_$]*\b'
$packageSrcFiles = @()
$nonPackageSrcFiles = @()
foreach ($src in $srcFiles) {
  $raw = Get-Content -Path $src.FullName -Raw
  $clean = Strip-HdlComments -Text $raw
  if ($packageDeclRegex.IsMatch($clean)) {
    $packageSrcFiles += $src
  }
  else {
    $nonPackageSrcFiles += $src
  }
}
$srcFiles = @($packageSrcFiles + $nonPackageSrcFiles)

$verilogFiles = $srcFiles | ForEach-Object {
  $rel = Get-ProjectRelativePath -BasePath $ProjectPath -TargetPath $_.FullName
  $rel
}
$incEntries = Read-ManifestEntries -ListFilePath $ManifestIncList -Label "manifest include list" -AllowEmpty:$true
$includeDirs = @()
foreach ($incEntry in $incEntries) {
  $incPath = $incEntry
  if ([System.IO.Path]::IsPathRooted($incPath) -eq $false) {
    $incPath = Join-Path $ProjectPath ($incEntry -replace '/', '\\')
  }
  if (-not (Test-Path $incPath)) { continue }
  $incItem = Get-Item -LiteralPath $incPath -ErrorAction SilentlyContinue
  if ($null -eq $incItem) { continue }
  if ($incItem.PSIsContainer) {
    $includeDirs += $incItem.FullName
  } else {
    $includeDirs += $incItem.DirectoryName
  }
}

# Derive include roots from source directories to stabilize `include` resolution.
$includeDirs += $srcFiles | Select-Object -ExpandProperty DirectoryName
$includeDirs = @(
  $includeDirs |
    ForEach-Object { Get-ProjectRelativePath -BasePath $ProjectPath -TargetPath $_ } |
    Sort-Object -Unique
)

$frontendRequested = [string]$Frontend
if ([string]::IsNullOrWhiteSpace($frontendRequested)) {
  $frontendRequested = "auto"
}
$frontendRequested = $frontendRequested.Trim().ToLowerInvariant()
if ($frontendRequested -notin @("auto", "verilog", "slang")) {
  Write-Host "[ERROR] Unsupported frontend request: $Frontend (use auto, verilog, or slang)"
  exit 1
}

$slangMode = Get-YosysReadSlangMode -YosysCmd $YosysCmd -PluginName $YosysPlugin
$slangAvailable = -not [string]::IsNullOrWhiteSpace($slangMode)
$resolvedFrontend = $frontendRequested
if ($resolvedFrontend -eq "auto") {
  if ($slangAvailable) {
    $resolvedFrontend = "slang"
  }
  else {
    $resolvedFrontend = "verilog"
  }
}
elseif ($resolvedFrontend -eq "slang" -and -not $slangAvailable) {
  Write-Host "[ERROR] Requested slang frontend, but read_slang is unavailable."
  if (-not [string]::IsNullOrWhiteSpace($YosysPlugin)) {
    Write-Host "[INFO] Checked Yosys plugin: $YosysPlugin"
  }
  Write-Host "[INFO] Install yosys-slang / OSS CAD Suite, or switch SCHEMATIC_FRONTEND=verilog."
  exit 1
}

$yosysVersionText = Get-YosysVersionText -YosysCmd $YosysCmd
$useYosysPluginForSlang = ($slangMode -eq "plugin")
$useReadSlangSingleThread = ($resolvedFrontend -eq "slang" -and (Test-IsYowaspYosys -YosysCmd $YosysCmd))

$moduleEntries = Try-LoadModuleEntriesFromIndexer -ProjectPath $ProjectPath -HdlIndexerPath $HdlIndexerPath -ManifestJson $ManifestJson
if ($moduleEntries.Count -eq 0) {
  Write-Host "[ERROR] hdl_indexer failed or returned no module entries. Strict mode does not allow fallback scanning."
  exit 1
}

$moduleNameByKey = @{}
$moduleSourceByKey = @{}
foreach ($entry in $moduleEntries) {
  $name = [string]$entry.Name
  $srcRel = [string]$entry.SourceFile
  if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($srcRel)) { continue }
  $key = $name.ToLowerInvariant()
  if (-not $moduleNameByKey.ContainsKey($key)) {
    $moduleNameByKey[$key] = $name
    $moduleSourceByKey[$key] = $srcRel
  }
}

$availableModuleNames = @($moduleNameByKey.Values | Sort-Object { $_.ToLowerInvariant() }, { $_ })
if ($availableModuleNames.Count -eq 0) {
  Write-Host "[ERROR] No module declarations found in src/."
  exit 1
}

if ($ListModulesOnly) {
  foreach ($name in $availableModuleNames) {
    Write-Output $name
  }
  exit 0
}

$missingModules = @()
$moduleInfoList = @()
$selectedKeys = @{}
foreach ($module in $modules) {
  $key = $module.ToLowerInvariant()
  if ($moduleNameByKey.ContainsKey($key)) {
    if ($selectedKeys.ContainsKey($key)) { continue }
    $selectedKeys[$key] = $true
    $moduleInfoList += [pscustomobject]@{
      Module = $moduleNameByKey[$key]
      SourceFile = $moduleSourceByKey[$key]
    }
  }
  else {
    Write-Host "[ERROR] Could not find source file for module $module (available: $($availableModuleNames -join ', '))"
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
Write-Host "[INFO] Yosys command: $YosysCmd"
if (-not [string]::IsNullOrWhiteSpace($yosysVersionText)) {
  Write-Host "[INFO] Yosys version: $yosysVersionText"
}
Write-Host "[INFO] Requested frontend: $frontendRequested"
Write-Host "[INFO] Active frontend: $resolvedFrontend"
if ($slangAvailable) {
  Write-Host "[INFO] read_slang mode: $slangMode"
}
if (-not [string]::IsNullOrWhiteSpace($YosysPlugin)) {
  Write-Host "[INFO] Yosys plugin hint: $YosysPlugin"
}
if ($useReadSlangSingleThread) {
  Write-Host "[INFO] read_slang threads: 1 (yowasp compatibility)"
}
Write-Host ""

$moduleWorker = {
  param(
    [string]$ProjectPath,
    [string]$Module,
    [string]$SourceFile,
    [string[]]$VerilogFiles,
    [string]$YosysCmd,
    [string]$Frontend,
    [string]$YosysPlugin,
    [string]$NetlistSvgCmd,
    [string]$ProcessSchematicScript,
    [string]$GenerateSimpleSvgScript,
    [string]$Svg2DrawioScript,
    [string]$SkinPath,
    [string]$LogDir,
    [string[]]$IncludeDirs,
    [bool]$UseYosysPluginForSlang,
    [bool]$UseReadSlangSingleThread
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

  function Format-YosysArgument {
    param([string]$Value)

    $normalized = [string]$Value
    $normalized = $normalized.Replace('\', '/')
    if ($normalized -notmatch '[\s";]') {
      return $normalized
    }
    $normalized = $normalized.Replace('"', '\"')
    return ('"' + $normalized + '"')
  }

  $moduleSuccess = $true

  Write-Log "--------------------------------------------------------"
  Write-Log " Processing Module: $Module"
  Write-Log "--------------------------------------------------------"
  Write-Log "[INFO] Found $Module in $SourceFile"
  Write-Log "[INFO] Using Yosys command: $YosysCmd"
  Write-Log "[INFO] Active frontend: $Frontend"
  if (-not [string]::IsNullOrWhiteSpace($YosysPlugin)) {
    Write-Log "[INFO] Yosys plugin hint: $YosysPlugin"
  }
  if ($Frontend -eq "slang" -and $UseReadSlangSingleThread) {
    Write-Log "[INFO] read_slang threads: 1 (yowasp compatibility)"
  }

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

  $yosysOk = $false
  $yosysScriptFileRel = "output/Diagram/JSON/schematic_{0}_{1}.ys" -f $Module, ([System.Guid]::NewGuid().ToString("N"))
  $yosysScriptFile = Join-Path $ProjectPath ($yosysScriptFileRel -replace '/', '\')
  try {
    $yosysCommands = @()
    if ($Frontend -eq "slang") {
      $readCommandParts = @("read_slang", "--top", $Module)
      if ($UseReadSlangSingleThread) {
        $readCommandParts += @("--threads", "1")
      }
      foreach ($dir in $IncludeDirs) {
        $readCommandParts += @("--include-directory", (Format-YosysArgument -Value $dir))
      }
      foreach ($file in $VerilogFiles) {
        $readCommandParts += (Format-YosysArgument -Value $file)
      }
      $yosysCommands += ($readCommandParts -join " ")
    }
    else {
      $readCommandParts = @("read_verilog", "-sv")
      foreach ($dir in $IncludeDirs) {
        $readCommandParts += ("-I" + (Format-YosysArgument -Value $dir))
      }
      foreach ($file in $VerilogFiles) {
        $readCommandParts += (Format-YosysArgument -Value $file)
      }
      $yosysCommands += ($readCommandParts -join " ")
    }

    # Keep hierarchy for schematic generation. Running `opt` here collapses
    # wrapper/dataflow structure that users expect to see in diagrams.
    $yosysCommands += @(
      "hierarchy -top $Module",
      "proc",
      ("write_json " + (Format-YosysArgument -Value $jsonFile))
    )

    Set-Content -Path $yosysScriptFile -Value ($yosysCommands -join [Environment]::NewLine) -Encoding ASCII

    $yosysArgs = @("-s", $yosysScriptFileRel)
    if ($Frontend -eq "slang" -and $UseYosysPluginForSlang -and -not [string]::IsNullOrWhiteSpace($YosysPlugin)) {
      $yosysArgs = @("-m", $YosysPlugin) + $yosysArgs
    }

    $yosysOk = Invoke-ExternalCommand -Label "Yosys synthesis for $Module" -Command $YosysCmd -Arguments $yosysArgs
  }
  finally {
    if (Test-Path $yosysScriptFile) {
      Remove-Item -Path $yosysScriptFile -Force -ErrorAction SilentlyContinue
    }
  }
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
      $resolvedFrontend,
      $YosysPlugin,
      $NetlistSvgCmd,
      $processSchematicScript,
      $generateSimpleSvgScript,
      $svg2drawioScript,
      $skinPath,
      $logDir,
      $includeDirs,
      $useYosysPluginForSlang,
      $useReadSlangSingleThread
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
