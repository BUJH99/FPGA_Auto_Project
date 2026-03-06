Param(
  [string]$VerilogFile,
  [string]$OutputSvg
)

$PORT_CHAR_WIDTH = 7
$MODULE_CHAR_WIDTH = 11

function Get-TextPixelWidth {
  Param(
    [string]$Text,
    [int]$CharWidth
  )

  if ([string]::IsNullOrWhiteSpace($Text)) {
    return 0
  }

  # Directly derive width from character count and constant width.
  return [Math]::Ceiling($Text.Length * $CharWidth)
}

function Get-DynamicBoxWidth {
  Param(
    [string]$ModuleName,
    [string[]]$InputPorts,
    [string[]]$OutputPorts
  )

  $allPorts = @($InputPorts + $OutputPorts)
  $maxPortTextWidth = 0
  if ($allPorts.Count -gt 0) {
    $maxPortTextWidth = ($allPorts |
      ForEach-Object { Get-TextPixelWidth -Text $_ -CharWidth $PORT_CHAR_WIDTH } |
      Measure-Object -Maximum).Maximum
  }

  $moduleTextWidth = Get-TextPixelWidth -Text $ModuleName -CharWidth $MODULE_CHAR_WIDTH

  $minWidth = 260
  $maxWidth = 700
  $labelPadding = 32

  $requiredWidth = [Math]::Max($maxPortTextWidth + $labelPadding, $moduleTextWidth + 24)
  return [Math]::Max($minWidth, [Math]::Min($maxWidth, [int]$requiredWidth))
}

function Remove-HdlComments {
  Param([string]$Text)

  if ($null -eq $Text) {
    return ""
  }

  $withoutBlock = [regex]::Replace($Text, '/\*[\s\S]*?\*/', '')
  return [regex]::Replace($withoutBlock, '//.*$', '', [System.Text.RegularExpressions.RegexOptions]::Multiline)
}

function Get-PortNamesFromDeclaration {
  Param(
    [string]$Line,
    [string]$Direction
  )

  if ([string]::IsNullOrWhiteSpace($Line)) {
    return @()
  }

  $decl = [regex]::Replace($Line, "^\s*$Direction\b", "", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  $decl = $decl.Trim().TrimEnd(",").TrimEnd(";")
  if ([string]::IsNullOrWhiteSpace($decl)) {
    return @()
  }

  $packedDims = @([regex]::Matches($decl, '\[[^\]]+\]') | ForEach-Object { $_.Value })
  $widthSuffix = if ($packedDims.Count -gt 0) { $packedDims -join "" } else { "" }
  $decl = [regex]::Replace($decl, '\[[^\]]+\]', ' ')
  $decl = [regex]::Replace(
    $decl,
    '\b(?:wire|reg|logic|var|signed|unsigned|bit|byte|shortint|int|longint|integer|time|shortreal|real|realtime|string|tri|tri0|tri1|supply0|supply1|wand|wor|uwire)\b',
    ' ',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )

  $ports = @()
  foreach ($part in ($decl -split ',')) {
    $candidate = ($part -split '=')[0].Trim()
    if ([string]::IsNullOrWhiteSpace($candidate)) {
      continue
    }

    if ($candidate -match '([A-Za-z_][A-Za-z0-9_$]*)') {
      $portName = $Matches[1]
      if (-not [string]::IsNullOrWhiteSpace($widthSuffix)) {
        $portName += $widthSuffix
      }
      $ports += $portName
    }
  }

  return @($ports)
}

# Parse Verilog/SystemVerilog module to extract module name and ports
$content = Remove-HdlComments -Text (Get-Content $VerilogFile -Raw)

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
  if (-not [string]::IsNullOrWhiteSpace($line)) {
    if ($line -match '^\s*input\b') {
      $inputPorts += Get-PortNamesFromDeclaration -Line $line -Direction "input"
    }

    if ($line -match '^\s*output\b') {
      $outputPorts += Get-PortNamesFromDeclaration -Line $line -Direction "output"
    }
  }
}

Write-Host "[INFO] Module: $moduleName"
Write-Host "[INFO] Inputs: $($inputPorts.Count), Outputs: $($outputPorts.Count)"

# Calculate dimensions
$portSpacing = 25
$maxPorts = [Math]::Max($inputPorts.Count, $outputPorts.Count)
$boxHeight = [Math]::Max(150, $maxPorts * $portSpacing + 80)
$arrowLength = [Math]::Max(24, [Math]::Round(80 * 0.4))
$arrowHeadLength = [Math]::Max(4, [Math]::Round($arrowLength * 0.22))
$arrowHeadHalfHeight = [Math]::Max(2, [Math]::Round($arrowHeadLength * 0.5))

# SVG coordinates
$boxX = 150
$boxY = 50
$boxWidth = Get-DynamicBoxWidth -ModuleName $moduleName -InputPorts $inputPorts -OutputPorts $outputPorts
$svgWidth = [Math]::Max(560, $boxX + $boxWidth + $arrowLength + 80)
$moduleNameY = $boxY + $boxHeight - 30

Write-Host "[INFO] Simple box width: $boxWidth"

# Generate SVG
$svg = @"
<svg xmlns="http://www.w3.org/2000/svg" width="$svgWidth" height="$($boxHeight + 100)">
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
  <polygon class="arrow" points="$($boxX-$arrowHeadLength),$($inputY-$arrowHeadHalfHeight) $boxX,$inputY $($boxX-$arrowHeadLength),$($inputY+$arrowHeadHalfHeight)"/>
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
  <polygon class="arrow" points="$($outputXEnd-$arrowHeadLength),$($outputY-$arrowHeadHalfHeight) $outputXEnd,$outputY $($outputXEnd-$arrowHeadLength),$($outputY+$arrowHeadHalfHeight)"/>
  <text class="port-label" text-anchor="end" x="$($boxX + $boxWidth - 10)" y="$($outputY + 4)">$port</text>
  
"@
  $outputY += $portSpacing
}

$svg += "</svg>"

# Write to file
Set-Content -Path $OutputSvg -Value $svg -Encoding UTF8
Write-Host "[SUCCESS] Generated simple module diagram: $OutputSvg"
