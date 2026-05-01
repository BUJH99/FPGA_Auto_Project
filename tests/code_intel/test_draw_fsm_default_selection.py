import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = (
    REPO_ROOT
    / "templates"
    / "contexts"
    / "code_intel"
    / "adapters"
    / "bat"
    / "code_draw_fsm.bat"
)


def find_cmd() -> str | None:
    return shutil.which("cmd.exe") or shutil.which("cmd")


def find_powershell() -> str | None:
    return shutil.which("powershell.exe") or shutil.which("powershell") or shutil.which("pwsh")


def find_windows_node() -> str | None:
    return shutil.which("node.exe")


def to_windows_path(path: Path) -> str:
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


class DrawFsmDefaultSelectionTests(unittest.TestCase):
    def run_draw_fsm(self, project_path: Path, user_input: str) -> subprocess.CompletedProcess[str]:
        cmd = find_cmd()
        powershell = find_powershell()
        node_exe = find_windows_node()
        if cmd is None or powershell is None or node_exe is None:
            self.skipTest("Windows cmd.exe, PowerShell, and node.exe are required")

        return subprocess.run(
            [cmd, "/d", "/c", to_windows_path(SCRIPT_PATH), to_windows_path(project_path)],
            cwd=str(REPO_ROOT),
            input=user_input,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def write_demo_project(self, temp_root: Path) -> Path:
        project_path = temp_root / "demo_project"
        (project_path / "src").mkdir(parents=True)
        (project_path / "tb").mkdir()

        (project_path / "fpga_auto.yml").write_text(
            textwrap.dedent(
                """\
                version: "0"
                project:
                  name: "demo_project"
                hdl:
                  top: "TOP"
                  src_globs:
                    - "src/**/*.sv"
                  tb_globs:
                    - "tb/**/*.sv"
                """
            ),
            encoding="utf-8",
        )

        (project_path / "src" / "TOP.sv").write_text(
            textwrap.dedent(
                """\
                module TOP (
                  input  logic iClk,
                  input  logic iRst,
                  input  logic iReq,
                  output logic oBusy
                );
                  logic Done;

                  WorkerFsm uWorkerFsm (
                    .iClk(iClk),
                    .iRst(iRst),
                    .iReq(iReq),
                    .oBusy(oBusy),
                    .oDone(Done)
                  );
                endmodule
                """
            ),
            encoding="utf-8",
        )

        (project_path / "src" / "WorkerFsm.sv").write_text(
            textwrap.dedent(
                """\
                module WorkerFsm (
                  input  logic iClk,
                  input  logic iRst,
                  input  logic iReq,
                  output logic oBusy,
                  output logic oDone
                );
                  typedef enum logic [1:0] {
                    IDLE,
                    RUN,
                    DONE
                  } state_e;

                  state_e state, state_d;

                  always_ff @(posedge iClk or posedge iRst) begin
                    if (iRst) begin
                      state <= IDLE;
                    end else begin
                      state <= state_d;
                    end
                  end

                  always_comb begin
                    state_d = state;

                    unique case (state)
                      IDLE: begin
                        if (iReq) begin
                          state_d = RUN;
                        end
                      end

                      RUN: begin
                        state_d = DONE;
                      end

                      DONE: begin
                        state_d = IDLE;
                      end

                      default: begin
                        state_d = IDLE;
                      end
                    endcase
                  end

                  assign oBusy = (state != IDLE);
                  assign oDone = (state == DONE);
                endmodule
                """
            ),
            encoding="utf-8",
        )

        return project_path

    def test_empty_selection_uses_detected_fsm_when_top_is_wrapper(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_path = self.write_demo_project(Path(temp_dir))
            completed = self.run_draw_fsm(project_path, "\n")

            stdout_text = completed.stdout
            stderr_text = completed.stderr
            self.assertEqual(0, completed.returncode, msg=stdout_text + "\n" + stderr_text)
            self.assertIn("TOP has no local FSM. Press Enter to use WorkerFsm.", stdout_text)
            self.assertIn("[INFO] Generating FSM diagrams for: WorkerFsm", stdout_text)
            self.assertNotIn("[INFO] Generating FSM diagrams for: TOP", stdout_text)
            self.assertTrue((project_path / "output" / "fsm" / "svg" / "WorkerFsm_fsm.svg").exists())

    def test_selecting_top_wrapper_reports_hint_instead_of_parser_error(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_path = self.write_demo_project(Path(temp_dir))
            completed = self.run_draw_fsm(project_path, "1\n")

            stdout_text = completed.stdout
            stderr_text = completed.stderr
            self.assertEqual(0, completed.returncode, msg=stdout_text + "\n" + stderr_text)
            self.assertIn("[WARN] TOP has no local FSM. Try WorkerFsm", stdout_text)
            self.assertNotIn("State vars not detected.", stdout_text)
            self.assertNotIn("[WARN] Source-level parse failed for TOP.", stdout_text)


if __name__ == "__main__":
    unittest.main()
