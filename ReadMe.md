# FPGA Automation Toolkit

<div align="center">

![FPGA](https://img.shields.io/badge/FPGA-Verilog%20%2F%20SystemVerilog-blue)
![Platform](https://img.shields.io/badge/Platform-Windows-lightgrey)
![License](https://img.shields.io/badge/License-MIT-green)

**Batch-based Automation Toolkit for Verilog/SystemVerilog Development**

[English Version](#english-version) | [Korean Summary](#korean-summary)

</div>

---

<div id="english-version"></div>

## English Version

### Overview
This project provides batch-script automation for Verilog/SystemVerilog FPGA workflows.
`MAIN.bat` is the launcher, and task entry points are in `templates/bat/*.bat`.

### Directory Structure
- `MAIN.bat`: main launcher
- `templates/`: shared scripts/tools/configs
- `templates/bat/`: task batch scripts
- `templates/tools/`: helper tools (Node.js/PowerShell/Python)
- `templates/tcl/`: Vivado Tcl scripts

### Quick Start

#### 1. Prerequisites
Required tools in `PATH`:
- Xilinx Vivado
- Node.js (+ npm)
- Python 3

Optional (recommended for full flow):
- Pandoc (`md -> html/docx`)
- Yosys or `yowasp-yosys` (schematic generation)
- Visual Studio Build Tools C++ workload (for native AST parser dependencies)

#### 2. Install dependencies
Run once:

```batch
cd templates
npm install
```

#### 3. Run
1. Execute `MAIN.bat`
2. Select target project
3. Choose task from the menu

### Core Workflows

#### A. One Source Reporting (Recommended)
1. `report_hdl_info_annotate.bat`
2. `report_markdown_generate.bat`
3. `report_markdown_to_docx.bat`

`report_markdown_generate.bat` behavior:
- Supports `--modules=` or interactive selection
- Selection applies only to `1.3 Sub block`
- `Top` is always included first in sub-block section

#### B. Interactive Simulation (Vivado GUI)
- `sim_vivado_run.bat` scans TB files (`.v/.sv`), lets you choose top, then launches Vivado GUI simulation.
- Artifacts stay inside project:
  - `<ProjectDir>/vivado_project/`
  - `<ProjectDir>/vivado_project/vivado_sim_log/`

#### C. Build & Program
- Step-by-step: `vivado_build_flow_run.bat` -> `vivado_fpga_program.bat`
- One-click: `vivado_build_and_program_auto.bat`

### SystemVerilog Compatibility (Updated: February 26, 2026)
- Reference matrix: `templates/docs/systemverilog_support_matrix.md`
- Compatibility levels: `Supported`, `Partial`, `Unsupported`, `SV-agnostic/N/A`
- Current snapshot (22 menu scripts):
  - `Supported`: 4
  - `Partial`: 12
  - `Unsupported`: 0
  - `SV-agnostic/N/A`: 6

### Recent SV Upgrades
- Hierarchy tools:
  - `code_verilog_hierarchy_browse.bat <Project_Directory> [--once] [--include-tb]`
  - `code_verilog_hierarchy_print.bat <Project_Directory> [--include-tb]`
  - Default scope hides TB; `--include-tb` shows TB modules and TB-side SV declarations
  - Declaration groups include `package`, `interface`, `program`, `class`, `checker`
- Parser consistency:
  - Fixed `module/program automatic|static` name mis-detection across hierarchy/report/sim helper paths
- Schematic flow:
  - `code_schematic_draw.bat` now lists real declared modules instead of filename stems
- Legacy docs:
  - `legacy_docs_generate.bat` now scans `.v` and `.sv`
- Auto sim+report:
  - VCD open collisions are handled as warning; fallback VCD lookup added

### AST Status and Strict Gate
- `templates/tools/hdl_indexer.js` supports AST mode with `tree-sitter` + `tree-sitter-verilog`.
- If AST provider is missing, it falls back to heuristic parsing with warnings.
- `--strict` fails on:
  - `ast_provider_missing`
  - `ast_parse_failed`
  - `ast_syntax_error`
- `ast_syntax_degraded` is warning-only (known parser limitation fallback).

AST environment check:

```batch
cd templates
npm ls tree-sitter tree-sitter-verilog --depth=0
node tools/hdl_indexer.js examples/sv_regression_project --strict --write
```

### Toolchain Limits (Important)
- Icarus Verilog can fail on advanced SV TB constructs (`class`, `mailbox`, etc.).
- Yosys can fail on valid SV constructs accepted by Vivado.
- Recommended broad SV simulation path:
  - `sim_vivado_run.bat`
  - `sim_report_auto_run.bat`

### Project Layout

```text
[ProjectName]/
|-- src/                          # Design sources (.v, .sv)
|-- tb/                           # Testbenches
|-- constrs/                      # Constraint files (.xdc)
|-- ip/                           # IP cores
|-- output/                       # Build/report outputs
|   |-- docs/                     # report.md / html / docx
|   |-- Diagram/                  # Simple/Detailed diagrams
|   `-- FINALReport/              # Vivado report assets
|-- vivado_project/               # Vivado simulation workspace
|   |-- project/                  # Generated Vivado sim project(s)
|   `-- vivado_sim_log/           # vivado log/journal/backup files
`-- Presentation/                 # Presentation assets
```

### Troubleshooting
- `netlistsvg not found`: run `npm install` in `templates`
- DOCX generation failed: close `report.docx` if open in Word
- `vivado` not found: confirm Vivado `bin` is in system `PATH`

---

<div id="korean-summary"></div>

## Korean Summary

Korean users can treat this README as the latest SV operation guide:
- Current SV status is summarized in `templates/docs/systemverilog_support_matrix.md`.
- This round improved hierarchy (`--include-tb`), declaration parsing (`automatic/static`), schematic module selection, legacy docs `.sv` support, and auto-sim VCD resilience.
- AST strict quality gate is available, but native AST dependency setup is still required in the current environment.
- Recommended simulation route for broad SV compatibility is:
  1. `sim_vivado_run.bat`
  2. `sim_report_auto_run.bat`

