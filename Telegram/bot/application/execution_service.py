from __future__ import annotations

from typing import Callable

from Telegram.bot.adapters.batch_executor import BatchExecutionOutcome, BatchExecutor
from Telegram.bot.application.result_collectors import CollectorContext, ResultCollectorRegistry
from Telegram.bot.domain.models import ExecutionRequest, ExecutionResult


PromptResolver = Callable[[object], str | None]
ProgressCallback = Callable[[int], None]


class ExecutionService:
    def __init__(
        self,
        *,
        batch_executor: BatchExecutor | None = None,
        collectors: ResultCollectorRegistry | None = None,
        progress_interval_sec: int = 10,
        default_timeout_sec: int = 7200,
        diagram_limit: int = 3,
        sim_vivado_auto_complete_on_replay: bool = True,
        sim_vivado_replay_check_sec: int = 5,
    ) -> None:
        self._batch_executor = batch_executor or BatchExecutor()
        self._collectors = collectors or ResultCollectorRegistry()
        self._progress_interval_sec = max(5, progress_interval_sec)
        self._default_timeout_sec = default_timeout_sec
        self._diagram_limit = diagram_limit
        self._sim_vivado_auto_complete_on_replay = sim_vivado_auto_complete_on_replay
        self._sim_vivado_replay_check_sec = max(2, sim_vivado_replay_check_sec)

    def execute(
        self,
        request: ExecutionRequest,
        *,
        on_progress: ProgressCallback | None = None,
        prompt_resolver: PromptResolver | None = None,
    ) -> ExecutionResult:
        del prompt_resolver
        handle = self._batch_executor.start(request)
        outcome = self._batch_executor.wait(
            handle,
            timeout_sec=request.timeout_sec or self._default_timeout_sec,
            progress_interval_sec=self._progress_interval_sec,
            on_progress=on_progress,
        )
        return self._build_collected_result(request, outcome, timed_out=outcome.timed_out, runtime_metadata={})

    def _build_collected_result(
        self,
        request: ExecutionRequest,
        outcome: BatchExecutionOutcome,
        *,
        timed_out: bool,
        runtime_metadata: dict[str, object],
    ) -> ExecutionResult:
        status = "timeout" if timed_out else "success" if outcome.return_code == 0 else "fail"
        result = ExecutionResult(
            command_id=request.spec.command_id,
            menu_no=request.spec.menu_no,
            project_name=request.spec.project_name,
            status=status,
            return_code=outcome.return_code,
            started_at=outcome.started_at,
            finished_at=outcome.finished_at,
            duration_sec=outcome.duration_sec,
            run_log_path=outcome.run_log_path,
            raw_output_tail=outcome.raw_output_tail,
            detached=False,
            timed_out=timed_out,
            sim_vivado_close_gui=request.spec.sim_vivado_close_gui,
            sim_vivado_close_decision=None,
            structured_payload={
                "project_name": request.spec.project_name or "",
                "menu_no": request.spec.menu_no,
                **runtime_metadata,
            },
        )
        context = CollectorContext(
            spec=request.spec,
            started_ts=outcome.started_at,
            run_log_path=outcome.run_log_path,
            timed_out=timed_out,
            runtime_metadata=runtime_metadata,
            diagram_limit=self._diagram_limit,
        )
        return self._collectors.collect(result, context)
