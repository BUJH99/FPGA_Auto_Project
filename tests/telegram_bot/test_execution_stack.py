import os
import tempfile
import time
import unittest
from pathlib import Path

from Telegram.bot.adapters.filesystem_evidence_reader import FilesystemEvidenceReader
from Telegram.bot.adapters.telegram_presenter import TelegramPresenter
from Telegram.bot.application.command_resolver import CommandResolver
from Telegram.bot.application.result_collectors import CollectorContext, ResultCollectorRegistry
from Telegram.bot.domain.models import Config, ExecutionResult, JobRequest
from Telegram.telegram_fpga_bot import parse_main_menu_registry


REPO_ROOT = Path(__file__).resolve().parents[2]


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def make_config(project_root: Path) -> Config:
    registry = parse_main_menu_registry(REPO_ROOT / "MAIN.bat", REPO_ROOT / "templates")
    return Config(
        bot_token="token",
        allowed_user_ids={1},
        allowed_usernames=set(),
        allowed_chat_ids=set(),
        automation_repo_root=REPO_ROOT,
        automation_templates_root=REPO_ROOT / "templates",
        main_bat_path=REPO_ROOT / "MAIN.bat",
        menu_registry=registry,
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


class ExecutionStackTests(unittest.TestCase):
    def create_project(self, root: Path) -> Path:
        project_root = root / "Project"
        project_path = project_root / "Demo"
        (project_path / "src").mkdir(parents=True, exist_ok=True)
        write_text(project_path / "fpga_auto.yml", "name: Demo\n")
        return project_path

    def test_command_resolver_builds_contract_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_path = self.create_project(Path(temp_dir))
            config = make_config(project_path.parent)
            resolver = CommandResolver(config)

            sim_spec, error = resolver.build_menu_command_spec(20, project_path, ["1", "2"], "sim_vivado")
            self.assertIsNone(error)
            assert sim_spec is not None
            self.assertEqual("sim_vivado", sim_spec.command_id)
            self.assertEqual("sim_vivado", sim_spec.result_kind)
            self.assertEqual("tb_folder_select", sim_spec.interaction_contract.input_mode)
            self.assertEqual(1, sim_spec.metadata["folder_idx"])
            self.assertEqual(2, sim_spec.metadata["tb_idx"])
            self.assertIsNone(sim_spec.sim_vivado_close_gui)

            hier_spec, error = resolver.build_menu_command_spec(2, project_path, ["tb"], "hierarchy")
            self.assertIsNone(error)
            assert hier_spec is not None
            self.assertEqual("hierarchy", hier_spec.command_id)
            self.assertEqual("hierarchy", hier_spec.result_kind)
            self.assertEqual("scope_select", hier_spec.interaction_contract.input_mode)
            self.assertEqual("tb_only", hier_spec.metadata["hierarchy_scope"])

    def test_result_collector_prefers_summary_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_path = self.create_project(Path(temp_dir))
            output_root = project_path / "output"
            write_text(
                output_root / "run_summary.json",
                '{"tool":"simulation_report","status":"ok","details":{"passCount":4}}',
            )

            config = make_config(project_path.parent)
            resolver = CommandResolver(config)
            spec, error = resolver.build_menu_command_spec(6, project_path, ["1"], "sim_auto_report")
            self.assertIsNone(error)
            assert spec is not None

            registry = ResultCollectorRegistry(FilesystemEvidenceReader())
            base_result = ExecutionResult(
                command_id=spec.command_id,
                menu_no=spec.menu_no,
                project_name=spec.project_name,
                status="success",
                return_code=0,
                started_at=0.0,
                finished_at=0.0,
            )
            collected = registry.collect(
                base_result,
                CollectorContext(spec=spec, started_ts=0.0, run_log_path=None, timed_out=False, runtime_metadata={}),
            )
            self.assertEqual("summary_json", collected.evidence_source)
            self.assertTrue(collected.summary_paths)
            self.assertEqual("simulation_report", collected.structured_payload["summary"]["tool"])

    def test_result_collector_prefers_runtime_selected_vivado_log(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_path = self.create_project(Path(temp_dir))
            tb_root = project_path / "tb" / "smoke"
            log_root = project_path / "log" / "vivado_sim"
            output_root = project_path / "output"
            tb_root.mkdir(parents=True, exist_ok=True)
            log_root.mkdir(parents=True, exist_ok=True)
            output_root.mkdir(parents=True, exist_ok=True)

            old_log = log_root / "vivado.log"
            current_log = tb_root / "vivado_sim_tb_smoke.log"
            write_text(old_log, "stale\n")
            write_text(current_log, "[INFO] Auto replay run all completed.\n")

            now = time.time()
            os.utime(old_log, (now, now))
            os.utime(current_log, (now - 1, now - 1))

            config = make_config(project_path.parent)
            resolver = CommandResolver(config)
            spec, error = resolver.build_menu_command_spec(20, project_path, ["1", "1"], "sim_vivado")
            self.assertIsNone(error)
            assert spec is not None

            registry = ResultCollectorRegistry(FilesystemEvidenceReader())
            base_result = ExecutionResult(
                command_id=spec.command_id,
                menu_no=spec.menu_no,
                project_name=spec.project_name,
                status="success",
                return_code=0,
                started_at=now,
                finished_at=now + 1,
            )
            collected = registry.collect(
                base_result,
                CollectorContext(
                    spec=spec,
                    started_ts=now,
                    run_log_path=None,
                    timed_out=False,
                    runtime_metadata={"sim_vivado_log_path": str(current_log)},
                ),
            )
            vivado_artifacts = [artifact for artifact in collected.artifacts if artifact.kind == "vivado_sim_log"]
            self.assertTrue(vivado_artifacts)
            self.assertEqual(current_log, vivado_artifacts[0].path)

    def test_presenter_renders_raw_tail_and_hierarchy_payload(self) -> None:
        presenter = TelegramPresenter()
        job = JobRequest(
            command_name="build",
            command_id="build",
            menu_no=13,
            project_name="Demo",
            script_path=REPO_ROOT / "templates" / "contexts" / "vivado" / "adapters" / "bat" / "vivado_run_build_flow.bat",
            cwd=REPO_ROOT,
            cmd=("cmd.exe", "/c", "build.bat"),
            stdin_text=None,
            artifact_paths=(),
            sim_vivado_close_gui=None,
        )

        failure = ExecutionResult(
            command_id="build",
            menu_no=13,
            project_name="Demo",
            status="failed",
            return_code=1,
            duration_sec=12,
            raw_output_tail=("first error", "second error"),
        )
        failure_text = presenter.build_completion_text(job, failure)
        self.assertIn("[FAIL]", failure_text)
        self.assertIn("Raw Tail", failure_text)
        self.assertIn("first error", failure_text)

        hierarchy = ExecutionResult(
            command_id="hierarchy",
            menu_no=2,
            project_name="Demo",
            status="success",
            return_code=0,
            duration_sec=3,
            structured_payload={"tree_lines": ["+-- TOP", "\\-- child"]},
        )
        hierarchy_job = JobRequest(
            command_name="hierarchy",
            command_id="hierarchy",
            menu_no=2,
            project_name="Demo",
            script_path=REPO_ROOT / "templates" / "contexts" / "code_intel" / "adapters" / "bat" / "code_browse_hierarchy.bat",
            cwd=REPO_ROOT,
            cmd=("cmd.exe", "/c", "hierarchy.bat"),
            stdin_text=None,
            artifact_paths=(),
            sim_vivado_close_gui=None,
        )
        hierarchy_text = presenter.build_completion_text(hierarchy_job, hierarchy)
        self.assertIn("Hierarchy", hierarchy_text)
        self.assertIn("+-- TOP", hierarchy_text)


if __name__ == "__main__":
    unittest.main()
