# VCD2SVG Manual

## 1. Scope
- Target: `vcd2sgv/vcd2svg.py`, `vcd2sgv/vcd2svg_interactive.py`
- Goal: Generate waveform SVG from VCD quickly through `MAIN.bat` menu or direct CLI.

## 2. Prerequisites
- `python` in `PATH`
- For VCD generation from TB: `iverilog`, `vvp` in `PATH`
- Project layout:
  - `<project>/src`
  - `<project>/tb`
  - `<project>/vcd` (created automatically by sim script if missing)

## 3. Recommended Flow (MAIN Menu)
1. Run `MAIN.bat`.
2. Select your project.
3. Run menu `8. Run Iverilog VCD (Select TB)`.
4. Select one or more TBs to generate `.vcd` files under `<project>/vcd`.
5. Run menu `9. Generate SVG from VCD (Select)`.
6. Select one or more VCD files (example: `1 3`).
7. For each selected VCD, configure signals/time/output in sequence.

## 4. What Menu #9 Asks
- VCD file selection:
  - Picks one or more `.vcd` from `<project>/vcd`
  - Index list/range supported (`1 3`, `2-5`)
  - `A`/`all` supported
- Per selected VCD:
  - Signal groups are shown separately:
    - TB-top signals (`tb_xxx.signal`)
    - DUT/internal signals (`tb_xxx.u_dut.signal`, deeper hierarchy)
- TB-top include:
  - Blank: first 10 TB-top signals
  - `all` or `*`: all TB-top signals
  - Index/name/range allowed
- DUT/internal include:
  - Blank: none
  - `all` or `*`: all DUT/internal signals
  - Index/name/range allowed
- Exclude signals (final filtering):
  - Optional, same format as include
- Bus radix:
  - Default bus radix input: `hex` / `dec` / `bin`
  - Then optional per-signal override prompt:
    - `Change radix for specific bus signals now? (y/N)`
    - Choose signal by index/name/range, then set radix
- Time range:
  - Format: `start:end`
  - Example: `0:5000000`
  - `end` must be greater than `start`
- Zoom:
  - Optional (`px/tick`)
  - Blank = auto
- Output path:
  - Blank default: `<project>/vcd/svg/<vcd_name>_custom.svg`

## 5. TB Profile TXT (Auto Save / Reuse)
- Profile path:
  - `<project>/vcd/svg_profiles/<vcd_name>.txt`
- On next run, if profile exists:
  - `U`: use profile defaults
  - `E`: open profile in Notepad, then continue
  - `N`: ignore and start new config
- Profile keys:
  - `include_tb=...`
  - `include_dut=...`
  - `exclude=...`
  - `time_range=start:end`
  - `zoom=...`
  - `output=...` (relative path allowed)
  - `radix_default=hex|dec|bin`
  - `radix_overrides=signal_name:radix,...`

## 6. Direct CLI Usage

### 6.1 List signals in VCD
```bat
python vcd2sgv\vcd2svg.py Sensor_Uart\vcd\tb_sr04_controller.vcd out.svg --list-signals
```

### 6.2 Generate SVG (explicit signals)
```bat
python vcd2sgv\vcd2svg.py ^
  Sensor_Uart\vcd\tb_sr04_controller.vcd ^
  Sensor_Uart\vcd\svg\tb_sr04_controller_manual.svg ^
  --signals tb_sr04_controller.iClk,tb_sr04_controller.iRst,tb_sr04_controller.oTrig ^
  --from-time 0 --to-time 5000000
```

### 6.3 Main options (`vcd2svg.py`)
- `--signals`: comma-separated signal names
- `--from-time`: start tick
- `--to-time`: end tick (`-1` means auto last timestamp)
- `--zoom`: pixels per tick (auto if omitted)
- `--max-signals`: used when `--signals` is omitted (default `10`)
- `--radix`: default bus radix (`hex`/`dec`/`bin`)
- `--list-signals`: print available signals and exit

## 7. Batch Scripts (Direct)

### 7.1 Generate VCD from TB
File: `templates/bat/sim_iverilog_vcd_run.bat`

```bat
templates\bat\sim_iverilog_vcd_run.bat Sensor_Uart --tb tb_sr04_controller --no-pause
```

Key options:
- `--tb <name|path>`: run only one TB
- `--all`: run all `tb_*.v`
- `--no-pause`: no pause on finish

### 7.2 Run interactive VCD->SVG directly
File: `templates/bat/sim_vcd_svg_run.bat`

```bat
templates\bat\sim_vcd_svg_run.bat Sensor_Uart --no-pause
```

## 8. Troubleshooting
- `[ERROR] python not found in PATH`:
  - Install Python and reopen terminal.
- `[ERROR] iverilog not found in PATH` or `vvp not found`:
  - Install Icarus Verilog and add to `PATH`.
- `[ERROR] VCD folder not found`:
  - Run menu `8` first, or create `<project>/vcd`.
- `Signal not found` or `Ambiguous signal`:
  - Use full scope name from `--list-signals` output.
- Profile mismatch after RTL/TB hierarchy changed:
  - Choose `N` (new config), or choose `E` and update names in profile text.
- SVG too large/heavy:
  - Reduce signals.
  - Narrow `--from-time` / `--to-time`.
  - Use selective include/exclude instead of `all`.

## 9. Code Reference
- Menu entry: `MAIN.bat`
- VCD generation script: `templates/bat/sim_iverilog_vcd_run.bat`
- Interactive SVG script: `templates/bat/sim_vcd_svg_run.bat`
- Interactive Python tool: `vcd2sgv/vcd2svg_interactive.py`
- Core converter: `vcd2sgv/vcd2svg.py`
- Parser utilities: `vcd2sgv/vcd_parser.py`
