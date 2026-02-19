#!/usr/bin/env python3
"""
Convert VCD to a compact SVG waveform image.
"""

from __future__ import annotations

import argparse
from html import escape
import os
from typing import Dict, List, Tuple

from vcd_parser import (
    build_segments,
    find_last_timestamp,
    format_value,
    parse_events,
    parse_header,
    resolve_signals,
)


def _time_grid(start_t: int, end_t: int, count: int = 8) -> List[int]:
    if end_t <= start_t:
        return [start_t]
    count = max(2, count)
    step = max(1, int((end_t - start_t) / (count - 1)))
    out = []
    t = start_t
    while t < end_t:
        out.append(t)
        t += step
    out.append(end_t)
    return sorted(set(out))


def _y_for_bit(value: str, y_top: float, row_h: float) -> float:
    v = value.lower()
    if v == "1":
        return y_top + row_h * 0.20
    if v == "0":
        return y_top + row_h * 0.80
    return y_top + row_h * 0.50


def make_svg(
    signal_rows: List[Tuple[str, int, List[Tuple[int, int, str]]]],
    start_t: int,
    end_t: int,
    scale: float,
    output_path: str,
    value_formats: Dict[str, str] | None = None,
    default_bus_fmt: str = "hex",
) -> None:
    out_dir = os.path.dirname(os.path.abspath(output_path))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    fmt_map = value_formats or {}
    default_bus_fmt = default_bus_fmt.lower()
    if default_bus_fmt not in ("hex", "dec", "bin"):
        default_bus_fmt = "hex"

    label_w = 280.0
    pad = 16.0
    row_h = 28.0
    row_gap = 8.0
    grid_h = 24.0

    width = pad * 2 + label_w + max(1.0, (end_t - start_t) * scale)
    height = pad * 2 + grid_h + len(signal_rows) * (row_h + row_gap) + 8.0

    def x_of(t: int) -> float:
        return pad + label_w + (t - start_t) * scale

    lines: List[str] = []
    lines.append('<?xml version="1.0" encoding="UTF-8"?>')
    lines.append(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{int(width)}" height="{int(height)}">'
    )
    lines.append('<rect x="0" y="0" width="100%" height="100%" fill="#ffffff"/>')

    # Time grid
    grid_times = _time_grid(start_t, end_t, count=9)
    for t in grid_times:
        x = x_of(t)
        lines.append(
            f'<line x1="{x:.2f}" y1="{pad:.2f}" x2="{x:.2f}" y2="{height - pad:.2f}" '
            f'stroke="#eeeeee" stroke-width="1"/>'
        )
        lines.append(
            f'<text x="{x:.2f}" y="{pad + 12:.2f}" font-size="10" text-anchor="middle" '
            f'fill="#666">{t}</text>'
        )

    # Signal rows
    for idx, (sig_name, width_bits, segments) in enumerate(signal_rows):
        y_top = pad + grid_h + idx * (row_h + row_gap)
        y_mid = y_top + row_h * 0.5

        lines.append(
            f'<text x="{pad + label_w - 8:.2f}" y="{y_mid + 4:.2f}" font-size="12" '
            f'font-family="Consolas, monospace" text-anchor="end" fill="#111">{escape(sig_name)}</text>'
        )

        lines.append(
            f'<line x1="{pad + label_w:.2f}" y1="{y_mid:.2f}" x2="{width - pad:.2f}" y2="{y_mid:.2f}" '
            f'stroke="#f3f3f3" stroke-width="1"/>'
        )

        if width_bits <= 1:
            prev_y = None
            for t0, t1, value in segments:
                x0 = x_of(t0)
                x1 = x_of(t1)
                y = _y_for_bit(value, y_top, row_h)
                dash = ' stroke-dasharray="4 2"' if value in ("x", "z") else ""

                if prev_y is not None and abs(prev_y - y) > 0.1:
                    lines.append(
                        f'<line x1="{x0:.2f}" y1="{prev_y:.2f}" x2="{x0:.2f}" y2="{y:.2f}" '
                        f'stroke="#1f2937" stroke-width="1.2"{dash}/>'
                    )
                lines.append(
                    f'<line x1="{x0:.2f}" y1="{y:.2f}" x2="{x1:.2f}" y2="{y:.2f}" '
                    f'stroke="#1f2937" stroke-width="1.6"{dash}/>'
                )
                prev_y = y
        else:
            for t0, t1, value in segments:
                x0 = x_of(t0)
                x1 = max(x0 + 1.0, x_of(t1))
                w = x1 - x0
                fmt = fmt_map.get(sig_name, default_bus_fmt).lower()
                if fmt not in ("hex", "dec", "bin"):
                    fmt = default_bus_fmt
                txt = format_value(value, width_bits, fmt=fmt)
                lines.append(
                    f'<rect x="{x0:.2f}" y="{y_top + 6:.2f}" width="{w:.2f}" height="{row_h - 12:.2f}" '
                    f'fill="none" stroke="#1f2937" stroke-width="1"/>'
                )
                if w >= 24:
                    lines.append(
                        f'<text x="{x0 + w / 2:.2f}" y="{y_mid + 4:.2f}" font-size="11" '
                        f'font-family="Consolas, monospace" text-anchor="middle" fill="#1f2937">{escape(txt)}</text>'
                    )

    lines.append("</svg>")

    with open(output_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser(description="Convert VCD to SVG waveform")
    ap.add_argument("input_vcd", help="Input VCD path")
    ap.add_argument("output_svg", help="Output SVG path")
    ap.add_argument(
        "--signals",
        default="",
        help="Comma separated signal names. Full scope names recommended.",
    )
    ap.add_argument("--from-time", type=int, default=0, help="Start time (VCD ticks)")
    ap.add_argument("--to-time", type=int, default=-1, help="End time (VCD ticks)")
    ap.add_argument("--zoom", type=float, default=0.0, help="Pixels per VCD tick")
    ap.add_argument("--max-signals", type=int, default=10, help="Used when --signals is not set")
    ap.add_argument(
        "--radix",
        choices=["hex", "dec", "bin"],
        default="hex",
        help="Default bus value format for multi-bit signals",
    )
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
    if args.to_time >= 0:
        end_t = args.to_time
    else:
        end_t = find_last_timestamp(args.input_vcd)
    if end_t <= start_t:
        end_t = start_t + 1

    tracked_ids = [s.id_code for s in selected]
    events_by_id = parse_events(
        args.input_vcd,
        tracked_ids=tracked_ids,
        start_time=start_t,
        end_time=end_t,
    )

    span = max(1, end_t - start_t)
    scale = args.zoom if args.zoom > 0 else max(1e-6, 1800.0 / span)

    rows: List[Tuple[str, int, List[Tuple[int, int, str]]]] = []
    for sig in selected:
        segs = build_segments(events_by_id.get(sig.id_code, []), start_t, end_t, default="x")
        rows.append((sig.full_name, sig.width, segs))

    make_svg(rows, start_t, end_t, scale, args.output_svg, default_bus_fmt=args.radix)
    print(f"[OK] SVG generated: {args.output_svg}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
