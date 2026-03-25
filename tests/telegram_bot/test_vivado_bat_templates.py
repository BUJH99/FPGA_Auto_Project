import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]

VIVADO_BATCH_SCRIPTS = (
    "templates/contexts/simulation/adapters/bat/sim_run_vivado.bat",
    "templates/contexts/simulation/adapters/bat/sim_run_vivado_nogui.bat",
    "templates/contexts/vivado/adapters/bat/vivado_run_build_flow.bat",
    "templates/contexts/vivado/adapters/bat/vivado_open_project_gui.bat",
    "templates/contexts/vivado/adapters/bat/vivado_program_fpga.bat",
    "templates/contexts/vivado/adapters/bat/vivado_retarget_ip_part.bat",
    "templates/contexts/vivado/adapters/bat/vivado_finalize_block_design.bat",
    "templates/contexts/reporting/adapters/bat/report_generate_legacy_html.bat",
)


class VivadoBatchTemplateTests(unittest.TestCase):
    def test_vivado_entrypoints_use_shared_vivado_helper(self) -> None:
        for rel_path in VIVADO_BATCH_SCRIPTS:
            script_path = REPO_ROOT / rel_path
            script_text = script_path.read_text(encoding="utf-8")
            with self.subTest(script=rel_path):
                self.assertIn("ensure_vivado_on_path.bat", script_text)
                self.assertIn('call "%VIVADO_ENV_HELPER%" --quiet >nul 2>nul', script_text)

    def test_setup_toolkit_references_new_amd_vivado_path(self) -> None:
        script_path = (
            REPO_ROOT
            / "templates"
            / "contexts"
            / "project_bootstrap"
            / "adapters"
            / "bat"
            / "toolkit_setup_dependencies.bat"
        )
        script_text = script_path.read_text(encoding="utf-8")

        self.assertIn('AMDDesignTools\\\\2025.2\\\\Vivado\\\\bin', script_text)
        self.assertNotIn('C:\\Xilinx\\Vivado\\2024.1\\bin', script_text)


if __name__ == "__main__":
    unittest.main()
