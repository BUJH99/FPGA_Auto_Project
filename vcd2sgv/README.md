# vcd2sgv

Fresh workspace for VCD conversion tools (independent from `vcd2svg.txt`).

## Files

- `vcd_parser.py`: reusable VCD header/event parser.
- `vcd2svg.py`: VCD -> SVG waveform image.
- `vcd2wavedrom.py`: VCD -> WaveDrom JSON (+ optional HTML viewer).
- `vcd2wavedrom_interactive.py`: interactive VCD->WaveDrom helper (VCD select, signals, range, step).
- `vcd2wavedrom_from_profile.py`: generate WaveDrom from `<project>/vcd/svg_profiles/*.txt`.
- `vcd2svg_interactive.py`: interactive VCD/SVG selection helper (file, signals, time range).
- `run_vcd2svg.bat`: Windows wrapper for `vcd2svg.py`.
- `run_vcd2wavedrom.bat`: Windows wrapper for `vcd2wavedrom.py`.
- `run_vcd2wavedrom_from_profile.bat`: Windows wrapper for profile-based WaveDrom generation.

## Quick Start (Windows)

List signals:

```bat
python vcd2sgv\vcd2svg.py Sensor_Uart\output\iverilog\vcd\tb_dht11_controller.vcd out.svg --list-signals
```

Generate SVG:

```bat
python vcd2sgv\vcd2svg.py ^
  Sensor_Uart\output\iverilog\vcd\tb_dht11_controller.vcd ^
  Sensor_Uart\vcd\svg\two_only\tb_dht11_controller_new.svg ^
  --signals tb_dht11_controller.iRst,tb_dht11_controller.iStart,tb_dht11_controller.iTickUs,tb_dht11_controller.rDhtDriveLow,tb_dht11_controller.ioData,tb_dht11_controller.oHumInt,tb_dht11_controller.oTempInt,tb_dht11_controller.oDataValid ^
  --from-time 0 --to-time 4865950000
```

Generate WaveDrom JSON + HTML:

```bat
python vcd2sgv\vcd2wavedrom.py ^
  Sensor_Uart\output\iverilog\vcd\tb_dht11_controller.vcd ^
  Sensor_Uart\vcd\wavedrom\tb_dht11_controller_new.json ^
  --signals tb_dht11_controller.iRst,tb_dht11_controller.iStart,tb_dht11_controller.ioData,tb_dht11_controller.oDataValid,tb_dht11_controller.oHumInt,tb_dht11_controller.oTempInt ^
  --from-time 0 --to-time 4865950000 --step 20000000 ^
  --html Sensor_Uart\vcd\wavedrom\tb_dht11_controller_new.html
```

Generate WaveDrom from SVG profile TXT:

```bat
python vcd2sgv\vcd2wavedrom_from_profile.py ^
  Sensor_Uart ^
  --profiles tb_control_unit,tb_button_sync ^
  --step 20000 --html
```

Profile mode prompt:
- Each selected profile asks once: `Yes / Edit / Skip / Quit`
- Use `--yes` to skip confirmation prompts (batch mode)

## Notes

- Time values are raw VCD ticks.
- If `--signals` is omitted, first `--max-signals` (default 10) are used.
- For very large VCDs, always set `--to-time` (and optionally `--step`) to reduce load.
- In profile-based mode, `time_range`/signals are read from `svg_profiles/*.txt`.
- `--step` in profile-based mode overrides `wavedrom_step` in profile.

## Interactive SVG Mode (MAIN menu #9)

`templates/bat/sim_vcd_svg_run.bat` now launches `vcd2svg_interactive.py`.

- VCD multi-selection from `<project>/vcd` (e.g. `1 3`, `2-4`, `A`)
- Per-VCD configuration flow (processed in selected order)
- TB-top signal include selection (index/name/range)
- DUT/internal signal include selection (index/name/range)
- Signal exclude selection (index/name/range)
- Bus radix selection:
  - default radix (`hex`/`dec`/`bin`)
  - optional per-signal override after selection
- Time range input (`start:end`) and optional zoom
- Custom output SVG path
- Per-VCD profile save/reuse: `<project>/vcd/svg_profiles/<vcd_name>.txt`

## Interactive WaveDrom Mode (MAIN menu #22)

`templates/bat/sim_vcd_wavedrom_run.bat` launches `vcd2wavedrom_interactive.py`.

- VCD multi-selection from `<project>/vcd` (e.g. `1 3`, `2-4`, `A`)
- Per-VCD configuration flow (processed in selected order)
- If profile TXT exists, asks once:
  - `Load saved TXT profile? [Y]es/[E]dit/[N]ew/[Q]cancel`
- TB-top signal include selection (index/name/range)
- DUT/internal signal include selection (index/name/range)
- Signal exclude selection (index/name/range)
- Time range input (`start:end`)
- Step input (`sample ticks`)
- Optional HTML generation toggle
- Custom output JSON/HTML paths

## Optional: WaveDrom From SVG Profile TXT

Use this when you want strict reuse of existing `svg_profiles/*.txt`:
- Script: `vcd2wavedrom_from_profile.py`
- Wrapper: `run_vcd2wavedrom_from_profile.bat`
