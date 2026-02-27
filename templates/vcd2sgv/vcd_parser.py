#!/usr/bin/env python3
"""
Lightweight VCD parsing helpers used by vcd2svg.py and vcd2wavedrom.py.
"""

from __future__ import annotations

from dataclasses import dataclass
import math
import re
from typing import Dict, Iterable, List, Optional, Sequence, Tuple


@dataclass
class SignalDef:
    full_name: str
    leaf_name: str
    id_code: str
    width: int


@dataclass
class VcdHeader:
    timescale_ps: float
    signals: List[SignalDef]


_TIMESCALE_UNIT_PS = {
    "s": 1e12,
    "ms": 1e9,
    "us": 1e6,
    "ns": 1e3,
    "ps": 1.0,
    "fs": 1e-3,
}


def _parse_timescale_value(raw: str) -> float:
    # Supports "1ps", "10 ns", etc.
    cleaned = raw.strip().replace("$timescale", "").replace("$end", "").strip()
    m = re.match(r"^(\d+(?:\.\d+)?)\s*([a-zA-Z]+)$", cleaned)
    if not m:
        return 1.0
    value = float(m.group(1))
    unit = m.group(2).lower()
    return value * _TIMESCALE_UNIT_PS.get(unit, 1.0)


def parse_header(vcd_path: str) -> VcdHeader:
    timescale_ps = 1.0
    signals: List[SignalDef] = []
    scopes: List[str] = []

    timescale_collect = False
    timescale_tokens: List[str] = []

    with open(vcd_path, "r", encoding="utf-8", errors="ignore") as f:
        for raw_line in f:
            line = raw_line.strip()
            if not line:
                continue

            if timescale_collect:
                if "$end" in line:
                    timescale_tokens.append(line.replace("$end", "").strip())
                    timescale_ps = _parse_timescale_value(" ".join(timescale_tokens))
                    timescale_collect = False
                    timescale_tokens = []
                else:
                    timescale_tokens.append(line)
                continue

            if line.startswith("$timescale"):
                if "$end" in line:
                    timescale_ps = _parse_timescale_value(line)
                else:
                    timescale_collect = True
                    rem = line.replace("$timescale", "").strip()
                    if rem:
                        timescale_tokens.append(rem)
                continue

            if line.startswith("$scope"):
                parts = line.split()
                if len(parts) >= 3:
                    scopes.append(parts[2])
                continue

            if line.startswith("$upscope"):
                if scopes:
                    scopes.pop()
                continue

            if line.startswith("$var"):
                parts = line.split()
                if len(parts) >= 5:
                    try:
                        width = int(parts[2])
                    except ValueError:
                        width = 1
                    id_code = parts[3]
                    leaf = parts[4]
                    full = ".".join(scopes + [leaf]) if scopes else leaf
                    signals.append(
                        SignalDef(
                            full_name=full,
                            leaf_name=leaf,
                            id_code=id_code,
                            width=width,
                        )
                    )
                continue

            if line.startswith("$enddefinitions"):
                break

    return VcdHeader(timescale_ps=timescale_ps, signals=signals)


def build_signal_maps(
    signals: Sequence[SignalDef],
) -> Tuple[Dict[str, SignalDef], Dict[str, List[SignalDef]]]:
    full_map: Dict[str, SignalDef] = {}
    leaf_map: Dict[str, List[SignalDef]] = {}
    for sig in signals:
        full_map[sig.full_name] = sig
        leaf_map.setdefault(sig.leaf_name, []).append(sig)
    return full_map, leaf_map


def resolve_signals(
    signals: Sequence[SignalDef],
    requested: Sequence[str],
) -> Tuple[List[SignalDef], List[str]]:
    full_map, leaf_map = build_signal_maps(signals)
    resolved: List[SignalDef] = []
    errors: List[str] = []

    for name in requested:
        key = name.strip()
        if not key:
            continue
        if key in full_map:
            resolved.append(full_map[key])
            continue
        leaf_hits = leaf_map.get(key, [])
        if len(leaf_hits) == 1:
            resolved.append(leaf_hits[0])
        elif len(leaf_hits) > 1:
            errors.append(f"Ambiguous signal '{key}' (use full scope name)")
        else:
            errors.append(f"Signal not found: '{key}'")
    return resolved, errors


def _append_event(events: List[Tuple[int, str]], t: int, value: str) -> None:
    if events and events[-1][0] == t:
        events[-1] = (t, value)
        return
    if events and events[-1][1] == value:
        return
    events.append((t, value))


def parse_events(
    vcd_path: str,
    tracked_ids: Iterable[str],
    start_time: int = 0,
    end_time: Optional[int] = None,
) -> Dict[str, List[Tuple[int, str]]]:
    tracked = set(tracked_ids)
    out: Dict[str, List[Tuple[int, str]]] = {sid: [] for sid in tracked}
    if not tracked:
        return out

    in_header = True
    current_time = 0

    with open(vcd_path, "r", encoding="utf-8", errors="ignore") as f:
        for raw_line in f:
            line = raw_line.strip()
            if not line:
                continue

            if in_header:
                if line.startswith("$enddefinitions"):
                    in_header = False
                continue

            if line.startswith("$"):
                continue

            if line.startswith("#"):
                try:
                    current_time = int(line[1:])
                except ValueError:
                    continue
                if end_time is not None and current_time > end_time:
                    break
                continue

            target_time = start_time if current_time < start_time else current_time
            lead = line[0]

            if lead in "01xXzZ":
                sig_id = line[1:]
                if sig_id in tracked:
                    _append_event(out[sig_id], target_time, lead.lower())
                continue

            if lead in "bB":
                parts = line.split()
                if len(parts) < 2:
                    continue
                sig_id = parts[1]
                if sig_id in tracked:
                    bits = parts[0][1:].lower()
                    _append_event(out[sig_id], target_time, "b" + bits)
                continue

    return out


def find_last_timestamp(vcd_path: str) -> int:
    last = 0
    with open(vcd_path, "r", encoding="utf-8", errors="ignore") as f:
        for raw_line in f:
            if raw_line.startswith("#"):
                try:
                    last = int(raw_line[1:].strip())
                except ValueError:
                    pass
    return last


def format_value(value: str, width: int, fmt: str = "hex") -> str:
    v = value.lower()
    if width <= 1 and not v.startswith("b"):
        return v

    bits = v[1:] if v.startswith("b") else v
    if any(ch in bits for ch in ("x", "z")):
        return bits

    if not bits:
        return "0"

    n = int(bits, 2)
    if fmt == "bin":
        return bits
    if fmt == "dec":
        return str(n)

    digits = max(1, int(math.ceil(max(width, len(bits)) / 4.0)))
    return f"{n:0{digits}X}"


def build_segments(
    events: Sequence[Tuple[int, str]],
    start_time: int,
    end_time: int,
    default: str = "x",
) -> List[Tuple[int, int, str]]:
    if end_time <= start_time:
        end_time = start_time + 1

    cursor = start_time
    cur_value = default
    segments: List[Tuple[int, int, str]] = []

    for t, value in events:
        if t < start_time:
            cur_value = value
            continue
        if t > end_time:
            break
        if t > cursor:
            segments.append((cursor, t, cur_value))
        cur_value = value
        cursor = t

    if cursor < end_time:
        segments.append((cursor, end_time, cur_value))

    if not segments:
        segments.append((start_time, end_time, cur_value))

    return segments
