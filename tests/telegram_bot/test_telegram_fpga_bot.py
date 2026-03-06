import importlib.util
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
        project_root = base_dir / "Project"
        project_path = project_root / "Demo"
        (project_path / "src").mkdir(parents=True, exist_ok=True)
        write_text(project_path / "fpga_auto.yml", "name: Demo\n")
        return project_root, project_path

    def test_get_secret_file_candidates_prefers_git_adjacent_mobile_agent_token(self) -> None:
        with mock.patch.dict(BOT.os.environ, {}, clear=True):
            candidates = BOT.get_secret_file_candidates()
        self.assertEqual(
            [REPO_ROOT.parent / "MOBILE_AGENT_TOKEN" / "TELEGRAMTOKEN_ID.txt"],
            candidates,
        )

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
            hinted_log = temp_root / "Project" / "log" / "hierarchy" / "hierarchy_20260306_123456_001.log"
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

    def test_parse_main_menu_registry_covers_main_menu(self) -> None:
        registry = BOT.parse_main_menu_registry(REPO_ROOT / "MAIN.bat", REPO_ROOT / "templates")
        self.assertEqual(set(range(1, 20)), set(registry))
        self.assertTrue(
            registry[5].script_path.as_posix().endswith("templates/contexts/simulation/adapters/bat/sim_run_vivado.bat")
        )
        self.assertTrue(
            registry[19]
            .script_path.as_posix()
            .endswith("templates/contexts/simulation/adapters/bat/sim_create_dut_tb_scaffold.bat")
        )

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
                    5,
                    ["1", "2", "--keep-gui"],
                    [str(project_path)],
                    "1\r\n2\r\n",
                    False,
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
                    {"id": "q1", "data": "wiz_act_5", "from": {"id": 1}, "message": {"chat": {"id": 10}, "message_id": 20}},
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

            with mock.patch.object(BOT, "edit_message_text") as edit_mock, \
                mock.patch.object(BOT, "answer_callback_query"):
                BOT.process_callback_query(
                    config,
                    {"id": "q3", "data": "wiz_vsimt_1_2", "from": {"id": 1}, "message": {"chat": {"id": 10}, "message_id": 20}},
                )
                reply_markup = edit_mock.call_args.kwargs["reply_markup"]
                self.assertEqual("wiz_gui_keep", reply_markup["inline_keyboard"][0][0]["callback_data"])

            with mock.patch.object(BOT, "process_message") as process_mock, \
                mock.patch.object(BOT, "edit_message_text"), \
                mock.patch.object(BOT, "answer_callback_query"):
                BOT.process_callback_query(
                    config,
                    {"id": "q4", "data": "wiz_gui_keep", "from": {"id": 1}, "message": {"chat": {"id": 10}, "message_id": 20}},
                )
                self.assertEqual("/sim_vivado Demo 1 2 --keep-gui", process_mock.call_args.args[1]["text"])

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
