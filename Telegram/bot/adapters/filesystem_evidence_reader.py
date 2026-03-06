from __future__ import annotations

import json
import os
from pathlib import Path


class FilesystemEvidenceReader:
    def read_log_tail_lines(self, log_path: Path, max_bytes: int = 1_000_000) -> list[str]:
        try:
            with log_path.open("rb") as fh:
                fh.seek(0, os.SEEK_END)
                size = fh.tell()
                start = max(0, size - max_bytes)
                fh.seek(start, os.SEEK_SET)
                blob = fh.read()
        except OSError:
            return []

        text = blob.decode("utf-8", errors="replace")
        lines = text.splitlines()
        if start > 0 and lines:
            lines = lines[1:]
        return lines

    def read_json_file(self, path: Path) -> dict[str, object] | None:
        try:
            raw = json.loads(path.read_text(encoding="utf-8", errors="replace"))
        except Exception:
            return None
        return raw if isinstance(raw, dict) else None

    def derive_project_root(self, roots: tuple[Path, ...]) -> Path | None:
        for root in roots:
            if root.name.lower() in {"log", "output", "tb"}:
                return root.parent
        return roots[0] if roots else None

    def collect_recent_files(
        self,
        roots: tuple[Path, ...],
        *,
        started_ts: float,
        suffixes: set[str],
        limit: int | None = None,
        slack_sec: float = 2.0,
        exclude_prefixes: tuple[str, ...] = (),
    ) -> list[Path]:
        cutoff_ts = started_ts - slack_sec
        ranked: list[tuple[float, Path]] = []
        seen: set[Path] = set()

        for root in roots:
            if not root.exists():
                continue
            iterator = [root] if root.is_file() else list(root.rglob("*"))
            for path in iterator:
                if not path.is_file():
                    continue
                if path.suffix.lower() not in suffixes:
                    continue
                stem_lower = path.stem.lower()
                if any(stem_lower.startswith(prefix.lower()) for prefix in exclude_prefixes):
                    continue
                try:
                    mtime = path.stat().st_mtime
                except OSError:
                    continue
                if mtime < cutoff_ts:
                    continue
                if path in seen:
                    continue
                seen.add(path)
                ranked.append((mtime, path))

        ranked.sort(key=lambda item: item[0], reverse=True)
        items = [path for _, path in ranked]
        return items[:limit] if limit is not None else items

    def find_summary_paths(
        self,
        roots: tuple[Path, ...],
        *,
        started_ts: float,
        expected_tools: tuple[str, ...] = (),
    ) -> list[Path]:
        project_root = self.derive_project_root(roots)
        if project_root is None:
            return []

        output_dir = project_root / "output"
        candidates = [
            output_dir / "run_summary.json",
            output_dir / "build_summary.json",
            output_dir / "report_doc_summary.json",
            output_dir / "report_one_source_summary.json",
            output_dir / "regression_dashboard_summary.json",
        ]
        ranked: list[tuple[float, Path]] = []
        for path in candidates:
            if not path.exists() or not path.is_file():
                continue
            try:
                mtime = path.stat().st_mtime
            except OSError:
                continue
            if mtime < (started_ts - 5.0):
                continue
            ranked.append((mtime, path))

        run_index_path = output_dir / "run_index.json"
        run_index = self.read_json_file(run_index_path) if run_index_path.exists() else None
        if run_index:
            for entry in run_index.get("runs", []):
                if not isinstance(entry, dict):
                    continue
                tool = str(entry.get("tool", ""))
                if expected_tools and tool not in expected_tools:
                    continue
                summary_rel = str(entry.get("summaryPath", "")).strip()
                if not summary_rel:
                    continue
                summary_path = (project_root / summary_rel).resolve()
                if not summary_path.exists():
                    continue
                try:
                    mtime = summary_path.stat().st_mtime
                except OSError:
                    continue
                if mtime < (started_ts - 5.0):
                    continue
                ranked.append((mtime, summary_path))

        ranked.sort(key=lambda item: item[0], reverse=True)
        deduped: list[Path] = []
        seen: set[Path] = set()
        for _, path in ranked:
            if path in seen:
                continue
            seen.add(path)
            deduped.append(path)
        return deduped
