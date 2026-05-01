import importlib.util
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


PIPELINE_REPORT_PATH = MANAGED_PROJECT_ROOT / "RISCV_RV32I_5STAGE" / "tools" / "generate_pipeline_perf_report.py"


def load_pipeline_report_module():
    if not PIPELINE_REPORT_PATH.exists():
        raise unittest.SkipTest(f"Managed workspace sample not available: {PIPELINE_REPORT_PATH}")

    pipeline_spec = importlib.util.spec_from_file_location("pipeline_report_module", PIPELINE_REPORT_PATH)
    assert pipeline_spec is not None and pipeline_spec.loader is not None
    pipeline_report = importlib.util.module_from_spec(pipeline_spec)
    pipeline_spec.loader.exec_module(pipeline_report)
    return pipeline_report


class SingleCycleReportLayoutTests(unittest.TestCase):
    def test_single_cycle_report_compacts_logs_and_surfaces_analysis(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            output_dir = temp_root / "output"
            output_dir.mkdir(parents=True, exist_ok=True)
            report_path = temp_root / "SINGLE_CYCLE_OPTIMIZATION_REPORT.md"

            metadata = {
                "project_name": "RISCV_RV32I_SINGLE",
                "analysis_mode": "single_cycle",
                "isa_profile": "RV32I",
                "top_name": "TOP",
                "part_name": "xc7a35tcpg236-1",
                "program_image": "Full Coverage.mem",
                "program_memory": str(temp_root / "InstructionFORTIMING.mem"),
                "project_root": str(MANAGED_PROJECT_ROOT / "RISCV_RV32I_SINGLE"),
                "program_key": "full_coverage",
                "manifest_path": str(MANAGED_PROJECT_ROOT / "RISCV_RV32I_SINGLE" / "fpga_auto.yml"),
                "profile_path": str(MANAGED_PROJECT_ROOT / "RISCV_RV32I_SINGLE" / "tools" / "timing_analysis_profile.json"),
                "manifest_top_name": "Top",
                "resolved_source_files": [str(MANAGED_PROJECT_ROOT / "RISCV_RV32I_SINGLE" / "src" / "TOP.sv")],
                "probe_families": [{"key": "timing_metric", "label": "Timing Metric"}],
                "instruction_class_source": str(temp_root / "InstructionFORTIMING.s"),
                "warnings": [],
                "class_order": ["RTYPE"],
                "class_instruction_counts": {"RTYPE": 10},
                "known_probe_families": [{"key": "timing_metric", "label": "Timing Metric"}],
                "family_active_classes": {"timing_metric": ["RTYPE"]},
            }

            with (
                patch.object(single_cycle, "parse_timing_summary", return_value={"wns_ns": -1.234, "tns_ns": -9.876, "setup_failing_endpoints": 8}),
                patch.object(
                    single_cycle,
                    "parse_timing_paths_tsv",
                    return_value=[
                        {
                            "slack_ns": -1.234,
                            "min_period_ns": 11.234,
                            "route_share_pct": 80.0,
                            "logic_levels": 10.0,
                            "max_fanout": 24.0,
                            "datapath_delay_ns": 11.0,
                            "logic_delay_ns": 2.0,
                            "net_delay_ns": 9.0,
                            "start_pin": "uStart/Q",
                            "end_pin": "uEnd/D",
                        }
                    ],
                ),
                patch.object(single_cycle, "parse_high_fanout_report", return_value=[{"rank": 1, "fanout_count": 24, "driver_type": "LUT6", "net_name": "uNet"}]),
                patch.object(
                    single_cycle,
                    "parse_module_metrics_tsv",
                    return_value=[
                        {
                            "instance": "uDesign",
                            "total_prim_cells": 123,
                            "ff_count": 64,
                            "lut_count": 100,
                            "carry_count": 4,
                            "ram_count": 0,
                            "muxf_count": 0,
                            "other_count": 1,
                        }
                    ],
                ),
                patch.object(
                    single_cycle,
                    "parse_top_timing_report",
                    return_value=[
                        {
                            "modules": ["Pc", "DataRam", "Regfile"],
                            "destination": "uEnd/D",
                            "slack_ns": -1.234,
                        }
                    ],
                ),
                patch.object(
                    single_cycle,
                    "parse_family_timing_rows",
                    return_value=[
                        {
                            "key": "timing_metric",
                            "label": "Timing Metric",
                            "description": "Top timing sink",
                            "min_period_ns": 11.234,
                            "fmax_mhz": 89.01,
                            "path_count": 20,
                            "worst_path": {"end_pin": "uEnd/D"},
                            "tsv_path": output_dir / "timing_metric_timing_paths.tsv",
                            "report_path": output_dir / "timing_metric_timing_top20.rpt",
                        }
                    ],
                ),
                patch.object(
                    single_cycle,
                    "parse_actual_utilization",
                    return_value={
                        "slice_luts": 100,
                        "logic_luts": 90,
                        "lutram": 0,
                        "distributed_ram": 0,
                        "slice_regs": 64,
                        "f7_mux": 0,
                        "f8_mux": 0,
                        "bram_tile": 0,
                        "dsp": 0,
                        "bonded_iob": 2,
                        "bufgctrl": 1,
                    },
                ),
                patch.object(single_cycle, "parse_instance_areas_from_log", return_value=[{"instance": "uDesign", "module": "TOP", "cells": 42}]),
                patch.object(
                    single_cycle,
                    "parse_methodology_report",
                    return_value={
                        "severity_counts": {"Warning": 2},
                        "rules": [{"rule": "TIMING-16", "severity": "Warning", "description": "Large setup violation", "violations": 2}],
                        "examples": [{"instance": "TIMING-16#1", "severity": "Warning", "description": "Large setup violation", "detail": "There is a large setup violation."}],
                    },
                ),
                patch.object(single_cycle, "parse_qor_suggestions", return_value=["Suggestion A"]),
                patch.object(single_cycle, "analyze_program_trace", return_value={"instruction_count": 10}),
                patch.object(
                    single_cycle,
                    "estimate_single_cycle_execution",
                    return_value={
                        "architecture": "Single-Cycle",
                        "instruction_count": 10,
                        "cycle_count": 10,
                        "cpi": 1.0,
                        "runtime_ns": 100.0,
                    },
                ),
                patch.object(
                    single_cycle,
                    "estimate_pipeline_5stage_execution",
                    return_value={
                        "architecture": "5-Stage Pipeline",
                        "instruction_count": 10,
                        "cycle_count": 14,
                        "cpi": 1.4,
                        "runtime_ns": 80.0,
                    },
                ),
                patch.object(
                    single_cycle,
                    "resolve_pipeline_reference_metrics",
                    return_value={
                        "project_name": "RISCV_RV32I_5STAGE",
                        "output_dir": temp_root / "pipeline",
                        "wns_ns": -0.5,
                        "min_period_ns": 9.5,
                        "lut_used": 120,
                        "ff_used": 90,
                    },
                ),
                patch.object(single_cycle, "write_artifact_manifest", return_value=output_dir / "artifact_manifest.json"),
            ):
                report_text = single_cycle.build_report(output_dir, report_path, metadata)

            self.assertLess(report_text.index("## 🧭 Summary"), report_text.index("## 🧠 Analysis Result"))
            self.assertLess(report_text.index("## 🧠 Analysis Result"), report_text.index("## 📊 Key Metrics"))
            self.assertLess(report_text.index("## 📊 Key Metrics"), report_text.index("## 🎯 Recommended Actions"))
            self.assertLess(report_text.index("## 🎯 Recommended Actions"), report_text.index("## 📁 Evidence"))
            self.assertIn("❌ FAIL", report_text)
            self.assertIn("Route-dominant timing paths", report_text)
            self.assertIn("Repeated critical path signature", report_text)
            self.assertIn("| LUTs | 100 | 120 | +20 |", report_text)
            self.assertIn("| Registers | 64 | 90 | +26 |", report_text)
            self.assertIn("| CPI | 1.000 | 1.400 | +0.400 |", report_text)
            self.assertIn("| Pipeline Speedup (x) | 1.000x | 1.250x | +0.250x |", report_text)
            self.assertNotIn("### Raw Files", report_text)
            self.assertNotIn("## Appendix", report_text)
            self.assertNotIn("vivado_run.log", report_text)
            self.assertTrue(report_path.exists())
            self.assertTrue(report_path.with_suffix(".html").exists())


class PipelineReportLayoutTests(unittest.TestCase):
    def test_pipeline_report_compacts_logs_and_surfaces_analysis(self) -> None:
        pipeline_report = load_pipeline_report_module()
        with patch.object(pipeline_report, "analyze_project_pipeline_trace", return_value={"instruction_count": 12}), patch.object(
            pipeline_report,
            "estimate_single_cycle_execution",
            return_value={
                "architecture": "Single-Cycle",
                "instruction_count": 12,
                "cycle_count": 12,
                "cpi": 1.0,
                "runtime_ns": 120.0,
            },
        ), patch.object(
            pipeline_report,
            "estimate_project_pipeline_execution",
            return_value={
                "architecture": "5-Stage Pipeline",
                "instruction_count": 12,
                "cycle_count": 16,
                "cpi": 1.333,
                "runtime_ns": 96.0,
                "model_note": "retired + 4 fill",
            },
        ):
            report_text = pipeline_report.render_program_report_section(
                {"project_name": "RISCV_RV32I_SINGLE", "top_name": "TOP"},
                {
                    "wns_ns": -1.2,
                    "min_period_ns": 11.2,
                    "fmax_mhz": 89.286,
                    "route_status": "ROUTED",
                    "lut_used": "100",
                    "ff_used": "64",
                },
                {
                    "project_name": "RISCV_RV32I_5STAGE",
                    "top_name": "TOP",
                    "part_name": "xc7a35tcpg236-1",
                    "profile": {"stage_order": ["IF", "ID"]},
                },
                {
                    "wns_ns": -0.6,
                    "min_period_ns": 10.6,
                    "fmax_mhz": 94.340,
                    "route_status": "ROUTED",
                    "lut_used": "140",
                    "ff_used": "96",
                },
                Path("/tmp/pipeline_out"),
                {
                    "synth_directive": "Default",
                    "opt_directive": "Default",
                    "place_directive": "Default",
                    "route_directive": "Default",
                    "phys_opt_directive": "AggressiveExplore",
                    "post_route_phys_opt_directive": "AggressiveExplore",
                    "core_pblock_clock_region": "",
                },
                [
                    {
                        "key": "ex_writeback",
                        "label": "EX Writeback",
                        "description": "Execute to writeback path",
                        "stage": "EX",
                        "datapath_delay_ns": 7.2,
                        "min_period_ns": 10.6,
                        "fmax_mhz": 94.340,
                        "worst_path": {"end_pin": "uPipe/ex_reg/D"},
                        "path_count": 20,
                    }
                ],
                [],
                [],
                [],
                {"instruction_source": "/tmp/full_coverage.s", "warnings": []},
                {
                    "focus_count": 1,
                    "measured_focus_count": 1,
                    "status": "PASS",
                    "detail": "1/1 focus builds resolved with measured paths",
                    "selected_focuses": [],
                    "class_rows": [],
                    "mnemonic_rows": [],
                },
                {"display_name": "Full Coverage.mem", "key": "full_coverage", "mem_path": Path("/tmp/full_coverage.mem")},
            )

        self.assertLess(report_text.index("### 🧭 Summary"), report_text.index("### 🧠 Analysis Result"))
        self.assertLess(report_text.index("### 🧠 Analysis Result"), report_text.index("### 📊 Key Metrics"))
        self.assertLess(report_text.index("### 📊 Key Metrics"), report_text.index("### 🎯 Recommended Actions"))
        self.assertLess(report_text.index("### 🎯 Recommended Actions"), report_text.index("### 📁 Evidence"))
        self.assertIn("❌ FAIL", report_text)
        self.assertIn("Negative post-route slack", report_text)
        self.assertIn("| LUTs | 100 | 140 | +40 |", report_text)
        self.assertIn("| Registers | 64 | 96 | +32 |", report_text)
        self.assertIn("| CPI | 1.000 | 1.333 | +0.333 |", report_text)
        self.assertIn("| Pipeline Speedup (x) | 1.000x | 1.250x | +0.250x |", report_text)
        self.assertNotIn("#### Full Instruction-Focus Tables", report_text)
        self.assertNotIn("### Appendix", report_text)


if __name__ == "__main__":
    unittest.main()
