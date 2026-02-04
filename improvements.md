# FPGA_Auto Improvement Notes

This file tracks applied and proposed improvements for the Vivado automation
flow and the Icarus simulation workflow.

## Highlighted Backlog (Top 5)

| ID | Item | Why | Status | Notes |
|----|------|-----|--------|-------|
| 1 | **Add `pushd %~dp0` in `autorun.bat`** | Prevents path issues when launched from another directory | Not done | Consider applying to all batch entrypoints |
| 2 | **Add `.sv`/`.vhd` support in `run_full_flow.tcl`** | Supports SystemVerilog/VHDL projects | Not done | Use `read_verilog -sv` and `read_vhdl` |
| 3 | **Add generated clock constraints for `clk_div` outputs** | Fixes unconstrained timing warnings | Not done | `create_generated_clock` on 1kHz/100Hz outputs |
| 4 | **Timestamped `output/` folders** | Keeps build history, avoids accidental overwrites | Not done | Example: `output/20260201_235901/` |
| 5 | **Vivado IP (BRAM) automation or XPM BRAM option** | Enables IP reuse without GUI | Not done | Tcl `create_ip` flow or XPM RAM macros |

## Applied Improvements
- Fixed utilization parsing in `templates/scripts/generate_report.tcl` so HTML shows correct Available/Util%.
- Added `templates/sim_icarus.bat` to compile/run Icarus and open VCD with default viewer.
- Added IP Integrator automation (`open_ipi_gui.bat`, `finalize_bd.bat`) and new Tcl helpers.
- Added `templates/build_config.tcl` and config overrides in build/report/RTL scripts.
- Added optional IP (.xci) handling in non-project build and RTL hierarchy flow.
- Added `retarget_ip.bat` to rebuild IP for the configured part and export `.xci`.
- Updated `Setup.bat` to create a `tb` folder and copy template scripts.
- Refreshed `Read Me.md` with clean ASCII documentation and Icarus usage.

## Additional Ideas (Backlog)
- Add `--clean` option in `autorun.bat` instead of always deleting `output/`.
- Add `report_methodology` and `check_timing` results into the HTML report summary.
- Accept a config file (part number, top module, power limit) instead of hardcoding.
- Add `read_xdc` warnings to the report when constraints are incomplete.
- Add optional SAIF/VCD activity import for more accurate power estimates.
