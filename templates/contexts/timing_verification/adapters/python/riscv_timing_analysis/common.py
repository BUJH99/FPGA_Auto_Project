from __future__ import annotations

import json
import os
import pathlib
import re
import subprocess
import time
from collections.abc import Callable
from typing import Any

import yaml


DEFAULT_PROFILE_NAME = "timing_analysis_profile.json"
DEFAULT_VIVADO_CANDIDATES = [
    r"C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat",
    r"C:\AMDDesignTools\2025.1\Vivado\bin\vivado.bat",
    r"C:\Xilinx\Vivado\2025.2\bin\vivado.bat",
    r"C:\Xilinx\Vivado\2025.1\bin\vivado.bat",
    r"C:\Xilinx\Vivado\2024.2\bin\vivado.bat",
    r"C:\Xilinx\Vivado\2024.1\bin\vivado.bat",
]


def wsl_to_windows(path: pathlib.Path) -> str:
    path_str = str(path.resolve())
    if path_str.startswith("/mnt/") and len(path_str) > 6:
      drive = path_str[5].upper()
      tail = path_str[6:]
      return f"{drive}:{tail}"
    return path_str.replace("\\", "/")


def windows_to_wsl(path_str: str) -> pathlib.Path:
    match = re.match(r"^(?P<drive>[A-Za-z]):[\\/](?P<tail>.*)$", path_str)
    if match:
        drive = match.group("drive").lower()
        tail = match.group("tail").replace("\\", "/")
        return pathlib.Path(f"/mnt/{drive}/{tail}")
    return pathlib.Path(path_str)


def host_path_exists(path_str: str) -> bool:
    if not path_str:
        return False
    try:
        if os.name == "nt":
            return pathlib.Path(path_str).exists()
        return windows_to_wsl(path_str).exists()
    except OSError:
        return False


def resolve_automation_repo_root(project_root: pathlib.Path) -> pathlib.Path:
    env_root = os.environ.get("FPGA_AUTOMATION_REPO_ROOT", "").strip()
    module_root = pathlib.Path(__file__).resolve().parents[6]
    managed_parent = project_root.resolve().parents[1]
    candidates = [
        pathlib.Path(env_root) if env_root else None,
        managed_parent / "FPGA_Auto_Project",
        module_root,
        managed_parent,
    ]

    for candidate in candidates:
        if candidate is None:
            continue
        marker = candidate / "templates" / "contexts" / "timing_verification" / "adapters" / "tcl" / "common.tcl"
        if marker.exists():
            return candidate.resolve()

    return module_root


def decode_windows_output(data: bytes) -> str:
    for encoding in ("utf-8", "cp949", "mbcs"):
        try:
            return data.decode(encoding)
        except (LookupError, UnicodeDecodeError):
            continue
    return data.decode("utf-8", errors="ignore")


def detect_vivado_bat() -> str:
    env_path = os.environ.get("VIVADO_BAT", "").strip()
    if env_path:
        return env_path

    for candidate in DEFAULT_VIVADO_CANDIDATES:
        if host_path_exists(candidate):
            return candidate

    try:
        result = subprocess.run(
            ["cmd.exe", "/c", "where", "vivado.bat"],
            capture_output=True,
            check=False,
        )
    except OSError:
        result = None

    if result and result.returncode == 0:
        stdout_text = decode_windows_output(result.stdout)
        for line in stdout_text.splitlines():
            candidate = line.strip()
            if candidate:
                return candidate

    return DEFAULT_VIVADO_CANDIDATES[0]


DEFAULT_VIVADO_BAT = detect_vivado_bat()
PROGRESS_MARKER_PREFIX = "__FPGA_AUTO_PROGRESS__"


def print_progress(percent: int, message: str, *, completed_units: int | None = None, total_units: int | None = None) -> None:
    clamped = max(0, min(100, int(percent)))
    if completed_units is not None and total_units is not None:
        print(f"[PROGRESS {clamped}% | {completed_units}/{total_units}] {message}", flush=True)
        return
    print(f"[PROGRESS {clamped}%] {message}", flush=True)


class ProgressTracker:
    def __init__(self, total_units: int) -> None:
        self.total_units = max(1, int(total_units))
        self.completed_units = 0
        self._last_reported: tuple[int, str] | None = None

    def _emit(self, completed_units: int, message: str) -> None:
        bounded_units = max(0, min(self.total_units, int(completed_units)))
        state = (bounded_units, message)
        if state == self._last_reported:
            return
        self._last_reported = state
        self.completed_units = max(self.completed_units, bounded_units)
        percent = (bounded_units * 100) // self.total_units
        print_progress(percent, message, completed_units=bounded_units, total_units=self.total_units)

    def step(self, message: str, units: int = 1) -> None:
        self._emit(self.completed_units + units, message)

    def set_completed(self, completed_units: int, message: str) -> None:
        self._emit(completed_units, message)

    def make_subrun_callback(
        self,
        base_units: int,
        span_units: int,
        *,
        prefix: str | None = None,
    ) -> Callable[[int, int, str], None]:
        bounded_base = max(0, int(base_units))
        bounded_span = max(1, int(span_units))

        def _callback(current_units: int, total_units: int, label: str) -> None:
            bounded_total = max(1, int(total_units))
            bounded_current = max(0, min(bounded_total, int(current_units)))
            translated_units = bounded_base + min(
                bounded_span,
                round((bounded_span * bounded_current) / bounded_total),
            )
            rendered_label = f"{prefix}: {label}" if prefix else label
            self.set_completed(translated_units, rendered_label)

        return _callback


def parse_progress_marker(line: str) -> tuple[int, int, str] | None:
    stripped = line.strip()
    if not stripped.startswith(PROGRESS_MARKER_PREFIX):
        return None
    parts = stripped.split("\t", 3)
    if len(parts) != 4:
        return None
    try:
        current_units = int(parts[1])
        total_units = int(parts[2])
    except ValueError:
        return None
    return current_units, total_units, parts[3]


def relpath_posix(path: pathlib.Path, root: pathlib.Path) -> str:
    return path.resolve().relative_to(root.resolve()).as_posix()


def load_yaml(path: pathlib.Path) -> dict[str, Any]:
    return yaml.safe_load(path.read_text(encoding="utf-8")) or {}


def load_json(path: pathlib.Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}


def deep_merge(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    merged: dict[str, Any] = dict(base)
    for key, value in override.items():
        current = merged.get(key)
        if isinstance(current, dict) and isinstance(value, dict):
            merged[key] = deep_merge(current, value)
        else:
            merged[key] = value
    return merged


def unique_paths(paths: list[pathlib.Path]) -> list[pathlib.Path]:
    seen: set[str] = set()
    ordered: list[pathlib.Path] = []
    for path in paths:
        key = str(path.resolve())
        if key in seen:
            continue
        seen.add(key)
        ordered.append(path.resolve())
    return ordered


def matches_glob(value: str, patterns: list[str]) -> bool:
    return any(pathlib.PurePosixPath(value).match(pattern) for pattern in patterns)


def rank_source_file(path: pathlib.Path) -> tuple[int, str]:
    name = path.name.lower()
    is_pkg = 0 if name.endswith("_pkg.sv") or name == "rv32i_pkg.sv" else 1
    return (is_pkg, path.as_posix().lower())


def resolve_source_files(project_root: pathlib.Path, manifest: dict[str, Any]) -> list[pathlib.Path]:
    hdl = manifest.get("hdl", {})
    include_patterns = list(hdl.get("src_globs", []))
    exclude_patterns = list(hdl.get("exclude_globs", []))

    matched: list[pathlib.Path] = []
    for pattern in include_patterns:
        matched.extend(path for path in project_root.glob(pattern) if path.is_file())

    filtered: list[pathlib.Path] = []
    for path in unique_paths(matched):
        relpath = relpath_posix(path, project_root)
        if exclude_patterns and matches_glob(relpath, exclude_patterns):
            continue
        filtered.append(path)

    return sorted(filtered, key=rank_source_file)


def discover_module_names(source_files: list[pathlib.Path]) -> list[str]:
    module_names: list[str] = []
    pattern = re.compile(r"^\s*module\s+([A-Za-z_][A-Za-z0-9_$]*)\b", re.MULTILINE)
    for path in source_files:
        if path.suffix.lower() not in {".sv", ".v"}:
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        module_names.extend(match.group(1) for match in pattern.finditer(text))
    return module_names


def resolve_top_name(requested_top: str, source_files: list[pathlib.Path]) -> tuple[str, list[str]]:
    warnings: list[str] = []
    if not requested_top:
        return requested_top, warnings

    module_names = discover_module_names(source_files)
    if requested_top in module_names:
        return requested_top, warnings

    casefold_matches = [name for name in module_names if name.casefold() == requested_top.casefold()]
    if len(casefold_matches) == 1:
        resolved_top = casefold_matches[0]
        warnings.append(
            f"Manifest top `{requested_top}` did not exactly match RTL; using discovered module `{resolved_top}`."
        )
        return resolved_top, warnings

    if not module_names:
        warnings.append(f"Could not discover module names while checking top `{requested_top}`.")
    else:
        warnings.append(f"Manifest top `{requested_top}` was not found in discovered RTL modules.")
    return requested_top, warnings


def load_project_contract(
    project_root: pathlib.Path,
    *,
    profile_name: str = DEFAULT_PROFILE_NAME,
) -> dict[str, Any]:
    manifest_path = project_root / "fpga_auto.yml"
    manifest = load_yaml(manifest_path)
    profile = load_json(project_root / "tools" / profile_name)
    project_name = str(manifest.get("project", {}).get("name") or project_root.name)
    manifest_top_name = str(manifest.get("hdl", {}).get("top") or "TOP")
    part_name = str(manifest.get("vivado", {}).get("part") or "")
    source_files = resolve_source_files(project_root, manifest)
    top_name, warnings = resolve_top_name(manifest_top_name, source_files)

    return {
        "project_root": project_root.resolve(),
        "repo_root": resolve_automation_repo_root(project_root),
        "manifest_path": manifest_path.resolve(),
        "manifest": manifest,
        "profile_path": (project_root / "tools" / profile_name).resolve(),
        "profile": profile,
        "project_name": project_name,
        "manifest_top_name": manifest_top_name,
        "top_name": top_name,
        "part_name": part_name,
        "clock_port": str(profile.get("clock_port", "iClk")),
        "reset_port": str(profile.get("reset_port", "iRstn")),
        "clock_period_ns": float(profile.get("clock_period_ns", 10.0)),
        "source_files": source_files,
        "warnings": warnings,
    }


def tcl_scalar(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace("{", "\\{").replace("}", "\\}")
    return "{" + escaped + "}"


def tcl_literal(value: Any) -> str:
    if isinstance(value, dict):
        parts: list[str] = []
        for key, nested_value in value.items():
            parts.append(tcl_scalar(str(key)))
            parts.append(tcl_literal(nested_value))
        return "[dict create " + " ".join(parts) + "]"
    if isinstance(value, (list, tuple)):
        return "[list " + " ".join(tcl_literal(item) for item in value) + "]"
    if isinstance(value, bool):
        return "1" if value else "0"
    if value is None:
        return "{}"
    if isinstance(value, (int, float)):
        return str(value)
    return tcl_scalar(str(value))


def write_wrapper_tcl(
    wrapper_path: pathlib.Path,
    *,
    variables: dict[str, Any],
    source_path: pathlib.Path,
) -> None:
    lines = [f"set {name} {tcl_literal(value)}" for name, value in variables.items()]
    lines.append(f'source [file normalize "{wsl_to_windows(source_path)}"]')
    lines.append("exit")
    lines.append("")
    wrapper_path.write_text("\n".join(lines), encoding="utf-8")


def run_vivado_batch(
    *,
    project_root: pathlib.Path,
    wrapper_tcl: pathlib.Path,
    log_path: pathlib.Path,
    progress_label: str | None = None,
    progress_callback: Callable[[int, int, str], None] | None = None,
    heartbeat_seconds: int = 15,
) -> pathlib.Path:
    if (":" in DEFAULT_VIVADO_BAT or "\\" in DEFAULT_VIVADO_BAT or "/" in DEFAULT_VIVADO_BAT) and not host_path_exists(DEFAULT_VIVADO_BAT):
        raise FileNotFoundError(
            f"Vivado launcher not found: {DEFAULT_VIVADO_BAT}. "
            "Set VIVADO_BAT or install Vivado 2025.2/2025.1/2024.2/2024.1."
        )
    cmd = [
        "cmd.exe",
        "/c",
        DEFAULT_VIVADO_BAT,
        "-mode",
        "batch",
        "-nojournal",
        "-nolog",
        "-source",
        wsl_to_windows(wrapper_tcl),
    ]
    log_path.parent.mkdir(parents=True, exist_ok=True)

    with log_path.open("w", encoding="utf-8") as log_handle:
        log_handle.write(f"[INFO] Working directory: {project_root}\n")
        log_handle.write(f"[INFO] Command: {' '.join(cmd)}\n\n")
        log_handle.flush()

        if progress_label:
            print(f"[INFO] {progress_label} started. Log: {log_path}", flush=True)

        process = subprocess.Popen(
            cmd,
            cwd=project_root,
            stdout=log_handle,
            stderr=subprocess.STDOUT,
        )
        start_time = time.monotonic()
        last_heartbeat = start_time
        last_stage_label = ""
        consumed_bytes = 0
        partial_line = ""

        with log_path.open("r", encoding="utf-8", errors="ignore") as log_reader:
            while True:
                log_reader.seek(consumed_bytes)
                chunk = log_reader.read()
                if chunk:
                    consumed_bytes = log_reader.tell()
                    partial_line += chunk
                    normalized_text = partial_line.replace("\r\n", "\n").replace("\r", "\n")
                    lines = normalized_text.split("\n")
                    partial_line = lines.pop() if normalized_text and not normalized_text.endswith("\n") else ""
                    for line in lines:
                        marker = parse_progress_marker(line)
                        if marker and progress_callback:
                            current_units, total_units, stage_label = marker
                            progress_callback(current_units, total_units, stage_label)
                            last_stage_label = stage_label

                return_code = process.poll()
                if return_code is not None:
                    if partial_line:
                        marker = parse_progress_marker(partial_line)
                        if marker and progress_callback:
                            current_units, total_units, stage_label = marker
                            progress_callback(current_units, total_units, stage_label)
                            last_stage_label = stage_label
                    break

                now = time.monotonic()
                if progress_label and now - last_heartbeat >= heartbeat_seconds:
                    elapsed_seconds = int(now - start_time)
                    stage_suffix = f" Current stage: {last_stage_label}." if last_stage_label else ""
                    print(
                        f"[INFO] {progress_label} running... elapsed {elapsed_seconds}s.{stage_suffix} Log: {log_path}",
                        flush=True,
                    )
                    last_heartbeat = now
                time.sleep(1)

    if process.returncode != 0:
        if progress_label:
            print(f"[INFO] {progress_label} failed. Log: {log_path}", flush=True)
        raise RuntimeError(f"Vivado failed with exit code {process.returncode}. See {log_path}")
    if progress_label:
        elapsed_seconds = int(time.monotonic() - start_time)
        print(f"[INFO] {progress_label} completed in {elapsed_seconds}s. Log: {log_path}", flush=True)
    return log_path
