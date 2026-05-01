import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
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

from riscv_timing_analysis.integrated_report import (
    merge_program_detail_section,
    render_physical_delay_stack_svg,
    shift_markdown_headings,
    status_badge,
    strip_first_markdown_heading,
    strip_noisy_report_sections,
    write_html_report,
)
from riscv_timing_analysis.single_cycle import build_integrated_single_cycle_detail_text


def resolve_program_selection(program_key: str) -> dict[str, str]:
    labels = {
        "full_coverage": "Full Coverage.mem",
        "bubble_sort": "Bubble Sort.mem",
    }
    return {
        "key": program_key,
        "display_name": labels[program_key],
    }


class IntegratedTimingReportTests(unittest.TestCase):
    def test_strip_and_shift_markdown_headings(self) -> None:
        text = "# Title\n\n## Scope\n\n### Detail\n"

        stripped = strip_first_markdown_heading(text)
        shifted = shift_markdown_headings(stripped, 2)

        self.assertEqual(stripped, "## Scope\n\n### Detail\n")
        self.assertEqual(shifted, "#### Scope\n\n##### Detail\n")

    def test_status_badges_and_noisy_sections_are_compacted(self) -> None:
        text = "## 🧭 Summary\n\n- keep\n\n## Appendix\n\n- drop\n\n## 📁 Evidence\n\n- keep evidence\n\n<details>\n<summary>Compact timing evidence</summary>\n\n- verbose\n</details>\n"

        compacted = strip_noisy_report_sections(text)

        self.assertEqual(status_badge("FAIL"), "❌ FAIL")
        self.assertEqual(status_badge("WARN"), "⚠️ WARN")
        self.assertIn("## 🧭 Summary", compacted)
        self.assertIn("## 📁 Evidence", compacted)
        self.assertNotIn("Appendix", compacted)
        self.assertNotIn("- drop", compacted)
        self.assertNotIn("<details>", compacted)
        self.assertNotIn("- verbose", compacted)

    def test_merge_program_detail_section_preserves_other_blocks(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            report_path = Path(temp_dir) / "INTEGRATED_TIMING_REPORT.md"

            report_text = merge_program_detail_section(
                report_path,
                program_selection=resolve_program_selection("full_coverage"),
                detail_key="single_cycle",
                detail_body="- full single\n",
                program_keys=["full_coverage", "bubble_sort"],
                resolve_program_selection=resolve_program_selection,
            )
            report_path.write_text(report_text, encoding="utf-8")

            report_text = merge_program_detail_section(
                report_path,
                program_selection=resolve_program_selection("full_coverage"),
                detail_key="pipeline_perf",
                detail_body="- full pipeline\n",
                program_keys=["full_coverage", "bubble_sort"],
                resolve_program_selection=resolve_program_selection,
            )
            report_path.write_text(report_text, encoding="utf-8")

            report_text = merge_program_detail_section(
                report_path,
                program_selection=resolve_program_selection("bubble_sort"),
                detail_key="single_cycle",
                detail_body="- bubble single\n",
                program_keys=["full_coverage", "bubble_sort"],
                resolve_program_selection=resolve_program_selection,
            )

            self.assertIn("## Full Coverage.mem", report_text)
            self.assertIn("## Bubble Sort.mem", report_text)
            self.assertIn("- full single", report_text)
            self.assertIn("- full pipeline", report_text)
            self.assertIn("- bubble single", report_text)
            self.assertIn("- No pipeline performance detail recorded yet for this program image.", report_text)

    def test_single_cycle_detail_wrapper_promotes_section_headings(self) -> None:
        detail_text = build_integrated_single_cycle_detail_text(
            "# SINGLE_CYCLE Optimization Report\n\n## Scope\n\n- detail line\n",
            project_name="RISCV_RV32I_SINGLE",
            artifact_dir=Path("/tmp/single_cycle/full_coverage"),
            report_path=Path("/tmp/SINGLE_CYCLE_OPTIMIZATION_REPORT.md"),
        )

        self.assertIn("- Source project: `RISCV_RV32I_SINGLE`", detail_text)
        self.assertIn("- Source artifacts: `/tmp/single_cycle/full_coverage`", detail_text)
        self.assertIn("- Standalone report path: `/tmp/SINGLE_CYCLE_OPTIMIZATION_REPORT.md`", detail_text)
        self.assertIn("#### Scope", detail_text)
        self.assertNotIn("# SINGLE_CYCLE Optimization Report", detail_text)

    def test_single_cycle_detail_wrapper_removes_verbose_appendix(self) -> None:
        detail_text = build_integrated_single_cycle_detail_text(
            "# SINGLE_CYCLE Optimization Report\n\n## 🧭 Summary\n\n- keep\n\n## Appendix\n\n### Raw Files\n\n- vivado_run.log\n",
            project_name="RISCV_RV32I_SINGLE",
            artifact_dir=Path("/tmp/single_cycle/full_coverage"),
            report_path=Path("/tmp/SINGLE_CYCLE_OPTIMIZATION_REPORT.md"),
        )

        self.assertIn("#### 🧭 Summary", detail_text)
        self.assertNotIn("Appendix", detail_text)
        self.assertNotIn("Raw Files", detail_text)
        self.assertNotIn("vivado_run.log", detail_text)

    def test_html_report_renders_metric_and_stage_charts(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            html_path = Path(temp_dir) / "report.html"
            markdown_text = """# Demo Report

## 📊 Key Metrics

| Metric | Single-Cycle | 5-Stage Pipeline | Delta |
| --- | ---: | ---: | ---: |
| Fmax (MHz) | 50.0 | 100.0 | +50.0 |
| WNS (ns) | -1.0 | 0.2 | +1.2 |
| Cycles | 10 | 14 | +4 |
| CPI | 1.000 | 1.400 | +0.400 |
| LUTs | 100 | 120 | +20 |
| Registers | 64 | 90 | +26 |

### Root Cause Candidates

| Severity | Category | Finding | Evidence | Impact |
| --- | --- | --- | --- | --- |
| ❌ FAIL | Timing Closure | Negative setup timing | WNS -1.0 ns | Clock target is missed. |
| ⚠️ WARN | Routing | Route-dominant path | Route share 78% | Physical locality needs review. |

#### True Stage Boundary Timing

| Boundary | Stage | Data Path (ns) | Minimum Period (ns) | Fmax (MHz) | Logic Levels | Route Share (%) | Worst Start | Worst Endpoint | Reported Paths | Unique Paths |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- | --- | ---: | ---: |
| EX Stage | EX | 9.1 | 10.2 | 98.0 | 12 | 78.5 | `a/C` | `b/D` | 20 | 1 |
"""

            write_html_report(html_path, markdown_text, title="Demo Report")
            html_text = html_path.read_text(encoding="utf-8")

        self.assertIn("Architecture Metric Comparison 1", html_text)
        self.assertIn("Architecture Performance Dashboard", html_text)
        self.assertIn("Pipeline Execution Breakdown", html_text)
        self.assertIn("Fmax Benchmark Comparison", html_text)
        self.assertIn("Physical Delay Stack", html_text)
        self.assertIn("Hardware Resource Utilization", html_text)
        self.assertIn("dashboard-stack", html_text)
        self.assertIn("kpi-grid", html_text)
        self.assertIn("Automated Root Cause Findings", html_text)
        self.assertIn("Root Cause Severity Mix", html_text)
        self.assertIn("Stage Boundary Timing", html_text)
        self.assertIn("chart-panel", html_text)
        self.assertIn("data-chart-engine=\"python-svg\"", html_text)
        self.assertIn("<svg", html_text)
        self.assertIn("Self-contained HTML", html_text)

    def test_physical_delay_chart_uses_one_row_per_pipeline_stage(self) -> None:
        svg = render_physical_delay_stack_svg(
            {
                "stage_rows": [
                    {"stage": "EX", "period_ns": 11.0, "datapath_ns": 10.0, "route_share_pct": 75.0},
                    {"stage": "EX", "period_ns": 10.0, "datapath_ns": 9.0, "route_share_pct": 70.0},
                    {"stage": "ID", "period_ns": 9.5, "datapath_ns": 8.8, "route_share_pct": 72.0},
                    {"stage": "ID", "period_ns": 8.5, "datapath_ns": 8.0, "route_share_pct": 69.0},
                    {"stage": "IF", "period_ns": 7.0, "datapath_ns": 6.5, "route_share_pct": 80.0},
                    {"stage": "MEM", "period_ns": 8.0, "datapath_ns": 7.5, "route_share_pct": 76.0},
                    {"stage": "WB", "period_ns": 6.0, "datapath_ns": 5.5, "route_share_pct": 78.0},
                ]
            }
        )

        self.assertEqual(svg.count(">IF</text>"), 1)
        self.assertEqual(svg.count(">ID</text>"), 1)
        self.assertEqual(svg.count(">EX</text>"), 1)
        self.assertEqual(svg.count(">MEM</text>"), 1)
        self.assertEqual(svg.count(">WB</text>"), 1)
        self.assertLess(svg.index(">IF</text>"), svg.index(">ID</text>"))
        self.assertLess(svg.index(">ID</text>"), svg.index(">EX</text>"))


if __name__ == "__main__":
    unittest.main()
