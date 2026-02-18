# Report BAT Guide

## Scope
- This document is for the current report automation flow in this repo.
- Goal: keep `report.md` as the single source, then build `html/docx` from it.

## Recommended Flow (One Source)
1. (Optional) `templates\bat\prepare_waveform_folders.bat <ProjectDir>` if this script exists in your repo
2. (Optional) `templates\bat\annotate_hdl_info.bat <ProjectDir>` to create initial header templates
3. Fill/adjust `MODULE_INFO` and `TB_INFO` blocks manually in source/testbench files
4. `templates\bat\draw_schematic.bat <ProjectDir>`
5. `templates\bat\draw_fsm.bat <ProjectDir>`
6. `templates\bat\generate_report_md.bat <ProjectDir>`
   - Optional: pass `--modules=moduleA,moduleB` for sub-block filtering
7. Edit `<ProjectDir>\output\docs\report.md` (manual review/update)
8. `templates\bat\mdToReport.bat <ProjectDir>`

## What Each BAT Does
- `prepare_waveform_folders.bat`
  - (If present in your repo)
  - Reads `src/*.v` and `src/*.sv`
  - Creates `waveform/<module_name>/` folders
- `draw_schematic.bat`
  - Generates diagram assets:
  - `output/Diagram/Simple/<module>/<module>.svg|drawio|png`
  - `output/Diagram/Detailed/<module>/<module>.svg|drawio|png`
- `annotate_hdl_info.bat`
  - Scans `src` and `tb` Verilog/SystemVerilog files
  - Inserts or refreshes structured header blocks:
  - `[MODULE_INFO_START] ... [MODULE_INFO_END]`
  - `[TB_INFO_START] ... [TB_INFO_END]`
  - For FSM-like RTL, automatically adds `StateDescription`
  - For TB, focuses on scenario/checkpoint bullets
- `draw_fsm.bat`
  - Generates FSM assets:
  - `output/fsm/<module>/<module>_fsm.svg|drawio|png`
- `generate_report_md.bat`
  - Generates `<ProjectDir>/output/docs/report.md` and `<ProjectDir>/output/docs/github.css`
  - Collects module structure and diagram/FSM/waveform references
  - Module selection (`--modules=` or interactive picker) applies to **section 1.3 sub-blocks only**
  - Sections `1.1` and `1.2` still use all modules
  - `Top` module is always included first in sub-block section
  - Parses code-header metadata blocks:
  - `[MODULE_INFO_START] ... [MODULE_INFO_END]`
  - `[TB_INFO_START] ... [TB_INFO_END]`
- `mdToReport.bat`
  - Converts existing `output/docs/report.md` to:
  - `<ProjectDir>/output/docs/report.html`
  - `<ProjectDir>/output/docs/report.docx`
  - If only legacy `<ProjectDir>/report.md` exists, it is used as fallback
  - If `pandoc` is missing, auto-install is attempted (`winget/choco/scoop`)

## Current Output Paths
- Markdown source: `<ProjectDir>/output/docs/report.md`
- CSS source: `<ProjectDir>/output/docs/github.css`
- HTML report: `<ProjectDir>/output/docs/report.html`
- Word report: `<ProjectDir>/output/docs/report.docx`
- Diagram assets: `<ProjectDir>/output/Diagram/...`
- FSM assets: `<ProjectDir>/output/fsm/...`
- Waveform folders: `<ProjectDir>/waveform/<module>/...`

## Legacy Scripts (Still Available)
- `templates\bat\generate_report.bat`
  - Old Vivado report parser flow (`output/reports` based)
- `templates\bat\generate_docs.bat`
  - Old documentation generator flow
- These are kept for compatibility, not the primary path.

## MAIN.bat Menu Mapping
- `annotate_hdl_info.bat`
- `generate_report_md.bat`
- `mdToReport.bat`
- Legacy section keeps `generate_report.bat`

## CLI Examples
- Generate full report:
  - `templates\bat\generate_report_md.bat <ProjectDir>`
- Generate sub-block section with selected modules:
  - `templates\bat\generate_report_md.bat <ProjectDir> --modules=uart_rx,uart_tx`
- Non-interactive mode (for scripts/CI):
  - `templates\bat\generate_report_md.bat <ProjectDir> --modules=Top,dht11_controller --no-pause`
