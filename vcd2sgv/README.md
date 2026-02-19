# vcd2sgv

Fresh workspace for VCD conversion tools (independent from `vcd2svg.txt`).

## Files

- `vcd_parser.py`: reusable VCD header/event parser.
- `vcd2svg.py`: VCD -> SVG waveform image.
- `vcd2wavedrom.py`: VCD -> WaveDrom JSON (+ optional HTML viewer).
- `vcd2svg_interactive.py`: interactive VCD/SVG selection helper (file, signals, time range).
- `run_vcd2svg.bat`: Windows wrapper for `vcd2svg.py`.
- `run_vcd2wavedrom.bat`: Windows wrapper for `vcd2wavedrom.py`.

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

## Notes

- Time values are raw VCD ticks.
- If `--signals` is omitted, first `--max-signals` (default 10) are used.
- For very large VCDs, always set `--to-time` (and optionally `--step`) to reduce load.

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
