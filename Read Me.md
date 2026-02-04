# Vivado FPGA Build Automation & Reporting

This repo provides a Vivado automation flow with a high-level HTML report
and a compact templates folder for new projects.

## Key Features
1. Project folder setup (`Setup.bat`)
2. Full Vivado batch flow (`autorun.bat` + `scripts/run_full_flow.tcl`)
3. HTML report generation (`scripts/generate_report.tcl`)
4. Optional FPGA programming (`program_device.bat`)
5. Icarus simulation helper (`sim_icarus.bat`) with VCD auto-open
6. IP Integrator GUI launcher (`open_ipi_gui.bat`)
7. Block design finalize (no wrapper auto-create) (`finalize_bd.bat`)

## Directory Layout

Project root:
- `Setup.bat` (creates a new project folder)
- `Read Me.md` (this file)
- `templates/` (copy source for new projects)

Each project folder:
- `src/` Verilog sources (`*.v`)
- `constrs/` XDC constraints (`*.xdc`)
- `scripts/` Vivado Tcl scripts
- `output/` build outputs, logs, reports
- `tb/` testbenches for Icarus
- `build_config.tcl` build settings (part/top/power/BD/project)
- `open_ipi_gui.bat` open Vivado GUI with IP Integrator
- `finalize_bd.bat` finalize block design and export BD/IP artifacts
- `ip/` exported IP files (`*.xci`) for non-project build

## How to Use

### 1) Create a project folder
Run `Setup.bat` and enter a project name. It will create the folder
structure (`src`, `constrs`, `scripts`, `output`, `tb`) and copy template
scripts from `templates`.

### 2) Add sources and constraints
- Put Verilog files in `src/`
- Put XDC files in `constrs/`
The `tb/` folder includes an example `tb_Top.v` template copied from
`templates/`. Update the DUT instantiation to match your top module.

### 3) Configure build settings
Edit `build_config.tcl` and set:
```
set part_number   "xc7a35tcpg236-1"
set top_module    "Top"
set power_limit   2.5
set bd_name       "design_1"
set project_name  "vivado_ipi"
set project_dir   "./vivado_ipi"
```

### 4) (Optional) Open IP Integrator GUI
If you need IP Integrator, run `open_ipi_gui.bat`. This creates/opens the
Vivado project, adds `src/` and `constrs/`, and opens an existing block
design if present (it does not auto-create one).

If you use IP Catalog (no block design), export the generated `.xci` file
to `ip/` so the non-project flow can `read_ip` and `synth_ip`. If the IP was
created for a different part, run `retarget_ip.bat` to rebuild it for the
part in `build_config.tcl` and re-export the `.xci`.

### 5) (Optional) Manual GUI edit
Edit the block design in Vivado GUI.

### 6) (Optional) Finalize BD (no wrapper auto-create)
Run `finalize_bd.bat` after GUI edits. This will:
- validate/save the BD
- generate targets
- export BD HDL into `src/`
- export IP `.xci` files into `ip/`

If you need a wrapper, create it in the Vivado GUI and set the top module
manually (then update `build_config.tcl` to match).

### 7) Run the build
From the project folder, run `autorun.bat`.
It runs synth/impl, generates the bitstream, extracts RTL hierarchy,
and creates the HTML report.

### 8) Check results
Open `output/Final_Build_Report.html`.

## Icarus Simulation (VCD Auto-Open)

1. Put a testbench in `tb/` (add your own testbench file).
2. Run `sim_icarus.bat` from the project folder. If you have multiple
   testbenches, pass one explicitly (example: `sim_icarus.bat tb_top.v`).
   With no argument, it compiles `tb/*_tb.v` or `tb/tb_*.v`.
   The example `tb_Top.v` also honors `+vcd=output/wave.vcd`.
3. The script compiles with Icarus, runs the sim, and opens the newest
   `output/*.vcd` using the default program associated with `.vcd`.
4. The BRAM wrapper uses a behavioral RAM model when `IVERILOG` is defined.

If your testbench supports it, the script passes:
```
+vcd=output/wave.vcd
```
so VCD output lands in the `output/` directory.

## Notes
- Make sure `vivado` is in PATH before running `autorun.bat`.
- Make sure `iverilog` and `vvp` are in PATH before running `sim_icarus.bat`.
