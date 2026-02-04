# Findings & Decisions

## Requirements
- User requested: analyze all files in current folder (including subfolders) and summarize functionality
- Provide improvement suggestions, including VCD auto-open for Icarus and possible Vivado IP catalog automation (at least BRAM)

## Research Findings
- Read Me.md now documents the automation flow in ASCII (previous content was encoding-garbled)
- Setup.bat creates a new project folder (constrs/output/scripts/src/tb) and copies template scripts from templates
- Test1/autorun.bat runs Vivado batch flow, cleans output, runs run_full_flow.tcl, exports RTL hierarchy, generates report, and optionally calls program_device.bat
- Test1/program_device.bat runs Vivado batch Hardware Manager via scripts/program_fpga.tcl and logs to output/vivado_program.log
- Test1/scripts/run_full_flow.tcl orchestrates non-project flow: read sources/XDC, synth, opt, place, route, power/timing checks, write reports/checkpoints, and generate bitstream if power/timing pass
- Test1/scripts/export_rtl_hierarchy.tcl creates Mermaid RTL hierarchy (pre-synth) by running synth_design -rtl and traversing non-primitive cells
- Test1/scripts/generate_report.tcl parses Vivado reports and generates Final_Build_Report.html (Tailwind/Chart/Mermaid) with timing/power/utilization/RTL hierarchy
- Test1/scripts/program_fpga.tcl uses Vivado Hardware Manager to program the bitstream from build_config.tcl via local hw_server (localhost:3121)
- Test1/clockInfo.txt is a Vivado clock routing debug summary (example output)
- Test1/src/Top.v is top-level: clock divider -> 1kHz/100Hz, counters, 7-seg controller (fnd)
- Test1/src/report.txt appears to be concatenated Verilog modules (adder, bcd, clk_div, counters, decoder, fnd controller, mux, Top), likely a generated/merged reference
- Test1/src/*.v contains 7-seg display logic (bcd, digit_splitter, mux, decoder, fndController), counters, clock divider, and a standalone adder module
- Test1/constrs/Basys-3-Master.xdc maps clk/reset/mode/stop and 7-seg pins for Basys-3
- Test1/usage_statistics_webtalk.xml is Vivado usage telemetry from a prior run (tool version, device, utilization/power summary)
- Test1/usage_statistics_webtalk.html is the human-readable view of the same Vivado usage telemetry
- Test1/output/report_gen.log shows generate_report.tcl ran under Vivado v2024.1 and produced Final_Build_Report.html using rtl_hierarchy.mmd
- Test1/output/rtl_hierarchy.mmd contains a Mermaid graph of the RTL module tree (Top -> U_FndController, U_clk_div, counters, etc.)
- Test1/output/rtl_hier.log shows export_rtl_hierarchy.tcl ran successfully and synthesized RTL for hierarchy extraction
- Test1/output/vivado_full_build.log is the main Vivado batch log for run_full_flow.tcl; shows synth/impl steps and constraints warning
- Test1/output/Final_Build_Report.html now shows correct utilization after fixing generate_report.tcl parsing indexes
- Test1/output/reports/timing_summary.rpt indicates multiple unconstrained endpoints and missing I/O delays (timing constraints incomplete)
- Test1/output/reports/power_report.rpt shows total on-chip power ~0.113W with low confidence (missing activity constraints)
- Test1/output/reports/post_place_util.rpt and post_synth_util.rpt show realistic utilization (LUTs ~224/20800, regs ~62/41600)
- Test1/output/reports/post_route_status.rpt shows 0 routing errors
- Test1/output/Top.bit and output/checkpoints/*.dcp are binary artifacts (bitstream + checkpoints)
- Added Test1/sim_icarus.bat for Icarus simulation with VCD auto-open and Test1/tb/tb_Top.v as a minimal testbench
- Added Test1/open_ipi_gui.bat and Test1/scripts/open_ipi_gui.tcl to open IP Integrator GUI with sources added
- Added Test1/finalize_bd.bat and Test1/scripts/finalize_bd.tcl to finalize BD, create wrapper, and export HDL
- Added Test1/build_config.tcl and config loading in build/report/RTL scripts
- Added optional IP (.xci) handling in non-project build and RTL hierarchy flow
- Added Test1/ip with exported blk_mem_gen_0.xci for non-project synthesis
- Added Test1/retarget_ip.bat and scripts/retarget_ip.tcl to retarget IP to build_config part and export .xci
- Added IVERILOG behavioral RAM path in bram_wrapper.v for Icarus simulation
- Updated Setup.bat and refreshed Read Me.md to reflect the new automation steps (including ip/)
- Reorganized templates into templates/ and removed the sample Test1 project for a compact layout
- open_ipi_gui.tcl now opens GUI without auto-creating a block design
- finalize_bd.tcl no longer generates a wrapper or updates build_config.tcl
- Read Me.md clarifies retargeting for IP Catalog flows
- sim_icarus.bat now accepts an optional tb file and defaults to tb/*_tb.v
- sim_icarus.bat also falls back to tb/tb_*.v when no argument is provided
- templates/tb/tb_Top.v provides a VCD-aware testbench template

## Technical Decisions
| Decision | Rationale |
|----------|-----------|
| Use planning-with-files templates in repo root | Aligns with skill instructions and keeps context on disk |

## Issues Encountered
| Issue | Resolution |
|-------|------------|
| session-catchup.py path mismatch (.claude vs .codex) | Skipped catchup and created files from templates |

## Resources
- C:\Users\user\.codex\skills\planning-with-files\templates\task_plan.md
- C:\Users\user\.codex\skills\planning-with-files\templates\findings.md
- C:\Users\user\.codex\skills\planning-with-files\templates\progress.md

## Visual/Browser Findings
-
