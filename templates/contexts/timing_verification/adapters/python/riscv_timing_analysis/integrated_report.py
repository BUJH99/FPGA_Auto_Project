from __future__ import annotations

import html
import math
import pathlib
import re
from collections.abc import Callable
from datetime import datetime
from typing import Any


PROGRAM_SECTION_START_TEMPLATE = "<!-- PROGRAM_SECTION:{program_key}:START -->"
PROGRAM_SECTION_END_TEMPLATE = "<!-- PROGRAM_SECTION:{program_key}:END -->"
DETAIL_SECTION_START_TEMPLATE = "<!-- DETAIL_SECTION:{detail_key}:{program_key}:START -->"
DETAIL_SECTION_END_TEMPLATE = "<!-- DETAIL_SECTION:{detail_key}:{program_key}:END -->"
DETAIL_SECTION_SPECS: tuple[tuple[str, str], ...] = (
    ("single_cycle", "Single-Cycle Optimization Detail"),
    ("pipeline_perf", "Pipeline Performance Detail"),
)
HEADING_PATTERN = re.compile(r"^(?P<hashes>#{1,6})(?P<suffix>\s+.*)$")
MARKDOWN_TABLE_SEPARATOR_PATTERN = re.compile(r"^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?\s*$")
MARKDOWN_TABLE_ROW_PATTERN = re.compile(r"^\s*\|.*\|\s*$")
MARKDOWN_ORDERED_LIST_PATTERN = re.compile(r"^\s*\d+\.\s+(.+)$")
NUMBER_PATTERN = re.compile(r"[-+]?\d+(?:,\d{3})*(?:\.\d+)?")
CHART_COLORS = {
    "blue": "#3182f6",
    "blue_soft": "#e8f3ff",
    "green": "#34c759",
    "green_soft": "#e3f8eb",
    "red": "#f04452",
    "red_soft": "#feecef",
    "amber": "#ff8f00",
    "amber_soft": "#fff4e6",
    "purple": "#748edc",
    "ink": "#191f28",
    "muted": "#8b95a1",
    "tertiary": "#b0b8c1",
    "line": "#e5e8eb",
    "panel": "#ffffff",
    "soft": "#f9fafb",
    "bg": "#f2f4f6",
}
STATUS_BADGES = {
    "PASS": "✅ PASS",
    "WARN": "⚠️ WARN",
    "FAIL": "❌ FAIL",
    "INFO": "ℹ️ INFO",
}
SEVERITY_RANK = {
    "PASS": 0,
    "INFO": 1,
    "WARN": 2,
    "FAIL": 3,
}
NOISY_SECTION_TITLES = {
    "appendix",
    "run metadata",
    "contract resolution",
    "analysis health",
    "methodology / qor details",
    "raw files",
    "full instruction-focus tables",
    "full instruction focus tables",
    "artifacts",
    "critical timing structure",
    "canonical timing families",
    "program coverage context",
    "top100 timing distribution",
    "path family buckets",
    "repeated exact path signatures",
    "start/end module pairs",
    "implementation footprint",
    "auto-discovered module metrics",
    "high-fanout nets",
    "utilization summary",
    "actual synth instance area",
    "compact timing evidence",
    "focus coverage snapshot",
}


def normalize_status(status: str | None) -> str:
    normalized = str(status or "INFO").strip().upper()
    return normalized if normalized in STATUS_BADGES else "INFO"


def status_badge(status: str | None) -> str:
    return STATUS_BADGES[normalize_status(status)]


def highest_status(statuses: list[str | None], *, default: str = "PASS") -> str:
    result = normalize_status(default)
    for status in statuses:
        normalized = normalize_status(status)
        if SEVERITY_RANK[normalized] > SEVERITY_RANK[result]:
            result = normalized
    return result


def render_finding_table(findings: list[dict[str, Any]], *, limit: int = 3) -> list[str]:
    if not findings:
        return ["- No automatic root-cause candidate was detected."]

    lines = [
        "| Severity | Category | Finding | Evidence | Impact |",
        "| --- | --- | --- | --- | --- |",
    ]
    for finding in findings[:limit]:
        lines.append(
            "| "
            + " | ".join(
                [
                    status_badge(str(finding.get("severity", "INFO"))),
                    str(finding.get("category", "Timing")),
                    str(finding.get("title", "NA")),
                    str(finding.get("evidence", finding.get("title", "NA"))),
                    str(finding.get("impact", "Review required.")),
                ]
            )
            + " |"
        )
    return lines


def render_recommended_actions(findings: list[dict[str, Any]], *, limit: int = 3) -> list[str]:
    actions: list[str] = []
    for finding in findings:
        action = str(finding.get("recommended_action", "")).strip()
        if action and action not in actions:
            actions.append(action)
        if len(actions) >= limit:
            break
    if not actions:
        return ["1. No immediate automatic action was detected; review the evidence artifacts manually."]
    return [f"{idx}. {action}" for idx, action in enumerate(actions, start=1)]


def _normalized_heading_title(line: str) -> tuple[int, str] | None:
    match = HEADING_PATTERN.match(line)
    if not match:
        return None
    heading_text = match.group("suffix").strip()
    heading_text = re.sub(r"^[^\w`#]+", "", heading_text).strip()
    heading_text = heading_text.strip("`").strip()
    return len(match.group("hashes")), heading_text.lower()


def clean_heading_text(line: str) -> tuple[int, str] | None:
    match = HEADING_PATTERN.match(line)
    if not match:
        return None
    heading_text = match.group("suffix").strip()
    heading_text = re.sub(r"^[^\w`#]+", "", heading_text).strip()
    heading_text = heading_text.strip("`").strip()
    return len(match.group("hashes")), heading_text


def strip_noisy_report_sections(text: str, noisy_titles: set[str] | None = None) -> str:
    noisy = noisy_titles or NOISY_SECTION_TITLES
    lines = text.replace("\r\n", "\n").split("\n")
    kept: list[str] = []
    skipping_level: int | None = None
    skipping_details = False

    for line in lines:
        stripped_line = line.strip().lower()
        if stripped_line == "<details>":
            skipping_details = True
            continue
        if skipping_details:
            if stripped_line == "</details>":
                skipping_details = False
            continue
        heading = _normalized_heading_title(line)
        if heading is not None:
            level, title = heading
            if skipping_level is not None and level <= skipping_level:
                skipping_level = None
            if title in noisy:
                skipping_level = level
                continue
        if skipping_level is not None:
            continue
        kept.append(line)

    return "\n".join(kept).strip() + ("\n" if kept else "")


def markdown_table_cells(line: str) -> list[str]:
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


def parse_markdown_tables(text: str) -> list[dict[str, Any]]:
    tables: list[dict[str, Any]] = []
    lines = text.replace("\r\n", "\n").split("\n")
    idx = 0
    current_heading = ""
    current_program_key = ""
    current_program_title = ""
    while idx < len(lines):
        program_start = re.match(r"<!-- PROGRAM_SECTION:(?P<key>[a-z0-9_]+):START -->", lines[idx].strip())
        if program_start:
            current_program_key = str(program_start.group("key"))
            current_program_title = current_program_key.replace("_", " ").title()
            idx += 1
            continue
        if re.match(r"<!-- PROGRAM_SECTION:[a-z0-9_]+:END -->", lines[idx].strip()):
            current_program_key = ""
            current_program_title = ""
            idx += 1
            continue
        heading = _normalized_heading_title(lines[idx])
        if heading is not None:
            current_heading = heading[1]
            clean_heading = clean_heading_text(lines[idx])
            if current_program_key and clean_heading is not None and clean_heading[0] == 2:
                current_program_title = clean_heading[1]
            idx += 1
            continue
        if not MARKDOWN_TABLE_ROW_PATTERN.match(lines[idx]):
            idx += 1
            continue
        table_lines: list[str] = []
        while idx < len(lines) and MARKDOWN_TABLE_ROW_PATTERN.match(lines[idx]):
            table_lines.append(lines[idx])
            idx += 1
        if len(table_lines) < 2 or not MARKDOWN_TABLE_SEPARATOR_PATTERN.match(table_lines[1]):
            continue
        header = markdown_table_cells(table_lines[0])
        rows = [markdown_table_cells(line) for line in table_lines[2:]]
        tables.append(
            {
                "heading": current_heading,
                "header": header,
                "rows": rows,
                "program_key": current_program_key,
                "program_title": current_program_title,
            }
        )
    return tables


def parse_first_number(value: Any) -> float | None:
    match = NUMBER_PATTERN.search(str(value).replace(",", ""))
    if not match:
        return None
    try:
        return float(match.group(0))
    except ValueError:
        return None


def extract_status(value: Any) -> str:
    upper_value = str(value or "").upper()
    for status in ("FAIL", "WARN", "PASS", "INFO"):
        if status in upper_value:
            return status
    return "INFO"


def compact_chart_label(value: Any, *, limit: int = 36) -> str:
    text = str(value or "").strip()
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"\1", text)
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) <= limit:
        return text
    return text[: max(0, limit - 3)].rstrip() + "..."


def anchor_slug(value: Any) -> str:
    text = str(value or "").strip()
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"\1", text)
    text = re.sub(r"\.mem\b", "", text, flags=re.IGNORECASE)
    text = re.sub(r"[^a-zA-Z0-9]+", "-", text).strip("-").lower()
    return text or "section"


def heading_id_for(text: str, used_ids: dict[str, int]) -> str:
    base = anchor_slug(text)
    count = used_ids.get(base, 0)
    used_ids[base] = count + 1
    return base if count == 0 else f"{base}-{count + 1}"


def svg_text(value: Any) -> str:
    return html.escape(str(value), quote=False)


def chart_number(value: float | None) -> str:
    if value is None:
        return "NA"
    if abs(value) >= 100:
        return f"{value:.0f}"
    if abs(value) >= 10:
        return f"{value:.2f}"
    return f"{value:.3f}"


def metric_key(value: Any) -> str:
    return re.sub(r"[^a-z0-9]+", " ", str(value or "").lower()).strip()


def get_cell(row: list[str], index: int | None) -> str:
    if index is None or index < 0 or index >= len(row):
        return "NA"
    return str(row[index])


def table_rows_as_dicts(table: dict[str, Any]) -> list[dict[str, str]]:
    header = [str(cell) for cell in table.get("header", [])]
    rows_as_dicts: list[dict[str, str]] = []
    for row in table.get("rows", []):
        rows_as_dicts.append({header[index]: str(row[index]) if index < len(row) else "" for index in range(len(header))})
    return rows_as_dicts


def first_row_value(row: dict[str, str], *keys: str) -> str:
    for key in keys:
        value = str(row.get(key, "")).strip()
        if value:
            return value
    return ""


def first_row_number(row: dict[str, str], *keys: str) -> float | None:
    for key in keys:
        value = row.get(key)
        if value is None:
            continue
        number = parse_first_number(value)
        if number is not None:
            return number
    return None


def preferred_metric_column(header: list[str], *, prefer_pipeline: bool = True) -> int | None:
    candidates = header[1:]
    if not candidates:
        return None
    if prefer_pipeline:
        for name in ("5-Stage Pipeline", "5-Stage Reference", "Pipeline", "5-Stage"):
            for index, candidate in enumerate(header):
                if name.lower() in candidate.lower():
                    return index
    for index, candidate in enumerate(header):
        if index > 0 and candidate.lower() != "delta":
            return index
    return None


def metric_value(metrics: dict[str, dict[str, str]], metric_name: str, columns: list[str]) -> float | None:
    row = metrics.get(metric_key(metric_name))
    if not row:
        return None
    for column in columns:
        for existing_column, value in row.items():
            if column.lower() in existing_column.lower():
                number = parse_first_number(value)
                if number is not None:
                    return number
    for existing_column, value in row.items():
        if existing_column.lower() == "metric" or existing_column.lower() == "delta":
            continue
        number = parse_first_number(value)
        if number is not None:
            return number
    return None


def metric_raw(metrics: dict[str, dict[str, str]], metric_name: str, columns: list[str]) -> str:
    row = metrics.get(metric_key(metric_name))
    if not row:
        return "NA"
    for column in columns:
        for existing_column, value in row.items():
            if column.lower() in existing_column.lower() and str(value).strip():
                return str(value)
    for existing_column, value in row.items():
        if existing_column.lower() != "metric" and str(value).strip():
            return str(value)
    return "NA"


def collect_soc_perf_model(tables: list[dict[str, Any]]) -> dict[str, Any] | None:
    summary: dict[str, str] = {}
    scenario_rows: list[dict[str, str]] = []
    execution_rows: list[dict[str, str]] = []
    bus_rows: list[dict[str, str]] = []
    axi_rows: list[dict[str, str]] = []
    apb_rows: list[dict[str, str]] = []
    interrupt_rows: list[dict[str, str]] = []
    e2e_rows: list[dict[str, str]] = []
    derived_rows: list[dict[str, str]] = []
    threshold_rows: list[dict[str, str]] = []
    pipeline_raw_rows: list[dict[str, str]] = []
    bus_raw_rows: list[dict[str, str]] = []
    apb_raw_rows: list[dict[str, str]] = []
    apb_reg_rows: list[dict[str, str]] = []
    irq_raw_rows: list[dict[str, str]] = []
    periph_raw_rows: list[dict[str, str]] = []

    for table in tables:
        header = [str(cell) for cell in table.get("header", [])]
        heading = str(table.get("heading", ""))
        rows = table_rows_as_dicts(table)
        if header[:2] == ["Item", "Value"]:
            candidate = {str(row.get("Item", "")): str(row.get("Value", "")) for row in rows if row.get("Item")}
            if any(key in candidate for key in ("Primary SoC bottleneck", "Scenario count", "Latest cache")):
                summary = candidate
        elif "Scenario/Profile" in header and "Verdict" in header and "Cycles" in header and "SoC Blocked" in header:
            scenario_rows.extend(rows)
        elif "Scenario/Profile" in header and "Window" in header and "APB Stall" in header and "LoadUse" in header:
            execution_rows.extend(rows)
        elif "Scenario/Profile" in header and "Fetch Req" in header and "MMIO Ratio x1000" in header:
            bus_rows.extend(rows)
        elif "Scenario/Profile" in header and "AXI Rd" in header and "Resp Err" in header:
            axi_rows.extend(rows)
        elif "Scenario/Profile" in header and "Branch Taken" in header and "WB Valid" in header:
            pipeline_raw_rows.extend(rows)
        elif "Scenario/Profile" in header and "Read Wait" in header and "Last RData" in header:
            bus_raw_rows.extend(rows)
        elif "Scenario/Profile" in header and "Target" in header and "PREADY Wait" in header:
            apb_raw_rows.extend(rows)
        elif "Scenario/Profile" in header and "Target" in header and "Register" in header and "Last RData" in header:
            apb_reg_rows.extend(rows)
        elif "Scenario/Profile" in header and "Source" in header and "Pending Cycles" in header and "MIE Disabled" in header:
            irq_raw_rows.extend(rows)
        elif "Scenario/Profile" in header and "Peripheral" in header and "RAW Metrics" in header:
            periph_raw_rows.extend(rows)
        elif "Scenario/Profile" in header and "Target" in header and "Reads" in header and "Avg x1000" in header and "PSLVERR" in header:
            apb_rows.extend(rows)
        elif "Scenario/Profile" in header and "Source" in header and "Service" in header:
            interrupt_rows.extend(rows)
        elif "Scenario/Profile" in header and "Input->Visible Done" in header:
            e2e_rows.extend(rows)
        elif "Scenario/Profile" in header and "Runtime CPI" in header and "MIPS" in header:
            derived_rows.extend(rows)
        elif "Status" in header and "Baseline" in header and "Detail" in header and "threshold" in heading:
            threshold_rows.extend(rows)

    if not summary and not scenario_rows and not execution_rows:
        return None

    primary_scenario = scenario_rows[0] if scenario_rows else {}
    program_runtime = next(
        (row for row in execution_rows if str(row.get("Window", "")).strip().lower() == "program_runtime"),
        execution_rows[0] if execution_rows else {},
    )
    primary_bus = bus_rows[0] if bus_rows else {}
    primary_derived = derived_rows[0] if derived_rows else {}

    runtime_cycles = first_row_number(primary_scenario, "Cycles") or first_row_number(program_runtime, "Cycles")
    retired = first_row_number(primary_scenario, "Retired") or first_row_number(program_runtime, "Retired")
    cpi_x1000 = first_row_number(primary_scenario, "CPI x1000") or first_row_number(program_runtime, "CPI x1000")
    runtime_cpi = first_row_number(primary_derived, "Runtime CPI")
    if runtime_cpi is None and cpi_x1000 is not None:
        runtime_cpi = cpi_x1000 / 1000.0
    soc_blocked = first_row_number(primary_scenario, "SoC Blocked") or first_row_number(program_runtime, "SoC Blocked", "Blocked")
    blocked_pct = (soc_blocked / runtime_cycles * 100.0) if soc_blocked is not None and runtime_cycles else None
    mmio_ratio_x1000 = first_row_number(primary_bus, "MMIO Ratio x1000")
    mmio_ratio_pct = (mmio_ratio_x1000 / 10.0) if mmio_ratio_x1000 is not None else None
    scenario_count = parse_first_number(summary.get("Scenario count")) or float(len(scenario_rows) or 0)
    verdict = extract_status(summary.get("Overall verdict") or primary_scenario.get("Verdict") or "INFO")
    threshold_status = highest_status([extract_status(row.get("Status", "")) for row in threshold_rows], default="PASS") if threshold_rows else "PASS"

    return {
        "summary": summary,
        "scenario_rows": scenario_rows,
        "execution_rows": execution_rows,
        "bus_rows": bus_rows,
        "axi_rows": axi_rows,
        "apb_rows": apb_rows,
        "interrupt_rows": interrupt_rows,
        "e2e_rows": e2e_rows,
        "derived_rows": derived_rows,
        "threshold_rows": threshold_rows,
        "pipeline_raw_rows": pipeline_raw_rows,
        "bus_raw_rows": bus_raw_rows,
        "apb_raw_rows": apb_raw_rows,
        "apb_reg_rows": apb_reg_rows,
        "irq_raw_rows": irq_raw_rows,
        "periph_raw_rows": periph_raw_rows,
        "primary_scenario": primary_scenario,
        "program_runtime": program_runtime,
        "verdict": verdict,
        "threshold_status": threshold_status,
        "scenario_count": scenario_count,
        "runtime_cycles": runtime_cycles,
        "retired": retired,
        "runtime_cpi": runtime_cpi,
        "soc_blocked": soc_blocked,
        "blocked_pct": blocked_pct,
        "mmio_ratio_pct": mmio_ratio_pct,
        "mips": first_row_number(primary_derived, "MIPS"),
        "fmax_mhz": first_row_number(primary_derived, "Pipeline Fmax MHz"),
        "primary_bottleneck": summary.get("Primary SoC bottleneck") or first_row_value(primary_scenario, "Worst Latency"),
        "worst_latency": summary.get("Worst latency") or first_row_value(primary_scenario, "Worst Latency"),
    }


def format_kpi_value(value: float | None, *, unit: str = "", precision: int = 3) -> str:
    if value is None:
        return "NA"
    if abs(value) >= 1000:
        rendered = f"{value:,.0f}"
    elif abs(value) >= 100:
        rendered = f"{value:.1f}"
    else:
        rendered = f"{value:.{precision}f}"
    return f"{rendered} {unit}".strip()


def report_kind(title: str, markdown_text: str) -> str:
    haystack = f"{title}\n{markdown_text[:4000]}".lower()
    if "pipeline" in haystack and "single_cycle optimization" not in haystack:
        return "RV32I 5-Stage Pipeline"
    if "single_cycle" in haystack or "single-cycle" in haystack:
        return "RV32I Single-Cycle"
    return "RV32I Timing Comparison"


def collect_visual_model(markdown_text: str, *, title: str) -> dict[str, Any]:
    tables = parse_markdown_tables(markdown_text)
    soc_perf = collect_soc_perf_model(tables)
    key_metric_sets: list[dict[str, Any]] = []
    findings: list[dict[str, str]] = []
    stage_rows: list[dict[str, Any]] = []
    summaries: list[dict[str, str]] = []
    route_share_candidates: list[float] = []
    logic_level_candidates: list[float] = []
    target_period_candidates: list[float] = []

    for table_index, table in enumerate(tables):
        header = [str(cell) for cell in table.get("header", [])]
        heading = str(table.get("heading", ""))
        program_title = str(table.get("program_title") or "").strip()
        label = program_title or f"Benchmark {len(key_metric_sets) + 1}"

        if header[:1] == ["Item"] and "Value" in header and "summary" in heading:
            summary = {str(row[0]): str(row[1]) for row in table.get("rows", []) if len(row) >= 2}
            if summary:
                summary["_program_title"] = program_title
                summaries.append(summary)

        if header[:1] == ["Metric"] and len(header) >= 3 and "key metrics" in heading:
            metrics = {metric_key(row[0]): {header[index]: str(row[index]) if index < len(row) else "" for index in range(len(header))} for row in table.get("rows", []) if row}
            preferred_index = preferred_metric_column(header)
            key_metric_sets.append(
                {
                    "label": label,
                    "header": header,
                    "rows": table.get("rows", []),
                    "metrics": metrics,
                    "preferred_index": preferred_index,
                    "table_index": table_index,
                }
            )
            wns = metric_value(metrics, "WNS (ns)", ["5-Stage", "Pipeline", "Reference", "Single-Cycle"])
            min_period = metric_value(metrics, "Minimum Period (ns)", ["5-Stage", "Pipeline", "Reference", "Single-Cycle"])
            if wns is not None and min_period is not None:
                required_period = min_period + wns
                if required_period > 0:
                    target_period_candidates.append(required_period)

        if "Severity" in header and "Finding" in header:
            for row in table.get("rows", []):
                row_dict = {header[index]: str(row[index]) if index < len(row) else "" for index in range(len(header))}
                row_dict["_program_title"] = program_title
                findings.append(row_dict)
                evidence = row_dict.get("Evidence", "")
                for route_match in re.finditer(r"(?:Average route share|max route share)\s+([0-9.]+)%", evidence, flags=re.IGNORECASE):
                    route_share_candidates.append(float(route_match.group(1)))

        if "Boundary" in header and "Stage" in header and "Minimum Period (ns)" in header:
            boundary_idx = header.index("Boundary")
            stage_idx = header.index("Stage")
            period_idx = header.index("Minimum Period (ns)")
            datapath_idx = header.index("Data Path (ns)") if "Data Path (ns)" in header else None
            route_idx = header.index("Route Share (%)") if "Route Share (%)" in header else None
            logic_idx = header.index("Logic Levels") if "Logic Levels" in header else None
            fmax_idx = header.index("Fmax (MHz)") if "Fmax (MHz)" in header else None
            start_idx = header.index("Worst Start") if "Worst Start" in header else None
            endpoint_idx = header.index("Worst Endpoint") if "Worst Endpoint" in header else None
            for row in table.get("rows", []):
                if len(row) <= max(boundary_idx, stage_idx, period_idx):
                    continue
                period = parse_first_number(row[period_idx])
                if period is None:
                    continue
                route_share = parse_first_number(get_cell(row, route_idx))
                logic_levels = parse_first_number(get_cell(row, logic_idx))
                if route_share is not None:
                    route_share_candidates.append(route_share)
                if logic_levels is not None:
                    logic_level_candidates.append(logic_levels)
                stage_rows.append(
                    {
                        "program_title": program_title,
                        "boundary": str(row[boundary_idx]),
                        "stage": str(row[stage_idx]),
                        "datapath_ns": parse_first_number(get_cell(row, datapath_idx)),
                        "period_ns": period,
                        "fmax_mhz": parse_first_number(get_cell(row, fmax_idx)),
                        "logic_levels": logic_levels,
                        "route_share_pct": route_share,
                        "worst_start": get_cell(row, start_idx),
                        "worst_endpoint": get_cell(row, endpoint_idx),
                    }
                )

    for route_match in re.finditer(r"(?:Average route share|max route share)\s+([0-9.]+)%", markdown_text, flags=re.IGNORECASE):
        route_share_candidates.append(float(route_match.group(1)))

    worst_wns_values: list[float] = []
    pipeline_cpi_values: list[float] = []
    fmax_points: list[dict[str, Any]] = []
    cycle_points: list[dict[str, Any]] = []
    resource_points: list[dict[str, Any]] = []
    for metric_set in key_metric_sets:
        metrics = metric_set["metrics"]
        label = metric_set["label"]
        header = metric_set["header"]
        preferred_index = metric_set["preferred_index"]
        preferred_name = header[preferred_index] if preferred_index is not None and preferred_index < len(header) else "Selected"

        for metric_name in ("WNS (ns)",):
            row = metrics.get(metric_key(metric_name), {})
            for column, value in row.items():
                if column.lower() != "metric" and column.lower() != "delta":
                    number = parse_first_number(value)
                    if number is not None:
                        worst_wns_values.append(number)

        cpi_value = metric_value(metrics, "CPI", ["5-Stage", "Pipeline", "Reference"])
        if cpi_value is not None:
            pipeline_cpi_values.append(cpi_value)
        fmax_value = metric_value(metrics, "Fmax (MHz)", ["5-Stage", "Pipeline", "Reference"])
        if fmax_value is not None:
            fmax_points.append({"label": label, "value": fmax_value, "series": preferred_name})
        single_cycles = metric_value(metrics, "Cycles", ["Single-Cycle"])
        pipeline_cycles = metric_value(metrics, "Cycles", ["5-Stage", "Pipeline", "Reference"])
        if single_cycles is not None and pipeline_cycles is not None:
            cycle_points.append({"label": label, "single": single_cycles, "pipeline": pipeline_cycles})
        lut_value = metric_value(metrics, "LUTs", ["5-Stage", "Pipeline", "Reference"])
        reg_value = metric_value(metrics, "Registers", ["5-Stage", "Pipeline", "Reference"])
        if lut_value is not None or reg_value is not None:
            resource_points.append({"label": label, "luts": lut_value, "registers": reg_value})

    target_period_ns = sum(target_period_candidates) / len(target_period_candidates) if target_period_candidates else None
    target_fmax_mhz = 1000.0 / target_period_ns if target_period_ns else None
    overall_status = highest_status([extract_status(summary.get("Overall verdict", "")) for summary in summaries] + [extract_status(finding.get("Severity", "")) for finding in findings])

    return {
        "title": title,
        "kind": report_kind(title, markdown_text),
        "tables": tables,
        "key_metric_sets": key_metric_sets,
        "findings": findings,
        "stage_rows": stage_rows,
        "summaries": summaries,
        "fmax_points": fmax_points,
        "cycle_points": cycle_points,
        "resource_points": resource_points,
        "worst_wns_ns": min(worst_wns_values) if worst_wns_values else None,
        "avg_cpi": sum(pipeline_cpi_values) / len(pipeline_cpi_values) if pipeline_cpi_values else None,
        "avg_route_share_pct": sum(route_share_candidates) / len(route_share_candidates) if route_share_candidates else None,
        "max_logic_levels": max(logic_level_candidates) if logic_level_candidates else None,
        "target_fmax_mhz": target_fmax_mhz,
        "overall_status": overall_status,
        "soc_perf": soc_perf,
    }


def render_svg_panel(title: str, note: str, svg: str, *, extra_class: str = "", extra_html: str = "") -> str:
    classes = "report-panel chart-panel"
    if extra_class:
        classes += f" {extra_class}"
    lines = [
        f'<section class="{classes}">',
        f"<h2>{html.escape(title)}</h2>",
        f'<p class="panel-note">{html.escape(note)}</p>',
        '<div class="generated-chart" data-chart-engine="python-svg">',
        svg,
        "</div>",
    ]
    if extra_html:
        lines.append(extra_html)
    lines.append("</section>")
    return "\n".join(lines)


def render_multi_series_svg(
    title: str,
    series_labels: list[str],
    rows: list[tuple[str, list[tuple[str, str, float]]]],
    *,
    palette: list[str] | None = None,
) -> str:
    if not rows or not series_labels:
        return ""

    palette = palette or [CHART_COLORS["blue"], CHART_COLORS["green"], CHART_COLORS["amber"], "#8b5cf6"]
    rows = rows[:10]
    series_count = max(1, len(series_labels))
    row_height = max(58, 30 + series_count * 13)
    width = 1000
    top = 108
    bottom = 38
    label_width = 260
    chart_x = 300
    chart_width = 500
    height = top + len(rows) * row_height + bottom
    legend_parts: list[str] = []
    legend_x = chart_x
    for index, series_label in enumerate(series_labels):
        color = palette[index % len(palette)]
        x_pos = legend_x + index * 158
        legend_parts.append(
            f'<circle cx="{x_pos}" cy="70" r="6" fill="{color}"/>'
            f'<text x="{x_pos + 12}" y="75" fill="{CHART_COLORS["muted"]}" font-size="13">{svg_text(compact_chart_label(series_label, limit=18))}</text>'
        )

    svg_lines = [
        f'<svg class="svg-chart" viewBox="0 0 {width} {height}" role="img" aria-label="{svg_text(title)}" xmlns="http://www.w3.org/2000/svg">',
        f'<rect x="0" y="0" width="{width}" height="{height}" rx="24" fill="{CHART_COLORS["panel"]}"/>',
        f'<text x="28" y="42" fill="{CHART_COLORS["ink"]}" font-size="24" font-weight="760">{svg_text(title)}</text>',
        *legend_parts,
    ]

    for row_index, (metric, values) in enumerate(rows):
        y_base = top + row_index * row_height
        numeric_values = [numeric for _, _, numeric in values]
        min_value = min(0.0, *numeric_values)
        max_value = max(0.0, *numeric_values)
        if math.isclose(min_value, max_value):
            max_value = min_value + 1.0
        scale = max_value - min_value

        def x_for(number: float) -> float:
            return chart_x + ((number - min_value) / scale) * chart_width

        zero_x = x_for(0.0)
        svg_lines.extend(
            [
                f'<line x1="24" y1="{y_base - 14}" x2="{width - 28}" y2="{y_base - 14}" stroke="{CHART_COLORS["line"]}" stroke-width="1"/>',
                f'<text x="28" y="{y_base + 17}" fill="{CHART_COLORS["ink"]}" font-size="15" font-weight="700">{svg_text(compact_chart_label(metric, limit=32))}</text>',
                f'<line x1="{zero_x:.1f}" y1="{y_base - 2}" x2="{zero_x:.1f}" y2="{y_base + row_height - 24}" stroke="#cbd5e1" stroke-width="1"/>',
            ]
        )
        bar_height = max(7, min(12, 32 // series_count))
        for series_index, (series_label, raw_value, numeric_value) in enumerate(values):
            color = palette[series_index % len(palette)]
            if numeric_value < 0:
                color = CHART_COLORS["red"]
            value_x = x_for(numeric_value)
            bar_x = min(zero_x, value_x)
            bar_width = max(2.0, abs(value_x - zero_x))
            bar_y = y_base + 28 + series_index * (bar_height + 5)
            label_x = min(width - 150, max(chart_x + 8, max(zero_x, value_x) + 10))
            svg_lines.extend(
                [
                    f'<rect x="{bar_x:.1f}" y="{bar_y}" width="{bar_width:.1f}" height="{bar_height}" rx="{bar_height / 2:.1f}" fill="{color}"/>',
                    f'<text x="{label_x:.1f}" y="{bar_y + bar_height}" fill="{CHART_COLORS["muted"]}" font-size="12">{svg_text(compact_chart_label(raw_value, limit=24))}</text>',
                ]
            )
        svg_lines.append(
            f'<text x="{chart_x + chart_width + 28}" y="{y_base + 17}" fill="{CHART_COLORS["muted"]}" font-size="12">range {svg_text(chart_number(min_value))} to {svg_text(chart_number(max_value))}</text>'
        )

    svg_lines.append("</svg>")
    return "\n".join(svg_lines)


def render_metric_comparison_svg(table: dict[str, Any], chart_index: int) -> str:
    header = [str(cell) for cell in table.get("header", [])]
    rows = list(table.get("rows", []))
    if len(header) < 3 or header[0] != "Metric":
        return ""

    series_labels = header[1:3]
    parsed_rows: list[tuple[str, list[tuple[str, str, float]]]] = []
    for row in rows:
        if len(row) < 3:
            continue
        values: list[tuple[str, str, float]] = []
        for series_index, series_label in enumerate(series_labels, start=1):
            number = parse_first_number(row[series_index])
            if number is None:
                continue
            values.append((series_label, str(row[series_index]), number))
        if values:
            parsed_rows.append((str(row[0]), values))
    if not parsed_rows:
        return ""

    svg = render_multi_series_svg(f"Architecture Metric Comparison {chart_index}", series_labels, parsed_rows)
    if not svg:
        return ""
    return render_svg_panel(
        f"Architecture Metric Comparison {chart_index}",
        "Each metric uses its own zero-based range so timing, area, and runtime can be compared without hiding small values.",
        svg,
    )


def render_timing_distribution_chart(table: dict[str, Any], chart_index: int) -> str:
    header = [str(cell) for cell in table.get("header", [])]
    if len(header) < 3 or header[0] != "Metric":
        return ""
    if not {"Worst", "P90", "Median", "Average"}.intersection(header[1:]):
        return ""

    series_labels = header[1:]
    parsed_rows: list[tuple[str, list[tuple[str, str, float]]]] = []
    for row in table.get("rows", []):
        if len(row) < 2:
            continue
        values: list[tuple[str, str, float]] = []
        for index, series_label in enumerate(series_labels, start=1):
            if len(row) <= index:
                continue
            number = parse_first_number(row[index])
            if number is not None:
                values.append((series_label, str(row[index]), number))
        if values:
            parsed_rows.append((str(row[0]), values))
    if not parsed_rows:
        return ""

    svg = render_multi_series_svg(
        f"Timing Distribution {chart_index}",
        series_labels,
        parsed_rows,
        palette=[CHART_COLORS["red"], CHART_COLORS["amber"], CHART_COLORS["blue"], CHART_COLORS["green"]],
    )
    if not svg:
        return ""
    return render_svg_panel(
        f"Timing Distribution {chart_index}",
        "Worst, P90, median, and average values are plotted per timing metric to expose tail behavior.",
        svg,
    )


def render_stage_boundary_svg(rows: list[tuple[str, str, float, float | None]], *, title: str = "Stage Boundary Timing") -> str:
    if not rows:
        return ""

    width = 1000
    row_height = 66
    top = 122
    bottom = 52
    chart_x = 330
    chart_width = 500
    height = top + len(rows) * row_height + bottom
    max_period = max(period for _, _, period, _ in rows) or 1.0
    bottleneck_period = max_period
    route_points: list[str] = []
    route_marker_lines: list[str] = []
    svg_lines = [
        f'<svg class="svg-chart" viewBox="0 0 {width} {height}" role="img" aria-label="Stage boundary timing chart" xmlns="http://www.w3.org/2000/svg">',
        f'<rect x="0" y="0" width="{width}" height="{height}" rx="24" fill="{CHART_COLORS["panel"]}"/>',
        f'<text x="28" y="42" fill="{CHART_COLORS["ink"]}" font-size="24" font-weight="760">{svg_text(title)}</text>',
        f'<circle cx="{chart_x}" cy="70" r="6" fill="{CHART_COLORS["blue"]}"/><text x="{chart_x + 12}" y="75" fill="{CHART_COLORS["muted"]}" font-size="13">minimum period, normalized to slowest stage</text>',
        f'<circle cx="{chart_x + 330}" cy="70" r="6" fill="{CHART_COLORS["amber"]}"/><text x="{chart_x + 342}" y="75" fill="{CHART_COLORS["muted"]}" font-size="13">route share line, 0-100%</text>',
    ]

    for row_index, (stage, boundary, period, route_share) in enumerate(rows):
        y_base = top + row_index * row_height
        is_bottleneck = math.isclose(period, bottleneck_period)
        if is_bottleneck:
            svg_lines.append(
                f'<rect x="18" y="{y_base - 22}" width="{width - 36}" height="{row_height - 8}" rx="14" fill="#fff7ed"/>'
            )
        svg_lines.extend(
            [
                f'<line x1="24" y1="{y_base - 22}" x2="{width - 28}" y2="{y_base - 22}" stroke="{CHART_COLORS["line"]}" stroke-width="1"/>',
                f'<text x="28" y="{y_base + 4}" fill="{CHART_COLORS["ink"]}" font-size="15" font-weight="760">{svg_text(compact_chart_label(stage, limit=22))}</text>',
                f'<text x="28" y="{y_base + 25}" fill="{CHART_COLORS["muted"]}" font-size="12">{svg_text(compact_chart_label(boundary, limit=42))}</text>',
            ]
        )
        period_width = max(2.0, (period / max_period) * chart_width)
        bar_y = y_base - 1
        period_color = CHART_COLORS["red"] if is_bottleneck else CHART_COLORS["blue"]
        svg_lines.extend(
            [
                f'<rect x="{chart_x}" y="{bar_y}" width="{chart_width}" height="13" rx="6.5" fill="#eef2f7"/>',
                f'<rect x="{chart_x}" y="{bar_y}" width="{period_width:.1f}" height="13" rx="6.5" fill="{period_color}"/>',
                f'<text x="{chart_x + period_width + 10:.1f}" y="{bar_y + 12}" fill="{CHART_COLORS["ink"]}" font-size="12" font-weight="700">{period:.3f} ns</text>',
            ]
        )
        if route_share is not None:
            share = max(0.0, min(100.0, route_share))
            route_x = chart_x + (share / 100.0) * chart_width
            route_y = y_base + 33
            route_points.append(f"{route_x:.1f},{route_y:.1f}")
            route_marker_lines.extend(
                [
                    f'<circle cx="{route_x:.1f}" cy="{route_y:.1f}" r="5.5" fill="{CHART_COLORS["amber"]}" stroke="#fff" stroke-width="2"/>',
                    f'<text x="{route_x + 10:.1f}" y="{route_y + 4:.1f}" fill="{CHART_COLORS["muted"]}" font-size="12">{route_share:.1f}% route</text>',
                ]
            )

    if len(route_points) >= 2:
        svg_lines.append(
            f'<polyline points="{" ".join(route_points)}" fill="none" stroke="{CHART_COLORS["amber"]}" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" opacity=".85"/>',
        )
    svg_lines.extend(route_marker_lines)
    svg_lines.extend(
        [
            f'<text x="{chart_x}" y="{height - 22}" fill="{CHART_COLORS["muted"]}" font-size="12">0 ns / 0%</text>',
            f'<text x="{chart_x + chart_width - 110}" y="{height - 22}" fill="{CHART_COLORS["muted"]}" font-size="12">{max_period:.3f} ns / 100%</text>',
            "</svg>",
        ]
    )
    return "\n".join(svg_lines)


def render_severity_chart(tables: list[dict[str, Any]]) -> str:
    counts = {"FAIL": 0, "WARN": 0, "PASS": 0, "INFO": 0}
    for table in tables:
        header = [str(cell) for cell in table.get("header", [])]
        if "Severity" not in header:
            continue
        severity_idx = header.index("Severity")
        for row in table.get("rows", []):
            if len(row) > severity_idx:
                counts[extract_status(row[severity_idx])] += 1

    total = sum(counts.values())
    if not total:
        return ""

    width = 1000
    height = 320
    cx = 160
    cy = 168
    radius = 82
    circumference = 2 * math.pi * radius
    offset = 0.0
    status_order = ["FAIL", "WARN", "PASS", "INFO"]
    status_colors = {
        "FAIL": CHART_COLORS["red"],
        "WARN": CHART_COLORS["amber"],
        "PASS": CHART_COLORS["green"],
        "INFO": CHART_COLORS["blue"],
    }
    svg_lines = [
        f'<svg class="svg-chart" viewBox="0 0 {width} {height}" role="img" aria-label="Root cause severity chart" xmlns="http://www.w3.org/2000/svg">',
        f'<rect x="0" y="0" width="{width}" height="{height}" rx="24" fill="{CHART_COLORS["panel"]}"/>',
        f'<text x="28" y="42" fill="{CHART_COLORS["ink"]}" font-size="24" font-weight="760">Root Cause Severity Mix</text>',
        f'<circle cx="{cx}" cy="{cy}" r="{radius}" fill="none" stroke="#eef2f7" stroke-width="30"/>',
    ]
    for status in status_order:
        count = counts[status]
        if count <= 0:
            continue
        dash = (count / total) * circumference
        svg_lines.append(
            f'<circle cx="{cx}" cy="{cy}" r="{radius}" fill="none" stroke="{status_colors[status]}" stroke-width="30" '
            f'stroke-dasharray="{dash:.2f} {circumference - dash:.2f}" stroke-dashoffset="{-offset:.2f}" '
            f'transform="rotate(-90 {cx} {cy})"/>'
        )
        offset += dash
    svg_lines.extend(
        [
            f'<text x="{cx}" y="{cy - 4}" fill="{CHART_COLORS["ink"]}" font-size="34" font-weight="780" text-anchor="middle">{total}</text>',
            f'<text x="{cx}" y="{cy + 22}" fill="{CHART_COLORS["muted"]}" font-size="13" text-anchor="middle">candidate findings</text>',
        ]
    )
    legend_x = 330
    for index, status in enumerate(status_order):
        y = 105 + index * 42
        svg_lines.extend(
            [
                f'<rect x="{legend_x}" y="{y - 14}" width="18" height="18" rx="5" fill="{status_colors[status]}"/>',
                f'<text x="{legend_x + 30}" y="{y}" fill="{CHART_COLORS["ink"]}" font-size="16" font-weight="720">{svg_text(status_badge(status))}</text>',
                f'<text x="{legend_x + 190}" y="{y}" fill="{CHART_COLORS["muted"]}" font-size="15">{counts[status]} finding(s)</text>',
            ]
        )
    svg_lines.append("</svg>")
    return render_svg_panel(
        "Root Cause Severity Mix",
        "Promoted analysis findings are grouped by severity so FAIL/WARN concentration is visible before reading tables.",
        "\n".join(svg_lines),
        extra_class="severity-panel",
    )


def render_metric_chart(table: dict[str, Any], chart_index: int) -> str:
    header = [str(cell) for cell in table.get("header", [])]
    rows = list(table.get("rows", []))
    if len(header) < 3 or "Metric" not in header[0]:
        return ""
    if header[0] == "Metric" and "Delta" in header:
        return render_metric_comparison_svg(table, chart_index)
    left_label = header[1]
    right_label = header[2]
    chart_rows: list[str] = []
    for row in rows:
        if len(row) < 3:
            continue
        metric = str(row[0])
        left_value = parse_first_number(row[1])
        right_value = parse_first_number(row[2])
        if left_value is None and right_value is None:
            continue
        scale = max(abs(left_value or 0.0), abs(right_value or 0.0), 1.0)
        left_width = max(2.0, min(100.0, abs(left_value or 0.0) / scale * 100.0))
        right_width = max(2.0, min(100.0, abs(right_value or 0.0) / scale * 100.0))
        left_class = "negative" if left_value is not None and left_value < 0 else "primary"
        right_class = "negative" if right_value is not None and right_value < 0 else "accent"
        chart_rows.append(
            "\n".join(
                [
                    '<div class="chart-row">',
                    f'<div class="chart-label">{html.escape(metric)}</div>',
                    '<div class="compare-bars">',
                    f'<div class="bar-line"><span>{html.escape(left_label)}</span><strong>{html.escape(str(row[1]))}</strong><div class="bar-track"><div class="bar-fill {left_class}" style="width:{left_width:.1f}%"></div></div></div>',
                    f'<div class="bar-line"><span>{html.escape(right_label)}</span><strong>{html.escape(str(row[2]))}</strong><div class="bar-track"><div class="bar-fill {right_class}" style="width:{right_width:.1f}%"></div></div></div>',
                    "</div>",
                    "</div>",
                ]
            )
        )
    if not chart_rows:
        return ""
    return "\n".join(
        [
            '<section class="report-panel chart-panel">',
            f"<h2>Performance Comparison {chart_index}</h2>",
            '<p class="panel-note">Normalized bars compare the two reported architectures for each parsed metric.</p>',
            *chart_rows,
            "</section>",
        ]
    )


def render_stage_chart(table: dict[str, Any]) -> str:
    header = [str(cell) for cell in table.get("header", [])]
    if "Boundary" not in header or "Stage" not in header:
        return ""
    try:
        boundary_idx = header.index("Boundary")
        stage_idx = header.index("Stage")
        period_idx = header.index("Minimum Period (ns)")
    except ValueError:
        return ""
    datapath_idx = header.index("Data Path (ns)") if "Data Path (ns)" in header else None
    fmax_idx = header.index("Fmax (MHz)") if "Fmax (MHz)" in header else None
    logic_idx = header.index("Logic Levels") if "Logic Levels" in header else None
    route_idx = header.index("Route Share (%)") if "Route Share (%)" in header else None
    start_idx = header.index("Worst Start") if "Worst Start" in header else None
    endpoint_idx = header.index("Worst Endpoint") if "Worst Endpoint" in header else None
    parsed_rows: list[tuple[str, str, float, float | None]] = []
    detail_rows: list[list[str]] = []
    for row in table.get("rows", []):
        if len(row) <= max(boundary_idx, stage_idx, period_idx):
            continue
        period = parse_first_number(row[period_idx])
        if period is None:
            continue
        route_share = parse_first_number(row[route_idx]) if route_idx is not None and len(row) > route_idx else None
        parsed_rows.append((str(row[stage_idx]), str(row[boundary_idx]), period, route_share))
        endpoint = get_cell(row, endpoint_idx)
        detail_rows.append(
            [
                get_cell(row, stage_idx),
                get_cell(row, boundary_idx),
                get_cell(row, datapath_idx),
                get_cell(row, period_idx),
                get_cell(row, fmax_idx),
                get_cell(row, logic_idx),
                get_cell(row, route_idx),
                f"{get_cell(row, start_idx)} -> {endpoint}",
            ]
        )
    if not parsed_rows:
        return ""
    program_title = str(table.get("program_title") or "").strip()
    chart_title = f"Stage Boundary Timing - {program_title}" if program_title else "Stage Boundary Timing"
    svg = render_stage_boundary_svg(parsed_rows, title=chart_title)
    if svg:
        table_rows = []
        for cells in detail_rows:
            table_rows.append(
                "<tr>"
                + "".join(f"<td>{render_inline_markdown(cell)}</td>" for cell in cells)
                + "</tr>"
            )
        detail_table = "\n".join(
            [
                '<div class="stage-detail-table table-container"><table><thead><tr>',
                "<th>Stage</th><th>Boundary</th><th>Data Path</th><th>Min Period</th><th>Fmax</th><th>Logic</th><th>Route</th><th>Worst Start -> Endpoint</th>",
                "</tr></thead><tbody>",
                *table_rows,
                "</tbody></table></div>",
            ]
        )
        return render_svg_panel(
            chart_title,
            "Minimum-period bars expose the timing bottleneck; the amber line overlays route share to show physical-delay pressure.",
            svg,
            extra_class="stage-panel",
            extra_html=detail_table,
        )
    max_period = max(period for _, _, period, _ in parsed_rows) or 1.0
    lines = [
        '<section class="report-panel stage-panel">',
        "<h2>Stage Boundary Timing</h2>",
        '<p class="panel-note">Minimum period and route share highlight the stage most likely to limit timing closure.</p>',
    ]
    for stage, boundary, period, route_share in parsed_rows:
        period_width = max(2.0, min(100.0, period / max_period * 100.0))
        route_width = max(2.0, min(100.0, route_share or 0.0)) if route_share is not None else 0.0
        route_text = f"{route_share:.1f}%" if route_share is not None else "NA"
        lines.extend(
            [
                '<div class="stage-row">',
                f'<div><strong>{html.escape(stage)}</strong><span>{html.escape(boundary)}</span></div>',
                '<div class="stage-bars">',
                f'<div class="bar-line"><span>Minimum period</span><strong>{period:.3f} ns</strong><div class="bar-track"><div class="bar-fill primary" style="width:{period_width:.1f}%"></div></div></div>',
                f'<div class="bar-line"><span>Route share</span><strong>{html.escape(route_text)}</strong><div class="bar-track"><div class="bar-fill amber" style="width:{route_width:.1f}%"></div></div></div>',
                "</div>",
                "</div>",
            ]
        )
    lines.append("</section>")
    return "\n".join(lines)


def badge_class(status: str | None) -> str:
    normalized = normalize_status(status)
    return {"FAIL": "fail", "WARN": "warn", "PASS": "pass", "INFO": "info"}.get(normalized, "info")


def kpi_card(title: str, value: str, unit: str, *, status: str = "INFO") -> str:
    status_class = {
        "FAIL": " alert",
        "WARN": " warn",
        "PASS": " success",
    }.get(normalize_status(status), "")
    unit_html = f' <span class="kpi-unit">{html.escape(unit)}</span>' if unit else ""
    return "\n".join(
        [
            f'<div class="kpi-card{status_class}">',
            f'<div class="kpi-title">{html.escape(title)}</div>',
            f'<div class="kpi-value">{html.escape(value)}{unit_html}</div>',
            "</div>",
        ]
    )


def render_kpi_dashboard(model: dict[str, Any]) -> str:
    worst_wns = model.get("worst_wns_ns")
    avg_cpi = model.get("avg_cpi")
    avg_route = model.get("avg_route_share_pct")
    max_logic = model.get("max_logic_levels")
    wns_status = "FAIL" if worst_wns is not None and worst_wns < 0 else "PASS"
    return "\n".join(
        [
            '<div class="kpi-grid animate-up delay-1">',
            kpi_card("Worst Negative Slack (WNS)", format_kpi_value(worst_wns, precision=3), "ns", status=wns_status),
            kpi_card("Avg. Pipeline Efficiency (CPI)", format_kpi_value(avg_cpi, precision=3), "Cycles/Inst"),
            kpi_card("Avg. Route Delay Share", format_kpi_value(avg_route, precision=1), "%", status="WARN" if avg_route and avg_route >= 70 else "PASS"),
            kpi_card("Max Logic Depth", format_kpi_value(max_logic, precision=0), "Levels", status="WARN" if max_logic and max_logic >= 10 else "PASS"),
            "</div>",
        ]
    )


def render_soc_kpi_dashboard(soc: dict[str, Any]) -> str:
    verdict = normalize_status(str(soc.get("verdict", "INFO")))
    threshold_status = normalize_status(str(soc.get("threshold_status", "INFO")))
    blocked_pct = soc.get("blocked_pct")
    blocked_status = "WARN" if blocked_pct is not None and float(blocked_pct) >= 10.0 else "PASS"
    return "\n".join(
        [
            '<div class="kpi-grid animate-up delay-2">',
            kpi_card("SoC Runtime Verdict", status_badge(verdict), "", status=verdict),
            kpi_card("Program Runtime", format_kpi_value(soc.get("runtime_cycles"), precision=0), "cycles"),
            kpi_card("Runtime CPI", format_kpi_value(soc.get("runtime_cpi"), precision=3), "cycles/inst"),
            kpi_card("SoC Blocked Share", format_kpi_value(blocked_pct, precision=1), "%", status=blocked_status),
            kpi_card("MMIO Traffic Share", format_kpi_value(soc.get("mmio_ratio_pct"), precision=1), "%"),
            kpi_card("Derived Throughput", format_kpi_value(soc.get("mips"), precision=3), "MIPS"),
            kpi_card("Scenario Count", format_kpi_value(soc.get("scenario_count"), precision=0), "case(s)"),
            kpi_card("Regression Thresholds", status_badge(threshold_status), "", status=threshold_status),
            "</div>",
        ]
    )


def render_dashboard_panel(title: str, desc: str, svg: str, insight_title: str, insight: str, *, danger: bool = False) -> str:
    insight_class = "insight-box danger" if danger else "insight-box"
    return "\n".join(
        [
            '<div class="panel">',
            '<div class="panel-header">',
            "<div>",
            f'<div class="panel-title">{html.escape(title)}</div>',
            f'<div class="panel-desc">{html.escape(desc)}</div>',
            "</div>",
            "</div>",
            '<div class="chart-wrapper" data-chart-engine="python-svg">',
            svg,
            "</div>",
            f'<div class="{insight_class}">',
            f"<h4>{html.escape(insight_title)}</h4>",
            f"<p>{render_inline_markdown(insight)}</p>",
            "</div>",
            "</div>",
        ]
    )


def render_pipeline_breakdown_svg(model: dict[str, Any]) -> str:
    cycle_points = list(model.get("cycle_points", []))
    if not cycle_points:
        return ""
    columns = 2 if len(cycle_points) > 1 else 1
    cell_width = 450 if columns > 1 else 500
    cell_height = 240
    rows = math.ceil(len(cycle_points) / columns)
    width = cell_width * columns
    height = cell_height * rows
    radius = 58
    circumference = 2 * math.pi * radius
    svg_lines = [
        f'<svg class="svg-chart compact-visual" viewBox="0 0 {width} {height}" role="img" aria-label="Pipeline execution breakdown by program" xmlns="http://www.w3.org/2000/svg">'
    ]
    for index, point in enumerate(cycle_points):
        column = index % columns
        row = index // columns
        cell_x = column * cell_width
        cell_y = row * cell_height
        cx = cell_x + 122
        cy = cell_y + 118
        legend_x = cell_x + 226
        label = compact_chart_label(point.get("label"), limit=24)
        retired = max(0.0, float(point.get("single") or 0.0))
        pipeline_cycles = max(retired, float(point.get("pipeline") or 0.0))
        overhead = max(0.0, pipeline_cycles - retired)
        total = max(1.0, pipeline_cycles)
        useful_dash = retired / total * circumference
        overhead_dash = overhead / total * circumference
        useful_pct = retired / total * 100.0
        overhead_pct = overhead / total * 100.0
        cpi = pipeline_cycles / retired if retired > 0 else None
        if row > 0:
            svg_lines.append(f'<line x1="{cell_x + 16}" y1="{cell_y}" x2="{cell_x + cell_width - 16}" y2="{cell_y}" stroke="{CHART_COLORS["line"]}" stroke-width="1"/>')
        svg_lines.extend(
            [
                f'<circle cx="{cx}" cy="{cy}" r="{radius}" fill="none" stroke="{CHART_COLORS["bg"]}" stroke-width="20"/>',
                f'<circle cx="{cx}" cy="{cy}" r="{radius}" fill="none" stroke="{CHART_COLORS["blue"]}" stroke-width="20" class="donut-segment" stroke-dasharray="{useful_dash:.1f} {circumference - useful_dash:.1f}" stroke-dashoffset="0" transform="rotate(-90 {cx} {cy})"><title>{svg_text(label)} useful retired cycles: {useful_pct:.1f}%</title></circle>',
                f'<circle cx="{cx}" cy="{cy}" r="{radius}" fill="none" stroke="{CHART_COLORS["amber"]}" stroke-width="20" class="donut-segment" stroke-dasharray="{overhead_dash:.1f} {circumference - overhead_dash:.1f}" stroke-dashoffset="-{useful_dash:.1f}" transform="rotate(-90 {cx} {cy})"><title>{svg_text(label)} pipeline overhead cycles: {overhead_pct:.1f}%</title></circle>',
                f'<text x="{cx}" y="{cy - 5}" fill="{CHART_COLORS["ink"]}" font-size="28" font-weight="800" text-anchor="middle">{pipeline_cycles:.0f}</text>',
                f'<text x="{cx}" y="{cy + 17}" fill="{CHART_COLORS["muted"]}" font-size="12" text-anchor="middle">Total Cycles</text>',
                f'<text x="{legend_x}" y="{cell_y + 58}" class="chart-text-bold">{svg_text(label)}</text>',
                f'<text x="{legend_x}" y="{cell_y + 80}" class="chart-text">CPI {chart_number(cpi)}</text>',
                f'<rect x="{legend_x}" y="{cell_y + 102}" width="12" height="12" rx="3" fill="{CHART_COLORS["blue"]}"/>',
                f'<text x="{legend_x + 20}" y="{cell_y + 113}" class="chart-text-bold">Useful work ({useful_pct:.1f}%)</text>',
                f'<rect x="{legend_x}" y="{cell_y + 134}" width="12" height="12" rx="3" fill="{CHART_COLORS["amber"]}"/>',
                f'<text x="{legend_x + 20}" y="{cell_y + 145}" class="chart-text-bold">Fill/Stall overhead ({overhead_pct:.1f}%)</text>',
            ]
        )
    svg_lines.append("</svg>")
    return "\n".join(svg_lines)


def render_fmax_benchmark_svg(model: dict[str, Any]) -> str:
    points = list(model.get("fmax_points", []))[:6]
    if not points:
        return ""
    width = 500
    height = 240
    chart_left = 62
    chart_right = 462
    chart_top = 42
    chart_bottom = 178
    max_value = max([float(point["value"]) for point in points] + [float(model.get("target_fmax_mhz") or 0.0), 1.0])
    scale_max = max_value * 1.12
    target = model.get("target_fmax_mhz")
    bar_width = min(64, max(26, int((chart_right - chart_left) / max(1, len(points)) * 0.48)))
    gap = (chart_right - chart_left) / max(1, len(points))
    lines = [
        f'<svg class="svg-chart compact-visual" viewBox="0 0 {width} {height}" role="img" aria-label="Fmax benchmark comparison" xmlns="http://www.w3.org/2000/svg">',
        f'<line x1="{chart_left}" y1="{chart_bottom}" x2="{chart_right}" y2="{chart_bottom}" stroke="{CHART_COLORS["line"]}" stroke-width="2"/>',
    ]
    if target:
        target_y = chart_bottom - (float(target) / scale_max) * (chart_bottom - chart_top)
        lines.extend(
            [
                f'<line x1="{chart_left}" y1="{target_y:.1f}" x2="{chart_right}" y2="{target_y:.1f}" stroke="{CHART_COLORS["red"]}" stroke-width="2" stroke-dasharray="6,4"/>',
                f'<rect x="{chart_right - 126}" y="4" width="126" height="28" rx="8" fill="{CHART_COLORS["red_soft"]}"/>',
                f'<text x="{chart_right - 63}" y="22" class="chart-text" fill="{CHART_COLORS["red"]}" text-anchor="middle" font-weight="700">Target {target:.1f} MHz</text>',
            ]
        )
    for index, point in enumerate(points):
        value = float(point["value"])
        x = chart_left + gap * index + (gap - bar_width) / 2
        bar_height = (value / scale_max) * (chart_bottom - chart_top)
        y = chart_bottom - bar_height
        color = CHART_COLORS["green"] if target and value >= float(target) else CHART_COLORS["amber"]
        lines.extend(
            [
                f'<rect class="bar" x="{x:.1f}" y="{y:.1f}" width="{bar_width}" height="{bar_height:.1f}" rx="5" fill="{color}"><title>{value:.3f} MHz</title></rect>',
                f'<text x="{x + bar_width / 2:.1f}" y="{y - 8:.1f}" class="chart-text-bold" text-anchor="middle" fill="{color}">{value:.1f}</text>',
                f'<text x="{x + bar_width / 2:.1f}" y="205" class="chart-text-bold" text-anchor="middle">{svg_text(compact_chart_label(point.get("label"), limit=14))}</text>',
            ]
        )
    lines.append("</svg>")
    return "\n".join(lines)


def normalize_pipeline_stage(value: Any) -> str:
    stage = str(value or "").strip().upper()
    if stage in {"IF", "ID", "EX", "MEM", "WB"}:
        return stage
    for candidate in ("IF", "ID", "EX", "MEM", "WB"):
        if re.search(rf"\b{candidate}\b", stage):
            return candidate
    return stage


def select_physical_delay_stage_rows(stage_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    stage_order = ["IF", "ID", "EX", "MEM", "WB"]
    selected: dict[str, dict[str, Any]] = {}
    for row in stage_rows:
        stage = normalize_pipeline_stage(row.get("stage"))
        if stage not in stage_order:
            continue
        row_with_stage = dict(row)
        row_with_stage["stage"] = stage
        current = selected.get(stage)
        row_period = float(row.get("period_ns") or 0.0)
        current_period = float(current.get("period_ns") or 0.0) if current else -1.0
        if current is None or row_period > current_period:
            selected[stage] = row_with_stage
    return [selected[stage] for stage in stage_order if stage in selected]


def group_stage_rows_by_program(stage_rows: list[dict[str, Any]]) -> list[tuple[str, list[dict[str, Any]]]]:
    grouped: dict[str, list[dict[str, Any]]] = {}
    for row in stage_rows:
        label = str(row.get("program_title") or "Selected Benchmark").strip() or "Selected Benchmark"
        grouped.setdefault(label, []).append(row)
    return [(label, rows) for label, rows in grouped.items()]


def render_physical_delay_stack_svg(model: dict[str, Any]) -> str:
    grouped_rows = [
        (label, selected_rows)
        for label, program_rows in group_stage_rows_by_program(list(model.get("stage_rows", [])))
        if (selected_rows := select_physical_delay_stage_rows(program_rows))
    ]
    if not grouped_rows:
        return ""
    columns = 2 if len(grouped_rows) > 1 else 1
    cell_width = 450 if columns > 1 else 500
    cell_height = 250
    row_count = math.ceil(len(grouped_rows) / columns)
    width = cell_width * columns
    height = cell_height * row_count
    max_delay = max(
        float(row.get("datapath_ns") or row.get("period_ns") or 1.0)
        for _, rows in grouped_rows
        for row in rows
    ) or 1.0
    bar_scale_width = 280 if columns > 1 else 330
    scale = bar_scale_width / max_delay
    lines = [
        f'<svg class="svg-chart compact-visual" viewBox="0 0 {width} {height}" role="img" aria-label="Physical delay stack by program" xmlns="http://www.w3.org/2000/svg">',
        f'<text x="{width - 176}" y="22" class="chart-text">■ Logic Delay</text>',
        f'<text x="{width - 176}" y="40" class="chart-text" fill="{CHART_COLORS["muted"]}">■ Routing Delay</text>',
    ]
    for group_index, (label, rows) in enumerate(grouped_rows):
        column = group_index % columns
        row_group = group_index // columns
        cell_x = column * cell_width
        cell_y = row_group * cell_height
        x0 = cell_x + (74 if columns > 1 else 82)
        value_x_limit = cell_x + cell_width - 22
        max_period = max(float(row.get("period_ns") or 0.0) for row in rows) or 0.0
        if row_group > 0:
            lines.append(f'<line x1="{cell_x + 16}" y1="{cell_y}" x2="{cell_x + cell_width - 16}" y2="{cell_y}" stroke="{CHART_COLORS["line"]}" stroke-width="1"/>')
        lines.append(
            f'<text x="{cell_x + 24}" y="{cell_y + 28}" class="chart-text-bold">{svg_text(compact_chart_label(label, limit=24))}</text>'
        )
        for index, row in enumerate(rows):
            y = cell_y + 62 + index * 34
            datapath = float(row.get("datapath_ns") or row.get("period_ns") or 0.0)
            route_share = float(row.get("route_share_pct") or 0.0)
            route_delay = datapath * route_share / 100.0
            logic_delay = max(0.0, datapath - route_delay)
            logic_width = logic_delay * scale
            route_width = route_delay * scale
            is_bottleneck = math.isclose(float(row.get("period_ns") or 0.0), max_period)
            logic_color = CHART_COLORS["red"] if is_bottleneck else CHART_COLORS["ink"]
            route_color = CHART_COLORS["red_soft"] if is_bottleneck else CHART_COLORS["line"]
            lines.extend(
                [
                    f'<text x="{x0 - 28}" y="{y + 12}" class="chart-text-bold" text-anchor="end">{svg_text(compact_chart_label(row.get("stage"), limit=8))}</text>',
                    f'<rect class="bar" x="{x0}" y="{y}" width="{logic_width:.1f}" height="16" fill="{logic_color}"/>',
                    f'<rect class="bar" x="{x0 + logic_width + 2:.1f}" y="{y}" width="{route_width:.1f}" height="16" fill="{route_color}"><title>{svg_text(label)} route share {route_share:.1f}%</title></rect>',
                    f'<text x="{min(value_x_limit, x0 + logic_width + route_width + 14):.1f}" y="{y + 12}" class="chart-text-bold" fill="{logic_color if is_bottleneck else CHART_COLORS["muted"]}">{float(row.get("period_ns") or datapath):.3f} ns</text>',
                ]
            )
    lines.append("</svg>")
    return "\n".join(lines)


def render_resource_utilization_svg(model: dict[str, Any]) -> str:
    points = list(model.get("resource_points", []))[:6]
    if not points:
        return ""
    max_value = max([float(point.get("luts") or 0.0) for point in points] + [float(point.get("registers") or 0.0) for point in points] + [1.0])
    width = 760
    height = 250
    label_x = 160
    bar_x = 186
    chart_width = 470
    axis_y = 212
    value_limit = width - 24
    lines = [
        f'<svg class="svg-chart compact-visual" viewBox="0 0 {width} {height}" role="img" aria-label="Hardware resource utilization" xmlns="http://www.w3.org/2000/svg">',
        f'<line x1="{bar_x}" y1="{axis_y}" x2="{bar_x + chart_width}" y2="{axis_y}" stroke="{CHART_COLORS["line"]}" stroke-width="2"/>',
        f'<rect x="{width - 178}" y="20" width="12" height="12" rx="3" fill="{CHART_COLORS["purple"]}"/><text x="{width - 158}" y="31" class="chart-text">LUTs</text>',
        f'<rect x="{width - 178}" y="42" width="12" height="12" rx="3" fill="{CHART_COLORS["tertiary"]}"/><text x="{width - 158}" y="53" class="chart-text">Registers</text>',
    ]
    for index, point in enumerate(points):
        y = 78 + index * 54
        label = compact_chart_label(point.get("label"), limit=24)
        lut_width = (float(point.get("luts") or 0.0) / max_value) * chart_width
        reg_width = (float(point.get("registers") or 0.0) / max_value) * chart_width
        lines.extend(
            [
                f'<text x="{label_x}" y="{y + 13}" class="chart-text-bold" text-anchor="end">{svg_text(label)}</text>',
                f'<rect class="bar" x="{bar_x}" y="{y}" width="{lut_width:.1f}" height="14" rx="4" fill="{CHART_COLORS["purple"]}"/>',
                f'<text x="{min(value_limit, bar_x + lut_width + 14):.1f}" y="{y + 12}" class="chart-text-bold">{float(point.get("luts") or 0.0):,.0f}</text>',
                f'<rect class="bar" x="{bar_x}" y="{y + 20}" width="{reg_width:.1f}" height="14" rx="4" fill="{CHART_COLORS["tertiary"]}"/>',
                f'<text x="{min(value_limit, bar_x + reg_width + 14):.1f}" y="{y + 32}" class="chart-text">{float(point.get("registers") or 0.0):,.0f}</text>',
            ]
        )
    lines.append("</svg>")
    return "\n".join(lines)


def render_soc_execution_window_svg(soc: dict[str, Any]) -> str:
    rows = list(soc.get("execution_rows", []))
    if not rows:
        return ""
    preferred_order = {
        "program_runtime": 0,
        "input_to_visible_done": 1,
        "sort_start_to_done": 2,
        "reset_to_ready": 3,
        "input_to_service": 4,
        "reset_to_first_retire": 5,
    }
    rows = sorted(rows, key=lambda row: preferred_order.get(str(row.get("Window", "")).strip(), 50))[:6]
    max_cycles = max([first_row_number(row, "Cycles") or 0.0 for row in rows] + [1.0])
    width = 900
    row_height = 42
    top = 82
    height = top + len(rows) * row_height + 34
    label_x = 34
    bar_x = 238
    bar_width = 430
    scale = bar_width / max_cycles
    lines = [
        f'<svg class="svg-chart compact-visual" viewBox="0 0 {width} {height}" role="img" aria-label="SoC execution window stall mix" xmlns="http://www.w3.org/2000/svg">',
        f'<text x="28" y="32" class="chart-text-bold">Execution windows</text>',
        f'<rect x="{bar_x}" y="22" width="12" height="12" rx="3" fill="{CHART_COLORS["blue"]}"/><text x="{bar_x + 20}" y="33" class="chart-text">retired/other</text>',
        f'<rect x="{bar_x + 132}" y="22" width="12" height="12" rx="3" fill="{CHART_COLORS["amber"]}"/><text x="{bar_x + 152}" y="33" class="chart-text">APB stall</text>',
        f'<rect x="{bar_x + 250}" y="22" width="12" height="12" rx="3" fill="{CHART_COLORS["purple"]}"/><text x="{bar_x + 270}" y="33" class="chart-text">load-use</text>',
    ]
    for index, row in enumerate(rows):
        y = top + index * row_height
        window = compact_chart_label(row.get("Window"), limit=26)
        cycles = first_row_number(row, "Cycles") or 0.0
        apb = min(cycles, first_row_number(row, "APB Stall") or 0.0)
        load_use = min(max(0.0, cycles - apb), first_row_number(row, "LoadUse") or 0.0)
        other = max(0.0, cycles - apb - load_use)
        other_width = other * scale
        apb_width = apb * scale
        load_width = load_use * scale
        blocked = first_row_number(row, "SoC Blocked")
        blocked_text = f"blocked {blocked:,.0f}" if blocked is not None else "blocked NA"
        lines.extend(
            [
                f'<text x="{label_x}" y="{y + 14}" class="chart-text-bold">{svg_text(window)}</text>',
                f'<rect x="{bar_x}" y="{y}" width="{bar_width}" height="18" rx="5" fill="{CHART_COLORS["bg"]}"/>',
                f'<rect class="bar" x="{bar_x}" y="{y}" width="{other_width:.1f}" height="18" rx="5" fill="{CHART_COLORS["blue"]}"/>',
                f'<rect class="bar" x="{bar_x + other_width:.1f}" y="{y}" width="{apb_width:.1f}" height="18" fill="{CHART_COLORS["amber"]}"/>',
                f'<rect class="bar" x="{bar_x + other_width + apb_width:.1f}" y="{y}" width="{load_width:.1f}" height="18" fill="{CHART_COLORS["purple"]}"/>',
                f'<text x="{bar_x + bar_width + 18}" y="{y + 13}" class="chart-text-bold">{cycles:,.0f} cycles</text>',
                f'<text x="{bar_x + bar_width + 132}" y="{y + 13}" class="chart-text">{svg_text(blocked_text)}</text>',
            ]
        )
    lines.append("</svg>")
    return "\n".join(lines)


def render_soc_bus_mix_svg(soc: dict[str, Any]) -> str:
    row = (list(soc.get("bus_rows", [])) or [{}])[0]
    values = [
        ("Fetch requests", first_row_number(row, "Fetch Req"), CHART_COLORS["blue"]),
        ("Data requests", first_row_number(row, "Data Req"), CHART_COLORS["ink"]),
        ("RAM access", (first_row_number(row, "RAM R") or 0.0) + (first_row_number(row, "RAM W") or 0.0), CHART_COLORS["green"]),
        ("MMIO access", (first_row_number(row, "MMIO R") or 0.0) + (first_row_number(row, "MMIO W") or 0.0), CHART_COLORS["amber"]),
        ("Fetch wait", first_row_number(row, "Fetch Wait"), CHART_COLORS["red"]),
    ]
    values = [(label, value, color) for label, value, color in values if value is not None]
    if not values:
        return ""
    width = 760
    height = 270
    label_x = 152
    bar_x = 184
    bar_width = 430
    max_value = max([float(value) for _, value, _ in values] + [1.0])
    lines = [
        f'<svg class="svg-chart compact-visual" viewBox="0 0 {width} {height}" role="img" aria-label="SoC bus and memory traffic mix" xmlns="http://www.w3.org/2000/svg">',
        f'<text x="28" y="34" class="chart-text-bold">Bus traffic mix</text>',
        f'<text x="28" y="58" class="chart-text">MMIO ratio {chart_number(soc.get("mmio_ratio_pct"))}% of data traffic</text>',
    ]
    for index, (label, value, color) in enumerate(values):
        y = 86 + index * 34
        value_width = float(value) / max_value * bar_width
        lines.extend(
            [
                f'<text x="{label_x}" y="{y + 12}" class="chart-text-bold" text-anchor="end">{svg_text(label)}</text>',
                f'<rect x="{bar_x}" y="{y}" width="{bar_width}" height="16" rx="5" fill="{CHART_COLORS["bg"]}"/>',
                f'<rect class="bar" x="{bar_x}" y="{y}" width="{value_width:.1f}" height="16" rx="5" fill="{color}"/>',
                f'<text x="{min(width - 24, bar_x + value_width + 14):.1f}" y="{y + 12}" class="chart-text-bold">{float(value):,.0f}</text>',
            ]
        )
    lines.append("</svg>")
    return "\n".join(lines)


def render_soc_interrupt_latency_svg(soc: dict[str, Any]) -> str:
    rows = [
        row
        for row in list(soc.get("interrupt_rows", []))
        if (first_row_number(row, "Asserts") or 0.0) > 0 or (first_row_number(row, "Service") or 0.0) > 0
    ]
    if not rows:
        return ""
    rows = sorted(rows, key=lambda row: first_row_number(row, "Service") or 0.0, reverse=True)[:6]
    width = 760
    row_height = 38
    top = 72
    height = top + len(rows) * row_height + 32
    label_x = 136
    bar_x = 168
    bar_width = 420
    max_service = max([first_row_number(row, "Service") or 0.0 for row in rows] + [1.0])
    lines = [
        f'<svg class="svg-chart compact-visual" viewBox="0 0 {width} {height}" role="img" aria-label="Interrupt service latency" xmlns="http://www.w3.org/2000/svg">',
        f'<text x="28" y="34" class="chart-text-bold">Interrupt latency</text>',
        f'<text x="28" y="56" class="chart-text">Active interrupt sources ranked by service cycles</text>',
    ]
    for index, row in enumerate(rows):
        y = top + index * row_height
        source = compact_chart_label(row.get("Source"), limit=18)
        service = first_row_number(row, "Service") or 0.0
        asserts = first_row_number(row, "Asserts") or 0.0
        service_width = service / max_service * bar_width
        color = CHART_COLORS["red"] if service == max_service and max_service > 1000 else CHART_COLORS["amber"]
        lines.extend(
            [
                f'<text x="{label_x}" y="{y + 12}" class="chart-text-bold" text-anchor="end">{svg_text(source)}</text>',
                f'<rect x="{bar_x}" y="{y}" width="{bar_width}" height="16" rx="5" fill="{CHART_COLORS["bg"]}"/>',
                f'<rect class="bar" x="{bar_x}" y="{y}" width="{service_width:.1f}" height="16" rx="5" fill="{color}"/>',
                f'<text x="{min(width - 24, bar_x + service_width + 14):.1f}" y="{y + 12}" class="chart-text-bold">{service:,.0f} cycles</text>',
                f'<text x="{width - 116}" y="{y + 12}" class="chart-text">{asserts:.0f} assert(s)</text>',
            ]
        )
    lines.append("</svg>")
    return "\n".join(lines)


def render_soc_e2e_latency_svg(soc: dict[str, Any]) -> str:
    row = (list(soc.get("e2e_rows", [])) or [{}])[0]
    metrics = [
        ("Reset -> Ready", first_row_number(row, "Reset->Ready")),
        ("External Input", first_row_number(row, "External Input Line")),
        ("Input -> Service", first_row_number(row, "Input->Service")),
        ("Sort -> Done", first_row_number(row, "Sort->Done")),
        ("Done -> UART", first_row_number(row, "Done->UART Report")),
        ("Input -> Visible", first_row_number(row, "Input->Visible Done")),
    ]
    metrics = [(label, value) for label, value in metrics if value is not None]
    if not metrics:
        return ""
    width = 760
    row_height = 34
    top = 76
    height = top + len(metrics) * row_height + 32
    label_x = 168
    bar_x = 198
    bar_width = 408
    max_value = max([float(value) for _, value in metrics] + [1.0])
    lines = [
        f'<svg class="svg-chart compact-visual" viewBox="0 0 {width} {height}" role="img" aria-label="SoC end-to-end latency" xmlns="http://www.w3.org/2000/svg">',
        f'<text x="28" y="34" class="chart-text-bold">End-to-end latency</text>',
        f'<text x="28" y="56" class="chart-text">Observable scenario milestones in core cycles</text>',
    ]
    for index, (label, value) in enumerate(metrics):
        y = top + index * row_height
        value_width = float(value) / max_value * bar_width
        color = CHART_COLORS["blue"] if label != "Input -> Visible" else CHART_COLORS["amber"]
        lines.extend(
            [
                f'<text x="{label_x}" y="{y + 12}" class="chart-text-bold" text-anchor="end">{svg_text(label)}</text>',
                f'<rect x="{bar_x}" y="{y}" width="{bar_width}" height="16" rx="5" fill="{CHART_COLORS["bg"]}"/>',
                f'<rect class="bar" x="{bar_x}" y="{y}" width="{value_width:.1f}" height="16" rx="5" fill="{color}"/>',
                f'<text x="{min(width - 24, bar_x + value_width + 14):.1f}" y="{y + 12}" class="chart-text-bold">{float(value):,.0f}</text>',
            ]
        )
    lines.append("</svg>")
    return "\n".join(lines)


def soc_has_raw_metrics(soc: dict[str, Any]) -> bool:
    raw_keys = (
        "pipeline_raw_rows",
        "bus_raw_rows",
        "apb_raw_rows",
        "apb_reg_rows",
        "irq_raw_rows",
        "periph_raw_rows",
    )
    return any(bool(soc.get(key)) for key in raw_keys)


def parse_metric_pairs(raw_value: Any) -> dict[str, float]:
    metrics: dict[str, float] = {}
    for part in str(raw_value or "").split(","):
        if "=" not in part:
            continue
        key, value = part.split("=", 1)
        key = key.strip()
        number = parse_first_number(value)
        if key and number is not None:
            metrics[key] = number
    return metrics


def render_soc_raw_grouped_bar_svg(
    title: str,
    groups: list[tuple[str, list[tuple[str, float | None, str]]]],
    *,
    max_rows_per_group: int = 14,
) -> str:
    normalized_groups: list[tuple[str, list[tuple[str, float, str]]]] = []
    for group_title, items in groups:
        normalized_items: list[tuple[str, float, str]] = []
        for label, value, color in items:
            if value is None:
                continue
            normalized_items.append((str(label), float(value), color))
        if normalized_items:
            normalized_groups.append((group_title, normalized_items[:max_rows_per_group]))
    if not normalized_groups:
        return ""

    width = 900
    label_x = 220
    bar_x = 248
    bar_width = 430
    row_height = 30
    group_gap = 34
    top = 78
    bottom = 30
    height = top + bottom + sum(group_gap + len(items) * row_height for _, items in normalized_groups)
    lines = [
        f'<svg class="svg-chart compact-visual" viewBox="0 0 {width} {height}" role="img" aria-label="{svg_text(title)}" xmlns="http://www.w3.org/2000/svg">',
        f'<text x="28" y="34" class="chart-text-bold">{svg_text(title)}</text>',
        f'<text x="28" y="58" class="chart-text">Each group is normalized independently so low-volume raw counters remain visible.</text>',
    ]
    y_cursor = top
    for group_title, items in normalized_groups:
        max_value = max([abs(value) for _, value, _ in items] + [1.0])
        lines.extend(
            [
                f'<line x1="28" y1="{y_cursor - 16}" x2="{width - 28}" y2="{y_cursor - 16}" stroke="{CHART_COLORS["line"]}" stroke-width="1"/>',
                f'<text x="28" y="{y_cursor + 2}" class="chart-text-bold">{svg_text(group_title)}</text>',
            ]
        )
        y_cursor += group_gap
        for label, value, color in items:
            y = y_cursor
            value_width = max(2.0, abs(value) / max_value * bar_width)
            value_text = f"{value:,.0f}" if abs(value) >= 10 else chart_number(value)
            lines.extend(
                [
                    f'<text x="{label_x}" y="{y + 13}" class="chart-text-bold" text-anchor="end">{svg_text(compact_chart_label(label, limit=27))}</text>',
                    f'<rect x="{bar_x}" y="{y}" width="{bar_width}" height="16" rx="5" fill="{CHART_COLORS["bg"]}"/>',
                    f'<rect class="bar" x="{bar_x}" y="{y}" width="{value_width:.1f}" height="16" rx="5" fill="{color}"><title>{svg_text(label)}: {svg_text(value_text)}</title></rect>',
                    f'<text x="{min(width - 30, bar_x + value_width + 14):.1f}" y="{y + 12}" class="chart-text-bold">{svg_text(value_text)}</text>',
                ]
            )
            y_cursor += row_height
    lines.append("</svg>")
    return "\n".join(lines)


def render_soc_pipeline_raw_svg(soc: dict[str, Any]) -> str:
    row = (list(soc.get("pipeline_raw_rows", [])) or [{}])[0]
    if not row:
        return ""
    event_items = [
        ("Branch taken", first_row_number(row, "Branch Taken"), CHART_COLORS["amber"]),
        ("Branch flush", first_row_number(row, "Branch Flush"), CHART_COLORS["red"]),
        ("JAL", first_row_number(row, "JAL"), CHART_COLORS["blue"]),
        ("JALR", first_row_number(row, "JALR"), CHART_COLORS["blue"]),
        ("Pipeline flush", first_row_number(row, "Pipe Flush"), CHART_COLORS["red"]),
        ("Pipeline stall", first_row_number(row, "Pipe Stall"), CHART_COLORS["amber"]),
        ("CSR access", first_row_number(row, "CSR"), CHART_COLORS["purple"]),
        ("Load", first_row_number(row, "Load"), CHART_COLORS["green"]),
        ("Store", first_row_number(row, "Store"), CHART_COLORS["green"]),
        ("ALU", first_row_number(row, "ALU"), CHART_COLORS["ink"]),
        ("Branch decode", first_row_number(row, "Branch"), CHART_COLORS["amber"]),
        ("Illegal instruction", first_row_number(row, "Illegal"), CHART_COLORS["red"]),
        ("MRET", first_row_number(row, "MRET"), CHART_COLORS["purple"]),
    ]
    stage_items = [
        ("IF valid cycles", first_row_number(row, "IF Valid"), CHART_COLORS["blue"]),
        ("ID valid cycles", first_row_number(row, "ID Valid"), CHART_COLORS["blue"]),
        ("EX valid cycles", first_row_number(row, "EX Valid"), CHART_COLORS["blue"]),
        ("MEM valid cycles", first_row_number(row, "MEM Valid"), CHART_COLORS["blue"]),
        ("WB valid cycles", first_row_number(row, "WB Valid"), CHART_COLORS["blue"]),
    ]
    return render_soc_raw_grouped_bar_svg(
        "Pipeline RAW Events",
        [("Instruction and control events", event_items), ("Stage valid occupancy", stage_items)],
    )


def render_soc_bus_raw_svg(soc: dict[str, Any]) -> str:
    row = (list(soc.get("bus_raw_rows", [])) or [{}])[0]
    if not row:
        return ""
    wait_items = [
        ("Data bus wait", first_row_number(row, "Wait"), CHART_COLORS["amber"]),
        ("Read wait", first_row_number(row, "Read Wait"), CHART_COLORS["blue"]),
        ("Write wait", first_row_number(row, "Write Wait"), CHART_COLORS["green"]),
        ("RAM wait", first_row_number(row, "RAM Wait"), CHART_COLORS["purple"]),
        ("MMIO wait", first_row_number(row, "MMIO Wait"), CHART_COLORS["red"]),
    ]
    occupancy_items = [
        ("Data bus busy", first_row_number(row, "Busy"), CHART_COLORS["ink"]),
        ("Data bus idle", first_row_number(row, "Idle"), CHART_COLORS["tertiary"]),
    ]
    error_items = [
        ("Response errors", first_row_number(row, "Rsp Err"), CHART_COLORS["red"]),
    ]
    return render_soc_raw_grouped_bar_svg(
        "Data Bus RAW Wait",
        [("Wait cycle split", wait_items), ("Bus occupancy", occupancy_items), ("Error counters", error_items)],
    )


def render_soc_apb_target_raw_svg(soc: dict[str, Any]) -> str:
    rows = list(soc.get("apb_raw_rows", []))
    if not rows:
        return ""
    wait_items: list[tuple[str, float | None, str]] = []
    handshake_items: list[tuple[str, float | None, str]] = []
    for row in rows:
        target = first_row_value(row, "Target") or "APB"
        wait_items.append((f"{target} wait", first_row_number(row, "Wait"), CHART_COLORS["amber"]))
        wait_items.append((f"{target} PREADY wait", first_row_number(row, "PREADY Wait"), CHART_COLORS["red"]))
        handshake = (first_row_number(row, "Setup") or 0.0) + (first_row_number(row, "Enable") or 0.0)
        selects = (first_row_number(row, "PSEL") or 0.0) + (first_row_number(row, "PENABLE") or 0.0)
        handshake_items.append((f"{target} setup/enable", handshake, CHART_COLORS["blue"]))
        handshake_items.append((f"{target} select/enable", selects, CHART_COLORS["green"]))
    wait_items = sorted(wait_items, key=lambda item: float(item[1] or 0.0), reverse=True)
    handshake_items = sorted(handshake_items, key=lambda item: float(item[1] or 0.0), reverse=True)
    return render_soc_raw_grouped_bar_svg(
        "APB Target RAW Wait",
        [("Target wait pressure", wait_items), ("Target handshake volume", handshake_items)],
    )


def render_soc_apb_register_raw_svg(soc: dict[str, Any]) -> str:
    rows = list(soc.get("apb_reg_rows", []))
    if not rows:
        return ""
    wait_items: list[tuple[str, float | None, str]] = []
    access_items: list[tuple[str, float | None, str]] = []
    error_items: list[tuple[str, float | None, str]] = []
    for row in rows:
        label = f"{first_row_value(row, 'Target')}.{first_row_value(row, 'Register')}"
        wait = first_row_number(row, "Wait")
        reads = first_row_number(row, "Reads") or 0.0
        writes = first_row_number(row, "Writes") or 0.0
        pslverr = first_row_number(row, "PSLVERR") or 0.0
        wait_items.append((label, wait, CHART_COLORS["amber"]))
        access_items.append((label, reads + writes, CHART_COLORS["blue"]))
        if pslverr > 0:
            error_items.append((label, pslverr, CHART_COLORS["red"]))
    wait_items = sorted(wait_items, key=lambda item: float(item[1] or 0.0), reverse=True)
    access_items = sorted(access_items, key=lambda item: float(item[1] or 0.0), reverse=True)
    groups = [("Register wait hot spots", wait_items), ("Register access hot spots", access_items)]
    if error_items:
        groups.append(("Register PSLVERR events", sorted(error_items, key=lambda item: float(item[1] or 0.0), reverse=True)))
    return render_soc_raw_grouped_bar_svg("APB Register Access RAW", groups, max_rows_per_group=12)


def render_soc_irq_raw_svg(soc: dict[str, Any]) -> str:
    rows = list(soc.get("irq_raw_rows", []))
    if not rows:
        return ""
    source_rows = [row for row in rows if first_row_value(row, "Source").strip().upper() != "GLOBAL"]
    global_rows = [row for row in rows if first_row_value(row, "Source").strip().upper() == "GLOBAL"]
    hold_items: list[tuple[str, float | None, str]] = []
    event_items: list[tuple[str, float | None, str]] = []
    for row in source_rows:
        source = first_row_value(row, "Source") or "IRQ"
        hold_items.append((f"{source} pending", first_row_number(row, "Pending Cycles"), CHART_COLORS["amber"]))
        hold_items.append((f"{source} line high", first_row_number(row, "Line High"), CHART_COLORS["blue"]))
        hold_items.append((f"{source} in service", first_row_number(row, "In Service"), CHART_COLORS["purple"]))
        event_items.append((f"{source} assert", first_row_number(row, "Assert"), CHART_COLORS["blue"]))
        event_items.append((f"{source} deassert", first_row_number(row, "Deassert"), CHART_COLORS["tertiary"]))
        event_items.append((f"{source} claim", first_row_number(row, "Claim"), CHART_COLORS["green"]))
        event_items.append((f"{source} complete", first_row_number(row, "Complete"), CHART_COLORS["green"]))
        event_items.append((f"{source} masked", first_row_number(row, "Masked"), CHART_COLORS["red"]))
    global_items: list[tuple[str, float | None, str]] = []
    for row in global_rows:
        global_items.extend(
            [
                ("IRQ global enable cycles", first_row_number(row, "Global Enable"), CHART_COLORS["green"]),
                ("Trap entry count", first_row_number(row, "Trap Entry"), CHART_COLORS["blue"]),
                ("Trap exit count", first_row_number(row, "Trap Exit"), CHART_COLORS["blue"]),
                ("MSTATUS.MIE disabled cycles", first_row_number(row, "MIE Disabled"), CHART_COLORS["red"]),
            ]
        )
    hold_items = sorted(hold_items, key=lambda item: float(item[1] or 0.0), reverse=True)
    event_items = sorted(event_items, key=lambda item: float(item[1] or 0.0), reverse=True)
    return render_soc_raw_grouped_bar_svg(
        "Interrupt RAW Timeline",
        [("IRQ source hold cycles", hold_items), ("IRQ source event counts", event_items), ("Global interrupt state", global_items)],
        max_rows_per_group=12,
    )


def render_soc_periph_raw_svg(soc: dict[str, Any]) -> str:
    rows = list(soc.get("periph_raw_rows", []))
    if not rows:
        return ""
    activity_items: list[tuple[str, float | None, str]] = []
    status_items: list[tuple[str, float | None, str]] = []
    for row in rows:
        periph = first_row_value(row, "Peripheral") or "PERIPH"
        for key, value in parse_metric_pairs(row.get("RAW Metrics", "")).items():
            color = CHART_COLORS["amber"] if "busy" in key or "cycles" in key else CHART_COLORS["blue"]
            label = f"{periph}.{key}"
            if any(token in key for token in ("busy", "cycles", "active", "full", "low", "high")):
                activity_items.append((label, value, color))
            else:
                status_items.append((label, value, CHART_COLORS["green"] if "max" in key else color))
    activity_items = sorted(activity_items, key=lambda item: float(item[1] or 0.0), reverse=True)
    status_items = sorted(status_items, key=lambda item: float(item[1] or 0.0), reverse=True)
    return render_soc_raw_grouped_bar_svg(
        "Peripheral RAW Status",
        [("Peripheral busy/backpressure", activity_items), ("Peripheral event and level counters", status_items)],
        max_rows_per_group=12,
    )


def render_soc_raw_dashboard(soc: dict[str, Any]) -> str:
    if not soc_has_raw_metrics(soc):
        return ""
    panel_specs = [
        (
            "Pipeline RAW Events",
            "Instruction class, flush, stall, and per-stage valid-cycle counters from the latest SoCPerf run.",
            render_soc_pipeline_raw_svg(soc),
            "Pipeline Interpretation",
            "Compare stall and flush counters against instruction mix before attributing runtime only to software workload length.",
        ),
        (
            "Data Bus RAW Wait",
            "Raw wait, busy, idle, RAM, MMIO, and response-error counters from the data bus monitor.",
            render_soc_bus_raw_svg(soc),
            "Bus Interpretation",
            "MMIO and RAM wait counters separate peripheral wait pressure from ordinary bus occupancy.",
        ),
        (
            "APB Target RAW Wait",
            "Target-level wait and handshake activity across UART, GPIO, I2C, SPI, INTC, TIMER, and FND.",
            render_soc_apb_target_raw_svg(soc),
            "Target Interpretation",
            "Tall target wait bars point directly to the APB target contributing the most observed backpressure.",
        ),
        (
            "APB Register Access RAW",
            "Register-level read/write and wait hot spots for the APB map.",
            render_soc_apb_register_raw_svg(soc),
            "Register Interpretation",
            "Access hot spots show whether polling is concentrated on status, claim, pending, or data registers.",
        ),
        (
            "Interrupt RAW Timeline",
            "IRQ source event counts, pending/line-high cycles, global enable, trap entry, and trap exit counters.",
            render_soc_irq_raw_svg(soc),
            "IRQ Interpretation",
            "Pending and line-high cycles distinguish slow interrupt service from a source that simply remains asserted.",
        ),
        (
            "Peripheral RAW Status",
            "Peripheral-local busy, FIFO, transfer, NACK, match, and status counters.",
            render_soc_periph_raw_svg(soc),
            "Peripheral Interpretation",
            "Local peripheral counters explain whether APB pressure came from device busy time, FIFO backpressure, or event volume.",
        ),
    ]
    panels = [
        render_dashboard_panel(title, desc, svg, insight_title, insight)
        for title, desc, svg, insight_title, insight in panel_specs
        if svg
    ]
    if not panels:
        return ""
    return "\n".join(
        [
            '<h2 id="soc-raw-dashboard" class="section-title animate-up delay-2">SoC RAW Metrics Dashboard</h2>',
            '<div class="dashboard-stack animate-up delay-2">',
            *panels,
            "</div>",
        ]
    )


def render_soc_runtime_dashboard(model: dict[str, Any]) -> str:
    soc = model.get("soc_perf")
    if not soc:
        return ""
    panels: list[str] = []
    execution_svg = render_soc_execution_window_svg(soc)
    if execution_svg:
        panels.append(
            render_dashboard_panel(
                "SoC Execution Windows",
                "Runtime windows separated into useful/other cycles and tracked stall contributors.",
                execution_svg,
                "Runtime Bottleneck",
                str(soc.get("primary_bottleneck") or "Review the execution-window table for the dominant blocked contributor."),
                danger=normalize_status(str(soc.get("verdict"))) == "FAIL",
            )
        )
    bus_svg = render_soc_bus_mix_svg(soc)
    if bus_svg:
        panels.append(
            render_dashboard_panel(
                "Bus And Memory Traffic",
                "Fetch, data, RAM, and MMIO request volume from the latest SoCPerf scenario.",
                bus_svg,
                "Traffic Interpretation",
                "High MMIO share usually points to peripheral polling, interrupt-service pressure, or APB bridge latency as the next optimization surface.",
                danger=False,
            )
        )
    interrupt_svg = render_soc_interrupt_latency_svg(soc)
    if interrupt_svg:
        panels.append(
            render_dashboard_panel(
                "Interrupt Service Latency",
                "Active interrupt sources ranked by observed service cycles.",
                interrupt_svg,
                "Latency Interpretation",
                "Long service bars are the best candidates for checking vector entry, claim/complete flow, and driver-side wait loops.",
                danger=False,
            )
        )
    e2e_svg = render_soc_e2e_latency_svg(soc)
    if e2e_svg:
        panels.append(
            render_dashboard_panel(
                "E2E Scenario Latency",
                "External input and visible-done milestones from the latest scenario profile.",
                e2e_svg,
                "User-Visible Path",
                str(soc.get("worst_latency") or "The longest milestone defines the user-visible runtime path for this scenario."),
                danger=False,
            )
        )
    stack_html = "\n".join(['<div class="dashboard-stack animate-up delay-2">', *panels, "</div>"]) if panels else ""
    return "\n".join(
        [
            '<h2 id="soc-runtime-dashboard" class="section-title animate-up delay-2">SoC Runtime Dashboard</h2>',
            render_soc_kpi_dashboard(soc),
            stack_html,
            render_soc_raw_dashboard(soc),
        ]
    )


def render_root_cause_table(model: dict[str, Any]) -> str:
    findings = sorted(
        list(model.get("findings", [])),
        key=lambda finding: SEVERITY_RANK.get(extract_status(finding.get("Severity", "")), 1),
        reverse=True,
    )[:3]
    if not findings:
        return ""
    rows = []
    for finding in findings:
        status = extract_status(finding.get("Severity", "INFO"))
        rows.append(
            "\n".join(
                [
                    "<tr>",
                    f'<td><span class="badge {badge_class(status)}">{html.escape(status_badge(status))}</span></td>',
                    f"<td>{render_inline_markdown(finding.get('Category', 'Timing'))}</td>",
                    f"<td><strong>{render_inline_markdown(finding.get('Finding', 'Review required'))}</strong><br><span class=\"muted-text\">{render_inline_markdown(finding.get('Evidence', 'NA'))}</span></td>",
                    f"<td>{render_inline_markdown(finding.get('Impact', 'Review required.'))}</td>",
                    "</tr>",
                ]
            )
        )
    return "\n".join(
        [
            '<h2 class="section-title animate-up delay-3">Automated Root Cause Findings</h2>',
            '<div class="panel animate-up delay-3">',
            '<div class="panel-header"><div><div class="panel-title">Top Critical Analysis Promoted</div>',
            '<div class="panel-desc">Parser-promoted timing risks ranked by severity and decision impact.</div></div></div>',
            '<div class="table-container"><table><thead><tr><th>Severity</th><th>Category</th><th>Finding Details</th><th>System Impact</th></tr></thead><tbody>',
            *rows,
            "</tbody></table></div>",
            "</div>",
        ]
    )


def render_benchmark_breakdowns(model: dict[str, Any]) -> str:
    summaries = list(model.get("summaries", []))
    stage_rows = list(model.get("stage_rows", []))
    if not summaries:
        return ""
    panels: list[str] = ['<h2 class="section-title animate-up delay-3">Detailed Benchmark Breakdowns</h2>']
    for index, summary in enumerate(summaries[:4], start=1):
        program_title = summary.get("_program_title") or f"Benchmark {index}"
        verdict = extract_status(summary.get("Overall verdict", "INFO"))
        primary = summary.get("Primary bottleneck", "NA")
        action = summary.get("First action", "Review the evidence table and rerun timing after the first fix.")
        program_stage_rows = [row for row in stage_rows if row.get("program_title") == program_title]
        program_stage_rows = sorted(program_stage_rows, key=lambda row: float(row.get("period_ns") or 0.0), reverse=True)[:3]
        boundary_rows: list[str] = []
        for row_index, row in enumerate(program_stage_rows):
            row_class = ' class="danger-row"' if row_index == 0 and verdict == "FAIL" else ""
            boundary_rows.append(
                "\n".join(
                    [
                        f"<tr{row_class}>",
                        f"<td><strong>{render_inline_markdown(row.get('stage', 'NA'))}</strong><br><span class=\"muted-text\">{render_inline_markdown(row.get('boundary', 'NA'))}</span></td>",
                        f"<td>{format_kpi_value(row.get('period_ns'), unit='ns', precision=3)}</td>",
                        f"<td>{format_kpi_value(row.get('logic_levels'), precision=0)}</td>",
                        f"<td>{format_kpi_value(row.get('route_share_pct'), unit='%', precision=1)}</td>",
                        f"<td><code>{render_inline_markdown(row.get('worst_start', 'NA'))} → {render_inline_markdown(row.get('worst_endpoint', 'NA'))}</code></td>",
                        "</tr>",
                    ]
                )
            )
        table_html = ""
        if boundary_rows:
            table_html = "\n".join(
                [
                    '<div class="table-container"><table><thead><tr><th>Critical Boundary</th><th>Worst Delay</th><th>Logic Levels</th><th>Route Share</th><th>Bottleneck Start → End Point</th></tr></thead><tbody>',
                    *boundary_rows,
                    "</tbody></table></div>",
                ]
            )
        panels.append(
            "\n".join(
                [
                    '<div class="panel animate-up delay-3">',
                    '<div class="panel-header">',
                    "<div>",
                    f'<div class="panel-title">{index}. {html.escape(program_title)} <span class="badge {badge_class(verdict)}">{html.escape(status_badge(verdict))}</span></div>',
                    f'<div class="panel-desc">{html.escape(primary)}</div>',
                    "</div>",
                    "</div>",
                    f'<div class="insight-box {"danger" if verdict == "FAIL" else ""}"><h4>First Recommended Action</h4><p>{render_inline_markdown(action)}</p></div>',
                    table_html,
                    "</div>",
                ]
            )
        )
    return "\n".join(panels)


def render_dashboard_charts(model: dict[str, Any]) -> str:
    panels: list[str] = []
    pipeline_svg = render_pipeline_breakdown_svg(model)
    if pipeline_svg:
        panels.append(
            render_dashboard_panel(
                "Pipeline Execution Breakdown",
                "Retired work versus fill/stall overhead inferred per timing program image.",
                pipeline_svg,
                "Architecture Insight",
                "Each donut uses that program's actual `Cycles` row: useful work follows the single-cycle retired count, while the gap to pipeline cycles is overhead from fill, stalls, or flush behavior.",
                danger=False,
            )
        )
    fmax_svg = render_fmax_benchmark_svg(model)
    if fmax_svg:
        panels.append(
            render_dashboard_panel(
                "Fmax Benchmark Comparison",
                "Maximum achieved frequency by timing program image.",
                fmax_svg,
                "Timing Margin Insight",
                "Bars below the inferred target line are the first candidates for timing closure; small positive margins should still be treated as fragile.",
                danger=bool(model.get("worst_wns_ns") is not None and model.get("worst_wns_ns") < 0),
            )
        )
    delay_svg = render_physical_delay_stack_svg(model)
    if delay_svg:
        panels.append(
            render_dashboard_panel(
                "Physical Delay Stack",
                "Logic delay versus routing delay for each program's true stage boundaries.",
                delay_svg,
                "Synthesis Action Required",
                "When route share dominates, placement locality, fanout cleanup, and register duplication usually deserve attention before broad RTL rewrites.",
                danger=bool(model.get("avg_route_share_pct") is not None and model.get("avg_route_share_pct") >= 70),
            )
        )
    resource_svg = render_resource_utilization_svg(model)
    if resource_svg:
        panels.append(
            render_dashboard_panel(
                "Hardware Resource Utilization",
                "LUT and register usage trends across timing program images.",
                resource_svg,
                "Area Efficiency Insight",
                "Resource changes show how much logic remains active after synthesis pruning for each benchmark image.",
                danger=False,
            )
        )
    if not panels:
        return ""
    return "\n".join(
        [
            '<h2 class="section-title animate-up delay-2">Architecture Performance Dashboard</h2>',
            '<div class="dashboard-stack animate-up delay-2">',
            *panels,
            "</div>",
        ]
    )


def render_auto_charts(markdown_text: str, *, title: str = "Timing Report") -> str:
    model = collect_visual_model(markdown_text, title=title)
    metric_charts: list[str] = []
    distribution_charts: list[str] = []
    stage_charts: list[str] = []
    tables = model["tables"]
    severity_chart = render_severity_chart(tables)
    for table in tables:
        header = [str(cell) for cell in table.get("header", [])]
        heading = str(table.get("heading", ""))
        if header[:1] == ["Metric"] and len(header) >= 3 and "key metrics" in heading:
            chart = render_metric_chart(table, len(metric_charts) + 1)
            if chart:
                metric_charts.append(chart)
        if header[:1] == ["Metric"] and "timing distribution" in heading:
            chart = render_timing_distribution_chart(table, len(distribution_charts) + 1)
            if chart:
                distribution_charts.append(chart)
        if "Boundary" in header and "Minimum Period (ns)" in header:
            chart = render_stage_chart(table)
            if chart:
                stage_charts.append(chart)
    soc_dashboard = render_soc_runtime_dashboard(model)
    if not severity_chart and not metric_charts and not distribution_charts and not stage_charts and not soc_dashboard:
        return ""
    pipeline_kpis = render_kpi_dashboard(model) if model.get("key_metric_sets") else ""
    pipeline_dashboard = render_dashboard_charts(model)
    stage_section = []
    if stage_charts:
        stage_section = [
            '<h2 class="section-title animate-up delay-3">Stage Boundary Timing</h2>',
            *stage_charts[:4],
        ]
    return "\n".join(
        [
            '<section class="visual-section">',
            pipeline_kpis,
            pipeline_dashboard,
            soc_dashboard,
            *stage_section,
            render_root_cause_table(model),
            '<h2 class="section-title animate-up delay-3">Generated Evidence Charts</h2>',
            '<p class="section-lede">These charts are generated as inline SVG from parsed timing metrics, root-cause findings, and stage-boundary evidence.</p>',
            severity_chart,
            *metric_charts[:4],
            *distribution_charts[:4],
            "</section>",
        ]
    )


def render_inline_markdown(text: str) -> str:
    escaped = html.escape(text)
    escaped = re.sub(r"`([^`]+)`", r"<code>\1</code>", escaped)
    escaped = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", escaped)
    return escaped


def markdown_to_html_body(markdown_text: str) -> str:
    lines = markdown_text.replace("\r\n", "\n").split("\n")
    html_lines: list[str] = []
    idx = 0
    in_ul = False
    in_ol = False
    used_heading_ids: dict[str, int] = {}

    def close_lists() -> None:
        nonlocal in_ul, in_ol
        if in_ul:
            html_lines.append("</ul>")
            in_ul = False
        if in_ol:
            html_lines.append("</ol>")
            in_ol = False

    while idx < len(lines):
        line = lines[idx]
        stripped = line.strip()
        if not stripped:
            close_lists()
            idx += 1
            continue
        if stripped.startswith("<!--") and stripped.endswith("-->"):
            idx += 1
            continue
        if stripped in {"<details>", "</details>"}:
            close_lists()
            html_lines.append(stripped)
            idx += 1
            continue
        if stripped.startswith("<summary>") and stripped.endswith("</summary>"):
            close_lists()
            html_lines.append(stripped)
            idx += 1
            continue
        if MARKDOWN_TABLE_ROW_PATTERN.match(line):
            table_lines: list[str] = []
            while idx < len(lines) and MARKDOWN_TABLE_ROW_PATTERN.match(lines[idx]):
                table_lines.append(lines[idx])
                idx += 1
            if len(table_lines) >= 2 and MARKDOWN_TABLE_SEPARATOR_PATTERN.match(table_lines[1]):
                close_lists()
                header = markdown_table_cells(table_lines[0])
                rows = [markdown_table_cells(row_line) for row_line in table_lines[2:]]
                html_lines.append('<div class="table-scroll"><table>')
                html_lines.append("<thead><tr>" + "".join(f"<th>{render_inline_markdown(cell)}</th>" for cell in header) + "</tr></thead>")
                html_lines.append("<tbody>")
                for row in rows:
                    html_lines.append("<tr>" + "".join(f"<td>{render_inline_markdown(cell)}</td>" for cell in row) + "</tr>")
                html_lines.append("</tbody></table></div>")
            continue
        heading = HEADING_PATTERN.match(line)
        if heading:
            close_lists()
            level = min(6, len(heading.group("hashes")))
            heading_text = heading.group("suffix").strip()
            html_lines.append(f'<h{level} id="{heading_id_for(heading_text, used_heading_ids)}">{render_inline_markdown(heading_text)}</h{level}>')
            idx += 1
            continue
        ordered_match = MARKDOWN_ORDERED_LIST_PATTERN.match(line)
        if ordered_match:
            if in_ul:
                html_lines.append("</ul>")
                in_ul = False
            if not in_ol:
                html_lines.append("<ol>")
                in_ol = True
            html_lines.append(f"<li>{render_inline_markdown(ordered_match.group(1))}</li>")
            idx += 1
            continue
        if stripped.startswith("- "):
            if in_ol:
                html_lines.append("</ol>")
                in_ol = False
            if not in_ul:
                html_lines.append("<ul>")
                in_ul = True
            html_lines.append(f"<li>{render_inline_markdown(stripped[2:].strip())}</li>")
            idx += 1
            continue
        close_lists()
        html_lines.append(f"<p>{render_inline_markdown(stripped)}</p>")
        idx += 1
    close_lists()
    return "\n".join(html_lines)


def render_report_nav(model: dict[str, Any]) -> str:
    nav_links = ['<a class="nav-link" href="#overview"><span>Overview</span></a>']
    seen: set[str] = {"overview"}
    for summary in list(model.get("summaries", []))[:8]:
        title = str(summary.get("_program_title") or "").strip()
        if not title:
            continue
        slug = anchor_slug(title)
        if slug in seen:
            continue
        seen.add(slug)
        label = re.sub(r"\.mem\b", "", title, flags=re.IGNORECASE).strip()
        nav_links.append(f'<a class="nav-link" href="#{html.escape(slug)}"><span>{html.escape(label)}</span></a>')
    if model.get("soc_perf"):
        nav_links.append('<a class="nav-link" href="#soc-runtime-dashboard"><span>SoC Runtime</span></a>')
        if soc_has_raw_metrics(model["soc_perf"]):
            nav_links.append('<a class="nav-link" href="#soc-raw-dashboard"><span>SoC RAW</span></a>')
    return "\n".join(
        [
            '<aside class="side-dashboard" aria-label="Report dashboard">',
            '<div class="side-card">',
            '<div class="side-eyebrow">Dashboard</div>',
            '<div class="side-title">Pipeline Report</div>',
            '<nav class="side-nav">',
            *nav_links,
            "</nav>",
            "</div>",
            "</aside>",
        ]
    )


def render_report_html(markdown_text: str, *, title: str, visual_markdown_text: str | None = None) -> str:
    visual_text = visual_markdown_text or markdown_text
    generated_at = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
    model = collect_visual_model(visual_text, title=title)
    target_fmax = model.get("target_fmax_mhz")
    target_tag = f"🎯 Target Fmax: {target_fmax:.1f} MHz" if target_fmax else "🎯 Target Fmax: inferred from timing metrics"
    status = normalize_status(str(model.get("overall_status", "INFO")))
    soc = model.get("soc_perf")
    soc_tag_html = ""
    if soc:
        soc_status = normalize_status(str(soc.get("verdict", "INFO")))
        soc_tag_html = (
            f'<span class="tag">🧪 SoC Runtime: <span class="badge {badge_class(soc_status)}">{html.escape(status_badge(soc_status))}</span></span>\n'
            f'        <span class="tag">📈 SoC MIPS: {html.escape(format_kpi_value(soc.get("mips"), precision=3))}</span>'
        )
    body_html = markdown_to_html_body(markdown_text)
    chart_html = render_auto_charts(visual_text, title=title)
    nav_html = render_report_nav(model)
    return f"""<!doctype html>
<html lang="ko">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html.escape(title)}</title>
  <style>
    :root {{
      color-scheme: light;
      --bg-color: #f2f4f6;
      --surface-main: #ffffff;
      --surface-sub: #f9fafb;
      --text-primary: #191f28;
      --text-secondary: #8b95a1;
      --text-tertiary: #b0b8c1;
      --toss-blue: #3182f6;
      --toss-blue-light: #e8f3ff;
      --toss-red: #f04452;
      --toss-red-light: #feecef;
      --toss-green: #34c759;
      --toss-green-light: #e3f8eb;
      --toss-orange: #ff8f00;
      --toss-orange-light: #fff4e6;
      --toss-purple: #748edc;
      --line-color: #e5e8eb;
      --radius-sm: 8px;
      --radius-md: 16px;
      --radius-lg: 24px;
      --shadow-sm: 0 2px 8px rgba(0, 0, 0, .04);
      --shadow-md: 0 10px 24px rgba(0, 0, 0, .06);
      --shadow-hover: 0 16px 32px rgba(0, 0, 0, .1);
      font-family: "Pretendard", -apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", "Segoe UI", sans-serif;
    }}
    * {{ box-sizing: border-box; margin: 0; padding: 0; }}
    html {{ scroll-behavior: smooth; }}
    body {{ background: var(--bg-color); color: var(--text-primary); line-height: 1.6; -webkit-font-smoothing: antialiased; }}
    .report-shell {{ max-width: 1760px; margin: 0 auto; padding: 40px 28px 100px; display: grid; grid-template-columns: 248px minmax(0, 1fr); gap: 28px; align-items: start; }}
    .container {{ max-width: none; min-width: 0; margin: 0; padding: 0; }}
    .side-dashboard {{ position: sticky; top: 24px; align-self: start; }}
    .side-card {{ background: var(--surface-main); border: 1px solid var(--line-color); border-radius: var(--radius-lg); box-shadow: var(--shadow-md); padding: 22px; }}
    .side-eyebrow {{ color: var(--toss-blue); font-size: 12px; font-weight: 800; letter-spacing: .4px; text-transform: uppercase; margin-bottom: 6px; }}
    .side-title {{ font-size: 20px; font-weight: 800; color: var(--text-primary); margin-bottom: 18px; }}
    .side-nav {{ display: grid; gap: 8px; }}
    .nav-link {{ display: flex; align-items: center; min-height: 42px; padding: 10px 12px; color: var(--text-primary); text-decoration: none; border-radius: var(--radius-sm); font-size: 14px; font-weight: 720; background: var(--surface-sub); border: 1px solid transparent; }}
    .nav-link:hover {{ color: var(--toss-blue); border-color: var(--toss-blue-light); background: var(--toss-blue-light); }}
    @keyframes fadeInUp {{ from {{ opacity: 0; transform: translateY(16px); }} to {{ opacity: 1; transform: translateY(0); }} }}
    @keyframes grow {{ from {{ transform: scaleX(.08); opacity: .55; }} to {{ transform: scaleX(1); opacity: 1; }} }}
    .animate-up {{ animation: fadeInUp .6s cubic-bezier(.16, 1, .3, 1) both; }}
    .delay-1 {{ animation-delay: .1s; }}
    .delay-2 {{ animation-delay: .2s; }}
    .delay-3 {{ animation-delay: .3s; }}
    .header {{ margin-bottom: 48px; }}
    .eyebrow {{ color: var(--toss-blue); font-size: 14px; font-weight: 700; letter-spacing: .5px; margin-bottom: 8px; text-transform: uppercase; }}
    h1 {{ font-size: 42px; font-weight: 800; letter-spacing: 0; line-height: 1.2; margin-bottom: 16px; }}
    .header-desc {{ font-size: 18px; color: var(--text-secondary); max-width: 840px; word-break: keep-all; }}
    .tag-group {{ display: flex; gap: 8px; margin-top: 24px; flex-wrap: wrap; }}
    .tag {{ background: var(--surface-main); border: 1px solid var(--line-color); padding: 8px 16px; border-radius: 99px; font-size: 14px; font-weight: 600; color: var(--text-secondary); display: inline-flex; align-items: center; box-shadow: var(--shadow-sm); }}
    .badge {{ padding: 4px 10px; border-radius: 6px; font-size: 13px; font-weight: 700; display: inline-flex; align-items: center; letter-spacing: 0; white-space: nowrap; }}
    .badge.fail {{ background: var(--toss-red-light); color: var(--toss-red); }}
    .badge.warn {{ background: var(--toss-orange-light); color: var(--toss-orange); }}
    .badge.pass {{ background: var(--toss-green-light); color: var(--toss-green); }}
    .badge.info {{ background: var(--toss-blue-light); color: var(--toss-blue); }}
    .kpi-grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 20px; margin-bottom: 56px; }}
    .kpi-card {{ background: var(--surface-main); border-radius: var(--radius-md); padding: 28px 24px; box-shadow: var(--shadow-sm); transition: transform .2s ease, box-shadow .2s ease; border: 1px solid transparent; }}
    .kpi-card:hover {{ transform: translateY(-4px); box-shadow: var(--shadow-hover); }}
    .kpi-title {{ font-size: 15px; color: var(--text-secondary); font-weight: 600; margin-bottom: 8px; }}
    .kpi-value {{ font-size: 34px; font-weight: 800; color: var(--text-primary); letter-spacing: 0; display: flex; align-items: baseline; gap: 4px; flex-wrap: wrap; line-height: 1.15; overflow-wrap: anywhere; }}
    .kpi-unit {{ font-size: 16px; font-weight: 600; color: var(--text-secondary); }}
    .kpi-card.alert {{ border: 1px solid var(--toss-red-light); background: #fffafa; }}
    .kpi-card.alert .kpi-value {{ color: var(--toss-red); }}
    .kpi-card.warn {{ border: 1px solid var(--toss-orange-light); background: #fffaf3; }}
    .kpi-card.warn .kpi-value {{ color: var(--toss-orange); }}
    .kpi-card.success {{ border: 1px solid var(--toss-green-light); background: #fbfffc; }}
    .kpi-card.success .kpi-value {{ color: var(--toss-green); }}
    .section-title {{ font-size: 26px; font-weight: 800; margin: 48px 0 24px; color: var(--text-primary); letter-spacing: 0; padding-top: 24px; border-top: 2px solid var(--line-color); }}
    .dashboard-stack {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(620px, 1fr)); gap: 24px; margin-bottom: 24px; }}
    .dashboard-stack .panel {{ min-height: 360px; }}
    .dashboard-stack .chart-wrapper {{ justify-content: stretch; overflow-x: hidden; }}
    .dashboard-stack .svg-chart.compact-visual {{ min-width: 0; max-width: 100%; max-height: 520px; }}
    .grid-2 {{ display: grid; grid-template-columns: 1fr 1fr; gap: 24px; margin-bottom: 24px; }}
    .panel, .report-panel {{ background: var(--surface-main); border-radius: var(--radius-lg); padding: 36px; margin-bottom: 24px; box-shadow: var(--shadow-md); display: flex; flex-direction: column; border: 1px solid transparent; }}
    .panel-header {{ margin-bottom: 24px; display: flex; justify-content: space-between; align-items: flex-start; gap: 16px; }}
    .panel-title {{ font-size: 22px; font-weight: 700; display: flex; align-items: center; gap: 10px; color: var(--text-primary); flex-wrap: wrap; }}
    .panel-desc, .panel-note, .section-lede, .muted-text {{ color: var(--text-secondary); font-size: 15px; margin-top: 6px; word-break: keep-all; }}
    .chart-wrapper, .generated-chart {{ width: 100%; flex-grow: 1; display: flex; align-items: center; justify-content: center; overflow-x: auto; padding: 16px 0; }}
    .svg-chart {{ width: 100%; min-width: 760px; height: auto; }}
    .svg-chart.compact-visual {{ min-width: 450px; max-height: 300px; }}
    .bar {{ transition: opacity .2s; rx: 4px; }}
    .bar:hover {{ opacity: .8; cursor: pointer; }}
    .chart-text {{ font-family: inherit; font-size: 13px; fill: var(--text-secondary); }}
    .chart-text-bold {{ font-family: inherit; font-size: 13px; font-weight: 700; fill: var(--text-primary); }}
    .donut-segment {{ transition: stroke-width .2s ease, opacity .2s; }}
    .donut-segment:hover {{ stroke-width: 36; opacity: .9; cursor: pointer; }}
    .insight-box {{ background: var(--toss-blue-light); border-left: 4px solid var(--toss-blue); padding: 20px 24px; border-radius: 0 var(--radius-sm) var(--radius-sm) 0; margin-top: auto; }}
    .insight-box h4 {{ color: var(--toss-blue); font-size: 15px; font-weight: 800; margin-bottom: 8px; }}
    .insight-box p, .insight-box li {{ color: var(--text-primary); font-size: 15px; line-height: 1.6; word-break: keep-all; }}
    .insight-box.danger {{ background: var(--toss-red-light); border-left-color: var(--toss-red); }}
    .insight-box.danger h4 {{ color: var(--toss-red); }}
    .table-container, .table-scroll {{ overflow-x: auto; border-radius: var(--radius-sm); border: 1px solid var(--line-color); margin: 20px 0; background: var(--surface-main); }}
    .stage-detail-table {{ margin-top: 12px; }}
    .stage-detail-table table {{ min-width: 1180px; }}
    table {{ width: 100%; border-collapse: collapse; text-align: left; min-width: 640px; }}
    th {{ background: var(--surface-sub); padding: 16px 20px; font-size: 14px; font-weight: 600; color: var(--text-secondary); border-bottom: 1px solid var(--line-color); white-space: nowrap; }}
    td {{ padding: 18px 20px; font-size: 15px; border-bottom: 1px solid var(--line-color); color: var(--text-primary); font-weight: 500; vertical-align: top; }}
    tr:last-child td {{ border-bottom: 0; }}
    tr:hover td {{ background: var(--surface-sub); }}
    .danger-row td {{ background: var(--toss-red-light); }}
    code {{ font-family: "JetBrains Mono", "SFMono-Regular", Consolas, monospace; background: var(--bg-color); padding: 3px 6px; border-radius: 4px; font-size: 13px; color: var(--toss-blue); }}
    details {{ background: var(--surface-sub); border-radius: var(--radius-md); margin-top: 16px; border: 1px solid var(--line-color); overflow: hidden; }}
    summary {{ padding: 20px 24px; font-size: 16px; font-weight: 700; cursor: pointer; color: var(--toss-blue); list-style: none; display: flex; justify-content: space-between; align-items: center; transition: background .2s; }}
    summary:hover {{ background: #f2f4f6; }}
    summary::-webkit-details-marker {{ display: none; }}
    summary:after {{ content: '+'; font-size: 22px; font-weight: 400; color: var(--toss-blue); }}
    details[open] summary:after {{ content: '−'; }}
    details[open] summary {{ border-bottom: 1px solid var(--line-color); }}
    article {{ margin-top: 48px; }}
    article > h1 {{ font-size: 26px; font-weight: 800; margin: 48px 0 20px; padding-top: 24px; border-top: 2px solid var(--line-color); }}
    article h2 {{ font-size: 22px; margin: 34px 0 12px; }}
    article h3 {{ font-size: 19px; margin: 28px 0 10px; }}
    article h4, article h5, article h6 {{ font-size: 16px; margin: 22px 0 10px; }}
    article p, article li {{ color: var(--text-primary); line-height: 1.68; }}
    article ul, article ol {{ padding-left: 22px; margin: 10px 0 18px; }}
    @media (max-width: 1180px) {{
      .report-shell {{ display: block; padding: 34px 18px 80px; }}
      .side-dashboard {{ position: static; margin-bottom: 24px; }}
      .side-nav {{ grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); }}
      .dashboard-stack {{ grid-template-columns: 1fr; }}
    }}
    @media (max-width: 960px) {{
      .grid-2 {{ grid-template-columns: 1fr; }}
      h1 {{ font-size: 34px; }}
      .panel, .report-panel {{ padding: 24px; }}
    }}
    @media (max-width: 680px) {{
      .container {{ padding: 34px 16px 72px; }}
      .kpi-value {{ font-size: 28px; }}
      .panel-title {{ font-size: 19px; }}
      .svg-chart, .svg-chart.compact-visual {{ min-width: 500px; }}
    }}
  </style>
</head>
<body>
  <div class="report-shell">
  {nav_html}
  <main class="container">
    <header class="header animate-up" id="overview">
      <p class="eyebrow">RISC-V Architecture Analysis Report</p>
      <h1>{html.escape(title)}</h1>
      <p class="header-desc">클럭 속도(Fmax), 파이프라인 효율(CPI), 논리/라우팅 지연, 자원 면적을 한 화면에서 판단할 수 있도록 자동 분석 결과와 그래프를 함께 구성한 리포트입니다.</p>
      <div class="tag-group">
        <span class="tag">📅 Generated: {html.escape(generated_at)}</span>
        <span class="tag">{html.escape(target_tag)}</span>
        <span class="tag">⚙️ Core: {html.escape(str(model.get("kind", "RV32I Timing")))}</span>
        <span class="tag"><span class="badge {badge_class(status)}">{html.escape(status_badge(status))}</span></span>
        {soc_tag_html}
        <span class="tag">Self-contained HTML</span>
      </div>
    </header>
    {chart_html}
    <article>
      <h1>Markdown Evidence</h1>
      {body_html}
    </article>
  </main>
  </div>
</body>
</html>
"""


def enrich_html_visual_markdown(html_path: pathlib.Path, markdown_text: str) -> str:
    """Keep the visible article compact while letting HTML charts use nearby evidence reports."""
    visual_sources = [markdown_text]
    if html_path.name.upper() == "INTEGRATED_TIMING_REPORT.HTML":
        for candidate in (
            html_path.with_name("PIPELINE_PERF_REPORT.md"),
            html_path.with_name("SINGLE_CYCLE_OPTIMIZATION_REPORT.md"),
        ):
            if not candidate.exists():
                continue
            try:
                candidate_text = candidate.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            if candidate_text and candidate_text not in visual_sources:
                visual_sources.append(candidate_text)
    return "\n\n".join(visual_sources)


def write_html_report(html_path: pathlib.Path, markdown_text: str, *, title: str) -> pathlib.Path:
    html_path.parent.mkdir(parents=True, exist_ok=True)
    visual_markdown_text = enrich_html_visual_markdown(html_path, markdown_text)
    html_path.write_text(render_report_html(markdown_text, title=title, visual_markdown_text=visual_markdown_text), encoding="utf-8")
    return html_path


def normalize_section_body(text: str) -> str:
    stripped = text.strip()
    return stripped + "\n" if stripped else ""


def render_detail_placeholder(detail_title: str) -> str:
    return f"- No {detail_title.lower()} recorded yet for this program image.\n"


def strip_first_markdown_heading(text: str) -> str:
    lines = text.replace("\r\n", "\n").split("\n")
    stripped_lines = list(lines)
    if stripped_lines and stripped_lines[0].startswith("#"):
        stripped_lines = stripped_lines[1:]
        while stripped_lines and not stripped_lines[0].strip():
            stripped_lines = stripped_lines[1:]
    return "\n".join(stripped_lines).strip() + ("\n" if stripped_lines else "")


def shift_markdown_headings(text: str, increment: int) -> str:
    shifted_lines: list[str] = []
    for line in text.replace("\r\n", "\n").split("\n"):
        match = HEADING_PATTERN.match(line)
        if not match:
            shifted_lines.append(line)
            continue
        level = min(6, len(match.group("hashes")) + max(0, int(increment)))
        shifted_lines.append("#" * level + match.group("suffix"))
    return "\n".join(shifted_lines).strip() + ("\n" if shifted_lines else "")


def extract_existing_program_sections(report_text: str) -> dict[str, str]:
    normalized_text = report_text.replace("\r\n", "\n")
    pattern = re.compile(
        r"<!-- PROGRAM_SECTION:(?P<key>[a-z0-9_]+):START -->\n(?P<body>.*?)(?:\n)?<!-- PROGRAM_SECTION:(?P=key):END -->",
        flags=re.DOTALL,
    )
    sections: dict[str, str] = {}
    for match in pattern.finditer(normalized_text):
        sections[str(match.group("key"))] = normalize_section_body(str(match.group("body")))
    return sections


def extract_existing_detail_sections(section_text: str) -> dict[str, str]:
    normalized_text = section_text.replace("\r\n", "\n")
    pattern = re.compile(
        r"<!-- DETAIL_SECTION:(?P<detail_key>[a-z_]+):(?P<program_key>[a-z0-9_]+):START -->\n(?P<body>.*?)(?:\n)?<!-- DETAIL_SECTION:(?P=detail_key):(?P=program_key):END -->",
        flags=re.DOTALL,
    )
    sections: dict[str, str] = {}
    for match in pattern.finditer(normalized_text):
        sections[str(match.group("detail_key"))] = normalize_section_body(str(match.group("body")))
    return sections


def build_program_section(
    program_selection: dict[str, Any],
    detail_sections: dict[str, str],
) -> str:
    program_key = str(program_selection["key"])
    lines = [
        f"## {program_selection['display_name']}",
        "",
        f"- Program key: `{program_key}`",
        "",
    ]

    for detail_key, detail_title in DETAIL_SECTION_SPECS:
        lines.append(f"### {detail_title}")
        lines.append("")
        lines.append(DETAIL_SECTION_START_TEMPLATE.format(detail_key=detail_key, program_key=program_key))
        detail_body = normalize_section_body(strip_noisy_report_sections(detail_sections.get(detail_key, "")))
        if detail_body:
            lines.append(detail_body.rstrip())
        else:
            lines.append(render_detail_placeholder(detail_title).rstrip())
        lines.append(DETAIL_SECTION_END_TEMPLATE.format(detail_key=detail_key, program_key=program_key))
        lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def render_integrated_report(
    program_sections: dict[str, str],
    *,
    program_keys: list[str],
    resolve_program_selection: Callable[[str], dict[str, Any]],
) -> str:
    lines = [
        "# INTEGRATED_TIMING_REPORT",
        "",
        "- This report keeps one category per timing program image.",
        "- Re-running one timing flow refreshes only that flow's detail block for the selected program.",
        "",
    ]

    for program_key in program_keys:
        program_selection = resolve_program_selection(program_key)
        section_body = program_sections.get(program_key)
        if not section_body:
            section_body = build_program_section(program_selection, {})
        lines.append(PROGRAM_SECTION_START_TEMPLATE.format(program_key=program_key))
        lines.append(section_body.rstrip())
        lines.append(PROGRAM_SECTION_END_TEMPLATE.format(program_key=program_key))
        lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def merge_program_detail_section(
    report_path: pathlib.Path,
    *,
    program_selection: dict[str, Any],
    detail_key: str,
    detail_body: str,
    program_keys: list[str],
    resolve_program_selection: Callable[[str], dict[str, Any]],
) -> str:
    existing_program_sections: dict[str, str] = {}
    if report_path.exists():
        existing_program_sections = extract_existing_program_sections(report_path.read_text(encoding="utf-8", errors="ignore"))

    program_key = str(program_selection["key"])
    existing_detail_sections = extract_existing_detail_sections(existing_program_sections.get(program_key, ""))
    existing_detail_sections[detail_key] = normalize_section_body(detail_body)
    existing_program_sections[program_key] = build_program_section(program_selection, existing_detail_sections)

    return render_integrated_report(
        existing_program_sections,
        program_keys=program_keys,
        resolve_program_selection=resolve_program_selection,
    )
