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

from riscv_timing_analysis.integrated_report import merge_program_detail_section, shift_markdown_headings, strip_first_markdown_heading
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
            project_name="RISCV_32I_SINGLE",
            artifact_dir=Path("/tmp/single_cycle/full_coverage"),
            report_path=Path("/tmp/SINGLE_CYCLE_OPTIMIZATION_REPORT.md"),
        )

        self.assertIn("- Source project: `RISCV_32I_SINGLE`", detail_text)
        self.assertIn("- Source artifacts: `/tmp/single_cycle/full_coverage`", detail_text)
        self.assertIn("- Standalone report path: `/tmp/SINGLE_CYCLE_OPTIMIZATION_REPORT.md`", detail_text)
        self.assertIn("#### Scope", detail_text)
        self.assertNotIn("# SINGLE_CYCLE Optimization Report", detail_text)


if __name__ == "__main__":
    unittest.main()
