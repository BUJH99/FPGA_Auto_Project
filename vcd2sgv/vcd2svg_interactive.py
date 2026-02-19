#!/usr/bin/env python3
"""
Interactive VCD -> SVG helper.

Features:
- Pick one or more VCD files from <project>/vcd
- Configure each selected TB (VCD) in sequence
- Split signal selection into TB-top and DUT-internal groups
- Save and reuse per-TB TXT profiles (editable by user)
"""

from __future__ import annotations

import os
import re
import sys
from typing import Dict, List, Optional, Tuple

from vcd_parser import build_segments, find_last_timestamp, parse_events, parse_header, resolve_signals
from vcd2svg import make_svg

PROFILE_DIRNAME = "svg_profiles"
VALID_RADIX = ("hex", "dec", "bin")


def _tokenize(spec: str) -> List[str]:
    return [t for t in re.split(r"[,\s]+", spec.strip()) if t]


def _parse_index_selector(spec: str, max_idx: int) -> Tuple[List[int], List[str]]:
    tokens = _tokenize(spec)
    out: List[int] = []
    errors: List[str] = []
    seen = set()

    for tk in tokens:
        m = re.match(r"^(\d+)-(\d+)$", tk)
        if m:
            a = int(m.group(1))
            b = int(m.group(2))
            if a > b:
                a, b = b, a
            for i in range(a, b + 1):
                if 1 <= i <= max_idx:
                    if i not in seen:
                        out.append(i)
                        seen.add(i)
                else:
                    errors.append(f"Index out of range: {i}")
            continue

        if tk.isdigit():
            i = int(tk)
            if 1 <= i <= max_idx:
                if i not in seen:
                    out.append(i)
                    seen.add(i)
            else:
                errors.append(f"Index out of range: {i}")
            continue

        errors.append(f"Invalid token: {tk}")

    return out, errors


def _parse_signal_selector(spec: str, signals) -> Tuple[List, List[str]]:
    tokens = _tokenize(spec)
    out: List = []
    errors: List[str] = []
    by_idx = {i + 1: s for i, s in enumerate(signals)}
    full_name_seen = set()

    for tk in tokens:
        m = re.match(r"^(\d+)-(\d+)$", tk)
        if m:
            a = int(m.group(1))
            b = int(m.group(2))
            if a > b:
                a, b = b, a
            for i in range(a, b + 1):
                if i in by_idx:
                    s = by_idx[i]
                    if s.full_name not in full_name_seen:
                        out.append(s)
                        full_name_seen.add(s.full_name)
                else:
                    errors.append(f"Index out of range: {i}")
            continue

        if tk.isdigit():
            idx = int(tk)
            if idx in by_idx:
                s = by_idx[idx]
                if s.full_name not in full_name_seen:
                    out.append(s)
                    full_name_seen.add(s.full_name)
            else:
                errors.append(f"Index out of range: {idx}")
            continue

        resolved, err = resolve_signals(signals, [tk])
        if err:
            errors.extend(err)
            continue
        for s in resolved:
            if s.full_name not in full_name_seen:
                out.append(s)
                full_name_seen.add(s.full_name)

    return out, errors


def _choose_vcds(vcd_dir: str) -> Optional[List[str]]:
    files = sorted(
        [os.path.join(vcd_dir, f) for f in os.listdir(vcd_dir) if f.lower().endswith(".vcd")]
    )
    if not files:
        return None

    print("Available VCD files:")
    for i, p in enumerate(files, start=1):
        print(f"  [{i}] {os.path.basename(p)}")

    while True:
        raw = input("Select VCD numbers (e.g. 1 3 / 2-4, A=all, Q=cancel): ").strip()
        if not raw:
            continue
        if raw.lower() == "q":
            return None
        if raw.lower() in ("a", "all", "*"):
            return files

        indices, errors = _parse_index_selector(raw, len(files))
        for e in errors:
            print(f"[WARN] {e}")
        if not indices:
            print("Invalid selection.")
            continue
        return [files[i - 1] for i in indices]


def _ask_range(default_start: int, default_end: int, default_spec: str = "") -> Tuple[int, int]:
    default_text = f"{default_start}:{default_end}"
    if default_spec:
        m = re.match(r"^\s*(\d+)\s*:\s*(\d+)\s*$", default_spec)
        if m:
            s = int(m.group(1))
            e = int(m.group(2))
            if e > s:
                default_start, default_end = s, e
                default_text = f"{s}:{e}"

    while True:
        raw = input(f"Time range start:end [{default_text}]: ").strip()
        if not raw:
            return int(default_start), int(default_end)
        m = re.match(r"^\s*(\d+)\s*:\s*(\d+)\s*$", raw)
        if not m:
            print("Invalid range format. Example: 0:5000000")
            continue
        s = int(m.group(1))
        e = int(m.group(2))
        if e <= s:
            print("End must be greater than start.")
            continue
        return s, e


def _infer_tb_scope(signals) -> str:
    counts: Dict[str, int] = {}
    for sig in signals:
        parts = sig.full_name.split(".")
        if not parts:
            continue
        top = parts[0]
        counts[top] = counts.get(top, 0) + 1
    if not counts:
        return ""
    return sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]


def _split_tb_and_dut(signals) -> Tuple[str, List, List]:
    tb_scope = _infer_tb_scope(signals)
    if not tb_scope:
        return "", list(signals), []

    tb_top: List = []
    dut_internal: List = []
    for sig in signals:
        parts = sig.full_name.split(".")
        if not parts:
            continue
        if parts[0] != tb_scope:
            continue
        # tb_scope.<signal> -> TB top signal, deeper hierarchy -> DUT/internal
        if len(parts) <= 2:
            tb_top.append(sig)
        else:
            dut_internal.append(sig)

    return tb_scope, tb_top, dut_internal


def _print_signal_list(title: str, signals) -> None:
    print(f"{title} ({len(signals)}):")
    if not signals:
        print("  [none]")
        return
    for i, sig in enumerate(signals, start=1):
        print(f"  [{i}] {sig.full_name} [{sig.width}]")


def _profile_path(project_dir: str, vcd_stem: str) -> str:
    return os.path.join(project_dir, "vcd", PROFILE_DIRNAME, f"{vcd_stem}.txt")


def _read_profile(path: str) -> Dict[str, str]:
    out: Dict[str, str] = {}
    if not os.path.isfile(path):
        return out
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            k, v = line.split("=", 1)
            out[k.strip().lower()] = v.strip()
    return out


def _write_profile(path: str, data: Dict[str, str]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lines = [
        "# VCD2SVG profile",
        "# Editable text file. Comma-separated signal names are supported.",
        "# Keys: include_tb, include_dut, exclude, time_range, zoom, output, radix_default, radix_overrides",
        f"include_tb={data.get('include_tb', '')}",
        f"include_dut={data.get('include_dut', '')}",
        f"exclude={data.get('exclude', '')}",
        f"time_range={data.get('time_range', '')}",
        f"zoom={data.get('zoom', '')}",
        f"output={data.get('output', '')}",
        f"radix_default={data.get('radix_default', 'hex')}",
        f"radix_overrides={data.get('radix_overrides', '')}",
        "",
    ]
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


def _open_profile_editor(path: str) -> None:
    if os.name == "nt":
        os.system(f'notepad "{path}"')
        return
    print(f"[INFO] Open and edit profile manually: {path}")
    input("Press Enter after profile edit is complete...")


def _path_from_profile(project_dir: str, raw_path: str, fallback: str) -> str:
    if not raw_path:
        return fallback
    if os.path.isabs(raw_path):
        return raw_path
    return os.path.normpath(os.path.join(project_dir, raw_path))


def _to_rel_if_under(path: str, root: str) -> str:
    abs_path = os.path.abspath(path)
    abs_root = os.path.abspath(root)
    try:
        common = os.path.commonpath([abs_path, abs_root])
    except ValueError:
        return abs_path
    if os.path.normcase(common) == os.path.normcase(abs_root):
        return os.path.relpath(abs_path, abs_root)
    return abs_path


def _signals_to_csv(signals) -> str:
    return ",".join(sig.full_name for sig in signals)


def _choose_signals_with_default(prompt: str, signals, default_spec: str, blank_behavior: str):
    while True:
        show_default = default_spec if default_spec else blank_behavior
        raw = input(f"{prompt} [default: {show_default}]: ").strip()
        spec = raw if raw else default_spec

        if not spec:
            if blank_behavior == "first 10":
                return list(signals[:10])
            return []

        if spec.lower() in ("all", "*"):
            return list(signals)

        selected, errors = _parse_signal_selector(spec, signals)
        for e in errors:
            print(f"[WARN] {e}")
        if selected or blank_behavior == "none":
            return selected
        print("[ERROR] No valid signals selected. Try again.")


def _normalize_radix(raw: str, fallback: str = "hex") -> str:
    value = raw.strip().lower()
    if value in VALID_RADIX:
        return value
    return fallback


def _parse_radix_overrides(spec: str) -> Tuple[Dict[str, str], List[str]]:
    out: Dict[str, str] = {}
    errors: List[str] = []
    if not spec:
        return out, errors

    for tk in [x.strip() for x in spec.split(",") if x.strip()]:
        if ":" not in tk:
            errors.append(f"Invalid radix override token: {tk}")
            continue
        name, fmt = tk.rsplit(":", 1)
        name = name.strip()
        fmt = fmt.strip().lower()
        if not name:
            errors.append(f"Invalid radix override token: {tk}")
            continue
        if fmt not in VALID_RADIX:
            errors.append(f"Invalid radix '{fmt}' for signal '{name}'")
            continue
        out[name] = fmt
    return out, errors


def _format_radix_overrides(bus_signals, overrides: Dict[str, str], default_fmt: str) -> str:
    items: List[str] = []
    for sig in bus_signals:
        fmt = overrides.get(sig.full_name, default_fmt)
        if fmt != default_fmt:
            items.append(f"{sig.full_name}:{fmt}")
    return ",".join(items)


def _ask_bus_radix(selected_signals, default_fmt: str, default_overrides: Dict[str, str]):
    bus_signals = [s for s in selected_signals if s.width > 1]
    if not bus_signals:
        return "hex", {}

    print()
    print(f"[INFO] Bus signals selected: {len(bus_signals)}")
    while True:
        raw = input(f"Default bus radix [hex/dec/bin] [{default_fmt}]: ").strip().lower()
        if not raw:
            base_fmt = default_fmt
            break
        if raw in VALID_RADIX:
            base_fmt = raw
            break
        print("Invalid radix. Choose one of: hex, dec, bin.")

    overrides: Dict[str, str] = {}
    valid_names = {s.full_name for s in bus_signals}
    for name, fmt in default_overrides.items():
        if name in valid_names and fmt in VALID_RADIX and fmt != base_fmt:
            overrides[name] = fmt

    edit_raw = input("Change radix for specific bus signals now? (y/N): ").strip().lower()
    if edit_raw in ("y", "yes"):
        print("Bus signal list:")
        for i, sig in enumerate(bus_signals, start=1):
            cur = overrides.get(sig.full_name, base_fmt)
            print(f"  [{i}] {sig.full_name} [{sig.width}] ({cur})")

        while True:
            spec = input("Signal to override (index/name/range, blank=done): ").strip()
            if not spec:
                break
            target_signals, errors = _parse_signal_selector(spec, bus_signals)
            for e in errors:
                print(f"[WARN] {e}")
            if not target_signals:
                print("[WARN] No valid bus signals selected.")
                continue

            while True:
                fmt_raw = input("Radix for selected signal(s) [hex/dec/bin]: ").strip().lower()
                if fmt_raw in VALID_RADIX:
                    break
                print("Invalid radix. Choose one of: hex, dec, bin.")

            for sig in target_signals:
                if fmt_raw == base_fmt:
                    overrides.pop(sig.full_name, None)
                else:
                    overrides[sig.full_name] = fmt_raw
            print(f"[INFO] Updated radix for {len(target_signals)} signal(s).")

    return base_fmt, overrides


def _configure_one_vcd(project_dir: str, vcd_path: str) -> bool:
    base_name = os.path.splitext(os.path.basename(vcd_path))[0]
    profile_path = _profile_path(project_dir, base_name)
    profile: Dict[str, str] = {}

    if os.path.isfile(profile_path):
        print(f"[INFO] Existing profile: {profile_path}")
        mode = input("Profile mode [U]se/[E]dit/[N]ew (default U): ").strip().lower()
        if mode in ("", "u"):
            profile = _read_profile(profile_path)
        elif mode == "e":
            _open_profile_editor(profile_path)
            profile = _read_profile(profile_path)
        else:
            profile = {}
    else:
        print(f"[INFO] No profile yet. New profile will be created: {profile_path}")

    header = parse_header(vcd_path)
    if not header.signals:
        print("[ERROR] No signals found in VCD header.")
        return False

    tb_scope, tb_top_signals, dut_internal_signals = _split_tb_and_dut(header.signals)
    print(f"[INFO] Signals total: {len(header.signals)}")
    if tb_scope:
        print(f"[INFO] Inferred TB scope: {tb_scope}")

    print()
    _print_signal_list("TB-top signals", tb_top_signals)
    print()
    _print_signal_list("DUT/internal signals", dut_internal_signals)
    print()

    default_tb = profile.get("include_tb", "")
    default_dut = profile.get("include_dut", "")
    default_exclude = profile.get("exclude", "")
    default_range = profile.get("time_range", "")
    default_zoom = profile.get("zoom", "")
    default_radix = _normalize_radix(profile.get("radix_default", "hex"), "hex")
    default_overrides, default_ov_errors = _parse_radix_overrides(profile.get("radix_overrides", ""))
    for e in default_ov_errors:
        print(f"[WARN] {e}")

    vcd_dir = os.path.dirname(vcd_path)
    out_default = os.path.join(vcd_dir, "svg", f"{base_name}_custom.svg")
    out_default = _path_from_profile(project_dir, profile.get("output", ""), out_default)

    selected_tb = _choose_signals_with_default(
        "TB-top include (indexes/names/ranges or all/*)",
        tb_top_signals,
        default_tb,
        "first 10",
    )
    selected_dut = _choose_signals_with_default(
        "DUT/internal include (indexes/names/ranges or all/*)",
        dut_internal_signals,
        default_dut,
        "none",
    )

    selected_map = {}
    for sig in selected_tb + selected_dut:
        selected_map[sig.full_name] = sig
    selected = list(selected_map.values())
    if not selected:
        print("[ERROR] No signals selected.")
        return False

    exclude_raw = input(
        f"Exclude signals (optional, indexes/names/ranges) [default: {default_exclude or 'none'}]: "
    ).strip()
    exclude_spec = exclude_raw if exclude_raw else default_exclude
    excluded_signals = []
    if exclude_spec:
        excluded_signals, exclude_err = _parse_signal_selector(exclude_spec, header.signals)
        for e in exclude_err:
            print(f"[WARN] {e}")
        excluded_set = {s.full_name for s in excluded_signals}
        selected = [s for s in selected if s.full_name not in excluded_set]
        if not selected:
            print("[ERROR] All selected signals were excluded.")
            return False

    bus_default_fmt, bus_fmt_overrides = _ask_bus_radix(selected, default_radix, default_overrides)

    last_t = find_last_timestamp(vcd_path)
    start_t, end_t = _ask_range(0, max(1, last_t), default_spec=default_range)

    zoom_raw = input(f"Zoom (px/tick, blank=auto) [default: {default_zoom or 'auto'}]: ").strip()
    zoom_text = zoom_raw if zoom_raw else default_zoom
    scale = 0.0
    if zoom_text:
        try:
            scale = float(zoom_text)
        except ValueError:
            print("[WARN] Invalid zoom. Auto mode will be used.")
            scale = 0.0

    out_raw = input(f"Output SVG path [{out_default}]: ").strip()
    out_path = out_raw if out_raw else out_default
    if not os.path.isabs(out_path):
        out_path = os.path.normpath(os.path.join(project_dir, out_path))

    tracked_ids = [s.id_code for s in selected]
    events_by_id = parse_events(
        vcd_path,
        tracked_ids=tracked_ids,
        start_time=start_t,
        end_time=end_t,
    )

    span = max(1, end_t - start_t)
    if scale <= 0:
        scale = max(1e-6, 1800.0 / span)

    rows = []
    for sig in selected:
        segments = build_segments(events_by_id.get(sig.id_code, []), start_t, end_t, default="x")
        rows.append((sig.full_name, sig.width, segments))

    make_svg(
        rows,
        start_t,
        end_t,
        scale,
        out_path,
        value_formats=bus_fmt_overrides,
        default_bus_fmt=bus_default_fmt,
    )

    bus_signals = [s for s in selected if s.width > 1]
    profile_data = {
        "include_tb": _signals_to_csv(selected_tb),
        "include_dut": _signals_to_csv(selected_dut),
        "exclude": _signals_to_csv(excluded_signals),
        "time_range": f"{start_t}:{end_t}",
        "zoom": zoom_text,
        "output": _to_rel_if_under(out_path, project_dir),
        "radix_default": bus_default_fmt,
        "radix_overrides": _format_radix_overrides(bus_signals, bus_fmt_overrides, bus_default_fmt),
    }
    _write_profile(profile_path, profile_data)

    print("\n[OK] SVG generated")
    print(f"[OK] VCD    : {vcd_path}")
    print(f"[OK] File   : {out_path}")
    print(f"[OK] Signals: {len(selected)}")
    print(f"[OK] Range  : {start_t}:{end_t}")
    print(f"[OK] Profile: {profile_path}")
    return True


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: vcd2svg_interactive.py <project_dir>")
        return 1

    project_dir = os.path.abspath(sys.argv[1])
    vcd_dir = os.path.join(project_dir, "vcd")
    if not os.path.isdir(vcd_dir):
        print(f"[ERROR] VCD folder not found: {vcd_dir}")
        return 1

    vcd_paths = _choose_vcds(vcd_dir)
    if not vcd_paths:
        print("[INFO] Cancelled.")
        return 1

    print(f"\n[INFO] Selected VCD count: {len(vcd_paths)}")
    ok_count = 0
    fail_count = 0

    for i, vcd_path in enumerate(vcd_paths, start=1):
        print("\n" + "=" * 79)
        print(f"[VCD {i}/{len(vcd_paths)}] {vcd_path}")
        print("=" * 79)
        try:
            ok = _configure_one_vcd(project_dir, vcd_path)
        except Exception as ex:
            print(f"[ERROR] Unexpected failure: {ex}")
            ok = False

        if ok:
            ok_count += 1
        else:
            fail_count += 1

    print("\n" + "=" * 79)
    print(f"[DONE] total={len(vcd_paths)} ok={ok_count} fail={fail_count}")
    if fail_count > 0:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
