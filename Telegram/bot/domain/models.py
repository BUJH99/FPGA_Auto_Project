from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class MenuEntry:
    menu_no: int
    script_rel: str
    script_path: Path


@dataclass
class Config:
    bot_token: str
    allowed_user_ids: set[int]
    allowed_usernames: set[str]
    allowed_chat_ids: set[int]
    automation_repo_root: Path
    automation_templates_root: Path
    main_bat_path: Path
    menu_registry: dict[int, MenuEntry]
    project_root: Path
    poll_timeout_sec: int
    command_timeout_sec: int
    skip_pending_updates: bool
    auto_delete_webhook_on_start: bool
    progress_interval_sec: int
    send_diagrams: bool
    max_diagram_files: int
    sim_vivado_log_lines: int
    sim_vivado_send_log_file: bool
    sim_vivado_auto_complete_on_replay: bool
    sim_vivado_replay_check_sec: int
    allowed_command_groups: set[str] = field(default_factory=lambda: {"status", "run", "report"})
    notify_events: set[str] = field(default_factory=lambda: {"success", "fail", "program_done"})


@dataclass(frozen=True)
class InteractionContract:
    input_mode: str = "direct_execute"
    selection_source: str = "none"
    selection_cardinality: str = "none"
    confirmation_policy: str = "none"
    progress_policy: str = "default"
    completion_policy: str = "status_only"
    followup_policy: str = "none"


@dataclass(frozen=True)
class PromptChoice:
    value: str
    label: str
    description: str = ""


@dataclass(frozen=True)
class PromptContract:
    prompt_id: str
    prompt_type: str
    choices: tuple[PromptChoice, ...]
    default_choice: str
    expires_in_sec: int
    metadata: dict[str, object] = field(default_factory=dict)


@dataclass(frozen=True)
class ArtifactRef:
    kind: str
    path: Path
    label: str = ""
    media_type: str = ""
    freshness: str = "current_run"
    origin: str = ""


@dataclass(frozen=True)
class CommandSpec:
    command_id: str
    menu_no: int | None
    project_name: str | None
    script_path: Path
    cwd: Path
    args: tuple[str, ...] = ()
    stdin_text: str | None = None
    artifact_roots: tuple[Path, ...] = ()
    result_kind: str = "default"
    interaction_contract: InteractionContract = field(default_factory=InteractionContract)
    timeout_policy: str = "default"
    sim_vivado_close_gui: bool | None = None
    metadata: dict[str, object] = field(default_factory=dict)

    @property
    def cmd(self) -> tuple[str, ...]:
        return ("cmd.exe", "/c", str(self.script_path), *self.args)

    @property
    def command_name(self) -> str:
        return self.command_id


@dataclass(frozen=True)
class ExecutionRequest:
    spec: CommandSpec
    env_overrides: dict[str, str] = field(default_factory=dict)
    timeout_sec: int = 0
    run_label: str = ""
    allow_detach: bool = False


@dataclass
class ExecutionResult:
    command_id: str
    menu_no: int | None = None
    project_name: str | None = None
    status: str = "unknown"
    return_code: int = -1
    started_at: float = 0.0
    finished_at: float = 0.0
    duration_sec: int = 0
    run_log_path: Path | None = None
    raw_output_tail: tuple[str, ...] = ()
    summary_paths: tuple[Path, ...] = ()
    artifacts: tuple[ArtifactRef, ...] = ()
    structured_payload: dict[str, object] = field(default_factory=dict)
    warnings: tuple[str, ...] = ()
    prompt: PromptContract | None = None
    evidence_source: str = "none"
    detached: bool = False
    timed_out: bool = False
    sim_vivado_close_gui: bool | None = None
    sim_vivado_close_decision: str | None = None


@dataclass(frozen=True)
class RuntimeJobSnapshot:
    command_id: str
    menu_no: int | None
    project_name: str | None
    started_at: float
    sim_vivado_close_gui: bool | None = None


@dataclass(frozen=True)
class JobRequest:
    command_name: str
    menu_no: int | None
    project_name: str | None
    script_path: Path
    cwd: Path
    cmd: tuple[str, ...]
    stdin_text: str | None
    artifact_paths: tuple[Path, ...]
    sim_vivado_close_gui: bool | None
    command_id: str = ""
    result_kind: str = "default"
    interaction_contract: InteractionContract = field(default_factory=InteractionContract)
    timeout_policy: str = "default"
    metadata: dict[str, object] = field(default_factory=dict)

    @property
    def artifact_roots(self) -> tuple[Path, ...]:
        return self.artifact_paths

    def to_command_spec(self) -> CommandSpec:
        command_id = self.command_id or self.command_name
        args = tuple(str(part) for part in self.cmd[3:]) if len(self.cmd) >= 3 else ()
        return CommandSpec(
            command_id=command_id,
            menu_no=self.menu_no,
            project_name=self.project_name,
            script_path=self.script_path,
            cwd=self.cwd,
            args=args,
            stdin_text=self.stdin_text,
            artifact_roots=self.artifact_paths,
            result_kind=self.result_kind,
            interaction_contract=self.interaction_contract,
            timeout_policy=self.timeout_policy,
            sim_vivado_close_gui=self.sim_vivado_close_gui,
            metadata=dict(self.metadata),
        )


def job_request_from_command_spec(spec: CommandSpec) -> JobRequest:
    return JobRequest(
        command_name=spec.command_id,
        menu_no=spec.menu_no,
        project_name=spec.project_name,
        script_path=spec.script_path,
        cwd=spec.cwd,
        cmd=spec.cmd,
        stdin_text=spec.stdin_text,
        artifact_paths=spec.artifact_roots,
        sim_vivado_close_gui=spec.sim_vivado_close_gui,
        command_id=spec.command_id,
        result_kind=spec.result_kind,
        interaction_contract=spec.interaction_contract,
        timeout_policy=spec.timeout_policy,
        metadata=dict(spec.metadata),
    )


def command_spec_from_job(job: JobRequest) -> CommandSpec:
    return job.to_command_spec()
