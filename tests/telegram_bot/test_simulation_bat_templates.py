import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


class SimulationBatchTemplateTests(unittest.TestCase):
    def test_nogui_vivado_options_stay_outside_tclargs(self) -> None:
        script_path = (
            REPO_ROOT
            / "templates"
            / "contexts"
            / "simulation"
            / "adapters"
            / "bat"
            / "sim_run_vivado_nogui.bat"
        )
        script_text = script_path.read_text(encoding="utf-8")

        log_idx = script_text.index('    "-log", $vivadoLogFile,')
        journal_idx = script_text.index('    "-journal", $vivadoJournalFile,')
        notrace_idx = script_text.index('    "-notrace",')
        tclargs_idx = script_text.index('    "-tclargs", $ProjectRoot, $tbTop, $VivadoRoot, $ManifestSrcList, $ManifestTbList, $ManifestIncList, $selectedTb.FullName, $simMoreOptions')

        self.assertLess(log_idx, tclargs_idx)
        self.assertLess(journal_idx, tclargs_idx)
        self.assertLess(notrace_idx, tclargs_idx)

    def test_gui_vivado_options_stay_outside_tclargs(self) -> None:
        script_path = (
            REPO_ROOT
            / "templates"
            / "contexts"
            / "simulation"
            / "adapters"
            / "bat"
            / "sim_run_vivado.bat"
        )
        script_text = script_path.read_text(encoding="utf-8")

        log_idx = script_text.index('    "-log", $vivadoLogFile,')
        journal_idx = script_text.index('    "-journal", $vivadoJournalFile,')
        notrace_idx = script_text.index('    "-notrace",')
        tclargs_idx = script_text.index('    "-tclargs", $ProjectRoot, $tbTop, $VivadoRoot, $ManifestSrcList, $ManifestTbList, $ManifestIncList, $selectedTb.FullName, $simMoreOptions, $promptArgMarker, $promptRequestFile, $promptCloseFile, $promptKeepFile')

        self.assertLess(log_idx, tclargs_idx)
        self.assertLess(journal_idx, tclargs_idx)
        self.assertLess(notrace_idx, tclargs_idx)


if __name__ == "__main__":
    unittest.main()
