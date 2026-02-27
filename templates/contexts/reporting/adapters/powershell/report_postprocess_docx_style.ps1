param(
    [Parameter(Mandatory = $true)]
    [string]$DocxPath,

    [switch]$EnableCodeBlockTable
)

$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────
#  Helper: w:val attribute setter
# ─────────────────────────────────────────────
function Set-ValAttr {
    param(
        [xml]$XmlDoc,
        [System.Xml.XmlElement]$Element,
        [string]$Value,
        [string]$WordNs
    )
    $attr = $Element.GetAttributeNode("val", $WordNs)
    if (-not $attr) {
        $attr = $XmlDoc.CreateAttribute("w", "val", $WordNs)
        [void]$Element.Attributes.Append($attr)
    }
    $attr.Value = $Value
}

function Set-NamedAttr {
    param(
        [xml]$XmlDoc,
        [System.Xml.XmlElement]$Element,
        [string]$AttrName,
        [string]$Value,
        [string]$WordNs
    )
    $attr = $Element.GetAttributeNode($AttrName, $WordNs)
    if (-not $attr) {
        $attr = $XmlDoc.CreateAttribute("w", $AttrName, $WordNs)
        [void]$Element.Attributes.Append($attr)
    }
    $attr.Value = $Value
}

function Get-OrCreateChild {
    param(
        [xml]$XmlDoc,
        [System.Xml.XmlNode]$Parent,
        [string]$LocalName,
        [System.Xml.XmlNamespaceManager]$NsMgr
    )
    $node = $Parent.SelectSingleNode("w:$LocalName", $NsMgr)
    if (-not $node) {
        $node = $XmlDoc.CreateElement("w", $LocalName, $NsMgr.LookupNamespace("w"))
        [void]$Parent.AppendChild($node)
    }
    return , $node
}

function Get-SingleXmlNode {
    param(
        [Parameter(Mandatory = $true)]
        $Value,
        [string]$Context = "XmlNode"
    )
    if ($Value -is [System.Xml.XmlNode]) { return , $Value }
    if ($Value -is [System.Array]) {
        foreach ($item in $Value) {
            if ($item -is [System.Xml.XmlNode]) { return , $item }
        }
    }
    throw "Failed to resolve single XmlNode for $Context. Actual type: $($Value.GetType().FullName)"
}

# ─────────────────────────────────────────────
#  Style setters
# ─────────────────────────────────────────────
function Set-StyleFont {
    param(
        [xml]$XmlDoc,
        [System.Xml.XmlNamespaceManager]$NsMgr,
        [string]$StyleId,
        [int]$HalfPointSize,
        [string]$FontName
    )
    $style = $XmlDoc.SelectSingleNode("//w:style[@w:styleId='$StyleId']", $NsMgr)
    if (-not $style) { return }

    $rPr = Get-OrCreateChild -XmlDoc $XmlDoc -Parent $style -LocalName "rPr" -NsMgr $NsMgr
    $sz = Get-OrCreateChild -XmlDoc $XmlDoc -Parent $rPr -LocalName "sz"     -NsMgr $NsMgr
    $szCs = Get-OrCreateChild -XmlDoc $XmlDoc -Parent $rPr -LocalName "szCs"   -NsMgr $NsMgr
    $rFonts = Get-OrCreateChild -XmlDoc $XmlDoc -Parent $rPr -LocalName "rFonts" -NsMgr $NsMgr

    $wNs = $NsMgr.LookupNamespace("w")
    Set-ValAttr -XmlDoc $XmlDoc -Element $sz   -Value "$HalfPointSize" -WordNs $wNs
    Set-ValAttr -XmlDoc $XmlDoc -Element $szCs -Value "$HalfPointSize" -WordNs $wNs
    foreach ($name in @("ascii", "hAnsi", "eastAsia", "cs")) {
        Set-NamedAttr -XmlDoc $XmlDoc -Element $rFonts -AttrName $name -Value $FontName -WordNs $wNs
    }
}

function Set-StyleColor {
    param(
        [xml]$XmlDoc,
        [System.Xml.XmlNamespaceManager]$NsMgr,
        [string]$StyleId,
        [string]$ColorHex
    )
    $style = $XmlDoc.SelectSingleNode("//w:style[@w:styleId='$StyleId']", $NsMgr)
    if (-not $style) { return }

    $rPr = Get-OrCreateChild -XmlDoc $XmlDoc -Parent $style -LocalName "rPr"   -NsMgr $NsMgr
    $color = Get-OrCreateChild -XmlDoc $XmlDoc -Parent $rPr  -LocalName "color" -NsMgr $NsMgr
    $wNs = $NsMgr.LookupNamespace("w")
    Set-ValAttr -XmlDoc $XmlDoc -Element $color -Value $ColorHex -WordNs $wNs
}

function Set-StyleBold {
    param(
        [xml]$XmlDoc,
        [System.Xml.XmlNamespaceManager]$NsMgr,
        [string]$StyleId
    )
    $style = $XmlDoc.SelectSingleNode("//w:style[@w:styleId='$StyleId']", $NsMgr)
    if (-not $style) { return }

    $rPr = Get-OrCreateChild -XmlDoc $XmlDoc -Parent $style -LocalName "rPr" -NsMgr $NsMgr
    [void](Get-OrCreateChild -XmlDoc $XmlDoc -Parent $rPr   -LocalName "b"   -NsMgr $NsMgr)
    [void](Get-OrCreateChild -XmlDoc $XmlDoc -Parent $rPr   -LocalName "bCs" -NsMgr $NsMgr)
    # presence of <w:b/> means bold; no value attribute needed
}

function Set-StyleSpacing {
    param(
        [xml]$XmlDoc,
        [System.Xml.XmlNamespaceManager]$NsMgr,
        [string]$StyleId,
        [int]$BeforeTwips,
        [int]$AfterTwips,
        [int]$LineTwips = 0,
        [string]$LineRule = "auto"
    )
    $style = $XmlDoc.SelectSingleNode("//w:style[@w:styleId='$StyleId']", $NsMgr)
    if (-not $style) { return }

    $pPr = Get-OrCreateChild -XmlDoc $XmlDoc -Parent $style -LocalName "pPr"     -NsMgr $NsMgr
    $spacing = Get-OrCreateChild -XmlDoc $XmlDoc -Parent $pPr  -LocalName "spacing" -NsMgr $NsMgr

    $wNs = $NsMgr.LookupNamespace("w")
    $attr = $spacing.GetAttributeNode("before", $wNs)
    if (-not $attr) { $attr = $XmlDoc.CreateAttribute("w", "before", $wNs); [void]$spacing.Attributes.Append($attr) }
    $attr.Value = "$BeforeTwips"

    $attr = $spacing.GetAttributeNode("after", $wNs)
    if (-not $attr) { $attr = $XmlDoc.CreateAttribute("w", "after", $wNs); [void]$spacing.Attributes.Append($attr) }
    $attr.Value = "$AfterTwips"

    if ($LineTwips -gt 0) {
        $attr = $spacing.GetAttributeNode("line", $wNs)
        if (-not $attr) { $attr = $XmlDoc.CreateAttribute("w", "line", $wNs); [void]$spacing.Attributes.Append($attr) }
        $attr.Value = "$LineTwips"

        $attr = $spacing.GetAttributeNode("lineRule", $wNs)
        if (-not $attr) { $attr = $XmlDoc.CreateAttribute("w", "lineRule", $wNs); [void]$spacing.Attributes.Append($attr) }
        $attr.Value = $LineRule
    }
}

function Set-StylePageBreakBefore {
    param(
        [xml]$XmlDoc,
        [System.Xml.XmlNamespaceManager]$NsMgr,
        [string]$StyleId
    )
    $style = $XmlDoc.SelectSingleNode("//w:style[@w:styleId='$StyleId']", $NsMgr)
    if (-not $style) { return }

    $pPr = Get-OrCreateChild -XmlDoc $XmlDoc -Parent $style -LocalName "pPr"             -NsMgr $NsMgr
    $pageBreakBefore = Get-OrCreateChild -XmlDoc $XmlDoc -Parent $pPr  -LocalName "pageBreakBefore" -NsMgr $NsMgr
    $wNs = $NsMgr.LookupNamespace("w")
    Set-ValAttr -XmlDoc $XmlDoc -Element $pageBreakBefore -Value "1" -WordNs $wNs
}

# ─────────────────────────────────────────────
#  Code paragraph helpers
# ─────────────────────────────────────────────
function Get-CodeParagraphStyleIds {
    param(
        [xml]$StylesXml,
        [System.Xml.XmlNamespaceManager]$NsMgr
    )
    $styleIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $wNs = $NsMgr.LookupNamespace("w")
    $pattern = "(?i)(source|code|verbatim|preformatted)"

    $styleNodes = $StylesXml.SelectNodes("//w:style", $NsMgr)
    foreach ($styleNode in $styleNodes) {
        if (-not ($styleNode -is [System.Xml.XmlElement])) { continue }
        $styleType = $styleNode.GetAttribute("type", $wNs)
        if ($styleType -ne "paragraph") { continue }
        $styleId = $styleNode.GetAttribute("styleId", $wNs)
        if ([string]::IsNullOrWhiteSpace($styleId)) { continue }
        $nameNode = $styleNode.SelectSingleNode("w:name", $NsMgr)
        $nameVal = ""
        if ($nameNode -is [System.Xml.XmlElement]) {
            $nameVal = $nameNode.GetAttribute("val", $wNs)
        }
        if ($styleId -match $pattern -or $nameVal -match $pattern) {
            [void]$styleIds.Add($styleId)
        }
    }
    if ($styleIds.Count -eq 0) {
        foreach ($fallback in @("SourceCode", "CodeBlock", "Verbatim")) {
            [void]$styleIds.Add($fallback)
        }
    }
    return , $styleIds
}

function Test-IsCodeParagraph {
    param(
        [System.Xml.XmlNode]$Node,
        [System.Collections.Generic.HashSet[string]]$CodeStyleIds,
        [System.Xml.XmlNamespaceManager]$NsMgr
    )
    if (-not $Node -or $Node.LocalName -ne "p") { return $false }
    if (-not $CodeStyleIds -or $CodeStyleIds.Count -eq 0) { return $false }
    $pStyleNode = $Node.SelectSingleNode("w:pPr/w:pStyle", $NsMgr)
    if (-not ($pStyleNode -is [System.Xml.XmlElement])) { return $false }
    $wNs = $NsMgr.LookupNamespace("w")
    $styleId = $pStyleNode.GetAttribute("val", $wNs)
    if ([string]::IsNullOrWhiteSpace($styleId)) { return $false }
    return $CodeStyleIds.Contains($styleId)
}

function New-CodeBlockTableNode {
    param(
        [xml]$XmlDoc,
        [string]$WordNs,
        [System.Collections.Generic.List[System.Xml.XmlNode]]$ParagraphNodes
    )
    $tbl = $XmlDoc.CreateElement("w", "tbl", $WordNs)
    $tblPr = $XmlDoc.CreateElement("w", "tblPr", $WordNs)
    [void]$tbl.AppendChild($tblPr)

    $tblW = $XmlDoc.CreateElement("w", "tblW", $WordNs)
    $tblW.SetAttribute("w", $WordNs, "0")
    $tblW.SetAttribute("type", $WordNs, "auto")
    [void]$tblPr.AppendChild($tblW)

    $tblBorders = $XmlDoc.CreateElement("w", "tblBorders", $WordNs)
    foreach ($edge in @("top", "left", "bottom", "right", "insideH", "insideV")) {
        $border = $XmlDoc.CreateElement("w", $edge, $WordNs)
        $border.SetAttribute("val", $WordNs, "single")
        $border.SetAttribute("sz", $WordNs, "6")
        $border.SetAttribute("space", $WordNs, "0")
        $border.SetAttribute("color", $WordNs, "A6A6A6")
        [void]$tblBorders.AppendChild($border)
    }
    [void]$tblPr.AppendChild($tblBorders)

    $tblCellMar = $XmlDoc.CreateElement("w", "tblCellMar", $WordNs)
    foreach ($side in @("top", "left", "bottom", "right")) {
        $m = $XmlDoc.CreateElement("w", $side, $WordNs)
        $m.SetAttribute("w", $WordNs, "80")
        $m.SetAttribute("type", $WordNs, "dxa")
        [void]$tblCellMar.AppendChild($m)
    }
    [void]$tblPr.AppendChild($tblCellMar)

    $tblGrid = $XmlDoc.CreateElement("w", "tblGrid", $WordNs)
    $gridCol = $XmlDoc.CreateElement("w", "gridCol", $WordNs)
    $gridCol.SetAttribute("w", $WordNs, "0")
    [void]$tblGrid.AppendChild($gridCol)
    [void]$tbl.AppendChild($tblGrid)

    $tr = $XmlDoc.CreateElement("w", "tr", $WordNs)
    $tc = $XmlDoc.CreateElement("w", "tc", $WordNs)
    $tcPr = $XmlDoc.CreateElement("w", "tcPr", $WordNs)
    $tcW = $XmlDoc.CreateElement("w", "tcW", $WordNs)
    $tcW.SetAttribute("w", $WordNs, "0")
    $tcW.SetAttribute("type", $WordNs, "auto")
    [void]$tcPr.AppendChild($tcW)
    [void]$tc.AppendChild($tcPr)

    foreach ($paragraphNode in $ParagraphNodes) {
        $cloned = $paragraphNode.CloneNode($true)
        [void]$tc.AppendChild($cloned)
    }
    [void]$tr.AppendChild($tc)
    [void]$tbl.AppendChild($tr)
    return , $tbl
}

# ─────────────────────────────────────────────
#  MAIN
# ─────────────────────────────────────────────
if (-not (Test-Path -LiteralPath $DocxPath)) {
    Write-Error "[ERROR] DOCX file not found: $DocxPath"
}

$resolvedDocx = (Resolve-Path -LiteralPath $DocxPath).Path
$guid = [guid]::NewGuid().ToString("N")
$workDir = Join-Path $env:TEMP ("docx_style_work_" + $guid)
$inputZip = Join-Path $env:TEMP ("docx_style_input_" + $guid + ".zip")
$rebuiltZip = Join-Path $env:TEMP ("docx_style_rebuilt_" + $guid + ".zip")

try {
    Copy-Item -LiteralPath $resolvedDocx -Destination $inputZip -Force
    Expand-Archive -LiteralPath $inputZip -DestinationPath $workDir -Force

    $stylesPath = Join-Path $workDir "word\styles.xml"
    $documentPath = Join-Path $workDir "word\document.xml"
    if (-not (Test-Path -LiteralPath $stylesPath)) {
        throw "styles.xml not found in DOCX."
    }

    # ── Load styles.xml ──────────────────────────────────────────────
    [xml]$xml = Get-Content -LiteralPath $stylesPath -Raw -Encoding UTF8
    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace("w", "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
    $wNs = $ns.LookupNamespace("w")

    # ── Default body: Malgun Gothic 10.5 pt, line-height 1.15 ────────
    $docDefaults = $xml.SelectSingleNode("//w:docDefaults", $ns)
    if ($docDefaults) {
        $rPrDefault = $xml.SelectSingleNode("//w:docDefaults/w:rPrDefault", $ns)
        if (-not $rPrDefault) {
            $rPrDefault = $xml.CreateElement("w", "rPrDefault", $wNs)
            [void]$docDefaults.AppendChild($rPrDefault)
        }
        $rPr = Get-OrCreateChild -XmlDoc $xml -Parent $rPrDefault -LocalName "rPr"    -NsMgr $ns
        $rFonts = Get-OrCreateChild -XmlDoc $xml -Parent $rPr        -LocalName "rFonts" -NsMgr $ns
        $sz = Get-OrCreateChild -XmlDoc $xml -Parent $rPr        -LocalName "sz"     -NsMgr $ns
        $szCs = Get-OrCreateChild -XmlDoc $xml -Parent $rPr        -LocalName "szCs"   -NsMgr $ns
        foreach ($name in @("ascii", "hAnsi", "eastAsia", "cs")) {
            Set-NamedAttr -XmlDoc $xml -Element $rFonts -AttrName $name -Value "Malgun Gothic" -WordNs $wNs
        }
        Set-ValAttr -XmlDoc $xml -Element $sz   -Value "21" -WordNs $wNs  # 10.5pt
        Set-ValAttr -XmlDoc $xml -Element $szCs -Value "21" -WordNs $wNs
    }

    # ── Default paragraph: spacing ────────────────────────────────────
    $docDefaults = $xml.SelectSingleNode("//w:docDefaults", $ns)
    if ($docDefaults) {
        $pPrDefault = $xml.SelectSingleNode("//w:docDefaults/w:pPrDefault", $ns)
        if (-not $pPrDefault) {
            $pPrDefault = $xml.CreateElement("w", "pPrDefault", $wNs)
            [void]$docDefaults.AppendChild($pPrDefault)
        }
        $pPr = Get-OrCreateChild -XmlDoc $xml -Parent $pPrDefault -LocalName "pPr"     -NsMgr $ns
        $spacing = Get-OrCreateChild -XmlDoc $xml -Parent $pPr        -LocalName "spacing" -NsMgr $ns
        $attr = $spacing.GetAttributeNode("line", $wNs)
        if (-not $attr) { $attr = $xml.CreateAttribute("w", "line", $wNs); [void]$spacing.Attributes.Append($attr) }
        $attr.Value = "276"   # 1.15x line height (240 = single)
        $attr = $spacing.GetAttributeNode("lineRule", $wNs)
        if (-not $attr) { $attr = $xml.CreateAttribute("w", "lineRule", $wNs); [void]$spacing.Attributes.Append($attr) }
        $attr.Value = "auto"
        $attr = $spacing.GetAttributeNode("after", $wNs)
        if (-not $attr) { $attr = $xml.CreateAttribute("w", "after", $wNs); [void]$spacing.Attributes.Append($attr) }
        $attr.Value = "80"
    }

    # ── Heading 1: 18pt, #1F3864 (Dark Navy), Bold, page-break ───────
    Set-StyleFont    -XmlDoc $xml -NsMgr $ns -StyleId "Heading1" -HalfPointSize 36 -FontName "Malgun Gothic"
    Set-StyleColor   -XmlDoc $xml -NsMgr $ns -StyleId "Heading1" -ColorHex "1F3864"
    Set-StyleBold    -XmlDoc $xml -NsMgr $ns -StyleId "Heading1"
    Set-StyleSpacing -XmlDoc $xml -NsMgr $ns -StyleId "Heading1" -BeforeTwips 480 -AfterTwips 160

    # ── Heading 2: 15pt, #2E5599 (Royal Blue), Bold ──────────────────
    Set-StyleFont    -XmlDoc $xml -NsMgr $ns -StyleId "Heading2" -HalfPointSize 30 -FontName "Malgun Gothic"
    Set-StyleColor   -XmlDoc $xml -NsMgr $ns -StyleId "Heading2" -ColorHex "2E5599"
    Set-StyleBold    -XmlDoc $xml -NsMgr $ns -StyleId "Heading2"
    Set-StyleSpacing -XmlDoc $xml -NsMgr $ns -StyleId "Heading2" -BeforeTwips 360 -AfterTwips 120

    # ── Heading 3: 13pt, #2F5496 (Navy Blue) ─────────────────────────
    Set-StyleFont    -XmlDoc $xml -NsMgr $ns -StyleId "Heading3" -HalfPointSize 26 -FontName "Malgun Gothic"
    Set-StyleColor   -XmlDoc $xml -NsMgr $ns -StyleId "Heading3" -ColorHex "2F5496"
    Set-StyleSpacing -XmlDoc $xml -NsMgr $ns -StyleId "Heading3" -BeforeTwips 240 -AfterTwips 80

    # ── Heading 4: 11pt, #4472C4 (Medium Blue) ───────────────────────
    Set-StyleFont    -XmlDoc $xml -NsMgr $ns -StyleId "Heading4" -HalfPointSize 22 -FontName "Malgun Gothic"
    Set-StyleColor   -XmlDoc $xml -NsMgr $ns -StyleId "Heading4" -ColorHex "4472C4"
    Set-StyleSpacing -XmlDoc $xml -NsMgr $ns -StyleId "Heading4" -BeforeTwips 160 -AfterTwips 60

    $xml.Save($stylesPath)
    Write-Host "[INFO] styles.xml: Body 10.5pt/1.15lh, H1=18pt, H2=15pt, H3=13pt, H4=11pt, Malgun Gothic"

    # ── Table styling: professional I/O port table design ────────────
    if (Test-Path -LiteralPath $documentPath) {
        [xml]$docXml = Get-Content -LiteralPath $documentPath -Raw -Encoding UTF8
        $docNs = New-Object System.Xml.XmlNamespaceManager($docXml.NameTable)
        $docNs.AddNamespace("w", "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
        $docWNs = $docNs.LookupNamespace("w")

        # Color constants
        $COL_HEADER_BG = "1F3864"   # Navy header background
        $COL_HEADER_FG = "FFFFFF"   # White header text
        $COL_ROW_ALT = "EBF3FA"   # Light blue alternating row
        $COL_ROW_NORMAL = "FFFFFF"   # White normal row
        $COL_OUTPUT_FG = "1A6B8A"   # Teal for Output signal rows
        $COL_INPUT_FG = "1F3864"   # Dark navy for Input signal rows (Name col)
        $COL_BORDER = "B8CCE4"   # Light blue border

        function New-TblBorderEl {
            param([xml]$Doc, [string]$Ns, [string]$Side, [string]$Color)
            [System.Xml.XmlElement]$el = $Doc.CreateElement("w", $Side, $Ns)
            $el.SetAttribute("val", $Ns, "single")
            $el.SetAttribute("sz", $Ns, "4")
            $el.SetAttribute("space", $Ns, "0")
            $el.SetAttribute("color", $Ns, $Color)
            Write-Output $el
        }

        function Set-CellShading {
            param([xml]$Doc, [string]$Ns, [System.Xml.XmlNode]$TcPr, [string]$FillColor)
            $shd = $TcPr.SelectSingleNode("w:shd", $docNs)
            if (-not $shd) {
                $shd = $Doc.CreateElement("w", "shd", $Ns)
                [void]$TcPr.AppendChild($shd)
            }
            [void]$shd.SetAttribute("val", $Ns, "clear")
            [void]$shd.SetAttribute("color", $Ns, "auto")
            [void]$shd.SetAttribute("fill", $Ns, $FillColor)
        }

        function Set-RunColor {
            param([xml]$Doc, [string]$Ns, [System.Xml.XmlNode]$Run, [string]$ColorHex, [bool]$Bold)
            $rPr = $Run.SelectSingleNode("w:rPr", $docNs)
            if (-not $rPr) {
                $rPr = $Doc.CreateElement("w", "rPr", $Ns)
                [void]$Run.PrependChild($rPr)
            }
            # color
            $col = $rPr.SelectSingleNode("w:color", $docNs)
            if (-not $col) { $col = $Doc.CreateElement("w", "color", $Ns); [void]$rPr.AppendChild($col) }
            [void]$col.SetAttribute("val", $Ns, $ColorHex)
            # bold
            if ($Bold) {
                $b = $rPr.SelectSingleNode("w:b", $docNs)
                if (-not $b) { $b = $Doc.CreateElement("w", "b", $Ns); [void]$rPr.AppendChild($b) }
                $bCs = $rPr.SelectSingleNode("w:bCs", $docNs)
                if (-not $bCs) { $bCs = $Doc.CreateElement("w", "bCs", $Ns); [void]$rPr.AppendChild($bCs) }
            }
        }

        $tables = $docXml.SelectNodes("//w:tbl", $docNs)
        $tableCount = 0
        foreach ($tbl in $tables) {
            $tableCount++

            # ── Apply table-level border ────────────────────────────────
            $tblPr = $tbl.SelectSingleNode("w:tblPr", $docNs)
            if (-not $tblPr) {
                $tblPr = $docXml.CreateElement("w", "tblPr", $docWNs)
                [void]$tbl.PrependChild($tblPr)
            }
            $tblBorders = $tblPr.SelectSingleNode("w:tblBorders", $docNs)
            if (-not $tblBorders) {
                $tblBorders = $docXml.CreateElement("w", "tblBorders", $docWNs)
                [void]$tblPr.AppendChild($tblBorders)
            }
            $tblBorders.RemoveAll()
            foreach ($side in @("top", "left", "bottom", "right", "insideH", "insideV")) {
                [System.Xml.XmlElement]$bEl = $docXml.CreateElement("w", $side, $docWNs)
                [void]$bEl.SetAttribute("val", $docWNs, "single")
                [void]$bEl.SetAttribute("sz", $docWNs, "4")
                [void]$bEl.SetAttribute("space", $docWNs, "0")
                [void]$bEl.SetAttribute("color", $docWNs, $COL_BORDER)
                [void]$tblBorders.AppendChild($bEl)
            }

            # ── Table width: 100% ───────────────────────────────────────
            $tblW = $tblPr.SelectSingleNode("w:tblW", $docNs)
            if (-not $tblW) { $tblW = $docXml.CreateElement("w", "tblW", $docWNs); [void]$tblPr.AppendChild($tblW) }
            [void]$tblW.SetAttribute("w", $docWNs, "5000")
            [void]$tblW.SetAttribute("type", $docWNs, "pct")

            # ── Style each row ──────────────────────────────────────────
            $rows = $tbl.SelectNodes("w:tr", $docNs)
            $rowIdx = 0
            foreach ($tr in $rows) {
                $isHeader = ($rowIdx -eq 0)

                # Detect if this row is an Output row (first cell text starts with 'o')
                $cells = $tr.SelectNodes("w:tc", $docNs)
                $firstCellText = ""
                if ($cells.Count -gt 0) {
                    $firstCellText = ($cells.Item(0).SelectNodes(".//w:t", $docNs) | ForEach-Object { $_.InnerText }) -join ""
                }
                $isOutput = (-not $isHeader) -and ($firstCellText -cmatch "^o[A-Z]")
                $isInput = (-not $isHeader) -and ($firstCellText -cmatch "^i[A-Z]")

                # Determine row fill color
                $rowFill = if ($isHeader) { $COL_HEADER_BG }
                elseif ($rowIdx % 2 -eq 1) { $COL_ROW_ALT }
                else { $COL_ROW_NORMAL }

                # Header row: mark as tblHeader
                if ($isHeader) {
                    $trPr = $tr.SelectSingleNode("w:trPr", $docNs)
                    if (-not $trPr) {
                        $trPr = $docXml.CreateElement("w", "trPr", $docWNs)
                        [void]$tr.PrependChild($trPr)
                    }
                    $tblHeader = $trPr.SelectSingleNode("w:tblHeader", $docNs)
                    if (-not $tblHeader) {
                        $tblHeader = $docXml.CreateElement("w", "tblHeader", $docWNs)
                        [void]$trPr.AppendChild($tblHeader)
                    }
                }

                # Style each cell in the row
                $colIdx = 0
                foreach ($tc in $cells) {
                    $tcPr = $tc.SelectSingleNode("w:tcPr", $docNs)
                    if (-not $tcPr) {
                        $tcPr = $docXml.CreateElement("w", "tcPr", $docWNs)
                        [void]$tc.PrependChild($tcPr)
                    }

                    # Cell shading
                    Set-CellShading -Doc $docXml -Ns $docWNs -TcPr $tcPr -FillColor $rowFill

                    # Cell padding: top/bottom 60 twips, left/right 100 twips
                    $tcMar = $tcPr.SelectSingleNode("w:tcMar", $docNs)
                    if (-not $tcMar) { $tcMar = $docXml.CreateElement("w", "tcMar", $docWNs); [void]$tcPr.AppendChild($tcMar) }
                    foreach ($side in @("top", "bottom")) {
                        $m = $tcMar.SelectSingleNode("w:$side", $docNs)
                        if (-not $m) { $m = $docXml.CreateElement("w", $side, $docWNs); [void]$tcMar.AppendChild($m) }
                        [void]$m.SetAttribute("w", $docWNs, "60")
                        [void]$m.SetAttribute("type", $docWNs, "dxa")
                    }
                    foreach ($side in @("left", "right")) {
                        $m = $tcMar.SelectSingleNode("w:$side", $docNs)
                        if (-not $m) { $m = $docXml.CreateElement("w", $side, $docWNs); [void]$tcMar.AppendChild($m) }
                        [void]$m.SetAttribute("w", $docWNs, "120")
                        [void]$m.SetAttribute("type", $docWNs, "dxa")
                    }

                    # Style all runs in this cell
                    $runs = $tc.SelectNodes(".//w:r", $docNs)
                    foreach ($run in $runs) {
                        if ($isHeader) {
                            Set-RunColor -Doc $docXml -Ns $docWNs -Run $run -ColorHex $COL_HEADER_FG -Bold $true
                        }
                        elseif ($isOutput -and $colIdx -eq 0) {
                            # Output signal name in teal
                            Set-RunColor -Doc $docXml -Ns $docWNs -Run $run -ColorHex $COL_OUTPUT_FG -Bold $false
                        }
                        elseif ($isInput -and $colIdx -eq 0) {
                            # Input signal name in dark navy
                            Set-RunColor -Doc $docXml -Ns $docWNs -Run $run -ColorHex $COL_INPUT_FG -Bold $false
                        }
                    }
                    $colIdx++
                }
                $rowIdx++
            }
        }

        if ($tableCount -gt 0) {
            $docXml.Save($documentPath)
            Write-Host "[INFO] Table styling applied: $tableCount tables (Navy header, Input/Output color coding)"
        }
    }

    # ── Optional: code block → 1x1 table ─────────────────────────────
    $convertedCodeBlockCount = 0
    if ($EnableCodeBlockTable -and (Test-Path -LiteralPath $documentPath)) {

        [xml]$docXml = Get-Content -LiteralPath $documentPath -Raw -Encoding UTF8
        $docNs = New-Object System.Xml.XmlNamespaceManager($docXml.NameTable)
        $docNs.AddNamespace("w", "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
        $docWNs = $docNs.LookupNamespace("w")

        $codeStyleIds = Get-CodeParagraphStyleIds -StylesXml $xml -NsMgr $ns
        $body = $docXml.SelectSingleNode("/w:document/w:body", $docNs)

        if ($body -and $codeStyleIds.Count -gt 0) {
            $children = @($body.ChildNodes)
            $i = 0
            while ($i -lt $children.Count) {
                $node = Get-SingleXmlNode -Value $children[$i] -Context "body child[$i]"
                if (-not (Test-IsCodeParagraph -Node $node -CodeStyleIds $codeStyleIds -NsMgr $docNs)) {
                    $i++; continue
                }
                $blockNodes = New-Object 'System.Collections.Generic.List[System.Xml.XmlNode]'
                $j = $i
                while ($j -lt $children.Count -and (Test-IsCodeParagraph -Node (Get-SingleXmlNode -Value $children[$j] -Context "code block child[$j]") -CodeStyleIds $codeStyleIds -NsMgr $docNs)) {
                    $childNode = Get-SingleXmlNode -Value $children[$j] -Context "code block child[$j]"
                    [void]$blockNodes.Add($childNode)
                    $j++
                }
                if ($blockNodes.Count -gt 0) {
                    $startNode = Get-SingleXmlNode -Value $blockNodes.Item(0) -Context "code block start node"
                    $tbl = Get-SingleXmlNode -Value (New-CodeBlockTableNode -XmlDoc $docXml -WordNs $docWNs -ParagraphNodes $blockNodes) -Context "generated code table"
                    [void]$body.InsertBefore($tbl, $startNode)
                    foreach ($oldNode in $blockNodes) { [void]$body.RemoveChild($oldNode) }
                    $convertedCodeBlockCount++
                    $children = @($body.ChildNodes)
                    $i = [Array]::IndexOf($children, $tbl) + 1
                }
                else { $i++ }
            }
        }
        $docXml.Save($documentPath)
    }

    # ── Rebuild DOCX ──────────────────────────────────────────────────
    if (Test-Path -LiteralPath $rebuiltZip) { Remove-Item -LiteralPath $rebuiltZip -Force }
    Compress-Archive -Path (Join-Path $workDir '*') -DestinationPath $rebuiltZip -Force
    Copy-Item -LiteralPath $rebuiltZip -Destination $resolvedDocx -Force

    Write-Host "[SUCCESS] DOCX style upgraded: Navy headings, Malgun Gothic, 1.15 line height."
    if ($EnableCodeBlockTable) {
        Write-Host "[INFO] Code blocks converted to 1x1 table: $convertedCodeBlockCount"
    }
}
finally {
    if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir    -Recurse -Force }
    if (Test-Path -LiteralPath $inputZip) { Remove-Item -LiteralPath $inputZip   -Force }
    if (Test-Path -LiteralPath $rebuiltZip) { Remove-Item -LiteralPath $rebuiltZip -Force }
}
