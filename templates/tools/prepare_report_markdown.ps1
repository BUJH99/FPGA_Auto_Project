param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [string]$ProjectName = "Project"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $InputPath)) {
    throw "[ERROR] Markdown source not found: $InputPath"
}

function Has-MetadataKey {
    param(
        [string[]]$Lines,
        [string]$Key
    )

    $escapedKey = [regex]::Escape($Key)
    foreach ($line in $Lines) {
        if ($line -match "^\s*$escapedKey\s*:") {
            return $true
        }
    }
    return $false
}

$raw = Get-Content -LiteralPath $InputPath -Raw -Encoding UTF8
if ($null -eq $raw) {
    $raw = ""
}

$normalized = $raw -replace "`r`n?", "`n"
$body = $normalized
$metadataLines = @()

if ($normalized.StartsWith("---`n")) {
    $metaEnd = $normalized.IndexOf("`n---`n", 4, [System.StringComparison]::Ordinal)
    if ($metaEnd -ge 0) {
        $metadataText = $normalized.Substring(4, $metaEnd - 4)
        $metadataLines = $metadataText -split "`n"
        $body = $normalized.Substring($metaEnd + 5)
    }
}

# Remove a generated top-cover block ("# Cover" or "# \uD45C\uC9C0") if present.
$coverPattern = '^\s*#\s*(?:\uD45C\uC9C0|Cover)\s*\n(?:.*\n)*?\\newpage\s*(?:\n+|$)'
$coverRegexOptions = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
$body = [System.Text.RegularExpressions.Regex]::Replace($body, $coverPattern, "", $coverRegexOptions)
$body = $body.TrimStart("`n")

if (-not (Has-MetadataKey -Lines $metadataLines -Key "title")) {
    $safeProjectName = $ProjectName.Replace('"', '\"')
    $metadataLines += "title: `"$safeProjectName Hardware Design Report`""
}
if (-not (Has-MetadataKey -Lines $metadataLines -Key "author")) {
    $metadataLines += 'author: "Auto-generated draft (manual review required)"'
}
if (-not (Has-MetadataKey -Lines $metadataLines -Key "date")) {
    $metadataLines += "date: `"$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))`""
}
if (-not (Has-MetadataKey -Lines $metadataLines -Key "lang")) {
    $metadataLines += 'lang: "ko-KR"'
}
if (-not (Has-MetadataKey -Lines $metadataLines -Key "toc")) {
    $metadataLines += "toc: true"
}
if (-not (Has-MetadataKey -Lines $metadataLines -Key "toc-depth")) {
    $metadataLines += "toc-depth: 3"
}

$resultLines = @()
$resultLines += "---"
$resultLines += $metadataLines
$resultLines += "---"
$resultLines += ""
if (-not [string]::IsNullOrWhiteSpace($body)) {
    $resultLines += $body.TrimStart("`n")
}

$result = ($resultLines -join "`n").TrimEnd() + "`n"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($OutputPath, $result, $utf8NoBom)

Write-Host "[INFO] Prepared markdown for pandoc: $OutputPath"
