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
  <g s:type="and" transform="translate(150,50)" s:width="62" s:height="54">
    <s:alias val="`$and"/>
    <s:alias val="`$logic_and"/>
    <s:alias val="`$_AND_"/>
    <path d="M0,0 L26,0 A26 27 0 0 1 26,54 L0,54 Z" class="`$cell_id"/>
    <g s:x="0" s:y="18" s:pid="A"/>
    <g s:x="0" s:y="36" s:pid="B"/>
    <g s:x="52" s:y="27" s:pid="Y"/>
  </g>

  <g s:type="nand" transform="translate(150,100)" s:width="68" s:height="54">
    <s:alias val="`$nand"/>
    <s:alias val="`$logic_nand"/>
    <s:alias val="`$_NAND_"/>
    <path d="M0,0 L26,0 A26 27 0 0 1 26,54 L0,54 Z" class="`$cell_id"/>
    <circle cx="66" cy="27" r="3" class="`$cell_id"/>
    <g s:x="0" s:y="18" s:pid="A"/>
    <g s:x="0" s:y="36" s:pid="B"/>
    <g s:x="68" s:y="27" s:pid="Y"/>
  </g>

  <g s:type="or" transform="translate(250,50)" s:width="62" s:height="54">
    <s:alias val="`$or"/>
    <s:alias val="`$logic_or"/>
    <s:alias val="`$_OR_"/>
    <path d="M0,0 C8,0 24,5 62,27 C24,49 8,54 0,54 C10,44 10,10 0,0 Z" class="`$cell_id"/>
    <g s:x="4" s:y="18" s:pid="A"/>
    <g s:x="4" s:y="36" s:pid="B"/>
    <g s:x="62" s:y="27" s:pid="Y"/>
  </g>

  <g s:type="xor" transform="translate(350, 50)" s:width="62" s:height="54">
    <s:alias val="`$xor"/>
    <s:alias val="`$_XOR_"/>
    <path d="M0,0 C8,0 24,5 62,27 C24,49 8,54 0,54 C10,44 10,10 0,0 Z" class="`$cell_id"/>
    <path d="M-5,0 C7,12 7,42 -5,54" class="`$cell_id"/>
    <g s:x="4" s:y="18" s:pid="A"/>
    <g s:x="4" s:y="36" s:pid="B"/>
    <g s:x="62" s:y="27" s:pid="Y"/>
  </g>

  <g s:type="reduce_xor" transform="translate(350, 50)" s:width="62" s:height="54">
    <s:alias val="`$reduce_xor"/>
    <path d="M0,0 C8,0 24,5 62,27 C24,49 8,54 0,54 C10,44 10,10 0,0 Z" class="`$cell_id"/>
    <path d="M-5,0 C7,12 7,42 -5,54" class="`$cell_id"/>
    <g s:x="4" s:y="27" s:pid="A"/>
    <g s:x="62" s:y="27" s:pid="Y"/>
  </g>
  
  <!-- NOT symbol based on Primitive_Symbols/not.svg -->
  <g s:type="not" transform="translate(450,100)" s:width="68" s:height="54">
    <s:alias val="`$_NOT_"/>
    <s:alias val="`$not"/>
    <s:alias val="`$logic_not"/>
    <path d="M0,0 L0,54 L54,27 Z" class="`$cell_id"/>
    <circle cx="60" cy="27" r="4.5" class="`$cell_id"/>
    <g transform="translate(0,27)" s:x="0" s:y="27" s:pid="A">
      <text x="2" y="0" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">A</text>
    </g>
    <g transform="translate(68,27)" s:x="68" s:y="27" s:pid="Y">
      <text x="-24" y="0" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Y</text>
    </g>
  </g>

  <g s:type="dff" transform="translate(350,150)" s:width="54" s:height="64">
    <s:alias val="`$dff"/>
    <s:alias val="`$_DFF_"/>
    <s:alias val="`$_DFF_P_"/>
    <s:alias val="`$_DFF_N_"/>
    <rect width="54" height="64" x="0" y="0" class="`$cell_id"/>
    <path d="M0,46 L6,43 L0,40" class="`$cell_id"/>
    <g transform="translate(0,22)" s:x="0" s:y="22" s:pid="D">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">D</text>
    </g>
    <g transform="translate(0,46)" s:x="0" s:y="46" s:pid="CLK">
      <text x="8" y="3" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">CLK</text>
    </g>
    <g s:x="0" s:y="46" s:pid="C"/>
    <g transform="translate(54,22)" s:x="54" s:y="22" s:pid="Q">
      <text x="-2" y="2" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Q</text>
    </g>
  </g>

  <!-- ADFF symbol based on Primitive_Symbols/adff.svg -->
  <g s:type="adff" transform="translate(350,150)" s:width="54" s:height="82">
    <s:alias val="`$adff"/>
    <rect x="0" y="18" width="54" height="64" class="`$cell_id"/>
    <path d="M27,0 L27,18" class="`$cell_id"/>
    <path d="M0,64 L6,61 L0,58" class="`$cell_id"/>

    <g transform="translate(0,39)" s:x="0" s:y="39" s:pid="D">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">D</text>
    </g>
    <g transform="translate(0,61)" s:x="0" s:y="61" s:pid="CLK">
      <text x="8" y="3" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">CLK</text>
    </g>
    <g s:x="0" s:y="61" s:pid="C"/>
    <g transform="translate(54,39)" s:x="54" s:y="39" s:pid="Q">
      <text x="-2" y="2" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Q</text>
    </g>
    <g transform="translate(27,0)" s:x="27" s:y="0" s:pid="ARST">
      <text x="0" y="28" style="fill:#000; stroke:none; text-anchor:middle; dominant-baseline: middle;" class="`$cell_id">CLR</text>
    </g>
  </g>

  <!-- ADFFE symbol based on Primitive_Symbols/adffe.svg -->
  <g s:type="adffe" transform="translate(350,150)" s:width="54" s:height="96">
    <s:alias val="`$adffe"/>
    <rect x="0" y="24" width="54" height="72" class="`$cell_id"/>
    <path d="M27,0 L27,24" class="`$cell_id"/>
    <path d="M0,78 L6,75 L0,72" class="`$cell_id"/>

    <g transform="translate(0,42)" s:x="0" s:y="42" s:pid="D">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">D</text>
    </g>
    <g transform="translate(0,60)" s:x="0" s:y="60" s:pid="EN">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">EN</text>
    </g>
    <g transform="translate(0,78)" s:x="0" s:y="78" s:pid="CLK">
      <text x="8" y="3" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">CLK</text>
    </g>
    <g s:x="0" s:y="78" s:pid="C"/>
    <g transform="translate(54,42)" s:x="54" s:y="42" s:pid="Q">
      <text x="-2" y="2" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Q</text>
    </g>
    <g transform="translate(27,0)" s:x="27" s:y="0" s:pid="ARST">
      <text x="0" y="34" style="fill:#000; stroke:none; text-anchor:middle; dominant-baseline: middle;" class="`$cell_id">CLR</text>
    </g>
  </g>

  <!-- DFFE symbol based on Primitive_Symbols/dffe.svg -->
  <g s:type="dffe" transform="translate(350,150)" s:width="54" s:height="82">
    <s:alias val="`$dffe"/>
    <s:alias val="`$_DFFE_NN_"/>
    <s:alias val="`$_DFFE_NP_"/>
    <s:alias val="`$_DFFE_PN_"/>
    <s:alias val="`$_DFFE_PP_"/>
    <rect x="0" y="18" width="54" height="64" class="`$cell_id"/>
    <path d="M0,62 L6,59 L0,56" class="`$cell_id"/>

    <g transform="translate(0,34)" s:x="0" s:y="34" s:pid="D">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">D</text>
    </g>
    <g transform="translate(0,48)" s:x="0" s:y="48" s:pid="EN">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">EN</text>
    </g>
    <g transform="translate(0,62)" s:x="0" s:y="62" s:pid="CLK">
      <text x="8" y="3" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">CLK</text>
    </g>
    <g s:x="0" s:y="62" s:pid="C"/>
    <g transform="translate(54,34)" s:x="54" s:y="34" s:pid="Q">
      <text x="-2" y="2" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Q</text>
    </g>
  </g>

  <!-- DLATCH symbol based on Primitive_Symbols/dlatch.svg -->
  <g s:type="dlatch" transform="translate(350,150)" s:width="54" s:height="64">
    <s:alias val="`$dlatch"/>
    <rect x="0" y="12" width="54" height="52" class="`$cell_id"/>
    <g transform="translate(0,28)" s:x="0" s:y="28" s:pid="D">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">D</text>
    </g>
    <g transform="translate(0,44)" s:x="0" s:y="44" s:pid="EN">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">EN</text>
    </g>
    <g transform="translate(54,28)" s:x="54" s:y="28" s:pid="Q">
      <text x="-2" y="2" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Q</text>
    </g>
  </g>

  <!-- Arithmetic / Compare symbols from Primitive_Symbols -->
  <g s:type="add" transform="translate(50,150)" s:width="54" s:height="54">
    <s:alias val="`$add"/>
    <circle cx="27" cy="27" r="27" class="`$cell_id"/>
    <text x="27" y="27" style="fill:#000; stroke:none; text-anchor:middle; dominant-baseline: middle; font-size:16px;" class="`$cell_id">+</text>
    <g transform="translate(0,18)" s:x="0" s:y="18" s:pid="A">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">A</text>
    </g>
    <g transform="translate(0,36)" s:x="0" s:y="36" s:pid="B">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">B</text>
    </g>
    <g transform="translate(54,27)" s:x="54" s:y="27" s:pid="Y">
      <text x="-2" y="2" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Y</text>
    </g>
  </g>

  <g s:type="sub" transform="translate(120,150)" s:width="54" s:height="54">
    <s:alias val="`$sub"/>
    <circle cx="27" cy="27" r="27" class="`$cell_id"/>
    <text x="27" y="27" style="fill:#000; stroke:none; text-anchor:middle; dominant-baseline: middle; font-size:16px;" class="`$cell_id">-</text>
    <g transform="translate(0,18)" s:x="0" s:y="18" s:pid="A">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">A</text>
    </g>
    <g transform="translate(0,36)" s:x="0" s:y="36" s:pid="B">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">B</text>
    </g>
    <g transform="translate(54,27)" s:x="54" s:y="27" s:pid="Y">
      <text x="-2" y="2" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Y</text>
    </g>
  </g>

  <g s:type="mul" transform="translate(150,150)" s:width="54" s:height="54">
    <s:alias val="`$mul"/>
    <circle cx="27" cy="27" r="27" class="`$cell_id"/>
    <text x="27" y="27" style="fill:#000; stroke:none; text-anchor:middle; dominant-baseline: middle; font-size:16px;" class="`$cell_id">*</text>
    <g transform="translate(0,18)" s:x="0" s:y="18" s:pid="A">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">A</text>
    </g>
    <g transform="translate(0,36)" s:x="0" s:y="36" s:pid="B">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">B</text>
    </g>
    <g transform="translate(54,27)" s:x="54" s:y="27" s:pid="Y">
      <text x="-2" y="2" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Y</text>
    </g>
  </g>

  <g s:type="div" transform="translate(220,150)" s:width="54" s:height="54">
    <s:alias val="`$div"/>
    <circle cx="27" cy="27" r="27" class="`$cell_id"/>
    <text x="27" y="27" style="fill:#000; stroke:none; text-anchor:middle; dominant-baseline: middle; font-size:16px;" class="`$cell_id">/</text>
    <g transform="translate(0,18)" s:x="0" s:y="18" s:pid="A">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">A</text>
    </g>
    <g transform="translate(0,36)" s:x="0" s:y="36" s:pid="B">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">B</text>
    </g>
    <g transform="translate(54,27)" s:x="54" s:y="27" s:pid="Y">
      <text x="-2" y="2" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Y</text>
    </g>
  </g>

  <g s:type="mod" transform="translate(290,150)" s:width="54" s:height="54">
    <s:alias val="`$mod"/>
    <circle cx="27" cy="27" r="27" class="`$cell_id"/>
    <text x="27" y="27" style="fill:#000; stroke:none; text-anchor:middle; dominant-baseline: middle; font-size:16px;" class="`$cell_id">%</text>
    <g transform="translate(0,18)" s:x="0" s:y="18" s:pid="A">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">A</text>
    </g>
    <g transform="translate(0,36)" s:x="0" s:y="36" s:pid="B">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">B</text>
    </g>
    <g transform="translate(54,27)" s:x="54" s:y="27" s:pid="Y">
      <text x="-2" y="2" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Y</text>
    </g>
  </g>

  <g s:type="pow" transform="translate(360,150)" s:width="54" s:height="54">
    <s:alias val="`$pow"/>
    <circle cx="27" cy="27" r="27" class="`$cell_id"/>
    <text x="27" y="27" style="fill:#000; stroke:none; text-anchor:middle; dominant-baseline: middle; font-size:14px;" class="`$cell_id">**</text>
    <g transform="translate(0,18)" s:x="0" s:y="18" s:pid="A">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">A</text>
    </g>
    <g transform="translate(0,36)" s:x="0" s:y="36" s:pid="B">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">B</text>
    </g>
    <g transform="translate(54,27)" s:x="54" s:y="27" s:pid="Y">
      <text x="-2" y="2" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Y</text>
    </g>
  </g>

  <g s:type="eq" transform="translate(190,150)" s:width="54" s:height="54">
    <s:alias val="`$eq"/>
    <circle cx="27" cy="27" r="27" class="`$cell_id"/>
    <text x="27" y="27" style="fill:#000; stroke:none; text-anchor:middle; dominant-baseline: middle; font-size:16px;" class="`$cell_id">=</text>
    <g transform="translate(0,18)" s:x="0" s:y="18" s:pid="A">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">A</text>
    </g>
    <g transform="translate(0,36)" s:x="0" s:y="36" s:pid="B">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">B</text>
    </g>
    <g transform="translate(54,27)" s:x="54" s:y="27" s:pid="Y">
      <text x="-2" y="2" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Y</text>
    </g>
  </g>

  <g s:type="ne" transform="translate(260,150)" s:width="54" s:height="54">
    <s:alias val="`$ne"/>
    <circle cx="27" cy="27" r="27" class="`$cell_id"/>
    <text x="27" y="27" style="fill:#000; stroke:none; text-anchor:middle; dominant-baseline: middle; font-size:14px;" class="`$cell_id">!=</text>
    <g transform="translate(0,18)" s:x="0" s:y="18" s:pid="A">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">A</text>
    </g>
    <g transform="translate(0,36)" s:x="0" s:y="36" s:pid="B">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">B</text>
    </g>
    <g transform="translate(54,27)" s:x="54" s:y="27" s:pid="Y">
      <text x="-2" y="2" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Y</text>
    </g>
  </g>

  <g s:type="ge" transform="translate(330,150)" s:width="54" s:height="54">
    <s:alias val="`$ge"/>
    <circle cx="27" cy="27" r="27" class="`$cell_id"/>
    <text x="27" y="27" style="fill:#000; stroke:none; text-anchor:middle; dominant-baseline: middle; font-size:14px;" class="`$cell_id">&gt;=</text>
    <g transform="translate(0,18)" s:x="0" s:y="18" s:pid="A">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">A</text>
    </g>
    <g transform="translate(0,36)" s:x="0" s:y="36" s:pid="B">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">B</text>
    </g>
    <g transform="translate(54,27)" s:x="54" s:y="27" s:pid="Y">
      <text x="-2" y="2" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Y</text>
    </g>
  </g>

  <g s:type="gt" transform="translate(400,150)" s:width="54" s:height="54">
    <s:alias val="`$gt"/>
    <circle cx="27" cy="27" r="27" class="`$cell_id"/>
    <text x="27" y="27" style="fill:#000; stroke:none; text-anchor:middle; dominant-baseline: middle; font-size:16px;" class="`$cell_id">&gt;</text>
    <g transform="translate(0,18)" s:x="0" s:y="18" s:pid="A">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">A</text>
    </g>
    <g transform="translate(0,36)" s:x="0" s:y="36" s:pid="B">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">B</text>
    </g>
    <g transform="translate(54,27)" s:x="54" s:y="27" s:pid="Y">
      <text x="-2" y="2" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Y</text>
    </g>
  </g>

  <g s:type="lt" transform="translate(470,150)" s:width="54" s:height="54">
    <s:alias val="`$lt"/>
    <circle cx="27" cy="27" r="27" class="`$cell_id"/>
    <text x="27" y="27" style="fill:#000; stroke:none; text-anchor:middle; dominant-baseline: middle; font-size:16px;" class="`$cell_id">&lt;</text>
    <g transform="translate(0,18)" s:x="0" s:y="18" s:pid="A">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">A</text>
    </g>
    <g transform="translate(0,36)" s:x="0" s:y="36" s:pid="B">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">B</text>
    </g>
    <g transform="translate(54,27)" s:x="54" s:y="27" s:pid="Y">
      <text x="-2" y="2" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Y</text>
    </g>
  </g>

  <g s:type="le" transform="translate(540,150)" s:width="54" s:height="54">
    <s:alias val="`$le"/>
    <circle cx="27" cy="27" r="27" class="`$cell_id"/>
    <text x="27" y="27" style="fill:#000; stroke:none; text-anchor:middle; dominant-baseline: middle; font-size:14px;" class="`$cell_id">&lt;=</text>
    <g transform="translate(0,18)" s:x="0" s:y="18" s:pid="A">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">A</text>
    </g>
    <g transform="translate(0,36)" s:x="0" s:y="36" s:pid="B">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">B</text>
    </g>
    <g transform="translate(54,27)" s:x="54" s:y="27" s:pid="Y">
      <text x="-2" y="2" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Y</text>
    </g>
  </g>

  <g s:type="eqx" transform="translate(610,150)" s:width="54" s:height="54">
    <s:alias val="`$eqx"/>
    <circle cx="27" cy="27" r="27" class="`$cell_id"/>
    <text x="27" y="27" style="fill:#000; stroke:none; text-anchor:middle; dominant-baseline: middle; font-size:12px;" class="`$cell_id">===</text>
    <g transform="translate(0,18)" s:x="0" s:y="18" s:pid="A">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">A</text>
    </g>
    <g transform="translate(0,36)" s:x="0" s:y="36" s:pid="B">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">B</text>
    </g>
    <g transform="translate(54,27)" s:x="54" s:y="27" s:pid="Y">
      <text x="-2" y="2" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Y</text>
    </g>
  </g>

  <g s:type="nex" transform="translate(680,150)" s:width="54" s:height="54">
    <s:alias val="`$nex"/>
    <circle cx="27" cy="27" r="27" class="`$cell_id"/>
    <text x="27" y="27" style="fill:#000; stroke:none; text-anchor:middle; dominant-baseline: middle; font-size:12px;" class="`$cell_id">!==</text>
    <g transform="translate(0,18)" s:x="0" s:y="18" s:pid="A">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">A</text>
    </g>
    <g transform="translate(0,36)" s:x="0" s:y="36" s:pid="B">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">B</text>
    </g>
    <g transform="translate(54,27)" s:x="54" s:y="27" s:pid="Y">
      <text x="-2" y="2" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Y</text>
    </g>
  </g>

  <g s:type="xnor" transform="translate(750,150)" s:width="68" s:height="54">
    <s:alias val="`$xnor"/>
    <s:alias val="`$_XNOR_"/>
    <path d="M0,0 C10,0 30,5 58,27 C30,49 10,54 0,54 C14,42 14,12 0,0 Z" class="`$cell_id"/>
    <path d="M-5,0 C7,12 7,42 -5,54" class="`$cell_id"/>
    <circle cx="62" cy="27" r="3" class="`$cell_id"/>
    <g transform="translate(0,18)" s:x="0" s:y="18" s:pid="A">
      <text x="10" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">A</text>
    </g>
    <g transform="translate(0,36)" s:x="0" s:y="36" s:pid="B">
      <text x="10" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">B</text>
    </g>
    <g transform="translate(68,27)" s:x="68" s:y="27" s:pid="Y">
      <text x="-15" y="2" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Y</text>
    </g>
  </g>

  <!-- Reduce / Shift symbols from Primitive_Symbols -->
  <g s:type="reduce_and" transform="translate(50,220)" s:width="62" s:height="54">
    <s:alias val="`$reduce_and"/>
    <path d="M0,0 L26,0 A26 27 0 0 1 26,54 L0,54 Z" class="`$cell_id"/>
    <g transform="translate(0,27)" s:x="0" s:y="27" s:pid="A">
      <text x="4" y="0" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">A</text>
    </g>
    <g transform="translate(52,27)" s:x="52" s:y="27" s:pid="Y">
      <text x="-12" y="0" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Y</text>
    </g>
  </g>

  <g s:type="reduce_or" transform="translate(130,220)" s:width="62" s:height="54">
    <s:alias val="`$reduce_or"/>
    <path d="M0,0 C8,0 24,5 62,27 C24,49 8,54 0,54 C10,44 10,10 0,0 Z" class="`$cell_id"/>
    <g transform="translate(0,27)" s:x="0" s:y="27" s:pid="A">
      <text x="8" y="0" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">A</text>
    </g>
    <g transform="translate(62,27)" s:x="62" s:y="27" s:pid="Y">
      <text x="-8" y="0" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Y</text>
    </g>
  </g>

  <g s:type="reduce_bool" transform="translate(210,220)" s:width="62" s:height="54">
    <s:alias val="`$reduce_bool"/>
    <path d="M0,0 C8,0 24,5 62,27 C24,49 8,54 0,54 C10,44 10,10 0,0 Z" class="`$cell_id"/>
    <text x="35" y="27" style="fill:#000; stroke:none; text-anchor:middle; dominant-baseline: middle; font-size:16px;" class="`$cell_id">?</text>
    <g transform="translate(0,27)" s:x="0" s:y="27" s:pid="A">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">A</text>
    </g>
    <g transform="translate(62,27)" s:x="62" s:y="27" s:pid="Y">
      <text x="-2" y="2" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Y</text>
    </g>
  </g>

  <g s:type="reduce_xnor" transform="translate(290,220)" s:width="68" s:height="54">
    <s:alias val="`$reduce_xnor"/>
    <path d="M0,0 C10,0 30,5 58,27 C30,49 10,54 0,54 C14,42 14,12 0,0 Z" class="`$cell_id"/>
    <path d="M-5,0 C7,12 7,42 -5,54" class="`$cell_id"/>
    <circle cx="62" cy="27" r="3" class="`$cell_id"/>
    <g transform="translate(0,27)" s:x="0" s:y="27" s:pid="A">
      <text x="10" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">A</text>
    </g>
    <g transform="translate(68,27)" s:x="68" s:y="27" s:pid="Y">
      <text x="-15" y="2" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Y</text>
    </g>
  </g>

  <g s:type="neg" transform="translate(370,220)" s:width="54" s:height="54">
    <s:alias val="`$neg"/>
    <circle cx="27" cy="27" r="27" class="`$cell_id"/>
    <text x="27" y="27" style="fill:#000; stroke:none; text-anchor:middle; dominant-baseline: middle; font-size:16px;" class="`$cell_id">~</text>
    <g transform="translate(0,27)" s:x="0" s:y="27" s:pid="A">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">A</text>
    </g>
    <g transform="translate(54,27)" s:x="54" s:y="27" s:pid="Y">
      <text x="-2" y="2" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Y</text>
    </g>
  </g>

  <g s:type="shiftx" transform="translate(290,220)" s:width="62" s:height="54">
    <s:alias val="`$shiftx"/>
    <path d="M8,0 L62,0 L54,54 L0,54 Z" class="`$cell_id"/>
    <text x="31" y="27" style="fill:#000; stroke:none; text-anchor:middle; dominant-baseline: middle; font-size:12px;" class="`$cell_id">SH</text>
    <g transform="translate(0,18)" s:x="0" s:y="18" s:pid="A">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">A</text>
    </g>
    <g transform="translate(0,36)" s:x="0" s:y="36" s:pid="B">
      <text x="2" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">B</text>
    </g>
    <g transform="translate(62,27)" s:x="62" s:y="27" s:pid="Y">
      <text x="-2" y="2" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Y</text>
    </g>
  </g>

  <g s:type="shl" transform="translate(370,220)" s:width="62" s:height="54">
    <s:alias val="`$shl"/>
    <path d="M8,0 L62,0 L54,54 L0,54 Z" class="`$cell_id"/>
    <text x="31" y="27" style="fill:#000; stroke:none; text-anchor:middle; dominant-baseline: middle; font-size:12px;" class="`$cell_id">&lt;&lt;</text>
    <g transform="translate(0,18)" s:x="0" s:y="18" s:pid="A">
      <text x="6" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">A</text>
    </g>
    <g transform="translate(0,36)" s:x="0" s:y="36" s:pid="B">
      <text x="6" y="2" style="fill:#000; stroke:none; text-anchor:start; dominant-baseline: middle;" class="`$cell_id">B</text>
    </g>
    <g transform="translate(62,27)" s:x="62" s:y="27" s:pid="Y">
      <text x="-6" y="2" style="fill:#000; stroke:none; text-anchor:end; dominant-baseline: middle;" class="`$cell_id">Y</text>
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
    <!-- Keep shaft and chevron in one path so the SVG renderer does not
         anti-alias them as visually separate pieces. -->
    <path d="M0,10 L20,10 L15,7 M20,10 L15,13"
          class="`$cell_id"
          style="stroke-width:1px; fill:none; stroke-linecap:round; stroke-linejoin:round;"/>
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
