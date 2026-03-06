from __future__ import annotations

import os
import re
import subprocess
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Callable

from Telegram.bot.adapters.filesystem_evidence_reader import FilesystemEvidenceReader
from Telegram.bot.domain.models import ExecutionRequest


@dataclass(frozen=True)
class BatchTickAction:
    done: bool = False
    return_code: int | None = None


@dataclass
class BatchProcessHandle:
    request: ExecutionRequest
    process: subprocess.Popen[str]
    run_log_path: Path
    output_handle: object
    started_at: float

    @property
    def pid(self) -> int:
        return int(self.process.pid)

    def poll(self) -> int | None:
        return self.process.poll()

    def wait(self, timeout: float | None = None) -> int:
        return int(self.process.wait(timeout=timeout))

    def kill(self) -> None:
        self.process.kill()

    def write_stdin(self, value: str) -> None:
        if self.process.stdin is None:
            return
        self.process.stdin.write(value)
        self.process.stdin.flush()

    def close_stdin(self) -> None:
        if self.process.stdin is None or self.process.stdin.closed:
            return
        self.process.stdin.close()

    def stdin_open(self) -> bool:
        return self.process.stdin is not None and not self.process.stdin.closed

    def close_output(self) -> None:
        try:
            self.output_handle.close()
        except Exception:
            pass


@dataclass(frozen=True)
class BatchExecutionOutcome:
    return_code: int
    timed_out: bool
    started_at: float
    finished_at: float
    duration_sec: int
    run_log_path: Path
    raw_output_tail: tuple[str, ...]


class BatchExecutor:
    def __init__(self, *, tail_line_limit: int = 200) -> None:
        self._reader = FilesystemEvidenceReader()
        self._tail_line_limit = tail_line_limit

    def start(self, request: ExecutionRequest, *, defer_stdin_close: bool = False) -> BatchProcessHandle:
        if os.name != "nt":
            raise RuntimeError("This bot launcher must run on Windows (cmd.exe required).")

        spec = request.spec
        if not spec.script_path.exists():
            raise RuntimeError(f"Script not found: {spec.script_path}")

        run_log_path = self._make_run_log_path(request.run_label or spec.command_id)
        out_handle = run_log_path.open("w", encoding="utf-8", errors="replace")
        env = os.environ.copy()
        env.update(request.env_overrides)

        process = subprocess.Popen(
            list(spec.cmd),
            cwd=str(spec.cwd),
            stdout=out_handle,
            stderr=subprocess.STDOUT,
            stdin=subprocess.PIPE if spec.stdin_text is not None else None,
            text=True,
            encoding="utf-8",
            errors="replace",
            env=env,
        )
        handle = BatchProcessHandle(
            request=request,
            process=process,
            run_log_path=run_log_path,
            output_handle=out_handle,
            started_at=time.time(),
        )

        if spec.stdin_text is not None and process.stdin is not None:
            handle.write_stdin(spec.stdin_text)
            if not defer_stdin_close:
                handle.close_stdin()

        return handle

    def wait(
        self,
        handle: BatchProcessHandle,
        *,
        timeout_sec: int,
        progress_interval_sec: int,
        on_progress: Callable[[int], None] | None = None,
        on_tick: Callable[[BatchProcessHandle, int], BatchTickAction | None] | None = None,
    ) -> BatchExecutionOutcome:
        timed_out = False
        result_rc = -1
        last_progress = time.time()

        try:
            while True:
                rc = handle.poll()
                now = time.time()
                elapsed = int(now - handle.started_at)

                if rc is not None:
                    result_rc = int(rc)
                    break

                if timeout_sec > 0 and elapsed >= timeout_sec:
                    timed_out = True
                    handle.kill()
                    try:
                        handle.wait(timeout=5)
                    except Exception:
                        pass
                    result_rc = 124
                    break

                if on_tick is not None:
                    action = on_tick(handle, elapsed)
                    if action is not None and action.done:
                        result_rc = int(action.return_code if action.return_code is not None else 0)
                        break

                if on_progress is not None and (now - last_progress) >= progress_interval_sec:
                    on_progress(elapsed)
                    last_progress = now

                time.sleep(1)
        finally:
            handle.close_output()

        finished_at = time.time()
        raw_tail = tuple(self._reader.read_log_tail_lines(handle.run_log_path)[-self._tail_line_limit :])
        return BatchExecutionOutcome(
            return_code=result_rc,
            timed_out=timed_out,
            started_at=handle.started_at,
            finished_at=finished_at,
            duration_sec=int(finished_at - handle.started_at),
            run_log_path=handle.run_log_path,
            raw_output_tail=raw_tail,
        )

    def terminate_process_tree(self, pid: int) -> None:
        try:
            subprocess.run(
                ["taskkill", "/PID", str(pid), "/T", "/F"],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except Exception:
            pass

    def _make_run_log_path(self, label: str) -> Path:
        sanitized = re.sub(r"[^A-Za-z0-9_-]", "_", label or "task")[:40]
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        return Path(tempfile.gettempdir()) / f"telegram_fpga_{sanitized}_{timestamp}.log"
