param(
    [Parameter(Mandatory = $true)]
    [string]$VivadoTcl,
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,
    [Parameter(Mandatory = $true)]
    [string]$SrcList,
    [Parameter(Mandatory = $true)]
    [string]$XdcList,
    [Parameter(Mandatory = $true)]
    [string]$IncList,
    [Parameter(Mandatory = $true)]
    [string]$TopModule,
    [Parameter(Mandatory = $true)]
    [string]$PartNumber,
    [string]$BoardPart = '',
    [Parameter(Mandatory = $true)]
    [string]$ProjectName,
    [Parameter(Mandatory = $true)]
    [string]$BuildStrategy,
    [Parameter(Mandatory = $true)]
    [string]$PowerLimit,
    [Parameter(Mandatory = $true)]
    [string]$BuildLog,
    [Parameter(Mandatory = $true)]
    [string]$BuildJournal,
    [Parameter(Mandatory = $true)]
    [string]$StageStatusFile
)

$ErrorActionPreference = 'Stop'

$stageMap = @{
    'SYNTHESIS' = @{
        Step = '6/15'
        Title = 'Run Synthesis'
        Detail = 'synth_design -> post_synth checkpoint'
    }
    'IMPLEMENTATION' = @{
        Step = '7/15'
        Title = 'Run Implementation'
        Detail = 'opt_design -> place_design -> route_design'
    }
    'BITSTREAM' = @{
        Step = '8/15'
        Title = 'Generate Bitstream'
        Detail = 'power/timing validation -> write_bitstream'
    }
}

function Show-StepBanner {
    param(
        [string]$Step,
        [string]$Title,
        [string]$Detail
    )

    Write-Host ''
    Write-Host '==============================================================================='
    Write-Host "[STEP $Step] $Title"
    Write-Host '==============================================================================='
    Write-Host "[RUN] $Title"
    Write-Host "      Detail: $Detail"
    Write-Host "      Log: $BuildLog"
    Write-Host '      Status: running...'
}

$argumentList = @(
    '-mode', 'batch',
    '-log', $BuildLog,
    '-journal', $BuildJournal,
    '-notrace',
    '-source', $VivadoTcl,
    '-tclargs',
    $ProjectRoot,
    $SrcList,
    $XdcList,
    $IncList,
    $TopModule,
    $PartNumber,
    $ProjectName,
    $BuildStrategy,
    $PowerLimit,
    $StageStatusFile,
    $BoardPart
)

if (Test-Path -LiteralPath $StageStatusFile) {
    Remove-Item -LiteralPath $StageStatusFile -Force -ErrorAction SilentlyContinue
}

$consoleStdOut = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($BuildLog), 'vivado_stage_monitor.stdout.log')
$consoleStdErr = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($BuildLog), 'vivado_stage_monitor.stderr.log')

$proc = Start-Process -FilePath 'vivado' -ArgumentList $argumentList -NoNewWindow -PassThru -RedirectStandardOutput $consoleStdOut -RedirectStandardError $consoleStdErr
$seenStages = @{}
$lastStage = ''

while (-not $proc.HasExited) {
    if (Test-Path -LiteralPath $StageStatusFile) {
        $kv = @{}
        foreach ($line in (Get-Content -LiteralPath $StageStatusFile -ErrorAction SilentlyContinue)) {
            if ($line -match '^(?<Key>[^=]+)=(?<Value>.*)$') {
                $kv[$Matches['Key']] = $Matches['Value']
            }
        }

        $stage = $kv['STAGE']
        if ($stage -and $stage -ne $lastStage -and $stageMap.ContainsKey($stage)) {
            $detail = $kv['DETAIL']
            if (-not $detail) {
                $detail = $stageMap[$stage].Detail
            }
            Show-StepBanner -Step $stageMap[$stage].Step -Title $stageMap[$stage].Title -Detail $detail
            $seenStages[$stage] = $true
            $lastStage = $stage
        }
    }

    Start-Sleep -Milliseconds 500
    $proc.Refresh()
}

$proc.WaitForExit()
if ((Test-Path -LiteralPath $consoleStdOut) -and ((Get-Item -LiteralPath $consoleStdOut).Length -eq 0)) {
    Remove-Item -LiteralPath $consoleStdOut -Force -ErrorAction SilentlyContinue
}
if ((Test-Path -LiteralPath $consoleStdErr) -and ((Get-Item -LiteralPath $consoleStdErr).Length -eq 0)) {
    Remove-Item -LiteralPath $consoleStdErr -Force -ErrorAction SilentlyContinue
}
exit $proc.ExitCode
