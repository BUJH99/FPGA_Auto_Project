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
    }


def render_svg_panel(title: str, note: str, svg: str, *, extra_class: str = "") -> str:
    classes = "report-panel chart-panel"
    if extra_class:
        classes += f" {extra_class}"
    return "\n".join(
        [
            f'<section class="{classes}">',
            f"<h2>{html.escape(title)}</h2>",
            f'<p class="panel-note">{html.escape(note)}</p>',
            '<div class="generated-chart" data-chart-engine="python-svg">',
            svg,
            "</div>",
            "</section>",
        ]
    )


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


def render_stage_boundary_svg(rows: list[tuple[str, str, float, float | None]]) -> str:
    if not rows:
        return ""

    width = 1000
    row_height = 66
    top = 96
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
        f'<text x="28" y="42" fill="{CHART_COLORS["ink"]}" font-size="24" font-weight="760">Stage Boundary Timing</text>',
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
    route_idx = header.index("Route Share (%)") if "Route Share (%)" in header else None
    parsed_rows: list[tuple[str, str, float, float | None]] = []
    for row in table.get("rows", []):
        if len(row) <= max(boundary_idx, stage_idx, period_idx):
            continue
        period = parse_first_number(row[period_idx])
        if period is None:
            continue
        route_share = parse_first_number(row[route_idx]) if route_idx is not None and len(row) > route_idx else None
        parsed_rows.append((str(row[stage_idx]), str(row[boundary_idx]), period, route_share))
    if not parsed_rows:
        return ""
    svg = render_stage_boundary_svg(parsed_rows)
    if svg:
        return render_svg_panel(
            "Stage Boundary Timing",
            "Minimum-period bars expose the timing bottleneck; the amber line overlays route share to show physical-delay pressure.",
            svg,
            extra_class="stage-panel",
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
    alert_class = " alert" if normalize_status(status) == "FAIL" else ""
    return "\n".join(
        [
            f'<div class="kpi-card{alert_class}">',
            f'<div class="kpi-title">{html.escape(title)}</div>',
            f'<div class="kpi-value">{html.escape(value)} <span class="kpi-unit">{html.escape(unit)}</span></div>',
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
    point = max(cycle_points, key=lambda row: float(row.get("pipeline") or 0.0))
    retired = max(0.0, float(point.get("single") or 0.0))
    pipeline_cycles = max(retired, float(point.get("pipeline") or 0.0))
    overhead = max(0.0, pipeline_cycles - retired)
    total = max(1.0, pipeline_cycles)
    circumference = 2 * math.pi * 70
    useful_dash = retired / total * circumference
    overhead_dash = overhead / total * circumference
    useful_pct = retired / total * 100.0
    overhead_pct = overhead / total * 100.0
    return f"""
<svg class="svg-chart compact-visual" viewBox="0 0 500 240" role="img" aria-label="Pipeline execution breakdown" xmlns="http://www.w3.org/2000/svg">
  <circle cx="150" cy="116" r="70" fill="none" stroke="{CHART_COLORS['bg']}" stroke-width="24"/>
  <circle cx="150" cy="116" r="70" fill="none" stroke="{CHART_COLORS['blue']}" stroke-width="24" class="donut-segment" stroke-dasharray="{useful_dash:.1f} {circumference - useful_dash:.1f}" stroke-dashoffset="0" transform="rotate(-90 150 116)"><title>Useful retired cycles: {useful_pct:.1f}%</title></circle>
  <circle cx="150" cy="116" r="70" fill="none" stroke="{CHART_COLORS['amber']}" stroke-width="24" class="donut-segment" stroke-dasharray="{overhead_dash:.1f} {circumference - overhead_dash:.1f}" stroke-dashoffset="-{useful_dash:.1f}" transform="rotate(-90 150 116)"><title>Pipeline overhead cycles: {overhead_pct:.1f}%</title></circle>
  <text x="150" y="111" fill="{CHART_COLORS['ink']}" font-size="32" font-weight="800" text-anchor="middle">{pipeline_cycles:.0f}</text>
  <text x="150" y="132" fill="{CHART_COLORS['muted']}" font-size="13" text-anchor="middle">Total Cycles</text>
  <rect x="280" y="80" width="12" height="12" rx="3" fill="{CHART_COLORS['blue']}"/>
  <text x="300" y="91" class="chart-text-bold">Useful work ({useful_pct:.1f}%)</text>
  <rect x="280" y="112" width="12" height="12" rx="3" fill="{CHART_COLORS['amber']}"/>
  <text x="300" y="123" class="chart-text-bold">Fill/Stall overhead ({overhead_pct:.1f}%)</text>
  <text x="280" y="160" class="chart-text">{svg_text(compact_chart_label(point.get('label'), limit=24))}</text>
</svg>
"""


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
                f'<text x="{chart_right}" y="{target_y - 8:.1f}" class="chart-text" fill="{CHART_COLORS["red"]}" text-anchor="end" font-weight="700">Target {target:.1f} MHz</text>',
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


def render_physical_delay_stack_svg(model: dict[str, Any]) -> str:
    rows = select_physical_delay_stage_rows(list(model.get("stage_rows", [])))
    if not rows:
        return ""
    width = 500
    height = 250
    x0 = 82
    max_delay = max(float(row.get("datapath_ns") or row.get("period_ns") or 1.0) for row in rows) or 1.0
    max_period = max(float(row.get("period_ns") or 0.0) for row in rows) or 0.0
    scale = 330 / max_delay
    lines = [
        f'<svg class="svg-chart compact-visual" viewBox="0 0 {width} {height}" role="img" aria-label="Physical delay stack" xmlns="http://www.w3.org/2000/svg">',
        f'<text x="328" y="22" class="chart-text">■ Logic Delay</text>',
        f'<text x="328" y="40" class="chart-text" fill="{CHART_COLORS["muted"]}">■ Routing Delay</text>',
    ]
    for index, row in enumerate(rows):
        y = 64 + index * 34
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
                f'<text x="40" y="{y + 12}" class="chart-text-bold" text-anchor="end">{svg_text(compact_chart_label(row.get("stage"), limit=8))}</text>',
                f'<rect class="bar" x="{x0}" y="{y}" width="{logic_width:.1f}" height="16" fill="{logic_color}"/>',
                f'<rect class="bar" x="{x0 + logic_width + 2:.1f}" y="{y}" width="{route_width:.1f}" height="16" fill="{route_color}"><title>Route share {route_share:.1f}%</title></rect>',
                f'<text x="{min(468, x0 + logic_width + route_width + 14):.1f}" y="{y + 12}" class="chart-text-bold" fill="{logic_color if is_bottleneck else CHART_COLORS["muted"]}">{float(row.get("period_ns") or datapath):.3f} ns</text>',
            ]
        )
    lines.append("</svg>")
    return "\n".join(lines)


def render_resource_utilization_svg(model: dict[str, Any]) -> str:
    points = list(model.get("resource_points", []))[:6]
    if not points:
        return ""
    max_value = max([float(point.get("luts") or 0.0) for point in points] + [float(point.get("registers") or 0.0) for point in points] + [1.0])
    lines = [
        '<svg class="svg-chart compact-visual" viewBox="0 0 500 250" role="img" aria-label="Hardware resource utilization" xmlns="http://www.w3.org/2000/svg">',
        f'<line x1="100" y1="212" x2="456" y2="212" stroke="{CHART_COLORS["line"]}" stroke-width="2"/>',
        f'<rect x="334" y="20" width="12" height="12" rx="3" fill="{CHART_COLORS["purple"]}"/><text x="354" y="31" class="chart-text">LUTs</text>',
        f'<rect x="334" y="42" width="12" height="12" rx="3" fill="{CHART_COLORS["tertiary"]}"/><text x="354" y="53" class="chart-text">Registers</text>',
    ]
    for index, point in enumerate(points):
        y = 78 + index * 54
        label = compact_chart_label(point.get("label"), limit=16)
        lut_width = (float(point.get("luts") or 0.0) / max_value) * 330
        reg_width = (float(point.get("registers") or 0.0) / max_value) * 330
        lines.extend(
            [
                f'<text x="84" y="{y + 13}" class="chart-text-bold" text-anchor="end">{svg_text(label)}</text>',
                f'<rect class="bar" x="100" y="{y}" width="{lut_width:.1f}" height="14" fill="{CHART_COLORS["purple"]}"/>',
                f'<text x="{min(470, 108 + lut_width):.1f}" y="{y + 12}" class="chart-text-bold">{float(point.get("luts") or 0.0):,.0f}</text>',
                f'<rect class="bar" x="100" y="{y + 20}" width="{reg_width:.1f}" height="14" fill="{CHART_COLORS["tertiary"]}"/>',
                f'<text x="{min(470, 108 + reg_width):.1f}" y="{y + 32}" class="chart-text">{float(point.get("registers") or 0.0):,.0f}</text>',
            ]
        )
    lines.append("</svg>")
    return "\n".join(lines)


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
                "Retired work versus fill/stall overhead inferred from cycle-count metrics.",
                pipeline_svg,
                "Architecture Insight",
                "The donut uses actual `Cycles` rows: useful work follows the single-cycle retired count, while the gap to pipeline cycles is overhead from fill, stalls, or flush behavior.",
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
                "Logic delay versus routing delay for the slowest true stage boundaries.",
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
    if not severity_chart and not metric_charts and not distribution_charts and not stage_charts:
        return ""
    return "\n".join(
        [
            '<section class="visual-section">',
            render_kpi_dashboard(model),
            render_dashboard_charts(model),
            render_root_cause_table(model),
            render_benchmark_breakdowns(model),
            '<h2 class="section-title animate-up delay-3">Generated Evidence Charts</h2>',
            '<p class="section-lede">These charts are generated as inline SVG from parsed timing metrics, root-cause findings, and stage-boundary evidence.</p>',
            severity_chart,
            *metric_charts[:4],
            *distribution_charts[:4],
            *stage_charts[:4],
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
            html_lines.append(f'<h{level}>{render_inline_markdown(heading.group("suffix").strip())}</h{level}>')
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


def render_report_html(markdown_text: str, *, title: str, visual_markdown_text: str | None = None) -> str:
    visual_text = visual_markdown_text or markdown_text
    generated_at = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
    model = collect_visual_model(visual_text, title=title)
    target_fmax = model.get("target_fmax_mhz")
    target_tag = f"🎯 Target Fmax: {target_fmax:.1f} MHz" if target_fmax else "🎯 Target Fmax: inferred from timing metrics"
    status = normalize_status(str(model.get("overall_status", "INFO")))
    body_html = markdown_to_html_body(markdown_text)
    chart_html = render_auto_charts(visual_text, title=title)
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
    body {{ background: var(--bg-color); color: var(--text-primary); line-height: 1.6; -webkit-font-smoothing: antialiased; }}
    .container {{ max-width: 1240px; margin: 0 auto; padding: 56px 24px 100px; }}
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
    .kpi-value {{ font-size: 34px; font-weight: 800; color: var(--text-primary); letter-spacing: 0; display: flex; align-items: baseline; gap: 4px; }}
    .kpi-unit {{ font-size: 16px; font-weight: 600; color: var(--text-secondary); }}
    .kpi-card.alert {{ border: 1px solid var(--toss-red-light); background: #fffafa; }}
    .kpi-card.alert .kpi-value {{ color: var(--toss-red); }}
    .section-title {{ font-size: 26px; font-weight: 800; margin: 48px 0 24px; color: var(--text-primary); letter-spacing: 0; padding-top: 24px; border-top: 2px solid var(--line-color); }}
    .dashboard-stack {{ display: grid; grid-template-columns: 1fr; gap: 24px; margin-bottom: 24px; }}
    .dashboard-stack .panel {{ min-height: 360px; }}
    .dashboard-stack .chart-wrapper {{ justify-content: stretch; }}
    .dashboard-stack .svg-chart.compact-visual {{ min-width: 900px; max-height: 360px; }}
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
  <main class="container">
    <header class="header animate-up">
      <p class="eyebrow">RISC-V Architecture Analysis Report</p>
      <h1>{html.escape(title)}</h1>
      <p class="header-desc">클럭 속도(Fmax), 파이프라인 효율(CPI), 논리/라우팅 지연, 자원 면적을 한 화면에서 판단할 수 있도록 자동 분석 결과와 그래프를 함께 구성한 리포트입니다.</p>
      <div class="tag-group">
        <span class="tag">📅 Generated: {html.escape(generated_at)}</span>
        <span class="tag">{html.escape(target_tag)}</span>
        <span class="tag">⚙️ Core: {html.escape(str(model.get("kind", "RV32I Timing")))}</span>
        <span class="tag"><span class="badge {badge_class(status)}">{html.escape(status_badge(status))}</span></span>
        <span class="tag">Self-contained HTML</span>
      </div>
    </header>
    {chart_html}
    <article>
      <h1>Markdown Evidence</h1>
      {body_html}
    </article>
  </main>
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
