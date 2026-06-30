import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


REPO_ROOT = Path(__file__).resolve().parents[2]
MANAGED_PROJECT_ROOT = REPO_ROOT.parent / "Project"
PYTHON_ADAPTER_ROOT = (
    REPO_ROOT
    / "templates"
    / "contexts"
    / "timing_verification"
    / "adapters"
    / "python"
)

if str(PYTHON_ADAPTER_ROOT) not in sys.path:
    sys.path.insert(0, str(PYTHON_ADAPTER_ROOT))

from riscv_timing_analysis import single_cycle


class SingleCycleVivadoSplitTests(unittest.TestCase):
    def make_fixture(self, temp_root: Path, *, include_probe_family: bool = False) -> tuple[Path, Path, dict[str, object], dict[str, object]]:
        project_root = temp_root / "project"
        output_dir = temp_root / "output"
        (project_root / "tools").mkdir(parents=True, exist_ok=True)
        (project_root / "src").mkdir(parents=True, exist_ok=True)
        output_dir.mkdir(parents=True, exist_ok=True)
        source_file = project_root / "src" / "TOP.sv"
        source_file.write_text("module TOP; endmodule\n", encoding="utf-8")

        contract = {
            "project_name": "RISCV_32I_SINGLE",
            "source_files": [source_file],
            "repo_root": REPO_ROOT,
            "part_name": "xczu3eg-sbva484-1-i",
            "top_name": "TOP",
            "clock_port": "iClk",
            "reset_port": "iRstn",
            "clock_period_ns": 10.0,
        }
        metadata = {
            "probe_families": [],
            "module_metrics_exclude_patterns": ["*probe*"],
        }
        if include_probe_family:
            metadata["probe_families"] = [
                {
                    "key": "timing_metric",
                    "label": "Timing Metric",
                    "description": "Test family",
                }
            ]

        return project_root, output_dir, contract, metadata

    def write_fake_wrapper(
        self,
        wrapper_path: Path,
        *,
        variables: dict[str, object],
        source_path: Path,
    ) -> None:
        _ = (variables, source_path)
        wrapper_path.write_text("# wrapper\n", encoding="utf-8")

    def write_artifacts(self, paths: list[Path]) -> None:
        for path in paths:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("artifact\n", encoding="utf-8")

    def test_build_wrapper_variables_includes_analysis_phase(self) -> None:
        contract = {
            "source_files": [MANAGED_PROJECT_ROOT / "RISCV_32I_SINGLE" / "src" / "TOP.sv"],
            "repo_root": REPO_ROOT,
            "part_name": "xczu3eg-sbva484-1-i",
            "top_name": "TOP",
            "clock_port": "iClk",
            "reset_port": "iRstn",
            "clock_period_ns": 10.0,
        }
        metadata = {
            "probe_families": [],
            "module_metrics_exclude_patterns": ["*probe*"],
        }

        variables = single_cycle.build_wrapper_variables(
            contract,
            REPO_ROOT / ".analysis" / "tmp",
            metadata,
            analysis_phase="hierarchical_only",
        )

        self.assertEqual(variables["analysis_phase"], "hierarchical_only")

    def test_run_vivado_uses_fresh_vivado_process_per_phase(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root, output_dir, contract, metadata = self.make_fixture(Path(temp_dir))

            wrapper_calls: list[tuple[str, str, str]] = []
            progress_updates: list[tuple[int, int, str]] = []

            def fake_write_wrapper_tcl(
                wrapper_path: Path,
                *,
                variables: dict[str, object],
                source_path: Path,
            ) -> None:
                wrapper_calls.append(
                    (
                        wrapper_path.name,
                        str(variables["analysis_phase"]),
                        source_path.name,
                    )
                )
                wrapper_path.write_text("# wrapper\n", encoding="utf-8")

            def fake_run_vivado_batch(
                *,
                project_root: Path,
                wrapper_tcl: Path,
                log_path: Path,
                progress_label: str | None = None,
                progress_callback=None,
                heartbeat_seconds: int = 15,
            ) -> Path:
                _ = (project_root, progress_label, heartbeat_seconds)
                log_path.parent.mkdir(parents=True, exist_ok=True)
                log_path.write_text(
                    "\n".join(
                        [
                            f"wrapper={wrapper_tcl.name}",
                            "Report Instance Areas",
                            "---------------------------------------------------------------------------------",
                            "| 1 | uDesign | TOP | 42 |",
                            "---------------------------------------------------------------------------------",
                            "",
                        ]
                    ),
                    encoding="utf-8",
                )
                if progress_callback is not None:
                    progress_callback(1, 3, f"{wrapper_tcl.stem} started")
                    progress_callback(3, 3, f"{wrapper_tcl.stem} finished")
                return log_path

            with (
                patch.object(single_cycle, "write_wrapper_tcl", side_effect=fake_write_wrapper_tcl),
                patch.object(single_cycle, "run_vivado_batch", side_effect=fake_run_vivado_batch),
            ):
                combined_log = single_cycle.run_vivado(
                    project_root,
                    output_dir,
                    contract,
                    metadata,
                    progress_callback=lambda current, total, label: progress_updates.append((current, total, label)),
                )

            self.assertEqual(
                wrapper_calls,
                [
                    (
                        "run_single_cycle_perf_actual_wrapper.tcl",
                        "actual_only",
                        "single_cycle_perf_collect.tcl",
                    ),
                    (
                        "run_single_cycle_perf_hierarchical_wrapper.tcl",
                        "hierarchical_only",
                        "single_cycle_perf_collect.tcl",
                    ),
                ],
            )
            self.assertEqual(combined_log, output_dir / "vivado_run.log")

            self.assertEqual(progress_updates[0], (1, 6, "Actual timing: run_single_cycle_perf_actual_wrapper started"))
            self.assertEqual(progress_updates[1], (3, 6, "Actual timing: run_single_cycle_perf_actual_wrapper finished"))
            self.assertEqual(progress_updates[2], (4, 6, "Hierarchical timing: run_single_cycle_perf_hierarchical_wrapper started"))
            self.assertEqual(progress_updates[3], (6, 6, "Hierarchical timing: run_single_cycle_perf_hierarchical_wrapper finished"))

            combined_text = combined_log.read_text(encoding="utf-8")
            self.assertIn("===== Actual Timing Run =====", combined_text)
            self.assertIn("wrapper=run_single_cycle_perf_actual_wrapper.tcl", combined_text)
            self.assertIn("===== Hierarchical Timing Run =====", combined_text)
            self.assertIn("wrapper=run_single_cycle_perf_hierarchical_wrapper.tcl", combined_text)

    def test_run_vivado_tolerates_exit_access_violation_after_phase_completion(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root, output_dir, contract, metadata = self.make_fixture(Path(temp_dir), include_probe_family=True)

            def fake_run_vivado_batch(
                *,
                project_root: Path,
                wrapper_tcl: Path,
                log_path: Path,
                progress_label: str | None = None,
                progress_callback=None,
                heartbeat_seconds: int = 15,
            ) -> Path:
                _ = (project_root, progress_label, progress_callback, heartbeat_seconds)
                if "actual" in wrapper_tcl.name:
                    self.write_artifacts(
                        single_cycle.expected_actual_phase_artifacts(output_dir, metadata)
                    )
                    completion_marker = "Completed single-cycle timing artifacts"
                else:
                    self.write_artifacts(
                        single_cycle.expected_hierarchical_phase_artifacts(output_dir)
                    )
                    completion_marker = "Completed hierarchical analysis artifacts"

                log_path.write_text(
                    "\n".join(
                        [
                            f"wrapper={wrapper_tcl.name}",
                            f"__FPGA_AUTO_PROGRESS__\t3\t3\t{completion_marker}",
                            "# exit",
                            "INFO: [Common 17-206] Exiting Vivado at Tue Mar 31 06:44:09 2026...",
                            "Abnormal program termination (EXCEPTION_ACCESS_VIOLATION)",
                            "",
                        ]
                    ),
                    encoding="utf-8",
                )
                raise RuntimeError(f"Vivado failed with exit code 3221225477. See {log_path}")

            with (
                patch.object(single_cycle, "write_wrapper_tcl", side_effect=self.write_fake_wrapper),
                patch.object(single_cycle, "run_vivado_batch", side_effect=fake_run_vivado_batch),
            ):
                combined_log = single_cycle.run_vivado(project_root, output_dir, contract, metadata)

            combined_text = combined_log.read_text(encoding="utf-8")
            self.assertIn("===== Actual Timing Run =====", combined_text)
            self.assertIn("===== Hierarchical Timing Run =====", combined_text)
            self.assertIn("EXCEPTION_ACCESS_VIOLATION", combined_text)

    def test_run_vivado_keeps_failure_when_exit_access_violation_happens_early(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root, output_dir, contract, metadata = self.make_fixture(Path(temp_dir))

            def fake_run_vivado_batch(
                *,
                project_root: Path,
                wrapper_tcl: Path,
                log_path: Path,
                progress_label: str | None = None,
                progress_callback=None,
                heartbeat_seconds: int = 15,
            ) -> Path:
                _ = (project_root, wrapper_tcl, progress_label, progress_callback, heartbeat_seconds)
                log_path.write_text(
                    "\n".join(
                        [
                            "__FPGA_AUTO_PROGRESS__\t1\t3\tLoaded single-cycle RTL sources",
                            "Abnormal program termination (EXCEPTION_ACCESS_VIOLATION)",
                            "",
                        ]
                    ),
                    encoding="utf-8",
                )
                raise RuntimeError(f"Vivado failed with exit code 3221225477. See {log_path}")

            with (
                patch.object(single_cycle, "write_wrapper_tcl", side_effect=self.write_fake_wrapper),
                patch.object(single_cycle, "run_vivado_batch", side_effect=fake_run_vivado_batch),
            ):
                with self.assertRaises(RuntimeError):
                    single_cycle.run_vivado(project_root, output_dir, contract, metadata)


if __name__ == "__main__":
    unittest.main()
