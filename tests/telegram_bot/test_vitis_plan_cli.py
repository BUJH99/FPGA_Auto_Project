import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
MANIFEST_CLI = REPO_ROOT / "templates/contexts/manifest/adapters/cli/manifest_resolve_cli.js"
VITIS_PLAN_CLI = REPO_ROOT / "templates/contexts/vitis/adapters/cli/vitis_plan_cli.js"
VITIS_MANIFEST_SYNC_CLI = REPO_ROOT / "templates/contexts/vitis/adapters/cli/vitis_manifest_sync_cli.js"


def node_platform() -> str:
    node = shutil.which("node")
    if not node:
        return ""
    try:
        result = subprocess.run(
            ["node", "-p", "process.platform"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except Exception:
        return ""
    return result.stdout.strip()


NODE_PLATFORM = node_platform()


def node_path(path: Path) -> str:
    if NODE_PLATFORM == "win32" and shutil.which("wslpath"):
        result = subprocess.run(
            ["wslpath", "-w", str(path)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        return result.stdout.strip()
    return str(path)


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


@unittest.skipUnless(NODE_PLATFORM, "Node.js is required for Vitis planner tests")
class VitisPlanCliTests(unittest.TestCase):
    def create_project(self, root: Path, app_count: int = 1) -> Path:
        project = root / "Demo"
        write_text(project / "src/TOP.sv", "module TOP; endmodule\n")
        write_text(project / "tb/tb_TOP.sv", "module tb_TOP; TOP dut(); endmodule\n")
        app_rows = []
        for idx in range(app_count):
            name = "hello_world" if idx == 0 else f"app_{idx + 1}"
            write_text(project / f"sw/apps/{name}/src/main.c", "int main(void) { return 0; }\n")
            app_rows.append(
                f"""
    - name: "{name}"
      template: "empty_application"
      sources:
        - "sw/apps/{name}/src/**/*"
      includes:
        - "sw/apps/{name}/include"
      target: "hw"
"""
            )
        write_text(
            project / "fpga_auto.yml",
            f"""version: "1"
project:
  name: "Demo"
hdl:
  top: "TOP"
  src_globs:
    - "src/**/*.sv"
  tb_globs:
    - "tb/**/*.sv"
vitis:
  applications:
{''.join(app_rows)}
""",
        )
        write_text(
            project / "output/vitis/workspace/Demo_platform/export/Demo_platform/Demo_platform.xpfm",
            "fake xpfm\n",
        )
        write_text(project / "output/vivado/Demo_hw/Demo_hw.xpr", "fake xpr\n")
        write_text(project / "output/vivado/Demo_hw/Demo_hw.runs/impl_1/Demo.bit", "fake bit\n")
        return project

    def resolve_manifest(self, project: Path) -> Path:
        manifest_json = project / "output/manifest/manifest_resolved.json"
        subprocess.run(
            [
                "node",
                node_path(MANIFEST_CLI),
                "--project",
                node_path(project),
                "--write",
                node_path(manifest_json),
                "--emit-lists",
                node_path(manifest_json.parent),
            ],
            cwd=REPO_ROOT,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        return manifest_json

    def test_default_paths_and_app_globs_resolve_under_output_vitis(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project = self.create_project(Path(temp_dir))
            manifest_json = self.resolve_manifest(project)
            result = subprocess.run(
                [
                    "node",
                    node_path(VITIS_PLAN_CLI),
                    "--project",
                    node_path(project),
                    "--manifest-json",
                    node_path(manifest_json),
                    "--step",
                    "create_application",
                    "--pretty",
                ],
                cwd=REPO_ROOT,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            payload = json.loads(result.stdout)
            plan = payload["plan"]
            self.assertIn("/output/vitis/workspace", plan["workspace"])
            self.assertIn("/output/vitis/xsa/Demo.xsa", plan["xsa"]["path"])
            self.assertEqual(["sw/apps/hello_world/src/main.c"], plan["application"]["sourceMatches"])
            self.assertTrue(payload["commandPath"].endswith("output/vitis/plan/create_application_plan.cmd"))

    def test_app_selection_fails_when_ambiguous(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project = self.create_project(Path(temp_dir), app_count=2)
            manifest_json = self.resolve_manifest(project)
            result = subprocess.run(
                [
                    "node",
                    node_path(VITIS_PLAN_CLI),
                    "--project",
                    node_path(project),
                    "--manifest-json",
                    node_path(manifest_json),
                    "--step",
                    "create_application",
                ],
                cwd=REPO_ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            self.assertNotEqual(0, result.returncode)
            self.assertIn("--apps <name1,name2>", result.stderr)

    def test_export_xsa_uses_timestamped_filename(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project = self.create_project(Path(temp_dir))
            manifest_json = self.resolve_manifest(project)
            copied_bit = project / "output/Demo.bit"
            write_text(copied_bit, "copied bit without run context\n")
            os.utime(copied_bit, (time.time() + 100, time.time() + 100))
            result = subprocess.run(
                [
                    "node",
                    node_path(VITIS_PLAN_CLI),
                    "--project",
                    node_path(project),
                    "--manifest-json",
                    node_path(manifest_json),
                    "--step",
                    "export_xsa",
                    "--timestamp",
                    "20240102_030405",
                    "--pretty",
                ],
                cwd=REPO_ROOT,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            payload = json.loads(result.stdout)
            xsa = payload["plan"]["xsa"]
            self.assertIn("/output/vitis/xsa/Demo_20240102_030405.xsa", xsa["path"])
            self.assertTrue(xsa["bitPath"].endswith("/output/vivado/Demo_hw/Demo_hw.runs/impl_1/Demo.bit"))
            self.assertTrue(xsa["bitSelected"]["hasRunPath"])
            self.assertTrue(xsa["vivadoProject"].endswith("/output/vivado/Demo_hw/Demo_hw.xpr"))
            self.assertEqual("impl_1", xsa["implRun"])

    def test_export_xsa_can_select_bitstream(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project = self.create_project(Path(temp_dir))
            manifest_json = self.resolve_manifest(project)
            alt_bit = project / "output/vivado/Demo_alt/Demo_alt.runs/route_fast/Demo_alt.bit"
            write_text(project / "output/vivado/Demo_alt/Demo_alt.xpr", "alt xpr\n")
            write_text(alt_bit, "alt bit\n")

            result = subprocess.run(
                [
                    "node",
                    node_path(VITIS_PLAN_CLI),
                    "--project",
                    node_path(project),
                    "--manifest-json",
                    node_path(manifest_json),
                    "--step",
                    "export_xsa",
                    "--bit",
                    "Demo_alt",
                    "--pretty",
                ],
                cwd=REPO_ROOT,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            xsa = json.loads(result.stdout)["plan"]["xsa"]
            self.assertTrue(xsa["bitPath"].endswith("/output/vivado/Demo_alt/Demo_alt.runs/route_fast/Demo_alt.bit"))
            self.assertTrue(xsa["vivadoProject"].endswith("/output/vivado/Demo_alt/Demo_alt.xpr"))
            self.assertEqual("route_fast", xsa["implRun"])

    def test_create_platform_selects_latest_xsa_and_timestamped_platform(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project = self.create_project(Path(temp_dir))
            manifest_json = self.resolve_manifest(project)
            old_xsa = project / "output/vitis/xsa/Demo_20240101_010101.xsa"
            new_xsa = project / "output/vitis/xsa/Demo_20240102_010101.xsa"
            write_text(old_xsa, "old\n")
            write_text(new_xsa, "new\n")
            old_time = time.time() - 100
            new_time = time.time()
            os.utime(old_xsa, (old_time, old_time))
            os.utime(new_xsa, (new_time, new_time))

            result = subprocess.run(
                [
                    "node",
                    node_path(VITIS_PLAN_CLI),
                    "--project",
                    node_path(project),
                    "--manifest-json",
                    node_path(manifest_json),
                    "--step",
                    "create_platform",
                    "--timestamp",
                    "20240102_030405",
                    "--pretty",
                ],
                cwd=REPO_ROOT,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            plan = json.loads(result.stdout)["plan"]
            self.assertTrue(plan["xsa"]["path"].endswith("Demo_20240102_010101.xsa"))
            self.assertEqual("Demo_platform_0102_030405", plan["platform"]["name"])
            self.assertIn("/Demo_platform_0102_030405/export/Demo_platform_0102_030405/", plan["platform"]["xpfm"])

    def test_list_choices_emit_file_name_labels_for_batch_selection(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project = self.create_project(Path(temp_dir), app_count=2)
            manifest_json = self.resolve_manifest(project)
            write_text(project / "output/vitis/xsa/Demo_20240102_010101.xsa", "xsa\n")

            def list_rows(kind: str) -> list[list[str]]:
                result = subprocess.run(
                    [
                        "node",
                        node_path(VITIS_PLAN_CLI),
                        "--project",
                        node_path(project),
                        "--manifest-json",
                        node_path(manifest_json),
                        "--list",
                        kind,
                    ],
                    cwd=REPO_ROOT,
                    check=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                return [line.split("|") for line in result.stdout.splitlines()]

            xsa_rows = list_rows("xsas")
            self.assertIn("Demo_20240102_010101.xsa", [row[3] for row in xsa_rows])

            platform_rows = list_rows("platforms")
            self.assertIn("Demo_platform.xpfm", [row[3] for row in platform_rows])

            app_rows = list_rows("applications")
            self.assertEqual(["hello_world", "app_2"], [row[3] for row in app_rows])

    def test_workspace_application_components_are_listed(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project = self.create_project(Path(temp_dir))
            manifest_json = self.resolve_manifest(project)
            write_text(
                project / "output/vitis/workspace/Test1/vitis-comp.json",
                """{
  "name": "Test1",
  "type": "HOST",
  "platform": "Demo_platform",
  "domain": "standalone_microblaze_0",
  "configuration": { "componentType": "HOST" },
  "template": "empty_application"
}
""",
            )

            result = subprocess.run(
                [
                    "node",
                    node_path(VITIS_PLAN_CLI),
                    "--project",
                    node_path(project),
                    "--manifest-json",
                    node_path(manifest_json),
                    "--list",
                    "applications",
                ],
                cwd=REPO_ROOT,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            app_rows = [line.split("|") for line in result.stdout.splitlines()]
            self.assertEqual(["hello_world", "Test1"], [row[3] for row in app_rows])

    def test_build_application_can_select_workspace_component(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project = self.create_project(Path(temp_dir))
            manifest_json = self.resolve_manifest(project)
            write_text(
                project / "output/vitis/workspace/Test1/vitis-comp.json",
                """{
  "name": "Test1",
  "type": "HOST",
  "platform": "Demo_platform",
  "domain": "standalone_microblaze_0",
  "configuration": { "componentType": "HOST" }
}
""",
            )

            result = subprocess.run(
                [
                    "node",
                    node_path(VITIS_PLAN_CLI),
                    "--project",
                    node_path(project),
                    "--manifest-json",
                    node_path(manifest_json),
                    "--step",
                    "build_application",
                    "--app",
                    "Test1",
                    "--pretty",
                ],
                cwd=REPO_ROOT,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            plan = json.loads(result.stdout)["plan"]
            self.assertEqual("Test1", plan["application"]["name"])
            self.assertEqual("workspace", plan["application"]["discoveredFrom"])
            self.assertEqual([], plan["application"]["sourceGlobs"])

    def test_platform_list_hides_missing_configured_placeholder(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project = self.create_project(Path(temp_dir))
            manifest_text = (project / "fpga_auto.yml").read_text(encoding="utf-8")
            manifest_text = manifest_text.replace(
                "vitis:\n  applications:\n",
                """vitis:
  platform:
    name: "Demo"
    xpfm: "output/vitis/workspace/${platform.name}/export/${platform.name}/${platform.name}.xpfm"
  applications:
""",
            )
            write_text(project / "fpga_auto.yml", manifest_text)
            manifest_json = self.resolve_manifest(project)

            result = subprocess.run(
                [
                    "node",
                    node_path(VITIS_PLAN_CLI),
                    "--project",
                    node_path(project),
                    "--manifest-json",
                    node_path(manifest_json),
                    "--list",
                    "platforms",
                ],
                cwd=REPO_ROOT,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            labels = [line.split("|")[3] for line in result.stdout.splitlines()]
            self.assertIn("Demo_platform.xpfm", labels)
            self.assertNotIn("Demo.xpfm", labels)

    def test_create_application_rejects_missing_platform_placeholder(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project = self.create_project(Path(temp_dir))
            manifest_text = (project / "fpga_auto.yml").read_text(encoding="utf-8")
            manifest_text = manifest_text.replace(
                "vitis:\n  applications:\n",
                """vitis:
  platform:
    name: "Demo"
    xpfm: "output/vitis/workspace/${platform.name}/export/${platform.name}/${platform.name}.xpfm"
  applications:
""",
            )
            write_text(project / "fpga_auto.yml", manifest_text)
            manifest_json = self.resolve_manifest(project)

            result = subprocess.run(
                [
                    "node",
                    node_path(VITIS_PLAN_CLI),
                    "--project",
                    node_path(project),
                    "--manifest-json",
                    node_path(manifest_json),
                    "--step",
                    "create_application",
                    "--platform",
                    "Demo",
                    "--app",
                    "sensor_console",
                ],
                cwd=REPO_ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            self.assertNotEqual(0, result.returncode)
            self.assertIn("No Vitis platform candidate matching 'Demo' was found", result.stderr)

    def test_create_application_can_select_platform_xpfm(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project = self.create_project(Path(temp_dir))
            manifest_json = self.resolve_manifest(project)
            alt_xpfm = project / "output/vitis/workspace/Demo_platform_alt/export/Demo_platform_alt/Demo_platform_alt.xpfm"
            write_text(alt_xpfm, "alt\n")
            result = subprocess.run(
                [
                    "node",
                    node_path(VITIS_PLAN_CLI),
                    "--project",
                    node_path(project),
                    "--manifest-json",
                    node_path(manifest_json),
                    "--step",
                    "create_application",
                    "--platform",
                    "Demo_platform_alt",
                    "--pretty",
                ],
                cwd=REPO_ROOT,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            plan = json.loads(result.stdout)["plan"]
            self.assertEqual("Demo_platform_alt", plan["platform"]["name"])
            self.assertTrue(plan["platform"]["xpfm"].endswith("Demo_platform_alt.xpfm"))

    def test_create_application_accepts_unbuilt_platform_component(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project = self.create_project(Path(temp_dir))
            manifest_json = self.resolve_manifest(project)
            component_dir = project / "output/vitis/workspace/Demo_platform_new"
            write_text(component_dir / "vitis-comp.json", '{"name":"Demo_platform_new","type":"PLATFORM"}\n')
            result = subprocess.run(
                [
                    "node",
                    node_path(VITIS_PLAN_CLI),
                    "--project",
                    node_path(project),
                    "--manifest-json",
                    node_path(manifest_json),
                    "--step",
                    "create_application",
                    "--platform",
                    "Demo_platform_new",
                    "--app",
                    "sensor_console",
                    "--pretty",
                ],
                cwd=REPO_ROOT,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            plan = json.loads(result.stdout)["plan"]
            self.assertEqual("Demo_platform_new", plan["platform"]["name"])
            self.assertFalse(plan["platform"]["selected"]["hasXpfm"])
            self.assertIn("selected_platform_xpfm_missing", ",".join(plan["warnings"]))

    def test_create_application_accepts_new_component_name(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project = self.create_project(Path(temp_dir))
            manifest_json = self.resolve_manifest(project)
            result = subprocess.run(
                [
                    "node",
                    node_path(VITIS_PLAN_CLI),
                    "--project",
                    node_path(project),
                    "--manifest-json",
                    node_path(manifest_json),
                    "--step",
                    "create_application",
                    "--app",
                    "sensor_console",
                    "--pretty",
                ],
                cwd=REPO_ROOT,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            plan = json.loads(result.stdout)["plan"]
            self.assertEqual("sensor_console", plan["application"]["name"])
            self.assertEqual(["sensor_console"], [app["name"] for app in plan["selectedApplications"]])
            self.assertIn("sw/apps/sensor_console/src/**/*", plan["application"]["sourceGlobs"])

    def test_manifest_sync_persists_created_application(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project = self.create_project(Path(temp_dir))
            manifest_json = self.resolve_manifest(project)
            result = subprocess.run(
                [
                    "node",
                    node_path(VITIS_PLAN_CLI),
                    "--project",
                    node_path(project),
                    "--manifest-json",
                    node_path(manifest_json),
                    "--step",
                    "create_application",
                    "--app",
                    "sensor_console",
                    "--pretty",
                ],
                cwd=REPO_ROOT,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            payload = json.loads(result.stdout)
            write_text(
                Path(payload["resultPath"]),
                json.dumps({
                    "schemaVersion": 1,
                    "type": "vitis_result",
                    "step": "create_application",
                    "status": "ok",
                    "outputs": {"applicationNames": ["sensor_console"]},
                    "warnings": [],
                    "errors": [],
                }),
            )

            sync_statuses = []
            for _ in range(2):
                sync = subprocess.run(
                    [
                        "node",
                        node_path(VITIS_MANIFEST_SYNC_CLI),
                        "--project",
                        node_path(project),
                        "--plan-json",
                        node_path(Path(payload["planPath"])),
                        "--result-json",
                        node_path(Path(payload["resultPath"])),
                    ],
                    cwd=REPO_ROOT,
                    check=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                sync_statuses.append(json.loads(sync.stdout.splitlines()[0])["status"])
            self.assertEqual(["updated", "current"], sync_statuses)

            manifest = self.resolve_manifest(project)
            resolved = json.loads(manifest.read_text(encoding="utf-8"))
            apps = resolved["config"]["vitis"]["applications"]
            matches = [app for app in apps if app["name"] == "sensor_console"]
            self.assertEqual(1, len(matches))
            self.assertEqual(["sw/apps/sensor_console/src/**/*", "sw/common/src/**/*"], matches[0]["sources"])
            self.assertEqual(["sw/apps/sensor_console/include", "sw/common/include"], matches[0]["includes"])
            self.assertEqual("hw", matches[0]["target"])

    def test_platform_discovery_ignores_vitis_internal_and_app_dirs(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project = self.create_project(Path(temp_dir))
            manifest_json = self.resolve_manifest(project)
            write_text(project / "output/vitis/workspace/.rigel_lopper/cpulist.yaml", "internal\n")
            write_text(project / "output/vitis/workspace/_ide/version.ini", "internal\n")
            write_text(
                project / "output/vitis/workspace/hello_world/vitis-comp.json",
                '{"name":"hello_world","type":"HOST"}\n',
            )

            result = subprocess.run(
                [
                    "node",
                    node_path(VITIS_PLAN_CLI),
                    "--project",
                    node_path(project),
                    "--manifest-json",
                    node_path(manifest_json),
                    "--step",
                    "build_platform",
                    "--pretty",
                ],
                cwd=REPO_ROOT,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            platform = json.loads(result.stdout)["plan"]["platform"]
            self.assertEqual("Demo_platform", platform["name"])
            self.assertNotIn(".rigel_lopper", platform["xpfm"])
            self.assertNotIn("/_ide/", platform["xpfm"])

    def test_build_application_accepts_multiple_apps(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project = self.create_project(Path(temp_dir), app_count=2)
            manifest_json = self.resolve_manifest(project)
            result = subprocess.run(
                [
                    "node",
                    node_path(VITIS_PLAN_CLI),
                    "--project",
                    node_path(project),
                    "--manifest-json",
                    node_path(manifest_json),
                    "--step",
                    "build_application",
                    "--apps",
                    "hello_world,app_2",
                    "--pretty",
                ],
                cwd=REPO_ROOT,
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            selected = json.loads(result.stdout)["plan"]["selectedApplications"]
            self.assertEqual(["hello_world", "app_2"], [app["name"] for app in selected])


if __name__ == "__main__":
    unittest.main()
