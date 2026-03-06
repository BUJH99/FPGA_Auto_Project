from __future__ import annotations

import html
from pathlib import Path

from Telegram.bot.domain.models import ExecutionResult, PromptContract
from Telegram.bot.domain.models import JobRequest


class TelegramPresenter:
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
