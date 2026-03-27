from __future__ import annotations

import pathlib
from typing import Any

from .focus import strip_mem_lines, trace_program_words


def analyze_program_trace(mem_path: pathlib.Path) -> dict[str, Any]:
    resolved_mem_path = mem_path.resolve()
    program_words = strip_mem_lines(resolved_mem_path)
    trace = trace_program_words(program_words)
    retired = list(trace.get("retired", []))
    hazards = dict(trace.get("hazards", {}))

    redirect_count = sum(
        1
        for item in retired[:-1]
        if bool(item.get("is_jump")) or (bool(item.get("is_branch")) and bool(item.get("taken")))
    )

    return {
        "program_mem_path": str(resolved_mem_path),
        "instruction_count": int(trace.get("retired_count", 0)),
        "load_use_stall_count": int(hazards.get("load_use_distance_1", 0)),
        "redirect_count": int(redirect_count),
        "branch_taken_count": int(hazards.get("branch_taken", 0)),
        "jump_count": int(hazards.get("jump_count", 0)),
        "terminal_pc": int(retired[-1]["pc"]) if retired else None,
        "terminal_mnemonic": str(retired[-1]["mnemonic"]) if retired else None,
    }


def estimate_single_cycle_execution(trace_summary: dict[str, Any], min_period_ns: float | None) -> dict[str, Any]:
    instruction_count = int(trace_summary.get("instruction_count", 0))
    cycle_count = instruction_count
    cpi = (cycle_count / instruction_count) if instruction_count > 0 else None
    runtime_ns = (cycle_count * min_period_ns) if min_period_ns is not None else None

    return {
        "architecture": "Single-Cycle",
        "instruction_count": instruction_count,
        "cycle_count": cycle_count,
        "cpi": cpi,
        "runtime_ns": runtime_ns,
        "fill_cycles": 0,
        "stall_cycles": 0,
        "redirect_penalty_cycles": 0,
        "model_note": "1 cycle per retired instruction",
    }


def estimate_pipeline_5stage_execution(trace_summary: dict[str, Any], min_period_ns: float | None) -> dict[str, Any]:
    instruction_count = int(trace_summary.get("instruction_count", 0))
    fill_cycles = 4 if instruction_count > 0 else 0
    stall_cycles = int(trace_summary.get("load_use_stall_count", 0))
    redirect_penalty_cycles = 2 * int(trace_summary.get("redirect_count", 0))
    cycle_count = instruction_count + fill_cycles + stall_cycles + redirect_penalty_cycles
    cpi = (cycle_count / instruction_count) if instruction_count > 0 else None
    runtime_ns = (cycle_count * min_period_ns) if min_period_ns is not None else None

    return {
        "architecture": "5-Stage Pipeline",
        "instruction_count": instruction_count,
        "cycle_count": cycle_count,
        "cpi": cpi,
        "runtime_ns": runtime_ns,
        "fill_cycles": fill_cycles,
        "stall_cycles": stall_cycles,
        "redirect_penalty_cycles": redirect_penalty_cycles,
        "model_note": "retired + 4 fill + load-use stalls + 2-cycle taken redirect penalties",
    }


def compute_runtime_speedup(single_runtime_ns: float | None, pipeline_runtime_ns: float | None) -> float | None:
    if single_runtime_ns is None or pipeline_runtime_ns is None:
        return None
    if pipeline_runtime_ns <= 0.0:
        return None
    return float(single_runtime_ns) / float(pipeline_runtime_ns)


def format_runtime_ns(runtime_ns: float | None) -> str:
    if runtime_ns is None:
        return "NA"
    if runtime_ns >= 1_000_000.0:
        return f"{runtime_ns:.3f} ns ({runtime_ns / 1_000_000.0:.3f} ms)"
    if runtime_ns >= 1_000.0:
        return f"{runtime_ns:.3f} ns ({runtime_ns / 1_000.0:.3f} us)"
    return f"{runtime_ns:.3f} ns"


def format_ratio(value: float | None, digits: int = 3) -> str:
    if value is None:
        return "NA"
    return f"{value:.{digits}f}x"
