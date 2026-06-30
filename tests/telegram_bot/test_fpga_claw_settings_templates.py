import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


class FpgaClawSettingsTemplateTests(unittest.TestCase):
    def test_main_menu_exposes_settings_without_breaking_registry(self) -> None:
        main_text = (REPO_ROOT / "MAIN.bat").read_text(encoding="utf-8")

        self.assertIn("[G]%Reset% Settings", main_text)
        self.assertIn("goto :SETTINGS_MENU", main_text)
        self.assertIn("fpga_claw_settings.bat", main_text)

        menu_numbers = {
            int(match.group(1))
            for match in re.finditer(r'^\s*set\s+"CMD_(\d+)=', main_text, flags=re.MULTILINE)
        }
        self.assertEqual(set(range(1, 32)), menu_numbers)

    def test_settings_context_and_shared_loader_exist(self) -> None:
        cli_text = (
            REPO_ROOT
            / "templates"
            / "contexts"
            / "settings"
            / "adapters"
            / "cli"
            / "fpga_claw_settings_cli.js"
        ).read_text(encoding="utf-8")
        loader_text = (
            REPO_ROOT / "templates" / "shared" / "adapters" / "bat" / "load_fpga_claw_settings.bat"
        ).read_text(encoding="utf-8")

        self.assertIn("fpga_claw.local.yml", cli_text)
        self.assertIn("project_root: \"../Project\"", cli_text)
        self.assertIn("token_source: \"env:TELEGRAM_BOT_TOKEN\"", cli_text)
        self.assertIn("[←→] section  [↑↓] field", cli_text)
        self.assertIn("--emit-bat", loader_text)

    def test_vivado_entrypoints_read_settings_output_and_vivado_path(self) -> None:
        scripts = (
            "templates/contexts/vivado/adapters/bat/vivado_run_build_flow.bat",
            "templates/contexts/vivado/adapters/bat/vivado_program_fpga.bat",
            "templates/contexts/vivado/adapters/bat/vivado_open_project_gui.bat",
            "templates/contexts/vivado/adapters/bat/vivado_open_ip_integrator_gui.bat",
            "templates/contexts/vivado/adapters/bat/vivado_build_ip_integrator_flow.bat",
        )
        for rel_path in scripts:
            script_text = (REPO_ROOT / rel_path).read_text(encoding="utf-8")
            with self.subTest(script=rel_path):
                self.assertIn("load_fpga_claw_settings.bat", script_text)
                self.assertIn("%FPGA_CLAW_OUTPUT_DIR%", script_text)
                self.assertIn("ensure_vivado_on_path.bat", script_text)

    def test_telegram_launcher_and_bot_read_settings_scope(self) -> None:
        launcher_text = (REPO_ROOT / "Telegram" / "telegram_fpga_bot_run.bat").read_text(encoding="utf-8")
        bot_text = (REPO_ROOT / "Telegram" / "telegram_fpga_bot.py").read_text(encoding="utf-8")

        self.assertIn("TELEGRAM_FPGA_CLAW_ENABLED", launcher_text)
        self.assertIn("load_fpga_claw_settings.bat", launcher_text)
        self.assertIn("TELEGRAM_ALLOWED_COMMAND_GROUPS", bot_text)
        self.assertIn("TELEGRAM_NOTIFY_EVENTS", bot_text)
        self.assertIn("notification_event_for_result", bot_text)


if __name__ == "__main__":
    unittest.main()
