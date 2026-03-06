#!/usr/bin/env python3
"""Generate module verification presentation HTML."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

try:
    from jinja2 import Environment, FileSystemLoader
except Exception as exc:  # pragma: no cover
    print("[ERROR] Jinja2 is required. Install with: python -m pip install jinja2", file=sys.stderr)
    print(f"[ERROR] Import detail: {exc}", file=sys.stderr)
    sys.exit(2)


TEXT_DECODINGS: Tuple[str, ...] = ("utf-8-sig", "utf-8", "cp949", "euc-kr")
RTL_SUFFIXES = {".v", ".sv"}
TB_SUFFIXES = {".v", ".sv", ".svh"}
COLORS = ("blue", "green", "amber", "purple", "teal", "rose")


@dataclass
class ModuleInfo:
    name: str
    file_path: Path
    text: str
    ports: List[Dict[str, str]] = field(default_factory=list)
    internals: List[Dict[str, str]] = field(default_factory=list)
    children: List[str] = field(default_factory=list)
    description: str = "Auto-generated module summary."
    fsm_states: List[str] = field(default_factory=list)


@dataclass
class TbScaffold:
    hint_name: str
    root: Path
    transaction: Optional[Path]
    generator: Optional[Path]
    driver: Optional[Path]
    monitor: Optional[Path]
    environment: Optional[Path]
    coverage: Optional[Path]
    scoreboard: Optional[Path]
    base_test: Optional[Path]
    tests: List[Path]
    interface: Optional[Path] = None


def read_text(path: Path) -> str:
    data = path.read_bytes()
    for enc in TEXT_DECODINGS:
        try:
            return data.decode(enc)
        except UnicodeDecodeError:
            continue
    return data.decode("latin1", errors="ignore")


def normalize(text: str) -> str:
    return re.sub(r"[^a-z0-9]", "", str(text or "").lower())


def relpath_posix(path: Path, root: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except Exception:
        return path.as_posix()


def parse_decl_names(fragment: str) -> List[str]:
    text = strip_verilog_comments(fragment)
    text = re.sub(r"\[[^\]]+\]", " ", text)
    text = re.sub(
        r"\b(?:wire|reg|logic|signed|unsigned|var|const|static|input|output|inout)\b",
        " ",
        text,
        flags=re.I,
    )
    out = []
    for part in text.split(","):
        part = part.split("=")[0].strip()
        m = re.search(r"([A-Za-z_][A-Za-z0-9_$]*)$", part)
        if m:
            out.append(m.group(1))
    uniq = []
    seen = set()
    for name in out:
        key = name.lower()
        if key in seen:
            continue
        seen.add(key)
        uniq.append(name)
    return uniq


def strip_verilog_comments(fragment: str) -> str:
    text = re.sub(r"/\*.*?\*/", " ", fragment, flags=re.S)
    text = re.sub(r"//.*$", "", text, flags=re.M)
    return text


def split_top_level_commas(fragment: str) -> List[str]:
    items: List[str] = []
    buf: List[str] = []
    paren = 0
    brack = 0
    brace = 0

    for ch in fragment:
        if ch == "," and paren == 0 and brack == 0 and brace == 0:
            item = "".join(buf).strip()
            if item:
                items.append(item)
            buf = []
            continue

        buf.append(ch)
        if ch == "(":
            paren += 1
        elif ch == ")":
            paren = max(paren - 1, 0)
        elif ch == "[":
            brack += 1
        elif ch == "]":
            brack = max(brack - 1, 0)
        elif ch == "{":
            brace += 1
        elif ch == "}":
            brace = max(brace - 1, 0)

    tail = "".join(buf).strip()
    if tail:
        items.append(tail)
    return items


def parse_ansi_ports(module_text: str) -> List[Dict[str, str]]:
    out: List[Dict[str, str]] = []
    header = re.search(
        r"\bmodule\s+[A-Za-z_][A-Za-z0-9_$]*\b(?:\s*#\s*\(.*?\))?\s*\((.*?)\)\s*;",
        module_text,
        flags=re.S,
    )
    if not header:
        return out

    header_text = strip_verilog_comments(header.group(1))
    current_dir: Optional[str] = None
    current_width = "1"

    for item in split_top_level_commas(header_text):
        text = item.strip()
        if not text:
            continue
        dm = re.match(r"^(input|output|inout)\b(.*)$", text, flags=re.I | re.S)
        if dm:
            current_dir = dm.group(1).lower()
            rest = dm.group(2).strip()
            width_m = re.search(r"(\[[^\]]+\])", rest)
            current_width = width_m.group(1) if width_m else "1"
        else:
            rest = text
            width_m = re.search(r"(\[[^\]]+\])", rest)
            if width_m:
                current_width = width_m.group(1)

        if not current_dir:
            continue

        for n in parse_decl_names(rest):
            out.append({"name": n, "dir": current_dir, "width": current_width, "desc": ""})
    return out


def parse_modules(src_files: Sequence[Path]) -> Dict[str, ModuleInfo]:
    modules: Dict[str, ModuleInfo] = {}
    block_re = re.compile(r"(?ms)^\s*module\s+([A-Za-z_][A-Za-z0-9_$]*)\b(.*?^\s*endmodule\b)", flags=re.M)
    for src in src_files:
        text = read_text(src)
        for hit in block_re.finditer(text):
            name = hit.group(1)
            body = hit.group(0)
            ports = parse_ansi_ports(body)

            body_decl_text = body
            header_span = re.search(
                r"(?s)^\s*module\s+[A-Za-z_][A-Za-z0-9_$]*\b(?:\s*#\s*\(.*?\))?\s*\(.*?\)\s*;",
                body,
            )
            if header_span:
                body_decl_text = body[header_span.end() :]

            if not ports:
                for pm in re.finditer(r"(?m)^\s*(input|output|inout)\b([^;]*);", body_decl_text):
                    direction = pm.group(1).lower()
                    rest = strip_verilog_comments(pm.group(2))
                    width_m = re.search(r"(\[[^\]]+\])", rest)
                    width = width_m.group(1) if width_m else "1"
                    for n in parse_decl_names(rest):
                        ports.append({"name": n, "dir": direction, "width": width, "desc": ""})
            if ports:
                dedup = []
                seen_port = set()
                for p in ports:
                    key = p["name"].lower()
                    if key in seen_port:
                        continue
                    seen_port.add(key)
                    dedup.append(p)
                ports = dedup
            port_names = {p["name"].lower() for p in ports}
            internals = []
            for sm in re.finditer(r"(?m)^\s*(wire|reg|logic)\b([^;]*);", body):
                kind = sm.group(1).lower()
                for n in parse_decl_names(sm.group(2)):
                    if n.lower() in port_names:
                        continue
                    internals.append({"name": n, "type": kind, "purpose": ""})
            comments = []
            for line in body.splitlines()[:30]:
                s = line.strip()
                if s.startswith("//") and len(s) > 2:
                    comments.append(s[2:].strip())
                if len(comments) >= 2:
                    break
            fsm = sorted(set(re.findall(r"\b(?:S|ST|STATE)_[A-Za-z0-9_]+\b", body)))[:12]
            modules[name] = ModuleInfo(
                name=name,
                file_path=src,
                text=body,
                ports=ports[:64],
                internals=internals[:48],
                description=" ".join(comments) if comments else "Auto-generated module summary.",
                fsm_states=fsm,
            )
    known = set(modules.keys())
    inst_re = re.compile(r"(?ms)^\s*([A-Za-z_][A-Za-z0-9_$]*)\s*(?:#\s*\(.*?\)\s*)?([A-Za-z_][A-Za-z0-9_$]*)\s*\(", flags=re.M)
    for mod in modules.values():
        seen = set()
        for hit in inst_re.finditer(mod.text):
            child = hit.group(1)
            if child in known and child != mod.name and child.lower() not in seen:
                seen.add(child.lower())
                mod.children.append(child)
    return modules


def choose_top(modules: Dict[str, ModuleInfo]) -> str:
    if "TOP" in modules:
        return "TOP"
    usage = {k: 0 for k in modules}
    for mod in modules.values():
        for c in mod.children:
            if c in usage:
                usage[c] += 1
    roots = sorted([k for k, v in usage.items() if v == 0], key=str.lower)
    if roots:
        return roots[0]
    return sorted(modules.keys(), key=str.lower)[0]


def parse_selection(raw: str, options: Sequence[str], allow_all: bool = False) -> Tuple[List[str], List[str]]:
    if not raw:
        return [], []
    if allow_all and raw.strip().lower() in {"all", "*"}:
        return list(options), []
    lookup = {o.lower(): o for o in options}
    out, err = [], []
    for token in [t.strip() for t in raw.split(",") if t.strip()]:
        if token.isdigit():
            idx = int(token)
            if 1 <= idx <= len(options):
                out.append(options[idx - 1])
            else:
                err.append(token)
        elif token.lower() in lookup:
            out.append(lookup[token.lower()])
        else:
            err.append(token)
    uniq, seen = [], set()
    for x in out:
        if x.lower() in seen:
            continue
        seen.add(x.lower())
        uniq.append(x)
    return uniq, err


def load_manifest(manifest_json: Path, project_root: Path) -> Dict[str, object]:
    payload = json.loads(manifest_json.read_text(encoding="utf-8"))
    errors = payload.get("errors") or []
    if errors:
        raise RuntimeError("Manifest JSON contains errors.")
    resolved = payload.get("resolved") if isinstance(payload.get("resolved"), dict) else {}
    src_rows = resolved.get("src_files") if isinstance(resolved.get("src_files"), list) else []
    tb_rows = resolved.get("tb_files") if isinstance(resolved.get("tb_files"), list) else []

    def to_abs(rows: Sequence[object], allowed: set) -> List[Path]:
        out = []
        for row in rows:
            text = str(row or "").strip()
            if not text:
                continue
            path = Path(text)
            if not path.is_absolute():
                path = (project_root / text).resolve()
            if path.exists() and path.suffix.lower() in allowed:
                out.append(path)
        return sorted(set(out), key=lambda p: str(p).lower())

    src_files = to_abs(src_rows, RTL_SUFFIXES)
    tb_files = to_abs(tb_rows, TB_SUFFIXES)
    cfg = payload.get("config") if isinstance(payload.get("config"), dict) else {}
    hdl = cfg.get("hdl") if isinstance(cfg.get("hdl"), dict) else {}
    top = str(hdl.get("top", "")).strip() if isinstance(hdl.get("top"), str) else ""
    if not src_files:
        raise RuntimeError("Manifest resolved no source files (.v/.sv).")
    return {"top": top, "src_files": src_files, "tb_files": tb_files}


def locate_draw_fsm_cli() -> Optional[Path]:
    script_dir = Path(__file__).resolve().parent
    try:
        templates_root = script_dir.parents[3]
    except IndexError:
        return None
    cli = templates_root / "contexts" / "code_intel" / "adapters" / "cli" / "code_generate_fsm_cli.js"
    return cli if cli.exists() else None


def parse_cli_json_payload(text: str) -> Optional[Dict[str, object]]:
    raw = (text or "").strip()
    if not raw:
        return None
    try:
        payload = json.loads(raw)
        return payload if isinstance(payload, dict) else None
    except Exception:
        pass
    m = re.search(r"(\{[\s\S]*\})", raw)
    if not m:
        return None
    try:
        payload = json.loads(m.group(1))
        return payload if isinstance(payload, dict) else None
    except Exception:
        return None


def dedup_strings(items: Sequence[object]) -> List[str]:
    out: List[str] = []
    seen = set()
    for item in items:
        s = str(item or "").strip()
        if not s:
            continue
        key = s.lower()
        if key in seen:
            continue
        seen.add(key)
        out.append(s)
    return out


def query_fsm_states_from_draw_cli(module: ModuleInfo, cli_path: Optional[Path]) -> List[str]:
    if cli_path is None:
        return []
    node_bin = shutil.which("node")
    if not node_bin:
        return []
    if not module.file_path.exists():
        return []

    cmd = [
        node_bin,
        str(cli_path),
        "--verilog",
        str(module.file_path),
        "--module",
        module.name,
        "--meta-only",
    ]

    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="ignore",
            timeout=20,
            check=False,
        )
    except Exception:
        return []

    payload = parse_cli_json_payload(proc.stdout) or parse_cli_json_payload(proc.stderr)
    if not payload:
        return []
    if not payload.get("ok"):
        return []
    states = payload.get("states")
    if not isinstance(states, list):
        return []
    return dedup_strings(states)


def resolve_fsm_state_map(modules: Dict[str, ModuleInfo], module_order: Sequence[str]) -> Dict[str, List[str]]:
    cli_path = locate_draw_fsm_cli()
    using_cli = bool(cli_path and shutil.which("node"))
    if using_cli:
        print(f"[INFO] FSM detect: Draw FSM parser enabled ({cli_path})")
    else:
        print("[INFO] FSM detect: Draw FSM parser unavailable, using fallback regex states.")

    out: Dict[str, List[str]] = {}
    for name in module_order:
        module = modules[name]
        states = query_fsm_states_from_draw_cli(module, cli_path if using_cli else None)
        if not states:
            states = dedup_strings(module.fsm_states)
        out[name] = states
    return out


def scan_tb_scaffolds(project_root: Path) -> Dict[str, TbScaffold]:
    out: Dict[str, TbScaffold] = {}
    for tb_root in (project_root / "tb", project_root / "TB"):
        if not tb_root.exists():
            continue
        for child in sorted(tb_root.iterdir(), key=lambda p: p.name.lower()):
            if not child.is_dir() or not child.name.lower().endswith("_tb"):
                continue
            tests = sorted((child / "tests").glob("test*.svh"), key=lambda p: p.name.lower())
            if not tests:
                tests = sorted((child / "tests").glob("*.svh"), key=lambda p: p.name.lower())
            tests = dedupe_test_files(tests)
            hint = child.name[:-3]
            # Interface file: look for interface.sv or *_if.sv in root
            iface_candidates = list(child.glob("interface.sv")) + list(child.glob("*_if.sv"))
            iface_path = iface_candidates[0] if iface_candidates else None
            out[normalize(hint)] = TbScaffold(
                hint_name=hint,
                root=child,
                transaction=(child / "objs" / "transaction.svh") if (child / "objs" / "transaction.svh").exists() else None,
                generator=(child / "components" / "generator.svh") if (child / "components" / "generator.svh").exists() else None,
                driver=(child / "components" / "driver.svh") if (child / "components" / "driver.svh").exists() else None,
                monitor=(child / "components" / "monitor.svh") if (child / "components" / "monitor.svh").exists() else None,
                environment=(child / "env" / "environment.svh") if (child / "env" / "environment.svh").exists() else None,
                coverage=(child / "env" / "coverage.svh") if (child / "env" / "coverage.svh").exists() else None,
                scoreboard=(child / "env" / "scoreboard.svh") if (child / "env" / "scoreboard.svh").exists() else None,
                base_test=(child / "tests" / "base_test.svh") if (child / "tests" / "base_test.svh").exists() else None,
                tests=tests,
                interface=iface_path,
            )
    return out


def resolve_scaffold_mapping(
    module_order: Sequence[str],
    scaffolds: Dict[str, TbScaffold],
    non_interactive: bool,
) -> Dict[str, Optional[TbScaffold]]:
    mapping: Dict[str, Optional[TbScaffold]] = {}
    used = set()
    for name in module_order:
        hit = scaffolds.get(normalize(name))
        if hit is not None and hit.root not in used:
            mapping[name] = hit
            used.add(hit.root)
        else:
            mapping[name] = None

    if non_interactive:
        return mapping

    pool = [s for s in scaffolds.values() if s.root not in used]
    if not pool:
        return mapping

    unmatched = [name for name, item in mapping.items() if item is None]
    if not unmatched:
        return mapping

    print("\n[INFO] Optional TB mapping correction for unmatched modules")
    for mod in unmatched:
        print(f"\nModule: {mod}")
        for idx, item in enumerate(pool, start=1):
            print(f"  [{idx}] {item.root.name}")
        print("  [S] skip")
        while True:
            raw = input("Select scaffold index or S: ").strip()
            if not raw or raw.lower() == "s":
                break
            selected = None
            if raw.isdigit():
                idx = int(raw)
                if 1 <= idx <= len(pool):
                    selected = pool[idx - 1]
            else:
                for item in pool:
                    if raw.lower() in {item.root.name.lower(), item.hint_name.lower()}:
                        selected = item
                        break
            if selected is None:
                print("[ERROR] Invalid scaffold selection.")
                continue
            mapping[mod] = selected
            used.add(selected.root)
            pool = [s for s in pool if s.root != selected.root]
            break
    return mapping


def task_names(path: Optional[Path]) -> List[str]:
    if path is None or not path.exists():
        return []
    return sorted(set(re.findall(r"\btask\s+(?:automatic\s+)?([A-Za-z_][A-Za-z0-9_$]*)", read_text(path), flags=re.I)))


def parse_directed_task_split(path: Optional[Path]) -> Dict[str, List[str]]:
    """Split generator tasks: tasks called in run() case = scenarioTasks, all others = helperTasks."""
    if path is None or not path.exists():
        return {"scenarioTasks": [], "helperTasks": []}
    text = read_text(path)
    # Extract all task names defined in the class
    all_tasks = set(re.findall(r"\btask\s+(?:automatic\s+)?([A-Za-z_][A-Za-z0-9_$]*)", text, flags=re.I))
    # Extract the run() body
    run_m = re.search(r"\bvirtual\s+task\s+run\s*\(\s*\)\s*;(.*?)\bendtask\b", text, flags=re.S | re.I)
    run_body = run_m.group(1) if run_m else ""
    # Find ALL task calls inside run() body (any identifier followed by ())
    tasks_in_run = set(re.findall(r"\b([A-Za-z_][A-Za-z0-9_$]*)\s*\(", run_body, flags=re.I)) & all_tasks
    tasks_in_run.discard("run")
    scenario_tasks = sorted(tasks_in_run)
    # Helper tasks = defined tasks NOT directly called from run()
    helper_tasks = sorted(all_tasks - tasks_in_run - {"run"})
    return {"scenarioTasks": scenario_tasks, "helperTasks": helper_tasks}


def parse_sva_assertions(scaffold: Optional[object]) -> List[Dict[str, str]]:
    """Parse SVA assertions from interface.sv in the TB scaffold."""
    if scaffold is None:
        return []
    iface_path = getattr(scaffold, "interface", None)
    if iface_path is None or not iface_path.exists():
        return []
    text = read_text(iface_path)
    results: List[Dict[str, str]] = []
    # Collect property bodies: name -> body text
    prop_bodies: Dict[str, str] = {}
    for pm in re.finditer(
        r"\bproperty\s+([A-Za-z_][A-Za-z0-9_$]*)\s*;([^;]+?)\bendproperty\b",
        text, flags=re.S | re.I
    ):
        prop_bodies[pm.group(1).lower()] = re.sub(r"\s+", " ", pm.group(2).strip())
    # Extract assert labels + property reference
    for am in re.finditer(
        r"([A-Za-z_][A-Za-z0-9_$]*)\s*:\s*assert\s+property\s*\(([A-Za-z_][A-Za-z0-9_$]*)\)",
        text, flags=re.I
    ):
        label = am.group(1)
        prop_name = am.group(2)
        body = prop_bodies.get(prop_name.lower(), "")
        # Extract disable iff from property body
        cond = ""
        cond_m = re.search(r"disable\s+iff\s*\(([^)]+)\)", body, flags=re.I)
        if cond_m:
            cond = cond_m.group(1).strip()
        # Clean body for display: remove 'disable iff (...)'
        clean_body = re.sub(r"disable\s+iff\s*\([^)]+\)\s*", "", body, flags=re.I).strip()
        results.append({"name": label, "prop": prop_name, "rule": clean_body, "cond": cond})
    return results


def parse_env_mailboxes(path: Optional[Path]) -> List[str]:
    """Extract mailbox variable names from environment.svh."""
    if path is None or not path.exists():
        return []
    text = read_text(path)
    return dedup_strings(re.findall(r"\b(mbx_[A-Za-z0-9_$]+)\b", text, flags=re.I))


def parse_env_components(path: Optional[Path]) -> List[Dict[str, str]]:
    """Extract component handles (m_* class declarations) from environment.svh."""
    if path is None or not path.exists():
        return []
    text = read_text(path)
    results = []
    for m in re.finditer(r"(?m)^\s*([A-Za-z_][A-Za-z0-9_$]*)\s+(m_[A-Za-z0-9_$]+)\s*;", text):
        cls = m.group(1)
        inst = m.group(2)
        # Skip primitive/process types
        if cls.lower() in {"process", "string", "int", "real", "bit", "logic", "integer"}:
            continue
        results.append({"cls": cls, "inst": inst})
    return results


def parse_clk_freq_from_tb(scaffold: Optional[object]) -> str:
    """Scan TB files for LP_CLK_PERIOD or P_CLK_HZ to derive a frequency label."""
    if scaffold is None:
        return ""
    # Check tb_top.sv, tb_defs.svh, and include files
    root = getattr(scaffold, "root", None)
    if root is None:
        return ""
    candidates: List[Path] = []
    for pat in ["tb_top.sv", "*.sv", "include/*.svh", "*.svh"]:
        candidates.extend(root.glob(pat))
    for path in candidates:
        if not path.exists():
            continue
        text = read_text(path)
        # LP_CLK_PERIOD in ns
        m = re.search(r"LP_CLK_PERIOD\s*=\s*([0-9]+(?:\.[0-9]+)?)", text)
        if m:
            ns = float(m.group(1))
            if ns > 0:
                freq_mhz = 1000.0 / ns
                if freq_mhz >= 1000:
                    return f"{freq_mhz/1000:.0f}GHz"
                elif freq_mhz == int(freq_mhz):
                    return f"{int(freq_mhz)}MHz"
                else:
                    return f"{freq_mhz:.1f}MHz"
        # P_CLK_HZ
        m = re.search(r"P_CLK_HZ\s*=\s*([0-9_]+)", text)
        if m:
            hz = int(m.group(1).replace("_", ""))
            if hz >= 1_000_000_000:
                return f"{hz // 1_000_000_000}GHz"
            elif hz >= 1_000_000:
                return f"{hz // 1_000_000}MHz"
            elif hz >= 1_000:
                return f"{hz // 1_000}kHz"
    return ""


def summary_lines(path: Optional[Path], regex: str, limit: int = 3) -> List[str]:
    if path is None or not path.exists():
        return []
    out = []
    for line in read_text(path).splitlines():
        if re.search(regex, line, flags=re.I):
            out.append(line.strip())
        if len(out) >= limit:
            break
    return out


def dedupe_test_files(tests: Sequence[Path]) -> List[Path]:
    test_files = [p for p in tests if p.exists() and p.stem.lower() != "base_test"]
    specific_nums = set()
    for path in test_files:
        m = re.match(r"^test[_-]?(\d+)[_-].+$", path.stem, flags=re.I)
        if m:
            specific_nums.add(int(m.group(1)))

    out: List[Path] = []
    seen = set()
    for path in test_files:
        stem = path.stem
        key = normalize(stem)
        if key in seen:
            continue
        generic = re.match(r"^test[_-]?(\d+)$", stem, flags=re.I)
        if generic and int(generic.group(1)) in specific_nums:
            continue
        seen.add(key)
        out.append(path)
    return out


def summarize_scenario(path: Path) -> Dict[str, str]:
    text = read_text(path)
    comment_line = next((line.strip().lstrip("/").strip() for line in text.splitlines() if line.strip().startswith("//")), "")
    kind_m = re.search(r"\bm_cfg\.m_test_kind\s*=\s*[A-Za-z_][A-Za-z0-9_$]*::([A-Za-z0-9_]+)\s*;", text)
    class_m = re.search(r"\bclass\s+([A-Za-z_][A-Za-z0-9_$]*)\s+extends\s+([A-Za-z_][A-Za-z0-9_$]*)", text)

    scenario_tag = ""
    if kind_m:
        scenario_tag = kind_m.group(1)
    elif class_m:
        scenario_tag = class_m.group(1)
    else:
        scenario_tag = path.stem

    pretty = re.sub(r"^LP_TEST_\d+_?", "", scenario_tag, flags=re.I)
    pretty = re.sub(r"^test[_-]?\d+[_-]?", "", pretty, flags=re.I)
    pretty = re.sub(r"[_\-]+", " ", pretty).strip().title()
    desc = comment_line or (pretty if pretty else f"Scenario from {path.stem}")

    cfg_lines = []
    for m in re.finditer(
        r"\bm_cfg\.(m_num_transactions|m_post_cycles|m_seed|m_enable_random|m_require_full_coverage)\s*=\s*([^;]+);",
        text,
    ):
        lhs = m.group(1).replace("m_", "")
        rhs = re.sub(r"\s+", " ", m.group(2).strip())
        cfg_lines.append(f"{lhs}={rhs}")
        if len(cfg_lines) >= 3:
            break
    constraints = ", ".join(cfg_lines) if cfg_lines else "N/A"
    return {"desc": desc, "constraints": constraints}


def parse_coverage_details(path: Optional[Path]) -> Dict[str, List[str]]:
    if path is None or not path.exists():
        return {"coverpoints": [], "crosses": [], "illegalBins": [], "summary": ["coverage.svh not found."]}

    text = read_text(path)
    coverpoints = dedup_strings(
        list(re.findall(r"\b([A-Za-z_][A-Za-z0-9_$]*)\s*:\s*coverpoint\b", text, flags=re.I))
        + list(re.findall(r"\bcoverpoint\s+([A-Za-z_][A-Za-z0-9_$]*)\b", text, flags=re.I))
    )
    crosses = dedup_strings(
        list(re.findall(r"\b([A-Za-z_][A-Za-z0-9_$]*)\s*:\s*cross\b", text, flags=re.I))
        + [re.sub(r"\s+", " ", x.strip()) for x in re.findall(r"\bcross\s+([^;]+);", text, flags=re.I)]
    )
    illegal_bins = dedup_strings(
        list(re.findall(r"\billegal_bins\s+([A-Za-z_][A-Za-z0-9_$]*)\b", text, flags=re.I))
        + [re.sub(r"\s+", " ", x.strip()) for x in re.findall(r"\billegal_bins\s+([^;]+);", text, flags=re.I)]
    )

    if not coverpoints:
        coverpoints = dedup_strings([f"cp_{x}" for x in re.findall(r"\bm_hit_cp_([A-Za-z0-9_]+)\b", text)])
    if not crosses:
        crosses = dedup_strings([f"cx_{x}" for x in re.findall(r"\bm_hit_cx_([A-Za-z0-9_]+)\b", text)])
    if not illegal_bins and re.search(r"\billegal_bins\b", text, flags=re.I):
        illegal_bins = ["illegal_bins detected (name parse fallback)"]

    summary = summary_lines(path, r"covergroup|coverpoint|cross|bins|ignore_bins|illegal_bins|m_hit_cp_|m_hit_cx_", 8)
    if not summary:
        summary = ["No explicit coverpoint/cross statement detected."]
    return {"coverpoints": coverpoints[:16], "crosses": crosses[:16], "illegalBins": illegal_bins[:16], "summary": summary}


def role_text_from_instance(instance_name: str) -> str:
    low = instance_name.lower()
    if "driver" in low:
        return "Drive DUT interface pins from generated transactions."
    if "monitor" in low:
        return "Sample DUT I/O and publish observed transactions."
    if "scoreboard" in low:
        return "Compare expected model output with observed response."
    if "coverage" in low:
        return "Collect functional coverage hits and closure metrics."
    if "generator" in low:
        return "Produce directed/random transaction streams."
    return "Verification worker thread."


def parse_env_thread_plan(path: Optional[Path]) -> Dict[str, object]:
    if path is None or not path.exists():
        return {"joinType": "N/A", "threads": [], "rawFork": "environment.svh not found.", "mailboxes": [], "components": []}

    text = read_text(path)
    decl_map = {}
    for m in re.finditer(r"(?m)^\s*([A-Za-z_][A-Za-z0-9_$]*)\s+(m_[A-Za-z0-9_$]+)\s*;", text):
        decl_map[m.group(2)] = m.group(1)

    run_body = ""
    run_m = re.search(r"\b(?:virtual\s+)?task\s+run\s*\(\s*\)\s*;\s*(.*?)\bendtask\b", text, flags=re.S | re.I)
    if run_m:
        run_body = run_m.group(1)

    join_type = "join"
    join_m = re.search(r"\b(join_none|join_any|join)\b", run_body, flags=re.I)
    if join_m:
        join_type = join_m.group(1).lower()

    calls = re.findall(r"\b(m_[A-Za-z0-9_$]+)\.run\s*\(", run_body, flags=re.I)
    threads = []
    for idx, inst in enumerate(calls, start=1):
        threads.append(
            {
                "name": f"Thread {idx}",
                "instance": inst,
                "className": decl_map.get(inst, ""),
                "role": role_text_from_instance(inst),
            }
        )
    fork_snippet = "fork ... " + join_type
    mailboxes = parse_env_mailboxes(path)
    components = parse_env_components(path)
    return {"joinType": join_type, "threads": threads, "rawFork": fork_snippet, "mailboxes": mailboxes, "components": components}


def parse_test_inheritance(base_test: Optional[Path], tests: Sequence[Path]) -> Dict[str, object]:
    base_class = ""
    base_methods: List[str] = []
    if base_test and base_test.exists():
        base_text = read_text(base_test)
        m = re.search(r"\bclass\s+([A-Za-z_][A-Za-z0-9_$]*)\b", base_text, flags=re.I)
        if m:
            base_class = m.group(1)
        base_methods = re.findall(r"\bvirtual\s+task\s+([A-Za-z_][A-Za-z0-9_$]*)\s*\(", base_text, flags=re.I)

    derived = []
    for t in tests:
        if t.name.lower() == "base_test.svh" or not t.exists():
            continue
        text = read_text(t)
        m = re.search(r"\bclass\s+([A-Za-z_][A-Za-z0-9_$]*)\s+extends\s+([A-Za-z_][A-Za-z0-9_$]*)\b", text, flags=re.I)
        if not m:
            continue
        cls_name = m.group(1)
        parent = m.group(2)
        if base_class and parent.lower() != base_class.lower():
            continue
        # Detect overridden virtual tasks
        overridden = re.findall(r"\bvirtual\s+task\s+([A-Za-z_][A-Za-z0-9_$]*)\s*\(", text, flags=re.I)
        overridden = [fn for fn in overridden if fn.lower() != "run"]
        # Extract first cfg set line from configure() override
        cfg_summary = ""
        cfg_m = re.search(r"\btask\s+configure\s*\(\s*\)\s*;(.*?)\bendtask\b", text, flags=re.S | re.I)
        if cfg_m:
            cfg_lines = [l.strip() for l in cfg_m.group(1).splitlines() if re.search(r"m_cfg\.m_test_kind|m_cfg\.m_num_transactions", l)]
            cfg_summary = " | ".join(cfg_lines[:2])
        derived.append({"name": cls_name, "parent": parent, "file": t.stem, "overrides": overridden, "cfgSummary": cfg_summary})
    return {"baseClass": base_class, "baseMethods": base_methods, "derived": derived[:12]}


def parse_results(
    project_root: Path,
    module_name: str,
    scenario_names: Sequence[str],
    scaffold: Optional[TbScaffold] = None,
) -> Dict[str, object]:
    token = normalize(module_name)
    reg_files = sorted((project_root / "output").glob("regression_*.md"), key=lambda p: p.stat().st_mtime)
    reg_candidates = [p for p in reg_files if token in normalize(p.stem)] or reg_files[-1:]

    reg_rows: Dict[str, Dict[str, object]] = {}
    for path in reg_candidates:
        lines = read_text(path).splitlines()
        header = None
        for line in lines:
            if not line.strip().startswith("|"):
                continue
            cols = [c.strip() for c in line.strip().strip("|").split("|")]
            if not cols:
                continue
            col0 = cols[0].lower()
            if "testname" in col0:
                header = [c.lower() for c in cols]
                continue
            if cols[0].startswith("---") or cols[0].startswith(":"):
                continue
            if header is None:
                continue
            row = {header[idx] if idx < len(header) else f"c{idx}": cols[idx] for idx in range(len(cols))}
            name = row.get("testname", cols[0]).strip()
            result = str(row.get("result", cols[1] if len(cols) > 1 else "")).upper()
            if result not in {"PASS", "FAIL"}:
                continue
            checked_txt = str(row.get("checked", row.get("checks", "0"))).strip()
            errors_txt = str(row.get("errors", row.get("error", "0"))).strip()
            score_txt = str(row.get("score", row.get("coverage", ""))).strip()
            reg_rows[normalize(name)] = {
                "name": name,
                "status": result,
                "checked": int(checked_txt) if checked_txt.isdigit() else 0,
                "errors": int(errors_txt) if errors_txt.isdigit() else 0,
                "reason": str(row.get("reason", "")).strip(),
                "score": score_txt,
            }

    log_candidates: List[Path] = []
    log_dir = project_root / "log" / "vivado_sim"
    if log_dir.exists():
        log_candidates.extend(sorted(log_dir.glob("*.log"), key=lambda p: p.stat().st_mtime))
    if scaffold and scaffold.root.exists():
        log_candidates.extend(sorted(scaffold.root.rglob("*.log"), key=lambda p: p.stat().st_mtime))
    if not log_candidates:
        log_candidates = []

    log_selected: Dict[str, Dict[str, object]] = {}
    current_key = ""
    current_name = ""
    for path in log_candidates[-4:]:
        text = read_text(path)
        for line in text.splitlines():
            pick = re.search(r"Selected\s+TESTNAME\s*=\s*([A-Za-z0-9_]+)", line, flags=re.I)
            if pick:
                current_name = pick.group(1)
                current_key = normalize(current_name)
                if current_key not in log_selected:
                    log_selected[current_key] = {"name": current_name}
                continue
            env_hit = re.search(
                r"ENV report:\s*checked=(\d+)\s+errors=(\d+)\s+coverage=([0-9]+(?:\.[0-9]+)?)%",
                line,
                flags=re.I,
            )
            if env_hit and current_key:
                log_selected[current_key] = {
                    "name": log_selected.get(current_key, {}).get("name", current_name),
                    "checked": int(env_hit.group(1)),
                    "errors": int(env_hit.group(2)),
                    "coverage": float(env_hit.group(3)),
                }

    def test_index(name: str) -> str:
        m = re.search(r"\btest[_-]?(\d+)", name, flags=re.I)
        return m.group(1).lstrip("0") if m else ""

    reg_by_idx: Dict[str, Dict[str, object]] = {}
    for row in reg_rows.values():
        idx = test_index(str(row.get("name", "")))
        if idx and idx not in reg_by_idx:
            reg_by_idx[idx] = row

    log_by_idx: Dict[str, Dict[str, object]] = {}
    for row in log_selected.values():
        idx = test_index(str(row.get("name", "")))
        if idx and idx not in log_by_idx:
            log_by_idx[idx] = row

    score_rows = []
    fail = 0
    for sname in scenario_names:
        key = normalize(sname)
        idx = test_index(sname)
        reg_exact = reg_rows.get(key)
        reg = reg_exact or (reg_by_idx.get(idx) if idx else None)
        log = log_selected.get(key) or (log_by_idx.get(idx) if idx else None)

        status = str((reg_exact or {}).get("status", (reg or {}).get("status", ""))).upper()
        checked = int((log or {}).get("checked", (reg or {}).get("checked", 0)) or 0)
        errors = int((log or {}).get("errors", (reg or {}).get("errors", 0)) or 0)
        reason = str((reg_exact or {}).get("reason", (reg or {}).get("reason", "")) or "")

        score_txt = str((reg or {}).get("score", "")).strip()
        score = None
        sm = re.search(r"([0-9]+(?:\.[0-9]+)?)\s*%", score_txt)
        if (log or {}).get("coverage") is not None:
            score = float((log or {}).get("coverage", 0.0))
        elif sm:
            score = float(sm.group(1))
        elif score_txt and re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", score_txt):
            score = float(score_txt)
        elif checked > 0:
            score = max(0.0, (float(checked - errors) / float(checked)) * 100.0)
        elif status == "PASS":
            score = 100.0
        elif status == "FAIL":
            score = 0.0
        else:
            score = 100.0

        if not status:
            if errors > 0:
                status = "FAIL"
            elif checked > 0:
                status = "PASS"
            else:
                status = "N/A"

        if status == "FAIL" or errors > 0:
            fail += 1

        score_rows.append(
            {
                "name": sname,
                "score": round(score, 2),
                "checked": checked,
                "errors": errors,
                "status": status,
                "reason": reason,
            }
        )

    if not score_rows:
        score_rows = [{"name": "overall", "score": 100.0, "checked": 0, "errors": 0, "status": "N/A", "reason": ""}]

    refs = [relpath_posix(p, project_root) for p in (reg_candidates + log_candidates[-4:])]
    return {
        "logDesc": " | ".join(refs[:4]) if refs else "No regression/log artifacts found.",
        "scenarioScores": score_rows,
        "overallIssues": "0 cases" if fail == 0 else f"{fail} cases",
    }


def find_asset(project_root: Path, module_name: str, ext: str, keyword: str) -> Optional[Path]:
    token = normalize(module_name)
    roots = [project_root / "Presentation", project_root / "NEW_Presentation", project_root / "output", project_root / "report_assets"]
    candidates = []
    for root in roots:
        if not root.exists():
            continue
        for path in root.rglob(f"*.{ext}"):
            low = path.name.lower()
            if keyword in low or token in normalize(path.stem):
                candidates.append(path)
    if not candidates:
        return None
    candidates.sort(key=lambda p: (token in normalize(p.stem), p.stat().st_mtime), reverse=True)
    return candidates[0]


def copy_asset(src: Optional[Path], out_dir: Path, subdir: str, stem: str) -> str:
    if src is None or not src.exists():
        return ""
    dst_dir = out_dir / "assets" / subdir
    dst_dir.mkdir(parents=True, exist_ok=True)
    dst = dst_dir / f"{stem}{src.suffix.lower()}"
    try:
        if src.resolve() != dst.resolve():
            shutil.copyfile(src, dst)
    except Exception:
        shutil.copyfile(src, dst)
    return relpath_posix(dst, out_dir)


def module_payload(
    project_root: Path,
    out_dir: Path,
    module: ModuleInfo,
    top_name: str,
    scaffold: Optional[TbScaffold],
    fsm_states: Optional[Sequence[object]] = None,
) -> Dict[str, object]:
    effective_fsm_states = dedup_strings(fsm_states if fsm_states is not None else module.fsm_states)
    if module.children:
        spec_kind = "type1"
    elif effective_fsm_states:
        spec_kind = "type3"
    else:
        spec_kind = "type2"

    tx_in = sorted(set(re.findall(r"\bm_i[A-Za-z0-9_]*\b", read_text(scaffold.transaction) if scaffold and scaffold.transaction else "")))
    tx_out = sorted(set(re.findall(r"\bm_o[A-Za-z0-9_]*\b", read_text(scaffold.transaction) if scaffold and scaffold.transaction else "")))
    drv_pins = sorted(set(re.findall(r"\btb_i[A-Za-z0-9_]*\b", read_text(scaffold.driver) if scaffold and scaffold.driver else "")))
    mon_pins = sorted(set(re.findall(r"\btb_[io][A-Za-z0-9_]*\b", read_text(scaffold.monitor) if scaffold and scaffold.monitor else "")))
    tests = scaffold.tests if scaffold else []
    scenarios = []
    for idx, t in enumerate(tests):
        scenario_info = summarize_scenario(t)
        scenarios.append(
            {
                "name": t.stem,
                "border": COLORS[idx % len(COLORS)],
                "desc": scenario_info["desc"],
                "constraints": scenario_info["constraints"],
                "expected": "PASS",
            }
        )
    if not scenarios:
        scenarios = [{"name": "no_test_found", "border": "slate", "desc": "No test*.svh found in TB scaffold.", "constraints": "N/A", "expected": "N/A"}]

    coverage_detail = parse_coverage_details(scaffold.coverage if scaffold else None)
    coverage_data = [{"title": f"Coverage-{i+1}", "desc": line} for i, line in enumerate(coverage_detail["summary"])]
    if not coverage_data:
        coverage_data = [{"title": "Coverage", "desc": "coverage.svh not found or no coverage line detected."}]

    # Parse SVA assertions from interface.sv
    sva_assertions = parse_sva_assertions(scaffold)

    scb_path = scaffold.scoreboard if scaffold else None
    scb_lines_raw = summary_lines(scb_path, r"function|task|case|if|\$error|\$display|compare|expect|\bassert\b|\bproperty\b|mismatch", 8)
    # Filter out header guards and pure declarations
    scb_lines = [l for l in scb_lines_raw if not re.match(r"^`(ifndef|define|endif|include)|^//|^package|^endpackage|^class|^endclass", l.strip())]
    if not scb_lines:
        scb_lines = ["scoreboard.svh not found or no logic detected."]
    scb_text = " | ".join(scb_lines[:2]) if scb_lines else "scoreboard.svh not found."
    assert_text = " | ".join(scb_lines[2:4]) if len(scb_lines) > 2 else "No assertion/property statement detected."

    # Build scored scbFlow from parsed function/task names in scoreboard.svh
    scb_fn_names: List[str] = []
    if scb_path and scb_path.exists():
        scb_fn_names = re.findall(r"\b(?:function|task)(?:\s+\w+)\s+([A-Za-z_][A-Za-z0-9_$]*)\s*[\/\(;]", read_text(scb_path), flags=re.I)
    fn_summary = ", ".join(scb_fn_names[:4]) if scb_fn_names else "(auto-parse unavailable)"

    def scb_flow_step(i, title, body, icon, color):
        return {"title": title, "body": body, "icon": icon, "color": color}

    built_scb_flow = [
        scb_flow_step(0, "1. Transaction Pop", "mbx_mon2scb.get(tx_obs) — DUT 관측 트랜잭션 수신", "ph-download-simple", "blue"),
        scb_flow_step(1, "2. Golden Model Compute", f"Scoreboard 내부에서 기댓값 계산. 파싱된 함수: {fn_summary}", "ph-cpu", "indigo"),
        scb_flow_step(2, "3. Compare Output", f"{scb_lines[0] if scb_lines else 'No compare logic detected'}", "ph-scales", "violet"),
        scb_flow_step(3, "4. Report Pass / Error", "$display / $error 로 결과 로깅. 불일치 시 에러 카운터 증가.", "ph-flag-banner", "emerald"),
    ]
    code_refs = [relpath_posix(scaffold.scoreboard, project_root)] if scaffold and scaffold.scoreboard else []

    test_names = [s["name"] for s in scenarios]
    results = parse_results(project_root, module.name, test_names, scaffold=scaffold)
    env_flow = parse_env_thread_plan(scaffold.environment if scaffold else None)
    inheritance = parse_test_inheritance(scaffold.base_test if scaffold else None, tests)
    clk_freq_label = parse_clk_freq_from_tb(scaffold)
    env_text = " | ".join(summary_lines(scaffold.base_test if scaffold else None, r"task|new\(|run\(|start\(", 4)) or "base_test.svh not found."
    simlog = copy_asset(find_asset(project_root, module.name, "png", "log"), out_dir, "simlog", module.name)
    timing = copy_asset(find_asset(project_root, module.name, "svg", "timing"), out_dir, "timing", module.name)

    return {
        "type": "top" if module.name == top_name else ("unit" if not module.children else "general"),
        "specKind": spec_kind,
        "name": module.name,
        "description": module.description,
        "clkFreqLabel": clk_freq_label,
        "ioPorts": module.ports,
        "internalSignals": module.internals,
        "fsmStates": effective_fsm_states,
        "hierarchy": [{"name": c, "desc": "Child module instance"} for c in module.children],
        "assets": {
            "simpleDiagramSvg": f"../output/Diagram/Simple/{module.name}.svg",
            "detailedDiagramSvg": f"../output/Diagram/Detailed/{module.name}_detailed.svg",
            "fsmDiagramSvg": f"../output/fsm/svg/{module.name}_fsm.svg",
            "simulationLogImage": simlog,
            "timingDiagramSvg": timing,
        },
        "verification": {
            "tb": {
                "hasScaffold": bool(scaffold),
                "txFile": relpath_posix(scaffold.transaction, project_root) if scaffold and scaffold.transaction else "",
                "genFile": relpath_posix(scaffold.generator, project_root) if scaffold and scaffold.generator else "",
                "drvFile": relpath_posix(scaffold.driver, project_root) if scaffold and scaffold.driver else "",
                "monFile": relpath_posix(scaffold.monitor, project_root) if scaffold and scaffold.monitor else "",
                "txIn": tx_in,
                "txOut": tx_out,
                "genDirected": [t.stem for t in tests] + task_names(scaffold.generator if scaffold else None),
                "genDirectedSplit": parse_directed_task_split(scaffold.generator if scaffold else None),
                "genRandom": " | ".join(summary_lines(scaffold.generator if scaffold else None, r"rand|random|srandom|\$urandom", 3)) or "No random policy detected.",
                "driverPins": drv_pins,
                "monitorPins": mon_pins,
                "driveStyle": "wait reset deassert -> drive on negedge -> sample on posedge",
                "envFile": relpath_posix(scaffold.environment, project_root) if scaffold and scaffold.environment else "",
            },
            "scenarios": scenarios,
            "coverage": coverage_data,
            "coverageDetail": {
                "coverpoints": coverage_detail["coverpoints"],
                "crosses": coverage_detail["crosses"],
                "illegalBins": coverage_detail["illegalBins"],
            },
            "scbAssert": {"scbText": scb_text, "assertText": assert_text, "scbFlow": built_scb_flow, "goldenBasis": "", "assertions": sva_assertions if sva_assertions else scb_lines, "codeRefs": code_refs},
            "envTest": {
                "text": env_text,
                "envForkJoin": env_flow,
                "testInheritance": inheritance,
            },
            "results": results,
        },
    }


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Generate module verification presentation HTML from project artifacts")
    p.add_argument("--project", required=True)
    p.add_argument("--manifest-json", required=True)
    p.add_argument("--top", default="")
    p.add_argument("--project-title", default="")
    p.add_argument("--author", default="")
    p.add_argument("--template", default="")
    p.add_argument("--output-html", default="")
    p.add_argument("--clean-assets", action="store_true")
    p.add_argument("--non-interactive", action="store_true")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    try:
        script_dir = Path(__file__).resolve().parent
        project_root = Path(args.project).resolve()
        template_path = Path(args.template).resolve() if args.template else (script_dir.parent.parent / "presentation" / "presentation_module_verification_template.html.j2").resolve()
        out_dir = project_root / "Presentation"
        out_dir.mkdir(parents=True, exist_ok=True)
        out_html = Path(args.output_html).resolve() if args.output_html else (out_dir / f"presentation_{project_root.name}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.html")
        if args.clean_assets:
            shutil.rmtree(out_dir / "assets", ignore_errors=True)
            print(f"[INFO] Cleaned assets: {out_dir / 'assets'}")

        manifest = load_manifest(Path(args.manifest_json).resolve(), project_root)
        modules = parse_modules(manifest["src_files"])
        if not modules:
            raise RuntimeError("No modules parsed from source files.")
        names = sorted(modules.keys(), key=str.lower)
        top_name = args.top.strip() or str(manifest.get("top") or "").strip() or choose_top(modules)
        top_name = next((n for n in names if n.lower() == top_name.lower()), top_name)
        if top_name not in modules:
            raise RuntimeError(f"Top module not found: {top_name}")
        if not args.non_interactive:
            print("\n[INFO] Select top module")
            for i, n in enumerate(names, 1):
                print(f"  [{i}] {n}")
            top_raw = input(f"Top module [default: {top_name}]: ").strip()
            if top_raw:
                selected, err = parse_selection(top_raw, names, allow_all=False)
                if err or len(selected) != 1:
                    raise RuntimeError("Invalid top module selection.")
                top_name = selected[0]

        if args.non_interactive:
            detail = [n for n in names if n != top_name]
            title = args.project_title.strip() or project_root.name
            author = args.author.strip() or "FPGA Team"
            trouble = {"issue": "No major blocker", "solution": "N/A"}
            conclusion = {"summary": "Verification artifacts were generated successfully.", "nextSteps": "Run additional directed/random regression as needed."}
        else:
            title = input(f"Presentation title [default: {args.project_title.strip() or project_root.name}]: ").strip() or (args.project_title.strip() or project_root.name)
            author = input(f"Author [default: {args.author.strip() or 'FPGA Team'}]: ").strip() or (args.author.strip() or "FPGA Team")
            candidates = [n for n in names if n != top_name]
            print("\n[INFO] Detail modules")
            for i, n in enumerate(candidates, 1):
                print(f"  [{i}] {n}")
            raw = input("Detail modules (ALL or index/name list, default ALL): ").strip()
            detail, err = parse_selection(raw, candidates, allow_all=True) if raw else (candidates, [])
            if err:
                raise RuntimeError(f"Invalid detail module selection: {', '.join(err)}")
            raw_order = input("Detail order (index/name list, default current): ").strip()
            if raw_order:
                order, err = parse_selection(raw_order, detail, allow_all=False)
                if err or len(order) != len(detail):
                    raise RuntimeError("Invalid detail module order.")
                detail = order
            trouble = {"issue": input("Trouble issue [default: No major blocker]: ").strip() or "No major blocker", "solution": input("Trouble solution [default: N/A]: ").strip() or "N/A"}
            conclusion = {"summary": input("Conclusion summary [default: Verification artifacts were generated successfully.]: ").strip() or "Verification artifacts were generated successfully.", "nextSteps": input("Next steps [default: Run additional directed/random regression as needed.]: ").strip() or "Run additional directed/random regression as needed."}

        scaffolds = scan_tb_scaffolds(project_root)
        order = [top_name] + [n for n in detail if n != top_name]
        tb_mapping = resolve_scaffold_mapping(order, scaffolds, args.non_interactive)
        fsm_state_map = resolve_fsm_state_map(modules, order)
        payload_modules = [
            module_payload(
                project_root,
                out_dir,
                modules[n],
                top_name,
                tb_mapping.get(n),
                fsm_states=fsm_state_map.get(n, []),
            )
            for n in order
        ]
        type_counts = {"type1": 0, "type2": 0, "type3": 0}
        for m in payload_modules:
            k = str(m.get("specKind", "")).lower()
            if k in type_counts:
                type_counts[k] += 1
        print(f"[INFO] SPEC kinds: type1={type_counts['type1']} type2={type_counts['type2']} type3={type_counts['type3']}")

        project_data = {
            "meta": {"title": title, "subtitle": "Module Verification Presentation", "author": author, "date": datetime.now().strftime("%Y-%m-%d"), "version": "v1.0"},
            "env": {
                "top": top_name,
                "tools": "vivado, verilog, system verilog",
                "svComponentSvg": "../NEW_Presentation/SV Component.svg",
            },
            "modules": payload_modules,
            "trouble": trouble,
            "conclusion": conclusion,
        }

        env = Environment(loader=FileSystemLoader(str(template_path.parent)), autoescape=False, trim_blocks=True, lstrip_blocks=True)
        html = env.get_template(template_path.name).render(project_data_json=json.dumps(project_data, ensure_ascii=False, indent=2))
        out_html.write_text(html, encoding="utf-8")
        print("------------------------------------------------------------------------------")
        print("[SUCCESS] Presentation HTML generated.")
        print(f"[INFO] Template: {template_path}")
        print(f"[INFO] HTML: {out_html}")
        return 0
    except KeyboardInterrupt:
        print("\n[ERROR] Interrupted by user.")
        return 130
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
