Param(
  [string]$VerilogFile,
  [string]$OutputSvg
)

# Parse Verilog module to extract module name and ports
$content = Get-Content $VerilogFile -Raw

# Extract module name
if ($content -match 'module\s+(\w+)\s*[\(#]') {
  $moduleName = $Matches[1]
}
else {
  Write-Host "[ERROR] Could not find module declaration in $VerilogFile"
  exit 1
}

# Extract ports
$inputPorts = @()
$outputPorts = @()

# Find all input/output declarations
$content -split "`n" | ForEach-Object {
  $line = $_.Trim()
    
  # Match input declarations
  if ($line -match '^\s*input\s+(?:wire\s+)?(?:reg\s+)?(?:\[[\d:]+\]\s+)?(\w+)') {
    $portName = $Matches[1]
    # Extract bit width if present
    if ($line -match '\[(\d+):(\d+)\]') {
      $portName += "[" + $Matches[1] + ":" + $Matches[2] + "]"
    }
    $inputPorts += $portName
  }
    
  # Match output declarations
  if ($line -match '^\s*output\s+(?:wire\s+)?(?:reg\s+)?(?:\[[\d:]+\]\s+)?(\w+)') {
    $portName = $Matches[1]
    # Extract bit width if present  
    if ($line -match '\[(\d+):(\d+)\]') {
      $portName += "[" + $Matches[1] + ":" + $Matches[2] + "]"
    }
    $outputPorts += $portName
  }
}

Write-Host "[INFO] Module: $moduleName"
Write-Host "[INFO] Inputs: $($inputPorts.Count), Outputs: $($outputPorts.Count)"

# Calculate dimensions
$portSpacing = 25
$maxPorts = [Math]::Max($inputPorts.Count, $outputPorts.Count)
$boxHeight = [Math]::Max(150, $maxPorts * $portSpacing + 80)
$boxWidth = 400
$arrowLength = 80

# SVG coordinates
$boxX = 150
$boxY = 50
$moduleNameY = $boxY + $boxHeight - 30

# Generate SVG
$svg = @"
<svg xmlns="http://www.w3.org/2000/svg" width="800" height="$($boxHeight + 100)">
  <style>
    text {
      font-family: Arial, sans-serif;
      font-size: 14px;
      fill: black;
    }
    .module-name {
      font-size: 18px;
      font-weight: bold;
      text-anchor: middle;
    }
    .port-label {
      font-size: 12px;
    }
    .box {
      fill: white;
      stroke: black;
      stroke-width: 2;
    }
    .wire {
      stroke: black;
      stroke-width: 2;
      fill: none;
    }
    .arrow {
      fill: black;
    }
  </style>
  
  <!-- Module Box -->
  <rect class="box" x="$boxX" y="$boxY" width="$boxWidth" height="$boxHeight"/>
  
  <!-- Module Name -->
  <text class="module-name" x="$($boxX + $boxWidth/2)" y="$moduleNameY">$moduleName</text>
  
"@

# Add input ports (left side)
$inputY = $boxY + 40
foreach ($port in $inputPorts) {
  $svg += @"
  <!-- Input: $port -->
  <line class="wire" x1="$($boxX - $arrowLength)" y1="$inputY" x2="$boxX" y2="$inputY"/>
  <polygon class="arrow" points="$($boxX-8),$($inputY-4) $boxX,$inputY $($boxX-8),$($inputY+4)"/>
  <text class="port-label" x="$($boxX + 10)" y="$($inputY + 4)">$port</text>
  
"@
  $inputY += $portSpacing
}

# Add output ports (right side)
$outputY = $boxY + 40
foreach ($port in $outputPorts) {
  $outputXStart = $boxX + $boxWidth
  $outputXEnd = $outputXStart + $arrowLength
  $svg += @"
  <!-- Output: $port -->
  <line class="wire" x1="$outputXStart" y1="$outputY" x2="$outputXEnd" y2="$outputY"/>
  <polygon class="arrow" points="$($outputXEnd-8),$($outputY-4) $outputXEnd,$outputY $($outputXEnd-8),$($outputY+4)"/>
  <text class="port-label" text-anchor="end" x="$($boxX + $boxWidth - 10)" y="$($outputY + 4)">$port</text>
  
"@
  $outputY += $portSpacing
}

$svg += "</svg>"

# Write to file
Set-Content -Path $OutputSvg -Value $svg -Encoding UTF8
Write-Host "[SUCCESS] Generated simple module diagram: $OutputSvg"
