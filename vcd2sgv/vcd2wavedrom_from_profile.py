#!/usr/bin/env python3
"""
Generate WaveDrom JSON/HTML from VCD using svg profile TXT files.

Profile location:
  <project>/vcd/svg_profiles/<tb_name>.txt
VCD location:
  <project>/vcd/<tb_name>.vcd
"""

from __future__ import annotations

import argparse
import json
import os
import re
from typing import Dict, List, Optional, Sequence, Tuple

from vcd2wavedrom import _make_html, _sample_wave
from vcd_parser import find_last_timestamp, parse_events, parse_header, resolve_signals

PROFILE_DIRNAME = "svg_profiles"
WAVEDROM_DIRNAME = "wavedrom"


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


def _read_profile(path: str) -> Dict[str, str]:
    out: Dict[str, str] = {}
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


def _split_csv(raw: str) -> List[str]:
    return [x.strip() for x in raw.split(",") if x.strip()]


def _parse_time_range(raw: str) -> Optional[Tuple[int, int]]:
    if not raw:
        return None
    m = re.match(r"^\s*(\d+)\s*:\s*(\d+)\s*$", raw)
    if not m:
        return None
    start_t = int(m.group(1))
    end_t = int(m.group(2))
    if end_t <= start_t:
        return None
    return start_t, end_t


def _parse_positive_int(raw: str) -> int:
    text = raw.strip()
    if not text:
        return 0
    if not text.isdigit():
        return 0
    value = int(text)
    return value if value > 0 else 0


def _parse_bool(raw: str) -> Optional[bool]:
    text = raw.strip().lower()
    if text in ("1", "true", "yes", "y", "on"):
        return True
    if text in ("0", "false", "no", "n", "off"):
        return False
    return None


def _path_from_profile(project_dir: str, raw_path: str, fallback: str) -> str:
    if not raw_path:
        return fallback
    if os.path.isabs(raw_path):
        return raw_path
    return os.path.normpath(os.path.join(project_dir, raw_path))


def _open_profile_editor(path: str) -> None:
    if os.name == "nt":
        os.system(f'notepad "{path}"')
        return
    print(f"[INFO] Open and edit profile manually: {path}")
    input("Press Enter after profile edit is complete...")


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


def _collect_profiles(project_dir: str) -> List[str]:
    profile_dir = os.path.join(project_dir, "vcd", PROFILE_DIRNAME)
    if not os.path.isdir(profile_dir):
        return []
    return sorted(
        [
            os.path.join(profile_dir, name)
            for name in os.listdir(profile_dir)
            if name.lower().endswith(".txt")
        ]
    )


def _choose_profile_paths(profile_paths: Sequence[str]) -> List[str]:
    print("Available profile files:")
    for i, p in enumerate(profile_paths, start=1):
        print(f"  [{i}] {os.path.basename(p)}")

    while True:
        raw = input("Select profile numbers (e.g. 1 3 / 2-4, A=all, Q=cancel): ").strip()
        if not raw:
            continue
        if raw.lower() == "q":
            return []
        if raw.lower() in ("a", "all", "*"):
            return list(profile_paths)

        idxs, errors = _parse_index_selector(raw, len(profile_paths))
        for e in errors:
            print(f"[WARN] {e}")
        if not idxs:
            print("Invalid selection.")
            continue
        return [profile_paths[i - 1] for i in idxs]


def _resolve_profile_signals(header_signals, profile: Dict[str, str], max_signals: int):
    include_names = _split_csv(profile.get("include_tb", "")) + _split_csv(profile.get("include_dut", ""))
    if not include_names:
        include_names = _split_csv(profile.get("signals", ""))

    selected = []
    if include_names:
        selected, sel_errors = resolve_signals(header_signals, include_names)
        for e in sel_errors:
            print(f"[WARN] {e}")
    else:
        selected = list(header_signals[: max(1, max_signals)])
        print(f"[WARN] Profile has no include signals. Using first {len(selected)} signal(s).")

    if not selected:
        return []

    exclude_names = _split_csv(profile.get("exclude", ""))
    if exclude_names:
        excluded, exc_errors = resolve_signals(header_signals, exclude_names)
        for e in exc_errors:
            print(f"[WARN] {e}")
        excluded_set = {s.full_name for s in excluded}
        selected = [s for s in selected if s.full_name not in excluded_set]

    unique = []
    seen = set()
    for sig in selected:
        if sig.full_name in seen:
            continue
        unique.append(sig)
        seen.add(sig.full_name)
    return unique


def _convert_one_profile(
    project_dir: str,
    profile_path: str,
    forced_step: int,
    max_signals: int,
    force_html: bool,
    force_no_html: bool,
    title_text: str,
) -> bool:
    stem = os.path.splitext(os.path.basename(profile_path))[0]
    profile = _read_profile(profile_path)

    default_vcd = os.path.join(project_dir, "vcd", f"{stem}.vcd")
    vcd_path = _path_from_profile(project_dir, profile.get("vcd", ""), default_vcd)
    if not os.path.isfile(vcd_path):
        print(f"[ERROR] VCD not found for profile '{stem}': {vcd_path}")
        return False

    header = parse_header(vcd_path)
    if not header.signals:
        print(f"[ERROR] No signals found in VCD header: {vcd_path}")
        return False

    selected = _resolve_profile_signals(header.signals, profile, max_signals)
    if not selected:
        print(f"[ERROR] No signals selected for profile '{stem}'.")
        return False

    time_range = _parse_time_range(profile.get("time_range", ""))
    start_t = 0
    end_t = find_last_timestamp(vcd_path)
    if time_range:
        start_t, end_t = time_range
    if end_t <= start_t:
        end_t = start_t + 1

    span = max(1, end_t - start_t)
    profile_step = _parse_positive_int(profile.get("wavedrom_step", ""))
    step = forced_step if forced_step > 0 else (profile_step if profile_step > 0 else max(1, span // 120))

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

    default_json = os.path.join(project_dir, "vcd", WAVEDROM_DIRNAME, f"{stem}.json")
    json_path = _path_from_profile(project_dir, profile.get("wavedrom_output", ""), default_json)
    os.makedirs(os.path.dirname(os.path.abspath(json_path)), exist_ok=True)

    title = title_text or profile.get("wavedrom_title", "") or f"{stem}: {start_t}..{end_t} (step={step})"
    payload = {
        "signal": signal_entries,
        "head": {"text": title},
        "config": {"hscale": 1},
    }
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)

    profile_html_pref = _parse_bool(profile.get("wavedrom_html", ""))
    if force_no_html:
        html_enabled = False
    elif force_html:
        html_enabled = True
    elif profile_html_pref is not None:
        html_enabled = profile_html_pref
    else:
        html_enabled = True

    html_path = ""
    if html_enabled:
        default_html = os.path.join(project_dir, "vcd", WAVEDROM_DIRNAME, f"{stem}.html")
        html_path = _path_from_profile(project_dir, profile.get("wavedrom_html_output", ""), default_html)
        os.makedirs(os.path.dirname(os.path.abspath(html_path)), exist_ok=True)
        json_for_html = os.path.relpath(json_path, os.path.dirname(os.path.abspath(html_path)))
        _make_html(json_for_html.replace("\\", "/"), html_path)

    profile["wavedrom_step"] = str(step)
    profile["wavedrom_output"] = _to_rel_if_under(json_path, project_dir)
    profile["wavedrom_html"] = "1" if html_enabled else "0"
    if not profile.get("radix_default"):
        profile["radix_default"] = "hex"
    profile["wavedrom_html_output"] = (
        _to_rel_if_under(html_path, project_dir) if html_enabled else profile.get("wavedrom_html_output", "")
    )
    _write_profile(profile_path, profile)

    print(f"[OK] WaveDrom JSON: {json_path}")
    if html_enabled:
        print(f"[OK] WaveDrom HTML: {html_path}")
    print(f"[OK] Profile used : {profile_path}")
    print(f"[OK] Signals      : {len(selected)}")
    print(f"[OK] Range/step   : {start_t}:{end_t} (step={step})")
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description="Generate WaveDrom from svg profile TXT files")
    ap.add_argument("project_dir", help="Project directory path")
    ap.add_argument(
        "--profiles",
        default="",
        help="Comma separated profile stems or .txt names (e.g. tb_a,tb_b)",
    )
    ap.add_argument("--all", action="store_true", help="Use all profile files")
    ap.add_argument("--step", type=int, default=0, help="Forced sample step (ticks)")
    ap.add_argument("--max-signals", type=int, default=10, help="Fallback when profile include is empty")
    ap.add_argument("--title", default="", help="Override WaveDrom title text")
    ap.add_argument("--html", action="store_true", help="Force HTML generation")
    ap.add_argument("--no-html", action="store_true", help="Disable HTML generation")
    ap.add_argument("--yes", action="store_true", help="Run without per-profile confirmation prompt")
    args = ap.parse_args()

    project_dir = os.path.abspath(args.project_dir)
    profile_paths = _collect_profiles(project_dir)
    if not profile_paths:
        print(f"[ERROR] No profile TXT files found: {os.path.join(project_dir, 'vcd', PROFILE_DIRNAME)}")
        return 1

    selected_paths: List[str] = []
    if args.profiles:
        by_stem = {
            os.path.splitext(os.path.basename(p))[0].lower(): p
            for p in profile_paths
        }
        by_name = {os.path.basename(p).lower(): p for p in profile_paths}
        missing: List[str] = []
        for item in _split_csv(args.profiles):
            key = item.lower()
            if key in by_name:
                selected_paths.append(by_name[key])
            elif key in by_stem:
                selected_paths.append(by_stem[key])
            elif key.endswith(".txt") and key[:-4] in by_stem:
                selected_paths.append(by_stem[key[:-4]])
            else:
                missing.append(item)
        if missing:
            for m in missing:
                print(f"[WARN] Profile not found: {m}")
    elif args.all:
        selected_paths = list(profile_paths)
    else:
        selected_paths = _choose_profile_paths(profile_paths)

    if not selected_paths:
        print("[INFO] No profile selected. Cancelled.")
        return 1

    # De-duplicate while preserving order
    dedup: List[str] = []
    seen = set()
    for p in selected_paths:
        if p in seen:
            continue
        dedup.append(p)
        seen.add(p)
    selected_paths = dedup

    ok_count = 0
    fail_count = 0
    skip_count = 0
    print(f"[INFO] Selected profile count: {len(selected_paths)}")
    for i, profile_path in enumerate(selected_paths, start=1):
        if not args.yes:
            while True:
                raw = input(
                    f"Use profile '{os.path.basename(profile_path)}'? [Y]es/[E]dit/[S]kip/[Q]uit: "
                ).strip().lower()
                if raw in ("", "y", "yes"):
                    break
                if raw in ("e", "edit"):
                    _open_profile_editor(profile_path)
                    continue
                if raw in ("s", "skip", "n", "no"):
                    print(f"[INFO] Skipped profile: {profile_path}")
                    skip_count += 1
                    profile_path = ""
                    break
                if raw in ("q", "quit"):
                    print("[INFO] Stopped by user.")
                    selected_paths = selected_paths[:i - 1]
                    profile_path = ""
                    break
                print("Invalid input. Enter Y/E/S/Q.")
            if not profile_path:
                # quit or skip path above
                if raw in ("q", "quit"):
                    break
                continue

        print("\n" + "=" * 79)
        print(f"[PROFILE {i}/{len(selected_paths)}] {profile_path}")
        print("=" * 79)
        ok = _convert_one_profile(
            project_dir=project_dir,
            profile_path=profile_path,
            forced_step=max(0, args.step),
            max_signals=max(1, args.max_signals),
            force_html=args.html,
            force_no_html=args.no_html,
            title_text=args.title,
        )
        if ok:
            ok_count += 1
        else:
            fail_count += 1

    print("\n" + "=" * 79)
    print(f"[DONE] total={len(selected_paths)} ok={ok_count} skip={skip_count} fail={fail_count}")
    return 0 if fail_count == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
