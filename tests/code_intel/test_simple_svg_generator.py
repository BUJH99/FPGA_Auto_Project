import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = (
    REPO_ROOT
    / "templates"
    / "contexts"
    / "code_intel"
    / "adapters"
    / "powershell"
    / "code_generate_simple_svg.ps1"
)


def find_powershell() -> str | None:
    return shutil.which("powershell.exe") or shutil.which("powershell") or shutil.which("pwsh")


def to_powershell_path(path: Path) -> str:
    wslpath = shutil.which("wslpath")
    if wslpath is None:
        return str(path)
    completed = subprocess.run(
        [wslpath, "-w", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if completed.returncode != 0:
        return str(path)
    return completed.stdout.decode("utf-8", errors="replace").strip() or str(path)


class SimpleSvgGeneratorTests(unittest.TestCase):
    def test_package_qualified_port_type_uses_actual_port_name(self) -> None:
        powershell = find_powershell()
        if powershell is None:
            self.skipTest("PowerShell is not available")

        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            verilog_path = temp_root / "ControlUnit.sv"
            output_path = temp_root / "ControlUnit.svg"
            verilog_path.write_text(
                "\n".join(
                    [
                        "module ControlUnit (",
                        "  input logic [31:0] iInstr,",
                        "  output rv32i_pkg::mem_size_e oMemSize,",
                        "  output rv32i_pkg::alu_a_sel_e oAluASel,",
                        "  output logic oTrapReq",
                        ");",
                        "endmodule",
                        "",
                    ]
                ),
                encoding="utf-8",
            )

            completed = subprocess.run(
                [
                    powershell,
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    to_powershell_path(SCRIPT_PATH),
                    "-VerilogFile",
                    to_powershell_path(verilog_path),
                    "-OutputSvg",
                    to_powershell_path(output_path),
                ],
                cwd=str(REPO_ROOT),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            stdout_text = completed.stdout.decode("utf-8", errors="replace")
            stderr_text = completed.stderr.decode("utf-8", errors="replace")
            self.assertEqual(0, completed.returncode, msg=stdout_text + "\n" + stderr_text)
            svg_text = output_path.read_text(encoding="utf-8", errors="replace")
            self.assertIn(">oMemSize</text>", svg_text)
            self.assertIn(">oAluASel</text>", svg_text)
            self.assertNotIn(">rv32i_pkg</text>", svg_text)


if __name__ == "__main__":
    unittest.main()
