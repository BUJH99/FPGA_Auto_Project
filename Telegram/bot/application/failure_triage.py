from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

from Telegram.bot.adapters.filesystem_evidence_reader import FilesystemEvidenceReader
from Telegram.bot.domain.models import ExecutionResult

if TYPE_CHECKING:
    from Telegram.bot.application.result_collectors import CollectorContext


@dataclass(frozen=True)
class FailureFinding:
    category: str
    title: str
    summary: str
    actions: tuple[str, ...]
    evidence: tuple[str, ...] = ()
    source: str = "text"


def build_failure_triage(
    result: ExecutionResult,
    context: "CollectorContext",
    reader: FilesystemEvidenceReader | None = None,
) -> dict[str, object] | None:
    if not _needs_failure_triage(result):
        return None

    evidence_reader = reader or FilesystemEvidenceReader()
    if result.timed_out or str(result.status).lower() == "timeout":
        return _to_payload(
            FailureFinding(
                category="timeout",
                title="Execution timed out",
                summary="The command exceeded the allowed runtime and was terminated before it could finish.",
                actions=(
                    "Open the attached run log and check the last active stage.",
                    "Retry after fixing the blocking stage, or increase the timeout if this run is expected to be long.",
                ),
                evidence=_trim_evidence(result.raw_output_tail),
                source="timeout",
            )
        )

    summary_payload = result.structured_payload.get("summary")
    if isinstance(summary_payload, dict):
        finding = _build_summary_finding(summary_payload)
        if finding is not None:
            return _to_payload(finding)

    lines = _collect_signal_lines(result, context, evidence_reader)
    finding = _match_text_finding(lines)
    if finding is not None:
        return _to_payload(finding)

    return _to_payload(_build_generic_finding(result, context, lines))


def _needs_failure_triage(result: ExecutionResult) -> bool:
    status = str(result.status or "").strip().lower()
    if result.timed_out or status == "timeout":
        return True
    if result.return_code != 0:
        return True
    summary_payload = result.structured_payload.get("summary")
    if isinstance(summary_payload, dict):
        return str(summary_payload.get("status", "")).strip().lower() == "failed"
    return status in {"fail", "failed", "error"}


def _build_summary_finding(summary: dict[str, object]) -> FailureFinding | None:
    tool = str(summary.get("tool", "")).strip().lower()
    summary_type = str(summary.get("type", "")).strip().lower()
    status = str(summary.get("status", "")).strip().lower()
    if status != "failed":
        return None

    if tool == "vivado_build" or summary_type == "build_summary":
        quality_gate = summary.get("qualityGate")
        if isinstance(quality_gate, dict):
            timing = quality_gate.get("timing")
            if isinstance(timing, dict) and str(timing.get("status", "")).strip().lower() == "failed":
                wns = timing.get("wnsNs")
                evidence = (f"qualityGate.timing.status=failed (wns={wns})",)
                return FailureFinding(
                    category="timing_violation",
                    title="Timing closure failed",
                    summary="Vivado generated outputs, but the timing quality gate failed.",
                    actions=(
                        "Open the timing report and inspect the worst failing paths.",
                        "Adjust clocks, constraints, or the critical RTL path, then rerun the build.",
                    ),
                    evidence=evidence,
                    source="summary",
                )
            power = quality_gate.get("power")
            if isinstance(power, dict) and str(power.get("status", "")).strip().lower() == "failed":
                total_power = power.get("totalOnChipPowerW")
                evidence = (f"qualityGate.power.status=failed (totalOnChipPowerW={total_power})",)
                return FailureFinding(
                    category="power_limit_exceeded",
                    title="Power quality gate failed",
                    summary="Vivado reported power above the configured quality threshold.",
                    actions=(
                        "Inspect the generated power report to find the dominant blocks.",
                        "Reduce switching activity or relax the power target before rerunning the build.",
                    ),
                    evidence=evidence,
                    source="summary",
                )
            bitstream = quality_gate.get("bitstream")
            if isinstance(bitstream, dict) and str(bitstream.get("status", "")).strip().lower() in {"missing", "failed"}:
                count = bitstream.get("count", 0)
                evidence = (f"qualityGate.bitstream.status={bitstream.get('status')} (count={count})",)
                return FailureFinding(
                    category="bitstream_missing",
                    title="Bitstream was not generated",
                    summary="The build finished in a failed state because no `.bit` output was produced.",
                    actions=(
                        "Open the build log and inspect the synthesis/implementation failure just before bitstream generation.",
                        "Fix the blocking Vivado error and rerun the build flow.",
                    ),
                    evidence=evidence,
                    source="summary",
                )

        details = summary.get("details")
        if isinstance(details, dict):
            step_results = details.get("stepResults")
            if isinstance(step_results, list):
                for row in step_results:
                    if not isinstance(row, dict):
                        continue
                    if str(row.get("name", "")).strip().lower() != "build":
                        continue
                    if str(row.get("status", "")).strip().lower() == "failed":
                        return FailureFinding(
                            category="vivado_build_failed",
                            title="Vivado build step failed",
                            summary="The main Vivado build stage exited before producing a clean build result.",
                            actions=(
                                "Open the build log and inspect the last synthesis or implementation error.",
                                "Fix the RTL, XDC, or tool issue that stopped the build, then rerun.",
                            ),
                            evidence=(f"details.stepResults.build=failed (rc={row.get('rc')})",),
                            source="summary",
                        )

    if tool == "simulation_report" or summary_type == "run_summary":
        details = summary.get("details")
        if isinstance(details, dict):
            regression_rows = details.get("regressionRows")
            if isinstance(regression_rows, list):
                for row in regression_rows:
                    if not isinstance(row, dict) or bool(row.get("pass", True)):
                        continue
                    reason = str(row.get("reason", "")).strip().lower()
                    test_name = str(row.get("testName", "")).strip() or "-"
                    if reason == "scoreboard_errors":
                        return FailureFinding(
                            category="simulation_assertion_failed",
                            title="Simulation reported DUT mismatches",
                            summary="The testbench completed, but the ENV report shows scoreboard errors.",
                            actions=(
                                "Inspect the failing testcase and compare DUT outputs against expected behavior.",
                                "Use the sim log or waveform artifacts to trace the mismatch before rerunning.",
                            ),
                            evidence=(f"regressionRows[{test_name}].reason=scoreboard_errors",),
                            source="summary",
                        )
                    if reason == "fatal_or_assert":
                        return FailureFinding(
                            category="simulation_assertion_failed",
                            title="Simulation hit an assertion or $fatal",
                            summary="The testbench raised an assertion or fatal condition during simulation.",
                            actions=(
                                "Open the sim log and inspect the assertion context and call site.",
                                "Fix the TB or DUT condition that triggers the failure, then rerun.",
                            ),
                            evidence=(f"regressionRows[{test_name}].reason=fatal_or_assert",),
                            source="summary",
                        )
                    if reason == "missing_env_report":
                        return FailureFinding(
                            category="simulation_env_report_missing",
                            title="Simulation ended without an ENV report",
                            summary="The sim run did not emit the expected ENV report marker, so completion status is uncertain.",
                            actions=(
                                "Check whether the selected TB prints the standard ENV report line.",
                                "Inspect the sim log for early termination before the normal TB summary.",
                            ),
                            evidence=(f"regressionRows[{test_name}].reason=missing_env_report",),
                            source="summary",
                        )
                    if reason == "vivado_failed":
                        return FailureFinding(
                            category="vivado_sim_failed",
                            title="Vivado simulation execution failed",
                            summary="The simulator did not complete the requested testcase successfully.",
                            actions=(
                                "Inspect the Vivado sim log around compile/elaboration/runtime failure.",
                                "Fix the simulator-side error and rerun the testcase.",
                            ),
                            evidence=(f"regressionRows[{test_name}].reason=vivado_failed",),
                            source="summary",
                        )

    return None


def _collect_signal_lines(
    result: ExecutionResult,
    context: "CollectorContext",
    reader: FilesystemEvidenceReader,
) -> list[str]:
    seen: set[str] = set()
    collected: list[str] = []

    def add_line(raw: object) -> None:
        text = str(raw or "").strip()
        if not text or text in seen:
            return
        seen.add(text)
        collected.append(text)

    def add_lines(rows: object) -> None:
        if isinstance(rows, (list, tuple)):
            for row in rows:
                add_line(row)

    add_lines(result.raw_output_tail[-60:])

    if result.run_log_path is not None and result.run_log_path.exists():
        add_lines(reader.read_log_tail_lines(result.run_log_path, max_bytes=350_000)[-120:])

    excerpt = result.structured_payload.get("vivado_log_excerpt")
    if isinstance(excerpt, list):
        add_lines(excerpt[-120:])

    for log_path in _related_log_paths(result, context, reader):
        if log_path.exists() and log_path.is_file():
            add_lines(reader.read_log_tail_lines(log_path, max_bytes=350_000)[-120:])

    return collected[-200:]


def _related_log_paths(
    result: ExecutionResult,
    context: "CollectorContext",
    reader: FilesystemEvidenceReader,
) -> tuple[Path, ...]:
    project_root = reader.derive_project_root(context.spec.artifact_roots)
    summary = result.structured_payload.get("summary")
    seen: set[Path] = set()
    paths: list[Path] = []

    def add_path(candidate: Path | None) -> None:
        if candidate is None or candidate in seen:
            return
        seen.add(candidate)
        paths.append(candidate)

    raw_vivado_log = result.structured_payload.get("vivado_log_path")
    if isinstance(raw_vivado_log, str):
        add_path(_resolve_maybe_relative_path(raw_vivado_log, project_root))

    for artifact in result.artifacts:
        if artifact.path.suffix.lower() == ".log":
            add_path(artifact.path)

    if isinstance(summary, dict):
        for key in ("logPath", "vivadoLogPath", "buildLogPath", "hierarchyLogPath"):
            details = summary.get("details")
            if isinstance(details, dict):
                add_path(_resolve_maybe_relative_path(details.get(key), project_root or _summary_project_root(summary)))
        artifacts = summary.get("artifacts")
        if isinstance(artifacts, list):
            for artifact in artifacts:
                if not isinstance(artifact, dict):
                    continue
                artifact_path = _resolve_maybe_relative_path(
                    artifact.get("path"),
                    project_root or _summary_project_root(summary),
                )
                if artifact_path is None:
                    continue
                if artifact_path.suffix.lower() == ".log" or "log" in str(artifact.get("kind", "")).lower():
                    add_path(artifact_path)

    return tuple(paths)


def _summary_project_root(summary: dict[str, object]) -> Path | None:
    project_root = str(summary.get("projectRoot", "")).strip()
    return Path(project_root) if project_root else None


def _resolve_maybe_relative_path(raw_value: object, project_root: Path | None) -> Path | None:
    value = str(raw_value or "").strip().strip('"')
    if not value:
        return None
    candidate = Path(value)
    if candidate.is_absolute():
        return candidate
    if project_root is None:
        return None
    return (project_root / candidate).resolve()


def _match_text_finding(lines: list[str]) -> FailureFinding | None:
    checks: tuple[tuple[tuple[str, ...], FailureFinding], ...] = (
        (
            (
                r"vivado executable not found in path",
                r"'vivado' is not recognized",
                r"\"vivado\" is not recognized",
            ),
            FailureFinding(
                category="vivado_missing",
                title="Vivado is not available",
                summary="The automation could not launch the `vivado` executable on this machine.",
                actions=(
                    "Add the Vivado bin directory to PATH, set `VIVADO_BIN`, or launch from an AMD/Xilinx-enabled shell.",
                    "Re-run Toolkit Doctor or `setup_toolkit.bat --check-only` before retrying the flow.",
                ),
            ),
        ),
        (
            (
                r"iverilog not found in path",
                r"'iverilog' is not recognized",
                r"\"iverilog\" is not recognized",
            ),
            FailureFinding(
                category="iverilog_missing",
                title="Iverilog is not available",
                summary="The automation could not find `iverilog`, so compile could not start.",
                actions=(
                    "Install Icarus Verilog and ensure `iverilog` is available on PATH.",
                    "Re-run the same sim command after the tool is visible in the current shell.",
                ),
            ),
        ),
        (
            (
                r"\bvvp not found in path",
                r"'vvp' is not recognized",
                r"\"vvp\" is not recognized",
            ),
            FailureFinding(
                category="vvp_missing",
                title="VVP runtime is not available",
                summary="Compilation may have succeeded, but the `vvp` runtime is missing so execution could not start.",
                actions=(
                    "Install the full Icarus Verilog runtime and ensure `vvp` is on PATH.",
                    "Retry the simulation after confirming both `iverilog` and `vvp` resolve correctly.",
                ),
            ),
        ),
        (
            (
                r"license checkout failed",
                r"failed to obtain a license",
                r"no valid license",
                r"common 17-345",
                r"common 17-301",
            ),
            FailureFinding(
                category="license_issue",
                title="Vivado license checkout failed",
                summary="The flow reached Vivado, but licensing prevented the requested step from running.",
                actions=(
                    "Verify the Xilinx license server or local license configuration for this shell.",
                    "Retry after restoring license access and checking connectivity to the license source.",
                ),
            ),
        ),
        (
            (
                r"manifest context initialization failed",
                r"manifest .* not found",
                r"manifest resolved .* is empty",
                r"manifest parse error",
                r"target project not found",
            ),
            FailureFinding(
                category="manifest_invalid",
                title="Manifest/bootstrap setup failed",
                summary="The run could not build a valid project context from `fpga_auto.yml` and its generated manifest lists.",
                actions=(
                    "Run Toolkit Doctor and fix the reported manifest or project-structure issues first.",
                    "Confirm `fpga_auto.yml`, `src/`, `tb/`, and resolved manifest list files exist and are current.",
                ),
            ),
        ),
        (
            (
                r"selected tb is not declared by manifest",
                r"tb file not found for",
                r"no testbench selected",
                r"resolved no testbench files",
            ),
            FailureFinding(
                category="tb_selection_invalid",
                title="Selected testbench could not be resolved",
                summary="The requested TB was missing on disk or not declared by the manifest-driven TB list.",
                actions=(
                    "Check the selected TB name/folder and verify it is declared by `hdl.tb_globs`.",
                    "If needed, add the TB to the project or refresh the manifest outputs before rerunning.",
                ),
            ),
        ),
        (
            (
                r"syntax error",
                r"malformed statement",
                r"invalid module instantiation",
                r"parse error",
                r"\bvrfc\b.*error",
                r"\bxvlog\b.*error",
                r"\bxelab\b.*error",
            ),
            FailureFinding(
                category="hdl_compile_error",
                title="HDL compile/elaboration error",
                summary="The tool reported a Verilog/SystemVerilog compile problem before the run could complete.",
                actions=(
                    "Open the cited HDL file/line and fix the syntax, undeclared symbol, or elaboration issue.",
                    "Rerun the same simulation/build command once compile is clean.",
                ),
            ),
        ),
        (
            (
                r"cannot open .*\.xdc",
                r"no such file or directory.*\.xdc",
                r"(error|failed|invalid).*(constraint|\.xdc)",
                r"get_ports .* returned empty",
            ),
            FailureFinding(
                category="xdc_issue",
                title="Constraint/XDC issue blocked the flow",
                summary="Vivado reported a constraints-related problem, so synthesis or implementation could not complete cleanly.",
                actions=(
                    "Check that each XDC referenced by the project exists and matches the current top-level ports.",
                    "Fix the missing/invalid constraint file, then rerun the build or simulation flow.",
                ),
            ),
        ),
        (
            (
                r"unable to find the root module",
                r"top module .* not found",
                r"cannot find design unit",
                r"unknown module type",
                r"module .* was not declared",
            ),
            FailureFinding(
                category="top_not_found",
                title="Selected top or TB module was not found",
                summary="Compilation/elaboration could not locate the requested module or program declaration.",
                actions=(
                    "Verify the selected TB/top name matches the actual `module` or `program` declaration in the source.",
                    "If this is a new TB, align the filename/top naming and rerun the same selection.",
                ),
            ),
        ),
        (
            (
                r"env report:\s*checked=\d+\s+errors=\s*[1-9]\d*",
                r"scoreboard mismatches found",
                r"\[assert\]",
                r"\$fatal",
                r"assertion failed",
            ),
            FailureFinding(
                category="simulation_assertion_failed",
                title="Simulation reported DUT mismatches",
                summary="The testbench ran far enough to report scoreboard/assertion failures rather than a launcher problem.",
                actions=(
                    "Inspect the failing testcase summary and nearby assertion lines in the sim log.",
                    "Use the waveform or log artifacts to compare DUT behavior against expected results before rerunning.",
                ),
            ),
        ),
    )

    for patterns, template in checks:
        evidence = _find_matching_lines(lines, patterns)
        if evidence:
            return FailureFinding(
                category=template.category,
                title=template.title,
                summary=template.summary,
                actions=template.actions,
                evidence=evidence,
                source="text",
            )
    return None


def _find_matching_lines(lines: list[str], patterns: tuple[str, ...]) -> tuple[str, ...]:
    compiled = [re.compile(pattern, re.IGNORECASE) for pattern in patterns]
    matches: list[str] = []
    for line in lines:
        if any(regex.search(line) for regex in compiled):
            matches.append(line)
        if len(matches) >= 3:
            break
    return tuple(matches)


def _build_generic_finding(
    result: ExecutionResult,
    context: "CollectorContext",
    lines: list[str],
) -> FailureFinding:
    command_id = str(context.spec.command_id or result.command_id or "").strip().lower()
    if command_id in {"build", "build_program", "program", "vivado_gui", "finalize_bd", "retarget_ip"}:
        title = "Vivado flow failed"
        summary = "The Vivado-oriented command exited in a failed state, but no specific root-cause pattern was matched."
    elif command_id == "sim_vivado":
        title = "Vivado simulation failed"
        summary = "The simulation command did not complete successfully, but the log did not match a known failure pattern yet."
    elif command_id == "sim_iverilog":
        title = "Iverilog simulation failed"
        summary = "The Iverilog/VVP run exited with a non-zero code, but no more specific classifier matched the log."
    else:
        title = "Command failed"
        summary = "The command exited with a non-zero result and needs manual log inspection."

    return FailureFinding(
        category="generic_failure",
        title=title,
        summary=summary,
        actions=(
            "Open the attached run log and inspect the last 50-100 lines around the failure.",
            "Re-run Toolkit Doctor before retrying if the failure may be environment or project-setup related.",
        ),
        evidence=_trim_evidence(lines[-3:]),
        source="generic",
    )


def _trim_evidence(rows: object) -> tuple[str, ...]:
    if not isinstance(rows, (list, tuple)):
        return ()
    values = [str(row).strip() for row in rows if str(row).strip()]
    return tuple(values[-3:])


def _to_payload(finding: FailureFinding) -> dict[str, object]:
    return {
        "category": finding.category,
        "title": finding.title,
        "summary": finding.summary,
        "actions": list(finding.actions),
        "evidence": list(finding.evidence),
        "source": finding.source,
    }
