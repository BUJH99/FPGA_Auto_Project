@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "SELF_PATH=%~f0"
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..\..") do set "TEMPLATES_ROOT=%%~fI"
set "CONSOLE_HELPER=%TEMPLATES_ROOT%\shared\adapters\bat\console_ui.bat"
set "USER_CANCEL_RC=99"

set "TARGET_PROJECT="
set "DUT_NAME="
set "APPLY_ALL=0"
set "FORCE_WRITE=0"
set "NO_PAUSE=0"
set "EXPECT_DUT_VALUE=0"
set "MANIFEST_SRC_LIST="

:parse_args
if "%~1"=="" goto args_done
if "%EXPECT_DUT_VALUE%"=="1" (
    set "DUT_NAME=%~1"
    set "EXPECT_DUT_VALUE=0"
) else if /i "%~1"=="--dut" (
    set "EXPECT_DUT_VALUE=1"
) else if /i "%~1"=="--all" (
    set "APPLY_ALL=1"
) else if /i "%~1"=="--force" (
    set "FORCE_WRITE=1"
) else if /i "%~1"=="--no-pause" (
    set "NO_PAUSE=1"
) else (
    set "ARG=%~1"
    if /i "!ARG:~0,6!"=="--dut=" (
        set "DUT_NAME=!ARG:~6!"
    ) else if not defined TARGET_PROJECT (
        set "TARGET_PROJECT=%~f1"
    ) else (
        echo [WARNING] Ignoring extra argument: %~1
    )
)
shift
goto parse_args

:args_done
if "%EXPECT_DUT_VALUE%"=="1" (
    echo [ERROR] --dut requires a value.
    goto usage_error
)

if not defined TARGET_PROJECT goto usage_error
if not exist "%TARGET_PROJECT%" (
    echo [ERROR] Target project not found: %TARGET_PROJECT%
    call :maybe_pause_then_clear
    exit /b 1
)

set "TB_ROOT=%TARGET_PROJECT%\tb"
if not exist "%TB_ROOT%" (
    if exist "%TARGET_PROJECT%\TB" (
        set "TB_ROOT=%TARGET_PROJECT%\TB"
    ) else (
        mkdir "%TB_ROOT%" >nul 2>nul
        if errorlevel 1 (
            echo [ERROR] Failed to create TB root folder: %TB_ROOT%
            call :maybe_pause_then_clear
            exit /b 1
        )
        echo [INFO] Created TB root folder: %TB_ROOT%
    )
)

set "MANIFEST_CTX=%TEMPLATES_ROOT%\shared\adapters\bat\bootstrap_manifest_context.bat"
if exist "%MANIFEST_CTX%" (
    call "%MANIFEST_CTX%" "%TARGET_PROJECT%" >nul 2>nul
    if errorlevel 1 (
        echo [WARN] Manifest context initialization failed. Fallback to direct source scan.
        set "MANIFEST_SRC_LIST="
    )
) else (
    echo [WARN] Manifest context script not found. Fallback to direct source scan.
)

set "PS_FILE=%TEMP%\tb_dut_scaffold_%RANDOM%%RANDOM%.ps1"
set "MARKER=:POWERSHELL_SCRIPT_START"
set "START_LINE="
for /f "tokens=1 delims=:" %%L in ('findstr /n "^%MARKER%" "%SELF_PATH%"') do set "START_LINE=%%L"
if not defined START_LINE (
    echo [ERROR] Internal marker not found: %MARKER%
    call :maybe_pause_then_clear
    exit /b 1
)

more +%START_LINE% "%SELF_PATH%" > "%PS_FILE%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_FILE%" "%TARGET_PROJECT%" "%TB_ROOT%" "%MANIFEST_SRC_LIST%" "%DUT_NAME%" "%APPLY_ALL%" "%FORCE_WRITE%"
set "SCRIPT_RC=%ERRORLEVEL%"

del "%PS_FILE%" >nul 2>nul

if "%SCRIPT_RC%"=="%USER_CANCEL_RC%" exit /b %USER_CANCEL_RC%
call :maybe_pause_then_clear
exit /b %SCRIPT_RC%

:usage_error
echo Usage: %~nx0 ^<Project_Directory^> [--dut ^<name^> ^| --dut=name] [--all] [--force] [--no-pause]
call :maybe_pause_then_clear
exit /b 1

:maybe_pause_then_clear
if "%NO_PAUSE%"=="1" exit /b 0
call "%CONSOLE_HELPER%" pause_then_clear
exit /b 0

:POWERSHELL_SCRIPT_START
param(
    [string]$ProjectRoot = "",
    [string]$TbRoot = "",
    [string]$ManifestSrcList = "",
    [string]$RequestedDut = "",
    [string]$ApplyAll = "0",
    [string]$ForceWrite = "0"
)

$ErrorActionPreference = "Stop"
$applyAllMode = ($ApplyAll -eq "1")
$forceMode = ($ForceWrite -eq "1")

function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    $baseNorm = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\', '/') + '\'
    $targetNorm = [System.IO.Path]::GetFullPath($TargetPath)
    if ($targetNorm.StartsWith($baseNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $targetNorm.Substring($baseNorm.Length)
    }
    return $targetNorm
}

function Normalize-DutName {
    param([string]$RawName)

    if ([string]::IsNullOrWhiteSpace($RawName)) {
        return ""
    }

    $name = [System.IO.Path]::GetFileNameWithoutExtension($RawName.Trim())
    $name = $name -replace '[^A-Za-z0-9_]', '_'
    $name = $name -replace '_{2,}', '_'
    $name = $name.Trim('_')

    if ([string]::IsNullOrWhiteSpace($name)) {
        return ""
    }
    if ($name -match '^[0-9]') {
        $name = "dut_" + $name
    }
    return $name
}

function Convert-ToPascalCase {
    param([string]$Name)

    $clean = Normalize-DutName $Name
    if ([string]::IsNullOrWhiteSpace($clean)) {
        return "Dut"
    }

    $parts = $clean -split '_+'
    $sb = [System.Text.StringBuilder]::new()
    foreach ($part in $parts) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        $head = $part.Substring(0, 1).ToUpperInvariant()
        $tail = ""
        if ($part.Length -gt 1) {
            $tail = $part.Substring(1).ToLowerInvariant()
        }
        [void]$sb.Append($head + $tail)
    }
    $value = $sb.ToString()
    if ([string]::IsNullOrWhiteSpace($value)) {
        return "Dut"
    }
    return $value
}

function Get-ModuleNamesFromFile {
    param([string]$FilePath)

    try {
        $content = Get-Content -LiteralPath $FilePath -Raw -ErrorAction Stop
    } catch {
        return @()
    }

    $content = [regex]::Replace($content, '//.*$', '', [System.Text.RegularExpressions.RegexOptions]::Multiline)
    $content = [regex]::Replace($content, '/\*.*?\*/', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)

    $result = @()
    foreach ($match in [regex]::Matches($content, '(?m)^\s*module\s+([A-Za-z_][A-Za-z0-9_]*)\b')) {
        if ($match.Groups.Count -gt 1) {
            $result += $match.Groups[1].Value
        }
    }

    if ($result.Count -eq 0) {
        $result += [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    }

    return @($result | Sort-Object -Unique)
}

function Collect-SourceFiles {
    param(
        [string]$ProjectRootPath,
        [string]$ManifestListPath
    )

    $filesByPath = @{}

    if (-not [string]::IsNullOrWhiteSpace($ManifestListPath) -and (Test-Path -LiteralPath $ManifestListPath)) {
        foreach ($line in Get-Content -LiteralPath $ManifestListPath) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $candidate = Join-Path $ProjectRootPath ($line.Trim() -replace '/', '\\')
            if (-not (Test-Path -LiteralPath $candidate)) { continue }

            $fi = Get-Item -LiteralPath $candidate -ErrorAction SilentlyContinue
            if ($null -eq $fi -or $fi.PSIsContainer) { continue }
            if ($fi.Extension -notin @('.v', '.sv')) { continue }
            $filesByPath[$fi.FullName.ToLowerInvariant()] = $fi.FullName
        }
    }

    $scanRoot = $ProjectRootPath
    if (Test-Path -LiteralPath $scanRoot) {
        $excludeRegex = '(?i)\\(tb|output|log|report_assets|presentation|work|xsim\.dir|\.xil|\.git|\.vscode|vivado_project|\.cache|\.runs|\.gen|ip_user_files)(\\|$)'
        $allFiles = Get-ChildItem -LiteralPath $scanRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Extension -in @('.v', '.sv') -and
            $_.Name -notmatch '^(?i)glbl\.v$' -and
            $_.Name -notmatch '^(?i)tb_' -and
            $_.Name -notmatch '(?i)_tb\.(v|sv)$' -and
            $_.FullName -notmatch $excludeRegex
        }

        foreach ($fi in $allFiles) {
            $filesByPath[$fi.FullName.ToLowerInvariant()] = $fi.FullName
        }
    }

    $ordered = @($filesByPath.Values | Sort-Object)
    return @($ordered)
}

function Collect-DutCandidates {
    param(
        [string]$ProjectRootPath,
        [string]$ManifestListPath
    )

    $files = Collect-SourceFiles -ProjectRootPath $ProjectRootPath -ManifestListPath $ManifestListPath
    $map = [ordered]@{}

    foreach ($fullPath in $files) {
        $moduleNames = Get-ModuleNamesFromFile -FilePath $fullPath
        $relative = Get-RelativePath -BasePath $ProjectRootPath -TargetPath $fullPath

        foreach ($moduleName in $moduleNames) {
            $normalized = Normalize-DutName $moduleName
            if ([string]::IsNullOrWhiteSpace($normalized)) { continue }
            if ($normalized -match '^(?i)tb_') { continue }
            if ($normalized -match '(?i)_tb$') { continue }

            $key = $normalized.ToLowerInvariant()
            if (-not $map.Contains($key)) {
                $map[$key] = [PSCustomObject]@{
                    Name = $normalized
                    SourceFile = $fullPath
                    RelativePath = $relative
                }
            }
        }
    }

    return @($map.Values)
}

function Resolve-DutToken {
    param(
        [string]$Token,
        [System.Collections.IEnumerable]$Candidates
    )

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return $null
    }

    $trimmed = $Token.Trim()
    if ($trimmed -match '^\d+$') {
        $idx = [int]$trimmed
        $arr = @($Candidates)
        if ($idx -ge 1 -and $idx -le $arr.Count) {
            return $arr[$idx - 1].Name
        }
        return $null
    }

    $normalizedToken = Normalize-DutName $trimmed
    if ([string]::IsNullOrWhiteSpace($normalizedToken)) {
        return $null
    }

    foreach ($cand in $Candidates) {
        if ($cand.Name.Equals($normalizedToken, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $cand.Name
        }
    }

    foreach ($cand in $Candidates) {
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($cand.SourceFile)
        if ($stem.Equals($trimmed, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $cand.Name
        }
    }

    return $normalizedToken
}

function New-TemplateMap {
    param([string]$DutName)

    $dutNameNorm = Normalize-DutName $DutName
    $classPrefix = Convert-ToPascalCase $dutNameNorm
    $pkgName = "${dutNameNorm}_tb_pkg"
    $ifName = "${dutNameNorm}_if"
    $macroPrefix = ($dutNameNorm.ToUpperInvariant() -replace '[^A-Z0-9]', '_')

    $txClass = "${classPrefix}Tx"
    $cfgClass = "${classPrefix}Config"
    $genClass = "${classPrefix}Generator"
    $drvClass = "${classPrefix}Driver"
    $monClass = "${classPrefix}Monitor"
    $scbClass = "${classPrefix}Scoreboard"
    $covClass = "${classPrefix}Coverage"
    $envClass = "${classPrefix}Env"
    $baseTestClass = "${classPrefix}BaseTest"
    $test01Class = "${classPrefix}Test01"
    $test02Class = "${classPrefix}Test02"

    $templates = [ordered]@{}

    $templates['include/tb_defs.svh'] = @'
`ifndef __TB_DEFS_GUARD__
`define __TB_DEFS_GUARD__

`define TB_INFO(MSG) $display("[%0t][TB][INFO] %s", $time, MSG)
`define TB_WARN(MSG) $display("[%0t][TB][WARN] %s", $time, MSG)
`define TB_ERR(MSG)  $error("[%0t][TB][ERR ] %s", $time, MSG)

`endif
'@

    $templates['objs/transaction.svh'] = @'
`ifndef __TRANSACTION_GUARD__
`define __TRANSACTION_GUARD__

class __TX_CLASS__;
    rand bit [31:0] m_data;
    rand bit        m_valid;

    constraint c_valid_bias {
        m_valid dist {1 := 80, 0 := 20};
    }

    function new();
        m_data = '0;
        m_valid = 1'b0;
    endfunction

    function __TX_CLASS__ clone();
        __TX_CLASS__ tx_clone = new();
        tx_clone.m_data = this.m_data;
        tx_clone.m_valid = this.m_valid;
        return tx_clone;
    endfunction

    function string sprint();
        return $sformatf("data=0x%08h valid=%0b", m_data, m_valid);
    endfunction
endclass

`endif
'@

    $templates['objs/config.svh'] = @'
`ifndef __CONFIG_GUARD__
`define __CONFIG_GUARD__

class __CFG_CLASS__;
    int unsigned m_num_transactions;
    bit          m_verbose;
    int unsigned m_timeout_cycles;

    function new();
        m_num_transactions = 100;
        m_verbose = 1'b1;
        m_timeout_cycles = 10000;
    endfunction
endclass

`endif
'@

    $templates['components/generator.svh'] = @'
`ifndef __GENERATOR_GUARD__
`define __GENERATOR_GUARD__

class __GEN_CLASS__;
    __CFG_CLASS__ m_cfg;
    mailbox #(__TX_CLASS__) mbx_gen2drv;

    function new(input __CFG_CLASS__ cfg, mailbox #(__TX_CLASS__) mbx_gen2drv);
        this.m_cfg = cfg;
        this.mbx_gen2drv = mbx_gen2drv;
    endfunction

    virtual task run();
        __TX_CLASS__ tx_item;
        repeat (m_cfg.m_num_transactions) begin
            tx_item = new();
            if (!tx_item.randomize()) begin
                `TB_ERR("Generator randomization failed")
            end
            mbx_gen2drv.put(tx_item);
            if (m_cfg.m_verbose) begin
                `TB_INFO($sformatf("GEN : %s", tx_item.sprint()))
            end
        end
    endtask
endclass

`endif
'@

    $templates['components/driver.svh'] = @'
`ifndef __DRIVER_GUARD__
`define __DRIVER_GUARD__

class __DRV_CLASS__;
    virtual __IF_NAME__ vif___DUT_NAME__;
    mailbox #(__TX_CLASS__) mbx_gen2drv;

    function new(virtual __IF_NAME__ vif___DUT_NAME__, mailbox #(__TX_CLASS__) mbx_gen2drv);
        this.vif___DUT_NAME__ = vif___DUT_NAME__;
        this.mbx_gen2drv = mbx_gen2drv;
    endfunction

    virtual task drive_one(input __TX_CLASS__ tx_item);
        @(posedge vif___DUT_NAME__.iClk);
        vif___DUT_NAME__.tb_data_in <= tx_item.m_data;
        vif___DUT_NAME__.tb_valid <= tx_item.m_valid;

        do begin
            @(posedge vif___DUT_NAME__.iClk);
        end while (!vif___DUT_NAME__.tb_ready);

        vif___DUT_NAME__.tb_valid <= 1'b0;
    endtask

    virtual task run();
        __TX_CLASS__ tx_item;
        vif___DUT_NAME__.tb_data_in <= '0;
        vif___DUT_NAME__.tb_valid <= 1'b0;

        forever begin
            mbx_gen2drv.get(tx_item);
            drive_one(tx_item);
        end
    endtask
endclass

`endif
'@

    $templates['components/monitor.svh'] = @'
`ifndef __MONITOR_GUARD__
`define __MONITOR_GUARD__

class __MON_CLASS__;
    virtual __IF_NAME__ vif___DUT_NAME__;
    mailbox #(__TX_CLASS__) mbx_mon2scb;
    mailbox #(__TX_CLASS__) mbx_mon2cov;

    function new(
        virtual __IF_NAME__ vif___DUT_NAME__,
        mailbox #(__TX_CLASS__) mbx_mon2scb,
        mailbox #(__TX_CLASS__) mbx_mon2cov
    );
        this.vif___DUT_NAME__ = vif___DUT_NAME__;
        this.mbx_mon2scb = mbx_mon2scb;
        this.mbx_mon2cov = mbx_mon2cov;
    endfunction

    virtual task run();
        __TX_CLASS__ tx_item;
        forever begin
            @(posedge vif___DUT_NAME__.iClk);
            if (vif___DUT_NAME__.tb_valid && vif___DUT_NAME__.tb_ready) begin
                tx_item = new();
                tx_item.m_valid = vif___DUT_NAME__.tb_valid;
                tx_item.m_data = vif___DUT_NAME__.tb_data_out;
                mbx_mon2scb.put(tx_item.clone());
                mbx_mon2cov.put(tx_item.clone());
            end
        end
    endtask
endclass

`endif
'@

    $templates['env/scoreboard.svh'] = @'
`ifndef __SCOREBOARD_GUARD__
`define __SCOREBOARD_GUARD__

class __SCB_CLASS__;
    mailbox #(__TX_CLASS__) mbx_mon2scb;
    int unsigned m_checked_count;

    function new(mailbox #(__TX_CLASS__) mbx_mon2scb);
        this.mbx_mon2scb = mbx_mon2scb;
        m_checked_count = 0;
    endfunction

    virtual function bit compare(input __TX_CLASS__ tx_actual);
        // TODO: Replace with DUT-specific expected vs actual comparison.
        return tx_actual.m_valid;
    endfunction

    virtual task run();
        __TX_CLASS__ tx_actual;
        forever begin
            mbx_mon2scb.get(tx_actual);
            m_checked_count++;
            if (!compare(tx_actual)) begin
                `TB_ERR($sformatf("Scoreboard mismatch #%0d : %s", m_checked_count, tx_actual.sprint()))
            end else begin
                `TB_INFO($sformatf("SCB PASS #%0d : %s", m_checked_count, tx_actual.sprint()))
            end
        end
    endtask
endclass

`endif
'@

    $templates['env/coverage.svh'] = @'
`ifndef __COVERAGE_GUARD__
`define __COVERAGE_GUARD__

class __COV_CLASS__;
    virtual __IF_NAME__ vif___DUT_NAME__;
    mailbox #(__TX_CLASS__) mbx_mon2cov;
    __TX_CLASS__ m_tx_item;

    covergroup cg___DUT_NAME___tx;
        option.per_instance = 1;

        cp_valid: coverpoint m_tx_item.m_valid {
            bins b_zero = {0};
            bins b_one = {1};
        }

        cp_data_lsb: coverpoint m_tx_item.m_data[1:0] {
            bins b_00 = {2'b00};
            bins b_01 = {2'b01};
            bins b_10 = {2'b10};
            bins b_11 = {2'b11};
        }

        cx_valid_data: cross cp_valid, cp_data_lsb;
    endgroup

    function new(virtual __IF_NAME__ vif___DUT_NAME__, mailbox #(__TX_CLASS__) mbx_mon2cov);
        this.vif___DUT_NAME__ = vif___DUT_NAME__;
        this.mbx_mon2cov = mbx_mon2cov;
        this.m_tx_item = new();
        this.cg___DUT_NAME___tx = new();
    endfunction

    virtual task run();
        forever begin
            mbx_mon2cov.get(m_tx_item);
            cg___DUT_NAME___tx.sample();
        end
    endtask
endclass

`endif
'@

    $templates['env/environment.svh'] = @'
`ifndef __ENVIRONMENT_GUARD__
`define __ENVIRONMENT_GUARD__

class __ENV_CLASS__;
    __CFG_CLASS__ m_cfg;

    __GEN_CLASS__ m_generator;
    __DRV_CLASS__ m_driver;
    __MON_CLASS__ m_monitor;
    __SCB_CLASS__ m_scoreboard;
    __COV_CLASS__ m_coverage;

    mailbox #(__TX_CLASS__) mbx_gen2drv;
    mailbox #(__TX_CLASS__) mbx_mon2scb;
    mailbox #(__TX_CLASS__) mbx_mon2cov;

    virtual __IF_NAME__ vif___DUT_NAME__;

    function new(virtual __IF_NAME__ vif___DUT_NAME__, __CFG_CLASS__ cfg = null);
        this.vif___DUT_NAME__ = vif___DUT_NAME__;
        if (cfg == null) begin
            m_cfg = new();
        end else begin
            m_cfg = cfg;
        end

        mbx_gen2drv = new();
        mbx_mon2scb = new();
        mbx_mon2cov = new();

        m_generator = new(m_cfg, mbx_gen2drv);
        m_driver = new(vif___DUT_NAME__, mbx_gen2drv);
        m_monitor = new(vif___DUT_NAME__, mbx_mon2scb, mbx_mon2cov);
        m_scoreboard = new(mbx_mon2scb);
        m_coverage = new(vif___DUT_NAME__, mbx_mon2cov);
    endfunction

    virtual task run();
        fork
            m_driver.run();
            m_monitor.run();
            m_scoreboard.run();
            m_coverage.run();
            m_generator.run();
        join_none
    endtask
endclass

`endif
'@

    $templates['tests/base_test.svh'] = @'
`ifndef __BASE_TEST_GUARD__
`define __BASE_TEST_GUARD__

class __BASE_TEST_CLASS__;
    __CFG_CLASS__ m_cfg;
    __ENV_CLASS__ m_env;
    virtual __IF_NAME__ vif___DUT_NAME__;

    function new(virtual __IF_NAME__ vif___DUT_NAME__);
        this.vif___DUT_NAME__ = vif___DUT_NAME__;
        this.m_cfg = new();
    endfunction

    virtual task configure();
        m_cfg.m_num_transactions = 100;
        m_cfg.m_verbose = 1'b1;
    endtask

    virtual task run();
        configure();
        m_env = new(vif___DUT_NAME__, m_cfg);
        m_env.run();

        repeat (m_cfg.m_num_transactions + 50) begin
            @(posedge vif___DUT_NAME__.iClk);
        end
    endtask
endclass

`endif
'@

    $templates['tests/test_01.svh'] = @'
`ifndef __TEST01_GUARD__
`define __TEST01_GUARD__

class __TEST01_CLASS__ extends __BASE_TEST_CLASS__;
    function new(virtual __IF_NAME__ vif___DUT_NAME__);
        super.new(vif___DUT_NAME__);
    endfunction

    virtual task configure();
        super.configure();
        m_cfg.m_num_transactions = 200;
    endtask
endclass

`endif
'@

    $templates['tests/test_02.svh'] = @'
`ifndef __TEST02_GUARD__
`define __TEST02_GUARD__

class __TEST02_CLASS__ extends __BASE_TEST_CLASS__;
    function new(virtual __IF_NAME__ vif___DUT_NAME__);
        super.new(vif___DUT_NAME__);
    endfunction

    virtual task configure();
        super.configure();
        m_cfg.m_num_transactions = 32;
        m_cfg.m_verbose = 1'b0;
    endtask
endclass

`endif
'@

    $templates['interface.sv'] = @'
interface __IF_NAME__(input logic iClk, input logic iRstn);
    logic [31:0] tb_data_in;
    logic [31:0] tb_data_out;
    logic        tb_valid;
    logic        tb_ready;
endinterface
'@

    $templates['tb_pkg.sv'] = @'
package __PKG_NAME__;
    `include "include/tb_defs.svh"

    `include "objs/transaction.svh"
    `include "objs/config.svh"

    `include "components/generator.svh"
    `include "components/driver.svh"
    `include "components/monitor.svh"

    `include "env/scoreboard.svh"
    `include "env/coverage.svh"
    `include "env/environment.svh"

    `include "tests/base_test.svh"
    `include "tests/test_01.svh"
    `include "tests/test_02.svh"
endpackage
'@

    $templates['tb_top.sv'] = @'
`timescale 1ns / 1ps

module TbTop;
    import __PKG_NAME__::*;

    localparam int unsigned LP_CLK_PERIOD  = 10;
    localparam int unsigned LP_SIM_TIMEOUT = 100_000;

    logic iClk;
    logic iRstn;

    __IF_NAME__ uIf (
        .iClk(iClk),
        .iRstn(iRstn)
    );

    // TODO: Connect the DUT with explicit pin mapping.
    // __DUT_NAME__ uDut (
    //     .iClk(iClk),
    //     .iRstn(iRstn),
    //     .iData(uIf.tb_data_in),
    //     .oData(uIf.tb_data_out),
    //     .iValid(uIf.tb_valid),
    //     .oReady(uIf.tb_ready)
    // );

    initial begin
        iClk = 1'b0;
        forever #(LP_CLK_PERIOD / 2.0) iClk = ~iClk;
    end

    initial begin
        iRstn = 1'b0;
        uIf.tb_data_in = '0;
        uIf.tb_valid = 1'b0;
        uIf.tb_ready = 1'b0;
        repeat (5) @(posedge iClk);
        iRstn = 1'b1;
    end

    initial begin
        __TEST01_CLASS__ tb_test;
        @(posedge iRstn);
        tb_test = new(uIf);
        tb_test.run();
        repeat (20) @(posedge iClk);
        $finish;
    end

    initial begin
        #(LP_SIM_TIMEOUT);
        $fatal(1, "[TB] Timeout reached: %0d ns", LP_SIM_TIMEOUT);
    end

    initial begin
        $dumpfile("__DUT_NAME___tb_wave.vcd");
        $dumpvars(0, TbTop);
    end
endmodule
'@

    foreach ($key in @($templates.Keys)) {
        $value = $templates[$key]
        $value = $value.Replace('__DUT_NAME__', $dutNameNorm)
        $value = $value.Replace('__PKG_NAME__', $pkgName)
        $value = $value.Replace('__IF_NAME__', $ifName)
        $value = $value.Replace('__TX_CLASS__', $txClass)
        $value = $value.Replace('__CFG_CLASS__', $cfgClass)
        $value = $value.Replace('__GEN_CLASS__', $genClass)
        $value = $value.Replace('__DRV_CLASS__', $drvClass)
        $value = $value.Replace('__MON_CLASS__', $monClass)
        $value = $value.Replace('__SCB_CLASS__', $scbClass)
        $value = $value.Replace('__COV_CLASS__', $covClass)
        $value = $value.Replace('__ENV_CLASS__', $envClass)
        $value = $value.Replace('__BASE_TEST_CLASS__', $baseTestClass)
        $value = $value.Replace('__TEST01_CLASS__', $test01Class)
        $value = $value.Replace('__TEST02_CLASS__', $test02Class)
        $value = $value.Replace('__TB_DEFS_GUARD__', "${macroPrefix}_TB_DEFS_SVH")
        $value = $value.Replace('__TRANSACTION_GUARD__', "${macroPrefix}_TRANSACTION_SVH")
        $value = $value.Replace('__CONFIG_GUARD__', "${macroPrefix}_CONFIG_SVH")
        $value = $value.Replace('__GENERATOR_GUARD__', "${macroPrefix}_GENERATOR_SVH")
        $value = $value.Replace('__DRIVER_GUARD__', "${macroPrefix}_DRIVER_SVH")
        $value = $value.Replace('__MONITOR_GUARD__', "${macroPrefix}_MONITOR_SVH")
        $value = $value.Replace('__SCOREBOARD_GUARD__', "${macroPrefix}_SCOREBOARD_SVH")
        $value = $value.Replace('__COVERAGE_GUARD__', "${macroPrefix}_COVERAGE_SVH")
        $value = $value.Replace('__ENVIRONMENT_GUARD__', "${macroPrefix}_ENVIRONMENT_SVH")
        $value = $value.Replace('__BASE_TEST_GUARD__', "${macroPrefix}_BASE_TEST_SVH")
        $value = $value.Replace('__TEST01_GUARD__', "${macroPrefix}_TEST_01_SVH")
        $value = $value.Replace('__TEST02_GUARD__', "${macroPrefix}_TEST_02_SVH")
        $templates[$key] = $value.TrimStart("`r", "`n") + "`r`n"
    }

    return $templates
}

function Write-TextFile {
    param(
        [string]$Path,
        [string]$Content,
        [bool]$Force
    )

    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $existsBefore = Test-Path -LiteralPath $Path
    if ($existsBefore -and (-not $Force)) {
        return "skipped"
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)

    if ($existsBefore) {
        return "updated"
    }

    return "created"
}

function New-DutTbScaffold {
    param(
        [string]$BaseTbRoot,
        [string]$DutName,
        [bool]$Force
    )

    $dutNorm = Normalize-DutName $DutName
    if ([string]::IsNullOrWhiteSpace($dutNorm)) {
        throw "Invalid DUT name: '$DutName'"
    }

    $dutRoot = Join-Path $BaseTbRoot ("{0}_tb" -f $dutNorm)
    $requiredDirs = @(
        'components',
        'env',
        'tests',
        'include',
        'objs'
    )

    foreach ($dirRel in $requiredDirs) {
        $dirPath = Join-Path $dutRoot $dirRel
        if (-not (Test-Path -LiteralPath $dirPath)) {
            New-Item -ItemType Directory -Path $dirPath -Force | Out-Null
        }
    }

    $templates = New-TemplateMap -DutName $dutNorm

    $created = 0
    $updated = 0
    $skipped = 0

    foreach ($relPath in @($templates.Keys)) {
        $normalizedRel = $relPath -replace '/', [System.IO.Path]::DirectorySeparatorChar
        $targetPath = Join-Path $dutRoot $normalizedRel
        $status = Write-TextFile -Path $targetPath -Content $templates[$relPath] -Force $Force
        switch ($status) {
            'created' { $created++ }
            'updated' { $updated++ }
            default { $skipped++ }
        }
    }

    return [PSCustomObject]@{
        DutName = $dutNorm
        DutRoot = $dutRoot
        Created = $created
        Updated = $updated
        Skipped = $skipped
    }
}

if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or -not (Test-Path -LiteralPath $ProjectRoot)) {
    throw "Project path is invalid: $ProjectRoot"
}
if ([string]::IsNullOrWhiteSpace($TbRoot)) {
    $TbRoot = Join-Path $ProjectRoot 'tb'
}
if (-not (Test-Path -LiteralPath $TbRoot)) {
    New-Item -ItemType Directory -Path $TbRoot -Force | Out-Null
}

$candidates = @(Collect-DutCandidates -ProjectRootPath $ProjectRoot -ManifestListPath $ManifestSrcList)

Write-Host "======================================================================="
Write-Host " [TB Scaffold] Create DUT-specific testbench scaffold"
Write-Host " Project: $ProjectRoot"
Write-Host " TB Root: $TbRoot"
Write-Host "======================================================================="

if ($candidates.Count -gt 0) {
    Write-Host ""
    Write-Host "Detected source DUT candidates:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $item = $candidates[$i]
        Write-Host ("[{0}] {1}    ({2})" -f ($i + 1), $item.Name, $item.RelativePath)
    }
} else {
    Write-Host "[WARN] No DUT candidates detected from source scan." -ForegroundColor Yellow
}

$selectedDuts = [System.Collections.Generic.List[string]]::new()

if ($applyAllMode) {
    foreach ($cand in $candidates) {
        $selectedDuts.Add($cand.Name)
    }
    if ($selectedDuts.Count -eq 0) {
        throw "--all was used but no source DUT candidates were found."
    }
} elseif (-not [string]::IsNullOrWhiteSpace($RequestedDut)) {
    $tokens = @($RequestedDut -split '[,\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($token in $tokens) {
        if ($token -match '^(?i)a(ll)?$') {
            foreach ($cand in $candidates) {
                $selectedDuts.Add($cand.Name)
            }
            continue
        }

        $resolved = Resolve-DutToken -Token $token -Candidates $candidates
        if ([string]::IsNullOrWhiteSpace($resolved)) {
            Write-Host "[WARN] Ignored invalid token: $token" -ForegroundColor Yellow
            continue
        }

        if (-not $selectedDuts.Contains($resolved)) {
            $selectedDuts.Add($resolved)
        }
    }

    if ($selectedDuts.Count -eq 0) {
        throw "No valid DUT name was resolved from --dut '$RequestedDut'."
    }
} else {
    while ($selectedDuts.Count -eq 0) {
        if ($candidates.Count -gt 0) {
            $raw = Read-Host "Select DUT (index/name, multiple with comma, A=all, Q=quit)"
        } else {
            $raw = Read-Host "Enter DUT name (Q=quit)"
        }

        if ([string]::IsNullOrWhiteSpace($raw)) {
            continue
        }

        if ($raw -match '^(?i)q$') {
            exit 99
        }

        $tokens = @($raw -split '[,\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        foreach ($token in $tokens) {
            if ($token -match '^(?i)a(ll)?$') {
                foreach ($cand in $candidates) {
                    if (-not $selectedDuts.Contains($cand.Name)) {
                        $selectedDuts.Add($cand.Name)
                    }
                }
                continue
            }

            $resolved = Resolve-DutToken -Token $token -Candidates $candidates
            if ([string]::IsNullOrWhiteSpace($resolved)) {
                Write-Host "[WARN] Ignored invalid token: $token" -ForegroundColor Yellow
                continue
            }

            if (-not $selectedDuts.Contains($resolved)) {
                $selectedDuts.Add($resolved)
            }
        }

        if ($selectedDuts.Count -eq 0) {
            Write-Host "[ERROR] No valid DUT selected. Try again." -ForegroundColor Red
        }
    }
}

Write-Host ""
Write-Host "Selected DUT name(s): $($selectedDuts -join ', ')" -ForegroundColor Green

$summary = @()
foreach ($dut in $selectedDuts) {
    $result = New-DutTbScaffold -BaseTbRoot $TbRoot -DutName $dut -Force $forceMode
    $summary += $result
    Write-Host ("[DONE] {0} -> {1}" -f $result.DutName, $result.DutRoot) -ForegroundColor Green
    Write-Host ("       files created={0}, updated={1}, skipped={2}" -f $result.Created, $result.Updated, $result.Skipped)
}

$totalCreated = ($summary | Measure-Object -Property Created -Sum).Sum
$totalUpdated = ($summary | Measure-Object -Property Updated -Sum).Sum
$totalSkipped = ($summary | Measure-Object -Property Skipped -Sum).Sum

Write-Host ""
Write-Host "======================================================================="
Write-Host ("TB scaffold generation complete. DUT folders={0}, files created={1}, updated={2}, skipped={3}" -f $summary.Count, $totalCreated, $totalUpdated, $totalSkipped)
Write-Host "======================================================================="
exit 0
