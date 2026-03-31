from __future__ import annotations

import pathlib
import re
from collections.abc import Callable
from typing import Any


PROGRAM_SECTION_START_TEMPLATE = "<!-- PROGRAM_SECTION:{program_key}:START -->"
PROGRAM_SECTION_END_TEMPLATE = "<!-- PROGRAM_SECTION:{program_key}:END -->"
DETAIL_SECTION_START_TEMPLATE = "<!-- DETAIL_SECTION:{detail_key}:{program_key}:START -->"
DETAIL_SECTION_END_TEMPLATE = "<!-- DETAIL_SECTION:{detail_key}:{program_key}:END -->"
DETAIL_SECTION_SPECS: tuple[tuple[str, str], ...] = (
    ("single_cycle", "Single-Cycle Optimization Detail"),
    ("pipeline_perf", "Pipeline Performance Detail"),
)
HEADING_PATTERN = re.compile(r"^(?P<hashes>#{1,6})(?P<suffix>\s+.*)$")


def normalize_section_body(text: str) -> str:
    stripped = text.strip()
    return stripped + "\n" if stripped else ""


def render_detail_placeholder(detail_title: str) -> str:
    return f"- No {detail_title.lower()} recorded yet for this program image.\n"


def strip_first_markdown_heading(text: str) -> str:
    lines = text.replace("\r\n", "\n").split("\n")
    stripped_lines = list(lines)
    if stripped_lines and stripped_lines[0].startswith("#"):
        stripped_lines = stripped_lines[1:]
        while stripped_lines and not stripped_lines[0].strip():
            stripped_lines = stripped_lines[1:]
    return "\n".join(stripped_lines).strip() + ("\n" if stripped_lines else "")


def shift_markdown_headings(text: str, increment: int) -> str:
    shifted_lines: list[str] = []
    for line in text.replace("\r\n", "\n").split("\n"):
        match = HEADING_PATTERN.match(line)
        if not match:
            shifted_lines.append(line)
            continue
        level = min(6, len(match.group("hashes")) + max(0, int(increment)))
        shifted_lines.append("#" * level + match.group("suffix"))
    return "\n".join(shifted_lines).strip() + ("\n" if shifted_lines else "")


def extract_existing_program_sections(report_text: str) -> dict[str, str]:
    normalized_text = report_text.replace("\r\n", "\n")
    pattern = re.compile(
        r"<!-- PROGRAM_SECTION:(?P<key>[a-z0-9_]+):START -->\n(?P<body>.*?)(?:\n)?<!-- PROGRAM_SECTION:(?P=key):END -->",
        flags=re.DOTALL,
    )
    sections: dict[str, str] = {}
    for match in pattern.finditer(normalized_text):
        sections[str(match.group("key"))] = normalize_section_body(str(match.group("body")))
    return sections


def extract_existing_detail_sections(section_text: str) -> dict[str, str]:
    normalized_text = section_text.replace("\r\n", "\n")
    pattern = re.compile(
        r"<!-- DETAIL_SECTION:(?P<detail_key>[a-z_]+):(?P<program_key>[a-z0-9_]+):START -->\n(?P<body>.*?)(?:\n)?<!-- DETAIL_SECTION:(?P=detail_key):(?P=program_key):END -->",
        flags=re.DOTALL,
    )
    sections: dict[str, str] = {}
    for match in pattern.finditer(normalized_text):
        sections[str(match.group("detail_key"))] = normalize_section_body(str(match.group("body")))
    return sections


def build_program_section(
    program_selection: dict[str, Any],
    detail_sections: dict[str, str],
) -> str:
    program_key = str(program_selection["key"])
    lines = [
        f"## {program_selection['display_name']}",
        "",
        f"- Program key: `{program_key}`",
        "",
    ]

    for detail_key, detail_title in DETAIL_SECTION_SPECS:
        lines.append(f"### {detail_title}")
        lines.append("")
        lines.append(DETAIL_SECTION_START_TEMPLATE.format(detail_key=detail_key, program_key=program_key))
        detail_body = normalize_section_body(detail_sections.get(detail_key, ""))
        if detail_body:
            lines.append(detail_body.rstrip())
        else:
            lines.append(render_detail_placeholder(detail_title).rstrip())
        lines.append(DETAIL_SECTION_END_TEMPLATE.format(detail_key=detail_key, program_key=program_key))
        lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def render_integrated_report(
    program_sections: dict[str, str],
    *,
    program_keys: list[str],
    resolve_program_selection: Callable[[str], dict[str, Any]],
) -> str:
    lines = [
        "# INTEGRATED_TIMING_REPORT",
        "",
        "- This report keeps one category per timing program image.",
        "- Re-running one timing flow refreshes only that flow's detail block for the selected program.",
        "",
    ]

    for program_key in program_keys:
        program_selection = resolve_program_selection(program_key)
        section_body = program_sections.get(program_key)
        if not section_body:
            section_body = build_program_section(program_selection, {})
        lines.append(PROGRAM_SECTION_START_TEMPLATE.format(program_key=program_key))
        lines.append(section_body.rstrip())
        lines.append(PROGRAM_SECTION_END_TEMPLATE.format(program_key=program_key))
        lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def merge_program_detail_section(
    report_path: pathlib.Path,
    *,
    program_selection: dict[str, Any],
    detail_key: str,
    detail_body: str,
    program_keys: list[str],
    resolve_program_selection: Callable[[str], dict[str, Any]],
) -> str:
    existing_program_sections: dict[str, str] = {}
    if report_path.exists():
        existing_program_sections = extract_existing_program_sections(report_path.read_text(encoding="utf-8", errors="ignore"))

    program_key = str(program_selection["key"])
    existing_detail_sections = extract_existing_detail_sections(existing_program_sections.get(program_key, ""))
    existing_detail_sections[detail_key] = normalize_section_body(detail_body)
    existing_program_sections[program_key] = build_program_section(program_selection, existing_detail_sections)

    return render_integrated_report(
        existing_program_sections,
        program_keys=program_keys,
        resolve_program_selection=resolve_program_selection,
    )
