from __future__ import annotations

import argparse
import csv
import json
import pathlib
import re
import statistics
from collections import Counter
from collections.abc import Callable
from datetime import datetime
from typing import Any

from .common import (
    ProgressTracker,
    load_project_contract,
    run_vivado_batch,
    write_wrapper_tcl,
    wsl_to_windows,
)
from .execution_metrics import (
    analyze_program_trace,
    compute_runtime_speedup,
    estimate_pipeline_5stage_execution,
    estimate_single_cycle_execution,
    format_ratio,
    format_runtime_ns,
)
from .focus import find_module_source_path, parse_ansi_module_ports, render_defparam_wrapper, sanitize_token
from .integrated_report import (
    highest_status,
    merge_program_detail_section,
    render_finding_table,
    render_recommended_actions,
    shift_markdown_headings,
    status_badge,
    strip_first_markdown_heading,
    strip_noisy_report_sections,
    write_html_report,
)
from .rv32i import DEFAULT_CLASS_ORDER, classify_word, parse_asm_instructions


RESERVED_ARTIFACT_KEYS = {"actual", "hierarchical"}
VIVADO_PHASE_PROGRESS_UNITS = 3
VIVADO_TOTAL_PROGRESS_UNITS = 6
VIVADO_EXIT_ACCESS_VIOLATION = "EXCEPTION_ACCESS_VIOLATION"

PROGRAM_LIBRARY: dict[str, dict[str, pathlib.Path | str]] = {
    "full_coverage": {
        "label": "Full Coverage",
        "mem_relpath": pathlib.Path("src") / "InstructionFORTIMING.mem",
        "asm_relpath": pathlib.Path("src") / "InstructionFORTIMING.s",
    },
    "bubble_sort": {
        "label": "Bubble Sort",
        "mem_relpath": pathlib.Path("src") / "timing_programs" / "Bubble Sort.mem",
        "asm_relpath": pathlib.Path("src") / "timing_programs" / "Bubble Sort.s",
    },
}

PROGRAM_ALIASES = {
    "full_coverage": "full_coverage",
    "fullcoverage": "full_coverage",
    "full_coverage_mem": "full_coverage",
    "full_coverage_s": "full_coverage",
    "bubble_sort": "bubble_sort",
    "bubblesort": "bubble_sort",
    "bubble_sort_mem": "bubble_sort",
    "bubble_sort_s": "bubble_sort",
}
SINGLE_CYCLE_PROJECT_NAMES = {"RISCV_32I_SINGLE", "RISCV_RV32I_SINGLE"}
PIPELINE_PROJECT_CANDIDATES = ("RISCV_RV32I_5STAGE", "RISCV_32I_5STAGE")


def fmt_float(value: float | None, digits: int = 3) -> str:
    if value is None:
        return "NA"
    return f"{value:.{digits}f}"


def fmt_int(value: int | None) -> str:
    if value is None:
        return "NA"
    return str(value)


def parse_int_metric(value: Any) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)

    text = str(value).replace(",", "").strip()
    if not text or text.upper() == "NA":
        return None
    try:
        return int(float(text))
    except ValueError:
        return None


def fmt_delta_float(left: float | None, right: float | None, digits: int = 3) -> str:
    if left is None or right is None:
        return "NA"
    return f"{right - left:+.{digits}f}"


def fmt_delta_int(left: int | None, right: int | None) -> str:
    if left is None or right is None:
        return "NA"
    return f"{right - left:+d}"


def fmt_delta_ratio(left: float | None, right: float | None, digits: int = 3) -> str:
    if left is None or right is None:
        return "NA"
    return f"{right - left:+.{digits}f}x"


def determine_timing_verdict(
    *,
    wns_ns: float | None,
    failing_endpoints: int,
    health_rows: list[dict[str, str]],
) -> str:
    if wns_ns is not None and wns_ns < 0:
        return "FAIL"
    if failing_endpoints > 0:
        return "FAIL"
    if any(row["status"] != "PASS" for row in health_rows):
        return "WARN"
    return "PASS"


def describe_runtime_winner(
    single_runtime_ns: float | None,
    pipeline_runtime_ns: float | None,
) -> str:
    if single_runtime_ns is None or pipeline_runtime_ns is None:
        return "NA"
    if abs(single_runtime_ns - pipeline_runtime_ns) < 1e-9:
        return "Tie"
    if pipeline_runtime_ns < single_runtime_ns:
        return f"5-stage pipeline ({format_runtime_ns(single_runtime_ns - pipeline_runtime_ns)} faster)"
    return f"Single-cycle ({format_runtime_ns(pipeline_runtime_ns - single_runtime_ns)} faster)"


def safe_mean(values: list[float]) -> float | None:
    return statistics.mean(values) if values else None


def percentile(values: list[float], ratio: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    idx = ratio * (len(ordered) - 1)
    lo = int(idx)
    hi = min(lo + 1, len(ordered) - 1)
    frac = idx - lo
    return ordered[lo] * (1.0 - frac) + ordered[hi] * frac


def title_from_key(value: str) -> str:
    return value.replace("_", " ").title()


def unique_strings(values: list[str]) -> list[str]:
    seen: set[str] = set()
    ordered: list[str] = []
    for value in values:
        if value in seen:
            continue
        seen.add(value)
        ordered.append(value)
    return ordered


def resolve_companion_pipeline_root(project_root: pathlib.Path) -> pathlib.Path | None:
    if project_root.name not in SINGLE_CYCLE_PROJECT_NAMES:
        return None
    for candidate_name in PIPELINE_PROJECT_CANDIDATES:
        candidate = project_root.parent / candidate_name
        if candidate.exists():
            return candidate
    return None


def normalize_program_key(raw_value: str | None) -> str:
    token = (raw_value or "full_coverage").strip().lower()
    if token.endswith(".mem") or token.endswith(".s"):
        token = token.rsplit(".", 1)[0]
    token = re.sub(r"[^a-z0-9]+", "_", token).strip("_")
    return PROGRAM_ALIASES.get(token, token)


def resolve_selected_program(project_root: pathlib.Path, raw_value: str | None) -> dict[str, Any]:
    program_key = normalize_program_key(raw_value)
    if program_key not in PROGRAM_LIBRARY:
        supported = ", ".join(sorted(PROGRAM_LIBRARY))
        raise ValueError(f"Unsupported timing program `{raw_value}`. Supported values: {supported}.")

    program_cfg = PROGRAM_LIBRARY[program_key]
    mem_path = (project_root / pathlib.Path(program_cfg["mem_relpath"])).resolve()
    asm_path = (project_root / pathlib.Path(program_cfg["asm_relpath"])).resolve()
    if not mem_path.exists():
        raise FileNotFoundError(f"Timing program image was not found: {mem_path}")

    return {
        "key": program_key,
        "label": str(program_cfg["label"]),
        "mem_path": mem_path,
        "asm_path": asm_path if asm_path.exists() else None,
        "display_name": f"{program_cfg['label']}.mem",
    }


def parse_selected_instruction_program(program_selection: dict[str, Any]) -> tuple[dict[str, int], str, list[str]]:
    asm_path = pathlib.Path(program_selection["asm_path"]) if program_selection.get("asm_path") else None
    mem_path = pathlib.Path(program_selection["mem_path"]).resolve()
    class_counts = Counter({class_name: 0 for class_name in DEFAULT_CLASS_ORDER})
    warnings: list[str] = []

    if asm_path and asm_path.exists():
        instructions = parse_asm_instructions(asm_path)
        for row in instructions:
            class_counts[row["class_name"]] += 1
        return dict(class_counts), str(asm_path), warnings

    for raw_line in mem_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        token = raw_line.strip().replace("_", "")
        if not token:
            continue
        try:
            class_name = classify_word(int(token, 16))
        except ValueError:
            continue
        if class_name:
            class_counts[class_name] += 1

    warnings.append(f"{mem_path.name} was used, so mnemonic-level timing rows could not be resolved.")
    return dict(class_counts), str(mem_path), warnings


def resolve_program_output_dir(
    requested_output_dir: pathlib.Path,
    default_output_dir: pathlib.Path,
    program_key: str,
) -> pathlib.Path:
    requested_resolved = requested_output_dir.resolve()
    default_resolved = default_output_dir.resolve()
    if requested_resolved == default_resolved:
        return default_resolved / "programs" / program_key
    return requested_resolved


def prepare_program_wrapper_assets(
    contract: dict[str, Any],
    output_dir: pathlib.Path,
    program_selection: dict[str, Any],
) -> dict[str, Any]:
    wrapper_dir = output_dir / "program_wrapper"
    wrapper_dir.mkdir(parents=True, exist_ok=True)

    top_name = str(contract["top_name"])
    top_source_path = find_module_source_path(list(contract["source_files"]), top_name)
    top_ports = parse_ansi_module_ports(top_source_path.read_text(encoding="utf-8", errors="ignore"), top_name)
    wrapper_module_name = (
        "TimingProgramTop_"
        + sanitize_token(f"{contract['project_name']}_{program_selection['key']}").upper()
    )
    wrapper_path = wrapper_dir / f"{wrapper_module_name}.sv"
    wrapper_path.write_text(
        render_defparam_wrapper(
            wrapper_module_name=wrapper_module_name,
            top_name=top_name,
            top_ports=top_ports,
            clock_port=str(contract["clock_port"]),
            reset_port=str(contract["reset_port"]),
            instance_name="uDesign",
            rom_param_path="uInstrRom.P_INIT_FILE",
            mem_file_path=pathlib.Path(program_selection["mem_path"]),
        ),
        encoding="utf-8",
    )

    return {
        "wrapper_path": wrapper_path,
        "wrapper_module_name": wrapper_module_name,
        "source_files": list(contract["source_files"]) + [wrapper_path],
    }


def build_single_cycle_metadata(
    contract: dict[str, Any],
    output_dir: pathlib.Path,
    program_selection: dict[str, Any],
) -> dict[str, Any]:
    profile = contract["profile"]
    probe_families = [dict(row) for row in profile.get("probe_families", [])]
    legacy_probe_families = [dict(row) for row in profile.get("legacy_probe_families", [])]
    class_counts, instruction_source, warnings = parse_selected_instruction_program(program_selection)
    warnings = list(contract.get("warnings", [])) + warnings
    class_coverage = {class_name: count for class_name, count in class_counts.items() if count > 0}

    return {
        "analysis_mode": str(profile.get("analysis_mode", "single_cycle")),
        "isa_profile": "RV32I",
        "project_name": contract["project_name"],
        "project_root": str(contract["project_root"]),
        "manifest_path": str(contract["manifest_path"]),
        "profile_path": str(contract["profile_path"]),
        "manifest_top_name": contract.get("manifest_top_name", contract["top_name"]),
        "top_name": contract["top_name"],
        "part_name": contract["part_name"],
        "clock_port": contract["clock_port"],
        "reset_port": contract["reset_port"],
        "clock_period_ns": float(contract["clock_period_ns"]),
        "output_dir": str(output_dir.resolve()),
        "program_key": str(program_selection["key"]),
        "program_image": str(program_selection["display_name"]),
        "program_memory": str(program_selection["mem_path"]),
        "resolved_source_files": [str(path) for path in contract["source_files"]],
        "probe_families": probe_families,
        "known_probe_families": probe_families + legacy_probe_families,
        "module_alias_prefixes": dict(profile.get("module_alias_prefixes", {})),
        "module_metrics_exclude_patterns": list(profile.get("module_metrics_exclude_patterns", [])),
        "class_targets": dict(profile.get("class_targets", {})),
        "stage_candidate_map": dict(profile.get("stage_candidate_map", {})),
        "family_active_classes": dict(profile.get("family_active_classes", {})),
        "class_stage_candidate_map": dict(profile.get("class_stage_candidate_map", {})),
        "class_order": list(DEFAULT_CLASS_ORDER),
        "class_instruction_counts": class_counts,
        "class_coverage": class_coverage,
        "instruction_class_source": instruction_source,
        "warnings": warnings,
    }


def write_metadata(output_dir: pathlib.Path, metadata: dict[str, Any]) -> pathlib.Path:
    metadata_path = output_dir / "analysis_metadata.json"
    output_dir.mkdir(parents=True, exist_ok=True)
    metadata_path.write_text(json.dumps(metadata, indent=2, sort_keys=True), encoding="utf-8")
    return metadata_path


def build_wrapper_variables(
    contract: dict[str, Any],
    output_dir: pathlib.Path,
    metadata: dict[str, Any],
    *,
    source_files: list[pathlib.Path] | None = None,
    top_name: str | None = None,
    analysis_phase: str = "full",
) -> dict[str, Any]:
    family_configs = []
    for family in metadata["probe_families"]:
        family_configs.append(
            {
                "key": family["key"],
                "label": family["label"],
                "description": family["description"],
                "endpoint_patterns": list(family.get("endpoint_patterns", [])),
            }
        )

    return {
        "source_files": [wsl_to_windows(path) for path in (source_files or contract["source_files"])],
        "output_dir": wsl_to_windows(output_dir),
        "repo_root": wsl_to_windows(contract["repo_root"]),
        "part_name": contract["part_name"],
        "top_name": top_name or contract["top_name"],
        "clock_port": contract["clock_port"],
        "reset_port": contract["reset_port"],
        "clk_period_ns": float(contract["clock_period_ns"]),
        "analysis_phase": analysis_phase,
        "family_configs": family_configs,
        "module_metric_exclude_patterns": metadata.get("module_metrics_exclude_patterns", []),
    }


def append_vivado_log_section(
    combined_log_path: pathlib.Path,
    *,
    title: str,
    source_log_path: pathlib.Path,
) -> None:
    if not source_log_path.exists():
        return

    combined_log_path.parent.mkdir(parents=True, exist_ok=True)
    content = source_log_path.read_text(encoding="utf-8", errors="ignore")
    with combined_log_path.open("a", encoding="utf-8") as handle:
        if handle.tell():
            handle.write("\n")
        handle.write(f"===== {title} =====\n")
        handle.write(content)
        if content and not content.endswith("\n"):
            handle.write("\n")


def expected_actual_phase_artifacts(output_dir: pathlib.Path, metadata: dict[str, Any]) -> list[pathlib.Path]:
    artifacts = [
        output_dir / "actual_timing_summary.rpt",
        output_dir / "actual_timing_top100.rpt",
        output_dir / "actual_timing_paths.tsv",
        output_dir / "actual_high_fanout.rpt",
        output_dir / "actual_utilization.rpt",
        output_dir / "actual_methodology.rpt",
        output_dir / "actual_qor_suggestions.rpt",
        output_dir / "actual_fanout_nets.tsv",
    ]
    for family in metadata.get("probe_families", []):
        artifact_key = str(family.get("artifact_key", family["key"]))
        artifacts.append(output_dir / f"{artifact_key}_timing_top20.rpt")
        artifacts.append(output_dir / f"{artifact_key}_timing_paths.tsv")
    return artifacts


def expected_hierarchical_phase_artifacts(output_dir: pathlib.Path) -> list[pathlib.Path]:
    return [
        output_dir / "hierarchical_utilization.rpt",
        output_dir / "hierarchical_timing_top20.rpt",
        output_dir / "module_metrics.tsv",
    ]


def vivado_exit_crash_is_tolerable(
    *,
    log_path: pathlib.Path,
    completion_marker: str,
    expected_artifacts: list[pathlib.Path],
) -> bool:
    if not log_path.exists():
        return False
    log_text = log_path.read_text(encoding="utf-8", errors="ignore")
    if completion_marker not in log_text:
        return False
    if VIVADO_EXIT_ACCESS_VIOLATION not in log_text:
        return False
    if "# exit" not in log_text and "Exiting Vivado" not in log_text:
        return False
    return all(path.exists() for path in expected_artifacts)


def maybe_tolerate_vivado_exit_crash(
    *,
    phase_label: str,
    log_path: pathlib.Path,
    completion_marker: str,
    expected_artifacts: list[pathlib.Path],
) -> bool:
    if not vivado_exit_crash_is_tolerable(
        log_path=log_path,
        completion_marker=completion_marker,
        expected_artifacts=expected_artifacts,
    ):
        return False

    print(
        f"[WARN] Vivado {phase_label} exited abnormally after writing all requested artifacts. "
        f"Continuing with collected results from {log_path}.",
        flush=True,
    )
    return True


def make_phase_progress_callback(
    progress_callback: Callable[[int, int, str], None] | None,
    *,
    phase_base_units: int,
    phase_label: str,
) -> Callable[[int, int, str], None] | None:
    if progress_callback is None:
        return None

    def _callback(current_units: int, total_units: int, label: str) -> None:
        bounded_total = max(1, int(total_units))
        bounded_current = max(0, min(bounded_total, int(current_units)))
        translated_units = phase_base_units + min(
            VIVADO_PHASE_PROGRESS_UNITS,
            round((VIVADO_PHASE_PROGRESS_UNITS * bounded_current) / bounded_total),
        )
        progress_callback(translated_units, VIVADO_TOTAL_PROGRESS_UNITS, f"{phase_label}: {label}")

    return _callback


def run_vivado(
    project_root: pathlib.Path,
    output_dir: pathlib.Path,
    contract: dict[str, Any],
    metadata: dict[str, Any],
    *,
    program_selection: dict[str, Any] | None = None,
    progress_callback: Callable[[int, int, str], None] | None = None,
) -> pathlib.Path:
    tools_dir = project_root / "tools"
    actual_wrapper_tcl = output_dir / "run_single_cycle_perf_actual_wrapper.tcl"
    hierarchical_wrapper_tcl = output_dir / "run_single_cycle_perf_hierarchical_wrapper.tcl"
    actual_log_path = output_dir / "vivado_actual.log"
    hierarchical_log_path = output_dir / "vivado_hierarchical.log"
    combined_log_path = output_dir / "vivado_run.log"
    if combined_log_path.exists():
        combined_log_path.unlink()
    source_files = list(contract["source_files"])
    top_name = str(contract["top_name"])
    if program_selection is not None:
        wrapper_assets = prepare_program_wrapper_assets(contract, output_dir, program_selection)
        source_files = list(wrapper_assets["source_files"])
        top_name = str(wrapper_assets["wrapper_module_name"])

    write_wrapper_tcl(
        actual_wrapper_tcl,
        variables=build_wrapper_variables(
            contract,
            output_dir,
            metadata,
            source_files=source_files,
            top_name=top_name,
            analysis_phase="actual_only",
        ),
        source_path=tools_dir / "single_cycle_perf_collect.tcl",
    )
    try:
        run_vivado_batch(
            project_root=project_root,
            wrapper_tcl=actual_wrapper_tcl,
            log_path=actual_log_path,
            progress_label=f"Vivado single-cycle actual timing run for {contract['project_name']}",
            progress_callback=make_phase_progress_callback(
                progress_callback,
                phase_base_units=0,
                phase_label="Actual timing",
            ),
        )
    except RuntimeError:
        if not maybe_tolerate_vivado_exit_crash(
            phase_label="actual timing",
            log_path=actual_log_path,
            completion_marker="Completed single-cycle timing artifacts",
            expected_artifacts=expected_actual_phase_artifacts(output_dir, metadata),
        ):
            raise
    finally:
        append_vivado_log_section(
            combined_log_path,
            title="Actual Timing Run",
            source_log_path=actual_log_path,
        )

    write_wrapper_tcl(
        hierarchical_wrapper_tcl,
        variables=build_wrapper_variables(
            contract,
            output_dir,
            metadata,
            source_files=source_files,
            top_name=top_name,
            analysis_phase="hierarchical_only",
        ),
        source_path=tools_dir / "single_cycle_perf_collect.tcl",
    )
    try:
        run_vivado_batch(
            project_root=project_root,
            wrapper_tcl=hierarchical_wrapper_tcl,
            log_path=hierarchical_log_path,
            progress_label=f"Vivado single-cycle hierarchical timing run for {contract['project_name']}",
            progress_callback=make_phase_progress_callback(
                progress_callback,
                phase_base_units=VIVADO_PHASE_PROGRESS_UNITS,
                phase_label="Hierarchical timing",
            ),
        )
    except RuntimeError:
        if not maybe_tolerate_vivado_exit_crash(
            phase_label="hierarchical timing",
            log_path=hierarchical_log_path,
            completion_marker="Completed hierarchical analysis artifacts",
            expected_artifacts=expected_hierarchical_phase_artifacts(output_dir),
        ):
            raise
    finally:
        append_vivado_log_section(
            combined_log_path,
            title="Hierarchical Timing Run",
            source_log_path=hierarchical_log_path,
        )

    return combined_log_path


def parse_timing_paths_tsv(path: pathlib.Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            if not row.get("index"):
                continue
            max_fanout_raw = row.get("max_fanout", "").strip()
            rows.append(
                {
                    "index": int(row["index"]),
                    "slack_ns": float(row["slack_ns"]),
                    "min_period_ns": float(row["min_period_ns"]),
                    "datapath_delay_ns": float(row["datapath_delay_ns"]),
                    "logic_delay_ns": float(row["logic_delay_ns"]),
                    "net_delay_ns": float(row["net_delay_ns"]),
                    "route_share_pct": float(row["route_share_pct"]),
                    "logic_share_pct": float(row["logic_share_pct"]),
                    "logic_levels": int(float(row["logic_levels"])),
                    "max_fanout": int(float(max_fanout_raw)) if max_fanout_raw else 0,
                    "start_pin": row["start_pin"],
                    "end_pin": row["end_pin"],
                    "path_name": row["path_name"],
                }
            )
    return rows


def parse_timing_summary(path: pathlib.Path) -> dict[str, float]:
    lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    result: dict[str, float] = {}
    for idx, line in enumerate(lines):
        if "WNS(ns)" not in line or "TNS(ns)" not in line:
            continue
        for look_ahead in range(idx + 1, min(idx + 8, len(lines))):
            candidate = lines[look_ahead].strip()
            match = re.match(r"([-\d.]+)\s+([-\d.]+)\s+\d+\s+\d+\s+([-\d.]+)\s+([-\d.]+)", candidate)
            if not match:
                continue
            result["wns_ns"] = float(match.group(1))
            result["tns_ns"] = float(match.group(2))
            result["wpws_ns"] = float(match.group(3))
            result["tpws_ns"] = float(match.group(4))
            break
        if "wns_ns" in result:
            break

    for line in lines:
        match = re.search(r"Setup\s*:\s*(\d+)\s*Failing Endpoints", line)
        if match:
            result["setup_failing_endpoints"] = float(match.group(1))
            break
    return result


def parse_post_route_min_period(path: pathlib.Path, clock_period_ns: float) -> float | None:
    if not path.exists():
        return None

    lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    for idx, line in enumerate(lines):
        if "WNS(ns)" not in line or "TNS(ns)" not in line:
            continue
        for look_ahead in range(idx + 1, min(idx + 8, len(lines))):
            candidate = lines[look_ahead].strip()
            match = re.match(r"([-\d.]+)\s+([-\d.]+)\s+\d+\s+\d+\s+([-\d.]+)\s+([-\d.]+)", candidate)
            if not match:
                continue
            return float(clock_period_ns) - float(match.group(1))
    return None


def resolve_existing_output_dir(preferred_dir: pathlib.Path, legacy_dir: pathlib.Path) -> pathlib.Path:
    if (preferred_dir / "post_route_timing_summary.rpt").exists():
        return preferred_dir
    if (legacy_dir / "post_route_timing_summary.rpt").exists():
        return legacy_dir
    if (preferred_dir / "actual_timing_summary.rpt").exists():
        return preferred_dir
    if (legacy_dir / "actual_timing_summary.rpt").exists():
        return legacy_dir
    return preferred_dir


def resolve_pipeline_reference_metrics(
    project_root: pathlib.Path,
    program_key: str,
) -> dict[str, Any] | None:
    pipeline_root = resolve_companion_pipeline_root(project_root)
    if pipeline_root is None:
        return None

    pipeline_contract = load_project_contract(pipeline_root)
    pipeline_profile = pipeline_contract["profile"]
    default_output_root = pipeline_root / str(pipeline_profile.get("default_output_root", ".analysis/pipeline_perf"))
    preferred_output_dir = default_output_root / "programs" / program_key / "pipeline"
    legacy_output_dir = default_output_root / "pipeline"
    output_dir = resolve_existing_output_dir(preferred_output_dir, legacy_output_dir)

    summary_path = output_dir / "post_route_timing_summary.rpt"
    summary_text = summary_path.read_text(encoding="utf-8", errors="ignore") if summary_path.exists() else ""
    wns_ns = None
    min_period_ns = None
    for idx, line in enumerate(summary_text.splitlines()):
        if "WNS(ns)" not in line or "TNS(ns)" not in line:
            continue
        for look_ahead in range(idx + 1, min(idx + 8, len(summary_text.splitlines()))):
            candidate = summary_text.splitlines()[look_ahead].strip()
            match = re.match(r"([-\d.]+)\s+([-\d.]+)\s+\d+\s+\d+\s+([-\d.]+)\s+([-\d.]+)", candidate)
            if not match:
                continue
            wns_ns = float(match.group(1))
            min_period_ns = float(pipeline_contract["clock_period_ns"]) - float(match.group(1))
            break
        if min_period_ns is not None:
            break
    if min_period_ns is None:
        min_period_ns = parse_post_route_min_period(
            summary_path,
            float(pipeline_contract["clock_period_ns"]),
        )
    if min_period_ns is None and not summary_path.exists():
        return None

    pipeline_util_summary = parse_actual_utilization(output_dir / "post_route_utilization.rpt")

    return {
        "project_name": str(pipeline_contract["project_name"]),
        "output_dir": output_dir,
        "wns_ns": wns_ns,
        "min_period_ns": min_period_ns,
        "lut_used": parse_int_metric(pipeline_util_summary.get("slice_luts")),
        "ff_used": parse_int_metric(pipeline_util_summary.get("slice_regs")),
    }


def resolve_integrated_report_path(project_root: pathlib.Path) -> pathlib.Path | None:
    pipeline_root = resolve_companion_pipeline_root(project_root)
    if pipeline_root is None:
        return None

    pipeline_contract = load_project_contract(pipeline_root)
    pipeline_profile = pipeline_contract["profile"]
    return (pipeline_root / str(pipeline_profile.get("integrated_report_path", "md/INTEGRATED_TIMING_REPORT.md"))).resolve()


def build_integrated_single_cycle_detail_text(
    report_text: str,
    *,
    project_name: str,
    artifact_dir: pathlib.Path,
    report_path: pathlib.Path,
) -> str:
    compact_body = strip_noisy_report_sections(strip_first_markdown_heading(report_text))
    detail_body = shift_markdown_headings(compact_body, 2).rstrip()
    generated_at = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
    lines = [
        f"- Source project: `{project_name}`",
        f"- Source artifacts: `{artifact_dir.as_posix()}`",
        f"- Standalone report path: `{report_path.as_posix()}`",
        f"- Detail updated: `{generated_at}`",
        "",
    ]
    if detail_body:
        lines.append(detail_body)
    else:
        lines.append("- No single-cycle optimization detail was rendered.")
    return "\n".join(lines).rstrip() + "\n"


def parse_high_fanout_report(path: pathlib.Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        match = re.match(r"\|\s*(.+?)\s*\|\s*(\d+)\s*\|\s*([A-Za-z0-9_]+)\s*\|", line)
        if not match:
            continue
        net_name = match.group(1).strip()
        if net_name in {"Net Name", "Command", "Design", "Device"} or net_name.startswith("+"):
            continue
        rows.append(
            {
                "rank": len(rows) + 1,
                "net_name": net_name,
                "fanout_count": int(match.group(2)),
                "driver_type": match.group(3),
            }
        )
    return rows


def parse_module_metrics_tsv(path: pathlib.Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            rows.append(
                {
                    "instance": row["instance"],
                    "total_prim_cells": int(row["total_prim_cells"]),
                    "ff_count": int(row["ff_count"]),
                    "lut_count": int(row["lut_count"]),
                    "carry_count": int(row["carry_count"]),
                    "ram_count": int(row["ram_count"]),
                    "muxf_count": int(row["muxf_count"]),
                    "other_count": int(row["other_count"]),
                }
            )
    return rows


def parse_actual_utilization(path: pathlib.Path) -> dict[str, int]:
    text = path.read_text(encoding="utf-8", errors="ignore")
    patterns = {
        "slice_luts": r"\|\s*Slice LUTs\*?\s*\|\s*(\d+)\s*\|",
        "logic_luts": r"\|\s*LUT as Logic\s*\|\s*(\d+)\s*\|",
        "lutram": r"\|\s*LUT as Memory\s*\|\s*(\d+)\s*\|",
        "distributed_ram": r"\|\s*LUT as Distributed RAM\s*\|\s*(\d+)\s*\|",
        "slice_regs": r"\|\s*Slice Registers\s*\|\s*(\d+)\s*\|",
        "f7_mux": r"\|\s*F7 Muxes\s*\|\s*(\d+)\s*\|",
        "f8_mux": r"\|\s*F8 Muxes\s*\|\s*(\d+)\s*\|",
        "bram_tile": r"\|\s*Block RAM Tile\s*\|\s*(\d+)\s*\|",
        "dsp": r"\|\s*DSPs\s*\|\s*(\d+)\s*\|",
        "bonded_iob": r"\|\s*Bonded IOB\s*\|\s*(\d+)\s*\|",
        "bufgctrl": r"\|\s*BUFGCTRL\s*\|\s*(\d+)\s*\|",
    }
    result: dict[str, int] = {}
    for key, pattern in patterns.items():
        match = re.search(pattern, text)
        if match:
            result[key] = int(match.group(1))
    return result


def parse_instance_areas_from_log(path: pathlib.Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    rows: list[dict[str, Any]] = []
    in_table = False
    for line in lines:
        if "Report Instance Areas" in line:
            in_table = True
            continue
        if not in_table:
            continue
        if in_table and line.startswith("---------------------------------------------------------------------------------"):
            if rows:
                break
            continue
        match = re.match(r"\|\s*\d+\s*\|\s*(.+?)\s*\|\s*(.*?)\s*\|\s*(\d+)\s*\|", line)
        if not match:
            continue
        rows.append(
            {
                "instance": match.group(1).strip(),
                "module": match.group(2).strip() or "(top)",
                "cells": int(match.group(3)),
            }
        )
    return rows


def parse_methodology_report(path: pathlib.Path) -> dict[str, Any]:
    if not path.exists():
        return {"severity_counts": {}, "rules": [], "examples": []}
    text = path.read_text(encoding="utf-8", errors="ignore")
    severity_counts: Counter[str] = Counter()
    rules: list[dict[str, Any]] = []
    examples: list[dict[str, str]] = []

    for line in text.splitlines():
        match = re.match(r"\|\s*(TIMING-\d+)\s*\|\s*([A-Za-z ]+)\s*\|\s*(.+?)\s*\|\s*(\d+)\s*\|", line)
        if not match:
            continue
        severity = match.group(2).strip()
        count = int(match.group(4))
        rules.append(
            {
                "rule": match.group(1),
                "severity": severity,
                "description": match.group(3).strip(),
                "violations": count,
            }
        )
        severity_counts[severity] += count

    lines = text.splitlines()
    idx = 0
    while idx < len(lines):
        line = lines[idx].strip()
        header_match = re.match(r"(TIMING-\d+#\d+)\s+([A-Za-z ]+)", line)
        if not header_match:
            idx += 1
            continue
        description = lines[idx + 1].strip() if idx + 1 < len(lines) else ""
        detail = ""
        for look_ahead in range(idx + 2, min(idx + 7, len(lines))):
            candidate = lines[look_ahead].strip()
            if candidate.startswith("There is "):
                detail = candidate
                break
        examples.append(
            {
                "instance": header_match.group(1),
                "severity": header_match.group(2).strip(),
                "description": description,
                "detail": detail,
            }
        )
        if len(examples) >= 5:
            break
        idx += 1

    return {"severity_counts": dict(severity_counts), "rules": rules, "examples": examples}


def parse_qor_suggestions(path: pathlib.Path) -> list[str]:
    if not path.exists():
        return []
    suggestions: list[str] = []
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        if not line.startswith("|"):
            continue
        cols = [part.strip() for part in line.strip().strip("|").split("|")]
        if len(cols) != 10:
            continue
        if cols[0] in {"Name", ""}:
            continue
        suggestions.append(f"{cols[0]} ({cols[2]}): {cols[8]}")
    return suggestions


def has_family_artifact(output_dir: pathlib.Path, artifact_key: str) -> bool:
    return (output_dir / f"{artifact_key}_timing_paths.tsv").exists() or (output_dir / f"{artifact_key}_timing_top20.rpt").exists()


def resolve_family_configs(output_dir: pathlib.Path, metadata: dict[str, Any]) -> list[dict[str, Any]]:
    configured = [dict(row) for row in metadata.get("probe_families", [])]
    known = [dict(row) for row in metadata.get("known_probe_families", configured)]
    rows = list(configured)
    seen_keys = {row["key"] for row in rows}

    for family in known:
        aliases = unique_strings([str(family.get("artifact_key", family["key"]))] + list(family.get("artifact_aliases", [])))
        if family["key"] in seen_keys:
            continue
        if any(has_family_artifact(output_dir, alias) for alias in aliases):
            rows.append(family)
            seen_keys.add(family["key"])

    matched_artifacts: set[str] = set()
    for family in rows:
        matched_artifacts.update(unique_strings([str(family.get("artifact_key", family["key"]))] + list(family.get("artifact_aliases", []))))

    for path in sorted(output_dir.glob("*_timing_paths.tsv")):
        artifact_key = path.name.removesuffix("_timing_paths.tsv")
        if artifact_key in RESERVED_ARTIFACT_KEYS:
            continue
        if artifact_key in matched_artifacts:
            continue
        rows.append(
            {
                "key": artifact_key,
                "label": title_from_key(artifact_key),
                "description": f"Auto-discovered timing family `{artifact_key}`",
                "artifact_key": artifact_key,
                "artifact_aliases": [artifact_key],
                "end_match_tokens": [],
            }
        )
        matched_artifacts.add(artifact_key)

    return rows


def parse_family_timing_rows(output_dir: pathlib.Path, metadata: dict[str, Any]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for config in resolve_family_configs(output_dir, metadata):
        candidate_keys = unique_strings(
            [str(config.get("artifact_key", config["key"]))] + list(config.get("artifact_aliases", []))
        )
        chosen_key = None
        timing_rows: list[dict[str, Any]] = []
        first_existing_key = None
        for candidate_key in candidate_keys:
            tsv_path = output_dir / f"{candidate_key}_timing_paths.tsv"
            if not tsv_path.exists():
                continue
            if first_existing_key is None:
                first_existing_key = candidate_key
            parsed_rows = parse_timing_paths_tsv(tsv_path)
            if parsed_rows:
                chosen_key = candidate_key
                timing_rows = parsed_rows
                break
        if chosen_key is None and first_existing_key is not None:
            chosen_key = first_existing_key
            timing_rows = parse_timing_paths_tsv(output_dir / f"{chosen_key}_timing_paths.tsv")
        chosen_key = chosen_key or str(config.get("artifact_key", config["key"]))
        report_path = output_dir / f"{chosen_key}_timing_top20.rpt"
        worst_path = timing_rows[0] if timing_rows else None
        min_period_ns = float(worst_path["min_period_ns"]) if worst_path else None
        fmax_mhz = 1000.0 / min_period_ns if min_period_ns and min_period_ns > 0 else None
        rows.append(
            {
                "key": config["key"],
                "label": config["label"],
                "description": config["description"],
                "artifact_key": chosen_key,
                "tsv_path": output_dir / f"{chosen_key}_timing_paths.tsv",
                "report_path": report_path,
                "path_count": len(timing_rows),
                "worst_path": worst_path,
                "min_period_ns": min_period_ns,
                "fmax_mhz": fmax_mhz,
            }
        )
    return rows


def module_from_name(name: str) -> str:
    token = name.strip()
    if "/" in token:
        return token.split("/", 1)[0]
    return token


def map_resource_to_module(resource: str, metadata: dict[str, Any]) -> str | None:
    if not resource:
        return None
    token = resource.strip()

    for family in metadata.get("known_probe_families", []):
        for match_token in family.get("end_match_tokens", []):
            if match_token and match_token in token:
                return family["label"]

    for label, prefixes in metadata.get("module_alias_prefixes", {}).items():
        if any(token.startswith(prefix) for prefix in prefixes):
            return label

    lowered = token.lower()
    if "regfile" in lowered:
        return "Regfile"
    if "instr" in lowered and "rom" in lowered:
        return "InstrRom"
    if "nextpc" in lowered:
        return "NextPcGen"
    if "pctarget" in lowered:
        return "PcTargetGen"
    if "trap" in lowered:
        return "CoreTrapGate"
    if "branch" in lowered and "decoder" not in lowered:
        return "BranchComparator"
    if "aluoperandsel" in lowered:
        return "AluOperandSel"
    if "alu" in lowered and "decoder" not in lowered:
        return "Alu"
    if "immgen" in lowered or "addrimm" in lowered:
        return "ImmGen"
    if "dataram" in lowered or "memram" in lowered:
        return "DataRam"
    if "control" in lowered or "decoder" in lowered:
        return "ControlUnit"
    if "datapath" in lowered:
        return "Datapath"
    if token.startswith("oTimingProbe") or token.startswith("oTimingProbe_OBUF"):
        return "TimingProbeSink"
    if "upc/" in lowered or lowered.startswith("upc"):
        return "Pc"
    return None


def pin_to_module(pin_name: str, metadata: dict[str, Any]) -> str:
    mapped = map_resource_to_module(pin_name, metadata)
    return mapped or "Other"


def parse_top_timing_report(path: pathlib.Path, metadata: dict[str, Any]) -> list[dict[str, Any]]:
    lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    paths: list[dict[str, Any]] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line.startswith("Slack ("):
            i += 1
            continue

        entry: dict[str, Any] = {
            "slack_ns": None,
            "source": None,
            "destination": None,
            "datapath_delay_ns": None,
            "logic_levels": None,
            "modules": [],
        }
        match = re.search(r":\s*([-\d.]+)ns", line)
        if match:
            entry["slack_ns"] = float(match.group(1))

        modules: list[str] = []
        j = i + 1
        while j < len(lines):
            current = lines[j]
            if j > i + 1 and current.startswith("Slack ("):
                break
            stripped = current.strip()
            if stripped.startswith("Source:"):
                entry["source"] = stripped.split("Source:", 1)[1].strip()
            elif stripped.startswith("Destination:"):
                entry["destination"] = stripped.split("Destination:", 1)[1].strip()
            elif stripped.startswith("Data Path Delay:"):
                match = re.search(r"Data Path Delay:\s*([-\d.]+)ns", stripped)
                if match:
                    entry["datapath_delay_ns"] = float(match.group(1))
            elif stripped.startswith("Logic Levels:"):
                match = re.search(r"Logic Levels:\s*(\d+)", stripped)
                if match:
                    entry["logic_levels"] = int(match.group(1))
            elif "Path(ns)" not in current and "Location" not in current:
                tokens = stripped.split()
                if not tokens:
                    j += 1
                    continue
                resource = tokens[-1]
                module_name = map_resource_to_module(resource, metadata)
                if module_name and (not modules or modules[-1] != module_name):
                    modules.append(module_name)
            j += 1

        entry["modules"] = modules
        paths.append(entry)
        i = j

    return paths


def end_family(end_pin: str, metadata: dict[str, Any]) -> str:
    for family in metadata.get("known_probe_families", []):
        for token in family.get("end_match_tokens", []):
            if token and token in end_pin:
                return family["label"]
    if "uDatapath/uRegfile/" in end_pin and end_pin.endswith("/CE"):
        return "Regfile CE"
    if "uDatapath/uRegfile/" in end_pin and end_pin.endswith("/D"):
        return "Regfile D"
    if "uPc/" in end_pin and end_pin.endswith("/CE"):
        return "Pc CE"
    if "oTimingProbe" in end_pin:
        return "Timing Probe"
    if end_pin.endswith("/CE"):
        return "Generic CE"
    if end_pin.endswith("/D"):
        return "Generic D"
    return "Other"


def path_bucket(modules: list[str], end_pin: str, metadata: dict[str, Any]) -> str:
    module_set = set(modules)
    end_module = pin_to_module(end_pin, metadata)
    if "DataRam" in module_set and "Regfile" in module_set:
        return "DataRam Readback To Regfile D"
    if "DataRam" in module_set and "CoreTrapGate" in module_set and end_pin.endswith("/CE"):
        return "Memory + Trap Enable"
    if "BranchComparator" in module_set or "NextPcGen" in module_set:
        return "Branch / Next-PC"
    if "CoreTrapGate" in module_set and end_module == "Pc":
        return "Trap To PC"
    if "ImmGen" in module_set and "Alu" in module_set and end_pin.endswith("/D"):
        return "ALU Writeback"
    if "InstrRom" in module_set and "Alu" in module_set:
        return "Decode / ALU"
    if end_pin.endswith("/CE"):
        return "Control Enable"
    return "Other"


def exact_signature(modules: list[str], end_pin: str, metadata: dict[str, Any]) -> str:
    module_set = set(modules)
    if "Pc" in module_set and "DataRam" in module_set and "Regfile" in module_set and end_family(end_pin, metadata) == "Regfile D":
        return "Pc -> decode/control -> DataRam readback -> Regfile D"
    if not modules:
        return f"Unknown -> {end_family(end_pin, metadata)}"
    return " -> ".join(modules + [end_family(end_pin, metadata)])


def fanout_display_rows(rows: list[dict[str, Any]], limit: int = 10) -> list[dict[str, Any]]:
    filtered = []
    skip_tokens = ("clk", "rst", "reset")
    for row in rows:
        net_name = str(row["net_name"]).lower()
        if any(token in net_name for token in skip_tokens):
            continue
        filtered.append(row)
    return filtered[:limit]


def write_artifact_manifest(output_dir: pathlib.Path, family_rows: list[dict[str, Any]]) -> pathlib.Path:
    manifest_path = output_dir / "artifact_manifest.json"
    payload = {
        "families": [
            {
                "key": row["key"],
                "label": row["label"],
                "artifact_key": row["artifact_key"],
                "path_count": row["path_count"],
                "tsv_path": str(row["tsv_path"]),
                "report_path": str(row["report_path"]),
            }
            for row in family_rows
        ]
    }
    manifest_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    return manifest_path


def build_report(output_dir: pathlib.Path, report_path: pathlib.Path, metadata: dict[str, Any]) -> str:
    timing_summary = parse_timing_summary(output_dir / "actual_timing_summary.rpt")
    timing_paths = parse_timing_paths_tsv(output_dir / "actual_timing_paths.tsv")
    fanout_rows = parse_high_fanout_report(output_dir / "actual_high_fanout.rpt")
    module_rows = parse_module_metrics_tsv(output_dir / "module_metrics.tsv")
    top100_paths = parse_top_timing_report(output_dir / "actual_timing_top100.rpt", metadata)
    family_timing_rows = parse_family_timing_rows(output_dir, metadata)
    util_summary = parse_actual_utilization(output_dir / "actual_utilization.rpt")
    instance_area_rows = parse_instance_areas_from_log(output_dir / "vivado_run.log")
    methodology_report = parse_methodology_report(output_dir / "actual_methodology.rpt")
    qor_suggestions = parse_qor_suggestions(output_dir / "actual_qor_suggestions.rpt")

    if not timing_paths:
        raise RuntimeError(f"No timing paths were parsed from {output_dir / 'actual_timing_paths.tsv'}")

    worst_path = timing_paths[0]
    wns_ns = timing_summary.get("wns_ns", float(worst_path["slack_ns"]))
    tns_ns = timing_summary.get("tns_ns")
    min_period_ns = float(worst_path["min_period_ns"])
    fmax_mhz = 1000.0 / min_period_ns if min_period_ns > 0 else None
    program_mem_path = pathlib.Path(str(metadata["program_memory"]))
    trace_summary = analyze_program_trace(program_mem_path)
    single_execution = estimate_single_cycle_execution(trace_summary, min_period_ns)
    pipeline_reference = resolve_pipeline_reference_metrics(
        pathlib.Path(str(metadata["project_root"])),
        str(metadata["program_key"]),
    )
    pipeline_execution = estimate_pipeline_5stage_execution(
        trace_summary,
        pipeline_reference["min_period_ns"] if pipeline_reference is not None else None,
    )
    failing_endpoints = int(timing_summary.get("setup_failing_endpoints", 0))
    available_family_rows = [row for row in family_timing_rows if row["worst_path"]]
    worst_family_row = max(available_family_rows, key=lambda row: float(row["min_period_ns"])) if available_family_rows else None

    route_shares = [float(row["route_share_pct"]) for row in timing_paths]
    logic_levels = [float(row["logic_levels"]) for row in timing_paths]
    max_fanouts = [float(row["max_fanout"]) for row in timing_paths]
    slacks = [float(row["slack_ns"]) for row in timing_paths]
    datapath_delays = [float(row["datapath_delay_ns"]) for row in timing_paths]
    logic_delays = [float(row["logic_delay_ns"]) for row in timing_paths]
    net_delays = [float(row["net_delay_ns"]) for row in timing_paths]
    ce_end_count = sum(1 for row in timing_paths if str(row["end_pin"]).endswith("/CE"))
    d_end_count = sum(1 for row in timing_paths if str(row["end_pin"]).endswith("/D"))
    route_dominant_count = sum(1 for row in timing_paths if float(row["route_share_pct"]) >= 70.0)
    severe_route_count = sum(1 for row in timing_paths if float(row["route_share_pct"]) >= 75.0)
    repeated_path_ratio = 0.0

    endpoint_counter = Counter(end_family(str(row["end_pin"]), metadata) for row in timing_paths)
    start_end_counter = Counter()
    bucket_counter = Counter()
    signature_counter = Counter()
    module_presence_counter = Counter()
    bucket_worst_slack: dict[str, float] = {}
    signature_worst_slack: dict[str, float] = {}
    module_worst_slack: dict[str, float] = {}
    module_slack_sum: Counter[str] = Counter()

    for row in timing_paths:
        start_end_counter[(pin_to_module(str(row["start_pin"]), metadata), pin_to_module(str(row["end_pin"]), metadata))] += 1

    for path in top100_paths:
        modules = list(path["modules"])
        end_pin = str(path["destination"] or "")
        bucket = path_bucket(modules, end_pin, metadata)
        signature = exact_signature(modules, end_pin, metadata)
        slack_ns = float(path["slack_ns"] or 0.0)
        bucket_counter[bucket] += 1
        signature_counter[signature] += 1
        bucket_worst_slack[bucket] = min(bucket_worst_slack.get(bucket, slack_ns), slack_ns)
        signature_worst_slack[signature] = min(signature_worst_slack.get(signature, slack_ns), slack_ns)
        for module_name in set(modules):
            module_presence_counter[module_name] += 1
            module_slack_sum[module_name] += abs(slack_ns)
            module_worst_slack[module_name] = min(module_worst_slack.get(module_name, slack_ns), slack_ns)

    if signature_counter:
        repeated_path_ratio = max(signature_counter.values()) / max(1, len(top100_paths))

    module_rows_sorted = sorted(module_rows, key=lambda row: row["total_prim_cells"], reverse=True)
    largest_modules = [row for row in module_rows_sorted if row["total_prim_cells"] > 0][:12]
    top_non_clock_fanout = fanout_display_rows(fanout_rows, limit=12)
    methodology_rules = list(methodology_report["rules"])
    methodology_examples = list(methodology_report["examples"])
    methodology_severity_counts = dict(methodology_report["severity_counts"])

    signature_rows = sorted(signature_counter.items(), key=lambda item: (-item[1], signature_worst_slack[item[0]]))[:12]
    bucket_rows = sorted(bucket_counter.items(), key=lambda item: (-item[1], bucket_worst_slack[item[0]]))
    hot_module_rows = sorted(module_presence_counter.items(), key=lambda item: (-item[1], module_worst_slack[item[0]]))[:12]
    start_end_rows = sorted(start_end_counter.items(), key=lambda item: (-item[1], item[0][0], item[0][1]))[:12]
    instance_area_top = [row for row in instance_area_rows if row["instance"] != "top"][:12]
    avg_route_share = safe_mean(route_shares)

    health_rows = [
        {"check": "Manifest loaded", "status": "PASS", "detail": metadata["manifest_path"]},
        {"check": "Profile loaded", "status": "PASS" if pathlib.Path(metadata["profile_path"]).exists() else "WARN", "detail": metadata["profile_path"]},
        {"check": "Resolved source files", "status": "PASS" if metadata["resolved_source_files"] else "FAIL", "detail": str(len(metadata["resolved_source_files"]))},
        {"check": "Probe families", "status": "PASS" if metadata["probe_families"] else "WARN", "detail": str(len(metadata["probe_families"]))},
        {"check": "Instruction-class source", "status": "PASS" if metadata["instruction_class_source"] != "NA" else "WARN", "detail": metadata["instruction_class_source"]},
    ]
    missing_family_count = sum(1 for row in family_timing_rows if not row["worst_path"])
    if missing_family_count:
        health_rows.append({"check": "Missing endpoints", "status": "WARN", "detail": str(missing_family_count)})
    for warning in metadata.get("warnings", []):
        health_rows.append({"check": "Metadata warning", "status": "WARN", "detail": warning})

    priorities: list[tuple[str, str]] = []
    if avg_route_share is not None and avg_route_share >= 70.0:
        priorities.append(
            (
                "Route-Dominant Timing",
                f"Top100 average route share is {avg_route_share:.1f}%, and {route_dominant_count} of {len(timing_paths)} paths exceed 70% route share.",
            )
        )
    regfile_total = endpoint_counter.get("Regfile D", 0) + endpoint_counter.get("Regfile CE", 0)
    if regfile_total:
        priorities.append(
            (
                "Regfile-Centric Endpoints",
                f"Regfile endpoints occupy {regfile_total} of the top {len(timing_paths)} unrestricted paths.",
            )
        )
    if worst_family_row:
        priorities.append(
            (
                "Canonical Family Worst",
                f"`{worst_family_row['label']}` is the worst available family at {worst_family_row['min_period_ns']:.3f} ns.",
            )
        )
    if bucket_counter.get("DataRam Readback To Regfile D", 0):
        priorities.append(
            (
                "DataRam / Writeback Structural Cone",
                f"`DataRam Readback To Regfile D` appears {bucket_counter['DataRam Readback To Regfile D']} times in the parsed top100 paths.",
            )
        )
    if repeated_path_ratio >= 0.20:
        priorities.append(
            (
                "Repeated Critical Archetypes",
                f"The most common exact path signature covers {repeated_path_ratio * 100.0:.1f}% of the parsed top100 paths.",
            )
        )
    if methodology_rules:
        top_rule = max(methodology_rules, key=lambda row: int(row["violations"]))
        priorities.append(
            (
                "Methodology Hot Rule",
                f"`{top_rule['rule']}` reports {top_rule['violations']} violations.",
            )
        )

    runtime_delta_ns = None
    if single_execution["runtime_ns"] is not None and pipeline_execution["runtime_ns"] is not None:
        runtime_delta_ns = float(pipeline_execution["runtime_ns"]) - float(single_execution["runtime_ns"])
    cycle_delta = int(pipeline_execution["cycle_count"]) - int(single_execution["cycle_count"])
    cpi_delta = None
    if single_execution["cpi"] is not None and pipeline_execution["cpi"] is not None:
        cpi_delta = float(pipeline_execution["cpi"]) - float(single_execution["cpi"])
    runtime_speedup = compute_runtime_speedup(single_execution["runtime_ns"], pipeline_execution["runtime_ns"])

    single_lut_used = parse_int_metric(util_summary.get("slice_luts"))
    single_ff_used = parse_int_metric(util_summary.get("slice_regs"))
    pipeline_ref_wns = float(pipeline_reference["wns_ns"]) if pipeline_reference and pipeline_reference.get("wns_ns") is not None else None
    pipeline_ref_min_period = (
        float(pipeline_reference["min_period_ns"])
        if pipeline_reference and pipeline_reference.get("min_period_ns") is not None
        else None
    )
    pipeline_ref_fmax = 1000.0 / pipeline_ref_min_period if pipeline_ref_min_period and pipeline_ref_min_period > 0 else None
    pipeline_ref_lut = parse_int_metric(pipeline_reference.get("lut_used")) if pipeline_reference else None
    pipeline_ref_ff = parse_int_metric(pipeline_reference.get("ff_used")) if pipeline_reference else None
    timing_verdict = determine_timing_verdict(
        wns_ns=wns_ns,
        failing_endpoints=failing_endpoints,
        health_rows=health_rows,
    )
    runtime_winner = describe_runtime_winner(single_execution["runtime_ns"], pipeline_execution["runtime_ns"])
    first_action = (
        f"`{priorities[0][0]}`: {priorities[0][1]}"
        if priorities
        else "Manual review required."
    )

    analysis_findings: list[dict[str, Any]] = []
    if timing_verdict == "FAIL":
        analysis_findings.append(
            {
                "severity": "FAIL",
                "category": "Timing Closure",
                "title": "Negative setup timing",
                "evidence": f"WNS {fmt_float(wns_ns)} ns, failing endpoints {failing_endpoints}",
                "impact": "The current single-cycle implementation does not meet the requested clock period.",
                "recommended_action": "Start with the worst endpoint and reduce the longest combinational cone before changing constraints.",
                "source_artifact": output_dir / "actual_timing_summary.rpt",
            }
        )
    if avg_route_share is not None and (avg_route_share >= 70.0 or max(route_shares) >= 75.0):
        analysis_findings.append(
            {
                "severity": "WARN",
                "category": "Routing",
                "title": "Route-dominant timing paths",
                "evidence": f"Average route share {fmt_float(avg_route_share, 1)}%, max route share {fmt_float(max(route_shares), 1)}%",
                "impact": "Physical distance or fanout is likely contributing more than logic depth on the critical paths.",
                "recommended_action": "Prioritize placement locality, high-fanout cleanup, and register duplication before deep RTL rewrites.",
                "source_artifact": output_dir / "actual_timing_paths.tsv",
            }
        )
    if worst_family_row:
        analysis_findings.append(
            {
                "severity": "WARN" if timing_verdict != "PASS" else "INFO",
                "category": "Structural Bottleneck",
                "title": str(worst_family_row["label"]),
                "evidence": f"{worst_family_row['label']} reaches {fmt_float(float(worst_family_row['min_period_ns']))} ns",
                "impact": "This retained timing family is the strongest current optimization target.",
                "recommended_action": f"Inspect `{worst_family_row['label']}` fan-in and split or register the dominant data path.",
                "source_artifact": worst_family_row.get("report_path"),
            }
        )
    if signature_rows and repeated_path_ratio >= 0.20:
        signature, count = signature_rows[0]
        analysis_findings.append(
            {
                "severity": "WARN",
                "category": "Repeated Archetype",
                "title": "Repeated critical path signature",
                "evidence": f"`{signature}` covers {repeated_path_ratio * 100.0:.1f}% of parsed top100 paths ({count} hits)",
                "impact": "One structural pattern dominates timing, so a targeted RTL/placement fix should move many paths together.",
                "recommended_action": "Optimize the repeated signature first, then regenerate the report to confirm the distribution changes.",
                "source_artifact": output_dir / "actual_timing_top100.rpt",
            }
        )
    if methodology_rules and timing_verdict != "PASS":
        top_rule = max(methodology_rules, key=lambda row: int(row["violations"]))
        analysis_findings.append(
            {
                "severity": "WARN",
                "category": "Methodology / QoR",
                "title": str(top_rule["rule"]),
                "evidence": f"{top_rule['rule']} reports {top_rule['violations']} violations",
                "impact": "The rule may explain part of the timing closure risk and should be checked with the critical path.",
                "recommended_action": f"Review `{top_rule['rule']}` only if it touches the reported bottleneck path or high-fanout nets.",
                "source_artifact": output_dir / "actual_methodology.rpt",
            }
        )
    if not analysis_findings:
        analysis_findings.append(
            {
                "severity": "PASS",
                "category": "Timing",
                "title": "No urgent timing risk detected",
                "evidence": "Parsed timing, health, and structural checks did not produce a high-priority finding.",
                "impact": "The current report can be used as a baseline for the next optimization run.",
                "recommended_action": "Keep this artifact set as the reference and compare against the next timing run.",
                "source_artifact": output_dir,
            }
        )

    finding_category_order = {
        "Timing Closure": 0,
        "Routing": 1,
        "Repeated Archetype": 2,
        "Structural Bottleneck": 3,
        "Methodology / QoR": 4,
        "Timing": 5,
    }
    ordered_findings = sorted(
        analysis_findings,
        key=lambda finding: finding_category_order.get(str(finding.get("category", "")), 9),
    )
    overall_status = highest_status([timing_verdict] + [str(finding["severity"]) for finding in analysis_findings])
    primary_bottleneck = (
        f"{worst_family_row['label']} at {fmt_float(float(worst_family_row['min_period_ns']))} ns"
        if worst_family_row
        else str(analysis_findings[0]["title"])
    )
    root_causes = ordered_findings[:3]
    recommended_actions = render_recommended_actions(ordered_findings, limit=3)

    family_active_classes = metadata.get("family_active_classes", {})
    coverage_rows: list[str] = []
    for class_name in metadata.get("class_order", []):
        active_families = [
            family["label"]
            for family in metadata.get("known_probe_families", [])
            if class_name in family_active_classes.get(family["key"], [])
        ]
        coverage_rows.append(
            f"| {class_name} | {metadata['class_instruction_counts'].get(class_name, 0)} | {', '.join(active_families) if active_families else 'NA'} |"
        )

    report_lines: list[str] = [
        "# SINGLE_CYCLE Optimization Report",
        "",
        "## 🧭 Summary",
        "",
        "| Item | Value |",
        "| --- | --- |",
        f"| Overall verdict | {status_badge(overall_status)} |",
        f"| Program image | `{metadata['program_image']}` |",
        f"| Worst endpoint | `{worst_path['end_pin']}` |",
        f"| Primary bottleneck | {primary_bottleneck} |",
        f"| Runtime winner | {runtime_winner} |",
        f"| First action | {recommended_actions[0].split('. ', 1)[1] if recommended_actions else first_action} |",
        "",
        "## 🧠 Analysis Result",
        "",
        "| Field | Result |",
        "| --- | --- |",
        f"| Overall Verdict | {status_badge(overall_status)} |",
        f"| Primary Bottleneck | {primary_bottleneck} |",
        f"| Root Cause Candidates | {min(3, len(root_causes))} candidate(s) promoted from parsed timing artifacts |",
        f"| Recommended Next Actions | {min(3, len(recommended_actions))} action(s) |",
        "",
        "### Root Cause Candidates",
        "",
        *render_finding_table(root_causes, limit=3),
        "",
        "## 📊 Key Metrics",
        "",
        "- `Delta` is `5-stage reference - single-cycle`.",
        "- Runtime and CPI are estimated from the selected timing-program trace.",
        "",
        "| Metric | Single-Cycle | 5-Stage Reference | Delta |",
        "| --- | ---: | ---: | ---: |",
        f"| WNS (ns) | {fmt_float(wns_ns)} | {fmt_float(pipeline_ref_wns)} | {fmt_delta_float(wns_ns, pipeline_ref_wns)} |",
        f"| Minimum Period (ns) | {fmt_float(min_period_ns)} | {fmt_float(pipeline_ref_min_period)} | {fmt_delta_float(min_period_ns, pipeline_ref_min_period)} |",
        f"| Fmax (MHz) | {fmt_float(fmax_mhz, 2)} | {fmt_float(pipeline_ref_fmax, 2)} | {fmt_delta_float(fmax_mhz, pipeline_ref_fmax, 2)} |",
        f"| LUTs | {fmt_int(single_lut_used)} | {fmt_int(pipeline_ref_lut)} | {fmt_delta_int(single_lut_used, pipeline_ref_lut)} |",
        f"| Registers | {fmt_int(single_ff_used)} | {fmt_int(pipeline_ref_ff)} | {fmt_delta_int(single_ff_used, pipeline_ref_ff)} |",
        f"| Cycles | {fmt_int(int(single_execution['cycle_count']))} | {fmt_int(int(pipeline_execution['cycle_count']))} | {cycle_delta:+d} |",
        f"| CPI | {fmt_float(single_execution['cpi'])} | {fmt_float(pipeline_execution['cpi'])} | {fmt_delta_float(single_execution['cpi'], pipeline_execution['cpi'])} |",
        f"| Runtime | {format_runtime_ns(single_execution['runtime_ns'])} | {format_runtime_ns(pipeline_execution['runtime_ns'])} | {format_runtime_ns(runtime_delta_ns)} |",
        f"| Pipeline Speedup (x) | {format_ratio(1.0 if runtime_speedup is not None else None)} | {format_ratio(runtime_speedup)} | {fmt_delta_ratio(1.0 if runtime_speedup is not None else None, runtime_speedup)} |",
        "",
        "## 🎯 Recommended Actions",
        "",
        *recommended_actions,
        "",
        "## 📁 Evidence",
        "",
        "| Evidence | Location |",
        "| --- | --- |",
        f"| Artifact directory | `{output_dir}` |",
        f"| Timing summary | `{output_dir / 'actual_timing_summary.rpt'}` |",
        f"| Parsed timing paths | `{output_dir / 'actual_timing_paths.tsv'}` |",
        f"| Top timing report | `{output_dir / 'actual_timing_top100.rpt'}` |",
        f"| Utilization summary | `{output_dir / 'actual_utilization.rpt'}` |",
        f"| Standalone report | `{report_path}` |",
    ]
    if pipeline_reference is not None:
        report_lines.append(f"| Companion pipeline artifacts | `{pipeline_reference['output_dir']}` |")
    report_lines.extend(
        [
            "",
            "<details>",
            "<summary>Compact timing evidence</summary>",
            "",
            "### Canonical Timing Families",
            "",
            "| Family | Worst Endpoint | Minimum Period (ns) | Est. Fmax (MHz) | Top Paths |",
            "| --- | --- | ---: | ---: | ---: |",
        ]
    )
    for family_row in family_timing_rows:
        worst_family_path = family_row["worst_path"]
        if worst_family_path:
            report_lines.append(
                f"| {family_row['label']} | `{worst_family_path['end_pin']}` | {fmt_float(float(family_row['min_period_ns']))} | {fmt_float(float(family_row['fmax_mhz']), 2)} | {family_row['path_count']} |"
            )
        else:
            report_lines.append(f"| {family_row['label']} | No retained path data | NA | NA | 0 |")
    report_lines.extend(
        [
            "",
            "### Top100 Timing Distribution",
            "",
            "| Metric | Worst | P90 | Median | Average |",
            "| --- | ---: | ---: | ---: | ---: |",
            f"| Slack (ns) | {fmt_float(min(slacks))} | {fmt_float(percentile(slacks, 0.10))} | {fmt_float(percentile(slacks, 0.50))} | {fmt_float(safe_mean(slacks))} |",
            f"| Data path delay (ns) | {fmt_float(max(datapath_delays))} | {fmt_float(percentile(datapath_delays, 0.90))} | {fmt_float(percentile(datapath_delays, 0.50))} | {fmt_float(safe_mean(datapath_delays))} |",
            f"| Route delay (ns) | {fmt_float(max(net_delays))} | {fmt_float(percentile(net_delays, 0.90))} | {fmt_float(percentile(net_delays, 0.50))} | {fmt_float(safe_mean(net_delays))} |",
            f"| Route share (%) | {fmt_float(max(route_shares), 1)} | {fmt_float(percentile(route_shares, 0.90), 1)} | {fmt_float(percentile(route_shares, 0.50), 1)} | {fmt_float(avg_route_share, 1)} |",
            f"| Logic levels | {fmt_float(max(logic_levels), 1)} | {fmt_float(percentile(logic_levels, 0.90), 1)} | {fmt_float(percentile(logic_levels, 0.50), 1)} | {fmt_float(safe_mean(logic_levels), 1)} |",
            "",
            "### Program Coverage Context",
            "",
            "| Class | Instruction Count | Active Family Hints |",
            "| --- | ---: | --- |",
            *coverage_rows,
            "",
            "</details>",
            "",
        ]
    )

    report_text = "\n".join(report_lines) + "\n"
    report_path.write_text(report_text, encoding="utf-8")
    write_html_report(report_path.with_suffix(".html"), report_text, title=report_path.stem)
    write_artifact_manifest(output_dir, family_timing_rows)
    return report_text


def run(project_root: pathlib.Path, argv: list[str] | None = None) -> int:
    contract = load_project_contract(project_root)
    profile = contract["profile"]
    default_output_dir = project_root / str(profile.get("default_output_dir", ".analysis/single_cycle_perf"))
    default_report_path = project_root / str(profile.get("default_report_path", "SINGLE_CYCLE_OPTIMIZATION_REPORT.md"))

    parser = argparse.ArgumentParser(description=f"Generate a single-cycle optimization report for {contract['project_name']}.")
    parser.add_argument("--output-dir", type=pathlib.Path, default=default_output_dir)
    parser.add_argument("--report-path", type=pathlib.Path, default=default_report_path)
    parser.add_argument("--reuse-existing", action="store_true", help="Reuse existing raw outputs instead of launching Vivado.")
    parser.add_argument("--program", default="full_coverage", help="Timing program image to use: `full_coverage` or `bubble_sort`.")
    args = parser.parse_args(argv)

    selected_program = resolve_selected_program(project_root, args.program)
    output_dir = resolve_program_output_dir(args.output_dir, default_output_dir, str(selected_program["key"]))
    report_path = args.report_path.resolve()
    report_path.parent.mkdir(parents=True, exist_ok=True)
    reuse_existing = args.reuse_existing and all(
        path.exists()
        for path in [
            output_dir / "actual_timing_summary.rpt",
            output_dir / "actual_timing_top100.rpt",
            output_dir / "actual_timing_paths.tsv",
            output_dir / "actual_high_fanout.rpt",
            output_dir / "actual_utilization.rpt",
            output_dir / "module_metrics.tsv",
        ]
    )
    vivado_units = 6
    total_progress_units = 4 + (1 if reuse_existing else vivado_units)
    tracker = ProgressTracker(total_progress_units)
    tracker.step(
        f"Loaded single-cycle timing contract for {contract['project_name']} | Program: {selected_program['display_name']} | Artifacts: {output_dir} | Report: {report_path}"
    )

    metadata = build_single_cycle_metadata(contract, output_dir, selected_program)
    write_metadata(output_dir, metadata)
    tracker.step("Timing metadata prepared")

    if reuse_existing:
        tracker.step(f"Reused existing Vivado artifacts from {output_dir}")
    else:
        run_vivado(
            project_root,
            output_dir,
            contract,
            metadata,
            program_selection=selected_program,
            progress_callback=tracker.make_subrun_callback(
                tracker.completed_units,
                vivado_units,
                prefix=contract["project_name"],
            ),
        )

    report_text = build_report(output_dir, report_path, metadata)
    tracker.step("Built Markdown timing report")

    integrated_report_path = resolve_integrated_report_path(project_root)
    if integrated_report_path is not None:
        integrated_report_path.parent.mkdir(parents=True, exist_ok=True)
        integrated_report_text = merge_program_detail_section(
            integrated_report_path,
            program_selection=selected_program,
            detail_key="single_cycle",
            detail_body=build_integrated_single_cycle_detail_text(
                report_text,
                project_name=str(metadata["project_name"]),
                artifact_dir=output_dir,
                report_path=report_path,
            ),
            program_keys=list(PROGRAM_LIBRARY),
            resolve_program_selection=lambda key: resolve_selected_program(project_root, key),
        )
        integrated_report_path.write_text(integrated_report_text, encoding="utf-8")
        write_html_report(integrated_report_path.with_suffix(".html"), integrated_report_text, title=integrated_report_path.stem)

    tracker.step(f"Report written to {report_path}")
    print(f"Report written to {report_path}")
    return 0
