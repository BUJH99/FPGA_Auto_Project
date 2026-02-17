param(
    [Parameter(Mandatory = $true)]
    [string]$DocxPath
)

$ErrorActionPreference = "Stop"

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
    return $node
}

function Set-StyleSizeAndFont {
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
    $sz = Get-OrCreateChild -XmlDoc $XmlDoc -Parent $rPr -LocalName "sz" -NsMgr $NsMgr
    $szCs = Get-OrCreateChild -XmlDoc $XmlDoc -Parent $rPr -LocalName "szCs" -NsMgr $NsMgr
    $rFonts = Get-OrCreateChild -XmlDoc $XmlDoc -Parent $rPr -LocalName "rFonts" -NsMgr $NsMgr

    $wNs = $NsMgr.LookupNamespace("w")
    Set-ValAttr -XmlDoc $XmlDoc -Element $sz -Value "$HalfPointSize" -WordNs $wNs
    Set-ValAttr -XmlDoc $XmlDoc -Element $szCs -Value "$HalfPointSize" -WordNs $wNs

    foreach ($name in @("ascii", "hAnsi", "eastAsia", "cs")) {
        Set-NamedAttr -XmlDoc $XmlDoc -Element $rFonts -AttrName $name -Value $FontName -WordNs $wNs
    }
}

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
    if (-not (Test-Path -LiteralPath $stylesPath)) {
        throw "styles.xml not found in DOCX."
    }

    [xml]$xml = Get-Content -LiteralPath $stylesPath -Raw -Encoding UTF8
    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace("w", "http://schemas.openxmlformats.org/wordprocessingml/2006/main")

    # 10~12pt range (half-point values: 20=10pt, 21=10.5pt, 22=11pt, 24=12pt)
    Set-StyleSizeAndFont -XmlDoc $xml -NsMgr $ns -StyleId "Normal" -HalfPointSize 21 -FontName "Malgun Gothic"
    Set-StyleSizeAndFont -XmlDoc $xml -NsMgr $ns -StyleId "Heading1" -HalfPointSize 24 -FontName "Malgun Gothic"
    Set-StyleSizeAndFont -XmlDoc $xml -NsMgr $ns -StyleId "Heading2" -HalfPointSize 22 -FontName "Malgun Gothic"
    Set-StyleSizeAndFont -XmlDoc $xml -NsMgr $ns -StyleId "Heading3" -HalfPointSize 21 -FontName "Malgun Gothic"
    Set-StyleSizeAndFont -XmlDoc $xml -NsMgr $ns -StyleId "Heading4" -HalfPointSize 20 -FontName "Malgun Gothic"
    Set-StyleSizeAndFont -XmlDoc $xml -NsMgr $ns -StyleId "Title" -HalfPointSize 24 -FontName "Malgun Gothic"
    Set-StyleSizeAndFont -XmlDoc $xml -NsMgr $ns -StyleId "Subtitle" -HalfPointSize 22 -FontName "Malgun Gothic"
    Set-StyleSizeAndFont -XmlDoc $xml -NsMgr $ns -StyleId "TOCHeading" -HalfPointSize 22 -FontName "Malgun Gothic"
    Set-StyleSizeAndFont -XmlDoc $xml -NsMgr $ns -StyleId "TableNormal" -HalfPointSize 21 -FontName "Malgun Gothic"

    # DocDefaults (fallback font/size)
    $stylesRoot = $xml.SelectSingleNode("/w:styles", $ns)
    $docDefaults = Get-OrCreateChild -XmlDoc $xml -Parent $stylesRoot -LocalName "docDefaults" -NsMgr $ns
    $rPrDefault = Get-OrCreateChild -XmlDoc $xml -Parent $docDefaults -LocalName "rPrDefault" -NsMgr $ns
    $rPr = Get-OrCreateChild -XmlDoc $xml -Parent $rPrDefault -LocalName "rPr" -NsMgr $ns
    $rFonts = Get-OrCreateChild -XmlDoc $xml -Parent $rPr -LocalName "rFonts" -NsMgr $ns
    $sz = Get-OrCreateChild -XmlDoc $xml -Parent $rPr -LocalName "sz" -NsMgr $ns
    $szCs = Get-OrCreateChild -XmlDoc $xml -Parent $rPr -LocalName "szCs" -NsMgr $ns

    $wNs = $ns.LookupNamespace("w")
    foreach ($name in @("ascii", "hAnsi", "eastAsia", "cs")) {
        Set-NamedAttr -XmlDoc $xml -Element $rFonts -AttrName $name -Value "Malgun Gothic" -WordNs $wNs
    }
    Set-ValAttr -XmlDoc $xml -Element $sz -Value "21" -WordNs $wNs
    Set-ValAttr -XmlDoc $xml -Element $szCs -Value "21" -WordNs $wNs

    $xml.Save($stylesPath)

    if (Test-Path -LiteralPath $rebuiltZip) {
        Remove-Item -LiteralPath $rebuiltZip -Force
    }
    Compress-Archive -Path (Join-Path $workDir '*') -DestinationPath $rebuiltZip -Force
    Copy-Item -LiteralPath $rebuiltZip -Destination $resolvedDocx -Force

    Write-Host "[INFO] DOCX styles updated: body 10.5pt, headings 10~12pt, font=Malgun Gothic."
}
finally {
    if (Test-Path -LiteralPath $workDir) {
        Remove-Item -LiteralPath $workDir -Recurse -Force
    }
    if (Test-Path -LiteralPath $inputZip) {
        Remove-Item -LiteralPath $inputZip -Force
    }
    if (Test-Path -LiteralPath $rebuiltZip) {
        Remove-Item -LiteralPath $rebuiltZip -Force
    }
}
