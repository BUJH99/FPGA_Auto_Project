# SystemVerilog Support Mid Check (Updated: 2026-02-26)

## 1. Scope
- Target: validate and strengthen SystemVerilog compatibility across all `templates/bat` menu scripts.
- Method: static inspection + smoke runs on representative SV projects/fixtures.
- This document reflects the latest implementation status after the recent SV hardening round.

## 2. Current Overall Status

Source of truth:
- `templates/docs/systemverilog_support_matrix.md`

Current 21-script snapshot:
- `Supported`: 3 (`2,6,16`)
- `Partial`: 12 (`1,4,5,7,8,10,11,12,14,15,17,21`)
- `Unsupported`: 0
- `SV-agnostic/N/A`: 6 (`9,13,18,19,20,22`)

Key delta vs previous baseline:
- `legacy_docs_generate.bat` moved from effectively unsupported (`.v` only scan) to `Partial` (`.v/.sv` scan).
- Hierarchy and declaration handling improved for broader SV declarations and TB filtering policy.
- `code_verilog_hierarchy_print.bat` removed; hierarchy output is now consolidated to browse mode.

## 3. Implemented Changes (This Round)

### 3.1 Declaration Regex Consistency
Unified handling for `module/program automatic|static` and removed name mis-detection.

Updated files:
- `templates/tools/parse_tb.js`
- `templates/bat/sim_iverilog_vcd_run.bat`
- `templates/bat/sim_vivado_run.bat`
- `templates/tools/annotate_hdl_info.js`
- `templates/tools/generate_one_source_report.js`
- `templates/tools/generate_presentation.py`
- `templates/tcl/generate_html_report.tcl`

### 3.2 Schematic Module Selection Fix
`code_schematic_draw.bat` no longer uses filename stems as module candidates.
Selection list now comes from real `module` declarations.

Implementation:
- indexer-first (`hdl_indexer.js`) module discovery
- fallback regex discovery in worker script
- case-insensitive canonical module mapping

Updated files:
- `templates/bat/code_schematic_draw.bat`
- `templates/tools/run_schematic_jobs.ps1`

### 3.3 Legacy Docs `.sv` Support
`legacy_docs_generate` path now scans both `.v` and `.sv`, and source linking uses `.v` first + `.sv` fallback.

Updated files:
- `templates/tools/generate_doc.js`
- `templates/bat/legacy_docs_generate.bat`

### 3.4 Auto Sim+Report Stability
Reduced hard failures caused by `open_vcd` conflicts after Vivado simulation.

Implementation:
- `open_vcd` conflict downgraded to warning
- fallback VCD search/copy path added
- report generation continues when fallback VCD exists

Updated file:
- `templates/tools/generate_report.js`

### 3.5 Hierarchy Enhancements
Hierarchy browse tool aligned on:
- `--include-tb` policy
- TB-hidden default behavior
- declaration groups for `package/interface/program/class/checker`
- `module automatic/static` fallback parsing support

Updated files:
- `templates/bat/code_verilog_hierarchy_browse.bat`
- `templates/tools/hdl_indexer.js`

## 4. Verification Summary

## 4.1 Hierarchy Tools
Commands:
- `templates\bat\code_verilog_hierarchy_browse.bat templates\examples\sv_regression_project --once`
- `templates\bat\code_verilog_hierarchy_browse.bat templates\examples\sv_regression_project --once --include-tb`

Result:
- PASS
- default TB hide policy works
- `--include-tb` includes TB scope
- declaration sections display correctly

## 4.2 Broad SV Declaration Parsing
Fixture included:
- `module automatic`
- `program automatic`
- `class`
- `checker`
- `package`
- `interface`

Command:
- `node templates/tools/hdl_indexer.js <fixture> --pretty`

Result:
- PASS
- declarations and summary counters include `programs/classes/checkers`
- no `automatic`-as-name mis-detection

## 4.3 Vivado Simulation Path
Command:
- `sim_report_auto_run.bat templates\examples\sv_regression_project`

Result:
- PASS
- Vivado logs include `Analyzing SystemVerilog file ...`
- report completed with fallback VCD warning when needed

## 4.4 Icarus Simulation Path
Command:
- `sim_iverilog_vcd_run.bat templates\examples\sv_regression_project --tb tb_top --no-pause`

Result:
- EXPECTED PARTIAL
- `.sv` filelist/top handling path is correct
- compile can fail due Icarus SV feature limits (toolchain limitation, not script routing issue)

Additional fixture:
- `program automatic tb_prog` testbench

Result:
- PASS (`top=tb_prog`, run success)

## 4.5 Legacy Docs Regression
Command:
- `legacy_docs_generate.bat <sv-only fixture>`

Result:
- PASS
- no more `.v`-only blocking message

## 5. Open Limitations

### 5.1 AST Provider Not Active in Current Environment
Observed:
- `npm ls tree-sitter tree-sitter-verilog --depth=0` reports invalid/missing native modules in this environment.
- `require('tree-sitter')` fails currently.

Impact:
- `hdl_indexer` runs heuristic mode (`parser.astAvailable=false`)
- strict gate fails with `ast_provider_missing`

### 5.2 External Tool Limits
- Icarus Verilog: limited support for advanced SV TB features (`class/mailbox/...`)
- Yosys: valid SV constructs may still fail in schematic flow

## 6. Recommended Next Steps
1. Recover native AST environment on Windows and re-run strict gate.
2. Keep CI gate as `hdl_indexer --strict --write` once AST env is stable.
3. Maintain matrix as source of truth for per-batch support status.

## 7. Quick Re-check Commands

```batch
:: Hierarchy (default TB hidden)
templates\bat\code_verilog_hierarchy_browse.bat templates\examples\sv_regression_project --once

:: Hierarchy (include TB)
templates\bat\code_verilog_hierarchy_browse.bat templates\examples\sv_regression_project --once --include-tb

:: Vivado sim/report path
templates\bat\sim_report_auto_run.bat templates\examples\sv_regression_project

:: Icarus path (tool-limit expected on advanced SV)
templates\bat\sim_iverilog_vcd_run.bat templates\examples\sv_regression_project --tb tb_top --no-pause

:: AST environment check
cd templates
npm ls tree-sitter tree-sitter-verilog --depth=0
node tools/hdl_indexer.js examples/sv_regression_project --strict --write
```
