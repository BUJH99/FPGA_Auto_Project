from __future__ import annotations

import html
from pathlib import Path

from Telegram.bot.domain.models import ExecutionResult, PromptContract
from Telegram.bot.domain.models import JobRequest


class TelegramPresenter:
    _DOCTOR_TOOL_ORDER = ("node", "python", "vivado", "yosys")
    _DOCTOR_TOOL_LABELS = {
        "node": "Node.js",
        "python": "Python",
        "vivado": "Vivado",
        "yosys": "Yosys",
    }

    def html_escape(self, value: object) -> str:
        return html.escape(str(value), quote=False)

    def _command_name(self, job: JobRequest) -> str:
        return job.command_id or job.command_name

    def build_start_text(self, job: JobRequest) -> str:
        lines = [f"🚀 <b>[START]</b> <i>command=</i><code>{self.html_escape(self._command_name(job))}</code>"]
        if job.menu_no is not None:
            lines.append(f"🔹 <i>menu=</i><code>{job.menu_no}</code>")
        if job.project_name:
            lines.append(f"🔹 <i>project=</i><code>{self.html_escape(job.project_name)}</code>")
        lines.append(f"🔹 <i>script=</i><code>{self.html_escape(job.script_path.name)}</code>")
        return "\n".join(lines)

    def build_progress_text(self, job: JobRequest, elapsed: int) -> str:
        lines = [
            f"⏳ <b>[PROGRESS]</b> <i>command=</i><code>{self.html_escape(self._command_name(job))}</code>",
            f"⏱ <i>elapsed=</i><code>{elapsed}s</code>",
        ]
        if job.menu_no is not None:
            lines.append(f"🔹 <i>menu=</i><code>{job.menu_no}</code>")
        if job.project_name:
            lines.append(f"🔹 <i>project=</i><code>{self.html_escape(job.project_name)}</code>")
        return "\n".join(lines)

    def build_prompt_message(self, job: JobRequest, prompt: PromptContract) -> tuple[str, dict[str, object]]:
        del prompt
        message = "\n".join(
            [
                "✨ <b>[INFO]</b> simulation completed.",
                f"🔹 <i>command=</i><code>{self.html_escape(self._command_name(job))}</code>",
                f"🔹 <i>project=</i><code>{self.html_escape(job.project_name or '')}</code>",
            ]
        )
        return message, {}

    def build_prompt(self, prompt: PromptContract) -> tuple[str, dict[str, object]]:
        project_name = str(prompt.metadata.get("project_name", "")).strip()
        command_id = str(prompt.metadata.get("command_id", "")).strip()
        lines = ["✨ <b>[INFO]</b> simulation completed."]
        if command_id:
            lines.append(f"🔹 <i>command=</i><code>{self.html_escape(command_id)}</code>")
        if project_name:
            lines.append(f"🔹 <i>project=</i><code>{self.html_escape(project_name)}</code>")
        return "\n".join(lines), {}

    def build_completion_text(self, job: JobRequest, result: ExecutionResult) -> str:
        command_name = self._command_name(job)
        if result.status == "timeout":
            lines = [
                f"⏰ <b>[TIMEOUT]</b> <i>command=</i><code>{self.html_escape(command_name)}</code>",
                f"⏱ <i>elapsed=</i><code>{result.duration_sec}s</code>",
            ]
        else:
            status = "✅ <b>[SUCCESS]</b>" if result.return_code == 0 else "❌ <b>[FAIL]</b>"
            lines = [
                f"{status} <i>command=</i><code>{self.html_escape(command_name)}</code>",
                f"🔹 <i>rc=</i><code>{result.return_code}</code> ⏱ <i>elapsed=</i><code>{result.duration_sec}s</code>",
            ]

        if result.run_log_path is not None:
            lines.append(f"📄 <i>run_log=</i><code>{self.html_escape(result.run_log_path.name)}</code>")
        if job.menu_no is not None:
            lines.append(f"🔹 <i>menu=</i><code>{job.menu_no}</code>")
        if job.project_name:
            lines.append(f"🔹 <i>project=</i><code>{self.html_escape(job.project_name)}</code>")
        if result.evidence_source != "none":
            lines.append(f"🔹 <i>evidence=</i><code>{self.html_escape(result.evidence_source)}</code>")
        if result.summary_paths:
            lines.append(f"📦 <i>summary=</i><code>{self.html_escape(result.summary_paths[0].name)}</code>")
        for artifact in result.artifacts:
            lines.append(f"📎 <i>artifact=</i><code>{self.html_escape(Path(artifact.path).name)}</code>")

        doctor_lines = self._build_doctor_summary_lines(command_name, result, job.menu_no)
        if doctor_lines:
            lines.append("")
            lines.extend(doctor_lines)

        tree_lines = result.structured_payload.get("tree_lines")
        if isinstance(tree_lines, list) and tree_lines:
            lines.append("")
            lines.append("🌳 <b>Hierarchy:</b>")
            lines.append("<pre>")
            lines.extend(str(line) for line in tree_lines)
            lines.append("</pre>")

        if result.status != "success" and result.raw_output_tail:
            lines.append("")
            lines.append("🧾 <b>Raw Tail:</b>")
            lines.append("<pre>")
            lines.extend(self.html_escape(line) for line in result.raw_output_tail[-20:])
            lines.append("</pre>")
        return "\n".join(lines)

    def _build_doctor_summary_lines(
        self,
        command_name: str,
        result: ExecutionResult,
        menu_no: int | None = None,
    ) -> list[str]:
        if command_name != "doctor" and menu_no != 21:
            return []

        summary = result.structured_payload.get("summary")
        if not isinstance(summary, dict):
            return []

        status = str(summary.get("status", "-")).strip() or "-"
        status_icon = {
            "ok": "🟢",
            "warning": "🟡",
            "failed": "🔴",
        }.get(status.lower(), "⚪")

        manifest = summary.get("manifest")
        manifest_valid = "-"
        if isinstance(manifest, dict):
            manifest_valid = "yes" if bool(manifest.get("valid")) else "no"

        resolved = summary.get("resolved")
        top_value = "-"
        counts_line = "src=<code>0</code> tb=<code>0</code> inc=<code>0</code> xdc=<code>0</code>"
        if isinstance(resolved, dict):
            top_value = str(resolved.get("top", "-")).strip() or "-"
            counts_line = (
                f"src=<code>{self.html_escape(resolved.get('srcCount', 0))}</code> "
                f"tb=<code>{self.html_escape(resolved.get('tbCount', 0))}</code> "
                f"inc=<code>{self.html_escape(resolved.get('incCount', 0))}</code> "
                f"xdc=<code>{self.html_escape(resolved.get('xdcCount', 0))}</code>"
            )

        tb_naming = summary.get("tbNaming")
        tb_line = "expected=<code>-</code> matched=<code>-</code>"
        if isinstance(tb_naming, dict):
            tb_line = (
                f"expected=<code>{self.html_escape(tb_naming.get('expectedBaseName', '-'))}</code> "
                f"matched=<code>{'yes' if bool(tb_naming.get('matched')) else 'no'}</code>"
            )

        tools = summary.get("tools")
        tool_lines: list[str] = []
        missing_tools: list[str] = []
        if isinstance(tools, dict):
            for tool_name in self._DOCTOR_TOOL_ORDER:
                tool_row = tools.get(tool_name)
                if not isinstance(tool_row, dict):
                    continue
                ok = bool(tool_row.get("ok"))
                label = self._DOCTOR_TOOL_LABELS.get(tool_name, tool_name)
                tool_lines.append(f"{'✅' if ok else '❌'} {label}")
                if not ok:
                    missing_tools.append(label)

        warnings = summary.get("warnings")
        warning_values = [str(item).strip() for item in warnings if str(item).strip()] if isinstance(warnings, list) else []

        lines = [
            "🩺 <b>Doctor Summary</b>",
            f"{status_icon} <b>Status:</b> <code>{self.html_escape(status)}</code> | <b>Healthy:</b> <code>{'yes' if bool(summary.get('ok')) else 'no'}</code>",
            f"📘 <b>Manifest:</b> <code>{self.html_escape(manifest_valid)}</code>",
            f"🧠 <b>Top:</b> <code>{self.html_escape(top_value)}</code>",
            f"📦 <b>Resolved:</b> {counts_line}",
            f"🧪 <b>TB Naming:</b> {tb_line}",
        ]

        if tool_lines:
            lines.append("🛠 <b>Tools:</b>")
            lines.extend(tool_lines)

        if warning_values:
            lines.append("⚠️ <b>Warnings:</b>")
            lines.extend(f"• <code>{self.html_escape(item)}</code>" for item in warning_values)
        else:
            lines.append("✅ <b>Warnings:</b> <code>none</code>")

        if missing_tools:
            lines.append(f"🚫 <b>Missing Tools:</b> <code>{self.html_escape(', '.join(missing_tools))}</code>")

        return lines
