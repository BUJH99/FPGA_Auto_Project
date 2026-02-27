param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [string]$ProjectRoot = ""
)

$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────────────────────
#  Resolve project root (used for resolving relative paths in markdown)
# ─────────────────────────────────────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $InputPath
}
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path

# ─────────────────────────────────────────────────────────────────────────────
#  Detect available SVG converter
# ─────────────────────────────────────────────────────────────────────────────
$script:converterType = $null
$script:converterPath = $null

function Find-Inkscape {
    $candidates = @(
        "inkscape",
        "$env:ProgramFiles\Inkscape\bin\inkscape.exe",
        "${env:ProgramFiles(x86)}\Inkscape\bin\inkscape.exe",
        "$env:LOCALAPPDATA\Programs\Inkscape\bin\inkscape.exe"
    )
    foreach ($c in $candidates) {
        try {
            $found = (Get-Command $c -ErrorAction SilentlyContinue)
            if ($found) { return $found.Source }
        }
        catch {}
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

function Find-ImageMagick {
    $candidates = @("magick", "convert")
    foreach ($c in $candidates) {
        try {
            $found = Get-Command $c -ErrorAction SilentlyContinue
            if ($found) {
                # Verify it's ImageMagick (not Windows' convert.exe for FAT)
                $ver = & $found.Source --version 2>$null
                if ($ver -match "ImageMagick") { return $found.Source }
            }
        }
        catch {}
    }
    return $null
}

$inkscape = Find-Inkscape
$imageMagick = Find-ImageMagick

# Check Node.js for resvg-js / puppeteer path (most reliable on Windows without extra installs)
$nodeJsCmdObj = Get-Command "node" -ErrorAction SilentlyContinue
$nodeJsPath = if ($nodeJsCmdObj) { $nodeJsCmdObj.Source } else { $null }
$nodeJsScript = Join-Path (Split-Path -Parent $PSCommandPath) "svg_to_png_node.js"
$nodeJsOk = $nodeJsPath -and (Test-Path -LiteralPath $nodeJsScript)

if ($inkscape) {
    $script:converterType = "inkscape"
    $script:converterPath = $inkscape
    Write-Host "[INFO] SVG converter: Inkscape ($inkscape)"
}
elseif ($imageMagick) {
    $script:converterType = "imagemagick"
    $script:converterPath = $imageMagick
    Write-Host "[INFO] SVG converter: ImageMagick ($imageMagick)"
}
elseif ($nodeJsOk) {
    # Node.js + @resvg/resvg-js (auto-installed on first run)
    $script:converterType = "nodejs"
    $script:converterPath = $nodeJsScript
    Write-Host "[INFO] SVG converter: Node.js/@resvg/resvg-js ($nodeJsPath)"
}
else {
    $script:converterType = "dotnet"
    Write-Host "[INFO] SVG converter: .NET WebBrowser (fallback – may be slow)"
}

# ─────────────────────────────────────────────────────────────────────────────
#  Convert single SVG → PNG
# ─────────────────────────────────────────────────────────────────────────────
$script:pngCache = @{}

function Convert-SvgToPng {
    param(
        [string]$SvgAbsPath,
        [string]$PngAbsPath
    )

    if ($script:pngCache.ContainsKey($SvgAbsPath)) {
        return $script:pngCache[$SvgAbsPath]
    }

    if (-not (Test-Path -LiteralPath $SvgAbsPath)) {
        Write-Warning "[WARN] SVG not found: $SvgAbsPath"
        $script:pngCache[$SvgAbsPath] = $null
        return $null
    }

    $pngDir = Split-Path -Parent $PngAbsPath
    if (-not (Test-Path -LiteralPath $pngDir)) {
        New-Item -ItemType Directory -Path $pngDir -Force | Out-Null
    }

    $ok = $false

    switch ($script:converterType) {
        "inkscape" {
            try {
                # Inkscape 1.x CLI
                $args1 = @("--export-type=png", "--export-filename=$PngAbsPath", "--export-dpi=150", $SvgAbsPath)
                & $script:converterPath @args1 2>$null
                if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $PngAbsPath)) {
                    $ok = $true
                }
            }
            catch {}

            if (-not $ok) {
                try {
                    # Inkscape 0.9x CLI fallback
                    $args2 = @("--export-png=$PngAbsPath", "--export-dpi=150", $SvgAbsPath)
                    & $script:converterPath @args2 2>$null
                    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $PngAbsPath)) {
                        $ok = $true
                    }
                }
                catch {}
            }
        }

        "imagemagick" {
            try {
                # ImageMagick with SVG support (requires librsvg or Inkscape delegate)
                & $script:converterPath -density 150 -background white $SvgAbsPath $PngAbsPath 2>$null
                if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $PngAbsPath)) {
                    $ok = $true
                }
            }
            catch {}
        }

        "nodejs" {
            # Node.js + @resvg/resvg-js (auto-installs on first run)
            try {
                $nodeArgs = @(
                    $script:converterPath,
                    "--input", $SvgAbsPath,
                    "--output", $PngAbsPath,
                    "--dpi", "150",
                    "--width", "1200",
                    "--project-root", $ProjectRoot
                )
                & node @nodeArgs 2>&1 | Write-Verbose
                if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $PngAbsPath)) {
                    $ok = $true
                }
            }
            catch { Write-Warning "[WARN] Node.js SVG conversion error: $_" }
        }

        "dotnet" {
            # .NET WebBrowser-based SVG rendering (Windows only, requires STA thread)
            try {
                $svgContent = Get-Content -LiteralPath $SvgAbsPath -Raw -Encoding UTF8

                # Parse width/height from SVG
                $w = 800; $h = 600
                if ($svgContent -match 'width="([^"]+)"') {
                    $wStr = $Matches[1] -replace 'px', '' -replace 'pt', ''
                    if ([double]::TryParse($wStr, [ref]$null)) { $w = [int][double]::Parse($wStr) }
                }
                if ($svgContent -match 'height="([^"]+)"') {
                    $hStr = $Matches[1] -replace 'px', '' -replace 'pt', ''
                    if ([double]::TryParse($hStr, [ref]$null)) { $h = [int][double]::Parse($hStr) }
                }
                if ($w -lt 100) { $w = 800 }
                if ($h -lt 100) { $h = 600 }

                $pngPathEsc = $PngAbsPath -replace "'", "''"
                $svgPathEsc = $SvgAbsPath -replace "'", "''"

                $staScript = @"
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

`$web = New-Object System.Windows.Forms.WebBrowser
`$web.ScrollBarsEnabled = `$false
`$web.Width  = $w
`$web.Height = $h
`$web.Navigate('file:///$($svgPathEsc -replace '\\','/')')
`$timeout = [System.DateTime]::Now.AddSeconds(10)
while (`$web.ReadyState -ne 'Complete' -and [System.DateTime]::Now -lt `$timeout) {
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 100
}
`$bmp = New-Object System.Drawing.Bitmap($w, $h)
`$g   = [System.Drawing.Graphics]::FromImage(`$bmp)
`$g.Clear([System.Drawing.Color]::White)
`$web.DrawToBitmap(`$bmp, (New-Object System.Drawing.Rectangle(0,0,$w,$h)))
`$bmp.Save('$pngPathEsc', [System.Drawing.Imaging.ImageFormat]::Png)
`$g.Dispose(); `$bmp.Dispose(); `$web.Dispose()
"@
                Start-Job -ScriptBlock ([scriptblock]::Create($staScript)) | Wait-Job -Timeout 30 | Receive-Job | Out-Null
                if (Test-Path -LiteralPath $PngAbsPath) { $ok = $true }
            }
            catch {
                Write-Warning "[WARN] .NET WebBrowser SVG render failed: $_"
            }
        }
    }

    if ($ok) {
        Write-Host "[INFO] Converted: $(Split-Path -Leaf $SvgAbsPath) → $(Split-Path -Leaf $PngAbsPath)"
        $script:pngCache[$SvgAbsPath] = $PngAbsPath
        return $PngAbsPath
    }
    else {
        Write-Warning "[WARN] SVG→PNG conversion failed: $SvgAbsPath"
        $script:pngCache[$SvgAbsPath] = $null
        return $null
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  Read markdown, replace SVG references with PNG
# ─────────────────────────────────────────────────────────────────────────────
if (-not (Test-Path -LiteralPath $InputPath)) {
    throw "[ERROR] Input markdown not found: $InputPath"
}

$raw = Get-Content -LiteralPath $InputPath -Raw -Encoding UTF8
$inputDir = Split-Path -Parent (Resolve-Path -LiteralPath $InputPath).Path

$convertedCount = 0
$skippedCount = 0

# Match: ![alt text](path/to/file.svg) — capture groups: alt, path
$pattern = '!\[([^\]]*)\]\(([^)]+?\.svg(?:\?[^)]*)?)\)'

$result = [System.Text.RegularExpressions.Regex]::Replace(
    $raw,
    $pattern,
    {
        param($m)
        $alt = $m.Groups[1].Value
        $svgRel = $m.Groups[2].Value  # may contain query string ?...
        $svgPath = $svgRel -replace '\?.*$', ''  # strip query

        # Resolve SVG absolute path (try relative to project root first, then markdown dir)
        $svgAbs = $null
        $candidates = @(
            (Join-Path $ProjectRoot $svgPath),
            (Join-Path $inputDir   $svgPath),
            $svgPath  # already absolute?
        )
        foreach ($c in $candidates) {
            if (Test-Path -LiteralPath $c) { $svgAbs = (Resolve-Path -LiteralPath $c).Path; break }
        }

        if (-not $svgAbs) {
            Write-Warning "[WARN] SVG not resolved: $svgPath"
            $script:skippedCount++
            # Keep original but make it a link (not image) so Word doesn't error
            return "[$alt]($svgRel)"
        }

        # Build PNG path (sibling to SVG, same name + .png extension)
        $pngAbs = [System.IO.Path]::ChangeExtension($svgAbs, ".docx_converted.png")
        $pngConverted = Convert-SvgToPng -SvgAbsPath $svgAbs -PngAbsPath $pngAbs

        if ($pngConverted) {
            # Use a path relative to project root for the markdown
            $pngRel = $pngConverted.Substring($ProjectRoot.Length).TrimStart('\', '/')
            $pngRel = $pngRel -replace '\\', '/'
            $script:convertedCount++
            return "![$alt]($pngRel)"
        }
        else {
            # Fallback: keep as link (non-image) so pandoc doesn't error on missing SVG embed
            $script:skippedCount++
            return "[$alt — diagram: $svgPath]"
        }
    }
)

# ─────────────────────────────────────────────────────────────────────────────
#  Write output
# ─────────────────────────────────────────────────────────────────────────────
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($OutputPath, $result, $utf8NoBom)

Write-Host "[SUCCESS] SVG→PNG conversion complete: $convertedCount converted, $skippedCount skipped/not found"
Write-Host "[INFO] Output markdown: $OutputPath"
