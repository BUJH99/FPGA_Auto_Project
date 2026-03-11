from __future__ import annotations

import html
import re
import time
from dataclasses import dataclass
from pathlib import Path

from Telegram.bot.adapters.filesystem_evidence_reader import FilesystemEvidenceReader
from Telegram.bot.application.failure_triage import build_failure_triage
from Telegram.bot.domain.models import ArtifactRef, CommandSpec, ExecutionResult

VIVADO_LOG_FRESH_SLACK_SEC = 60.0
HIERARCHY_LOG_FRESH_SLACK_SEC = 30.0


@dataclass(frozen=True)
class CollectorContext:
    spec: CommandSpec
    started_ts: float
    run_log_path: Path | None
    timed_out: bool
    runtime_metadata: dict[str, object]
    diagram_limit: int = 3


def media_type_for_path(path: Path) -> str:
    suffix = path.suffix.lower()
    if suffix == ".svg":
        return "image/svg+xml"
    if suffix == ".png":
        return "image/png"
    if suffix in {".jpg", ".jpeg"}:
        return "image/jpeg"
    if suffix == ".webp":
        return "image/webp"
    if suffix == ".json":
        return "application/json"
    if suffix == ".log":
        return "text/plain"
    if suffix == ".md":
        return "text/markdown"
    if suffix in {".html", ".htm"}:
        return "text/html"
    if suffix == ".pdf":
        return "application/pdf"
    return "application/octet-stream"


def _resolve_summary_detail_path(summary_path: Path, payload: dict[str, object], raw_value: object) -> Path | None:
    value = str(raw_value or "").strip()
    if not value:
        return None

    candidate = Path(value.strip('"'))
    if candidate.is_absolute():
        return candidate

    project_root_raw = str(payload.get("projectRoot", "")).strip()
    if project_root_raw:
        return (Path(project_root_raw) / candidate).resolve()
    return (summary_path.parent / candidate).resolve()


def _extract_paths_from_summary_payload(
    summary_path: Path,
    *,
    reader: FilesystemEvidenceReader,
    detail_keys: tuple[str, ...],
    artifact_kinds: tuple[str, ...],
) -> list[Path]:
    payload = reader.read_json_file(summary_path)
    if not payload:
        return []

    out: list[Path] = []
    seen: set[Path] = set()
    details = payload.get("details")
    if isinstance(details, dict):
        for key in detail_keys:
            path = _resolve_summary_detail_path(summary_path, payload, details.get(key))
            if path is None or path in seen:
                continue
            seen.add(path)
            out.append(path)

    artifacts = payload.get("artifacts")
    if isinstance(artifacts, list):
        for artifact in artifacts:
            if not isinstance(artifact, dict):
                continue
            if artifact_kinds and str(artifact.get("kind", "")).strip() not in artifact_kinds:
                continue
            path = _resolve_summary_detail_path(summary_path, payload, artifact.get("path"))
            if path is None or path in seen:
                continue
            seen.add(path)
            out.append(path)

    return out


def _preferred_vivado_log_from_result(
    result: ExecutionResult,
    *,
    reader: FilesystemEvidenceReader,
    runtime_metadata: dict[str, object],
    lookup_ts: float | None = None,
) -> Path | None:
    runtime_path = str(runtime_metadata.get("sim_vivado_log_path") or "").strip()
    if runtime_path:
        candidate = Path(runtime_path)
        if candidate.exists() and candidate.is_file() and _is_recent_vivado_log(candidate, lookup_ts=lookup_ts):
            return candidate

    for summary_path in result.summary_paths:
        summary_candidates = _extract_paths_from_summary_payload(
            summary_path,
            reader=reader,
            detail_keys=("vivadoLogPath", "logPath"),
            artifact_kinds=("vivado_sim_log", "vivado_log"),
        )
        for candidate in summary_candidates:
            if candidate.exists() and candidate.is_file() and _is_recent_vivado_log(candidate, lookup_ts=lookup_ts):
                return candidate

    return None


def _is_recent_vivado_log(path: Path, *, lookup_ts: float | None = None) -> bool:
    check_ts = time.time() if lookup_ts is None else float(lookup_ts)
    try:
        mtime = path.stat().st_mtime
    except OSError:
        return False
    return mtime >= (check_ts - VIVADO_LOG_FRESH_SLACK_SEC)


def extract_hierarchy_log_candidates_from_run_log(run_log: Path, reader: FilesystemEvidenceReader | None = None) -> list[Path]:
    evidence = reader or FilesystemEvidenceReader()
    if not run_log.exists():
        return []

    lines = evidence.read_log_tail_lines(run_log, max_bytes=400_000)
    if not lines:
        return []

    out: list[Path] = []
    seen: set[Path] = set()
    file_re = re.compile(r"^\[INFO\]\s+Hierarchy log file\s*:\s*(.+?)\s*$", re.IGNORECASE)
    dir_re = re.compile(r"^\[INFO\]\s+Hierarchy logs?\s*:\s*(.+?)\s*$", re.IGNORECASE)
    summary_re = re.compile(r"^\[INFO\]\s+Hierarchy summary\s*:\s*(.+?)\s*$", re.IGNORECASE)

    for raw in lines:
        line = raw.strip()
        file_match = file_re.match(line)
        if file_match:
            path = Path(file_match.group(1).strip().strip('"'))
            if path not in seen:
                seen.add(path)
                out.append(path)
            continue

        summary_match = summary_re.match(line)
        if summary_match:
            summary_path = Path(summary_match.group(1).strip().strip('"'))
            summary_candidates = _extract_paths_from_summary_payload(
                summary_path,
                reader=evidence,
                detail_keys=("logPath", "hierarchyLogPath"),
                artifact_kinds=("hierarchy_log",),
            )
            for path in summary_candidates:
                if path in seen:
                    continue
                seen.add(path)
                out.append(path)
            if summary_path.suffix.lower() == ".log" and summary_path not in seen:
                seen.add(summary_path)
                out.append(summary_path)
            continue

        m_dir = dir_re.match(line)
        if m_dir:
            directory = Path(m_dir.group(1).strip().strip('"'))
            for path in sorted(directory.glob("hierarchy*.log")):
                if path in seen:
                    continue
                seen.add(path)
                out.append(path)

    return out


def list_recent_hierarchy_logs(
    spec: CommandSpec,
    started_ts: float,
    *,
    run_log: Path | None = None,
    require_fresh: bool = False,
    reader: FilesystemEvidenceReader | None = None,
) -> list[Path]:
    evidence = reader or FilesystemEvidenceReader()
    candidates: list[Path] = []
    seen: set[Path] = set()
    hinted_set: set[Path] = set()

    if run_log is not None:
        for path in extract_hierarchy_log_candidates_from_run_log(run_log, evidence):
            if path in seen:
                continue
            seen.add(path)
            hinted_set.add(path)
            candidates.append(path)

    for root in spec.artifact_roots:
        if root.name.lower() != "log":
            continue
        hierarchy_root = root / "hierarchy"
        if not hierarchy_root.exists():
            continue
        for path in sorted(hierarchy_root.glob("hierarchy*.log")):
            if path in seen:
                continue
            seen.add(path)
            candidates.append(path)

    scored: list[tuple[int, int, float, Path]] = []
    for path in candidates:
        try:
            mtime = path.stat().st_mtime
        except OSError:
            continue
        hinted = 1 if path in hinted_set else 0
        fresh = 1 if mtime >= (started_ts - HIERARCHY_LOG_FRESH_SLACK_SEC) else 0
        if require_fresh and fresh == 0 and hinted == 0:
            continue
        scored.append((hinted, fresh, mtime, path))

    scored.sort(key=lambda item: (item[0], item[1], item[2]), reverse=True)
    return [item[3] for item in scored]


def find_recent_hierarchy_log(
    spec: CommandSpec,
    started_ts: float,
    *,
    run_log: Path | None = None,
    require_fresh: bool = False,
    reader: FilesystemEvidenceReader | None = None,
) -> Path | None:
    logs = list_recent_hierarchy_logs(
        spec,
        started_ts,
        run_log=run_log,
        require_fresh=require_fresh,
        reader=reader,
    )
    return logs[0] if logs else None


def extract_vivado_log_candidates_from_run_log(run_log: Path, reader: FilesystemEvidenceReader | None = None) -> list[Path]:
    evidence = reader or FilesystemEvidenceReader()
    if not run_log.exists():
        return []
    lines = evidence.read_log_tail_lines(run_log, max_bytes=400_000)
    if not lines:
        return []

    out: list[Path] = []
    seen: set[Path] = set()
    file_res = (
        re.compile(r"^\[INFO\]\s+Vivado log file\s*:\s*(.+?)\s*$", re.IGNORECASE),
        re.compile(r"^\[INFO\]\s+Resolved Vivado log file\s*:\s*(.+?)\s*$", re.IGNORECASE),
    )
    dir_re = re.compile(r"^\[INFO\]\s+Vivado logs?\s*:\s*(.+?)\s*$", re.IGNORECASE)
    summary_res = (
        re.compile(r"^\[INFO\]\s+Vivado summary\s*:\s*(.+?)\s*$", re.IGNORECASE),
        re.compile(r"^\[INFO\]\s+summary\s*=\s*(.+?)\s*$", re.IGNORECASE),
        re.compile(r"^\[INFO\]\s+run_summary\s*=\s*(.+?)\s*$", re.IGNORECASE),
        re.compile(r"^\[INFO\]\s+run_summary_history\s*=\s*(.+?)\s*$", re.IGNORECASE),
    )

    for raw in lines:
        line = raw.strip()
        file_path: Path | None = None
        for file_re in file_res:
            file_match = file_re.match(line)
            if file_match:
                file_path = Path(file_match.group(1).strip().strip('"'))
                break
        if file_path is not None:
            if file_path not in seen:
                seen.add(file_path)
                out.append(file_path)
            continue

        summary_path: Path | None = None
        for summary_re in summary_res:
            summary_match = summary_re.match(line)
            if summary_match:
                summary_path = Path(summary_match.group(1).strip().strip('"'))
                break
        if summary_path is not None:
            summary_candidates = _extract_paths_from_summary_payload(
                summary_path,
                reader=evidence,
                detail_keys=("vivadoLogPath", "logPath"),
                artifact_kinds=("vivado_sim_log", "vivado_log"),
            )
            for path in summary_candidates:
                if path in seen:
                    continue
                seen.add(path)
                out.append(path)
            if summary_path.suffix.lower() == ".log" and summary_path not in seen:
                seen.add(summary_path)
                out.append(summary_path)
            continue

        m_dir = dir_re.match(line)
        if m_dir:
            directory = Path(m_dir.group(1).strip().strip('"'))
            for name in ("vivado_sim.log", "vivado.log"):
                path = directory / name
                if path not in seen:
                    seen.add(path)
                    out.append(path)
    return out


def list_recent_vivado_sim_logs(
    spec: CommandSpec,
    started_ts: float,
    *,
    run_log: Path | None = None,
    require_fresh: bool = False,
    lookup_ts: float | None = None,
    reader: FilesystemEvidenceReader | None = None,
) -> list[Path]:
    evidence = reader or FilesystemEvidenceReader()
    check_ts = time.time() if lookup_ts is None else float(lookup_ts)
    candidates: list[Path] = []
    seen: set[Path] = set()
    hinted_set: set[Path] = set()

    if run_log is not None:
        hinted = extract_vivado_log_candidates_from_run_log(run_log, evidence)
        for path in hinted:
            if path in seen:
                continue
            seen.add(path)
            hinted_set.add(path)
            candidates.append(path)

    for root in spec.artifact_roots:
        root_name = root.name.lower()
        if root_name not in {"log", "vivado_sim", "tb"}:
            continue
        if not root.exists():
            continue

        search_root = root / "vivado_sim" if root_name == "log" else root
        if not search_root.exists():
            continue

        preferred = search_root / "vivado_sim.log"
        if preferred.is_file() and preferred not in seen:
            seen.add(preferred)
            candidates.append(preferred)

        iterator = search_root.rglob("vivado_sim*.log") if root_name == "tb" else search_root.glob("*.log")
        for path in sorted(iterator):
            if not path.is_file() or path in seen:
                continue
            seen.add(path)
            candidates.append(path)

    scored: list[tuple[int, int, int, float, Path]] = []
    for path in candidates:
        try:
            mtime = path.stat().st_mtime
        except OSError:
            continue
        fresh = 1 if mtime >= (check_ts - VIVADO_LOG_FRESH_SLACK_SEC) else 0
        if fresh == 0:
            continue
        if require_fresh and fresh == 0 and path not in hinted_set:
            continue
        hinted = 1 if path in hinted_set else 0
        name = path.name.lower()
        priority = 2 if name == "vivado_sim.log" else 1 if name.startswith("vivado_sim") else 0
        scored.append((fresh, hinted, priority, mtime, path))

    scored.sort(key=lambda item: (item[0], item[1], item[2], item[3]), reverse=True)
    return [item[4] for item in scored]


def find_recent_vivado_sim_log(
    spec: CommandSpec,
    started_ts: float,
    *,
    run_log: Path | None = None,
    require_fresh: bool = False,
    lookup_ts: float | None = None,
    reader: FilesystemEvidenceReader | None = None,
) -> Path | None:
    logs = list_recent_vivado_sim_logs(
        spec,
        started_ts,
        run_log=run_log,
        require_fresh=require_fresh,
        lookup_ts=lookup_ts,
        reader=reader,
    )
    return logs[0] if logs else None


def extract_hierarchy_lines(log_path: Path, reader: FilesystemEvidenceReader | None = None) -> list[str]:
    evidence = reader or FilesystemEvidenceReader()
    lines = evidence.read_log_tail_lines(log_path)
    if not lines:
        return []

    hier_lines: list[str] = []
    capture = False
    start_markers = (
        "+--",
        "\\--",
        "[SV Declarations]",
        "[TB Folders]",
        "[TB Folder]",
        "No modules found.",
        "No TB folders found.",
        "No TB top modules/programs found.",
    )

    for raw in lines:
        clean_line = raw.rstrip("\r\n")
        stripped = clean_line.strip()
        if not capture and any(marker in clean_line for marker in start_markers):
            capture = True
        if not capture:
            continue
        if (
            "------------------------------------------------------------" in clean_line
            or stripped.startswith("Command")
            or stripped.startswith("**********************")
            or stripped.startswith("Transcript started")
            or stripped.startswith("Transcript stopped")
        ):
            break
        hier_lines.append(html.escape(clean_line))

    while hier_lines and not hier_lines[-1].strip():
        hier_lines.pop()
    return hier_lines


def parse_replay_state_from_lines(lines: list[str]) -> str | None:
    for line in reversed(lines):
        lower = line.lower()
        if "auto replay completed" in lower:
            return "success"
        if "run all completed" in lower and "auto replay" in lower:
            return "success"
        if "run all failed" in lower and "auto replay" in lower:
            return "fail"
        if "restart failed" in lower and "auto replay" in lower:
            return "fail"
        if "keeping vivado gui open by user choice" in lower:
            return "success"
        if "close request sent to vivado" in lower:
            return "success"
    return None


def extract_replay_log_excerpt(
    log_path: Path,
    max_lines: int,
    reader: FilesystemEvidenceReader | None = None,
) -> tuple[list[str], bool, bool]:
    evidence = reader or FilesystemEvidenceReader()
    lines = evidence.read_log_tail_lines(log_path)
    if not lines:
        return [], False, False

    marker_idx = -1
    for idx, line in enumerate(lines):
        if "Auto replay: restart + run all" in line:
            marker_idx = idx
    if marker_idx < 0:
        for idx, line in enumerate(lines):
            lower = line.lower()
            if "restart" in lower and "run all" in lower:
                marker_idx = idx

    excerpt = lines[marker_idx:] if marker_idx >= 0 else lines
    truncated = False
    if max_lines > 0 and len(excerpt) > max_lines:
        excerpt = excerpt[-max_lines:]
        truncated = True
    return excerpt, marker_idx >= 0, truncated


class DefaultResultCollector:
    def __init__(self, reader: FilesystemEvidenceReader) -> None:
        self._reader = reader

    def collect(self, result: ExecutionResult, context: CollectorContext) -> ExecutionResult:
        if context.spec.command_id == "report_html" or context.spec.menu_no == 10:
            return result
        tool_filters = self._expected_tools_for_command(context.spec.command_id)
        summary_paths = self._reader.find_summary_paths(
            context.spec.artifact_roots,
            started_ts=context.started_ts,
            expected_tools=tool_filters,
        )
        if summary_paths:
            result.summary_paths = tuple(summary_paths)
            summary_payload = self._reader.read_json_file(summary_paths[0])
            if summary_payload:
                result.structured_payload.setdefault("summary", summary_payload)
            result.evidence_source = "summary_json"
        return result

    def _expected_tools_for_command(self, command_id: str) -> tuple[str, ...]:
        tool_map: dict[str, tuple[str, ...]] = {
            "build": ("vivado_build",),
            "build_program": ("vivado_build",),
            "program": ("vivado_build",),
            "sim_auto_report": ("simulation_report",),
            "report_docs": ("report_documentation", "report_doc"),
            "doctor": ("toolkit_doctor",),
            "hierarchy": ("hierarchy_view",),
            "sim_vivado": ("vivado_sim_nogui",),
        }
        return tool_map.get(command_id, ())


class HierarchyResultCollector:
    def __init__(self, reader: FilesystemEvidenceReader) -> None:
        self._reader = reader

    def collect(self, result: ExecutionResult, context: CollectorContext) -> ExecutionResult:
        hierarchy_log = find_recent_hierarchy_log(
            context.spec,
            context.started_ts,
            run_log=context.run_log_path,
            require_fresh=not context.timed_out,
            reader=self._reader,
        )
        if hierarchy_log is not None:
            result.artifacts = result.artifacts + (
                ArtifactRef(
                    kind="hierarchy_log",
                    path=hierarchy_log,
                    label=hierarchy_log.name,
                    media_type=media_type_for_path(hierarchy_log),
                    origin="hierarchy_log",
                ),
            )
            result.structured_payload["hierarchy_log_path"] = str(hierarchy_log)
            result.structured_payload["tree_lines"] = extract_hierarchy_lines(hierarchy_log, self._reader)
            result.structured_payload["hierarchy_scope"] = context.spec.metadata.get("hierarchy_scope", "src")
            if result.evidence_source == "none":
                result.evidence_source = "log_hint"
        return result


class VivadoSimResultCollector:
    def __init__(self, reader: FilesystemEvidenceReader) -> None:
        self._reader = reader

    def collect(self, result: ExecutionResult, context: CollectorContext) -> ExecutionResult:
        log_path = _preferred_vivado_log_from_result(
            result,
            reader=self._reader,
            runtime_metadata=context.runtime_metadata,
            lookup_ts=time.time(),
        )
        if log_path is None:
            log_path = find_recent_vivado_sim_log(
                context.spec,
                context.started_ts,
                run_log=context.run_log_path,
                require_fresh=not context.timed_out,
                lookup_ts=time.time(),
                reader=self._reader,
            )
        if log_path is None and not context.timed_out:
            log_path = find_recent_vivado_sim_log(
                context.spec,
                context.started_ts,
                run_log=context.run_log_path,
                require_fresh=False,
                lookup_ts=time.time(),
                reader=self._reader,
            )
        if log_path is not None:
            result.artifacts = result.artifacts + (
                ArtifactRef(
                    kind="vivado_sim_log",
                    path=log_path,
                    label=log_path.name,
                    media_type=media_type_for_path(log_path),
                    origin="vivado_log",
                ),
            )
            result.structured_payload["vivado_log_path"] = str(log_path)
            lines = self._reader.read_log_tail_lines(log_path, max_bytes=900_000)
            replay_state = parse_replay_state_from_lines(lines)
            if replay_state is not None:
                result.structured_payload["replay_state"] = replay_state
            excerpt, marker_found, truncated = extract_replay_log_excerpt(
                log_path,
                max_lines=500,
                reader=self._reader,
            )
            if excerpt:
                result.structured_payload["vivado_log_excerpt"] = excerpt
                result.structured_payload["vivado_log_excerpt_marker_found"] = marker_found
                result.structured_payload["vivado_log_excerpt_truncated"] = truncated
            if result.evidence_source == "none":
                result.evidence_source = "log_hint"

        for key in (
            "sim_vivado_log_path",
            "sim_vivado_replay_state",
            "sim_vivado_replay_source",
            "sim_vivado_close_decision",
            "sim_vivado_controller_detached",
        ):
            if key in context.runtime_metadata:
                result.structured_payload[key] = context.runtime_metadata[key]
        return result


class DiagramResultCollector:
    def __init__(self, reader: FilesystemEvidenceReader) -> None:
        self._reader = reader

    def collect(self, result: ExecutionResult, context: CollectorContext) -> ExecutionResult:
        diagram_paths = self._reader.collect_recent_files(
            context.spec.artifact_roots,
            started_ts=context.started_ts,
            suffixes={".svg", ".png", ".jpg", ".jpeg", ".webp"},
            limit=context.diagram_limit,
            exclude_prefixes=("skin_",),
        )
        result.artifacts = result.artifacts + tuple(
            ArtifactRef(
                kind="diagram",
                path=path,
                label=path.name,
                media_type=media_type_for_path(path),
                origin="artifact_scan",
            )
            for path in diagram_paths
        )
        if diagram_paths and result.evidence_source == "none":
            result.evidence_source = "mtime_scan"
        return result


class ReportResultCollector:
    def __init__(self, reader: FilesystemEvidenceReader) -> None:
        self._reader = reader

    def collect(self, result: ExecutionResult, context: CollectorContext) -> ExecutionResult:
        if context.spec.command_id == "report_html":
            files = self._collect_report_files(context.spec, context.started_ts, "FINALReport", {".html", ".htm", ".pdf", ".md"})
        elif context.spec.command_id == "report_docs":
            files = self._collect_report_files(context.spec, context.started_ts, "docs", {".md"})
        else:
            files = []
        result.artifacts = result.artifacts + tuple(
            ArtifactRef(
                kind="report",
                path=path,
                label=path.name,
                media_type=media_type_for_path(path),
                origin="artifact_scan",
            )
            for path in files
        )
        if files and result.evidence_source == "none":
            result.evidence_source = "mtime_scan"
        return result

    def _collect_report_files(
        self,
        spec: CommandSpec,
        started_ts: float,
        output_subdir: str,
        suffixes: set[str],
    ) -> list[Path]:
        output_root = next((root for root in spec.artifact_roots if root.name.lower() == "output"), None)
        if output_root is None:
            return []
        target_root = output_root / output_subdir
        if not target_root.exists():
            return []
        return self._reader.collect_recent_files(
            (target_root,),
            started_ts=started_ts,
            suffixes=suffixes,
            limit=5 if output_subdir == "FINALReport" else None,
            slack_sec=5.0,
        )


class ResultCollectorRegistry:
    def __init__(self, reader: FilesystemEvidenceReader | None = None) -> None:
        self._reader = reader or FilesystemEvidenceReader()
        self._default = DefaultResultCollector(self._reader)
        self._by_kind = {
            "hierarchy": [HierarchyResultCollector(self._reader)],
            "sim_vivado": [VivadoSimResultCollector(self._reader)],
            "diagram": [DiagramResultCollector(self._reader)],
            "report": [ReportResultCollector(self._reader)],
        }

    @property
    def reader(self) -> FilesystemEvidenceReader:
        return self._reader

    def collect(self, result: ExecutionResult, context: CollectorContext) -> ExecutionResult:
        result = self._default.collect(result, context)
        for collector in self._by_kind.get(context.spec.result_kind, []):
            result = collector.collect(result, context)
        triage = build_failure_triage(result, context, self._reader)
        if triage:
            result.structured_payload["failure_triage"] = triage
        if result.evidence_source == "none" and result.raw_output_tail:
            result.evidence_source = "raw_output_tail"
        return result
