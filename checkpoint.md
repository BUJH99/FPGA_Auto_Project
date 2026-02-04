# Checkpoint - FPGA_Auto

This is a snapshot of the current state after the BRAM IP debugging session.

## What Was Done
- Added Icarus simulation flow with VCD auto-open and sample testbench.
- Fixed report utilization parsing; HTML now matches Vivado reports.
- Added config-driven build flow via `build_config.tcl`.
- Added IP Integrator GUI automation (`open_ipi_gui.bat`) and BD finalize flow (`finalize_bd.bat`).
- Added IP retarget flow (`retarget_ip.bat`) to rebuild IP for the configured part.
- Added `IVERILOG` behavioral BRAM path in `bram_wrapper.v` for Icarus simulation.
- Updated `Setup.bat` to copy templates for new projects.
- Updated README and improvements notes.

## Current Issue (BRAM)
- `blk_mem_gen_0` was created for a different part (xc7a12t) and locked.
- Running `retarget_ip.bat` rebuilds IP for the part in `build_config.tcl`.
- `bram_wrapper.v` port mapping matches the IP stub (clka/ena/wea/addra/dina/douta).
- Icarus uses a behavioral RAM when `IVERILOG` is defined.

## Files Added/Updated (Key)
- `Test1/sim_icarus.bat`
- `Test1/tb/tb_Top.v`
- `Test1/build_config.tcl`
- `Test1/open_ipi_gui.bat`
- `Test1/scripts/open_ipi_gui.tcl`
- `Test1/finalize_bd.bat`
- `Test1/scripts/finalize_bd.tcl`
- `Test1/retarget_ip.bat`
- `Test1/scripts/retarget_ip.tcl`
- `Test1/scripts/run_full_flow.tcl`
- `Test1/scripts/export_rtl_hierarchy.tcl`
- `Test1/scripts/generate_report.tcl`
- `Test1/scripts/program_fpga.tcl`
- `Test1/src/bram_wrapper.v`
- `Setup.bat`
- `Read Me.md`
- `improvements.md`

## Recommended Next Steps (When You Resume)
1) If using IP Catalog (no BD), run:
   - `Test1/retarget_ip.bat`
   - `Test1/autorun.bat`

2) If using IP Integrator BD:
   - `Test1/open_ipi_gui.bat` (GUI edit)
   - `Test1/finalize_bd.bat`
   - `Test1/autorun.bat`

3) If build is still running, check:
   - `Test1/output/vivado_full_build.log`

## Notes
- Last `run_full_flow.tcl` attempt timed out at 120s while Vivado was still working.
- IP output products are generated under `c:/Users/user/vivado_ipi.gen/...` by Vivado.
