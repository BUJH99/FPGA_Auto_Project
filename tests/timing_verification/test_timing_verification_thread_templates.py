import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
MANAGED_PROJECT_ROOT = REPO_ROOT.parent / "Project"


class TimingVerificationThreadTemplateTests(unittest.TestCase):
    def test_common_tcl_configures_max_threads_from_cpu_count(self) -> None:
        script_path = (
            REPO_ROOT
            / "templates"
            / "contexts"
            / "timing_verification"
            / "adapters"
            / "tcl"
            / "common.tcl"
        )
        script_text = script_path.read_text(encoding="utf-8")

        self.assertIn("proc riscv_timing_analysis::configure_max_threads", script_text)
        self.assertIn("{{default_threads 20}}", script_text)
        self.assertIn("info exists ::env(NUMBER_OF_PROCESSORS)", script_text)
        self.assertIn("set_param general.maxThreads $resolved_threads", script_text)
        self.assertIn('puts " \\[INFO\\] CPU Optimization Enabled: Using $resolved_threads threads."', script_text)
        self.assertIn('puts " \\[INFO\\] CPU Count detection failed. Defaulting to $resolved_threads threads."', script_text)

    def test_collectors_call_shared_thread_helper(self) -> None:
        collector_paths = (
            REPO_ROOT
            / "templates"
            / "contexts"
            / "timing_verification"
            / "adapters"
            / "tcl"
            / "single_cycle_collect_core.tcl",
            REPO_ROOT
            / "templates"
            / "contexts"
            / "timing_verification"
            / "adapters"
            / "tcl"
            / "focus_collect_core.tcl",
        )

        for script_path in collector_paths:
            with self.subTest(script=script_path.as_posix()):
                script_text = script_path.read_text(encoding="utf-8")
                self.assertIn("riscv_timing_analysis::configure_max_threads", script_text)

    def test_external_pipeline_collector_calls_shared_thread_helper(self) -> None:
        script_path = MANAGED_PROJECT_ROOT / "RISCV_32I_5STAGE" / "tools" / "pipeline_perf_collect.tcl"
        if not script_path.exists():
            self.skipTest(f"Managed workspace sample not available: {script_path}")

        script_text = script_path.read_text(encoding="utf-8")
        self.assertIn("riscv_timing_analysis::configure_max_threads", script_text)

    def test_vivado_build_tcl_uses_20_thread_fallback(self) -> None:
        script_path = (
            REPO_ROOT
            / "templates"
            / "contexts"
            / "vivado"
            / "adapters"
            / "tcl"
            / "vivado_run_build_flow.tcl"
        )
        script_text = script_path.read_text(encoding="utf-8")

        self.assertIn("set_param general.maxThreads 20", script_text)
        self.assertIn("Defaulting to 20 threads.", script_text)


if __name__ == "__main__":
    unittest.main()
