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
        self.assertNotIn('set "BUILD_TOP_MODULE=TOP"', script_text)
        self.assertNotIn("Overriding GUI top module to TOP", script_text)
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

    def test_ip_integrator_gui_tcl_creates_or_opens_bd_from_manifest_sources(self) -> None:
        script_path = (
            REPO_ROOT
            / "templates"
            / "contexts"
            / "vivado"
            / "adapters"
            / "tcl"
            / "vivado_open_ip_integrator_gui.tcl"
        )
        script_text = script_path.read_text(encoding="utf-8")

        self.assertIn('"output" "vivado" $project_name', script_text)
        self.assertIn('set project_name "${base_project_name}_ipi"', script_text)
        self.assertIn("create_bd_design $bd_name", script_text)
        self.assertIn("open_bd_design $bd_file", script_text)
        self.assertIn("add_missing_files sources_1", script_text)
        self.assertIn("add_missing_files constrs_1", script_text)
        self.assertIn("set_property top $top_module $source_fs", script_text)
        self.assertIn("Edit the BD manually, then save from Vivado.", script_text)
        self.assertNotIn("save_bd_design", script_text)
        self.assertNotIn("save_project", script_text)
        self.assertNotIn("apply_bd_automation", script_text)
        self.assertNotIn("connect_bd", script_text)


if __name__ == "__main__":
    unittest.main()
