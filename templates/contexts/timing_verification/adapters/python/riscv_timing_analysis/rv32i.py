from __future__ import annotations

import pathlib
import re
from collections import Counter
from typing import Any


DEFAULT_CLASS_ORDER = (
    "RTYPE",
    "OPIMM",
    "LOAD",
    "STORE",
    "BRANCH",
    "UPPER_IMM",
    "JUMP",
    "SYSTEM",
)

MNEMONIC_CLASS_MAP = {
    "add": "RTYPE",
    "sub": "RTYPE",
    "sll": "RTYPE",
    "slt": "RTYPE",
    "sltu": "RTYPE",
    "xor": "RTYPE",
    "srl": "RTYPE",
    "sra": "RTYPE",
    "or": "RTYPE",
    "and": "RTYPE",
    "addi": "OPIMM",
    "slti": "OPIMM",
    "sltiu": "OPIMM",
    "xori": "OPIMM",
    "ori": "OPIMM",
    "andi": "OPIMM",
    "slli": "OPIMM",
    "srli": "OPIMM",
    "srai": "OPIMM",
    "lw": "LOAD",
    "lh": "LOAD",
    "lb": "LOAD",
    "lhu": "LOAD",
    "lbu": "LOAD",
    "sw": "STORE",
    "sh": "STORE",
    "sb": "STORE",
    "beq": "BRANCH",
    "bne": "BRANCH",
    "blt": "BRANCH",
    "bge": "BRANCH",
    "bltu": "BRANCH",
    "bgeu": "BRANCH",
    "lui": "UPPER_IMM",
    "auipc": "UPPER_IMM",
    "jal": "JUMP",
    "jalr": "JUMP",
    "fence": "SYSTEM",
    "ecall": "SYSTEM",
    "ebreak": "SYSTEM",
}

OPCODE_CLASS_MAP = {
    0b0110011: "RTYPE",
    0b0010011: "OPIMM",
    0b0000011: "LOAD",
    0b0100011: "STORE",
    0b1100011: "BRANCH",
    0b0010111: "UPPER_IMM",
    0b0110111: "UPPER_IMM",
    0b1101111: "JUMP",
    0b1100111: "JUMP",
    0b0001111: "SYSTEM",
    0b1110011: "SYSTEM",
}


def classify_mnemonic(mnemonic: str) -> str | None:
    return MNEMONIC_CLASS_MAP.get(mnemonic.lower())


def classify_word(word: int) -> str | None:
    return OPCODE_CLASS_MAP.get(word & 0x7F)


def parse_asm_instructions(asm_path: pathlib.Path) -> list[dict[str, Any]]:
    instructions: list[dict[str, Any]] = []
    for line_no, raw_line in enumerate(asm_path.read_text(encoding="utf-8", errors="ignore").splitlines(), start=1):
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        if ":" in line:
            line = line.split(":", 1)[1].strip()
        if not line:
            continue
        mnemonic = re.split(r"[\s,]+", line)[0].lower()
        class_name = classify_mnemonic(mnemonic)
        if not class_name:
            continue
        instructions.append(
            {
                "line_no": line_no,
                "mnemonic": mnemonic,
                "class_name": class_name,
            }
        )
    return instructions


def parse_instruction_program(project_root: pathlib.Path) -> tuple[dict[str, int], str, list[str]]:
    details = parse_instruction_program_details(project_root)
    return details["class_counts"], details["instruction_source"], list(details["warnings"])


def parse_instruction_program_details(project_root: pathlib.Path) -> dict[str, Any]:
    asm_path = project_root / "src" / "InstructionFORTIMING.s"
    mem_path = project_root / "src" / "InstructionFORTIMING.mem"
    class_counts = Counter({class_name: 0 for class_name in DEFAULT_CLASS_ORDER})
    mnemonic_counts: Counter[str] = Counter()
    ordered_mnemonics: list[str] = []
    instructions: list[dict[str, Any]] = []
    warnings: list[str] = []

    if asm_path.exists():
        instructions = parse_asm_instructions(asm_path)
        seen_mnemonics: set[str] = set()
        for row in instructions:
            class_name = row["class_name"]
            mnemonic = row["mnemonic"]
            class_counts[class_name] += 1
            mnemonic_counts[mnemonic] += 1
            if mnemonic not in seen_mnemonics:
                seen_mnemonics.add(mnemonic)
                ordered_mnemonics.append(mnemonic)
        return {
            "class_counts": dict(class_counts),
            "mnemonic_counts": dict(mnemonic_counts),
            "ordered_mnemonics": ordered_mnemonics,
            "instructions": instructions,
            "instruction_source": str(asm_path),
            "warnings": warnings,
        }

    if mem_path.exists():
        for raw_line in mem_path.read_text(encoding="utf-8", errors="ignore").splitlines():
            token = raw_line.strip().replace("_", "")
            if not token:
                continue
            try:
                class_name = classify_word(int(token, 16))
            except ValueError:
                continue
            if class_name:
                class_counts[class_name] += 1
        warnings.append("InstructionFORTIMING.mem was used, so mnemonic-level timing rows could not be resolved.")
        return {
            "class_counts": dict(class_counts),
            "mnemonic_counts": {},
            "ordered_mnemonics": [],
            "instructions": [],
            "instruction_source": str(mem_path),
            "warnings": warnings,
        }

    warnings.append("InstructionFORTIMING.s or InstructionFORTIMING.mem was not found.")
    return {
        "class_counts": dict(class_counts),
        "mnemonic_counts": {},
        "ordered_mnemonics": [],
        "instructions": [],
        "instruction_source": "NA",
        "warnings": warnings,
    }
