import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


class VivadoIpIntegratorTemplateTests(unittest.TestCase):
    def test_main_menu_exposes_ip_integrator_entries(self) -> None:
        main_text = (REPO_ROOT / "MAIN.bat").read_text(encoding="utf-8")

        self.assertIn("CMD_29=contexts\\vivado\\adapters\\bat\\vivado_open_ip_integrator_gui.bat", main_text)
        self.assertIn("CMD_30=contexts\\vivado\\adapters\\bat\\vivado_build_ip_integrator_flow.bat", main_text)
        self.assertIn("29  Open IP Integrator GUI", main_text)
        self.assertIn("30  Build IP Integrator Bitstream", main_text)

    def test_gui_tcl_uses_output_vivado_ipi_project_location(self) -> None:
        script_text = (
            REPO_ROOT
            / "templates"
            / "contexts"
            / "vivado"
            / "adapters"
            / "tcl"
            / "vivado_open_ip_integrator_gui.tcl"
        ).read_text(encoding="utf-8")

        self.assertIn('set project_name "${base_project_name}_ipi"', script_text)
        self.assertIn('set output_dir "output"', script_text)
        self.assertIn('[file join $output_root "vivado" $project_name]', script_text)
        self.assertIn('set xpr_path [file join $proj_path "${project_name}.xpr"]', script_text)
        self.assertIn("Edit the BD manually, then save from Vivado.", script_text)
        self.assertNotIn("save_bd_design", script_text)
        self.assertNotIn("save_project", script_text)

    def test_gui_batch_passes_vivado_options_before_tclargs(self) -> None:
        script_text = (
            REPO_ROOT
            / "templates"
            / "contexts"
            / "vivado"
            / "adapters"
            / "bat"
            / "vivado_open_ip_integrator_gui.bat"
        ).read_text(encoding="utf-8")

        self.assertIn('-notrace -log "%GUI_LOG%" -journal "%GUI_JOU%" -tclargs', script_text)
        self.assertNotIn('"%BUILD_PROJECT_NAME%" -notrace -log', script_text)

    def test_build_tcl_runs_project_mode_bd_to_bitstream_without_xsa_export(self) -> None:
        script_text = (
            REPO_ROOT
            / "templates"
            / "contexts"
            / "vivado"
            / "adapters"
            / "tcl"
            / "vivado_build_ip_integrator_flow.tcl"
        ).read_text(encoding="utf-8")

        self.assertIn("open_project $xpr_path", script_text)
        self.assertIn("open_bd_design $bd_file", script_text)
        self.assertIn("validate_bd_design", script_text)
        self.assertIn("save_bd_design", script_text)
        self.assertIn("generate_target all", script_text)
        self.assertIn("make_wrapper -files $bd_obj -top", script_text)
        self.assertIn("set_property top $wrapper_top $source_fs", script_text)
        self.assertIn("launch_runs synth_1", script_text)
        self.assertIn("launch_runs impl_1 -to_step write_bitstream", script_text)
        self.assertNotIn("save_project", script_text)
        self.assertNotIn("write_hw_platform", script_text)


if __name__ == "__main__":
    unittest.main()
