#!/usr/bin/env python3
"""
Convert VCD to WaveDrom JSON (and optional HTML viewer).
"""

from __future__ import annotations

import argparse
import json
import os
from typing import Dict, List, Sequence, Tuple

from vcd_parser import find_last_timestamp, format_value, parse_events, parse_header, resolve_signals


def _sample_wave(
    events: Sequence[Tuple[int, str]],
    width: int,
    start_t: int,
    end_t: int,
    step: int,
) -> Tuple[str, List[str]]:
    if step <= 0:
        step = 1
    if end_t <= start_t:
        end_t = start_t + 1

    idx = 0
    cur = "x"
    n = len(events)
    while idx < n and events[idx][0] <= start_t:
        cur = events[idx][1]
        idx += 1

    wave_chars: List[str] = []
    data_items: List[str] = []
    last_symbol = ""
    last_bus_data = ""

    t = start_t
    while t <= end_t:
        while idx < n and events[idx][0] <= t:
            cur = events[idx][1]
            idx += 1

        symbol = "x"
        data_token = ""

        if width <= 1:
            v = cur.lower()
            if v in ("0", "1", "x", "z"):
                symbol = v
            elif v.startswith("b") and len(v) > 1:
                bit = v[-1]
                symbol = bit if bit in ("0", "1", "x", "z") else "x"
            else:
                symbol = "x"
        else:
            v = cur.lower()
            if v.startswith("b"):
                bits = v[1:]
                if "x" in bits:
                    symbol = "x"
                elif "z" in bits:
                    symbol = "z"
                else:
                    symbol = "="
                    data_token = format_value(v, width, fmt="hex")
            else:
                if v in ("x", "z"):
                    symbol = v
                else:
                    symbol = "x"

        emit = symbol
        if not wave_chars:
            emit = symbol
        elif symbol == "=":
            if last_symbol == "=" and data_token == last_bus_data:
                emit = "."
            else:
                emit = "="
        elif symbol == last_symbol:
            emit = "."
        else:
            emit = symbol

        wave_chars.append(emit)

        if emit == "=":
            data_items.append(data_token)
            last_bus_data = data_token

        if emit != ".":
            last_symbol = symbol

        t += step

    return "".join(wave_chars), data_items


def _make_html(json_path: str, html_path: str) -> None:
    html = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>WaveDrom Viewer</title>
  <script src="https://cdnjs.cloudflare.com/ajax/libs/wavedrom/3.5.0/skins/default.js"></script>
  <script src="https://cdnjs.cloudflare.com/ajax/libs/wavedrom/3.5.0/wavedrom.min.js"></script>
  <style>
    body {{ font-family: Consolas, monospace; margin: 24px; background: #f8fafc; color: #111827; }}
    h1 {{ font-size: 18px; margin: 0 0 12px 0; }}
    #wave {{ border: 1px solid #d1d5db; background: #fff; padding: 12px; overflow-x: auto; }}
  </style>
</head>
<body>
  <h1>WaveDrom: {json_path}</h1>
  <script type="WaveDrom" id="wave"></script>
  <script>
    fetch("{json_path}")
      .then(r => r.json())
      .then(obj => {{
        const n = document.getElementById("wave");
        n.textContent = JSON.stringify(obj);
        WaveDrom.ProcessAll();
      }})
      .catch(err => {{
        const n = document.getElementById("wave");
        n.textContent = "Failed to load JSON: " + err;
      }});
  </script>
</body>
</html>
"""
    with open(html_path, "w", encoding="utf-8") as f:
        f.write(html)


def main() -> int:
    ap = argparse.ArgumentParser(description="Convert VCD to WaveDrom JSON")
    ap.add_argument("input_vcd", help="Input VCD path")
    ap.add_argument("output_json", help="Output WaveDrom JSON path")
    ap.add_argument(
        "--signals",
        default="",
        help="Comma separated signal names. Full scope names recommended.",
    )
    ap.add_argument("--from-time", type=int, default=0, help="Start time (VCD ticks)")
    ap.add_argument("--to-time", type=int, default=-1, help="End time (VCD ticks)")
    ap.add_argument("--step", type=int, default=0, help="Sample step (VCD ticks)")
    ap.add_argument("--max-signals", type=int, default=10, help="Used when --signals is not set")
    ap.add_argument("--title", default="", help="WaveDrom head text")
    ap.add_argument("--html", default="", help="Optional output HTML path")
    ap.add_argument("--list-signals", action="store_true", help="Print available signals and exit")
    args = ap.parse_args()

    header = parse_header(args.input_vcd)
    if args.list_signals:
        for sig in header.signals:
            print(sig.full_name)
        return 0

    requested = [s.strip() for s in args.signals.split(",") if s.strip()]
    if requested:
        selected, errors = resolve_signals(header.signals, requested)
        if errors:
            for e in errors:
                print(f"[ERROR] {e}")
            return 1
    else:
        selected = header.signals[: max(1, args.max_signals)]

    if not selected:
        print("[ERROR] No signals selected")
        return 1

    start_t = max(0, args.from_time)
    end_t = args.to_time if args.to_time >= 0 else find_last_timestamp(args.input_vcd)
    if end_t <= start_t:
        end_t = start_t + 1

    span = max(1, end_t - start_t)
    step = args.step if args.step > 0 else max(1, span // 120)

    tracked_ids = [s.id_code for s in selected]
    events_by_id = parse_events(
        args.input_vcd,
        tracked_ids=tracked_ids,
        start_time=start_t,
        end_time=end_t,
    )

    signal_entries: List[Dict[str, object]] = []
    for sig in selected:
        wave, data = _sample_wave(
            events_by_id.get(sig.id_code, []),
            sig.width,
            start_t,
            end_t,
            step,
        )
        entry: Dict[str, object] = {"name": sig.full_name, "wave": wave}
        if data:
            entry["data"] = data
        signal_entries.append(entry)

    title = args.title or f"{start_t}..{end_t} (step={step})"
    payload = {
        "signal": signal_entries,
        "head": {"text": title},
        "config": {"hscale": 1},
    }

    out_dir = os.path.dirname(os.path.abspath(args.output_json))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(args.output_json, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)

    if args.html:
        html_dir = os.path.dirname(os.path.abspath(args.html))
        if html_dir:
            os.makedirs(html_dir, exist_ok=True)
        _make_html(args.output_json, args.html)
        print(f"[OK] HTML generated: {args.html}")

    print(f"[OK] WaveDrom JSON generated: {args.output_json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
