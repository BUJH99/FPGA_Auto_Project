import importlib.util
import os
import sys
import tempfile
import time
import unittest
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
BOT_PATH = REPO_ROOT / "Telegram" / "telegram_fpga_bot.py"
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from Telegram.bot.adapters.batch_executor import BatchExecutionOutcome
from Telegram.bot.adapters.telegram_presenter import TelegramPresenter
from Telegram.bot.application.command_resolver import CommandResolver
from Telegram.bot.application.execution_service import ExecutionService
from Telegram.bot.application.result_collectors import ResultCollectorRegistry
from Telegram.bot.domain.models import CommandSpec, Config, ExecutionRequest, JobRequest, MenuEntry


def load_bot_module():
    module_name = "telegram_fpga_bot_layered_under_test"
    spec = importlib.util.spec_from_file_location(module_name, BOT_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


BOT = load_bot_module()


class FakeBatchExecutor:
    def __init__(self, outcome: BatchExecutionOutcome):
        self.outcome = outcome
        self.started_requests: list[ExecutionRequest] = []

    def start(self, request: ExecutionRequest, defer_stdin_close: bool = False):
        self.started_requests.append(request)
        return object()

    def wait(self, handle, *, timeout_sec, progress_interval_sec, on_progress=None, on_tick=None):
        if on_progress is not None:
            on_progress(12)
        return self.outcome


@dataclass
class FakeSimVivadoHandle:
    run_log_path: Path
    started_at: float
    stdin_closed: bool = False

    @property
    def pid(self) -> int:
        return 1234

    def stdin_open(self) -> bool:
        return not self.stdin_closed

    def write_stdin(self, value: str) -> None:
        return None

    def close_stdin(self) -> None:
        self.stdin_closed = True

    def wait(self, timeout=None) -> int:
        return 0


class FakeSimVivadoBatchExecutor:
    def __init__(self, handle: FakeSimVivadoHandle, outcome: BatchExecutionOutcome, *, tick_elapsed: int = 5):
        self.handle = handle
        self.outcome = outcome
        self.tick_elapsed = tick_elapsed
        self.started_requests: list[ExecutionRequest] = []

    def start(self, request: ExecutionRequest, defer_stdin_close: bool = False):
        self.started_requests.append(request)
        return self.handle

    def wait(self, handle, *, timeout_sec, progress_interval_sec, on_progress=None, on_tick=None):
        if on_tick is not None:
            on_tick(handle, self.tick_elapsed)
        return self.outcome

    def terminate_process_tree(self, pid: int) -> None:
        return None


class LayeredComponentTests(unittest.TestCase):
    def make_config(self, project_root: Path) -> Config:
        templates_root = REPO_ROOT / "templates"
        return Config(
            bot_token="token",
            allowed_user_ids={1},
            allowed_usernames=set(),
            allowed_chat_ids=set(),
            automation_repo_root=REPO_ROOT,
            automation_templates_root=templates_root,
            main_bat_path=REPO_ROOT / "MAIN.bat",
            menu_registry={
                2: MenuEntry(
                    menu_no=2,
                    script_rel="contexts\\code_intel\\adapters\\bat\\code_browse_hierarchy.bat",
                    script_path=templates_root / "contexts" / "code_intel" / "adapters" / "bat" / "code_browse_hierarchy.bat",
                ),
                5: MenuEntry(
                    menu_no=5,
                    script_rel="contexts\\simulation\\adapters\\bat\\sim_run_vivado.bat",
                    script_path=templates_root / "contexts" / "simulation" / "adapters" / "bat" / "sim_run_vivado.bat",
                ),
                20: MenuEntry(
                    menu_no=20,
                    script_rel="contexts\\simulation\\adapters\\bat\\sim_run_vivado_nogui.bat",
                    script_path=templates_root / "contexts" / "simulation" / "adapters" / "bat" / "sim_run_vivado_nogui.bat",
                ),
                21: MenuEntry(
                    menu_no=21,
                    script_rel="shared\\adapters\\bat\\toolkit_doctor.bat",
                    script_path=templates_root / "shared" / "adapters" / "bat" / "toolkit_doctor.bat",
                ),
            },
            project_root=project_root,
            poll_timeout_sec=25,
            command_timeout_sec=7200,
            skip_pending_updates=True,
            auto_delete_webhook_on_start=True,
            progress_interval_sec=10,
            send_diagrams=True,
            max_diagram_files=3,
            sim_vivado_log_lines=120,
            sim_vivado_send_log_file=True,
            sim_vivado_auto_complete_on_replay=True,
            sim_vivado_replay_check_sec=5,
        )

    def make_resolver(self, config: Config) -> CommandResolver:
        return CommandResolver(
            config,
            parse_module_selection=BOT.parse_module_selection,
            parse_positive_int=BOT.parse_positive_int,
            parse_yes_no_token=BOT.parse_yes_no_token,
            parse_sim_vivado_close_choice=BOT.parse_sim_vivado_close_choice,
            format_stdin=BOT.format_stdin,
        )

    def test_command_resolver_assigns_interaction_contracts_and_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir) / "managed_root" / "Project"
            project_path = project_root / "Demo"
            project_path.mkdir(parents=True)
            config = self.make_config(project_root)
            resolver = self.make_resolver(config)

            spec, error = resolver.build_menu_command_spec(2, project_path, ["tb"], "hierarchy")
            self.assertIsNone(error)
            assert spec is not None
            self.assertEqual("hierarchy", spec.command_id)
            self.assertEqual("hierarchy", spec.result_kind)
            self.assertEqual("scope_select", spec.interaction_contract.input_mode)
            self.assertEqual("tb_only", spec.metadata["hierarchy_scope"])

            spec, error = resolver.build_menu_command_spec(20, project_path, ["1", "2"], "sim_vivado")
            self.assertIsNone(error)
            assert spec is not None
            self.assertEqual("sim_vivado", spec.command_id)
            self.assertEqual("sim_vivado", spec.result_kind)
            self.assertEqual("tb_folder_select", spec.interaction_contract.input_mode)
            self.assertEqual(1, spec.metadata["folder_idx"])
            self.assertEqual(2, spec.metadata["tb_idx"])
            self.assertIsNone(spec.sim_vivado_close_gui)

            spec, error = resolver.build_menu_command_spec(21, project_path, [], "doctor")
            self.assertIsNone(error)
            assert spec is not None
            self.assertEqual("doctor", spec.command_id)
            self.assertEqual("doctor", spec.result_kind)
            self.assertEqual("direct_execute", spec.interaction_contract.input_mode)

    def test_execution_service_collects_summary_paths_from_default_collector(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir) / "Demo"
            output_dir = project_root / "output"
            log_dir = project_root / "log"
            output_dir.mkdir(parents=True)
            log_dir.mkdir(parents=True)
            summary_path = output_dir / "run_summary.json"
            summary_path.write_text('{"tool":"simulation_report","status":"ok"}\n', encoding="utf-8")
            run_log = Path(temp_dir) / "telegram_fpga_fake.log"
            run_log.write_text("[INFO] complete\n", encoding="utf-8")
            now = time.time()
            outcome = BatchExecutionOutcome(
                return_code=0,
                timed_out=False,
                started_at=now,
                finished_at=now + 1,
                duration_sec=1,
                run_log_path=run_log,
                raw_output_tail=("[INFO] complete",),
            )
            spec = CommandSpec(
                command_id="sim_auto_report",
                menu_no=6,
                project_name="Demo",
                script_path=REPO_ROOT / "templates" / "contexts" / "simulation" / "adapters" / "bat" / "sim_run_auto_report.bat",
                cwd=REPO_ROOT,
                args=(str(project_root),),
                artifact_roots=(log_dir, output_dir),
                result_kind="simulation_report",
            )
            service = ExecutionService(
                batch_executor=FakeBatchExecutor(outcome),
                collectors=ResultCollectorRegistry(),
                progress_interval_sec=10,
                default_timeout_sec=60,
            )

            result = service.execute(ExecutionRequest(spec=spec, timeout_sec=60, run_label="sim_auto_report"))
            self.assertEqual("success", result.status)
            self.assertEqual(6, result.menu_no)
            self.assertEqual("Demo", result.project_name)
            self.assertFalse(result.timed_out)
            self.assertTrue(result.summary_paths)
            self.assertEqual(summary_path, result.summary_paths[0])
            self.assertEqual("summary_json", result.evidence_source)

    def test_result_collector_extracts_hierarchy_tree_from_run_log_hint(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir) / "Demo"
            log_root = project_root / "log" / "hierarchy"
            output_root = project_root / "output"
            log_root.mkdir(parents=True)
            output_root.mkdir(parents=True)
            hierarchy_log = log_root / "hierarchy_20260306_123456_001.log"
            hierarchy_log.write_text("+-- Top (src/top.sv)\n", encoding="utf-8")
            run_log = Path(temp_dir) / "telegram_fpga_hierarchy.log"
            run_log.write_text(f"[INFO] Hierarchy log file: {hierarchy_log}\n", encoding="utf-8")
            now = time.time()
            outcome = BatchExecutionOutcome(
                return_code=0,
                timed_out=False,
                started_at=now,
                finished_at=now + 1,
                duration_sec=1,
                run_log_path=run_log,
                raw_output_tail=("[INFO] Hierarchy log file",),
            )
            spec = CommandSpec(
                command_id="hierarchy",
                menu_no=2,
                project_name="Demo",
                script_path=REPO_ROOT / "templates" / "contexts" / "code_intel" / "adapters" / "bat" / "code_browse_hierarchy.bat",
                cwd=REPO_ROOT,
                args=(str(project_root), "--once", "--tb-only"),
                artifact_roots=(project_root / "log", output_root),
                result_kind="hierarchy",
                metadata={"hierarchy_scope": "tb_only"},
            )
            service = ExecutionService(
                batch_executor=FakeBatchExecutor(outcome),
                collectors=ResultCollectorRegistry(),
                progress_interval_sec=10,
                default_timeout_sec=60,
            )

            result = service.execute(ExecutionRequest(spec=spec, timeout_sec=60, run_label="hierarchy"))
            self.assertEqual("log_hint", result.evidence_source)
            self.assertEqual("tb_only", result.structured_payload["hierarchy_scope"])
            self.assertIn("+-- Top (src/top.sv)", result.structured_payload["tree_lines"][0])

    def test_execution_service_runs_sim_vivado_without_prompt_branch(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir) / "Demo"
            tb_root = project_root / "tb" / "StopwatchFsm_tb"
            tb_root.mkdir(parents=True, exist_ok=True)
            now = time.time()
            run_log = Path(temp_dir) / "telegram_fpga_sim_vivado.log"
            run_log.write_text("[INFO] Auto replay run all completed.\n", encoding="utf-8")
            outcome = BatchExecutionOutcome(
                return_code=0,
                timed_out=False,
                started_at=now,
                finished_at=now + 1,
                duration_sec=1,
                run_log_path=run_log,
                raw_output_tail=("[INFO] Auto replay run all completed.",),
            )
            spec = CommandSpec(
                command_id="sim_vivado",
                menu_no=20,
                project_name="Demo",
                script_path=REPO_ROOT / "templates" / "contexts" / "simulation" / "adapters" / "bat" / "sim_run_vivado_nogui.bat",
                cwd=REPO_ROOT,
                args=(str(project_root), "TbTop"),
                artifact_roots=(project_root / "log", project_root / "output", project_root / "tb"),
                result_kind="sim_vivado",
            )
            service = ExecutionService(
                batch_executor=FakeBatchExecutor(outcome),
                collectors=ResultCollectorRegistry(),
                progress_interval_sec=1,
                default_timeout_sec=60,
            )

            result = service.execute(
                ExecutionRequest(spec=spec, timeout_sec=60, run_label="sim_vivado"),
            )

            self.assertEqual("success", result.status)
            self.assertNotIn("sim_vivado_close_decision", result.structured_payload)
            self.assertFalse(result.detached)

    def test_telegram_presenter_includes_raw_tail_for_failures(self) -> None:
        presenter = TelegramPresenter()
        job = JobRequest(
            command_name="build",
            menu_no=13,
            project_name="Demo",
            script_path=REPO_ROOT / "templates" / "contexts" / "vivado" / "adapters" / "bat" / "vivado_run_build_flow.bat",
            cwd=REPO_ROOT,
            cmd=("cmd.exe", "/c", "vivado_run_build_flow.bat", "Demo"),
            stdin_text=None,
            artifact_paths=(),
            sim_vivado_close_gui=None,
            command_id="build",
            result_kind="build",
        )
        from Telegram.bot.domain.models import ExecutionResult

        result = ExecutionResult(
            command_id="build",
            status="fail",
            return_code=1,
            duration_sec=5,
            raw_output_tail=("line1", "line2"),
            evidence_source="raw_output_tail",
        )
        text = presenter.build_completion_text(job, result)
        self.assertIn("[FAIL]", text)
        self.assertIn("Raw Tail", text)
        self.assertIn("line2", text)

    def test_telegram_presenter_renders_doctor_summary(self) -> None:
        presenter = TelegramPresenter()
        job = JobRequest(
            command_name="doctor",
            menu_no=21,
            project_name="Demo",
            script_path=REPO_ROOT / "templates" / "shared" / "adapters" / "bat" / "toolkit_doctor.bat",
            cwd=REPO_ROOT,
            cmd=("cmd.exe", "/c", "toolkit_doctor.bat", "Demo"),
            stdin_text=None,
            artifact_paths=(),
            sim_vivado_close_gui=None,
            command_id="doctor",
            result_kind="doctor",
        )
        from Telegram.bot.domain.models import ExecutionResult

        result = ExecutionResult(
            command_id="doctor",
            status="fail",
            return_code=1,
            duration_sec=4,
            structured_payload={
                "summary": {
                    "status": "warning",
                    "ok": False,
                    "warnings": ["tool_missing:node", "xdc_missing"],
                    "tools": {
                        "node": {"ok": False},
                        "python": {"ok": True},
                        "vivado": {"ok": False},
                        "yosys": {"ok": False},
                    },
                }
            },
        )
        text = presenter.build_completion_text(job, result)
        self.assertIn("Doctor Summary", text)
        self.assertIn("Status:</b> <code>warning</code>", text)
        self.assertIn("Healthy:</b> <code>no</code>", text)
        self.assertIn("Manifest:</b> <code>-</code>", text)
        self.assertIn("Top:</b> <code>-</code>", text)
        self.assertIn("Node.js", text)
        self.assertIn("Vivado", text)
        self.assertIn("tool_missing:node", text)
        self.assertIn("Missing Tools:</b> <code>Node.js, Vivado, Yosys</code>", text)


if __name__ == "__main__":
    unittest.main()
