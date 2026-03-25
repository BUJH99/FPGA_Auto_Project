import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


class VivadoPathResolutionTemplateTests(unittest.TestCase):
    def test_shared_resolver_scans_amd_design_tools_layout(self) -> None:
        resolver_path = (
            REPO_ROOT
            / "templates"
            / "shared"
            / "adapters"
            / "bat"
            / "resolve_vivado.bat"
        )
        script_text = resolver_path.read_text(encoding="utf-8")

        self.assertIn('call :scan_vendor_root "C:\\AMDDesignTools"', script_text)
        self.assertIn('if exist "!CANDIDATE!\\Vivado\\bin\\vivado.bat"', script_text)

    def test_vivado_entrypoints_use_shared_resolver(self) -> None:
        script_paths = [
            REPO_ROOT / "templates" / "contexts" / "simulation" / "adapters" / "bat" / "sim_run_vivado.bat",
            REPO_ROOT / "templates" / "contexts" / "simulation" / "adapters" / "bat" / "sim_run_vivado_nogui.bat",
            REPO_ROOT / "templates" / "contexts" / "vivado" / "adapters" / "bat" / "vivado_run_build_flow.bat",
            REPO_ROOT / "templates" / "contexts" / "vivado" / "adapters" / "bat" / "vivado_open_project_gui.bat",
            REPO_ROOT / "templates" / "contexts" / "vivado" / "adapters" / "bat" / "vivado_program_fpga.bat",
            REPO_ROOT / "templates" / "contexts" / "vivado" / "adapters" / "bat" / "vivado_finalize_block_design.bat",
            REPO_ROOT / "templates" / "contexts" / "vivado" / "adapters" / "bat" / "vivado_retarget_ip_part.bat",
        ]

        for script_path in script_paths:
            with self.subTest(script=script_path.name):
                script_text = script_path.read_text(encoding="utf-8")
                self.assertIn('set "VIVADO_RESOLVER=%TEMPLATES_ROOT%\\shared\\adapters\\bat\\resolve_vivado.bat"', script_text)
                self.assertIn('call "%VIVADO_RESOLVER%" --quiet', script_text)
                self.assertIn('Checked PATH and common install directories, including C:\\AMDDesignTools\\*\\Vivado\\bin.', script_text)

    def test_toolkit_setup_collects_resolved_vivado_bin(self) -> None:
        setup_path = (
            REPO_ROOT
            / "templates"
            / "contexts"
            / "project_bootstrap"
            / "adapters"
            / "bat"
            / "toolkit_setup_dependencies.bat"
        )
        script_text = setup_path.read_text(encoding="utf-8")

        self.assertIn('set "VIVADO_RESOLVER=%TEMPLATES_ROOT%\\shared\\adapters\\bat\\resolve_vivado.bat"', script_text)
        self.assertIn('call "%VIVADO_RESOLVER%" --quiet', script_text)
        self.assertIn('call :add_path_candidate "%FPGA_AUTO_VIVADO_BIN%"', script_text)
        self.assertIn('C:\\AMDDesignTools\\2025.2\\Vivado\\bin', script_text)


if __name__ == "__main__":
    unittest.main()
