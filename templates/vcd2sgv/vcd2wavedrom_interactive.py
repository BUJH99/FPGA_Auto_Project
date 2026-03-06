#!/usr/bin/env python3
"""
Interactive VCD -> WaveDrom helper.

Features:
- Pick one or more VCD files from <project>/vcd
- Configure each selected VCD in sequence
- Split signal selection into TB-top and DUT/internal groups
- Reuse/edit/create per-VCD TXT profile under <project>/vcd/svg_profiles
- Set time range, step, and JSON/HTML output paths
"""

from __future__ import annotations

import argparse
import json
import os
import re
from typing import Dict, List, Optional, Tuple

from vcd2wavedrom import _make_html, _sample_wave
from vcd_parser import find_last_timestamp, parse_events, parse_header, resolve_signals

PROFILE_DIRNAME = "svg_profiles"
USER_CANCEL_RC = 99


def _tokenize(spec: str) -> List[str]:
    return [t for t in re.split(r"[,\s]+", spec.strip()) if t]


def _split_csv(raw: str) -> List[str]:
    return [x.strip() for x in raw.split(",") if x.strip()]


def _parse_bool(raw: str) -> Optional[bool]:
    text = raw.strip().lower()
    if text in ("1", "true", "yes", "y", "on"):
        return True
    if text in ("0", "false", "no", "n", "off"):
        return False
    return None


def _parse_positive_int(raw: str) -> int:
    text = raw.strip()
    if not text:
        return 0
    if not text.isdigit():
        return 0
    value = int(text)
    return value if value > 0 else 0


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


def _parse_time_range(raw: str) -> Optional[Tuple[int, int]]:
    if not raw:
        return None
    m = re.match(r"^\s*(\d+)\s*:\s*(\d+)\s*$", raw)
    if not m:
        return None
    s = int(m.group(1))
    e = int(m.group(2))
    if e <= s:
        return None
    return s, e


def _ask_range(default_start: int, default_end: int, default_spec: str = "") -> Tuple[int, int]:
    default_text = f"{default_start}:{default_end}"
    parsed = _parse_time_range(default_spec)
    if parsed:
        default_start, default_end = parsed
        default_text = f"{default_start}:{default_end}"

    while True:
        raw = input(f"Time range start:end [{default_text}]: ").strip()
        if not raw:
            return int(default_start), int(default_end)
        parsed = _parse_time_range(raw)
        if not parsed:
            print("Invalid range format. Example: 0:5000000")
            continue
        return parsed


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
    ordered_keys = [
        "include_tb",
        "include_dut",
        "exclude",
        "time_range",
        "zoom",
        "output",
        "radix_default",
        "radix_overrides",
        "wavedrom_step",
        "wavedrom_output",
        "wavedrom_html_output",
        "wavedrom_html",
    ]
    extras = [k for k in sorted(data.keys()) if k not in ordered_keys]
    lines = [
        "# VCD2SVG profile",
        "# Editable text file. Comma-separated signal names are supported.",
        "# Keys: include_tb, include_dut, exclude, time_range, zoom, output, radix_default, radix_overrides, wavedrom_step, wavedrom_output, wavedrom_html_output, wavedrom_html",
    ]
    defaults = {
        "radix_default": "hex",
        "radix_overrides": "",
        "wavedrom_step": "",
        "wavedrom_output": "",
        "wavedrom_html_output": "",
        "wavedrom_html": "",
    }
    for k in ordered_keys:
        v = data.get(k, defaults.get(k, ""))
        if k == "radix_default" and not str(v).strip():
            v = "hex"
        lines.append(f"{k}={v}")
    for k in extras:
        lines.append(f"{k}={data.get(k, '')}")
    lines.append("")

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


def _choose_signals_with_default(
    prompt: str,
    signals,
    default_spec: str,
    blank_behavior: str,
    default_count: int,
):
    show_default = default_spec if default_spec else blank_behavior

    while True:
        raw = input(f"{prompt} [default: {show_default}]: ").strip()
        spec = raw if raw else default_spec

        if not spec:
            if blank_behavior == "first":
                return list(signals[: max(1, default_count)])
            return []

        if spec.lower() in ("all", "*"):
            return list(signals)

        selected, errors = _parse_signal_selector(spec, signals)
        for e in errors:
            print(f"[WARN] {e}")
        if selected or blank_behavior == "none":
            return selected
        print("[ERROR] No valid signals selected. Try again.")


def _ask_positive_int(prompt: str, default_value: int) -> int:
    while True:
        raw = input(f"{prompt} [{default_value}]: ").strip()
        if not raw:
            return default_value
        if raw.isdigit() and int(raw) > 0:
            return int(raw)
        print("Invalid value. Enter a positive integer.")


def _ask_yes_no(prompt: str, default_yes: bool = True) -> bool:
    hint = "Y/n" if default_yes else "y/N"
    while True:
        raw = input(f"{prompt} [{hint}]: ").strip().lower()
        if not raw:
            return default_yes
        if raw in ("y", "yes"):
            return True
        if raw in ("n", "no"):
            return False
        print("Invalid input. Enter y or n.")


def _configure_one_vcd(
    project_dir: str,
    vcd_path: str,
    max_signals: int,
    forced_step: int,
    force_html: Optional[bool],
) -> Optional[bool]:
    base_name = os.path.splitext(os.path.basename(vcd_path))[0]
    profile_path = _profile_path(project_dir, base_name)
    profile: Dict[str, str] = {}

    if os.path.isfile(profile_path):
        print(f"[INFO] Existing profile: {profile_path}")
        while True:
            mode = input(
                "Load saved TXT profile? [Y]es/[E]dit/[N]ew/[Q]cancel (default Y): "
            ).strip().lower()
            if mode in ("", "y", "yes", "u", "use", "l", "load"):
                profile = _read_profile(profile_path)
                break
            if mode in ("e", "edit"):
                _open_profile_editor(profile_path)
                profile = _read_profile(profile_path)
                break
            if mode in ("n", "new"):
                profile = {}
                break
            if mode in ("q", "quit", "c", "cancel"):
                print("[INFO] Cancelled by user.")
                return None
            print("Invalid input. Enter Y/E/N/Q.")
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

    selected_tb = _choose_signals_with_default(
        "TB-top include",
        tb_top_signals,
        default_tb,
        blank_behavior="first",
        default_count=max_signals,
    )
    selected_dut = _choose_signals_with_default(
        "DUT/internal include",
        dut_internal_signals,
        default_dut,
        blank_behavior="none",
        default_count=max_signals,
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

    last_t = find_last_timestamp(vcd_path)
    start_t, end_t = _ask_range(0, max(1, last_t), default_spec=default_range)

    span = max(1, end_t - start_t)
    auto_step = max(1, span // 120)
    profile_step = _parse_positive_int(profile.get("wavedrom_step", ""))
    default_step = forced_step if forced_step > 0 else (profile_step if profile_step > 0 else auto_step)
    step = _ask_positive_int("Step (sample ticks)", default_step)

    if force_html is None:
        profile_html = _parse_bool(profile.get("wavedrom_html", ""))
        html_default = True if profile_html is None else profile_html
        html_enabled = _ask_yes_no("Generate HTML viewer too?", default_yes=html_default)
    else:
        html_enabled = force_html
        print(f"[INFO] HTML generation forced: {'ON' if html_enabled else 'OFF'}")

    vcd_dir = os.path.dirname(vcd_path)
    out_json_default = os.path.join(vcd_dir, "wavedrom", f"{base_name}_custom.json")
    out_json_default = _path_from_profile(project_dir, profile.get("wavedrom_output", ""), out_json_default)
    out_json_raw = input(f"Output JSON path [{out_json_default}]: ").strip()
    out_json_path = out_json_raw if out_json_raw else out_json_default
    if not os.path.isabs(out_json_path):
        out_json_path = os.path.normpath(os.path.join(project_dir, out_json_path))

    out_html_path = ""
    if html_enabled:
        out_html_default = os.path.splitext(out_json_path)[0] + ".html"
        out_html_default = _path_from_profile(
            project_dir, profile.get("wavedrom_html_output", ""), out_html_default
        )
        out_html_raw = input(f"Output HTML path [{out_html_default}]: ").strip()
        out_html_path = out_html_raw if out_html_raw else out_html_default
        if not os.path.isabs(out_html_path):
            out_html_path = os.path.normpath(os.path.join(project_dir, out_html_path))

    tracked_ids = [s.id_code for s in selected]
    events_by_id = parse_events(
        vcd_path,
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

    title = f"{base_name}: {start_t}..{end_t} (step={step})"
    payload = {
        "signal": signal_entries,
        "head": {"text": title},
        "config": {"hscale": 1},
    }

    os.makedirs(os.path.dirname(os.path.abspath(out_json_path)), exist_ok=True)
    with open(out_json_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)

    if html_enabled:
        os.makedirs(os.path.dirname(os.path.abspath(out_html_path)), exist_ok=True)
        json_for_html = os.path.relpath(out_json_path, os.path.dirname(os.path.abspath(out_html_path)))
        _make_html(json_for_html.replace("\\", "/"), out_html_path)

    profile_out = dict(profile)
    profile_out["include_tb"] = _signals_to_csv(selected_tb)
    profile_out["include_dut"] = _signals_to_csv(selected_dut)
    profile_out["exclude"] = _signals_to_csv(excluded_signals)
    profile_out["time_range"] = f"{start_t}:{end_t}"
    profile_out["wavedrom_step"] = str(step)
    profile_out["wavedrom_output"] = _to_rel_if_under(out_json_path, project_dir)
    profile_out["wavedrom_html"] = "1" if html_enabled else "0"
    if html_enabled:
        profile_out["wavedrom_html_output"] = _to_rel_if_under(out_html_path, project_dir)
    _write_profile(profile_path, profile_out)

    print("\n[OK] WaveDrom generated")
    print(f"[OK] VCD    : {vcd_path}")
    print(f"[OK] JSON   : {out_json_path}")
    if html_enabled:
        print(f"[OK] HTML   : {out_html_path}")
    print(f"[OK] Signals: {len(selected)}")
    print(f"[OK] Range  : {start_t}:{end_t}")
    print(f"[OK] Step   : {step}")
    print(f"[OK] Profile: {profile_path}")
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description="Interactive VCD to WaveDrom converter")
    ap.add_argument("project_dir", help="Project directory")
    ap.add_argument("--max-signals", type=int, default=10, help="Default TB-top signal count for blank selection")
    ap.add_argument("--step", type=int, default=0, help="Default sample step (ticks)")
    ap.add_argument("--html", action="store_true", help="Force HTML generation")
    ap.add_argument("--no-html", action="store_true", help="Disable HTML generation")
    args = ap.parse_args()

    project_dir = os.path.abspath(args.project_dir)
    vcd_dir = os.path.join(project_dir, "vcd")
    if not os.path.isdir(vcd_dir):
        print(f"[ERROR] VCD folder not found: {vcd_dir}")
        return 1

    if args.html and args.no_html:
        print("[ERROR] --html and --no-html cannot be used together.")
        return 1

    force_html: Optional[bool] = None
    if args.html:
        force_html = True
    elif args.no_html:
        force_html = False

    vcd_paths = _choose_vcds(vcd_dir)
    if not vcd_paths:
        print("[INFO] Cancelled.")
        return USER_CANCEL_RC

    print(f"\n[INFO] Selected VCD count: {len(vcd_paths)}")
    ok_count = 0
    fail_count = 0
    for i, vcd_path in enumerate(vcd_paths, start=1):
        print("\n" + "=" * 79)
        print(f"[VCD {i}/{len(vcd_paths)}] {vcd_path}")
        print("=" * 79)
        try:
            result = _configure_one_vcd(
                project_dir=project_dir,
                vcd_path=vcd_path,
                max_signals=max(1, args.max_signals),
                forced_step=max(0, args.step),
                force_html=force_html,
            )
        except Exception as ex:
            print(f"[ERROR] Unexpected failure: {ex}")
            result = False

        if result is None:
            print("[INFO] Cancelled.")
            return USER_CANCEL_RC
        if result:
            ok_count += 1
        else:
            fail_count += 1

    print("\n" + "=" * 79)
    print(f"[DONE] total={len(vcd_paths)} ok={ok_count} fail={fail_count}")
    return 0 if fail_count == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
