#!/usr/bin/env python3
"""
Generate presentation HTML/JSON from Verilog sources using Jinja2.

This tool scans src/*.v, src/*.sv and builds a presentation_config object
for templates/Presentation/Presentation_templates.html.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Set, Tuple

try:
    from jinja2 import Environment, FileSystemLoader
except Exception as exc:  # pragma: no cover
    print("[ERROR] Jinja2 is required. Install with: python -m pip install jinja2", file=sys.stderr)
    print(f"[ERROR] Import detail: {exc}", file=sys.stderr)
    sys.exit(2)


IDENTIFIER_KEYWORDS: Set[str] = {
    "always",
    "assign",
    "begin",
    "case",
    "casex",
    "casez",
    "default",
    "else",
    "end",
    "endcase",
    "endmodule",
    "for",
    "function",
    "if",
    "input",
    "inout",
    "localparam",
    "module",
    "negedge",
    "or",
    "output",
    "parameter",
    "posedge",
    "reg",
    "wire",
    "logic",
    "signed",
    "unsigned",
    "integer",
    "real",
    "time",
    "task",
    "while",
    "repeat",
    "generate",
    "endgenerate",
    "genvar",
    "initial",
    "typedef",
    "struct",
    "union",
    "enum",
    "automatic",
    "disable",
    "wait",
    "fork",
    "join",
    "join_any",
    "join_none",
    "package",
    "endpackage",
    "interface",
    "endinterface",
    "import",
    "export",
}

TEXT_DECODINGS: Tuple[str, ...] = ("utf-8-sig", "utf-8", "cp949", "euc-kr")
IMAGE_EXTENSIONS: Tuple[str, ...] = (".svg", ".png", ".jpg", ".jpeg")


@dataclass
class InstanceInfo:
    child_module: str
    instance_name: str
    text_index: int


@dataclass
class ModuleInfo:
    name: str
    file_path: Path
    text_original: str
    text_clean: str
    ports: Dict[str, str] = field(default_factory=dict)
    port_order: List[str] = field(default_factory=list)
    signal_kinds: Dict[str, str] = field(default_factory=dict)
    instances: List[InstanceInfo] = field(default_factory=list)
    role: str = ""
    summary: List[str] = field(default_factory=list)
    state_description: List[str] = field(default_factory=list)
    has_fsm: bool = False

    def direct_children(self, known_modules: Set[str]) -> List[str]:
        seen: Set[str] = set()
        out: List[str] = []
        for inst in sorted(self.instances, key=lambda i: i.text_index):
            child = inst.child_module
            if child not in known_modules or child in seen:
                continue
            seen.add(child)
            out.append(child)
        return out


def replace_non_newline_with_space(text: str) -> str:
    return re.sub(r"[^\n]", " ", text)


def read_text_autodetect(file_path: Path) -> str:
    raw = file_path.read_bytes()
    for encoding in TEXT_DECODINGS:
        try:
            return raw.decode(encoding)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")


def strip_comments_keep_shape(text: str) -> str:
    text = re.sub(
        r"/\*[\s\S]*?\*/",
        lambda m: replace_non_newline_with_space(m.group(0)),
        text,
    )
    text = re.sub(r"//[^\n\r]*", lambda m: " " * len(m.group(0)), text)
    return text


def split_top_level(text: str, delimiter: str = ",") -> List[str]:
    out: List[str] = []
    token: List[str] = []
    paren = 0
    bracket = 0
    brace = 0
    for ch in text:
        if ch == "(":
            paren += 1
        elif ch == ")":
            paren = max(paren - 1, 0)
        elif ch == "[":
            bracket += 1
        elif ch == "]":
            bracket = max(bracket - 1, 0)
        elif ch == "{":
            brace += 1
        elif ch == "}":
            brace = max(brace - 1, 0)

        if ch == delimiter and paren == 0 and bracket == 0 and brace == 0:
            out.append("".join(token))
            token = []
            continue
        token.append(ch)
    if token:
        out.append("".join(token))
    return out


def parse_balanced(text: str, start: int, open_ch: str, close_ch: str) -> Optional[Tuple[str, int]]:
    if start < 0 or start >= len(text) or text[start] != open_ch:
        return None
    depth = 0
    i = start
    while i < len(text):
        ch = text[i]
        if ch == open_ch:
            depth += 1
        elif ch == close_ch:
            depth -= 1
            if depth == 0:
                return text[start + 1 : i], i + 1
        i += 1
    return None


def extract_decl_names_from_segment(segment: str) -> List[str]:
    chunks = split_top_level(segment, ",")
    names: List[str] = []
    for raw in chunks:
        chunk = raw.strip()
        if not chunk:
            continue
        chunk = re.sub(r"=\s*.+$", " ", chunk)
        chunk = re.sub(r"\[[^\]]*\]", " ", chunk)
        chunk = re.sub(
            r"\b(wire|reg|logic|signed|unsigned|var|tri|tri0|tri1|supply0|supply1|bit|byte|shortint|int|longint|integer|time|real)\b",
            " ",
            chunk,
            flags=re.IGNORECASE,
        )
        m = re.search(r"([A-Za-z_][A-Za-z0-9_$]*)\s*$", chunk)
        if m:
            names.append(m.group(1))
    return names


def parse_header_ports(module_text: str, module_name: str) -> Tuple[Dict[str, str], List[str]]:
    ports: Dict[str, str] = {}
    port_order: List[str] = []
    module_name_pos = module_text.find(module_name)
    if module_name_pos < 0:
        return ports, port_order
    header_end = module_text.find(";")
    if header_end < 0:
        return ports, port_order
    header = module_text[module_name_pos + len(module_name) : header_end + 1]
    i = 0
    while i < len(header) and header[i].isspace():
        i += 1
    if i < len(header) and header[i] == "#":
        i += 1
        while i < len(header) and header[i].isspace():
            i += 1
        if i < len(header) and header[i] == "(":
            params = parse_balanced(header, i, "(", ")")
            if params is None:
                return ports, port_order
            _, i = params
    while i < len(header) and header[i].isspace():
        i += 1
    if i >= len(header) or header[i] != "(":
        return ports, port_order
    port_block = parse_balanced(header, i, "(", ")")
    if port_block is None:
        return ports, port_order

    current_dir = ""
    for segment in split_top_level(port_block[0], ","):
        clean = segment.strip()
        if not clean:
            continue
        dir_match = re.search(r"\b(input|output|inout)\b", clean, flags=re.IGNORECASE)
        if dir_match:
            current_dir = dir_match.group(1).lower()
        for name in extract_decl_names_from_segment(clean):
            if name not in ports:
                ports[name] = current_dir or "unknown"
                port_order.append(name)
    return ports, port_order


def parse_body_ports(module_text: str, ports: Dict[str, str], port_order: List[str]) -> None:
    header_end = module_text.find(";")
    body_text = module_text[header_end + 1 :] if header_end >= 0 else module_text
    for m in re.finditer(r"^\s*(input|output|inout)\b([^;]*);", body_text, flags=re.MULTILINE | re.IGNORECASE):
        direction = m.group(1).lower()
        names = extract_decl_names_from_segment(m.group(2))
        for name in names:
            if name not in ports:
                port_order.append(name)
            ports[name] = direction


def parse_internal_signals(module_text: str, signal_kinds: Dict[str, str]) -> None:
    for m in re.finditer(r"^\s*(wire|reg|logic)\b([^;]*);", module_text, flags=re.MULTILINE | re.IGNORECASE):
        kind = m.group(1).lower()
        names = extract_decl_names_from_segment(m.group(2))
        for name in names:
            if name not in signal_kinds:
                signal_kinds[name] = kind


def detect_fsm(module_text: str, state_description: Sequence[str]) -> bool:
    if state_description:
        return True
    has_state_case = re.search(
        r"\bcase\s*\(\s*[A-Za-z_]\w*(?:state|cur)[A-Za-z_0-9]*\s*\)",
        module_text,
        flags=re.IGNORECASE,
    )
    has_state_decl = re.search(
        r"\b(localparam|parameter)\b[\s\S]{0,240}\b[A-Za-z_]\w*(?:state|idle|init|run|wait|done)\w*\s*=",
        module_text,
        flags=re.IGNORECASE,
    )
    has_next_assign = re.search(
        r"\b[A-Za-z_]\w*(?:next|nxt|_d)\w*\s*(?:<=|=)\s*[A-Za-z_]\w+",
        module_text,
        flags=re.IGNORECASE,
    )
    has_always = re.search(r"\balways\s*@|\balways_comb\b", module_text, flags=re.IGNORECASE)
    has_state_reg = re.search(r"\b(reg|logic)\b[^\n;]*\bstate\b", module_text, flags=re.IGNORECASE)
    return bool((has_always and has_state_case) or (has_state_decl and has_next_assign) or (has_state_case and has_state_reg))


def parse_module_info_block(block: str) -> Tuple[str, List[str], List[str]]:
    role = ""
    summary: List[str] = []
    state_description: List[str] = []
    section = ""

    for raw_line in block.splitlines():
        line = raw_line.strip()
        line = re.sub(r"^(?:/\*+|\*/|//+|\*+)\s*", "", line)
        line = re.sub(r"\s*\*/\s*$", "", line).strip()
        if not line:
            continue

        key_match = re.match(r"^(name|role|summary|statedescription)\s*[:=]\s*(.*)$", line, flags=re.IGNORECASE)
        if key_match:
            key = key_match.group(1).lower()
            value = key_match.group(2).strip()
            if key == "name":
                section = ""
                continue
            if key == "role":
                role = value
                section = ""
                continue
            if key == "summary":
                section = "summary"
                if value:
                    summary.append(value)
                continue
            if key == "statedescription":
                section = "state"
                if value:
                    state_description.append(value)
                continue

        if re.match(r"^[A-Za-z_]\w*\s*[:=]", line):
            section = ""
            continue
        if line.startswith("-"):
            item = line[1:].strip()
            if not item:
                continue
            if section == "summary":
                summary.append(item)
            elif section == "state":
                state_description.append(item)
            continue
        if section == "summary":
            summary.append(line)
        elif section == "state":
            state_description.append(line)

    return role, summary, state_description


def parse_module_info_for_span(file_text: str, module_start: int, module_end: int) -> Tuple[str, List[str], List[str]]:
    matches = list(
        re.finditer(
            r"\[\s*MODULE_INFO_START\s*\](.*?)\[\s*MODULE_INFO_END\s*\]",
            file_text,
            flags=re.IGNORECASE | re.DOTALL,
        )
    )
    if not matches:
        return "", [], []
    inside = [m for m in matches if module_start <= m.start() and m.end() <= module_end]
    if inside:
        chosen = inside[0]
        return parse_module_info_block(chosen.group(1))
    before = [m for m in matches if m.end() <= module_start]
    if before:
        chosen = before[-1]
        return parse_module_info_block(chosen.group(1))
    after = [m for m in matches if m.start() >= module_start]
    chosen = after[0] if after else matches[0]
    return parse_module_info_block(chosen.group(1))


def parse_instances(module_text: str, module_names: Sequence[str], current_module: str) -> List[InstanceInfo]:
    out: List[InstanceInfo] = []
    for child in module_names:
        if child == current_module:
            continue
        pattern = re.compile(
            rf"(?<![\w$]){re.escape(child)}\s*(?:#\s*\([\s\S]*?\)\s*)?([A-Za-z_][A-Za-z0-9_$]*)\s*\(",
            flags=re.MULTILINE,
        )
        for m in pattern.finditer(module_text):
            prefix = module_text[max(0, m.start() - 20) : m.start()]
            if re.search(r"\bmodule\s+$", prefix):
                continue
            instance_name = m.group(1)
            out.append(InstanceInfo(child_module=child, instance_name=instance_name, text_index=m.start()))
    out.sort(key=lambda x: x.text_index)
    unique: Dict[Tuple[str, str, int], InstanceInfo] = {}
    for item in out:
        unique[(item.child_module, item.instance_name, item.text_index)] = item
    return list(unique.values())


def parse_modules_from_source_file(file_path: Path) -> List[ModuleInfo]:
    raw_text = read_text_autodetect(file_path)
    clean_text = strip_comments_keep_shape(raw_text)
    modules: List[ModuleInfo] = []
    for m in re.finditer(
        r"\bmodule\s+([A-Za-z_][A-Za-z0-9_$]*)\b([\s\S]*?)\bendmodule\b",
        clean_text,
        flags=re.MULTILINE,
    ):
        module_name = m.group(1)
        module_clean = m.group(0)
        module_orig = raw_text[m.start() : m.end()]
        role, summary, state_desc = parse_module_info_for_span(raw_text, m.start(), m.end())

        ports, port_order = parse_header_ports(module_clean, module_name)
        parse_body_ports(module_clean, ports, port_order)
        signal_kinds = dict(ports)
        parse_internal_signals(module_clean, signal_kinds)

        modules.append(
            ModuleInfo(
                name=module_name,
                file_path=file_path,
                text_original=module_orig,
                text_clean=module_clean,
                ports=ports,
                port_order=port_order,
                signal_kinds=signal_kinds,
                role=role,
                summary=summary,
                state_description=state_desc,
            )
        )
    return modules


def list_verilog_files(src_dir: Path) -> List[Path]:
    files = sorted(src_dir.rglob("*.v")) + sorted(src_dir.rglob("*.sv"))
    return sorted(set(files), key=lambda p: str(p).lower())


def build_module_db(src_dir: Path) -> Dict[str, ModuleInfo]:
    modules_by_name: Dict[str, ModuleInfo] = {}
    duplicates: List[str] = []
    for file_path in list_verilog_files(src_dir):
        parsed = parse_modules_from_source_file(file_path)
        for module in parsed:
            if module.name in modules_by_name:
                duplicates.append(module.name)
                continue
            modules_by_name[module.name] = module
    if duplicates:
        dup_names = ", ".join(sorted(set(duplicates)))
        print(f"[WARN] Duplicate module names detected and ignored (kept first): {dup_names}")

    names = sorted(modules_by_name.keys())
    for name in names:
        mod = modules_by_name[name]
        mod.instances = parse_instances(mod.text_clean, names, mod.name)
        mod.has_fsm = detect_fsm(mod.text_clean, mod.state_description)
    return modules_by_name


def choose_top_module(modules_by_name: Dict[str, ModuleInfo]) -> Optional[str]:
    if "TOP" in modules_by_name:
        return "TOP"
    if "Top" in modules_by_name:
        return "Top"
    usage = {name: 0 for name in modules_by_name}
    for mod in modules_by_name.values():
        for inst in mod.instances:
            if inst.child_module in usage:
                usage[inst.child_module] += 1
    roots = sorted([name for name, cnt in usage.items() if cnt == 0], key=lambda n: n.lower())
    if roots:
        return roots[0]
    names = sorted(modules_by_name.keys(), key=lambda n: n.lower())
    return names[0] if names else None


def prompt_select_top(modules_by_name: Dict[str, ModuleInfo], initial_top: Optional[str]) -> str:
    default_top = initial_top or choose_top_module(modules_by_name)
    if not default_top:
        raise RuntimeError("No module found.")
    module_names = sorted(modules_by_name.keys(), key=lambda n: n.lower())
    while True:
        raw = input(f"Top module [default: {default_top}]: ").strip()
        if not raw:
            return default_top
        matched = next((name for name in module_names if name.lower() == raw.lower()), None)
        if matched:
            return matched
        print(f"[ERROR] Top module not found: {raw}")
        print(f"[INFO] Available: {', '.join(module_names)}")


def prompt_with_default(label: str, default: str) -> str:
    try:
        raw = input(f"{label} [default: {default}]: ").strip()
    except EOFError:
        return default
    return raw if raw else default


def prompt_cover_meta(default_project_name: str, default_author: str) -> Tuple[str, str]:
    print("")
    print("[INFO] Cover metadata input:")
    project_name = prompt_with_default("Project name", default_project_name)
    author_name = prompt_with_default("Author", default_author)
    return project_name, author_name


def classify_signal_bucket(kind: str) -> int:
    k = (kind or "").lower()
    if k == "input":
        return 1
    if k == "output":
        return 2
    if k == "inout":
        return 3
    if k in {"wire", "reg", "logic"}:
        return 4
    return 9


def top_signal_entries(module: ModuleInfo) -> List[Tuple[str, str]]:
    items = [(name, kind) for name, kind in module.signal_kinds.items()]
    items.sort(key=lambda x: (classify_signal_bucket(x[1]), x[0].lower()))
    return items


def parse_index_or_name_selection(
    raw: str,
    names_ordered: Sequence[str],
    allow_all: bool = True,
) -> Tuple[List[str], List[str]]:
    tokens = [tok for tok in re.split(r"[,\s]+", raw.strip()) if tok]
    if allow_all and len(tokens) == 1 and tokens[0].upper() == "ALL":
        return list(names_ordered), []

    errors: List[str] = []
    selected: List[str] = []
    seen: Set[str] = set()
    name_map = {name.lower(): name for name in names_ordered}
    for token in tokens:
        picked: Optional[str] = None
        if token.isdigit():
            idx = int(token)
            if 1 <= idx <= len(names_ordered):
                picked = names_ordered[idx - 1]
            else:
                errors.append(f"Index out of range: {token}")
        else:
            picked = name_map.get(token.lower())
            if picked is None:
                errors.append(f"Unknown name token: {token}")
        if picked and picked not in seen:
            seen.add(picked)
            selected.append(picked)
    return selected, errors


def prompt_select_datapath_signals(top_module: ModuleInfo) -> List[str]:
    signal_items = top_signal_entries(top_module)
    if not signal_items:
        raise RuntimeError(f"No signals found in top module: {top_module.name}")

    print("")
    print(f"[INFO] Top module signal list: {top_module.name}")
    names_ordered: List[str] = []
    for idx, (name, kind) in enumerate(signal_items, start=1):
        names_ordered.append(name)
        print(f"  [{idx}] {name} ({kind})")
    print("")
    print("[INFO] DataPath signal selection format:")
    print("  - ALL")
    print("  - Number list: 1,2,3")
    print("  - Name list: signal_a,signal_b")

    while True:
        raw = input("DataPath signal selection (required): ").strip()
        if not raw:
            print("[ERROR] Selection cannot be empty.")
            continue
        selected, errors = parse_index_or_name_selection(raw, names_ordered, allow_all=True)
        if errors:
            for err in errors:
                print(f"[ERROR] {err}")
            continue
        if not selected:
            print("[ERROR] No valid signal selected.")
            continue
        print("[INFO] Selected DataPath signals:")
        for sig in selected:
            print(f"  - {sig}")
        return selected


def prompt_select_module_rank(module_names: Sequence[str]) -> Dict[str, int]:
    print("")
    print("[INFO] Module detail order input (rank source):")
    for idx, name in enumerate(module_names, start=1):
        print(f"  [{idx}] {name}")
    print("")
    print("[INFO] Order selection format:")
    print("  - ALL")
    print("  - Number list: 1,5,3")
    print("  - Name list: TOP,uart_rx,uart_tx")

    while True:
        raw = input("Module order input (required, default ALL): ").strip()
        if not raw:
            raw = "ALL"
        selected, errors = parse_index_or_name_selection(raw, module_names, allow_all=True)
        if errors:
            for err in errors:
                print(f"[ERROR] {err}")
            continue
        if not selected:
            print("[ERROR] No valid module selected.")
            continue
        rank: Dict[str, int] = {}
        for idx, name in enumerate(selected):
            rank[name] = idx
        tail = len(rank)
        for name in module_names:
            if name not in rank:
                rank[name] = tail
                tail += 1
        print("[INFO] Rank order applied.")
        return rank


def build_sorted_children(mod: ModuleInfo, modules_by_name: Dict[str, ModuleInfo], rank: Dict[str, int]) -> List[str]:
    children = mod.direct_children(set(modules_by_name.keys()))
    children.sort(key=lambda n: (rank.get(n, 10**9), n.lower()))
    return children


def discover_testbenches(tb_dir: Path) -> List[Path]:
    if not tb_dir.exists():
        return []
    files = sorted(tb_dir.glob("*.v")) + sorted(tb_dir.glob("*.sv"))
    return sorted(set(files), key=lambda p: p.name.lower())


def auto_map_testbench(tb_file: Path, module_names: Sequence[str]) -> Optional[str]:
    stem = tb_file.stem.lower()
    for mod in module_names:
        mod_l = mod.lower()
        if stem == f"tb_{mod_l}" or stem == f"{mod_l}_tb":
            return mod
    return None


def prompt_map_unmatched_testbenches(
    unmatched: Sequence[Path], module_names: Sequence[str]
) -> Dict[str, List[Path]]:
    mapping: Dict[str, List[Path]] = defaultdict(list)
    if not unmatched:
        return mapping

    print("")
    print("[INFO] Unmatched testbench files need mapping.")
    for tb in unmatched:
        print("")
        print(f"[TB] {tb.name}")
        for idx, name in enumerate(module_names, start=1):
            print(f"  [{idx}] {name}")
        while True:
            raw = input("Map to module (index/name/skip): ").strip()
            if not raw or raw.lower() == "skip":
                break
            picked: Optional[str] = None
            if raw.isdigit():
                idx = int(raw)
                if 1 <= idx <= len(module_names):
                    picked = module_names[idx - 1]
            else:
                picked = next((name for name in module_names if name.lower() == raw.lower()), None)
            if picked:
                mapping[picked].append(tb)
                break
            print("[ERROR] Invalid module selection.")
    return mapping


def choose_waveform_asset(project_root: Path, module_name: str, tb_file: Path, presentation_dir: Path) -> str:
    tb_stem = tb_file.stem
    candidates = [
        project_root / "output" / f"{tb_stem}.png",
        project_root / "output" / f"{tb_stem}.svg",
        project_root / "output" / f"{tb_stem}.jpg",
        project_root / "output" / "FINALReport" / "assets" / "waveform" / f"{tb_stem}.png",
        project_root / "output" / "FINALReport" / "assets" / "waveform" / f"{tb_stem}.svg",
        project_root / "output" / "FINALReport" / "assets" / "waveform" / f"{module_name}.png",
        project_root / "output" / "FINALReport" / "assets" / "waveform" / f"{module_name}.svg",
    ]
    for item in candidates:
        if item.exists():
            return os.path.relpath(item, presentation_dir).replace("\\", "/")
    return ""


def build_output_image_index(project_root: Path) -> Dict[str, List[Path]]:
    output_dir = project_root / "output"
    index: Dict[str, List[Path]] = defaultdict(list)
    if not output_dir.exists():
        return index

    for path in output_dir.rglob("*"):
        if not path.is_file():
            continue
        if path.suffix.lower() not in IMAGE_EXTENSIONS:
            continue
        stem = path.stem.lower()
        keys = {stem}
        for prefix in ("output_", "skin_"):
            if stem.startswith(prefix) and len(stem) > len(prefix):
                keys.add(stem[len(prefix) :])
        for suffix in ("_detailed", "_simple", "_fsm", "_fsm_fsm"):
            if stem.endswith(suffix) and len(stem) > len(suffix):
                keys.add(stem[: -len(suffix)])
        for key in keys:
            index[key].append(path)
    return index


def find_first_existing_rel(presentation_dir: Path, candidates: Iterable[Path]) -> str:
    for item in candidates:
        if item.exists():
            return os.path.relpath(item, presentation_dir).replace("\\", "/")
    return ""


def dedup_paths(paths: Iterable[Path]) -> List[Path]:
    out: List[Path] = []
    seen: Set[str] = set()
    for path in paths:
        key = str(path).lower()
        if key in seen:
            continue
        seen.add(key)
        out.append(path)
    return out


def image_rank(path: Path, module_name: str, kind: str) -> Tuple[int, int, str]:
    module_l = module_name.lower()
    parent = str(path.parent).replace("\\", "/").lower()
    stem = path.stem.lower()
    ext = path.suffix.lower()
    score = 0

    if kind == "fsm":
        if "/fsm/svg" in parent and stem in {f"{module_l}_fsm", f"{module_l}_fsm_fsm"}:
            score += 100
        elif "/fsm" in parent and module_l in stem and "fsm" in stem:
            score += 90
        elif module_l in stem and "fsm" in stem:
            score += 70
    elif kind == "top":
        if "/diagram/detailed" in parent and stem == f"{module_l}_detailed":
            score += 100
        elif "/diagram/simple" in parent and stem == module_l:
            score += 90
        elif module_l in stem:
            score += 50
    else:
        if "/diagram/simple" in parent and stem == module_l:
            score += 100
        elif "/diagram/detailed" in parent and stem == f"{module_l}_detailed":
            score += 95
        elif "/diagram/detailed" in parent and stem == module_l:
            score += 90
        elif stem == module_l:
            score += 75
        elif stem in {f"{module_l}_detailed", f"output_{module_l}", f"skin_{module_l}"}:
            score += 70
        elif module_l in stem:
            score += 45

    if ext == ".svg":
        score += 10
    elif ext == ".png":
        score += 7
    elif ext in {".jpg", ".jpeg"}:
        score += 5

    return (-score, len(str(path)), str(path).lower())


def select_image_from_index(
    module_name: str,
    kind: str,
    image_index: Dict[str, List[Path]],
    presentation_dir: Path,
) -> str:
    module_l = module_name.lower()
    candidates: List[Path] = []
    if kind == "fsm":
        preferred_keys = [f"{module_l}_fsm", f"{module_l}_fsm_fsm"]
    elif kind == "top":
        preferred_keys = [f"{module_l}_detailed", module_l, f"output_{module_l}", f"skin_{module_l}"]
    else:
        preferred_keys = [module_l, f"{module_l}_detailed", f"output_{module_l}", f"skin_{module_l}"]

    for key in preferred_keys:
        candidates.extend(image_index.get(key, []))

    if kind == "fsm":
        for key, paths in image_index.items():
            if "fsm" not in key:
                continue
            if key == module_l or key.startswith(f"{module_l}_") or key.endswith(f"_{module_l}"):
                candidates.extend(paths)
    else:
        for key, paths in image_index.items():
            if key.startswith(f"{module_l}_") and ("detailed" in key or "simple" in key):
                candidates.extend(paths)

    unique_candidates = dedup_paths(candidates)
    if not unique_candidates:
        return ""
    unique_candidates.sort(key=lambda p: image_rank(p, module_name, kind))
    return os.path.relpath(unique_candidates[0], presentation_dir).replace("\\", "/")


def build_image_candidate_paths(base_dir: Path, stems: Sequence[str]) -> List[Path]:
    out: List[Path] = []
    seen: Set[str] = set()
    for stem in stems:
        if not stem:
            continue
        for ext in IMAGE_EXTENSIONS:
            key = f"{stem.lower()}{ext}"
            if key in seen:
                continue
            seen.add(key)
            out.append(base_dir / f"{stem}{ext}")
    return out


def resolve_module_simple_image(
    module_name: str,
    project_root: Path,
    presentation_dir: Path,
    image_index: Dict[str, List[Path]],
) -> str:
    candidates: List[Path] = []
    candidates.extend(
        build_image_candidate_paths(
            project_root / "output" / "Diagram" / "Simple",
            [module_name, module_name.lower(), f"{module_name}_simple", f"{module_name}_detailed"],
        )
    )
    candidates.extend(
        build_image_candidate_paths(
            project_root / "output" / "Diagram" / "Detailed",
            [f"{module_name}_detailed", module_name, module_name.lower()],
        )
    )
    candidates.extend(
        build_image_candidate_paths(
            project_root / "output" / "Diagram" / "JSON",
            [f"output_{module_name}", f"skin_{module_name}", f"output_{module_name.lower()}", f"skin_{module_name.lower()}"],
        )
    )
    candidates.extend(build_image_candidate_paths(project_root / "output", [module_name, module_name.lower()]))

    resolved = find_first_existing_rel(presentation_dir, candidates)
    if resolved:
        return resolved
    return select_image_from_index(module_name, "simple", image_index, presentation_dir)


def resolve_module_fsm_image(
    module_name: str,
    project_root: Path,
    presentation_dir: Path,
    image_index: Dict[str, List[Path]],
) -> str:
    candidates: List[Path] = []
    candidates.extend(
        build_image_candidate_paths(
            project_root / "output" / "fsm" / "svg",
            [f"{module_name}_fsm", f"{module_name}_fsm_fsm", module_name],
        )
    )
    candidates.extend(
        build_image_candidate_paths(
            project_root / "output" / "fsm",
            [f"{module_name}_fsm", f"{module_name}_fsm_fsm", module_name],
        )
    )
    resolved = find_first_existing_rel(presentation_dir, candidates)
    if resolved:
        return resolved
    return select_image_from_index(module_name, "fsm", image_index, presentation_dir)


def resolve_top_block_image(
    top_name: str,
    project_root: Path,
    presentation_dir: Path,
    image_index: Dict[str, List[Path]],
) -> str:
    candidates: List[Path] = []
    candidates.extend(
        build_image_candidate_paths(
            project_root / "output" / "Diagram" / "Detailed",
            [f"{top_name}_detailed", top_name],
        )
    )
    candidates.extend(
        build_image_candidate_paths(
            project_root / "output" / "Diagram" / "Simple",
            [top_name, f"{top_name}_simple", f"{top_name}_detailed"],
        )
    )
    resolved = find_first_existing_rel(presentation_dir, candidates)
    if resolved:
        return resolved
    return select_image_from_index(top_name, "top", image_index, presentation_dir)


def is_external_path(path_text: str) -> bool:
    lower = path_text.strip().lower()
    return lower.startswith("http://") or lower.startswith("https://") or lower.startswith("data:")


def resolve_existing_path(path_text: str, project_root: Path, presentation_dir: Path) -> Optional[Path]:
    raw = (path_text or "").strip()
    if not raw or is_external_path(raw):
        return None
    p = Path(raw)
    if p.is_absolute():
        return p if p.exists() else None

    candidates = [
        (presentation_dir / raw).resolve(),
        (project_root / raw).resolve(),
    ]
    if raw.startswith("../"):
        candidates.append((project_root / raw[3:]).resolve())

    for c in candidates:
        if c.exists():
            return c
    return None


def copy_asset_to_presentation(
    source: Path,
    presentation_dir: Path,
    bucket: str,
    copied_cache: Dict[Tuple[str, str], str],
) -> str:
    source_resolved = source.resolve()
    cache_key = (str(source_resolved).lower(), bucket)
    if cache_key in copied_cache:
        return copied_cache[cache_key]

    safe_bucket = re.sub(r"[^A-Za-z0-9_-]+", "_", bucket.strip() or "misc")
    dst_dir = presentation_dir / "assets" / safe_bucket
    dst_dir.mkdir(parents=True, exist_ok=True)

    stem = re.sub(r"[^A-Za-z0-9._-]+", "_", source_resolved.stem).strip("._")
    if not stem:
        stem = "asset"
    digest = hashlib.md5(str(source_resolved).encode("utf-8")).hexdigest()[:8]
    ext = source_resolved.suffix or ".bin"
    dst_name = f"{stem}_{digest}{ext}"
    dst_path = dst_dir / dst_name
    if not dst_path.exists():
        shutil.copy2(source_resolved, dst_path)

    rel = os.path.relpath(dst_path, presentation_dir).replace("\\", "/")
    if not rel.startswith("."):
        rel = f"./{rel}"
    copied_cache[cache_key] = rel
    return rel


def materialize_presentation_assets(
    presentation_config: dict,
    project_root: Path,
    presentation_dir: Path,
) -> None:
    copied_cache: Dict[Tuple[str, str], str] = {}

    def rewrite_path(container: dict, key: str, bucket: str) -> None:
        value = container.get(key)
        if not isinstance(value, str):
            return
        raw = value.strip()
        if not raw or is_external_path(raw):
            return
        src = resolve_existing_path(raw, project_root, presentation_dir)
        if src is None:
            return
        container[key] = copy_asset_to_presentation(src, presentation_dir, bucket, copied_cache)

    assets = presentation_config.get("assets")
    if isinstance(assets, dict):
        rewrite_path(assets, "topBlockSvg", "top")
        rewrite_path(assets, "testbenchWaveform", "waveform")
        rewrite_path(assets, "timingDiagramSvg", "timing")
        rewrite_path(assets, "clockResetTreeSvg", "clock_reset")
        rewrite_path(assets, "powerReportRpt", "reports")
        rewrite_path(assets, "timingReportRpt", "reports")
        rewrite_path(assets, "utilReportRpt", "reports")

    modules = presentation_config.get("modules")
    if not isinstance(modules, list):
        return

    for module in modules:
        if not isinstance(module, dict):
            continue
        kind = str(module.get("slideKind", "module")).strip().lower()
        if kind == "testbench":
            rewrite_path(module, "testbenchWaveform", "waveform")
        else:
            rewrite_path(module, "simpleDiagramSvg", "diagram")
            rewrite_path(module, "fsmImage", "fsm")


def module_layout(mod: ModuleInfo, modules_by_name: Dict[str, ModuleInfo]) -> str:
    children = mod.direct_children(set(modules_by_name.keys()))
    if children:
        return "parent-module"
    if mod.has_fsm:
        return "fsm-module"
    return "leaf-module"


def build_module_slides(
    top_name: str,
    modules_by_name: Dict[str, ModuleInfo],
    rank: Dict[str, int],
    tb_map: Dict[str, List[Path]],
    project_root: Path,
    presentation_dir: Path,
    image_index: Dict[str, List[Path]],
) -> List[dict]:
    emitted: Set[str] = set()
    visiting: Set[str] = set()
    slides: List[dict] = []

    def emit_module(name: str) -> None:
        if name in emitted:
            return
        if name in visiting:
            print(f"[WARN] Cycle detected in hierarchy at module: {name}")
            return
        if name not in modules_by_name:
            return

        visiting.add(name)
        mod = modules_by_name[name]
        children = build_sorted_children(mod, modules_by_name, rank)
        layout = module_layout(mod, modules_by_name)

        simple_svg = resolve_module_simple_image(
            module_name=name,
            project_root=project_root,
            presentation_dir=presentation_dir,
            image_index=image_index,
        )
        fsm_svg = resolve_module_fsm_image(
            module_name=name,
            project_root=project_root,
            presentation_dir=presentation_dir,
            image_index=image_index,
        )
        role_text = mod.role.strip() if mod.role.strip() else "[Input Needed] Role comment not found."
        summary_items = [item for item in mod.summary if item.strip()]
        if not summary_items:
            summary_items = [
                "[Input Needed] Summary #1",
                "[Input Needed] Summary #2",
            ]
        elif len(summary_items) == 1:
            summary_items.append("[Input Needed] Summary #2")

        child_modules = [
            {
                "name": child,
                "role": (modules_by_name[child].role.strip() if modules_by_name[child].role.strip() else ""),
            }
            for child in children
        ]

        slides.append(
            {
                "slideKind": "module",
                "name": name,
                "role": role_text,
                "summary": summary_items,
                "stateDescription": mod.state_description,
                "simpleDiagramSvg": simple_svg,
                "fsmImage": fsm_svg,
                "detailLayout": layout,
                "childModules": child_modules,
            }
        )

        for child in children:
            emit_module(child)

        if layout == "parent-module":
            for tb_file in tb_map.get(name, []):
                waveform = choose_waveform_asset(project_root, name, tb_file, presentation_dir)
                slides.append(
                    {
                        "slideKind": "testbench",
                        "name": tb_file.stem,
                        "linkedModule": name,
                        "testbenchFiles": [os.path.relpath(tb_file, presentation_dir).replace("\\", "/")],
                        "testbenchWaveform": waveform,
                        "testbenchChecks": [
                            "Reset release and startup behavior",
                            "Main control/data handshake timing",
                            "Boundary/error stimulus handling result",
                        ],
                    }
                )

        visiting.remove(name)
        emitted.add(name)

    ordered_roots = [top_name] + [n for n in sorted(modules_by_name, key=lambda x: (rank.get(x, 10**9), x.lower())) if n != top_name]
    for root in ordered_roots:
        emit_module(root)
    return slides


def collect_tb_mapping(project_root: Path, module_names: Sequence[str]) -> Dict[str, List[Path]]:
    tb_files = discover_testbenches(project_root / "tb")
    mapped: Dict[str, List[Path]] = defaultdict(list)
    unmatched: List[Path] = []

    for tb_file in tb_files:
        target = auto_map_testbench(tb_file, module_names)
        if target:
            mapped[target].append(tb_file)
        else:
            unmatched.append(tb_file)

    if unmatched:
        manual_map = prompt_map_unmatched_testbenches(unmatched, module_names)
        for module_name, files in manual_map.items():
            mapped[module_name].extend(files)

    for key in list(mapped.keys()):
        dedup = sorted(set(mapped[key]), key=lambda p: p.name.lower())
        mapped[key] = dedup
    return mapped


def build_presentation_config(
    project_root: Path,
    top_name: str,
    modules_by_name: Dict[str, ModuleInfo],
    datapath_signals: Sequence[str],
    rank: Dict[str, int],
    tb_map: Dict[str, List[Path]],
    presentation_dir: Path,
    image_index: Dict[str, List[Path]],
    project_display_name: str,
    author_name: str,
) -> dict:
    now = datetime.now()
    project_name = project_root.name
    top_module = modules_by_name[top_name]

    top_block_svg = resolve_top_block_image(
        top_name=top_name,
        project_root=project_root,
        presentation_dir=presentation_dir,
        image_index=image_index,
    )

    default_tb_wave = find_first_existing_rel(
        presentation_dir,
        [
            project_root / "output" / "FINALReport" / "assets" / "waveform" / "testbench_overview.png",
            project_root / "output" / "FINALReport" / "assets" / "waveform" / "testbench_overview.svg",
        ],
    )

    power_report = find_first_existing_rel(
        presentation_dir, [project_root / "output" / "reports" / "power_report.rpt"]
    )
    timing_report = find_first_existing_rel(
        presentation_dir, [project_root / "output" / "reports" / "timing_summary.rpt"]
    )
    util_report = find_first_existing_rel(
        presentation_dir,
        [
            project_root / "output" / "reports" / "post_place_util.rpt",
            project_root / "output" / "reports" / "post_synth_util.rpt",
        ],
    )

    module_slides = build_module_slides(
        top_name=top_name,
        modules_by_name=modules_by_name,
        rank=rank,
        tb_map=tb_map,
        project_root=project_root,
        presentation_dir=presentation_dir,
        image_index=image_index,
    )

    signal_kind_map = {name: kind for name, kind in top_signal_entries(top_module)}
    datapath_steps = [f"{name} ({signal_kind_map.get(name, 'signal')})" for name in datapath_signals]

    os_label = f"{platform.system()} {platform.release()}".strip()

    return {
        "meta": {
            "projectTitle": f"Project Presentation: {project_display_name}",
            "projectSubtitle": f"Auto-generated from RTL source (Top: {top_name})",
            "author": author_name,
            "date": now.strftime("%Y-%m-%d"),
            "team": "FPGA Team",
            "cover": {
                "titleLine1": "FPGA Project",
                "titleLine2": project_display_name,
                "subtitle": f"Top module: {top_name}",
                "dateLabel": "Date",
                "authorLabel": "Author",
            },
        },
        "developmentEnvironment": {
            "os": os_label,
            "tools": ["Vivado", "Icarus Verilog", "Python", "Jinja2"],
            "language": ["Verilog", "SystemVerilog"],
        },
        "featurePlaceholders": [
            {
                "title": "Top Architecture",
                "description": f"Hierarchy-driven summary from {top_name}",
            },
            {
                "title": "Module Details",
                "description": "1 module per page with role/summary and FSM or hierarchy layout",
            },
            {
                "title": "Datapath",
                "description": "Selected signal path list from top module",
            },
            {
                "title": "Verification",
                "description": "Testbench slides inserted after 6.3 module subtree",
            },
        ],
        "constraints": [
            "[Input Needed] Clock constraint and timing budget",
            "[Input Needed] I/O standard and pin policy",
            "[Input Needed] CDC/reset release policy",
            "[Input Needed] Resource/power target",
        ],
        "timingNotes": [
            "[Input Needed] Main timing path notes",
            "[Input Needed] Setup/hold exception rationale",
            "[Input Needed] Validation vs design intent",
        ],
        "datapathFlowSteps": datapath_steps,
        "clockFlowSteps": [
            "[Input Needed] Clock source generation",
            "[Input Needed] Clock distribution path",
            "[Input Needed] Clock domain boundary checks",
        ],
        "resetFlowSteps": [
            "[Input Needed] Reset source and polarity",
            "[Input Needed] Reset sync and release order",
            "[Input Needed] Safe startup condition",
        ],
        "conclusionPoints": [
            "[Input Needed] Implementation result summary",
            "[Input Needed] Requirement coverage and limits",
        ],
        "conclusionNextSteps": [
            "[Input Needed] Improvement roadmap",
            "[Input Needed] Additional test/validation plan",
        ],
        "assets": {
            "topBlockSvg": top_block_svg,
            "testbenchWaveform": default_tb_wave,
            "timingDiagramSvg": "",
            "clockResetTreeSvg": "",
            "powerReportRpt": power_report,
            "timingReportRpt": timing_report,
            "utilReportRpt": util_report,
        },
        "modules": module_slides,
    }


def resolve_paths(args: argparse.Namespace) -> Tuple[Path, Path, Path, Path]:
    script_dir = Path(__file__).resolve().parent
    project_root = Path(args.project).resolve()
    default_template = (script_dir.parent / "Presentation" / "Presentation_templates.html").resolve()
    template_path = Path(args.template).resolve() if args.template else default_template

    presentation_dir = project_root / "Presentation"
    presentation_dir.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    default_prefix = f"presentation_{project_root.name}_{timestamp}"
    output_html = Path(args.output_html).resolve() if args.output_html else (presentation_dir / f"{default_prefix}.html")
    output_json = Path(args.output_json).resolve() if args.output_json else (presentation_dir / f"{default_prefix}.json")

    return project_root, template_path, output_html, output_json


def clean_presentation_assets(presentation_dir: Path) -> None:
    assets_dir = presentation_dir / "assets"
    if not assets_dir.exists():
        return
    if not assets_dir.is_dir():
        raise RuntimeError(f"Expected directory for assets path, got file: {assets_dir}")
    shutil.rmtree(assets_dir)
    print(f"[INFO] Cleaned previous assets directory: {assets_dir}")


def validate_environment(project_root: Path, template_path: Path) -> Path:
    src_dir = project_root / "src"
    if not project_root.exists():
        raise RuntimeError(f"Project path not found: {project_root}")
    if not src_dir.exists():
        raise RuntimeError(f"Source directory not found: {src_dir}")
    if not template_path.exists():
        raise RuntimeError(f"Template file not found: {template_path}")
    return src_dir


def render_html(template_path: Path, output_html: Path, presentation_config: dict) -> None:
    env = Environment(loader=FileSystemLoader(str(template_path.parent)), autoescape=False)
    template = env.get_template(template_path.name)
    html = template.render(presentation_config=presentation_config)
    output_html.parent.mkdir(parents=True, exist_ok=True)
    output_html.write_text(html, encoding="utf-8")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate presentation HTML/JSON from Verilog source",
    )
    parser.add_argument("--project", required=True, help="Target project directory")
    parser.add_argument("--top", default="", help="Top module name (optional)")
    parser.add_argument("--project-title", default="", help="Cover project title (optional)")
    parser.add_argument("--author", default="", help="Cover author name (optional)")
    parser.add_argument("--template", default="", help="Template HTML path (optional)")
    parser.add_argument("--output-html", default="", help="Output HTML path (optional)")
    parser.add_argument("--output-json", default="", help="Output JSON path (optional)")
    parser.add_argument(
        "--clean-assets",
        action="store_true",
        help="Clean existing Presentation/assets folder before generation",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        project_root, template_path, output_html, output_json = resolve_paths(args)
        src_dir = validate_environment(project_root, template_path)
        if args.clean_assets:
            clean_presentation_assets(output_html.parent)

        print("==============================================================================")
        print(" Presentation Generator (Python + Jinja2)")
        print("==============================================================================")
        print(f"[INFO] Project: {project_root}")
        print(f"[INFO] Template: {template_path}")

        modules_by_name = build_module_db(src_dir)
        if not modules_by_name:
            raise RuntimeError(f"No Verilog modules parsed from: {src_dir}")

        module_names = sorted(modules_by_name.keys(), key=lambda n: n.lower())
        print(f"[INFO] Parsed module count: {len(module_names)}")

        requested_top = args.top.strip()
        if requested_top:
            top_name = next((name for name in module_names if name.lower() == requested_top.lower()), "")
            if not top_name:
                raise RuntimeError(f"Top module not found: {requested_top}")
        else:
            top_name = prompt_select_top(modules_by_name, choose_top_module(modules_by_name))
        print(f"[INFO] Selected top module: {top_name}")

        default_project_title = args.project_title.strip() or project_root.name
        default_author_name = args.author.strip() or os.environ.get("USERNAME", "User")
        project_display_name, author_name = prompt_cover_meta(default_project_title, default_author_name)

        datapath_signals = prompt_select_datapath_signals(modules_by_name[top_name])
        rank = prompt_select_module_rank(module_names)

        tb_map = collect_tb_mapping(project_root, module_names)
        mapped_tb_count = sum(len(items) for items in tb_map.values())
        print(f"[INFO] Testbench files mapped: {mapped_tb_count}")
        image_index = build_output_image_index(project_root)

        presentation_config = build_presentation_config(
            project_root=project_root,
            top_name=top_name,
            modules_by_name=modules_by_name,
            datapath_signals=datapath_signals,
            rank=rank,
            tb_map=tb_map,
            presentation_dir=output_html.parent,
            image_index=image_index,
            project_display_name=project_display_name,
            author_name=author_name,
        )
        materialize_presentation_assets(presentation_config, project_root, output_html.parent)

        output_json.parent.mkdir(parents=True, exist_ok=True)
        output_json.write_text(
            json.dumps(presentation_config, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        render_html(template_path, output_html, presentation_config)

        print("------------------------------------------------------------------------------")
        print("[SUCCESS] Presentation generated.")
        print(f"[INFO] HTML: {output_html}")
        print(f"[INFO] JSON: {output_json}")
        return 0
    except KeyboardInterrupt:
        print("\n[ERROR] Interrupted by user.")
        return 130
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
