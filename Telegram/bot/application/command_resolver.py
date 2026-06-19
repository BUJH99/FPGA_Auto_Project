from __future__ import annotations

import re
from pathlib import Path
from typing import Callable

from Telegram.bot.domain.models import (
    CommandSpec,
    Config,
    InteractionContract,
    JobRequest,
    job_request_from_command_spec,
)


MENU_USAGE: dict[int, str] = {
    1: "Usage: /task 1 <project> <modules: ALL|1,3,5|module_a,module_b>",
    2: "Usage: /task 2 <project> [--once] [src|tb|tb_only|tb-only]",
    3: "Usage: /task 3 <project> <modules: ALL|1,3,5|module_a,module_b>",
    4: "Usage: /task 4 <project> [Y|N|clean-assets]",
    5: "Usage: /task 5 <project> <folder_idx> <tb_idx> [--close-gui|--keep-gui]",
    6: "Usage: /task 6 <project> <tb_idx>",
    7: "Usage: /task 7 <project> (--all | --tb <name>)",
    8: "Usage: /task 8 <project>",
    9: "Usage: /task 9 <project> [--step N] [--max-signals N] [--html|--no-html]",
    10: "Usage: /task 10 <project>",
    11: "Usage: /task 11 <project>",
    12: "Usage: /task 12 <project>",
    13: "Usage: /task 13 <project> [--auto-program]",
    14: "Usage: /task 14 <project>",
    15: "Usage: /task 15 <project>",
    16: "Usage: /task 16 <project>",
    17: "Usage: /task 17 <project>",
    18: "Usage: /task 18 <project>",
    19: "Usage: /task 19 <project> (--all | --dut <name>) [--force]",
    20: "Usage: /task 20 <project> <folder_idx> <tb_idx>",
    21: "Usage: /task 21 <project>",
    22: "Usage: /task 22 <project> [bit_name|--bit <name-or-path>]",
    23: "Usage: /task 23 <project> [xsa_name|--xsa <name-or-path>]",
    24: "Usage: /task 24 <project> [app_name|--app <name>|--apps a,b|--all-apps] [--platform <name-or-xpfm>]",
    25: "Usage: /task 25 <project> [platform_name|--platform <name-or-xpfm>]",
    26: "Usage: /task 26 <project> [app_name|--app <name>|--apps a,b|--all-apps] [--target hw]",
    27: "Usage: /task 27 <project> [app_name|--app <name>] [--target hw]",
    28: "Usage: /task 28 <project> [app_name|--app <name>|--apps a,b|--all-apps] [--run]",
    29: "Usage: /task 29 <project>",
    30: "Usage: /task 30 <project>",
    31: "Usage: /task 31 <project> [--dest <path>] [--dry-run]",
}

HIERARCHY_SCOPE_ALIASES: dict[str, str] = {
    "src": "src",
    "tb": "tb_only",
    "tb_only": "tb_only",
    "tb-only": "tb_only",
    "tbonly": "tb_only",
}

HIERARCHY_SCOPE_FLAGS: dict[str, str] = {
    "src": "",
    "tb_only": "--tb-only",
}


def default_parse_positive_int(raw: str, label: str) -> tuple[int | None, str | None]:
    if not re.fullmatch(r"\d+", raw.strip()):
        return None, f"{label} must be a positive integer."
    value = int(raw)
    if value <= 0:
        return None, f"{label} must be a positive integer."
    return value, None


def default_parse_module_selection(raw: str) -> tuple[str | None, str | None]:
    value = raw.strip()
    if not value:
        return None, "Module selection cannot be empty."
    if value.upper() == "ALL":
        return "ALL", None
    tokens = [token.strip() for token in value.split(",") if token.strip()]
    if not tokens:
        return None, "Module selection cannot be empty."
    for token in tokens:
        if re.fullmatch(r"\d+", token):
            continue
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_$]*", token):
            continue
        return None, f"Invalid module token: {token}"
    return ",".join(tokens), None


def default_parse_yes_no_token(raw: str) -> bool | None:
    value = raw.strip().lower()
    if value in {"y", "yes", "1", "true", "clean_assets", "clean-assets"}:
        return True
    if value in {"n", "no", "0", "false", ""}:
        return False
    return None


def default_parse_sim_vivado_close_choice(raw: str) -> bool | None:
    value = raw.strip().lower()
    if value == "--close-gui":
        return True
    if value == "--keep-gui":
        return False
    return None


def default_format_stdin(lines: list[str]) -> str | None:
    if not lines:
        return None
    return "".join(f"{line}\r\n" for line in lines)


class CommandResolver:
    def __init__(
        self,
        config: Config,
        *,
        parse_module_selection: Callable[[str], tuple[str | None, str | None]] | None = None,
        parse_positive_int: Callable[[str, str], tuple[int | None, str | None]] | None = None,
        parse_yes_no_token: Callable[[str], bool | None] | None = None,
        parse_sim_vivado_close_choice: Callable[[str], bool | None] | None = None,
        format_stdin: Callable[[list[str]], str | None] | None = None,
    ) -> None:
        self._config = config
        self._parse_module_selection = parse_module_selection or default_parse_module_selection
        self._parse_positive_int = parse_positive_int or default_parse_positive_int
        self._parse_yes_no_token = parse_yes_no_token or default_parse_yes_no_token
        self._parse_sim_vivado_close_choice = parse_sim_vivado_close_choice or default_parse_sim_vivado_close_choice
        self._format_stdin = format_stdin or default_format_stdin

    def build_menu_invocation(
        self,
        menu_no: int,
        project_path: Path,
        extra_tokens: list[str],
        command_id: str,
    ) -> tuple[JobRequest | None, str | None]:
        spec, error = self.build_menu_command_spec(menu_no, project_path, extra_tokens, command_id)
        if error:
            return None, error
        if spec is None:
            return None, "Failed to build command spec."
        return job_request_from_command_spec(spec), None

    def build_menu_command_spec(
        self,
        menu_no: int,
        project_path: Path,
        extra_tokens: list[str],
        command_id: str,
    ) -> tuple[CommandSpec | None, str | None]:
        entry = self._config.menu_registry.get(menu_no)
        if entry is None:
            return None, f"Menu {menu_no} is not available in MAIN.bat mapping."

        if not entry.script_path.exists():
            return None, f"Mapped script not found for menu {menu_no}: {entry.script_path}"

        script_args: list[str] = [str(project_path)]
        stdin_lines: list[str] = []
        tokens = [t for t in extra_tokens if t.strip()]
        sim_vivado_close_gui: bool | None = None
        usage = MENU_USAGE.get(menu_no, f"Usage: /task {menu_no} <project> [args...]")
        metadata: dict[str, object] = {}

        if menu_no in {1, 3}:
            if not tokens:
                return None, usage
            modules, err = self._parse_module_selection(" ".join(tokens))
            if err:
                return None, f"{usage}\n{err}"
            stdin_lines.extend([modules or "", ""])

        elif menu_no == 2:
            scope_flag = "src"
            flags: list[str] = []

            for token in tokens:
                lower = token.lower()
                normalized_scope = HIERARCHY_SCOPE_ALIASES.get(lower)
                if normalized_scope:
                    if scope_flag and scope_flag != "src":
                        return None, f"{usage}\nOnly one scope can be specified."
                    scope_flag = normalized_scope
                elif lower in {"--once", "--tb-only"}:
                    flags.append(lower)
                else:
                    return None, usage

            scope_flag_cli = HIERARCHY_SCOPE_FLAGS.get(scope_flag, "")
            if scope_flag_cli and scope_flag_cli not in flags:
                flags.append(scope_flag_cli)

            if "--once" not in flags:
                flags.insert(0, "--once")
            metadata["hierarchy_scope"] = scope_flag
            script_args.extend(flags)

        elif menu_no == 4:
            if len(tokens) > 1:
                return None, usage
            if not tokens:
                script_args.append("N")
                metadata["clean_assets"] = False
            else:
                decision = self._parse_yes_no_token(tokens[0])
                if decision is None:
                    return None, usage
                metadata["clean_assets"] = bool(decision)
                script_args.append("Y" if decision else "N")
            stdin_lines.append("")

        elif menu_no == 5:
            if len(tokens) < 2 or len(tokens) > 3:
                return None, usage
            folder_idx, err = self._parse_positive_int(tokens[0], "folder_idx")
            if err:
                return None, f"{usage}\n{err}"
            tb_idx, err = self._parse_positive_int(tokens[1], "tb_idx")
            if err:
                return None, f"{usage}\n{err}"
            sim_vivado_close_gui = True
            if len(tokens) == 3:
                parsed_choice = self._parse_sim_vivado_close_choice(tokens[2])
                if parsed_choice is None:
                    return None, f"{usage}\nclose-gui option must be --close-gui or --keep-gui."
                sim_vivado_close_gui = parsed_choice
            metadata["folder_idx"] = int(folder_idx)
            metadata["tb_idx"] = int(tb_idx)
            stdin_lines.extend([str(folder_idx), str(tb_idx)])

        elif menu_no == 20:
            if len(tokens) != 2:
                return None, usage
            folder_idx, err = self._parse_positive_int(tokens[0], "folder_idx")
            if err:
                return None, f"{usage}\n{err}"
            tb_idx, err = self._parse_positive_int(tokens[1], "tb_idx")
            if err:
                return None, f"{usage}\n{err}"
            metadata["folder_idx"] = int(folder_idx)
            metadata["tb_idx"] = int(tb_idx)
            stdin_lines.extend([str(folder_idx), str(tb_idx)])

        elif menu_no == 6:
            if len(tokens) != 1:
                return None, usage
            tb_idx, err = self._parse_positive_int(tokens[0], "tb_idx")
            if err:
                return None, f"{usage}\n{err}"
            metadata["tb_idx"] = int(tb_idx)
            stdin_lines.extend([str(tb_idx), ""])

        elif menu_no == 7:
            mode_all = False
            tb_name = ""
            i = 0
            while i < len(tokens):
                token = tokens[i]
                lower = token.lower()
                if lower == "--all":
                    mode_all = True
                elif lower == "--tb":
                    if i + 1 >= len(tokens):
                        return None, usage
                    tb_name = tokens[i + 1]
                    i += 1
                elif lower.startswith("--tb="):
                    tb_name = token.split("=", 1)[1].strip()
                elif lower == "--no-pause":
                    pass
                else:
                    return None, usage
                i += 1

            if mode_all and tb_name:
                return None, f"{usage}\nUse either --all or --tb, not both."
            if not mode_all and not tb_name:
                return None, usage
            if mode_all:
                metadata["sim_mode"] = "all"
                script_args.append("--all")
            else:
                metadata["sim_mode"] = "named"
                metadata["tb_name"] = tb_name
                script_args.extend(["--tb", tb_name])
            script_args.append("--no-pause")

        elif menu_no == 8:
            if any(t.lower() != "--no-pause" for t in tokens):
                return None, usage
            script_args.append("--no-pause")

        elif menu_no == 9:
            i = 0
            while i < len(tokens):
                token = tokens[i]
                lower = token.lower()
                if lower in {"--html", "--no-html", "--no-pause"}:
                    script_args.append(lower)
                elif lower in {"--step", "--max-signals"}:
                    if i + 1 >= len(tokens):
                        return None, usage
                    value, err = self._parse_positive_int(tokens[i + 1], lower)
                    if err:
                        return None, f"{usage}\n{err}"
                    metadata[lower.lstrip("-").replace("-", "_")] = int(value)
                    script_args.extend([lower, str(value)])
                    i += 1
                elif lower.startswith("--step="):
                    value, err = self._parse_positive_int(token.split("=", 1)[1], "--step")
                    if err:
                        return None, f"{usage}\n{err}"
                    metadata["step"] = int(value)
                    script_args.extend(["--step", str(value)])
                elif lower.startswith("--max-signals="):
                    value, err = self._parse_positive_int(token.split("=", 1)[1], "--max-signals")
                    if err:
                        return None, f"{usage}\n{err}"
                    metadata["max_signals"] = int(value)
                    script_args.extend(["--max-signals", str(value)])
                else:
                    return None, usage
                i += 1
            if "--no-pause" not in [a.lower() for a in script_args]:
                script_args.append("--no-pause")

        elif menu_no in {10, 11, 12, 14, 15, 18, 29}:
            if tokens:
                return None, usage
            stdin_lines.append("")

        elif menu_no == 13:
            has_auto_program = False
            for token in tokens:
                lower = token.lower()
                if lower == "--auto-program":
                    has_auto_program = True
                    script_args.append("--auto-program")
                elif lower == "--no-pause":
                    script_args.append("--no-pause")
                else:
                    return None, usage
            if "--no-pause" not in [a.lower() for a in script_args]:
                script_args.append("--no-pause")
            if not has_auto_program:
                stdin_lines.append("N")
            metadata["auto_program"] = has_auto_program

        elif menu_no == 16:
            if any(t.lower() != "--no-pause" for t in tokens):
                return None, usage
            script_args.append("--no-pause")

        elif menu_no == 17:
            if tokens:
                return None, usage

        elif menu_no == 19:
            apply_all = False
            dut_name = ""
            force_write = False
            i = 0
            while i < len(tokens):
                token = tokens[i]
                lower = token.lower()
                if lower == "--all":
                    apply_all = True
                elif lower == "--dut":
                    if i + 1 >= len(tokens):
                        return None, usage
                    dut_name = tokens[i + 1]
                    i += 1
                elif lower.startswith("--dut="):
                    dut_name = token.split("=", 1)[1].strip()
                elif lower == "--force":
                    force_write = True
                elif lower == "--no-pause":
                    pass
                else:
                    return None, usage
                i += 1
            if apply_all and dut_name:
                return None, f"{usage}\nUse either --all or --dut, not both."
            if not apply_all and not dut_name:
                return None, usage
            if apply_all:
                metadata["tb_scaffold_mode"] = "all"
                script_args.append("--all")
            else:
                metadata["tb_scaffold_mode"] = "named"
                metadata["dut_name"] = dut_name
                script_args.extend(["--dut", dut_name])
            if force_write:
                metadata["force"] = True
                script_args.append("--force")
            script_args.append("--no-pause")

        elif menu_no == 21:
            if tokens:
                return None, usage

        elif menu_no == 22:
            i = 0
            bit_selector = ""
            while i < len(tokens):
                token = tokens[i]
                lower = token.lower()
                if lower == "--no-pause":
                    pass
                elif lower in {"--bit", "--bitstream"}:
                    if i + 1 >= len(tokens):
                        return None, usage
                    bit_selector = tokens[i + 1]
                    i += 1
                elif lower.startswith("--bit="):
                    bit_selector = token.split("=", 1)[1].strip()
                elif lower.startswith("--bitstream="):
                    bit_selector = token.split("=", 1)[1].strip()
                elif not bit_selector:
                    bit_selector = token
                else:
                    return None, usage
                i += 1
            if bit_selector:
                metadata["bit"] = bit_selector
                script_args.extend(["--bit", bit_selector])

        elif menu_no == 23:
            i = 0
            xsa_selector = ""
            while i < len(tokens):
                token = tokens[i]
                lower = token.lower()
                if lower == "--no-pause":
                    pass
                elif lower == "--xsa":
                    if i + 1 >= len(tokens):
                        return None, usage
                    xsa_selector = tokens[i + 1]
                    i += 1
                elif lower.startswith("--xsa="):
                    xsa_selector = token.split("=", 1)[1].strip()
                elif not xsa_selector:
                    xsa_selector = token
                else:
                    return None, usage
                i += 1
            if xsa_selector:
                metadata["xsa"] = xsa_selector
                script_args.extend(["--xsa", xsa_selector])

        elif menu_no == 25:
            i = 0
            platform_selector = ""
            while i < len(tokens):
                token = tokens[i]
                lower = token.lower()
                if lower == "--no-pause":
                    pass
                elif lower == "--platform":
                    if i + 1 >= len(tokens):
                        return None, usage
                    platform_selector = tokens[i + 1]
                    i += 1
                elif lower.startswith("--platform="):
                    platform_selector = token.split("=", 1)[1].strip()
                elif not platform_selector:
                    platform_selector = token
                else:
                    return None, usage
                i += 1
            if platform_selector:
                metadata["platform"] = platform_selector
                script_args.extend(["--platform", platform_selector])

        elif menu_no in {24, 26, 27}:
            i = 0
            app_name = ""
            app_names = ""
            all_apps = False
            platform_selector = ""
            target = ""
            while i < len(tokens):
                token = tokens[i]
                lower = token.lower()
                if lower == "--no-pause":
                    pass
                elif lower == "--app":
                    if i + 1 >= len(tokens):
                        return None, usage
                    app_name = tokens[i + 1]
                    i += 1
                elif lower.startswith("--app="):
                    app_name = token.split("=", 1)[1].strip()
                elif lower == "--apps" and menu_no in {24, 26}:
                    if i + 1 >= len(tokens):
                        return None, usage
                    app_names = tokens[i + 1]
                    i += 1
                elif lower.startswith("--apps=") and menu_no in {24, 26}:
                    app_names = token.split("=", 1)[1].strip()
                elif lower == "--all-apps" and menu_no in {24, 26}:
                    all_apps = True
                elif lower == "--platform" and menu_no == 24:
                    if i + 1 >= len(tokens):
                        return None, usage
                    platform_selector = tokens[i + 1]
                    i += 1
                elif lower.startswith("--platform=") and menu_no == 24:
                    platform_selector = token.split("=", 1)[1].strip()
                elif lower == "--target" and menu_no in {26, 27}:
                    if i + 1 >= len(tokens):
                        return None, usage
                    target = tokens[i + 1]
                    i += 1
                elif lower.startswith("--target=") and menu_no in {26, 27}:
                    target = token.split("=", 1)[1].strip()
                elif not app_name:
                    app_name = token
                else:
                    return None, usage
                i += 1
            if sum(1 for value in (app_name, app_names, all_apps) if value) > 1:
                return None, usage
            if app_name:
                metadata["app_name"] = app_name
                script_args.extend(["--app", app_name])
            if app_names:
                metadata["app_names"] = app_names
                script_args.extend(["--apps", app_names])
            if all_apps:
                metadata["all_apps"] = True
                script_args.append("--all-apps")
            if platform_selector:
                metadata["platform"] = platform_selector
                script_args.extend(["--platform", platform_selector])
            if target:
                metadata["target"] = target
                script_args.extend(["--target", target])

        elif menu_no == 28:
            i = 0
            app_name = ""
            app_names = ""
            all_apps = False
            run_requested = False
            while i < len(tokens):
                token = tokens[i]
                lower = token.lower()
                if lower == "--no-pause":
                    pass
                elif lower == "--run":
                    run_requested = True
                elif lower == "--app":
                    if i + 1 >= len(tokens):
                        return None, usage
                    app_name = tokens[i + 1]
                    i += 1
                elif lower.startswith("--app="):
                    app_name = token.split("=", 1)[1].strip()
                elif lower == "--apps":
                    if i + 1 >= len(tokens):
                        return None, usage
                    app_names = tokens[i + 1]
                    i += 1
                elif lower.startswith("--apps="):
                    app_names = token.split("=", 1)[1].strip()
                elif lower == "--all-apps":
                    all_apps = True
                elif not app_name:
                    app_name = token
                else:
                    return None, usage
                i += 1
            if sum(1 for value in (app_name, app_names, all_apps) if value) > 1:
                return None, usage
            if app_name:
                metadata["app_name"] = app_name
                script_args.extend(["--app", app_name])
            if app_names:
                metadata["app_names"] = app_names
                script_args.extend(["--apps", app_names])
            if all_apps:
                metadata["all_apps"] = True
                script_args.append("--all-apps")
            if run_requested:
                metadata["run"] = True
                script_args.append("--run")

        elif menu_no == 30:
            if any(t.lower() != "--no-pause" for t in tokens):
                return None, usage
            script_args.append("--no-pause")

        elif menu_no == 31:
            script_args.extend(tokens)

        else:
            return None, f"Menu {menu_no} is not supported."

        stdin_text = self._format_stdin(stdin_lines)
        artifact_roots = (project_path / "log", project_path / "output")
        if menu_no in {5, 20}:
            artifact_roots = (project_path / "tb",) + artifact_roots

        return (
            CommandSpec(
                command_id=command_id,
                menu_no=menu_no,
                project_name=project_path.name,
                script_path=entry.script_path,
                cwd=self._config.automation_repo_root,
                args=tuple(script_args),
                stdin_text=stdin_text,
                artifact_roots=artifact_roots,
                result_kind=self._result_kind_for_command(command_id, menu_no),
                interaction_contract=self._interaction_contract_for_command(command_id, menu_no),
                timeout_policy="default",
                sim_vivado_close_gui=sim_vivado_close_gui,
                metadata=metadata,
            ),
            None,
        )

    def build_setup_project_invocation(
        self,
        project_name: str,
        hdl_ext: str,
    ) -> tuple[JobRequest | None, str | None]:
        spec, error = self.build_setup_project_spec(project_name, hdl_ext)
        if error:
            return None, error
        if spec is None:
            return None, "Failed to build setup command spec."
        return job_request_from_command_spec(spec), None

    def build_setup_project_spec(
        self,
        project_name: str,
        hdl_ext: str,
    ) -> tuple[CommandSpec | None, str | None]:
        name = project_name.strip()
        if not name:
            return None, "Usage: /setup_project <name> [v|sv]"
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
            return None, "Project name can only contain letters, digits, underscore, dot, and dash."

        ext = hdl_ext.strip().lower() if hdl_ext else "v"
        if ext not in {"v", "sv"}:
            return None, "Usage: /setup_project <name> [v|sv]"

        script_path = (
            self._config.automation_templates_root
            / "contexts"
            / "project_bootstrap"
            / "adapters"
            / "bat"
            / "project_create.bat"
        ).resolve()
        if not script_path.exists():
            return None, f"Setup script not found: {script_path}"

        spec = CommandSpec(
            command_id="setup_project",
            menu_no=None,
            project_name=name,
            script_path=script_path,
            cwd=self._config.automation_repo_root,
            args=(name, f"--hdl-ext={ext}", "--no-pause"),
            stdin_text=None,
            artifact_roots=(self._config.project_root / name,),
            result_kind="project_setup",
            interaction_contract=InteractionContract(
                input_mode="direct_execute",
                selection_source="project_name",
                selection_cardinality="single",
                completion_policy="status_artifacts",
            ),
            timeout_policy="default",
            metadata={"hdl_ext": ext},
        )
        return spec, None

    def _result_kind_for_command(self, command_id: str, menu_no: int | None) -> str:
        if command_id in {"schematic", "fsm", "vcd_svg", "vcd_wavedrom"}:
            return "diagram"
        if command_id == "hierarchy":
            return "hierarchy"
        if command_id == "doctor" or menu_no == 21:
            return "doctor"
        if menu_no in {22, 23, 24, 25, 26, 27, 28} or command_id.startswith("vitis"):
            return "vitis"
        if command_id == "sim_vivado" or menu_no == 20:
            return "sim_vivado"
        if command_id in {"report_html", "report_docs", "presentation"}:
            return "report"
        if command_id in {"build", "build_program", "program", "vivado_gui", "finalize_bd", "retarget_ip"} or menu_no in {29, 30}:
            return "build"
        if menu_no == 31:
            return "remote_sync"
        if menu_no == 6:
            return "simulation_report"
        return "default"

    def _interaction_contract_for_command(self, command_id: str, menu_no: int | None) -> InteractionContract:
        if command_id in {
            "build",
            "program",
            "build_program",
            "vivado_gui",
            "finalize_bd",
            "retarget_ip",
            "report_html",
            "report_docs",
            "vcd_svg",
            "open_presentation",
            "setup_project",
            "doctor",
            "vitis",
        } or menu_no in {29, 30, 31}:
            return InteractionContract(
                input_mode="direct_execute",
                selection_source="project",
                selection_cardinality="single",
                completion_policy="status_artifacts",
            )
        if menu_no in {22, 23, 24, 25, 26, 27, 28} or command_id.startswith("vitis"):
            return InteractionContract(
                input_mode="direct_execute",
                selection_source="project",
                selection_cardinality="single",
                progress_policy="long_running",
                completion_policy="status_artifacts",
            )
        if command_id in {"schematic", "fsm"}:
            return InteractionContract(
                input_mode="multi_select_modules",
                selection_source="module_catalog",
                selection_cardinality="multi",
                completion_policy="status_artifacts",
            )
        if command_id == "hierarchy":
            return InteractionContract(
                input_mode="scope_select",
                selection_source="hierarchy_scope",
                selection_cardinality="single",
                followup_policy="tb_folder_select",
                completion_policy="status_artifacts",
            )
        if command_id == "sim_vivado" or menu_no == 20:
            return InteractionContract(
                input_mode="tb_folder_select",
                selection_source="tb_folder_then_tb",
                selection_cardinality="single",
                progress_policy="long_running",
                completion_policy="status_artifacts_log",
            )
        if command_id == "sim_auto_report":
            return InteractionContract(
                input_mode="tb_select",
                selection_source="tb_entry",
                selection_cardinality="single",
                progress_policy="long_running",
                completion_policy="status_artifacts",
            )
        if command_id in {"sim_iverilog", "tb_scaffold"}:
            return InteractionContract(
                input_mode="toggle_or_named_target",
                selection_source="flags_or_name",
                selection_cardinality="single",
                completion_policy="status_artifacts",
            )
        if command_id == "presentation":
            return InteractionContract(
                input_mode="optional_confirmation",
                selection_source="clean_assets",
                selection_cardinality="single",
                confirmation_policy="optional",
                completion_policy="status_artifacts",
            )
        return InteractionContract()
