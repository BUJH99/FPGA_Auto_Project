# SystemVerilog Support Matrix

This document tracks SystemVerilog compatibility for the batch entry points in `templates/bat`.

## Legend
- `Supported`: `.sv` path is implemented and validated in core flow.
- `Partial`: `.sv` path exists but has parser/toolchain/runtime constraints.
- `Unsupported`: `.sv` is not practically supported in current implementation.
- `SV-agnostic/N/A`: no direct HDL parser/compile responsibility.

## Baseline (Before This Update)
- `Supported`: 4 (`2,3,6,16`)
- `Partial`: 11 (`1,4,5,7,8,10,11,12,14,17,21`)
- `Unsupported`: 1 (`15`)
- `SV-agnostic/N/A`: 6 (`9,13,18,19,20,22`)

## Current Snapshot
- `Supported`: 3 (`2,6,16`)
- `Partial`: 12 (`1,4,5,7,8,10,11,12,14,15,17,21`)
- `Unsupported`: 0
- `SV-agnostic/N/A`: 6 (`9,13,18,19,20,22`)
- `Removed`: 1 (`3`, merged into `2`)

## Current Matrix

| No. | Script | Status | SV Handling Summary | Main Constraints / Notes |
|---|---|---|---|---|
| 1 | `code_schematic_draw.bat` | Partial | Module selection now uses real `module` declarations (indexer-first, regex fallback) | Yosys frontend limitations can fail advanced SV (`import`, etc.) |
| 2 | `code_verilog_hierarchy_browse.bat` | Supported | `.sv/.svh` scanned, SV declarations shown, `--include-tb` supported | Graph is module-instance centric; `program/class/checker` are declaration-only |
| 4 | `code_fsm_draw.bat` | Partial | Accepts `.v/.sv` and extracts FSM from source | Heuristic parser may miss atypical coding styles |
| 5 | `code_presentation_generate.bat` | Partial | Reads `.v/.sv`; uses internal parser + HDL index cache | Interactive prompts required unless explicitly automated |
| 6 | `sim_vivado_run.bat` | Supported | TB/source `.sv` supported end-to-end via Vivado Tcl | Vivado GUI/runtime dependency |
| 7 | `sim_report_auto_run.bat` | Partial | `.sv` TB parsing + Vivado sim + report generation supported | VCD output depends on TB dump behavior; fallback handling added |
| 8 | `sim_iverilog_vcd_run.bat` | Partial | `.sv` filelist and TB top parsing supported (`-g2012`) | Icarus SV feature coverage is tool-limited |
| 9 | `sim_vcd_svg_run.bat` | SV-agnostic/N/A | Converts VCD to SVG | Depends on existing VCD, not HDL language directly |
| 10 | `report_hdl_info_annotate.bat` | Partial | Scans `.v/.sv`, annotation regex updated for SV qualifiers | Heuristic annotation logic, not full AST semantics |
| 11 | `report_waveform_folders_prepare.bat` | Partial | Works with modules discovered from report generator (`.v/.sv`) | Depends on module parser quality in downstream tool |
| 12 | `report_markdown_generate.bat` | Partial | Generates report from `.v/.sv` project content | Some sections remain template/heuristic driven |
| 13 | `report_markdown_to_docx.bat` | SV-agnostic/N/A | Markdown to HTML/DOCX conversion | Pandoc version/option compatibility can fail independently of HDL |
| 14 | `legacy_report_generate.bat` | Partial | Consumes Vivado outputs; source scan includes `.v/.sv` | Legacy HTML flow, limited semantic SV understanding |
| 15 | `legacy_docs_generate.bat` | Partial | Legacy doc tool now scans `.v/.sv` | Legacy parser remains heuristic and feature-limited |
| 16 | `vivado_ipi_gui_launch.bat` | Supported | Vivado project source add supports `.v/.sv` | GUI and Vivado environment dependency |
| 17 | `vivado_build_flow_run.bat` | Partial | Non-project build reads `.v` + `.sv` | Build success depends on Vivado + source/tool constraints |
| 18 | `vivado_block_design_finalize.bat` | SV-agnostic/N/A | BD/IP export automation | No direct SV parsing path |
| 19 | `vivado_ip_retarget_part.bat` | SV-agnostic/N/A | IP retarget/export automation | No direct SV parsing path |
| 20 | `vivado_fpga_program.bat` | SV-agnostic/N/A | Bitstream programming only | No HDL parsing/compilation step |
| 21 | `vivado_build_and_program_auto.bat` | Partial | Delegates to #17 + #20 | Inherits #17 constraints |
| 22 | `sim_vcd_wavedrom_run.bat` | SV-agnostic/N/A | Converts VCD to WaveDrom | Depends on existing VCD, not HDL language directly |

## Important Notes
- `Icarus Verilog` and `Yosys` have external SystemVerilog support limits. Failures there are not always script defects.
- Recommended simulation path for broad SV TB compatibility:
  1. `6. sim_vivado_run.bat`
  2. `7. sim_report_auto_run.bat`
- Header files (`.svh`) are include-only inputs, not simulation top candidates.
