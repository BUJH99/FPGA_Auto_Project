from __future__ import annotations

import html
import json
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


TOOL_ALIAS_MAP: dict[str, tuple[str, ...]] = {
    "doctor": ("toolkit_doctor",),
    "toolkit_doctor": ("toolkit_doctor",),
    "build": ("vivado_build",),
    "vivado_build": ("vivado_build",),
    "sim": ("simulation_report",),
    "simulation_report": ("simulation_report",),
    "sim_vivado": ("vivado_sim_nogui", "vivado_sim_gui"),
    "vivado_sim": ("vivado_sim_nogui", "vivado_sim_gui"),
    "vivado_sim_nogui": ("vivado_sim_nogui",),
    "vivado_sim_gui": ("vivado_sim_gui",),
    "hierarchy": ("hierarchy_view",),
    "hierarchy_view": ("hierarchy_view",),
    "report_docs": ("report_documentation", "report_doc"),
    "report_doc": ("report_documentation", "report_doc"),
    "presentation": ("report_presentation", "presentation"),
}

TOOL_LABELS: dict[str, str] = {
    "toolkit_doctor": "Toolkit Doctor",
    "vivado_build": "Vivado Build",
    "simulation_report": "Simulation Report",
    "vivado_sim_nogui": "Vivado Sim (No GUI)",
    "vivado_sim_gui": "Vivado Sim (GUI)",
    "hierarchy_view": "Hierarchy View",
    "report_documentation": "Docs Report",
    "report_doc": "Docs Report",
    "report_presentation": "Presentation",
    "presentation": "Presentation",
}

STATUS_ICONS: dict[str, str] = {
    "ok": "🟢",
    "success": "🟢",
    "warning": "🟡",
    "warn": "🟡",
    "failed": "🔴",
    "fail": "🔴",
    "error": "🔴",
    "unknown": "⚪",
}


@dataclass(frozen=True)
class RunHistoryRecord:
    tool: str
    status: str
    created_at: str
    summary_path: Path | None
    summary: dict[str, object] | None
    metadata: dict[str, object]
    outputs: tuple[dict[str, object], ...]


def build_run_history_text(
    project_path: Path,
    *,
    project_name: str,
    tool_filter: str = "",
    limit: int = 5,
) -> str:
    records = load_run_history(project_path, tool_filter=tool_filter, limit=limit)
    resolved_tools = resolve_tool_filters(tool_filter)
    if not records:
        if tool_filter:
            return (
                "🗂 <b>[Run History]</b>\n"
                f"📁 <b>Project:</b> <code>{_escape(project_name)}</code>\n"
                f"🔎 <b>Filter:</b> <code>{_escape(format_tool_filter_label(tool_filter, resolved_tools))}</code>\n"
                "ℹ️ No matching run history was found."
            )
        return (
            "🗂 <b>[Run History]</b>\n"
            f"📁 <b>Project:</b> <code>{_escape(project_name)}</code>\n"
            "ℹ️ No run history was found. Execute at least one automated task first."
        )

    total = count_run_history(project_path, tool_filter=tool_filter)
    lines = [
        "🗂 <b>[Run History]</b>",
        f"📁 <b>Project:</b> <code>{_escape(project_name)}</code>",
        f"🔎 <b>Filter:</b> <code>{_escape(format_tool_filter_label(tool_filter, resolved_tools))}</code>",
        f"📚 <b>Showing:</b> <code>{len(records)}</code> / <code>{total}</code>",
    ]

    for idx, record in enumerate(records, start=1):
        lines.extend(_build_history_record_lines(idx, record))
    return "\n".join(lines)


def build_run_diff_text(
    project_path: Path,
    *,
    project_name: str,
    tool_filter: str = "",
) -> str:
    selected_filter = tool_filter.strip()
    selected_tools = resolve_tool_filters(selected_filter)
    if not selected_tools:
        latest = load_run_history(project_path, limit=1)
        if not latest:
            return (
                "🧾 <b>[Run Diff]</b>\n"
                f"📁 <b>Project:</b> <code>{_escape(project_name)}</code>\n"
                "ℹ️ No run history was found. Execute at least one automated task first."
            )
        selected_tools = (latest[0].tool,)
        selected_filter = latest[0].tool

    records = load_run_history(project_path, tool_filter=selected_filter, limit=2)
    if not records:
        return (
            "🧾 <b>[Run Diff]</b>\n"
            f"📁 <b>Project:</b> <code>{_escape(project_name)}</code>\n"
            f"🔎 <b>Tool:</b> <code>{_escape(format_tool_filter_label(selected_filter, selected_tools))}</code>\n"
            "ℹ️ No matching run history was found."
        )
    if len(records) == 1:
        current = records[0]
        return (
            "🧾 <b>[Run Diff]</b>\n"
            f"📁 <b>Project:</b> <code>{_escape(project_name)}</code>\n"
            f"🔎 <b>Tool:</b> <code>{_escape(display_tool_label(current.tool))}</code>\n"
            f"🆕 <b>Latest Run:</b> <code>{_escape(format_timestamp(current.created_at))}</code> "
            f"{_status_badge(current.status)}\n"
            "ℹ️ Need at least two runs of the same tool to compute a diff."
        )

    current, previous = records[0], records[1]
    lines = [
        "🧾 <b>[Run Diff]</b>",
        f"📁 <b>Project:</b> <code>{_escape(project_name)}</code>",
        f"🔎 <b>Tool:</b> <code>{_escape(display_tool_label(current.tool))}</code>",
        f"🆕 <b>Current:</b> <code>{_escape(format_timestamp(current.created_at))}</code> {_status_badge(current.status)}",
        f"🕘 <b>Previous:</b> <code>{_escape(format_timestamp(previous.created_at))}</code> {_status_badge(previous.status)}",
    ]
    lines.extend(_build_diff_lines(previous, current))
    return "\n".join(lines)


def count_run_history(project_path: Path, *, tool_filter: str = "") -> int:
    records = _read_run_index_records(project_path)
    tools = resolve_tool_filters(tool_filter)
    if tools:
        records = [record for record in records if record.tool in tools]
    return len(records)


def load_run_history(project_path: Path, *, tool_filter: str = "", limit: int = 5) -> list[RunHistoryRecord]:
    records = _read_run_index_records(project_path)
    tools = resolve_tool_filters(tool_filter)
    if tools:
        records = [record for record in records if record.tool in tools]
    records.sort(key=lambda item: _timestamp_sort_key(item.created_at), reverse=True)
    capped_limit = max(1, min(int(limit or 5), 20))
    return records[:capped_limit]


def resolve_tool_filters(raw_tool: str) -> tuple[str, ...]:
    value = raw_tool.strip().lower()
    if not value:
        return ()
    if value in TOOL_ALIAS_MAP:
        return TOOL_ALIAS_MAP[value]
    return (raw_tool.strip(),)


def format_tool_filter_label(raw_tool: str, resolved_tools: tuple[str, ...]) -> str:
    if not raw_tool:
        return "all"
    if not resolved_tools:
        return raw_tool
    labels = [display_tool_label(tool) for tool in resolved_tools]
    return " / ".join(labels)


def display_tool_label(tool: str) -> str:
    value = str(tool or "").strip()
    if not value:
        return "-"
    return TOOL_LABELS.get(value, value)


def _build_history_record_lines(index: int, record: RunHistoryRecord) -> list[str]:
    summary_name = record.summary_path.name if record.summary_path is not None else "-"
    extra = _summarize_record(record)
    return [
        f"{index}. {STATUS_ICONS.get(record.status.lower(), '⚪')} <b>{_escape(display_tool_label(record.tool))}</b> "
        f"<code>{_escape(format_timestamp(record.created_at))}</code>",
        f"   <i>status=</i><code>{_escape(record.status)}</code> "
        f"<i>summary=</i><code>{_escape(summary_name)}</code>",
        f"   {extra}",
    ]


def _summarize_record(record: RunHistoryRecord) -> str:
    summary = record.summary or {}
    details = summary.get("details") if isinstance(summary, dict) else None
    if not isinstance(details, dict):
        details = {}

    if record.tool == "toolkit_doctor":
        warning_count = len(_list_string_values(summary.get("warnings")))
        healthy = "yes" if bool(summary.get("ok")) else "no"
        return (
            f"🩺 <i>healthy=</i><code>{healthy}</code> "
            f"<i>warnings=</i><code>{warning_count}</code>"
        )

    if record.tool == "vivado_build":
        top_module = str(details.get("topModule", "")).strip() or "-"
        quality_gate = summary.get("qualityGate") if isinstance(summary, dict) else None
        timing_status = _nested_value(quality_gate, "timing", "status") or "-"
        bitstream_status = _nested_value(quality_gate, "bitstream", "status") or "-"
        return (
            f"🛠 <i>top=</i><code>{_escape(top_module)}</code> "
            f"<i>timing=</i><code>{_escape(str(timing_status))}</code> "
            f"<i>bitstream=</i><code>{_escape(str(bitstream_status))}</code>"
        )

    if record.tool == "simulation_report":
        pass_count = int(details.get("passCount", 0) or 0)
        fail_count = int(details.get("failCount", 0) or 0)
        top_module = str(details.get("topModule", "")).strip() or "-"
        return (
            f"🧪 <i>top=</i><code>{_escape(top_module)}</code> "
            f"<i>pass=</i><code>{pass_count}</code> "
            f"<i>fail=</i><code>{fail_count}</code>"
        )

    if record.tool in {"vivado_sim_nogui", "vivado_sim_gui"}:
        tb_name = str(details.get("tbName") or details.get("tb_name") or "").strip() or "-"
        replay_state = str(details.get("replayState") or details.get("replay_state") or "").strip() or "-"
        return (
            f"▶️ <i>tb=</i><code>{_escape(tb_name)}</code> "
            f"<i>replay=</i><code>{_escape(replay_state)}</code>"
        )

    warning_count = len(_list_string_values(summary.get("warnings")))
    artifact_count = len(_artifact_rows(record))
    return (
        f"📦 <i>artifacts=</i><code>{artifact_count}</code> "
        f"<i>warnings=</i><code>{warning_count}</code>"
    )


def _build_diff_lines(previous: RunHistoryRecord, current: RunHistoryRecord) -> list[str]:
    lines: list[str] = []
    status_line = _diff_value_line("🔁 <b>Status:</b>", previous.status, current.status)
    if status_line:
        lines.append(status_line)

    artifact_count_prev = len(_artifact_rows(previous))
    artifact_count_curr = len(_artifact_rows(current))
    artifact_line = _diff_value_line("📦 <b>Artifacts:</b>", artifact_count_prev, artifact_count_curr)
    if artifact_line:
        lines.append(artifact_line)

    warning_lines = _warning_diff_lines(previous, current)
    lines.extend(warning_lines)

    tool = current.tool
    if tool == "toolkit_doctor":
        lines.extend(_doctor_diff_lines(previous, current))
    elif tool == "vivado_build":
        lines.extend(_build_diff_specific_lines(previous, current))
    elif tool == "simulation_report":
        lines.extend(_simulation_diff_lines(previous, current))
    elif tool in {"vivado_sim_nogui", "vivado_sim_gui"}:
        lines.extend(_vivado_sim_diff_lines(previous, current))

    if len(lines) <= 2:
        lines.append("ℹ️ No material difference was detected between the latest two runs.")
    return lines


def _warning_diff_lines(previous: RunHistoryRecord, current: RunHistoryRecord) -> list[str]:
    previous_warnings = set(_list_string_values((previous.summary or {}).get("warnings")))
    current_warnings = set(_list_string_values((current.summary or {}).get("warnings")))
    added = sorted(current_warnings - previous_warnings)
    cleared = sorted(previous_warnings - current_warnings)
    lines: list[str] = []
    if added:
        lines.append(f"⚠️ <b>Warnings Added:</b> <code>{_escape(', '.join(added[:4]))}</code>")
    if cleared:
        lines.append(f"✅ <b>Warnings Cleared:</b> <code>{_escape(', '.join(cleared[:4]))}</code>")
    return lines


def _doctor_diff_lines(previous: RunHistoryRecord, current: RunHistoryRecord) -> list[str]:
    lines: list[str] = []
    prev_summary = previous.summary or {}
    curr_summary = current.summary or {}
    healthy_line = _diff_value_line("🩺 <b>Healthy:</b>", bool(prev_summary.get("ok")), bool(curr_summary.get("ok")))
    if healthy_line:
        lines.append(healthy_line)

    prev_missing = set(_doctor_missing_tools(prev_summary))
    curr_missing = set(_doctor_missing_tools(curr_summary))
    added = sorted(curr_missing - prev_missing)
    cleared = sorted(prev_missing - curr_missing)
    if added:
        lines.append(f"🚫 <b>Missing Tools Added:</b> <code>{_escape(', '.join(added))}</code>")
    if cleared:
        lines.append(f"🧰 <b>Missing Tools Cleared:</b> <code>{_escape(', '.join(cleared))}</code>")
    return lines


def _build_diff_specific_lines(previous: RunHistoryRecord, current: RunHistoryRecord) -> list[str]:
    lines: list[str] = []
    prev_summary = previous.summary or {}
    curr_summary = current.summary or {}
    prev_gate = prev_summary.get("qualityGate") if isinstance(prev_summary, dict) else None
    curr_gate = curr_summary.get("qualityGate") if isinstance(curr_summary, dict) else None

    for label, key_path in (
        ("⏱ <b>Timing Gate:</b>", ("timing", "status")),
        ("⚡ <b>Power Gate:</b>", ("power", "status")),
        ("🔗 <b>CDC Gate:</b>", ("cdc", "status")),
        ("🧱 <b>Bitstream:</b>", ("bitstream", "status")),
    ):
        line = _diff_value_line(label, _nested_value(prev_gate, *key_path), _nested_value(curr_gate, *key_path))
        if line:
            lines.append(line)

    line = _diff_value_line(
        "📉 <b>WNS (ns):</b>",
        _nested_value(prev_gate, "timing", "wnsNs"),
        _nested_value(curr_gate, "timing", "wnsNs"),
    )
    if line:
        lines.append(line)

    line = _diff_value_line(
        "⚡ <b>Total Power (W):</b>",
        _nested_value(prev_gate, "power", "totalOnChipPowerW"),
        _nested_value(curr_gate, "power", "totalOnChipPowerW"),
    )
    if line:
        lines.append(line)

    prev_program = _summary_details_value(prev_summary, "programStatus")
    curr_program = _summary_details_value(curr_summary, "programStatus")
    line = _diff_value_line("🎯 <b>Program Status:</b>", prev_program, curr_program)
    if line:
        lines.append(line)
    return lines


def _simulation_diff_lines(previous: RunHistoryRecord, current: RunHistoryRecord) -> list[str]:
    lines: list[str] = []
    prev_summary = previous.summary or {}
    curr_summary = current.summary or {}

    for label, key in (("✅ <b>Pass Count:</b>", "passCount"), ("❌ <b>Fail Count:</b>", "failCount")):
        line = _diff_value_line(label, _summary_details_value(prev_summary, key), _summary_details_value(curr_summary, key))
        if line:
            lines.append(line)

    prev_fail_map = _simulation_fail_map(prev_summary)
    curr_fail_map = _simulation_fail_map(curr_summary)
    added = sorted(set(curr_fail_map) - set(prev_fail_map))
    cleared = sorted(set(prev_fail_map) - set(curr_fail_map))
    changed = sorted(name for name in curr_fail_map if name in prev_fail_map and curr_fail_map[name] != prev_fail_map[name])
    if added:
        lines.append(
            f"🆕 <b>Failing Tests Added:</b> <code>{_escape(', '.join(f'{name}:{curr_fail_map[name]}' for name in added[:4]))}</code>"
        )
    if cleared:
        lines.append(
            f"🧹 <b>Failing Tests Cleared:</b> <code>{_escape(', '.join(f'{name}:{prev_fail_map[name]}' for name in cleared[:4]))}</code>"
        )
    if changed:
        lines.append(
            f"🔄 <b>Failure Reasons Changed:</b> <code>{_escape(', '.join(f'{name}:{prev_fail_map[name]}→{curr_fail_map[name]}' for name in changed[:4]))}</code>"
        )
    return lines


def _vivado_sim_diff_lines(previous: RunHistoryRecord, current: RunHistoryRecord) -> list[str]:
    lines: list[str] = []
    prev_summary = previous.summary or {}
    curr_summary = current.summary or {}
    for label, key in (
        ("🧪 <b>TB:</b>", "tbName"),
        ("▶️ <b>Replay:</b>", "replayState"),
        ("📂 <b>Folder:</b>", "folderName"),
        ("🚪 <b>Close Decision:</b>", "closeDecision"),
    ):
        line = _diff_value_line(label, _summary_details_value(prev_summary, key), _summary_details_value(curr_summary, key))
        if line:
            lines.append(line)
    return lines


def _summary_details_value(summary: dict[str, object], key: str) -> object:
    details = summary.get("details")
    if not isinstance(details, dict):
        return None
    variants = (key, f"{key[:1].lower()}{key[1:]}", key.lower(), _to_snake_case(key))
    for variant in variants:
        if variant in details:
            return details.get(variant)
    return None


def _simulation_fail_map(summary: dict[str, object]) -> dict[str, str]:
    details = summary.get("details")
    rows = details.get("regressionRows") if isinstance(details, dict) else None
    if not isinstance(rows, list):
        return {}
    out: dict[str, str] = {}
    for row in rows:
        if not isinstance(row, dict) or bool(row.get("pass", True)):
            continue
        test_name = str(row.get("testName", "")).strip()
        if not test_name:
            continue
        out[test_name] = str(row.get("reason", "")).strip() or "failed"
    return out


def _doctor_missing_tools(summary: dict[str, object]) -> list[str]:
    tools = summary.get("tools")
    if not isinstance(tools, dict):
        return []
    out = [display_tool_label(name) for name, row in tools.items() if isinstance(row, dict) and not bool(row.get("ok"))]
    return sorted(out)


def _artifact_rows(record: RunHistoryRecord) -> list[dict[str, object]]:
    summary_artifacts = record.summary.get("artifacts") if isinstance(record.summary, dict) else None
    rows = summary_artifacts if isinstance(summary_artifacts, list) else list(record.outputs)
    return [row for row in rows if isinstance(row, dict)]


def _diff_value_line(label: str, previous: object, current: object) -> str:
    prev_text = _normalize_value_text(previous)
    curr_text = _normalize_value_text(current)
    if prev_text == curr_text:
        return ""
    return f"{label} <code>{_escape(prev_text)} → {_escape(curr_text)}</code>"


def _nested_value(root: object, *keys: str) -> object:
    current = root
    for key in keys:
        if not isinstance(current, dict):
            return None
        current = current.get(key)
    return current


def _normalize_value_text(value: object) -> str:
    if value is None or value == "":
        return "-"
    if isinstance(value, bool):
        return "yes" if value else "no"
    return str(value)


def _read_run_index_records(project_path: Path) -> list[RunHistoryRecord]:
    run_index_path = project_path / "output" / "run_index.json"
    if not run_index_path.exists():
        return []
    try:
        payload = json.loads(run_index_path.read_text(encoding="utf-8", errors="replace"))
    except Exception:
        return []
    raw_runs = payload.get("runs") if isinstance(payload, dict) else None
    if not isinstance(raw_runs, list):
        return []

    records: list[RunHistoryRecord] = []
    for entry in raw_runs:
        if not isinstance(entry, dict):
            continue
        summary_path = _resolve_summary_path(project_path, entry.get("summaryPath"))
        summary = _read_json(summary_path) if summary_path is not None else None
        outputs = tuple(row for row in entry.get("outputs", []) if isinstance(row, dict)) if isinstance(entry.get("outputs"), list) else ()
        metadata = entry.get("metadata") if isinstance(entry.get("metadata"), dict) else {}
        records.append(
            RunHistoryRecord(
                tool=str(entry.get("tool", "")).strip() or "unknown",
                status=_status_from_entry(entry, summary),
                created_at=str(entry.get("createdAt", "")).strip() or _summary_timestamp(summary),
                summary_path=summary_path,
                summary=summary,
                metadata=dict(metadata),
                outputs=outputs,
            )
        )
    return records


def _resolve_summary_path(project_path: Path, raw_value: object) -> Path | None:
    value = str(raw_value or "").strip().strip('"')
    if not value:
        return None
    candidate = Path(value)
    return candidate if candidate.is_absolute() else (project_path / candidate).resolve()


def _read_json(path: Path | None) -> dict[str, object] | None:
    if path is None or not path.exists() or not path.is_file():
        return None
    try:
        payload = json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except Exception:
        return None
    return payload if isinstance(payload, dict) else None


def _status_from_entry(entry: dict[str, object], summary: dict[str, object] | None) -> str:
    summary_status = str(summary.get("status", "")).strip() if isinstance(summary, dict) else ""
    entry_status = str(entry.get("status", "")).strip()
    return summary_status or entry_status or "unknown"


def _summary_timestamp(summary: dict[str, object] | None) -> str:
    if not isinstance(summary, dict):
        return ""
    for key in ("generatedAt", "finishedAt", "startedAt", "createdAt"):
        value = str(summary.get(key, "")).strip()
        if value:
            return value
    return ""


def _timestamp_sort_key(raw_value: str) -> float:
    value = str(raw_value or "").strip()
    if not value:
        return 0.0
    parsed = _parse_iso_timestamp(value)
    if parsed is None:
        return 0.0
    return parsed.timestamp()


def format_timestamp(raw_value: str) -> str:
    parsed = _parse_iso_timestamp(raw_value)
    if parsed is None:
        return raw_value or "-"
    utc_value = parsed.astimezone(timezone.utc)
    return utc_value.strftime("%Y-%m-%d %H:%M:%SZ")


def _parse_iso_timestamp(raw_value: str) -> datetime | None:
    value = str(raw_value or "").strip()
    if not value:
        return None
    try:
        if value.endswith("Z"):
            return datetime.fromisoformat(value[:-1] + "+00:00")
        parsed = datetime.fromisoformat(value)
        return parsed if parsed.tzinfo is not None else parsed.replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def _list_string_values(value: object) -> list[str]:
    if not isinstance(value, list):
        return []
    return [str(item).strip() for item in value if str(item).strip()]


def _to_snake_case(value: str) -> str:
    out: list[str] = []
    for idx, char in enumerate(str(value or "")):
        if char.isupper() and idx > 0:
            out.append("_")
        out.append(char.lower())
    return "".join(out)


def _status_badge(status: str) -> str:
    normalized = str(status or "").strip().lower() or "unknown"
    return f"{STATUS_ICONS.get(normalized, '⚪')}<code>{_escape(normalized)}</code>"


def _escape(value: object) -> str:
    return html.escape(str(value), quote=False)
