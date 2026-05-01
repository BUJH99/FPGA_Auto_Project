import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]

VITIS_BAT_SCRIPTS = (
    "templates/contexts/vitis/adapters/bat/vitis_export_xsa.bat",
    "templates/contexts/vitis/adapters/bat/vitis_create_platform.bat",
    "templates/contexts/vitis/adapters/bat/vitis_create_application.bat",
    "templates/contexts/vitis/adapters/bat/vitis_build_platform.bat",
    "templates/contexts/vitis/adapters/bat/vitis_build_application.bat",
    "templates/contexts/vitis/adapters/bat/vitis_run_application.bat",
    "templates/contexts/vitis/adapters/bat/vitis_run_full_flow.bat",
)


class VitisBatchTemplateTests(unittest.TestCase):
    def test_vitis_entrypoints_bootstrap_manifest_plan_and_summary(self) -> None:
        for rel_path in VITIS_BAT_SCRIPTS:
            script_text = (REPO_ROOT / rel_path).read_text(encoding="utf-8")
            with self.subTest(script=rel_path):
                self.assertIn("bootstrap_manifest_context.bat", script_text)
                self.assertIn("vitis_plan_cli.js", script_text)
                self.assertIn("vitis_summary_cli.js", script_text)

    def test_xsa_export_uses_vivado_helper_and_vitis_steps_use_vitis_helper(self) -> None:
        export_text = (REPO_ROOT / VITIS_BAT_SCRIPTS[0]).read_text(encoding="utf-8")
        export_tcl = (REPO_ROOT / "templates/contexts/vitis/adapters/tcl/vivado_export_xsa.tcl").read_text(encoding="utf-8")
        self.assertIn("ensure_vivado_on_path.bat", export_text)
        self.assertIn("vivado_export_xsa.tcl", export_text)
        self.assertIn("vivado_validate_xsa.tcl", export_text)
        self.assertIn("--bit", export_text)
        self.assertIn("Open IP Integrator GUI from Current Sources", export_text)
        self.assertIn("Build IP Integrator Project + Bitstream", export_text)
        self.assertIn("-log \"%TARGET_PROJECT%\\log\\vitis\\export_xsa_validate.log\" -journal", export_text)
        self.assertLess(export_text.index("-log \"%TARGET_PROJECT%\\log\\vitis\\export_xsa_validate.log\""), export_text.index("-tclargs \"%VITIS_XSA_PATH%\""))
        self.assertIn("open_run", export_tcl)
        self.assertNotIn("synth_design", export_tcl)
        self.assertNotIn("write_bitstream", export_tcl)
        self.assertNotIn("launch_runs", export_tcl)

        for rel_path in VITIS_BAT_SCRIPTS[1:6]:
            script_text = (REPO_ROOT / rel_path).read_text(encoding="utf-8")
            with self.subTest(script=rel_path):
                self.assertIn("ensure_vitis_on_path.bat", script_text)
                self.assertIn("vitis -s", script_text)

    def test_shared_vitis_path_helper_probes_amd_design_tools(self) -> None:
        script_text = (REPO_ROOT / "templates/shared/adapters/bat/ensure_vitis_on_path.bat").read_text(encoding="utf-8")
        self.assertIn("AMDDesignTools", script_text)
        self.assertIn("Vitis\\bin", script_text)
        self.assertIn("where vitis", script_text)
        self.assertIn('set "PATH=%PATH%"', script_text)
        self.assertIn("chcp 65001", script_text)

    def test_vitis_entrypoints_expose_multi_artifact_selection(self) -> None:
        create_platform = (REPO_ROOT / VITIS_BAT_SCRIPTS[1]).read_text(encoding="utf-8")
        export_xsa = (REPO_ROOT / VITIS_BAT_SCRIPTS[0]).read_text(encoding="utf-8")
        create_application = (REPO_ROOT / VITIS_BAT_SCRIPTS[2]).read_text(encoding="utf-8")
        build_platform = (REPO_ROOT / VITIS_BAT_SCRIPTS[3]).read_text(encoding="utf-8")
        build_application = (REPO_ROOT / VITIS_BAT_SCRIPTS[4]).read_text(encoding="utf-8")
        full_flow = (REPO_ROOT / VITIS_BAT_SCRIPTS[6]).read_text(encoding="utf-8")

        self.assertIn("vitis_select_helper.bat", export_xsa)
        self.assertIn("--bit", export_xsa)
        self.assertIn("vitis_select_helper.bat", create_platform)
        self.assertIn("--xsa", create_platform)
        self.assertIn("--platform", create_application)
        self.assertIn("New application component name", create_application)
        self.assertIn("--app", create_application)
        self.assertIn("vitis_manifest_sync_cli.js", create_application)
        self.assertNotIn("vitis_select_helper.bat\" apps", create_application)
        create_application_py = (REPO_ROOT / "templates/contexts/vitis/adapters/python/vitis_create_application.py").read_text(encoding="utf-8")
        self.assertIn("ensure_platform_xpfm", create_application_py)
        self.assertIn("ensure_platform_domain", create_application_py)
        self.assertIn("platform_xpfm_missing_auto_build", create_application_py)
        create_platform_py = (REPO_ROOT / "templates/contexts/vitis/adapters/python/vitis_create_platform.py").read_text(encoding="utf-8")
        self.assertIn("ensure_platform_domain", create_platform_py)
        build_platform_py = (REPO_ROOT / "templates/contexts/vitis/adapters/python/vitis_build_platform.py").read_text(encoding="utf-8")
        self.assertIn("ensure_platform_domain", build_platform_py)
        common_py = (REPO_ROOT / "templates/contexts/vitis/adapters/python/vitis_common.py").read_text(encoding="utf-8")
        self.assertIn("maybe_subst_windows_workspace", common_py)
        self.assertIn('getattr(vitis, "dispose"', common_py)
        self.assertIn("--platform", build_platform)
        self.assertIn("--all-apps", build_application)
        self.assertIn("--all-apps", full_flow)

        selector = (REPO_ROOT / "templates/contexts/vitis/adapters/bat/vitis_select_helper.bat").read_text(encoding="utf-8")
        self.assertIn("--list bits", selector)
        self.assertIn("--list xsas", selector)
        self.assertIn("--list platforms", selector)
        self.assertIn("call :PRINT_CHOICES", selector)
        self.assertIn("!ITEM_LABEL_%%I!", selector)
        self.assertNotIn("call echo   [%%I] %%ITEM_LABEL_%%I%%", selector)
        self.assertIn("B=back", selector)
        self.assertIn("Returning to Vitis menu", selector)
        self.assertIn("exit /b 99", selector)


if __name__ == "__main__":
    unittest.main()
