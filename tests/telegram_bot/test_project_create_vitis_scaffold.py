import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


class ProjectCreateVitisScaffoldTests(unittest.TestCase):
    def test_project_create_batch_creates_vitis_scaffold(self) -> None:
        script_text = (
            REPO_ROOT
            / "templates"
            / "contexts"
            / "project_bootstrap"
            / "adapters"
            / "bat"
            / "project_create.bat"
        ).read_text(encoding="utf-8")

        expected_fragments = (
            r"%TARGET_PROJECT%\include",
            r"%TARGET_PROJECT%\inc",
            r"%TARGET_PROJECT%\sw\common\include",
            r"%TARGET_PROJECT%\sw\common\src",
            r"%TARGET_PROJECT%\sw\apps\hello_world\src",
            r"%TARGET_PROJECT%\sw\apps\hello_world\include",
            r"%TARGET_PROJECT%\sw\apps\hello_world\data",
            r"%TARGET_PROJECT%\vitis\launch",
            r"%TARGET_PROJECT%\vitis\bsp_overrides",
            r"%TARGET_PROJECT%\output\vitis\xsa",
            r"%TARGET_PROJECT%\output\vitis\workspace",
            r"%TARGET_PROJECT%\output\vitis\platform",
            r"%TARGET_PROJECT%\output\vitis\apps",
            r"%TARGET_PROJECT%\output\vitis\summaries",
            r"%TARGET_PROJECT%\log\vitis",
            r"sw\apps\hello_world\src\main.c",
            r"vitis\launch\hardware.json",
            r"%TEMPLATES_ROOT%\project\fpgaclaw.cmd",
            r"fpgaclaw.cmd",
        )

        for fragment in expected_fragments:
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, script_text)

    def test_project_create_does_not_auto_sync_to_legacy_source_project(self) -> None:
        script_text = (
            REPO_ROOT
            / "templates"
            / "contexts"
            / "project_bootstrap"
            / "adapters"
            / "bat"
            / "project_create.bat"
        ).read_text(encoding="utf-8")

        self.assertNotIn("SyncProjectsToSourceProject.bat", script_text)
        self.assertNotIn("SOURCE_PROJECT", script_text)

    def test_manifest_template_includes_vitis_defaults(self) -> None:
        template_text = (REPO_ROOT / "templates" / "manifest" / "fpga_auto.template.yml").read_text(encoding="utf-8")

        self.assertIn("vitis:", template_text)
        self.assertIn('workspace: "output/vitis/workspace"', template_text)
        self.assertIn('path: "output/vitis/xsa/${project.name}.xsa"', template_text)
        self.assertIn('bit_path: ""', template_text)
        self.assertIn('"output/vivado/**/*.runs/impl_1/*.bit"', template_text)
        self.assertIn('vivado_project: ""', template_text)
        self.assertIn('impl_run: "impl_1"', template_text)
        self.assertIn('name: "${project.name}_platform"', template_text)
        self.assertIn('name: "hello_world"', template_text)
        self.assertIn('"sw/apps/hello_world/src/**/*"', template_text)
        self.assertIn('hw_server: ""', template_text)
        self.assertIn("auto: false", template_text)


if __name__ == "__main__":
    unittest.main()
