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


def extract_declared_reg_logic_names(module_text: str) -> Set[str]:
    names: Set[str] = set()
    for m in re.finditer(r"\b(?:reg|logic)\b\s*([^;]+);", module_text, flags=re.IGNORECASE | re.DOTALL):
        decl = m.group(1)
        for item in split_top_level(decl, ","):
            token = item.strip()
            if not token:
                continue
            token = re.sub(r"=\s*.+$", " ", token)
            token = re.sub(r"\[[^\]]*\]", " ", token)
            token = re.sub(r"\b(signed|unsigned)\b", " ", token, flags=re.IGNORECASE)
            mm = re.search(r"([A-Za-z_][A-Za-z0-9_$]*)\s*$", token)
            if mm:
                names.add(mm.group(1))
    return names


def extract_always_blocks_for_fsm(module_text: str) -> List[Dict[str, str]]:
    blocks: List[Dict[str, str]] = []
    pattern = re.compile(
        r"(always\s*@\s*(?:\([^)]*\)|\*)|always_comb|always_ff|always_latch)\s*begin",
        flags=re.IGNORECASE,
    )
    token_re = re.compile(r"\bbegin\b|\bend\b", flags=re.IGNORECASE)

    for m in pattern.finditer(module_text):
        matched_text = m.group(0)
        begin_rel = matched_text.lower().rfind("begin")
        if begin_rel < 0:
            continue
        begin_pos = m.start() + begin_rel
        depth = 1
        end_pos = -1
        for tok in token_re.finditer(module_text, begin_pos + len("begin")):
            word = tok.group(0).lower()
            if word == "begin":
                depth += 1
            else:
                depth -= 1
                if depth == 0:
                    end_pos = tok.end()
                    break
        if end_pos < 0:
            continue

        blocks.append(
            {
                "header": module_text[m.start() : begin_pos].strip(),
                "text": module_text[begin_pos:end_pos],
            }
        )

    return blocks


def detect_state_vars_like_fsm_tool(module_text: str, always_blocks: Sequence[Dict[str, str]]) -> Optional[Tuple[str, str]]:
    reg_names = extract_declared_reg_logic_names(module_text)
    for cur in sorted(reg_names, key=lambda n: n.lower()):
        cur_l = cur.lower()
        if not re.search(r"(cur|state)", cur_l):
            continue
        preferred = [
            f"{cur}_d",
            f"{cur}d",
            f"{cur}_next",
            f"{cur}_nxt",
            f"next_{cur}",
            f"nxt_{cur}",
        ]
        for cand in preferred:
            if cand in reg_names:
                return cur, cand

    for block in always_blocks:
        header = block.get("header", "")
        text = block.get("text", "")
        if not re.search(r"(posedge|negedge)", header, flags=re.IGNORECASE):
            continue
        for lhs, rhs in re.findall(r"\b([A-Za-z_]\w*)\b\s*<=\s*([A-Za-z_]\w*)\b\s*;", text):
            lhs_l = lhs.lower()
            rhs_l = rhs.lower()
            if lhs_l == rhs_l:
                continue
            if not re.search(r"(cur|state)", lhs_l):
                continue
            rhs_looks_next = bool(
                re.search(r"(next|nxt)", rhs_l)
                or rhs_l.endswith("_d")
                or rhs_l == f"{lhs_l}_d"
                or rhs_l == f"{lhs_l}d"
            )
            if rhs_looks_next:
                return lhs, rhs

    for block in always_blocks:
        text = block.get("text", "")
        case_m = re.search(r"\bcase\s*\(\s*([A-Za-z_]\w*)\s*\)", text, flags=re.IGNORECASE)
        if not case_m:
            continue
        cur_var = case_m.group(1)
        assign_re = re.compile(
            rf"\b([A-Za-z_]\w*)\b\s*(?:<=|=)\s*\b{re.escape(cur_var)}\b\s*;",
            flags=re.IGNORECASE,
        )
        assign_m = assign_re.search(text)
        if assign_m:
            return cur_var, assign_m.group(1)
    return None


def find_next_state_block_like_fsm_tool(
    always_blocks: Sequence[Dict[str, str]], cur_var: str, next_var: str
) -> Optional[Dict[str, str]]:
    best_block: Optional[Dict[str, str]] = None
    best_score = -1
    next_re = re.compile(rf"\b{re.escape(next_var)}\b")
    case_re = re.compile(rf"\bcase\s*\(\s*{re.escape(cur_var)}\s*\)", flags=re.IGNORECASE)
    hold_re = re.compile(
        rf"\b{re.escape(next_var)}\s*(?:<=|=)\s*{re.escape(cur_var)}\b",
        flags=re.IGNORECASE,
    )
    assign_re = re.compile(rf"\b{re.escape(next_var)}\s*(?:<=|=)", flags=re.IGNORECASE)

    for block in always_blocks:
        text = block.get("text", "")
        if not next_re.search(text):
            continue
        score = 0
        if case_re.search(text):
            score += 20
        if hold_re.search(text):
            score += 10
        score += len(assign_re.findall(text))
        if score > best_score:
            best_score = score
            best_block = block
    return best_block


def extract_case_body_for_var(text: str, var_name: str) -> str:
    case_re = re.compile(rf"\bcase(?:x|z)?\s*\(\s*{re.escape(var_name)}\s*\)", flags=re.IGNORECASE)
    match = case_re.search(text)
    if not match:
        return ""
    start = match.end()
    token_re = re.compile(r"\bcase(?:x|z)?\b|\bendcase\b", flags=re.IGNORECASE)
    depth = 1
    for token in token_re.finditer(text, start):
        word = token.group(0).lower()
        if word.startswith("case"):
            depth += 1
        else:
            depth -= 1
            if depth == 0:
                return text[start : token.start()]
    return ""


def extract_case_labels(case_body: str) -> Set[str]:
    labels: Set[str] = set()
    if not case_body:
        return labels
    for m in re.finditer(r"^\s*([^:\n]+)\s*:", case_body, flags=re.MULTILINE):
        raw_label = m.group(1)
        for item in split_top_level(raw_label, ","):
            token = item.strip()
            if not token:
                continue
            if token.lower() == "default":
                continue
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_$]*", token):
                labels.add(token)
    return labels


def collect_named_state_symbols(module_text: str) -> Set[str]:
    symbols: Set[str] = set()
    for m in re.finditer(r"\b(?:localparam|parameter)\b([\s\S]*?);", module_text, flags=re.IGNORECASE):
        decl = m.group(1)
        for item in split_top_level(decl, ","):
            assign_m = re.search(r"\b([A-Za-z_][A-Za-z0-9_$]*)\b\s*=", item)
            if not assign_m:
                continue
            name = assign_m.group(1)
            if name.isupper() or re.search(r"(state|idle|init|run|wait|done|start|stop|edit|tx|rx)", name, flags=re.IGNORECASE):
                symbols.add(name)
    for m in re.finditer(r"\btypedef\s+enum\b[\s\S]*?\{([\s\S]*?)\}\s*[A-Za-z_]\w*\s*;", module_text, flags=re.IGNORECASE):
        body = m.group(1)
        for item in split_top_level(body, ","):
            name_m = re.match(r"\s*([A-Za-z_][A-Za-z0-9_$]*)", item)
            if name_m:
                symbols.add(name_m.group(1))
    return symbols


def detect_fsm(module_text: str, state_description: Sequence[str]) -> bool:
    if state_description:
        return True
    always_blocks = extract_always_blocks_for_fsm(module_text)
    if not always_blocks:
        return False

    vars_pair = detect_state_vars_like_fsm_tool(module_text, always_blocks)
    if not vars_pair:
        return False
    cur_var, next_var = vars_pair

    next_block = find_next_state_block_like_fsm_tool(always_blocks, cur_var, next_var)
    if not next_block:
        return False

    block_text = next_block.get("text", "")
    transition_targets = set(
        re.findall(
            rf"\b{re.escape(next_var)}\b\s*(?:<=|=)\s*([A-Za-z_][A-Za-z0-9_$]*)\b",
            block_text,
            flags=re.IGNORECASE,
        )
    )
    transition_targets.discard(cur_var)
    if not transition_targets:
        return False

    case_body = extract_case_body_for_var(block_text, cur_var)
    case_labels = extract_case_labels(case_body)
    declared_states = collect_named_state_symbols(module_text)
    known_states = case_labels | declared_states | transition_targets
    if len(known_states) < 2:
        return False

    if case_body:
        return bool(case_labels or transition_targets)
    return len(transition_targets) >= 2


def normalize_module_info_key(raw_key: str) -> str:
    key = re.sub(r"[\s_-]+", "", raw_key.strip().lower())
    if key in {"name", "modulename"}:
        return "name"
    if key in {
        "role",
        "modulerole",
        "function",
        "description",
        "역할",
        "모듈역할",
        "모듈기능",
        "기능",
        "모듈설명",
        "설명",
    }:
        return "role"
    if key in {
        "summary",
        "summary1",
        "summary2",
        "highlights",
        "요약",
        "요약1",
        "요약2",
        "핵심요약",
        "핵심",
    }:
        return "summary"
    if key in {
        "statedescription",
        "state",
        "states",
        "fsmstate",
        "fsmstatedescription",
        "상태설명",
        "상태",
        "상태기술",
        "상태기술설명",
        "fsm상태",
        "fsm상태설명",
    }:
        return "state"
    return ""


def normalize_module_info_value(value: str) -> str:
    text = value.strip()
    text = text.strip("`'\"")
    text = re.sub(r"\s+", " ", text).strip()
    return text


def split_summary_value(value: str) -> List[str]:
    if not value:
        return []
    if "|" in value:
        parts = [item.strip() for item in value.split("|")]
        return [item for item in parts if item]
    return [value]


def parse_module_info_block(block: str) -> Tuple[str, List[str], List[str]]:
    role = ""
    summary: List[str] = []
    state_description: List[str] = []
    section = ""

    for raw_line in block.splitlines():
        line = raw_line.strip()
        line = re.sub(r"^(?:/\*+|\*/|//+|\*+)\s*", "", line)
        line = re.sub(r"\s*\*/\s*$", "", line).strip()
        line = re.sub(r"^\[\s*MODULE_INFO_(?:START|END)\s*\]\s*$", "", line, flags=re.IGNORECASE).strip()
        if not line:
            continue

        key_match = re.match(r"^([A-Za-z가-힣_][A-Za-z0-9가-힣_\s-]*)\s*[:=\-]\s*(.*)$", line)
        if key_match:
            key = normalize_module_info_key(key_match.group(1))
            value = normalize_module_info_value(key_match.group(2))
            if key:
                if key == "name":
                    section = ""
                    continue
                if key == "role":
                    role = value or role
                    section = ""
                    continue
                if key == "summary":
                    section = "summary"
                    if value:
                        summary.extend(split_summary_value(value))
                    continue
                if key == "state":
                    section = "state"
                    if value:
                        state_description.append(value)
                    continue

        if re.match(r"^[A-Za-z가-힣_][A-Za-z0-9가-힣_\s-]*\s*[:=\-]", line):
            section = ""
            continue
        if re.match(r"^(?:[-*•]|[0-9]+\.)\s+", line):
            item = normalize_module_info_value(re.sub(r"^(?:[-*•]|[0-9]+\.)\s+", "", line))
            if not item:
                continue
            if section == "summary":
                summary.append(item)
            elif section == "state":
                state_description.append(item)
            continue
        if section == "summary":
            normalized = normalize_module_info_value(line)
            if normalized:
                summary.append(normalized)
        elif section == "state":
            normalized = normalize_module_info_value(line)
            if normalized:
                state_description.append(normalized)

    return role, summary, state_description


def parse_module_info_from_leading_comment(file_text: str, module_start: int) -> Tuple[str, List[str], List[str]]:
    prefix = file_text[:module_start]
    block_match = re.search(r"/\*([\s\S]*?)\*/\s*$", prefix, flags=re.IGNORECASE)
    if block_match:
        parsed = parse_module_info_block(block_match.group(1))
        if parsed[0] or parsed[1] or parsed[2]:
            return parsed
    line_match = re.search(r"((?:\s*//[^\n]*\n)+)\s*$", prefix, flags=re.IGNORECASE)
    if line_match:
        parsed = parse_module_info_block(line_match.group(1))
        if parsed[0] or parsed[1] or parsed[2]:
            return parsed
    return "", [], []


def parse_module_info_for_span(file_text: str, module_start: int, module_end: int) -> Tuple[str, List[str], List[str]]:
    matches = list(
        re.finditer(
            r"(?:\[\s*)?MODULE_INFO_START(?:\s*\])?([\s\S]*?)(?:\[\s*)?MODULE_INFO_END(?:\s*\])?",
            file_text,
            flags=re.IGNORECASE | re.DOTALL,
        )
    )
    if matches:
        inside = [m for m in matches if module_start <= m.start() and m.end() <= module_end]
        if inside:
            chosen = inside[0]
            return parse_module_info_block(chosen.group(1))
        before = [m for m in matches if m.end() <= module_start]
        if before:
            chosen = before[-1]
            return parse_module_info_block(chosen.group(1))
        after = [m for m in matches if m.start() >= module_start]
        if after:
            return parse_module_info_block(after[0].group(1))
        return parse_module_info_block(matches[0].group(1))
    return parse_module_info_from_leading_comment(file_text, module_start)


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


def find_first_existing_path(candidates: Iterable[Path]) -> Optional[Path]:
    for item in candidates:
        if item.exists():
            return item
    return None


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
            project_root / "output" / "Diagram" / "JSON",
            [
                f"skin_{top_name}",
                f"output_{top_name}",
                f"skin_{top_name.lower()}",
                f"output_{top_name.lower()}",
            ],
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
        is_top_module = name == top_name

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
        role_text = mod.role.strip() if mod.role.strip() else "[입력 필요] MODULE_INFO 주석의 역할(Role)을 입력하세요."
        summary_items = [item for item in mod.summary if item.strip()]
        if not summary_items:
            summary_items = [
                "[입력 필요] 요약 1",
                "[입력 필요] 요약 2",
            ]
        elif len(summary_items) == 1:
            summary_items.append("[입력 필요] 요약 2")

        child_modules = [
            {
                "name": child,
                "role": (modules_by_name[child].role.strip() if modules_by_name[child].role.strip() else ""),
            }
            for child in children
        ]

        # TOP module is explained by Top Block Diagram slide, so skip detail slide generation.
        if not is_top_module:
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

        if (not is_top_module) and layout == "parent-module":
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


def to_optional_float(raw: str) -> Optional[float]:
    text = str(raw or "").replace(",", "").strip()
    if not text:
        return None
    text = text.replace("*", "").strip()
    if text.startswith("<"):
        text = text[1:].strip()
    if text.endswith("%"):
        text = text[:-1].strip()
    if text.lower() in {"---", "na", "n/a", "unspecified", "-", "_"}:
        return None
    try:
        return float(text)
    except ValueError:
        return None


def find_metric_value(text: str, patterns: Sequence[str]) -> Optional[float]:
    lines = text.splitlines()
    for line in lines:
        for pattern in patterns:
            if not re.search(pattern, line, flags=re.IGNORECASE):
                continue
            tail = re.sub(pattern, " ", line, flags=re.IGNORECASE)
            m = re.search(r"[-+]?\d*\.?\d+(?:[eE][-+]?\d+)?", tail)
            if m:
                value = to_optional_float(m.group(0))
                if value is not None:
                    return value
    return None


def find_metric_text(text: str, patterns: Sequence[str]) -> str:
    lines = text.splitlines()
    for line in lines:
        for pattern in patterns:
            m = re.search(pattern, line, flags=re.IGNORECASE)
            if not m:
                continue
            tail = line[m.end() :].replace("|", " ").replace(":", " ").replace("=", " ").strip()
            if tail:
                parts = [p.strip() for p in re.split(r"\s{2,}", tail) if p.strip()]
                return parts[0] if parts else tail
    return ""


def find_metric_numbers(text: str, pattern: str) -> List[float]:
    lines = text.splitlines()
    for line in lines:
        if not re.search(pattern, line, flags=re.IGNORECASE):
            continue
        tail = re.sub(pattern, " ", line, flags=re.IGNORECASE)
        matches = re.findall(r"[-+]?\d*\.?\d+(?:[eE][-+]?\d+)?", tail)
        out = [v for v in (to_optional_float(x) for x in matches) if v is not None]
        if out:
            return out
    return []


def percent_of(part: Optional[float], total: Optional[float]) -> Optional[float]:
    if part is None or total is None or total <= 0:
        return None
    raw = (part / total) * 100.0
    return max(0.0, min(100.0, raw))


def parse_power_table_value(text: str, label_pattern: str) -> Optional[float]:
    matcher = re.compile(label_pattern, flags=re.IGNORECASE)
    for line in text.splitlines():
        if "|" not in line:
            continue
        cells = [c.strip() for c in line.split("|")[1:-1]]
        if len(cells) < 2:
            continue
        label = re.sub(r"\s+", " ", cells[0].replace("*", " ")).strip()
        if not matcher.fullmatch(label):
            continue
        value = to_optional_float(cells[1])
        if value is not None:
            return value
    return None


def first_not_none(*values: Optional[float]) -> Optional[float]:
    for value in values:
        if value is not None:
            return value
    return None


def parse_power_report_text(text: str) -> Dict[str, object]:
    total_from_table = parse_power_table_value(text, r"(?:Total|Total\s+On-Chip\s+Power\s*\(W\))")
    dynamic_from_table = parse_power_table_value(text, r"Dynamic(?:\s*\(W\))?")
    static_from_table = parse_power_table_value(text, r"(?:Device\s+)?Static(?:\s+Power)?(?:\s*\(W\))?")
    clocks_from_table = parse_power_table_value(text, r"Clocks?")
    signals_from_table = parse_power_table_value(text, r"Signals?")
    logic_from_table = parse_power_table_value(text, r"(?:Slice\s+Logic|Logic)")
    io_from_table = parse_power_table_value(text, r"(?:I/O|IO)")

    return {
        "totalOnChipPowerW": first_not_none(
            total_from_table,
            find_metric_value(text, [r"Total\s+On[- ]Chip\s+Power"]),
        ),
        "dynamicPowerW": first_not_none(
            dynamic_from_table,
            find_metric_value(text, [r"(?:Total\s+)?Dynamic(?:\s+On[- ]Chip)?(?:\s+Power)?\b"]),
        ),
        "staticPowerW": first_not_none(
            static_from_table,
            find_metric_value(text, [r"(?:Device\s+)?Static(?:\s+Power)?\b"]),
        ),
        "clocksW": first_not_none(clocks_from_table, find_metric_value(text, [r"\bClocks?\b"])),
        "signalsW": first_not_none(signals_from_table, find_metric_value(text, [r"\bSignals?\b"])),
        "logicW": first_not_none(logic_from_table, find_metric_value(text, [r"\bLogic\b"])),
        "bramW": find_metric_value(text, [r"\bBRAM\b"]),
        "pllW": find_metric_value(text, [r"\bPLL\b"]),
        "ioW": first_not_none(io_from_table, find_metric_value(text, [r"\b(?:I/O|IO)\b"])),
        "junctionTempC": find_metric_value(text, [r"Junction\s+Temperature"]),
        "effectiveTjaCPerW": find_metric_value(text, [r"Effective\s+TJA"]),
        "maxAmbientC": find_metric_value(text, [r"Max\s+Ambient"]),
        "thermalMarginC": find_metric_value(text, [r"Thermal\s+Margin"]),
        "confidenceLevel": find_metric_text(text, [r"Confidence\s+Level"]),
    }


def parse_design_timing_summary_row(text: str) -> Dict[str, Optional[float]]:
    lines = text.splitlines()
    max_scan = 96
    for idx, line in enumerate(lines):
        if not re.search(r"\bDesign\s+Timing\s+Summary\b", line, flags=re.IGNORECASE):
            continue
        section = lines[idx : min(len(lines), idx + max_scan)]

        header_idx = -1
        for rel_idx, candidate in enumerate(section):
            if re.search(r"\bWNS\s*\(ns\)", candidate, flags=re.IGNORECASE) and re.search(
                r"\bTPWS(?:\s*\(ns\))?", candidate, flags=re.IGNORECASE
            ):
                header_idx = rel_idx
                break
        if header_idx < 0:
            continue

        for data_line in section[header_idx + 1 : header_idx + 14]:
            values = [to_optional_float(v) for v in re.findall(r"[-+]?\d*\.?\d+(?:[eE][-+]?\d+)?", data_line)]
            nums = [v for v in values if v is not None]
            if len(nums) < 12:
                continue
            return {
                "wnsNs": nums[0],
                "tnsNs": nums[1],
                "failingEndpoints": nums[2],
                "totalEndpoints": nums[3],
                "whsNs": nums[4],
                "thsNs": nums[5],
                "wpwsNs": nums[8],
                "tpwsNs": nums[9],
            }
    return {}


def parse_timing_detail_line(text: str, label: str) -> Dict[str, Optional[float]]:
    pattern = re.compile(
        rf"^\s*{re.escape(label)}\s*:\s*(\d+)\s+Failing\s+Endpoints,\s*Worst\s+Slack\s*"
        r"([-+]?\d*\.?\d+)\s*ns,\s*Total\s+Violation\s*([-+]?\d*\.?\d+)\s*ns",
        flags=re.IGNORECASE,
    )
    for line in text.splitlines():
        m = pattern.search(line)
        if not m:
            continue
        return {
            "failing": to_optional_float(m.group(1)),
            "worst": to_optional_float(m.group(2)),
            "total": to_optional_float(m.group(3)),
        }
    return {}


def parse_timing_report_text(text: str) -> Dict[str, object]:
    summary_row = parse_design_timing_summary_row(text)
    setup_detail = parse_timing_detail_line(text, "Setup")
    hold_detail = parse_timing_detail_line(text, "Hold")
    pw_detail = parse_timing_detail_line(text, "PW")

    wns = summary_row.get("wnsNs")
    tns = summary_row.get("tnsNs")
    whs = summary_row.get("whsNs")
    ths = summary_row.get("thsNs")
    wpws = summary_row.get("wpwsNs")
    tpws = summary_row.get("tpwsNs")
    failing = summary_row.get("failingEndpoints")
    total = summary_row.get("totalEndpoints")

    if wns is None:
        wns = setup_detail.get("worst")
    if tns is None:
        tns = setup_detail.get("total")
    if whs is None:
        whs = hold_detail.get("worst")
    if ths is None:
        ths = hold_detail.get("total")
    if wpws is None:
        wpws = pw_detail.get("worst")
    if tpws is None:
        tpws = pw_detail.get("total")
    if failing is None:
        failing = setup_detail.get("failing")

    return {
        "wnsNs": wns if wns is not None else find_metric_value(text, [r"\bWNS(?:\s*\(ns\))?\b"]),
        "tnsNs": tns if tns is not None else find_metric_value(text, [r"\bTNS(?:\s*\(ns\))?\b"]),
        "whsNs": whs if whs is not None else find_metric_value(text, [r"\bWHS(?:\s*\(ns\))?\b"]),
        "thsNs": ths if ths is not None else find_metric_value(text, [r"\bTHS(?:\s*\(ns\))?\b"]),
        "wpwsNs": wpws if wpws is not None else find_metric_value(text, [r"\bWPWS(?:\s*\(ns\))?\b"]),
        "tpwsNs": tpws if tpws is not None else find_metric_value(text, [r"\bTPWS(?:\s*\(ns\))?\b"]),
        "failingEndpoints": failing if failing is not None else find_metric_value(text, [r"Failing\s+Endpoints"]),
        "totalEndpoints": total if total is not None else find_metric_value(text, [r"Total\s+Endpoints"]),
    }


def normalize_util_label(raw: str) -> str:
    return re.sub(r"\s+", " ", str(raw or "").replace("*", " ")).strip()


def parse_util_table_rows(text: str) -> List[Dict[str, object]]:
    rows: List[Dict[str, object]] = []
    inside = False
    for line in text.splitlines():
        if (
            re.search(r"\|\s*Site\s+Type\s*\|", line, flags=re.IGNORECASE)
            and re.search(r"\|\s*Used\s*\|", line, flags=re.IGNORECASE)
            and re.search(r"\|\s*Available\s*\|", line, flags=re.IGNORECASE)
            and re.search(r"\|\s*Util%?\s*\|", line, flags=re.IGNORECASE)
        ):
            inside = True
            continue
        if not inside:
            continue
        trimmed = line.strip()
        if not trimmed:
            inside = False
            continue
        if "|" not in line or re.match(r"^\+-+", trimmed):
            continue
        cells = [c.strip() for c in line.split("|")[1:-1]]
        if len(cells) < 6:
            continue
        label = normalize_util_label(cells[0])
        if not label or re.fullmatch(r"site\s*type", label, flags=re.IGNORECASE):
            continue
        used = to_optional_float(cells[1])
        available = to_optional_float(cells[4])
        percent_raw = to_optional_float(cells[5])
        percent = percent_raw if percent_raw is not None else percent_of(used, available)
        # Keep only rows with utilization share (% > 0).
        if percent is None or percent <= 0:
            continue
        rows.append({"label": label, "used": used, "available": available, "percent": percent})

    deduped: List[Dict[str, object]] = []
    seen: Set[str] = set()
    for row in rows:
        key = str(row["label"]).lower()
        if key in seen:
            continue
        seen.add(key)
        deduped.append(row)
    return deduped


def parse_util_row_numbers(text: str, pattern: str) -> Dict[str, Optional[float]]:
    nums = find_metric_numbers(text, pattern)
    used = nums[0] if len(nums) > 0 else None
    available = nums[1] if len(nums) > 1 else None
    percent = nums[2] if len(nums) > 2 else percent_of(used, available)
    return {"used": used, "available": available, "percent": percent}


def parse_util_report_text(text: str) -> Dict[str, object]:
    util_resources = parse_util_table_rows(text)

    def pick_row(label_pattern: str) -> Optional[Dict[str, object]]:
        for row in util_resources:
            if re.search(label_pattern, str(row.get("label", "")), flags=re.IGNORECASE):
                return row
        return None

    lut_row = pick_row(r"\b(?:slice\s+luts?|luts?)\b")
    ff_row = pick_row(r"\b(?:slice\s+registers?|registers?|ff)\b")
    io_row = pick_row(r"\b(?:bonded\s+iobs?|i/o|io)\b")
    bufg_row = pick_row(r"\b(?:bufgctrl|bufg)\b")

    lut = lut_row or parse_util_row_numbers(text, r"(?:^|[|\s])(?:Slice\s+LUTs?|LUT)\b(?!RAM)")
    ff = ff_row or parse_util_row_numbers(text, r"(?:^|[|\s])(?:Slice\s+Registers?|FF)\b")
    io = io_row or parse_util_row_numbers(text, r"(?:^|[|\s])(?:Bonded\s+IOBs?|I/O|IO)\b")
    bufg = bufg_row or parse_util_row_numbers(text, r"(?:^|[|\s])BUFG(?:CTRL)?s?\b")

    lut_used = lut.get("used") if isinstance(lut, dict) else None
    lut_avail = lut.get("available") if isinstance(lut, dict) else None
    lut_pct = lut.get("percent") if isinstance(lut, dict) else None
    ff_used = ff.get("used") if isinstance(ff, dict) else None
    ff_avail = ff.get("available") if isinstance(ff, dict) else None
    ff_pct = ff.get("percent") if isinstance(ff, dict) else None
    io_used = io.get("used") if isinstance(io, dict) else None
    io_avail = io.get("available") if isinstance(io, dict) else None
    io_pct = io.get("percent") if isinstance(io, dict) else None
    bufg_used = bufg.get("used") if isinstance(bufg, dict) else None
    bufg_avail = bufg.get("available") if isinstance(bufg, dict) else None
    bufg_pct = bufg.get("percent") if isinstance(bufg, dict) else None

    return {
        "lutUsed": lut_used,
        "lutAvailable": lut_avail,
        "lutPct": lut_pct,
        "ffUsed": ff_used,
        "ffAvailable": ff_avail,
        "ffPct": ff_pct,
        "ioUsed": io_used,
        "ioAvailable": io_avail,
        "ioPct": io_pct,
        "bufgUsed": bufg_used,
        "bufgAvailable": bufg_avail,
        "bufgPct": bufg_pct,
        "utilResources": util_resources,
        "sliceLuts": lut_used,
        "sliceRegisters": ff_used,
        "bondedIob": io_used,
        "bufg": bufg_used,
    }


def parse_report_file(path: Optional[Path], parser) -> Dict[str, object]:
    if path is None or not path.exists():
        return {}
    try:
        text = read_text_autodetect(path)
    except Exception:
        return {}
    try:
        return parser(text)
    except Exception:
        return {}


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

    power_candidates = [
        project_root / "output" / "reports" / "power_report.rpt",
        project_root / "output" / "reports" / "post_route_power.rpt",
    ]
    timing_candidates = [
        project_root / "output" / "reports" / "timing_summary.rpt",
        project_root / "output" / "reports" / "post_route_timing_summary.rpt",
        project_root / "output" / "reports" / "timing_report.rpt",
    ]
    util_candidates = [
        project_root / "output" / "reports" / "post_route_util.rpt",
        project_root / "output" / "reports" / "post_route_utilization.rpt",
        project_root / "output" / "reports" / "post_place_util.rpt",
        project_root / "output" / "reports" / "post_synth_util.rpt",
        project_root / "output" / "reports" / "utilization_report.rpt",
    ]
    power_report_path = find_first_existing_path(power_candidates)
    timing_report_path = find_first_existing_path(timing_candidates)
    util_report_path = find_first_existing_path(util_candidates)
    power_report = (
        os.path.relpath(power_report_path, presentation_dir).replace("\\", "/")
        if power_report_path
        else ""
    )
    timing_report = (
        os.path.relpath(timing_report_path, presentation_dir).replace("\\", "/")
        if timing_report_path
        else ""
    )
    util_report = (
        os.path.relpath(util_report_path, presentation_dir).replace("\\", "/")
        if util_report_path
        else ""
    )
    parsed_power_report = parse_report_file(power_report_path, parse_power_report_text)
    parsed_timing_report = parse_report_file(timing_report_path, parse_timing_report_text)
    parsed_util_report = parse_report_file(util_report_path, parse_util_report_text)

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
            "tools": ["Vivado", "Python", "Jinja2"],
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
        "reportData": {
            "power": parsed_power_report,
            "timing": parsed_timing_report,
            "util": parsed_util_report,
        },
        "reportPreview": {
            "enableOnLoadFail": True,
            "power": parsed_power_report,
            "timing": parsed_timing_report,
            "util": parsed_util_report,
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
        default_author_name = args.author.strip() or "KOREA"
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
