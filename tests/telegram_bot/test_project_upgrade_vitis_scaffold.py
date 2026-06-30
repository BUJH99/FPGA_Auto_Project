import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
MANIFEST_CLI = REPO_ROOT / "templates/contexts/manifest/adapters/cli/manifest_resolve_cli.js"
UPGRADE_CLI = REPO_ROOT / "templates/contexts/project_bootstrap/adapters/cli/project_upgrade_cli.js"


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


@unittest.skipUnless(NODE_PLATFORM, "Node.js is required for project upgrade tests")
class ProjectUpgradeVitisScaffoldTests(unittest.TestCase):
    def create_legacy_project(self, project_root: Path, name: str = "LegacyDemo") -> Path:
        project = project_root / name
        write_text(project / "src/LegacyTop.sv", "module LegacyTop; endmodule\n")
        write_text(
            project / "fpga_auto.yml",
            f"""version: "1"
project:
  name: "{name}"
hdl:
  top: "LegacyTop"
  src_globs:
    - "src/**/*.sv"
  tb_globs:
    - "tb/**/*.sv"
sim:
  tool: "xsim"
""",
        )
        return project

    def run_upgrade(self, repo: Path, project_root: Path, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "node",
                node_path(UPGRADE_CLI),
                "--repo",
                node_path(repo),
                "--project-root",
                node_path(project_root),
                *args,
            ],
            cwd=REPO_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    def resolve_manifest(self, project: Path) -> dict:
        result = subprocess.run(
            [
                "node",
                node_path(MANIFEST_CLI),
                "--project",
                node_path(project),
                "--json",
            ],
            cwd=REPO_ROOT,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        return json.loads(result.stdout)

    def test_upgrade_adds_vitis_scaffold_and_preserves_hdl_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = Path(temp_dir)
            repo = temp / "repo"
            repo.mkdir()
            project_root = temp / "Project"
            project = self.create_legacy_project(project_root)

            result = self.run_upgrade(repo, project_root, "--project", "LegacyDemo")

            self.assertEqual(0, result.returncode, msg=result.stderr + result.stdout)
            for rel_path in (
                "tb",
                "include",
                "inc",
                "constrs",
                "sw/common/include",
                "sw/common/src",
                "sw/apps/hello_world/src",
                "sw/apps/hello_world/include",
                "sw/apps/hello_world/data",
                "vitis/launch",
                "vitis/bsp_overrides",
                "output/vitis/xsa",
                "output/vitis/workspace",
                "output/vitis/platform",
                "output/vitis/apps",
                "output/vitis/summaries",
                "log/vitis",
            ):
                with self.subTest(rel_path=rel_path):
                    self.assertTrue((project / rel_path).is_dir())

            self.assertTrue((project / "sw/apps/hello_world/src/main.c").is_file())
            hardware = json.loads((project / "vitis/launch/hardware.json").read_text(encoding="utf-8"))
            self.assertEqual("hardware", hardware["mode"])
            launcher_text = (project / "fpgaclaw.cmd").read_text(encoding="utf-8")
            self.assertIn("MAIN.bat", launcher_text)
            self.assertIn("TARGET_PROJECT_ABS", launcher_text)
            self.assertNotIn("__FPGA_CLAW_REPO_ROOT__", launcher_text)

            manifest = self.resolve_manifest(project)
            self.assertEqual([], manifest["errors"])
            config = manifest["config"]
            self.assertEqual("LegacyTop", config["hdl"]["top"])
            self.assertEqual("output/vitis/workspace", config["vitis"]["workspace"])
            self.assertEqual("", config["vitis"]["xsa"]["bit_path"])
            self.assertIn("output/vivado/**/*.runs/impl_1/*.bit", config["vitis"]["xsa"]["bit_globs"])
            self.assertEqual("", config["vitis"]["xsa"]["vivado_project"])
            self.assertEqual("impl_1", config["vitis"]["xsa"]["impl_run"])
            self.assertEqual("hello_world", config["vitis"]["applications"][0]["name"])
            self.assertEqual(["sw/apps/hello_world/src/**/*", "sw/common/src/**/*"], config["vitis"]["applications"][0]["sources"])

    def test_dry_run_reports_plan_without_modifying_project(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = Path(temp_dir)
            repo = temp / "repo"
            repo.mkdir()
            project_root = temp / "Project"
            project = self.create_legacy_project(project_root)

            result = self.run_upgrade(repo, project_root, "--project", "LegacyDemo", "--dry-run")

            self.assertEqual(0, result.returncode, msg=result.stderr + result.stdout)
            self.assertFalse((project / "sw").exists())
            self.assertFalse((project / "fpgaclaw.cmd").exists())
            self.assertNotIn("vitis:", (project / "fpga_auto.yml").read_text(encoding="utf-8"))

            summary_path = repo / "output/project_upgrade/project_upgrade_summary.json"
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            self.assertEqual("warning", summary["status"])
            self.assertEqual(1, summary["details"]["results"][0]["plannedFiles"].count("sw/apps/hello_world/src/main.c"))
            self.assertEqual(1, summary["details"]["results"][0]["plannedFiles"].count("fpgaclaw.cmd"))

    def test_upgrade_second_run_is_current_with_empty_vitis_defaults(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = Path(temp_dir)
            repo = temp / "repo"
            repo.mkdir()
            project_root = temp / "Project"
            project = self.create_legacy_project(project_root)

            first = self.run_upgrade(repo, project_root, "--project", "LegacyDemo")
            self.assertEqual(0, first.returncode, msg=first.stderr + first.stdout)
            manifest_after_first = (project / "fpga_auto.yml").read_text(encoding="utf-8")

            second = self.run_upgrade(repo, project_root, "--project", "LegacyDemo")
            self.assertEqual(0, second.returncode, msg=second.stderr + second.stdout)
            self.assertEqual(manifest_after_first, (project / "fpga_auto.yml").read_text(encoding="utf-8"))

            summary_path = repo / "output/project_upgrade/project_upgrade_summary.json"
            summary = json.loads(summary_path.read_text(encoding="utf-8"))
            self.assertEqual(0, summary["details"]["upgraded"])
            self.assertEqual(1, summary["details"]["current"])
            self.assertEqual("current", summary["details"]["results"][0]["status"])
            self.assertEqual(["already_current"], summary["details"]["results"][0]["changes"])

    def test_batch_and_main_expose_upgrade_entrypoint(self) -> None:
        batch_text = (
            REPO_ROOT
            / "templates/contexts/project_bootstrap/adapters/bat/project_upgrade_existing.bat"
        ).read_text(encoding="utf-8")
        main_text = (REPO_ROOT / "MAIN.bat").read_text(encoding="utf-8")

        self.assertIn("project_upgrade_cli.js", batch_text)
        self.assertIn("--dry-run", batch_text)
        self.assertIn("UPGRADE_BAT", main_text)
        self.assertIn("FPGA_CLAW_LAUNCH_CWD", main_text)
        self.assertIn(":APPLY_LAUNCH_CWD_PROJECT", main_text)
        self.assertIn("Upgrade Existing Projects", main_text)
        self.assertIn("Upgrade This Project", main_text)


if __name__ == "__main__":
    unittest.main()
