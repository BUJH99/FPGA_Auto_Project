# SystemVerilog Support Matrix (Draft)

This document tracks support status for Verilog/SystemVerilog workflows in the FPGA automation toolkit.

## Scope
- Toolchain priority: `Vivado + Icarus Verilog`
- Supported source extensions: `.v`, `.sv`
- Supported include/header extension: `.svh` (header/include only, not top selection target)

## Workflow Matrix

| Workflow | Verilog (.v) | SystemVerilog (.sv) | Header (.svh) | Notes |
|---|---:|---:|---:|---|
| `sim_iverilog_vcd_run.bat` | PASS | PASS (planned/implemented) | INCLUDE PATH | Uses `iverilog -g2012` |
| `sim_vivado_run.bat` | PASS | PASS | INCLUDE DIRS | Vivado GUI launch path |
| `sim_report_auto_run.bat` | PASS | PASS (planned/implemented) | INCLUDE DIRS | `parse_tb.js` + `generate_report.js` |
| `report_markdown_generate.bat` | PASS | PASS | INFO ONLY | Source/TB module scanning |
| `code_verilog_hierarchy_*` | PASS | PASS (planned/implemented) | INDEXED | Package/interface shown separately |
| `code_fsm_draw.bat` | PASS | PASS (planned/implemented) | N/A | SV enum state extraction preferred |
| `code_schematic_draw.bat` | PASS | PASS (planned/implemented) | INCLUDE DIRS | Yosys `read_verilog -sv` |
| `code_presentation_generate.bat` | PASS | PASS | INDEXED | Python parser path |

## Regression Scenarios
- `TC01`: Pure Verilog regression
- `TC02`: Mixed `.v + .sv` core flow
- `TC03`: SV FSM (`typedef enum logic`, `always_ff`, `always_comb`)
- `TC04`: `package` + `import`
- `TC05`: `interface` + `modport`
- `TC06`: `.svh` include + macros
- `TC07`: Syntax error reporting quality
- `TC08`: Generator UX (`--hdl-ext`, `--tb-ext`)

## Current Limits (to refine)
- `.svh` files are include/header files only and should not be selected as simulation top.
- AST-backed parsing depends on optional Node dependencies in `templates/package.json`.
- If AST parser is unavailable, tools may fall back to heuristic parsing and emit warnings.
- Advanced SystemVerilog testbench features (`class`, `mailbox`, constrained random, some interface patterns) may fail on Icarus Verilog even when toolkit path selection/parsing works. Prefer Vivado/xsim for those TBs.
- On Windows, `tree-sitter-verilog` install may require Visual Studio Build Tools (C++ workload) because it builds native modules via `node-gyp`.
