Param(
  [string]$JsonPath = "output.json",
  [string]$SkinPath = "skin.svg"
)

# 1. READ AND CLEAN JSON FIRST to determine sizing
$maxPortLen = 0
if (Test-Path $JsonPath) {
  try {
    $content = Get-Content $JsonPath -Raw
    # Clean $paramod$ prefixes
    $content = $content -replace '(?:\$paramod\$[a-f0-9]+\\\\)([a-zA-Z0-9_]+)', '$1'
    $content = $content -replace '(?:\$paramod\\\\)([a-zA-Z0-9_]+)(?:\\\\[^\"]+)', '$1'
        
    # Save cleaned JSON immediately
    Set-Content $JsonPath $content -Encoding UTF8
    Write-Host "[INFO] Cleaned JSON module names."

    # Parse JSON to find max port length
    $json = $content | ConvertFrom-Json
        
    # Traverse modules -> cells -> connections
    if ($json.modules) {
      foreach ($moduleProp in $json.modules.PSObject.Properties) {
        $module = $moduleProp.Value
        
        # FIX: Sanitize Ports
        if ($module.ports) {
            foreach ($portProp in $module.ports.PSObject.Properties) {
                $port = $portProp.Value
                # Fix direction: inout -> output (netlistsvg schema restriction)
                if ($port.direction -eq "inout") {
                    $port.direction = "output"
                }
                # Fix bits: "z" -> "x" (schema only allows 0, 1, x, or int)
                if ($port.bits) {
                    for ($i = 0; $i -lt $port.bits.Count; $i++) {
                        if ($port.bits[$i] -is [string]) {
                          if ([string]::IsNullOrWhiteSpace($port.bits[$i]) -or $port.bits[$i] -eq "z") {
                            $port.bits[$i] = "x"
                          }
                        }
                    }
                }
            }
        }

        # FIX: Sanitize Netnames
        if ($module.netnames) {
            foreach ($netProp in $module.netnames.PSObject.Properties) {
                $net = $netProp.Value
                if ($net.bits) {
                    for ($i = 0; $i -lt $net.bits.Count; $i++) {
                        if ($net.bits[$i] -is [string]) {
                          if ([string]::IsNullOrWhiteSpace($net.bits[$i]) -or $net.bits[$i] -eq "z") {
                            $net.bits[$i] = "x"
                          }
                        }
                    }
                }
            }
        }

        # FIX: Sanitize Cell Connections
        if ($module.cells) {
          foreach ($cellProp in $module.cells.PSObject.Properties) {
            $cell = $cellProp.Value

            # Fix cell port directions: inout -> output (netlistsvg schema restriction)
            if ($cell.port_directions) {
              foreach ($dirProp in $cell.port_directions.PSObject.Properties) {
                if ($dirProp.Value -eq "inout") {
                  $cell.port_directions.($dirProp.Name) = "output"
                }
              }
            }

            # Check if this cell is likely generic (has connections)
            if ($cell.connections) {
              foreach ($connProp in $cell.connections.PSObject.Properties) {
                # Find the longest port name (key) for sizing
                $portName = $connProp.Name
                if ($portName.Length -gt $maxPortLen) {
                  $maxPortLen = $portName.Length
                }
                
                # Fix connection bits: "z" -> "x"
                $connBits = $connProp.Value
                if ($connBits) {
                    for ($i = 0; $i -lt $connBits.Count; $i++) {
                        if ($connBits[$i] -is [string]) {
                          if ([string]::IsNullOrWhiteSpace($connBits[$i]) -or $connBits[$i] -eq "z") {
                            $connBits[$i] = "x"
                          }
                        }
                    }
                }
              }
            }
          }
        }
      }
    }
    
    # Save the sanitized JSON back to file (Depth 100 is critical)
    $cleanContent = $json | ConvertTo-Json -Depth 100
    Set-Content $JsonPath $cleanContent -Encoding UTF8
  }
  catch {
    Write-Host "[WARN] Failed to parse JSON for sizing: $_. Using default width."
  }
}

# Calculate dynamic width
# Simple heuristic: max(120, maxlen * 15px per char + padding)
$calcWidth = [Math]::Max(40, $maxPortLen * 10.5 + 30)
$sWidth = $calcWidth
$sHalf = $sWidth / 2

Write-Host "[INFO] Max port length detected: $maxPortLen. Setting generic module width to: $sWidth"


$skinContent = @"
<svg  xmlns="http://www.w3.org/2000/svg"
  xmlns:xlink="http://www.w3.org/1999/xlink"
  xmlns:s="https://github.com/nturley/netlistsvg"
  width="800" height="300">
  <s:properties>
    <s:layoutEngine
      org.eclipse.elk.layered.spacing.nodeNodeBetweenLayers="40"
      org.eclipse.elk.spacing.nodeNode="40"
      org.eclipse.elk.spacing.portPort="15"
      org.eclipse.elk.layered.layering.strategy="LONGEST_PATH"
    />
    <s:low_priority_alias val="`$dff" />
  </s:properties>
<style>
svg {
  stroke:#000;
  fill:none;
}
text {
  fill:#000;
  stroke:none;
  font-size:10px;
  font-weight: bold;
  font-family: Helvetica, Arial, sans-serif;
}
.nodelabel {
  text-anchor: middle;
}
.inputPortLabel {
  text-anchor: end;
}
.splitjoinBody {
  fill:#000;
}
</style>
  
  <g s:type="mux" transform="translate(50, 50)" s:width="20" s:height="40">
    <s:alias val="`$pmux"/>
    <s:alias val="`$mux"/>
    <s:alias val="`$_MUX_"/>
    <path d="M0,0 L20,10 L20,30 L0,40 Z" class="`$cell_id"/>
    <g s:x="0" s:y="10" s:pid="A"/>
    <g s:x="0" s:y="30" s:pid="B"/>
    <g s:x="10" s:y="35" s:pid="S"/>
    <g s:x="20" s:y="20" s:pid="Y"/>
  </g>

  <!-- Standard Gates -->
  <g s:type="and" transform="translate(150,50)" s:width="30" s:height="25">
    <s:alias val="`$and"/>
    <s:alias val="`$logic_and"/>
    <s:alias val="`$_AND_"/>
    <path d="M0,0 L0,25 L15,25 A15 12.5 0 0 0 15,0 Z" class="`$cell_id"/>
    <g s:x="0" s:y="5" s:pid="A"/>
    <g s:x="0" s:y="20" s:pid="B"/>
    <g s:x="30" s:y="12.5" s:pid="Y"/>
  </g>

  <g s:type="nand" transform="translate(150,100)" s:width="30" s:height="25">
    <s:alias val="`$nand"/>
    <s:alias val="`$logic_nand"/>
    <s:alias val="`$_NAND_"/>
    <path d="M0,0 L0,25 L15,25 A15 12.5 0 0 0 15,0 Z" class="`$cell_id"/>
    <circle cx="34" cy="12.5" r="3" class="`$cell_id"/>
    <g s:x="0" s:y="5" s:pid="A"/>
    <g s:x="0" s:y="20" s:pid="B"/>
    <g s:x="36" s:y="12.5" s:pid="Y"/>
  </g>

  <g s:type="or" transform="translate(250,50)" s:width="30" s:height="25">
    <s:alias val="`$or"/>
    <s:alias val="`$logic_or"/>
    <s:alias val="`$_OR_"/>
    <path d="M0,25 L0,25 L15,25 A15 12.5 0 0 0 15,0 L0,0" class="`$cell_id"/>
    <path d="M0,0 A30 25 0 0 1 0,25" class="`$cell_id"/>
    <g s:x="3" s:y="5" s:pid="A"/>
    <g s:x="3" s:y="20" s:pid="B"/>
    <g s:x="30" s:y="12.5" s:pid="Y"/>
  </g>

  <g s:type="reduce_xor" transform="translate(350, 50)" s:width="33" s:height="25">
    <s:alias val="`$xor"/>
    <s:alias val="`$reduce_xor"/>
    <s:alias val="`$_XOR_"/>
    <path d="M3,0 A30 25 0 0 1 3,25 A30 25 0 0 0 33,12.5 A30 25 0 0 0 3,0" class="`$cell_id"/>
    <path d="M0,0 A30 25 0 0 1 0,25" class="`$cell_id"/>
    <g s:x="3" s:y="5" s:pid="A"/>
    <g s:x="3" s:y="20" s:pid="B"/>
    <g s:x="33" s:y="12.5" s:pid="Y"/>
  </g>
  
  <!-- NOT Gate: Standard Triangle with Bubble -->
  <g s:type="not" transform="translate(450,100)" s:width="30" s:height="20">
    <s:alias val="`$_NOT_"/>
    <s:alias val="`$not"/>
    <s:alias val="`$logic_not"/>
    <!-- Triangle -->
    <path d="M0,0 L0,20 L20,10 Z" class="`$cell_id"/>
    <!-- Bubble -->
    <circle cx="23" cy="10" r="3" class="`$cell_id"/>
    <g s:x="0" s:y="10" s:pid="A"/>
    <!-- Output at the bubble tip -->
    <g s:x="26" s:y="10" s:pid="Y"/>
  </g>

  <g s:type="dff" transform="translate(350,150)" s:width="42" s:height="64">
    <s:alias val="`$dff"/>
    <s:alias val="`$adff"/>
    <s:alias val="`$_DFF_"/>
    <s:alias val="`$_DFF_P_"/>
    <rect width="42" height="64" x="0" y="0" class="`$cell_id"/>
    <text x="21" y="-4" class="nodelabel">D-FF</text>
    <path d="M0,35 L6,32 L0,29" class="`$cell_id"/>
    <g transform="translate(0,16)" s:x="0" s:y="16" s:pid="D">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">D</text>
    </g>
    <g transform="translate(0,32)" s:x="0" s:y="32" s:pid="CLK">
      <text x="8" y="3" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">CLK</text>
    </g>
    <g s:x="0" s:y="32" s:pid="C"/>
    <g transform="translate(0,48)" s:x="0" s:y="48" s:pid="ARST">
      <text x="2" y="4" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">ARST</text>
    </g>
    <g transform="translate(42,16)" s:x="42" s:y="16" s:pid="Q">
      <text x="-2" y="2" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Q</text>
    </g>
  </g>

  <!-- Input Port: LINE ONLY (No Double Arrow) -->
  <g s:type="inputExt" transform="translate(50,250)" s:width="30" s:height="20">
    <s:alias val="`$_inputExt_"/>
    <!-- Removed M24,6 L30,10 L24,14 (arrow head), kept only start line -->
    <!-- Just a line from left to right to connect to the wire -->
    <path d="M10,10 L30,10" class="`$cell_id" style="stroke-width:1px; fill:none;"/>
    <g s:x="30" s:y="10" s:pid="Y"/>
  </g>

   <!-- Constant -->
  <g s:type="constant" transform="translate(150,250)" s:width="30" s:height="20">
    <s:alias val="`$_constant_"/>
    <rect width="30" height="20" class="`$cell_id"/>
    <g s:x="30" s:y="10" s:pid="Y"/>
  </g>

  <!-- Output Port: LINE ONLY (No Double Arrow) -->
  <g s:type="outputExt" transform="translate(250,250)" s:width="30" s:height="20">
    <s:alias val="`$_outputExt_"/>
    <!-- Removed arrow head, kept only line -->
    <path d="M0,10 L20,10" class="`$cell_id" style="stroke-width:1px; fill:none;"/>
    <!-- Add outgoing arrow tip at the END of the diagram if desired, or just line -->
    <!-- Adding a single arrow tip at the very end of the port symbol -->
    <path d="M20,10 L15,7 M20,10 L15,13" class="`$cell_id" style="stroke-width:1px; fill:none; stroke-linecap:round;"/>
    <g s:x="0" s:y="10" s:pid="A"/>
  </g>

  <g s:type="split" transform="translate(350,250)" s:width="5" s:height="40">
    <rect width="5" height="40" class="splitjoinBody" s:generic="body"/>
    <s:alias val="`$_split_"/>
    <g s:x="0" s:y="20" s:pid="in"/>
    <g transform="translate(5, 10)" s:x="4" s:y="10" s:pid="out0">
      <text x="5" y="-4">hi:lo</text>
    </g>
    <g transform="translate(5, 30)" s:x="4" s:y="30" s:pid="out1">
      <text x="5" y="-4">hi:lo</text>
    </g>
  </g>

  <g s:type="join" transform="translate(450,250)" s:width="4" s:height="40">
    <rect width="5" height="40" class="splitjoinBody" s:generic="body"/>
    <s:alias val="`$_join_"/>
    <g s:x="5" s:y="20"  s:pid="out"/>
    <g transform="translate(0, 10)" s:x="0" s:y="10" s:pid="in0">
      <text x="-3" y="-4" class="inputPortLabel">hi:lo</text>
    </g>
    <g transform="translate(0, 30)" s:x="0" s:y="30" s:pid="in1">
      <text x="-3" y="-4" class="inputPortLabel">hi:lo</text>
    </g>
  </g>

  <!-- GENERIC MODULE: Enlarged Size + OUTSIDE Triangle Ports + Inside Labels -->
  <g s:type="generic" transform="translate(550,250)" s:width="$sWidth" s:height="40">
    <text x="$sHalf" y="-4" class="nodelabel `$cell_id" s:attribute="ref">generic</text>
    <rect width="$sWidth" height="40" s:generic="body" class="`$cell_id"/>

    <g transform="translate($sWidth, 10)" s:x="$sWidth" s:y="10" s:pid="out0">
       <path d="M0,-3 L5,0 L0,3 Z" style="fill:#000;"/>
      <text x="-8" y="4" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">out0</text>
    </g>
    <g transform="translate($sWidth, 30)" s:x="$sWidth" s:y="30" s:pid="out1">
       <path d="M0,-3 L5,0 L0,3 Z" style="fill:#000;"/>
      <text x="-8" y="4" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">out1</text>
    </g>
    
    <g transform="translate(0, 10)" s:x="0" s:y="10" s:pid="in0">
       <path d="M-5,-3 L0,0 L-5,3 Z" style="fill:#000;"/>
      <text x="8" y="4" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">in0</text>
    </g>
    <g transform="translate(0, 30)" s:x="0" s:y="30" s:pid="in1">
       <path d="M-5,-3 L0,0 L-5,3 Z" style="fill:#000;"/>
      <text x="8" y="4" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">in1</text>
    </g>
  </g>

</svg>
"@

Set-Content -Path $SkinPath -Value $skinContent -Encoding UTF8
Write-Host "[INFO] Generated skin file '$SkinPath' with dynamic width: $sWidth (Max port len: $maxPortLen)"
