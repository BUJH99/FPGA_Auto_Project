import importlib.util
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
BOT_PATH = REPO_ROOT / "Telegram" / "telegram_fpga_bot.py"


def load_bot_module():
    module_name = "telegram_fpga_bot_under_test"
    spec = importlib.util.spec_from_file_location(module_name, BOT_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


BOT = load_bot_module()


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


class TelegramBotTests(unittest.TestCase):
    def setUp(self) -> None:
        BOT.STATE = BOT.RuntimeState()

    def make_config(self, project_root: Path):
        registry = BOT.parse_main_menu_registry(REPO_ROOT / "MAIN.bat", REPO_ROOT / "templates")
        return BOT.Config(
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

    def create_project_root(self, base_dir: Path) -> tuple[Path, Path]:
        project_root = base_dir / "managed_root" / "Project"
        project_path = project_root / "Demo"
        (project_path / "src").mkdir(parents=True, exist_ok=True)
        write_text(project_path / "fpga_auto.yml", "name: Demo\n")
        return project_root, project_path

    def write_run_index(self, project_path: Path, runs: list[dict]) -> None:
        write_text(
            project_path / "output" / "run_index.json",
            json.dumps(
                {
                    "schemaVersion": 1,
                    "kind": "run_index",
                    "projectRoot": project_path.as_posix(),
                    "updatedAt": "2026-03-11T00:00:00Z",
                    "runs": runs,
                },
                indent=2,
            )
            + "\n",
        )

    def test_get_secret_file_candidates_prefers_git_adjacent_fpga_agent_token(self) -> None:
        with mock.patch.dict(BOT.os.environ, {}, clear=True):
            candidates = BOT.get_secret_file_candidates()
        self.assertEqual(
            [
                REPO_ROOT.parent / "FPGA_AGENT_TOKEN" / "TELEGRAMTOKEN_ID.txt",
                REPO_ROOT.parent / "MOBILE_AGENT_TOKEN" / "TELEGRAMTOKEN_ID.txt",
            ],
            candidates,
        )

    def test_register_bot_menu_commands_includes_run(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root, _ = self.create_project_root(Path(temp_dir))
            config = self.make_config(project_root)

            with mock.patch.object(BOT, "telegram_api") as api_mock:
                BOT.register_bot_menu_commands(config)

            payload = api_mock.call_args.args[2]
            commands = payload["commands"]
            command_names = [row["command"] for row in commands]
            self.assertIn("run", command_names)
            self.assertEqual("Open interactive project wizard", commands[1]["description"])

    def test_load_secret_file_defaults_parses_external_token_and_username(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            secret_path = Path(temp_dir) / "TELEGRAMTOKEN_ID.txt"
            write_text(
                secret_path,
                "API TOKEN : <1234567890:ABCDEFGHIJKLMNOPQRSTUVWX>\n\nID : <jh99_99>\n",
            )

            with mock.patch.dict(BOT.os.environ, {}, clear=True):
                BOT.load_secret_file_defaults(secret_path)
                self.assertEqual("1234567890:ABCDEFGHIJKLMNOPQRSTUVWX", BOT.os.environ["TELEGRAM_BOT_TOKEN"])
                self.assertEqual("jh99_99", BOT.os.environ["TELEGRAM_ALLOWED_USERNAMES"])
                self.assertNotIn("TELEGRAM_ALLOWED_USER_IDS", BOT.os.environ)

    def test_extract_hierarchy_log_candidates_from_run_log_reads_current_log_hint(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            hinted_log = temp_root / "managed_root" / "Project" / "log" / "hierarchy" / "hierarchy_20260306_123456_001.log"
            write_text(
                temp_root / "telegram_fpga_hierarchy.log",
                "\n".join(
                    [
                        f"[INFO] Hierarchy logs    : {hinted_log.parent}",
                        f"[INFO] Hierarchy log file: {hinted_log}",
                    ]
                )
                + "\n",
            )

            candidates = BOT.extract_hierarchy_log_candidates_from_run_log(temp_root / "telegram_fpga_hierarchy.log")
            self.assertIn(hinted_log, candidates)

    def test_extract_hierarchy_log_candidates_from_summary_marker_reads_summary_payload(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            project_root = temp_root / "managed_root" / "Project"
            hinted_log = project_root / "log" / "hierarchy" / "hierarchy_20260306_123456_001.log"
            summary_path = project_root / "output" / "history" / "hierarchy_view" / "r1" / "run_summary.json"
            write_text(hinted_log, "+-- TOP\n")
            write_text(
                summary_path,
                '{\n'
                '  "projectRoot": "' + project_root.as_posix() + '",\n'
                '  "details": {"logPath": "log/hierarchy/hierarchy_20260306_123456_001.log"}\n'
                '}\n',
            )
            write_text(
                temp_root / "telegram_fpga_hierarchy.log",
                f"[INFO] Hierarchy summary: {summary_path}\n",
            )

            candidates = BOT.extract_hierarchy_log_candidates_from_run_log(temp_root / "telegram_fpga_hierarchy.log")
            self.assertIn(hinted_log, candidates)
            self.assertNotIn(summary_path, candidates)

    def test_extract_vivado_log_candidates_from_summary_marker_reads_summary_payload(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            project_root = temp_root / "managed_root" / "Project"
            hinted_log = project_root / "tb" / "smoke" / "vivado_sim_tb_smoke.log"
            summary_path = project_root / "output" / "history" / "vivado_sim_nogui" / "r1" / "run_summary.json"
            write_text(hinted_log, "[INFO] Auto replay completed\n")
            write_text(
                summary_path,
                '{\n'
                '  "projectRoot": "' + project_root.as_posix() + '",\n'
                '  "details": {"vivadoLogPath": "tb/smoke/vivado_sim_tb_smoke.log"}\n'
                '}\n',
            )
            write_text(
                temp_root / "telegram_fpga_vivado.log",
                f"[INFO] Vivado summary: {summary_path}\n",
            )

            candidates = BOT.extract_vivado_log_candidates_from_run_log(temp_root / "telegram_fpga_vivado.log")
            self.assertIn(hinted_log, candidates)
            self.assertNotIn(summary_path, candidates)

    def test_extract_vivado_log_candidates_from_run_summary_marker_reads_summary_payload(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            project_root = temp_root / "managed_root" / "Project"
            hinted_log = project_root / "custom_logs" / "vivado_sim_tb_smoke.log"
            summary_path = project_root / "output" / "history" / "vivado_sim_nogui" / "r1" / "run_summary.json"
            write_text(hinted_log, "[INFO] Auto replay completed\n")
            write_text(
                summary_path,
                '{\n'
                '  "projectRoot": "' + project_root.as_posix() + '",\n'
                '  "details": {"vivadoLogPath": "custom_logs/vivado_sim_tb_smoke.log"}\n'
                '}\n',
            )
            write_text(
                temp_root / "telegram_fpga_vivado.log",
                f"[INFO] run_summary={summary_path.as_posix()}\n",
            )

            candidates = BOT.extract_vivado_log_candidates_from_run_log(temp_root / "telegram_fpga_vivado.log")
            self.assertIn(hinted_log, candidates)
            self.assertNotIn(summary_path, candidates)

    def test_extract_vivado_log_candidates_from_resolved_log_line(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            hinted_log = temp_root / "managed_root" / "Project" / "vivado_project" / "vivado.log"
            write_text(hinted_log, "[INFO] Auto replay run all completed.\n")
            write_text(
                temp_root / "telegram_fpga_vivado.log",
                f"[INFO] Resolved Vivado log file: {hinted_log}\n",
            )

            candidates = BOT.extract_vivado_log_candidates_from_run_log(temp_root / "telegram_fpga_vivado.log")
            self.assertIn(hinted_log, candidates)

    def test_find_recent_hierarchy_log_prefers_current_run_log(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            project_root, project_path = self.create_project_root(temp_root)
            log_root = project_path / "log" / "hierarchy"
            log_root.mkdir(parents=True, exist_ok=True)

            old_log = log_root / "hierarchy_20260305_235959_001.log"
            current_log = log_root / "hierarchy_20260306_123456_001.log"
            write_text(old_log, "old hierarchy\n")
            write_text(current_log, "+-- Top (src/top.v)\n")

            now = time.time()
            os.utime(old_log, (now - 600, now - 600))
            os.utime(current_log, (now, now))

            run_log = temp_root / "telegram_fpga_hierarchy.log"
            write_text(run_log, f"[INFO] Hierarchy log file: {current_log}\n")

            job = BOT.JobRequest(
                command_name="hierarchy",
                menu_no=2,
                project_name=project_path.name,
                script_path=REPO_ROOT / "templates" / "contexts" / "code_intel" / "adapters" / "bat" / "code_browse_hierarchy.bat",
                cwd=REPO_ROOT,
                cmd=("cmd.exe", "/c", "code_browse_hierarchy.bat", str(project_path), "--once"),
                stdin_text=None,
                artifact_paths=(project_path / "log", project_path / "output"),
                sim_vivado_close_gui=None,
            )

            found = BOT.find_recent_hierarchy_log(job, started_ts=now, run_log=run_log, require_fresh=True)
            self.assertEqual(current_log, found)

    def test_find_recent_vivado_sim_log_prefers_current_run_summary_hint(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            project_root, project_path = self.create_project_root(temp_root)
            tb_log_root = project_path / "tb" / "smoke"
            tb_log_root.mkdir(parents=True, exist_ok=True)

            old_log = tb_log_root / "vivado_sim.log"
            current_log = project_path / "custom_logs" / "vivado_sim_tb_smoke.log"
            summary_path = project_path / "output" / "history" / "vivado_sim_nogui" / "r1" / "run_summary.json"

            write_text(old_log, "old log\n")
            write_text(current_log, "[INFO] Auto replay run all completed.\n")
            write_text(
                summary_path,
                '{\n'
                '  "projectRoot": "' + project_root.as_posix() + '",\n'
                '  "details": {"vivadoLogPath": "Demo/custom_logs/vivado_sim_tb_smoke.log"}\n'
                '}\n',
            )

            now = time.time()
            os.utime(old_log, (now - 600, now - 600))
            os.utime(current_log, (now, now))

            run_log = temp_root / "telegram_fpga_vivado.log"
            write_text(run_log, f"[INFO] run_summary={summary_path.as_posix()}\n")

            job = BOT.JobRequest(
                command_name="sim_vivado",
                command_id="sim_vivado",
                menu_no=20,
                project_name=project_path.name,
                script_path=REPO_ROOT / "templates" / "contexts" / "simulation" / "adapters" / "bat" / "sim_run_vivado_nogui.bat",
                cwd=REPO_ROOT,
                cmd=("cmd.exe", "/c", "sim_run_vivado_nogui.bat", str(project_path)),
                stdin_text="1\r\n1\r\n",
                artifact_paths=(project_path / "tb", project_path / "log", project_path / "output"),
                sim_vivado_close_gui=None,
            )

            found = BOT.find_recent_vivado_sim_log(job, started_ts=now, run_log=run_log, require_fresh=True)
            self.assertEqual(current_log, found)

    def test_send_sim_vivado_result_summary_restores_parsed_case_report(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root, _ = self.create_project_root(Path(temp_dir))
            config = self.make_config(project_root)
            result = BOT.ExecutionResult(
                command_id="sim_vivado",
                status="success",
                return_code=0,
                structured_payload={
                    "vivado_log_path": str(Path(temp_dir) / "vivado_sim_tb_smoke.log"),
                    "vivado_log_excerpt": [
                        "[INFO] Auto replay: restart + run all",
                        "[TB][INFO] RUN CASE 1 / 1",
                        "[TB][INFO] Selected TESTNAME=SMOKE",
                        "[TB][INFO] ENV report: checked=128 errors=2 coverage=97.5%",
                        "[INFO] Auto replay run all completed.",
                    ],
                    "vivado_log_excerpt_marker_found": True,
                    "vivado_log_excerpt_truncated": False,
                },
            )

            with mock.patch.object(BOT, "safe_send_text") as send_text_mock:
                BOT.send_sim_vivado_result_summary(config, 1001, result)

            sent_text = send_text_mock.call_args.args[2]
            self.assertIn("[SIM_VIVADO_SUMMARY]", sent_text)
            self.assertIn("Case Results", sent_text)
            self.assertIn("SMOKE", sent_text)
            self.assertIn("97.5", sent_text)
            self.assertIn("errs=<code>2</code>", sent_text)

    def test_send_sim_vivado_result_summary_parses_env_report_without_run_case(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root, _ = self.create_project_root(Path(temp_dir))
            config = self.make_config(project_root)
            result = BOT.ExecutionResult(
                command_id="sim_vivado",
                status="success",
                return_code=0,
                structured_payload={
                    "vivado_log_path": str(Path(temp_dir) / "vivado_sim_tb_smoke.log"),
                    "vivado_log_excerpt": [
                        "[TB][INFO] Selected TESTNAME=SMOKE",
                        "[TB][INFO] ENV report: checked=64 errors=0",
                        "$finish called at time : 100 ns",
                    ],
                    "vivado_log_excerpt_marker_found": False,
                    "vivado_log_excerpt_truncated": False,
                },
            )

            with mock.patch.object(BOT, "safe_send_text") as send_text_mock:
                BOT.send_sim_vivado_result_summary(config, 1001, result)

            sent_text = send_text_mock.call_args.args[2]
            self.assertIn("Case Results", sent_text)
            self.assertIn("SMOKE", sent_text)
            self.assertIn("errs=<code>0</code>", sent_text)
            self.assertIn("cov=<code>-%</code>", sent_text)

    def test_parse_history_request_args_accepts_tool_and_limit_any_order(self) -> None:
        project_token, tool_filter, limit, error = BOT.parse_history_request_args(["Demo", "build", "7"])
        self.assertIsNone(error)
        self.assertEqual("Demo", project_token)
        self.assertEqual("build", tool_filter)
        self.assertEqual(7, limit)

        project_token, tool_filter, limit, error = BOT.parse_history_request_args(["Demo", "3", "doctor"])
        self.assertIsNone(error)
        self.assertEqual("Demo", project_token)
        self.assertEqual("doctor", tool_filter)
        self.assertEqual(3, limit)

    def test_process_message_history_renders_recent_runs(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root, project_path = self.create_project_root(Path(temp_dir))
            config = self.make_config(project_root)
            write_text(
                project_path / "output" / "history" / "toolkit_doctor" / "r2" / "doctor_summary.json",
                json.dumps(
                    {
                        "tool": "toolkit_doctor",
                        "type": "doctor_summary",
                        "status": "warning",
                        "ok": False,
                        "warnings": ["xdc_missing"],
                    }
                )
                + "\n",
            )
            write_text(
                project_path / "output" / "history" / "vivado_build" / "b1" / "build_summary.json",
                json.dumps(
                    {
                        "tool": "vivado_build",
                        "type": "build_summary",
                        "status": "ok",
                        "qualityGate": {
                            "timing": {"status": "ok", "wnsNs": 0.125},
                            "bitstream": {"status": "ok", "count": 1},
                        },
                        "details": {"topModule": "TOP"},
                    }
                )
                + "\n",
            )
            self.write_run_index(
                project_path,
                [
                    {
                        "tool": "vivado_build",
                        "status": "ok",
                        "summaryPath": "output/history/vivado_build/b1/build_summary.json",
                        "outputs": [],
                        "metadata": {"topModule": "TOP"},
                        "createdAt": "2026-03-11T01:00:00Z",
                    },
                    {
                        "tool": "toolkit_doctor",
                        "status": "warning",
                        "summaryPath": "output/history/toolkit_doctor/r2/doctor_summary.json",
                        "outputs": [],
                        "metadata": {},
                        "createdAt": "2026-03-11T02:00:00Z",
                    },
                ],
            )

            with mock.patch.object(BOT, "send_text") as send_text_mock:
                BOT.process_message(
                    config,
                    {"message_id": 1, "from": {"id": 1}, "chat": {"id": 10}, "text": "/history Demo 2"},
                )

            sent_text = send_text_mock.call_args.args[2]
            self.assertIn("[Run History]", sent_text)
            self.assertIn("Toolkit Doctor", sent_text)
            self.assertIn("Vivado Build", sent_text)
            self.assertLess(sent_text.index("Toolkit Doctor"), sent_text.index("Vivado Build"))

    def test_process_message_diff_renders_simulation_changes(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root, project_path = self.create_project_root(Path(temp_dir))
            config = self.make_config(project_root)
            write_text(
                project_path / "output" / "history" / "simulation_report" / "r1" / "run_summary.json",
                json.dumps(
                    {
                        "tool": "simulation_report",
                        "type": "run_summary",
                        "status": "ok",
                        "warnings": [],
                        "details": {
                            "topModule": "tb_TOP",
                            "passCount": 1,
                            "failCount": 0,
                            "regressionRows": [
                                {"testName": "SMOKE", "pass": True, "reason": "ok"},
                            ],
                        },
                    }
                )
                + "\n",
            )
            write_text(
                project_path / "output" / "history" / "simulation_report" / "r2" / "run_summary.json",
                json.dumps(
                    {
                        "tool": "simulation_report",
                        "type": "run_summary",
                        "status": "failed",
                        "warnings": ["scoreboard_errors"],
                        "details": {
                            "topModule": "tb_TOP",
                            "passCount": 0,
                            "failCount": 1,
                            "regressionRows": [
                                {"testName": "SMOKE", "pass": False, "reason": "scoreboard_errors"},
                            ],
                        },
                    }
                )
                + "\n",
            )
            self.write_run_index(
                project_path,
                [
                    {
                        "tool": "simulation_report",
                        "status": "ok",
                        "summaryPath": "output/history/simulation_report/r1/run_summary.json",
                        "outputs": [],
                        "metadata": {},
                        "createdAt": "2026-03-11T01:00:00Z",
                    },
                    {
                        "tool": "simulation_report",
                        "status": "failed",
                        "summaryPath": "output/history/simulation_report/r2/run_summary.json",
                        "outputs": [],
                        "metadata": {},
                        "createdAt": "2026-03-11T02:00:00Z",
                    },
                ],
            )

            with mock.patch.object(BOT, "send_text") as send_text_mock:
                BOT.process_message(
                    config,
                    {"message_id": 2, "from": {"id": 1}, "chat": {"id": 10}, "text": "/diff Demo sim"},
                )

            sent_text = send_text_mock.call_args.args[2]
            self.assertIn("[Run Diff]", sent_text)
            self.assertIn("Simulation Report", sent_text)
            self.assertIn("Fail Count", sent_text)
            self.assertIn("Failing Tests Added", sent_text)
            self.assertIn("SMOKE:scoreboard_errors", sent_text)

    def test_process_message_diff_sim_vivado_uses_same_workflow_history(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root, project_path = self.create_project_root(Path(temp_dir))
            config = self.make_config(project_root)
            write_text(
                project_path / "output" / "history" / "vivado_sim_gui" / "g1" / "run_summary.json",
                json.dumps(
                    {
                        "tool": "vivado_sim_gui",
                        "type": "run_summary",
                        "status": "ok",
                        "details": {"tbName": "tb_gui_old", "replayState": "completed"},
                    }
                )
                + "\n",
            )
            write_text(
                project_path / "output" / "history" / "vivado_sim_nogui" / "n1" / "run_summary.json",
                json.dumps(
                    {
                        "tool": "vivado_sim_nogui",
                        "type": "run_summary",
                        "status": "ok",
                        "details": {"tbName": "tb_nogui", "replayState": "completed"},
                    }
                )
                + "\n",
            )
            write_text(
                project_path / "output" / "history" / "vivado_sim_gui" / "g2" / "run_summary.json",
                json.dumps(
                    {
                        "tool": "vivado_sim_gui",
                        "type": "run_summary",
                        "status": "ok",
                        "details": {"tbName": "tb_gui_new", "replayState": "completed"},
                    }
                )
                + "\n",
            )
            self.write_run_index(
                project_path,
                [
                    {
                        "tool": "vivado_sim_gui",
                        "status": "ok",
                        "summaryPath": "output/history/vivado_sim_gui/g1/run_summary.json",
                        "outputs": [],
                        "metadata": {},
                        "createdAt": "2026-03-11T01:00:00Z",
                    },
                    {
                        "tool": "vivado_sim_nogui",
                        "status": "ok",
                        "summaryPath": "output/history/vivado_sim_nogui/n1/run_summary.json",
                        "outputs": [],
                        "metadata": {},
                        "createdAt": "2026-03-11T02:00:00Z",
                    },
                    {
                        "tool": "vivado_sim_gui",
                        "status": "ok",
                        "summaryPath": "output/history/vivado_sim_gui/g2/run_summary.json",
                        "outputs": [],
                        "metadata": {},
                        "createdAt": "2026-03-11T03:00:00Z",
                    },
                ],
            )

            with mock.patch.object(BOT, "send_text") as send_text_mock:
                BOT.process_message(
                    config,
                    {"message_id": 3, "from": {"id": 1}, "chat": {"id": 10}, "text": "/diff Demo sim_vivado"},
                )

            sent_text = send_text_mock.call_args.args[2]
            self.assertIn("[Run Diff]", sent_text)
            self.assertIn("Vivado Sim (GUI)", sent_text)
            self.assertIn("tb_gui_old", sent_text)
            self.assertIn("tb_gui_new", sent_text)
            self.assertNotIn("tb_nogui", sent_text)

    def test_process_message_history_presentation_filter_matches_report_one_source(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root, project_path = self.create_project_root(Path(temp_dir))
            config = self.make_config(project_root)
            write_text(
                project_path / "output" / "history" / "report_one_source" / "r1" / "run_summary.json",
                json.dumps(
                    {
                        "tool": "report_one_source",
                        "type": "run_summary",
                        "status": "ok",
                        "details": {"topModule": "TOP"},
                    }
                )
                + "\n",
            )
            self.write_run_index(
                project_path,
                [
                    {
                        "tool": "report_one_source",
                        "status": "ok",
                        "summaryPath": "output/history/report_one_source/r1/run_summary.json",
                        "outputs": [],
                        "metadata": {"topModule": "TOP"},
                        "createdAt": "2026-03-11T04:00:00Z",
                    },
                ],
            )

            with mock.patch.object(BOT, "send_text") as send_text_mock:
                BOT.process_message(
                    config,
                    {"message_id": 4, "from": {"id": 1}, "chat": {"id": 10}, "text": "/history Demo presentation"},
                )

            filtered_text = send_text_mock.call_args.args[2]
            self.assertIn("[Run History]", filtered_text)
            self.assertIn("Filter:</b> <code>Presentation</code>", filtered_text)
            self.assertIn("HTML Report", filtered_text)
            self.assertNotIn("No matching run history", filtered_text)

            with mock.patch.object(BOT, "send_text") as send_text_mock:
                BOT.process_message(
                    config,
                    {"message_id": 5, "from": {"id": 1}, "chat": {"id": 10}, "text": "/history Demo 5"},
                )

            unfiltered_text = send_text_mock.call_args.args[2]
            self.assertIn("HTML Report", unfiltered_text)
            self.assertNotIn("report_one_source", unfiltered_text)

    def test_parse_main_menu_registry_covers_main_menu(self) -> None:
        registry = BOT.parse_main_menu_registry(REPO_ROOT / "MAIN.bat", REPO_ROOT / "templates")
        self.assertEqual(set(range(1, 31)), set(registry))
        self.assertTrue(
            registry[5].script_path.as_posix().endswith("templates/contexts/simulation/adapters/bat/sim_run_vivado.bat")
        )
        self.assertTrue(
            registry[19]
            .script_path.as_posix()
            .endswith("templates/contexts/simulation/adapters/bat/sim_create_dut_tb_scaffold.bat")
        )
        self.assertTrue(
            registry[20]
            .script_path.as_posix()
            .endswith("templates/contexts/simulation/adapters/bat/sim_run_vivado_nogui.bat")
        )
        self.assertTrue(
            registry[21]
            .script_path.as_posix()
            .endswith("templates/shared/adapters/bat/toolkit_doctor.bat")
        )
        self.assertTrue(
            registry[28]
            .script_path.as_posix()
            .endswith("templates/contexts/vitis/adapters/bat/vitis_run_full_flow.bat")
        )
        self.assertTrue(
            registry[29]
            .script_path.as_posix()
            .endswith("templates/contexts/vivado/adapters/bat/vivado_open_ip_integrator_gui.bat")
        )
        self.assertTrue(
            registry[30]
            .script_path.as_posix()
            .endswith("templates/contexts/vivado/adapters/bat/vivado_build_ip_integrator_flow.bat")
        )

    def test_make_execution_service_returns_layered_service(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root, _ = self.create_project_root(Path(temp_dir))
            config = self.make_config(project_root)
            config.max_diagram_files = 7
            service = BOT.make_execution_service(config)
            self.assertIsInstance(service, BOT.LayeredExecutionService)
            self.assertEqual(7, service._diagram_limit)

    def test_send_execution_artifacts_sends_png_document_for_svg(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            from Telegram.bot.domain.models import ArtifactRef

            project_root, project_path = self.create_project_root(Path(temp_dir))
            config = self.make_config(project_root)
            svg_path = project_path / "output" / "Diagram" / "Simple" / "TOP.svg"
            png_path = svg_path.with_suffix(".png")
            write_text(svg_path, "<svg/>\n")
            write_text(png_path, "png\n")
            result = BOT.ExecutionResult(
                command_id="schematic",
                status="success",
                return_code=0,
                artifacts=(
                    ArtifactRef(
                        kind="diagram",
                        path=svg_path,
                        label=svg_path.name,
                    ),
                ),
            )

            with (
                mock.patch.object(BOT, "render_svg_preview", return_value=png_path),
                mock.patch.object(BOT, "safe_send_photo") as photo_mock,
                mock.patch.object(BOT, "safe_send_document") as document_mock,
            ):
                BOT.send_execution_artifacts(config, 10, result)

            self.assertEqual(
                [call.args[2] for call in photo_mock.call_args_list],
                [png_path],
            )
            self.assertEqual(
                [call.args[2] for call in document_mock.call_args_list],
                [png_path, svg_path],
            )
            self.assertEqual(
                [call.args[3] for call in document_mock.call_args_list],
                ["schematic | TOP.png", "schematic | TOP.svg"],
            )

    def test_send_execution_artifacts_dedupes_sidecar_png_after_svg_send(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            from Telegram.bot.domain.models import ArtifactRef

            project_root, project_path = self.create_project_root(Path(temp_dir))
            config = self.make_config(project_root)
            svg_path = project_path / "output" / "Diagram" / "Simple" / "TOP.svg"
            png_path = svg_path.with_suffix(".png")
            write_text(svg_path, "<svg/>\n")
            write_text(png_path, "png\n")
            result = BOT.ExecutionResult(
                command_id="schematic",
                status="success",
                return_code=0,
                artifacts=(
                    ArtifactRef(kind="diagram", path=svg_path, label=svg_path.name),
                    ArtifactRef(kind="diagram", path=png_path, label=png_path.name),
                ),
            )

            with (
                mock.patch.object(BOT, "render_svg_preview", return_value=png_path),
                mock.patch.object(BOT, "safe_send_photo") as photo_mock,
                mock.patch.object(BOT, "safe_send_document") as document_mock,
            ):
                BOT.send_execution_artifacts(config, 10, result)

            self.assertEqual(1, photo_mock.call_count)
            self.assertEqual([call.args[2] for call in document_mock.call_args_list], [png_path, svg_path])

    def test_render_svg_preview_falls_back_to_node_converter(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            svg_path = Path(temp_dir) / "TOP.svg"
            write_text(svg_path, '<svg width="2670" height="733"></svg>\n')

            def fake_node(svg_arg: Path, png_arg: Path, target_width: int) -> bool:
                self.assertEqual(svg_path, svg_arg)
                self.assertEqual(5340, target_width)
                write_text(png_arg, "png\n")
                return True

            with (
                mock.patch.object(BOT, "_render_svg_preview_with_cairosvg", return_value=False),
                mock.patch.object(BOT, "_render_svg_preview_with_node", side_effect=fake_node) as node_mock,
            ):
                preview = BOT.render_svg_preview(svg_path)

            self.assertIsNotNone(preview)
            assert preview is not None
            self.assertTrue(preview.exists())
            self.assertEqual(".png", preview.suffix.lower())
            self.assertEqual(1, node_mock.call_count)
            preview.unlink(missing_ok=True)

    def test_determine_svg_preview_width_scales_large_detailed_svg(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            svg_path = Path(temp_dir) / "TOP_detailed.svg"
            write_text(svg_path, '<svg width="2670" height="733"></svg>\n')

            self.assertEqual(5340, BOT.determine_svg_preview_width(svg_path))

    def test_render_svg_preview_ignores_low_res_sidecar_png(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            svg_path = Path(temp_dir) / "TOP_detailed.svg"
            png_path = svg_path.with_suffix(".png")
            write_text(svg_path, '<svg width="2670" height="733"></svg>\n')
            png_path.write_bytes(
                b"\x89PNG\r\n\x1a\n"
                + b"\x00\x00\x00\rIHDR"
                + (1200).to_bytes(4, "big")
                + (330).to_bytes(4, "big")
                + b"\x08\x02\x00\x00\x00"
            )

            def fake_node(svg_arg: Path, out_arg: Path, target_width: int) -> bool:
                self.assertEqual(svg_path, svg_arg)
                self.assertEqual(5340, target_width)
                write_text(out_arg, "png\n")
                return True

            with (
                mock.patch.object(BOT, "_render_svg_preview_with_cairosvg", return_value=False),
                mock.patch.object(BOT, "_render_svg_preview_with_node", side_effect=fake_node) as node_mock,
            ):
                preview = BOT.render_svg_preview(svg_path)

            self.assertIsNotNone(preview)
            assert preview is not None
            self.assertNotEqual(png_path, preview)
            self.assertEqual(1, node_mock.call_count)
            preview.unlink(missing_ok=True)

    def test_build_menu_invocation_matches_batch_contracts(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root, project_path = self.create_project_root(Path(temp_dir))
            config = self.make_config(project_root)

            cases = [
                (
                    2,
                    ["tb_only"],
                    [str(project_path), "--once", "--tb-only"],
                    None,
                    None,
                ),
                (
                    20,
                    ["1", "2"],
                    [str(project_path)],
                    "1\r\n2\r\n",
                    None,
                ),
                (
                    6,
                    ["3"],
                    [str(project_path)],
                    "3\r\n\r\n",
                    None,
                ),
                (
                    7,
                    ["--all"],
                    [str(project_path), "--all", "--no-pause"],
                    None,
                    None,
                ),
                (
                    9,
                    ["--step", "5", "--max-signals", "10", "--html"],
                    [str(project_path), "--step", "5", "--max-signals", "10", "--html", "--no-pause"],
                    None,
                    None,
                ),
                (
                    13,
                    [],
                    [str(project_path), "--no-pause"],
                    "N\r\n",
                    None,
                ),
                (
                    19,
                    ["--all"],
                    [str(project_path), "--all", "--no-pause"],
                    None,
                    None,
                ),
                (
                    21,
                    [],
                    [str(project_path)],
                    None,
                    None,
                ),
                (
                    22,
                    ["--bit", "latest"],
                    [str(project_path), "--bit", "latest"],
                    None,
                    None,
                ),
                (
                    23,
                    ["--xsa", "latest"],
                    [str(project_path), "--xsa", "latest"],
                    None,
                    None,
                ),
                (
                    24,
                    ["--platform", "Demo_platform", "--apps", "hello_world,app_2"],
                    [str(project_path), "--apps", "hello_world,app_2", "--platform", "Demo_platform"],
                    None,
                    None,
                ),
                (
                    26,
                    ["--all-apps", "--target", "hw"],
                    [str(project_path), "--all-apps", "--target", "hw"],
                    None,
                    None,
                ),
                (
                    28,
                    ["--run"],
                    [str(project_path), "--run"],
                    None,
                    None,
                ),
            ]

            for menu_no, extras, expected_tail, expected_stdin, expected_close in cases:
                with self.subTest(menu_no=menu_no):
                    request, error = BOT.build_menu_invocation(config, menu_no, project_path, extras, f"test_{menu_no}")
                    self.assertIsNone(error)
                    assert request is not None
                    self.assertEqual(("cmd.exe", "/c"), request.cmd[:2])
                    self.assertEqual(expected_tail, list(request.cmd[3:]))
                    self.assertEqual(expected_stdin, request.stdin_text)
                    self.assertEqual(expected_close, request.sim_vivado_close_gui)

    def test_parse_alias_command_doctor_maps_to_menu_21(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root, project_path = self.create_project_root(Path(temp_dir))
            config = self.make_config(project_root)

            request, error = BOT.parse_alias_command(config, "/doctor", "Demo")
            self.assertIsNone(error)
            assert request is not None
            self.assertEqual(21, request.menu_no)
            self.assertEqual("doctor", request.command_id)
            self.assertEqual([str(project_path)], list(request.cmd[3:]))
            self.assertIsNone(request.stdin_text)

    def test_parse_task_command_accepts_menu_21_and_rejects_extra_tokens(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root, project_path = self.create_project_root(Path(temp_dir))
            config = self.make_config(project_root)

            request, error = BOT.parse_task_command(config, "21 Demo")
            self.assertIsNone(error)
            assert request is not None
            self.assertEqual(21, request.menu_no)
            self.assertEqual([str(project_path)], list(request.cmd[3:]))

            request, error = BOT.parse_task_command(config, "21 Demo extra")
            self.assertIsNone(request)
            self.assertEqual("Usage: /task 21 <project>", error)

    def test_parse_task_command_accepts_vitis_menu_range(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root, project_path = self.create_project_root(Path(temp_dir))
            config = self.make_config(project_root)

            request, error = BOT.parse_task_command(config, "22 Demo")
            self.assertIsNone(error)
            assert request is not None
            self.assertEqual(22, request.menu_no)
            self.assertEqual([str(project_path)], list(request.cmd[3:]))

            request, error = BOT.parse_task_command(config, "28 Demo --run")
            self.assertIsNone(error)
            assert request is not None
            self.assertEqual(28, request.menu_no)
            self.assertEqual([str(project_path), "--run"], list(request.cmd[3:]))

    def test_build_menu_invocation_hierarchy_accepts_batch_scope_aliases(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root, project_path = self.create_project_root(Path(temp_dir))
            config = self.make_config(project_root)

            cases = [
                (["src"], [str(project_path), "--once"]),
                (["tb"], [str(project_path), "--once", "--tb-only"]),
                (["tb_only"], [str(project_path), "--once", "--tb-only"]),
                (["tb-only"], [str(project_path), "--once", "--tb-only"]),
                (["tbonly"], [str(project_path), "--once", "--tb-only"]),
            ]

            for extras, expected_tail in cases:
                with self.subTest(extras=extras):
                    request, error = BOT.build_menu_invocation(config, 2, project_path, extras, "hierarchy")
                    self.assertIsNone(error)
                    assert request is not None
                    self.assertEqual(expected_tail, list(request.cmd[3:]))

            for extras in (["include_tb"], ["include-tb"], ["--include-tb"]):
                with self.subTest(invalid_extras=extras):
                    request, error = BOT.build_menu_invocation(config, 2, project_path, extras, "hierarchy")
                    self.assertIsNone(request)
                    self.assertIsNotNone(error)

    def test_manifest_target_builders_track_tb_order_and_folder_choices(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            _, project_path = self.create_project_root(Path(temp_dir))
            write_text(project_path / "tb/auto/helper.sv", "logic helper_signal;\n")
            write_text(project_path / "tb/auto/tb_alpha.sv", "module tb_alpha; endmodule\n")
            write_text(project_path / "tb/auto/tb_beta.sv", "program automatic tb_beta; endprogram\n")
            write_text(project_path / "tb/manual/manual_only.sv", "logic fallback_only;\n")
            write_text(
                project_path / "output/manifest/manifest_tb_files.lst",
                "\n".join(
                    [
                        "tb/auto/helper.sv",
                        "tb/manual/manual_only.sv",
                        "tb/auto/tb_beta.sv",
                        "tb/auto/tb_alpha.sv",
                    ]
                )
                + "\n",
            )

            entries = BOT.read_manifest_tb_entries(project_path)
            self.assertEqual([1, 2, 3, 4], [entry["manifest_idx"] for entry in entries])

            auto_report_targets = BOT.build_auto_report_tb_targets_from_entries(entries)
            self.assertEqual(
                ["tb/auto/helper.sv", "tb/manual/manual_only.sv", "tb/auto/tb_beta.sv", "tb/auto/tb_alpha.sv"],
                [target["file_display"] for target in auto_report_targets],
            )

            vivado_targets = BOT.build_vivado_tb_targets_from_entries(entries)
            target_by_folder = {target["folder_display"]: target for target in vivado_targets}
            self.assertIn("tb/auto", target_by_folder)
            self.assertIn("tb/manual", target_by_folder)
            self.assertEqual(2, target_by_folder["tb/auto"]["tb_count"])
            self.assertEqual(
                ["tb/auto/tb_alpha.sv", "tb/auto/tb_beta.sv"],
                [item["file_display"] for item in target_by_folder["tb/auto"]["tb_targets"]],
            )
            self.assertEqual([1, 2], [item["tb_idx"] for item in target_by_folder["tb/auto"]["tb_targets"]])
            self.assertEqual(1, target_by_folder["tb/manual"]["tb_count"])
            self.assertEqual("tb/manual/manual_only.sv", target_by_folder["tb/manual"]["tb_targets"][0]["file_display"])

    def test_process_callback_query_drives_dynamic_vivado_wizard_flow(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root, _ = self.create_project_root(Path(temp_dir))
            config = self.make_config(project_root)
            BOT.STATE.update_user_state(1, {"wizard": "project", "project": "Demo", "category": "sim"})
            targets = [
                {
                    "folder_idx": 1,
                    "folder_display": "tb/auto",
                    "display_name": "auto",
                    "tb_count": 2,
                    "tb_targets": [
                        {"tb_idx": 1, "tb_stem": "tb_alpha", "tb_name": "tb_alpha.sv", "top_candidate": "tb_alpha"},
                        {"tb_idx": 2, "tb_stem": "tb_beta", "tb_name": "tb_beta.sv", "top_candidate": "tb_beta"},
                    ],
                }
            ]

            with mock.patch.object(BOT, "find_vivado_tb_targets", return_value=targets), \
                mock.patch.object(BOT, "edit_message_text") as edit_mock, \
                mock.patch.object(BOT, "answer_callback_query"):
                BOT.process_callback_query(
                    config,
                    {"id": "q1", "data": "wiz_act_20", "from": {"id": 1}, "message": {"chat": {"id": 10}, "message_id": 20}},
                )
                reply_markup = edit_mock.call_args.kwargs["reply_markup"]
                self.assertEqual("wiz_vsimf_1", reply_markup["inline_keyboard"][0][0]["callback_data"])

            with mock.patch.object(BOT, "edit_message_text") as edit_mock, \
                mock.patch.object(BOT, "answer_callback_query"):
                BOT.process_callback_query(
                    config,
                    {"id": "q2", "data": "wiz_vsimf_1", "from": {"id": 1}, "message": {"chat": {"id": 10}, "message_id": 20}},
                )
                reply_markup = edit_mock.call_args.kwargs["reply_markup"]
                self.assertEqual("wiz_vsimt_1_2", reply_markup["inline_keyboard"][0][1]["callback_data"])

            with mock.patch.object(BOT, "process_message") as process_mock, \
                mock.patch.object(BOT, "edit_message_text"), \
                mock.patch.object(BOT, "answer_callback_query"):
                BOT.process_callback_query(
                    config,
                    {"id": "q3", "data": "wiz_vsimt_1_2", "from": {"id": 1}, "message": {"chat": {"id": 10}, "message_id": 20}},
                )
                self.assertEqual("/sim_vivado Demo 1 2", process_mock.call_args.args[1]["text"])

    def test_process_callback_query_drives_dynamic_auto_report_flow(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root, _ = self.create_project_root(Path(temp_dir))
            config = self.make_config(project_root)
            BOT.STATE.update_user_state(1, {"wizard": "project", "project": "Demo", "category": "sim"})
            targets = [
                {"tb_idx": 1, "tb_name": "tb_alpha.sv", "tb_stem": "tb_alpha", "top_candidate": "tb_alpha"},
                {"tb_idx": 2, "tb_name": "tb_beta.sv", "tb_stem": "tb_beta", "top_candidate": "tb_beta"},
            ]

            with mock.patch.object(BOT, "find_auto_report_tb_targets", return_value=targets), \
                mock.patch.object(BOT, "edit_message_text") as edit_mock, \
                mock.patch.object(BOT, "answer_callback_query"):
                BOT.process_callback_query(
                    config,
                    {"id": "q5", "data": "wiz_act_6", "from": {"id": 1}, "message": {"chat": {"id": 10}, "message_id": 20}},
                )
                reply_markup = edit_mock.call_args.kwargs["reply_markup"]
                self.assertEqual("wiz_sar_2", reply_markup["inline_keyboard"][0][1]["callback_data"])

            with mock.patch.object(BOT, "process_message") as process_mock, \
                mock.patch.object(BOT, "edit_message_text"), \
                mock.patch.object(BOT, "answer_callback_query"):
                BOT.process_callback_query(
                    config,
                    {"id": "q6", "data": "wiz_sar_2", "from": {"id": 1}, "message": {"chat": {"id": 10}, "message_id": 20}},
                )
                self.assertEqual("/sim_auto_report Demo 2", process_mock.call_args.args[1]["text"])

    def test_process_callback_query_project_selection_exposes_health_category(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root, _ = self.create_project_root(Path(temp_dir))
            config = self.make_config(project_root)
            BOT.STATE.update_user_state(1, {"wizard": "project", "step": "project"})

            with mock.patch.object(BOT, "edit_message_text") as edit_mock, \
                mock.patch.object(BOT, "answer_callback_query"):
                BOT.process_callback_query(
                    config,
                    {"id": "q6a", "data": "wiz_proj_Demo", "from": {"id": 1}, "message": {"chat": {"id": 10}, "message_id": 20}},
                )
                keyboard = edit_mock.call_args.kwargs["reply_markup"]["inline_keyboard"]
                self.assertEqual("wiz_cat_health", keyboard[2][0]["callback_data"])

    def test_process_callback_query_health_wizard_runs_doctor(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root, _ = self.create_project_root(Path(temp_dir))
            config = self.make_config(project_root)
            BOT.STATE.update_user_state(1, {"wizard": "project", "project": "Demo", "category": "health"})

            with mock.patch.object(BOT, "edit_message_text") as edit_mock, \
                mock.patch.object(BOT, "answer_callback_query"):
                BOT.process_callback_query(
                    config,
                    {"id": "q6b", "data": "wiz_cat_health", "from": {"id": 1}, "message": {"chat": {"id": 10}, "message_id": 20}},
                )
                keyboard = edit_mock.call_args.kwargs["reply_markup"]["inline_keyboard"]
                self.assertEqual("wiz_act_21", keyboard[0][0]["callback_data"])
                self.assertEqual("wiz_act_hist", keyboard[1][0]["callback_data"])
                self.assertEqual("wiz_act_diff", keyboard[1][1]["callback_data"])

            with mock.patch.object(BOT, "process_message") as process_mock, \
                mock.patch.object(BOT, "edit_message_text"), \
                mock.patch.object(BOT, "answer_callback_query"):
                BOT.process_callback_query(
                    config,
                    {"id": "q6c", "data": "wiz_act_21", "from": {"id": 1}, "message": {"chat": {"id": 10}, "message_id": 20}},
                )
                self.assertEqual("/doctor Demo", process_mock.call_args.args[1]["text"])

    def test_process_callback_query_health_wizard_runs_history_and_diff(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root, _ = self.create_project_root(Path(temp_dir))
            config = self.make_config(project_root)

            BOT.STATE.update_user_state(1, {"wizard": "project", "project": "Demo", "category": "health"})
            with mock.patch.object(BOT, "process_message") as process_mock, \
                mock.patch.object(BOT, "edit_message_text"), \
                mock.patch.object(BOT, "answer_callback_query"):
                BOT.process_callback_query(
                    config,
                    {"id": "q6d", "data": "wiz_act_hist", "from": {"id": 1}, "message": {"chat": {"id": 10}, "message_id": 20}},
                )
                self.assertEqual("/history Demo", process_mock.call_args.args[1]["text"])

            BOT.STATE.update_user_state(1, {"wizard": "project", "project": "Demo", "category": "health"})
            with mock.patch.object(BOT, "process_message") as process_mock, \
                mock.patch.object(BOT, "edit_message_text"), \
                mock.patch.object(BOT, "answer_callback_query"):
                BOT.process_callback_query(
                    config,
                    {"id": "q6e", "data": "wiz_act_diff", "from": {"id": 1}, "message": {"chat": {"id": 10}, "message_id": 20}},
                )
                self.assertEqual("/diff Demo", process_mock.call_args.args[1]["text"])

    def test_process_callback_query_hierarchy_wizard_matches_batch_scopes(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root, _ = self.create_project_root(Path(temp_dir))
            config = self.make_config(project_root)
            BOT.STATE.update_user_state(1, {"wizard": "project", "project": "Demo", "category": "vis"})

            with mock.patch.object(BOT, "edit_message_text") as edit_mock, \
                mock.patch.object(BOT, "answer_callback_query"):
                BOT.process_callback_query(
                    config,
                    {"id": "q7", "data": "wiz_act_2", "from": {"id": 1}, "message": {"chat": {"id": 10}, "message_id": 20}},
                )
                keyboard = edit_mock.call_args.kwargs["reply_markup"]["inline_keyboard"]
                self.assertEqual("wiz_hier_src", keyboard[0][0]["callback_data"])
                self.assertEqual("wiz_hier_tb", keyboard[0][1]["callback_data"])

            targets = [
                {
                    "folder_idx": 1,
                    "folder_display": "tb/Counter_tb",
                    "display_name": "Counter_tb",
                    "tb_count": 1,
                    "tb_targets": [{"tb_idx": 1, "tb_stem": "tb_counter", "tb_name": "tb_counter.sv"}],
                }
            ]

            with mock.patch.object(BOT, "find_vivado_tb_targets", return_value=targets), \
                mock.patch.object(BOT, "edit_message_text") as edit_mock, \
                mock.patch.object(BOT, "answer_callback_query"):
                BOT.process_callback_query(
                    config,
                    {"id": "q8", "data": "wiz_hier_tb", "from": {"id": 1}, "message": {"chat": {"id": 10}, "message_id": 20}},
                )
                text = edit_mock.call_args.args[3]
                reply_markup = edit_mock.call_args.kwargs["reply_markup"]["inline_keyboard"]
                self.assertIn("[TB Folders]", text)
                self.assertIn("tb/Counter_tb", text)
                self.assertEqual("hier_tbf_1_Demo", reply_markup[1][0]["callback_data"])

    def test_process_callback_query_hierarchy_tb_scope_opens_folder_picker(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root, _ = self.create_project_root(Path(temp_dir))
            config = self.make_config(project_root)
            targets = [
                {
                    "folder_idx": 1,
                    "folder_display": "tb/BcdCounter_tb",
                    "display_name": "BcdCounter_tb",
                    "tb_count": 1,
                    "tb_targets": [{"tb_idx": 1, "tb_stem": "tb_bcd_counter", "tb_name": "tb_bcd_counter.sv"}],
                },
                {
                    "folder_idx": 2,
                    "folder_display": "tb/WatchFsm_tb",
                    "display_name": "WatchFsm_tb",
                    "tb_count": 1,
                    "tb_targets": [{"tb_idx": 1, "tb_stem": "tb_watch_fsm", "tb_name": "tb_watch_fsm.sv"}],
                },
            ]

            with mock.patch.object(BOT, "find_vivado_tb_targets", return_value=targets), \
                mock.patch.object(BOT, "edit_message_text") as edit_mock, \
                mock.patch.object(BOT, "answer_callback_query"):
                BOT.process_callback_query(
                    config,
                    {"id": "q8b", "data": "hier_tb_Demo", "from": {"id": 1}, "message": {"chat": {"id": 10}, "message_id": 20}},
                )

                text = edit_mock.call_args.args[3]
                reply_markup = edit_mock.call_args.kwargs["reply_markup"]["inline_keyboard"]
                self.assertIn("[TB Folders]", text)
                self.assertIn("tb/BcdCounter_tb", text)
                self.assertIn("tb/WatchFsm_tb", text)
                self.assertEqual("hier_tbf_1_Demo", reply_markup[1][0]["callback_data"])
                self.assertEqual("hier_tbf_2_Demo", reply_markup[2][0]["callback_data"])

    def test_process_callback_query_hierarchy_tb_folder_opens_detail_view(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root, project_path = self.create_project_root(Path(temp_dir))
            config = self.make_config(project_root)
            write_text(project_path / "src/counter.sv", "module counter(input logic clk); endmodule\n")
            write_text(
                project_path / "tb/Counter_tb/tb_counter.sv",
                "module tb_counter;\n  counter dut(.clk(clk));\nendmodule\n",
            )
            write_text(
                project_path / "output/manifest/manifest_tb_files.lst",
                "tb/Counter_tb/tb_counter.sv\n",
            )

            with mock.patch.object(BOT, "edit_message_text") as edit_mock, \
                mock.patch.object(BOT, "answer_callback_query"):
                BOT.process_callback_query(
                    config,
                    {"id": "q9", "data": "hier_tbf_1_Demo", "from": {"id": 1}, "message": {"chat": {"id": 10}, "message_id": 20}},
                )

                text = edit_mock.call_args.args[3]
                reply_markup = edit_mock.call_args.kwargs["reply_markup"]["inline_keyboard"]
                self.assertIn("[TB Folder] tb/Counter_tb", text)
                self.assertIn("tb_counter", text)
                self.assertIn("counter", text)
                self.assertEqual("hier_tb_Demo", reply_markup[1][0]["callback_data"])
                self.assertEqual("hier_tbf_1_Demo", reply_markup[1][1]["callback_data"])

    def test_process_message_hierarchy_tb_sends_folder_picker(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root, _ = self.create_project_root(Path(temp_dir))
            config = self.make_config(project_root)
            targets = [
                {
                    "folder_idx": 1,
                    "folder_display": "tb/StopwatchCore_tb",
                    "display_name": "StopwatchCore_tb",
                    "tb_count": 1,
                    "tb_targets": [{"tb_idx": 1, "tb_stem": "tb_stopwatch_core", "tb_name": "tb_stopwatch_core.sv"}],
                }
            ]

            with mock.patch.object(BOT, "find_vivado_tb_targets", return_value=targets), \
                mock.patch.object(BOT, "send_text") as send_mock, \
                mock.patch.object(BOT, "launch_job_async") as launch_mock:
                BOT.process_message(
                    config,
                    {"message_id": 20, "from": {"id": 1}, "chat": {"id": 10}, "text": "/hierarchy Demo tb_only"},
                )

                launch_mock.assert_not_called()
                self.assertIn("[TB Folders]", send_mock.call_args.args[2])
                self.assertEqual(
                    "hier_tbf_1_Demo",
                    send_mock.call_args.kwargs["reply_markup"]["inline_keyboard"][1][0]["callback_data"],
                )


if __name__ == "__main__":
    unittest.main()
