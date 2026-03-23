# FPGA Auto Project Agent Guide

This file defines the default working contract for Codex agents operating anywhere in this repository.

## Repo shape

- Treat this repo as two connected layers:
  - automation framework: `MAIN.bat`, `templates/contexts/*`, `templates/shared/*`, `Telegram/*`, `tests/*`
  - managed workspaces: `Project/*/src`, `Project/*/tb`, `Project/*/fpga_auto.yml`, plus project-local outputs
- `MAIN.bat` is the top-level menu contract.
- Valid projects are discovered only from `Project/*` directories that contain both `src/` and `fpga_auto.yml`.
- The runtime is Windows-first. WSL is fine for inspection, grep, patching, and many tests, but batch/Vivado flows should be treated as Windows-oriented.

## Required reading order

- For project-local HDL work, read `Project/<name>/fpga_auto.yml` before changing source, testbench, include, or constraint files.
- Read files in this order when possible:
  1. manifest and top-level contract files
  2. directly affected source or testbench files
  3. related package/include/helper files
  4. the BAT/PowerShell/Python/TCL entrypoint that builds or simulates them
  5. tests and generated summaries only as supporting evidence

## HDL routing

- `src/**/*.sv`: synthesizable SystemVerilog RTL
- `tb/**/*.sv` and `tb/**/*.svh`: SystemVerilog testbench or verification code
- `src/**/*.v` and `tb/**/*.v`: plain Verilog

## Naming and style rules

- Apply `.agents/rules/verilog-naming-rules.md` for Verilog work.
- Apply `.agents/rules/systemverilog-naming-rules.md` for synthesizable SystemVerilog RTL under `src/`.
- Apply `.agents/rules/systemverilog-tb-naming-rules.md` for SystemVerilog testbench code under `tb/`.
- Keep RTL and TB conventions separate. Do not move TB-only constructs into synthesizable source.

## Automation guidance

- For menu or routing changes, inspect `MAIN.bat` first.
- For project bootstrap or discovery changes, inspect `templates/contexts/project_bootstrap/` and manifest handling before editing.
- For simulation/reporting/Vivado changes, follow the execution chain from the relevant BAT adapter into helper scripts.
- Telegram behavior often mirrors menu behavior. Check `Telegram/telegram_fpga_bot.py` and `tests/telegram_bot/` when changing commands or project selection behavior.

## Safe editing

- Prefer surgical changes. Do not rewrite generated assets or large artifacts unless the task explicitly requires it.
- Treat files such as `*.vcd`, `*.wdb`, `xsim.*`, and generated HTML/report outputs as artifacts, not primary source.
- The worktree may already contain unrelated edits. Do not revert them unless explicitly asked.

## Validation

- Prefer targeted verification over full-repo sweeps.
- Use existing tests under `tests/` when they cover the changed behavior.
- When touching HDL flow logic, validate the nearest manifest, script entrypoint, and any affected parser or Telegram tests before broadening scope.

## Useful skills if available

- `fpga-auto-hdl-workspace` for repo navigation and bounded-context routing
- `verilog-rtl-style` for Verilog RTL edits and reviews
- `systemverilog-rtl-style` for synthesizable SystemVerilog under `src/`
- `systemverilog-tb-style` for verification code under `tb/`
