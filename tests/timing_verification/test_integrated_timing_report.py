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
    render_fmax_benchmark_svg,
    render_physical_delay_stack_svg,
    render_pipeline_breakdown_svg,
    render_resource_utilization_svg,
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
        self.assertIn("side-dashboard", html_text)
        self.assertIn("max-width: 1760px", html_text)
        self.assertIn("minmax(620px, 1fr)", html_text)
        self.assertIn("overflow-x: hidden", html_text)
        self.assertIn('href="#overview"', html_text)
        self.assertIn("kpi-grid", html_text)
        self.assertIn("Automated Root Cause Findings", html_text)
        self.assertIn("Root Cause Severity Mix", html_text)
        self.assertIn("Stage Boundary Timing", html_text)
        self.assertNotIn("Detailed Benchmark Breakdowns", html_text)
        self.assertIn("chart-panel", html_text)
        self.assertIn("data-chart-engine=\"python-svg\"", html_text)
        self.assertIn("<svg", html_text)
        self.assertIn("Self-contained HTML", html_text)

    def test_html_report_promotes_soc_perf_metrics_to_dashboard(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            html_path = Path(temp_dir) / "report.html"
            markdown_text = """# PIPELINE_PERF_REPORT

<!-- SOC_PERF_SECTION:START -->
## SoC Runtime Metrics

### 🚦 Overall Verdict

| Item | Value |
| --- | --- |
| Overall verdict | ✅ PASS |
| Primary SoC bottleneck | soc_perf / demo_fast_io: APB/MMIO stall cycles (50) |
| Scenario count | 1 |
| Latest cache | `.analysis/soc_perf/latest.json` |

### 📊 Scenario Summary

| Scenario/Profile | Verdict | Cycles | Retired | CPI x1000 | SoC Blocked | Worst Latency |
| --- | --- | --- | --- | --- | --- | --- |
| soc_perf / demo_fast_io | ✅ PASS | 1000 | 400 | 2500 | 50 | input_to_visible_done=900 |

### 🧠 Execution And Stall Breakdown

| Scenario/Profile | Window | Cycles | Retired | CPI x1000 | IF Stall | APB Stall | LoadUse | SoC Blocked |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| soc_perf / demo_fast_io | program_runtime | 1000 | 400 | 2500 | 0 | 40 | 2 | 50 |
| soc_perf / demo_fast_io | input_to_visible_done | 900 | 360 | 2500 | 0 | 35 | 2 | 45 |

### 🚌 Bus And Memory Traffic Mix

| Scenario/Profile | Fetch Req | Fetch Wait | Data Req | RAM R | RAM W | MMIO R | MMIO W | MMIO Ratio x1000 | Decode Err | Rsp Err |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| soc_perf / demo_fast_io | 500 | 10 | 200 | 80 | 40 | 30 | 50 | 400 | 0 | 0 |

### ⚡ Interrupt Latency

| Scenario/Profile | Source | Asserts | Assert->Vector | Assert->Trap | Trap->Claim | Claim->Complete | Service |
| --- | --- | --- | --- | --- | --- | --- | --- |
| soc_perf / demo_fast_io | UART_RX | 1 | 0 | 10 | 4 | 3 | 25 |

### 🧪 E2E Latency

| Scenario/Profile | Reset->Ready | External Input Line | Input->Service | Sort->Done | Done->UART Report | Input->Visible Done |
| --- | --- | --- | --- | --- | --- | --- |
| soc_perf / demo_fast_io | 100 | 640 | 12 | 200 | 32 | 900 |

### 🧮 Derived Efficiency

| Scenario/Profile | Pipeline Fmax MHz | Runtime CPI | MIPS |
| --- | --- | --- | --- |
| soc_perf / demo_fast_io | 100.000 | 2.500 | 40.000 |

### Regression Thresholds

| Status | Scenario | Metric | Current | Baseline | Detail |
| --- | --- | --- | --- | --- | --- |
| ✅ PASS | all | thresholds | within policy | baseline.json | No configured threshold was exceeded. |

### 🧾 Pipeline RAW Events

| Scenario/Profile | Branch Taken | Branch Flush | JAL | JALR | Pipe Flush | Pipe Stall | CSR | Load | Store | ALU | Branch | Illegal | MRET | IF Valid | ID Valid | EX Valid | MEM Valid | WB Valid |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| soc_perf / demo_fast_io | 3 | 1 | 2 | 1 | 4 | 50 | 8 | 20 | 12 | 120 | 10 | 0 | 12 | 900 | 880 | 870 | 860 | 850 |

### 🧾 Data Bus RAW Wait

| Scenario/Profile | Wait | Read Wait | Write Wait | RAM Wait | MMIO Wait | Busy | Idle | Rsp Err | Decode Err Addr | Rsp Err Addr | Last Addr | Last WData | Last RData |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| soc_perf / demo_fast_io | 60 | 40 | 20 | 8 | 52 | 210 | 790 | 0 | 0 | 0 | 0x10000000 | 0x1 | 0x2 |

### 🧾 APB Target RAW Wait

| Scenario/Profile | Target | Wait | Setup | Enable | PSEL | PENABLE | PREADY Wait |
| --- | --- | --- | --- | --- | --- | --- | --- |
| soc_perf / demo_fast_io | UART | 30 | 20 | 20 | 20 | 20 | 10 |
| soc_perf / demo_fast_io | INTC | 25 | 18 | 18 | 18 | 18 | 7 |

### 🧾 APB Register Access RAW

| Scenario/Profile | Target | Register | Reads | Writes | Wait | PSLVERR | Last WData | Last RData |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| soc_perf / demo_fast_io | INTC | INTC_CLAIM | 12 | 0 | 18 | 0 | 0 | 1 |
| soc_perf / demo_fast_io | UART | UART_STATUS | 20 | 0 | 16 | 0 | 0 | 2 |

### 🧾 Interrupt RAW Timeline

| Scenario/Profile | Source | Assert | Deassert | Pending Set | Pending Clear | Claim | Complete | Masked | Pending Cycles | Line High | In Service | Global Enable | Trap Entry | Trap Exit | MIE Disabled |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| soc_perf / demo_fast_io | UART_RX | 2 | 2 | 2 | 2 | 2 | 2 | 0 | 44 | 30 | 15 |  |  |  |  |
| soc_perf / demo_fast_io | GLOBAL |  |  |  |  |  |  |  |  |  |  | 900 | 12 | 12 | 20 |

### 🧾 Peripheral RAW Status

| Scenario/Profile | Peripheral | RAW Metrics |
| --- | --- | --- |
| soc_perf / demo_fast_io | UART | uart_rx_fifo_max_level=4, uart_tx_fifo_max_level=3, uart_tx_busy_cycles=20 |
| soc_perf / demo_fast_io | SPI | spi_busy_cycles=10, spi_cs_active_cycles=8 |
<!-- SOC_PERF_SECTION:END -->
"""

            write_html_report(html_path, markdown_text, title="PIPELINE_PERF_REPORT")
            html_text = html_path.read_text(encoding="utf-8")

        self.assertIn("SoC Runtime Dashboard", html_text)
        self.assertIn("SoC Execution Windows", html_text)
        self.assertIn("Bus And Memory Traffic", html_text)
        self.assertIn("Interrupt Service Latency", html_text)
        self.assertIn("E2E Scenario Latency", html_text)
        self.assertIn("SoC RAW Metrics Dashboard", html_text)
        self.assertIn("Pipeline RAW Events", html_text)
        self.assertIn("Data Bus RAW Wait", html_text)
        self.assertIn("APB Target RAW Wait", html_text)
        self.assertIn("APB Register Access RAW", html_text)
        self.assertIn("Interrupt RAW Timeline", html_text)
        self.assertIn("Peripheral RAW Status", html_text)
        self.assertIn('href="#soc-raw-dashboard"', html_text)
        self.assertIn("IRQ global enable cycles", html_text)
        self.assertIn('href="#soc-runtime-dashboard"', html_text)
        self.assertIn("SoC MIPS: 40.000", html_text)
        self.assertNotIn("Worst Negative Slack", html_text)

    def test_resource_chart_keeps_program_labels_inside_viewbox(self) -> None:
        svg = render_resource_utilization_svg(
            {
                "resource_points": [
                    {"label": "Full Coverage.mem", "luts": 2525, "registers": 1850},
                    {"label": "Bubble Sort.mem", "luts": 2863, "registers": 2177},
                ]
            }
        )

        self.assertIn('viewBox="0 0 760 250"', svg)
        self.assertIn('x="160"', svg)
        self.assertIn("Full Coverage.mem", svg)
        self.assertIn("Bubble Sort.mem", svg)

    def test_fmax_chart_renders_target_label_as_top_badge(self) -> None:
        svg = render_fmax_benchmark_svg(
            {
                "target_fmax_mhz": 100.0,
                "fmax_points": [
                    {"label": "Full Coverage.mem", "value": 100.09},
                    {"label": "Bubble Sort.mem", "value": 100.02},
                ],
            }
        )

        self.assertIn('y="4"', svg)
        self.assertIn('y="22"', svg)
        self.assertNotIn('<text x="462" y=', svg)
        self.assertIn("Target 100.0 MHz", svg)

    def test_html_report_adds_program_nav_targets(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            html_path = Path(temp_dir) / "report.html"
            markdown_text = """# Demo Report

<!-- PROGRAM_SECTION:full_coverage:START -->
## Full Coverage.mem

### Summary

| Item | Value |
| --- | --- |
| Overall verdict | ⚠️ WARN |
<!-- PROGRAM_SECTION:full_coverage:END -->

<!-- PROGRAM_SECTION:bubble_sort:START -->
## Bubble Sort.mem

### Summary

| Item | Value |
| --- | --- |
| Overall verdict | ⚠️ WARN |
<!-- PROGRAM_SECTION:bubble_sort:END -->
"""

            write_html_report(html_path, markdown_text, title="Demo Report")
            html_text = html_path.read_text(encoding="utf-8")

        self.assertIn('href="#full-coverage"', html_text)
        self.assertIn('href="#bubble-sort"', html_text)
        self.assertIn('id="full-coverage"', html_text)
        self.assertIn('id="bubble-sort"', html_text)

    def test_pipeline_breakdown_renders_every_program_image(self) -> None:
        svg = render_pipeline_breakdown_svg(
            {
                "cycle_points": [
                    {"label": "Full Coverage.mem", "single": 92, "pipeline": 118},
                    {"label": "Bubble Sort.mem", "single": 93, "pipeline": 126},
                ]
            }
        )

        self.assertIn("Full Coverage.mem", svg)
        self.assertIn("Bubble Sort.mem", svg)
        self.assertIn(">118</text>", svg)
        self.assertIn(">126</text>", svg)
        self.assertEqual(svg.count("Total Cycles"), 2)

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

    def test_physical_delay_chart_renders_every_program_image(self) -> None:
        svg = render_physical_delay_stack_svg(
            {
                "stage_rows": [
                    {"program_title": "Full Coverage.mem", "stage": "IF", "period_ns": 5.8, "datapath_ns": 5.4, "route_share_pct": 80.0},
                    {"program_title": "Full Coverage.mem", "stage": "EX", "period_ns": 9.7, "datapath_ns": 9.5, "route_share_pct": 65.0},
                    {"program_title": "Bubble Sort.mem", "stage": "IF", "period_ns": 6.5, "datapath_ns": 6.1, "route_share_pct": 85.0},
                    {"program_title": "Bubble Sort.mem", "stage": "EX", "period_ns": 10.0, "datapath_ns": 9.8, "route_share_pct": 83.0},
                ]
            }
        )

        self.assertIn("Full Coverage.mem", svg)
        self.assertIn("Bubble Sort.mem", svg)
        self.assertEqual(svg.count(">IF</text>"), 2)
        self.assertEqual(svg.count(">EX</text>"), 2)


if __name__ == "__main__":
    unittest.main()
