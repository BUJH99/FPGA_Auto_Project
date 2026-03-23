import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


class VivadoOpenProjectGuiTemplateTests(unittest.TestCase):
    def test_gui_bat_prepares_launch_plan_and_passes_top_args(self) -> None:
        script_path = (
            REPO_ROOT
            / "templates"
            / "contexts"
            / "vivado"
            / "adapters"
            / "bat"
            / "vivado_open_project_gui.bat"
        )
        script_text = script_path.read_text(encoding="utf-8")

        self.assertIn("--stage prepare", script_text)
        self.assertIn('--inc-list "%MANIFEST_INC_LIST%"', script_text)
        self.assertIn('set "BUILD_TOP_MODULE=TOP"', script_text)
        self.assertIn(
            '"%MANIFEST_INC_LIST%" "%BUILD_TOP_MODULE%" "%BUILD_PART_NUMBER%" "%BUILD_PROJECT_NAME%"',
            script_text,
        )
        self.assertNotIn("call :prompt_run_or_cancel", script_text)

    def test_gui_tcl_sets_sources_top_and_treats_tb_as_optional(self) -> None:
        script_path = (
            REPO_ROOT
            / "templates"
            / "contexts"
            / "vivado"
            / "adapters"
            / "tcl"
            / "vivado_open_project_gui.tcl"
        )
        script_text = script_path.read_text(encoding="utf-8")

        self.assertIn('set top_module "TOP"', script_text)
        self.assertIn("apply_include_dirs sources_1 $inc_dirs", script_text)
        self.assertIn("set_property top $top_module $source_fs", script_text)
        self.assertIn("current_fileset -srcset $source_fs", script_text)
        self.assertIn("No manifest testbench files resolved. Skipping sim_1 update.", script_text)


if __name__ == "__main__":
    unittest.main()
