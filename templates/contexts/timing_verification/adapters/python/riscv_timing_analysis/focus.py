from __future__ import annotations

import json
import pathlib
import re
from collections import Counter
from typing import Any, Callable

from .common import wsl_to_windows
from .rv32i import DEFAULT_CLASS_ORDER, MNEMONIC_CLASS_MAP


NOP_INSTR = 0x00000013


def sanitize_token(value: str) -> str:
    sanitized = re.sub(r"[^A-Za-z0-9_]+", "_", value.strip())
    sanitized = sanitized.strip("_")
    return sanitized or "focus"


def ordered_unique(values: list[str]) -> list[str]:
    seen: set[str] = set()
    ordered: list[str] = []
    for value in values:
        if value in seen:
            continue
        seen.add(value)
        ordered.append(value)
    return ordered


def strip_mem_lines(path: pathlib.Path) -> list[int]:
    values: list[int] = []
    for raw_line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw_line.split("//", 1)[0].strip().replace("_", "")
        if not line:
            continue
        values.append(int(line, 16))
    return values


def sign_extend(value: int, bits: int) -> int:
    sign_bit = 1 << (bits - 1)
    return (value & (sign_bit - 1)) - (value & sign_bit)


def decode_instruction(instr: int) -> dict[str, Any]:
    opcode = instr & 0x7F
    rd = (instr >> 7) & 0x1F
    funct3 = (instr >> 12) & 0x7
    rs1 = (instr >> 15) & 0x1F
    rs2 = (instr >> 20) & 0x1F
    funct7 = (instr >> 25) & 0x7F

    i_imm = sign_extend(instr >> 20, 12)
    s_imm = sign_extend(((instr >> 25) << 5) | ((instr >> 7) & 0x1F), 12)
    b_imm = sign_extend(
        (((instr >> 31) & 0x1) << 12)
        | (((instr >> 7) & 0x1) << 11)
        | (((instr >> 25) & 0x3F) << 5)
        | (((instr >> 8) & 0xF) << 1),
        13,
    )
    u_imm = instr & 0xFFFFF000
    j_imm = sign_extend(
        (((instr >> 31) & 0x1) << 20)
        | (((instr >> 12) & 0xFF) << 12)
        | (((instr >> 20) & 0x1) << 11)
        | (((instr >> 21) & 0x3FF) << 1),
        21,
    )

    info = {
        "instr": instr,
        "opcode": opcode,
        "rd": rd,
        "rs1": rs1,
        "rs2": rs2,
        "funct3": funct3,
        "funct7": funct7,
        "imm_i": i_imm,
        "imm_s": s_imm,
        "imm_b": b_imm,
        "imm_u": u_imm,
        "imm_j": j_imm,
        "writes_rd": False,
        "uses_rs1": False,
        "uses_rs2": False,
        "is_load": False,
        "is_store": False,
        "is_branch": False,
        "is_jump": False,
        "is_jalr": False,
        "mnemonic": "unknown",
        "class_name": "ILLEGAL",
    }

    if opcode == 0x33:
        info["class_name"] = "RTYPE"
        info["writes_rd"] = True
        info["uses_rs1"] = True
        info["uses_rs2"] = True
        table = {
            (0x0, 0x00): "add",
            (0x0, 0x20): "sub",
            (0x1, 0x00): "sll",
            (0x2, 0x00): "slt",
            (0x3, 0x00): "sltu",
            (0x4, 0x00): "xor",
            (0x5, 0x00): "srl",
            (0x5, 0x20): "sra",
            (0x6, 0x00): "or",
            (0x7, 0x00): "and",
        }
        info["mnemonic"] = table.get((funct3, funct7), "rtype")
    elif opcode == 0x13:
        info["class_name"] = "OPIMM"
        info["writes_rd"] = True
        info["uses_rs1"] = True
        table = {
            0x0: "addi",
            0x2: "slti",
            0x3: "sltiu",
            0x4: "xori",
            0x6: "ori",
            0x7: "andi",
            0x1: "slli",
            0x5: "srai" if funct7 == 0x20 else "srli",
        }
        info["mnemonic"] = table.get(funct3, "opimm")
    elif opcode == 0x03:
        info["class_name"] = "LOAD"
        info["writes_rd"] = True
        info["uses_rs1"] = True
        info["is_load"] = True
        table = {0x0: "lb", 0x1: "lh", 0x2: "lw", 0x4: "lbu", 0x5: "lhu"}
        info["mnemonic"] = table.get(funct3, "load")
    elif opcode == 0x23:
        info["class_name"] = "STORE"
        info["uses_rs1"] = True
        info["uses_rs2"] = True
        info["is_store"] = True
        table = {0x0: "sb", 0x1: "sh", 0x2: "sw"}
        info["mnemonic"] = table.get(funct3, "store")
    elif opcode == 0x63:
        info["class_name"] = "BRANCH"
        info["uses_rs1"] = True
        info["uses_rs2"] = True
        info["is_branch"] = True
        table = {
            0x0: "beq",
            0x1: "bne",
            0x4: "blt",
            0x5: "bge",
            0x6: "bltu",
            0x7: "bgeu",
        }
        info["mnemonic"] = table.get(funct3, "branch")
    elif opcode in (0x37, 0x17):
        info["class_name"] = "UPPER_IMM"
        info["writes_rd"] = True
        info["mnemonic"] = "lui" if opcode == 0x37 else "auipc"
    elif opcode in (0x6F, 0x67):
        info["class_name"] = "JUMP"
        info["writes_rd"] = True
        info["is_jump"] = True
        info["is_jalr"] = opcode == 0x67
        info["uses_rs1"] = opcode == 0x67
        info["mnemonic"] = "jalr" if opcode == 0x67 else "jal"
    elif opcode in (0x0F, 0x73):
        info["class_name"] = "SYSTEM"
        if opcode == 0x0F:
            info["mnemonic"] = "fence"
        else:
            imm12 = (instr >> 20) & 0xFFF
            info["mnemonic"] = {0x000: "ecall", 0x001: "ebreak"}.get(imm12, "system")

    return info


def read_mem_word(memory: dict[int, int], addr: int) -> int:
    base = addr & ~0x3
    value = 0
    for byte_idx in range(4):
        value |= (memory.get(base + byte_idx, 0) & 0xFF) << (8 * byte_idx)
    return value & 0xFFFFFFFF


def read_load(memory: dict[int, int], addr: int, funct3: int) -> int:
    if funct3 == 0x2:
        return read_mem_word(memory, addr)

    byte_value = memory.get(addr, 0) & 0xFF
    if funct3 == 0x0:
        return sign_extend(byte_value, 8) & 0xFFFFFFFF
    if funct3 == 0x4:
        return byte_value

    half_addr = addr & ~0x1
    half_value = (memory.get(half_addr, 0) & 0xFF) | ((memory.get(half_addr + 1, 0) & 0xFF) << 8)
    if funct3 == 0x1:
        return sign_extend(half_value, 16) & 0xFFFFFFFF
    if funct3 == 0x5:
        return half_value

    raise ValueError(f"Unsupported load funct3: {funct3}")


def write_store(memory: dict[int, int], addr: int, funct3: int, value: int) -> None:
    if funct3 == 0x0:
        memory[addr] = value & 0xFF
        return
    if funct3 == 0x1:
        memory[addr] = value & 0xFF
        memory[addr + 1] = (value >> 8) & 0xFF
        return
    if funct3 == 0x2:
        for byte_idx in range(4):
            memory[addr + byte_idx] = (value >> (8 * byte_idx)) & 0xFF
        return
    raise ValueError(f"Unsupported store funct3: {funct3}")


def access_byte_addresses(addr: int, funct3: int) -> list[int]:
    if funct3 in {0x0, 0x4}:
        return [addr]
    if funct3 in {0x1, 0x5}:
        return [addr, addr + 1]
    if funct3 == 0x2:
        return [addr + offset for offset in range(4)]
    return []


def trace_program_words(program_words: list[int]) -> dict[str, Any]:
    program = {idx * 4: value for idx, value in enumerate(program_words)}
    regs = [0] * 32
    memory: dict[int, int] = {}
    pc = 0
    retired: list[dict[str, Any]] = []
    seen_self_loop = 0

    while True:
        instr = program.get(pc, NOP_INSTR)
        info = decode_instruction(instr)
        info["pc"] = pc
        info["taken"] = False
        info["effective_addr"] = None
        info["memory_byte_addresses"] = []
        info["result"] = None
        old_pc = pc
        next_pc = (pc + 4) & 0xFFFFFFFF

        rs1_val = regs[info["rs1"]] if info["uses_rs1"] else 0
        rs2_val = regs[info["rs2"]] if info["uses_rs2"] else 0
        mnemonic = str(info["mnemonic"])

        if mnemonic == "add":
            result = (rs1_val + rs2_val) & 0xFFFFFFFF
        elif mnemonic == "sub":
            result = (rs1_val - rs2_val) & 0xFFFFFFFF
        elif mnemonic == "sll":
            result = (rs1_val << (rs2_val & 0x1F)) & 0xFFFFFFFF
        elif mnemonic == "slt":
            result = 1 if sign_extend(rs1_val, 32) < sign_extend(rs2_val, 32) else 0
        elif mnemonic == "sltu":
            result = 1 if rs1_val < rs2_val else 0
        elif mnemonic == "xor":
            result = (rs1_val ^ rs2_val) & 0xFFFFFFFF
        elif mnemonic == "srl":
            result = (rs1_val >> (rs2_val & 0x1F)) & 0xFFFFFFFF
        elif mnemonic == "sra":
            result = (sign_extend(rs1_val, 32) >> (rs2_val & 0x1F)) & 0xFFFFFFFF
        elif mnemonic == "or":
            result = (rs1_val | rs2_val) & 0xFFFFFFFF
        elif mnemonic == "and":
            result = (rs1_val & rs2_val) & 0xFFFFFFFF
        elif mnemonic == "addi":
            result = (rs1_val + int(info["imm_i"])) & 0xFFFFFFFF
        elif mnemonic == "slti":
            result = 1 if sign_extend(rs1_val, 32) < int(info["imm_i"]) else 0
        elif mnemonic == "sltiu":
            result = 1 if rs1_val < (int(info["imm_i"]) & 0xFFFFFFFF) else 0
        elif mnemonic == "xori":
            result = (rs1_val ^ (int(info["imm_i"]) & 0xFFFFFFFF)) & 0xFFFFFFFF
        elif mnemonic == "ori":
            result = (rs1_val | (int(info["imm_i"]) & 0xFFFFFFFF)) & 0xFFFFFFFF
        elif mnemonic == "andi":
            result = (rs1_val & (int(info["imm_i"]) & 0xFFFFFFFF)) & 0xFFFFFFFF
        elif mnemonic == "slli":
            result = (rs1_val << ((instr >> 20) & 0x1F)) & 0xFFFFFFFF
        elif mnemonic == "srli":
            result = (rs1_val >> ((instr >> 20) & 0x1F)) & 0xFFFFFFFF
        elif mnemonic == "srai":
            result = (sign_extend(rs1_val, 32) >> ((instr >> 20) & 0x1F)) & 0xFFFFFFFF
        elif mnemonic == "lui":
            result = int(info["imm_u"]) & 0xFFFFFFFF
        elif mnemonic == "auipc":
            result = (pc + int(info["imm_u"])) & 0xFFFFFFFF
        elif mnemonic in {"lb", "lh", "lw", "lbu", "lhu"}:
            addr = (rs1_val + int(info["imm_i"])) & 0xFFFFFFFF
            info["effective_addr"] = addr
            info["memory_byte_addresses"] = access_byte_addresses(addr, int(info["funct3"]))
            result = read_load(memory, addr, int(info["funct3"]))
        elif mnemonic in {"sb", "sh", "sw"}:
            addr = (rs1_val + int(info["imm_s"])) & 0xFFFFFFFF
            info["effective_addr"] = addr
            info["memory_byte_addresses"] = access_byte_addresses(addr, int(info["funct3"]))
            write_store(memory, addr, int(info["funct3"]), rs2_val)
            result = None
        elif mnemonic in {"beq", "bne", "blt", "bge", "bltu", "bgeu"}:
            taken = False
            if mnemonic == "beq":
                taken = rs1_val == rs2_val
            elif mnemonic == "bne":
                taken = rs1_val != rs2_val
            elif mnemonic == "blt":
                taken = sign_extend(rs1_val, 32) < sign_extend(rs2_val, 32)
            elif mnemonic == "bge":
                taken = sign_extend(rs1_val, 32) >= sign_extend(rs2_val, 32)
            elif mnemonic == "bltu":
                taken = rs1_val < rs2_val
            elif mnemonic == "bgeu":
                taken = rs1_val >= rs2_val
            info["taken"] = taken
            if taken:
                next_pc = (pc + int(info["imm_b"])) & 0xFFFFFFFF
            result = None
        elif mnemonic == "jal":
            result = (pc + 4) & 0xFFFFFFFF
            next_pc = (pc + int(info["imm_j"])) & 0xFFFFFFFF
            info["taken"] = True
        elif mnemonic == "jalr":
            result = (pc + 4) & 0xFFFFFFFF
            next_pc = (rs1_val + int(info["imm_i"])) & 0xFFFFFFFE
            info["taken"] = True
        elif mnemonic in {"fence", "ecall", "ebreak", "system"}:
            result = None
        else:
            raise ValueError(f"Unsupported mnemonic: {mnemonic}")

        info["result"] = result
        if info["writes_rd"] and info["rd"] != 0 and result is not None:
            regs[info["rd"]] = result & 0xFFFFFFFF
        regs[0] = 0

        retired.append(info)

        if mnemonic == "jal" and info["rd"] == 0 and next_pc == old_pc:
            seen_self_loop += 1
            if seen_self_loop >= 1:
                break

        pc = next_pc
        if len(retired) > 2000:
            raise RuntimeError("Instruction program did not converge during focus tracing.")

    class_counts = Counter(str(item["class_name"]) for item in retired)
    mnemonic_counts = Counter(str(item["mnemonic"]) for item in retired)

    dep_d1 = 0
    dep_d2 = 0
    load_use = 0
    branch_dep_d1 = 0
    branch_dep_d2 = 0
    jalr_dep_d1 = 0
    jalr_dep_d2 = 0
    forwarding_pairs: Counter[tuple[int, str, str]] = Counter()

    for idx, item in enumerate(retired):
        srcs: set[int] = set()
        if item["uses_rs1"] and item["rs1"] != 0:
            srcs.add(int(item["rs1"]))
        if item["uses_rs2"] and item["rs2"] != 0:
            srcs.add(int(item["rs2"]))

        for distance in (1, 2):
            if idx < distance:
                continue
            prev = retired[idx - distance]
            prev_rd = int(prev["rd"])
            if not prev["writes_rd"] or prev_rd == 0:
                continue
            if prev_rd not in srcs:
                continue

            forwarding_pairs[(distance, str(prev["class_name"]), str(item["class_name"]))] += 1
            if distance == 1:
                dep_d1 += 1
                if prev["is_load"]:
                    load_use += 1
                if item["is_branch"]:
                    branch_dep_d1 += 1
                if item["is_jalr"]:
                    jalr_dep_d1 += 1
            else:
                dep_d2 += 1
                if item["is_branch"]:
                    branch_dep_d2 += 1
                if item["is_jalr"]:
                    jalr_dep_d2 += 1

    branch_count = sum(1 for item in retired if item["is_branch"])
    branch_taken = sum(1 for item in retired if item["is_branch"] and item["taken"])
    jump_count = sum(1 for item in retired if item["is_jump"])

    return {
        "retired": retired,
        "retired_count": len(retired),
        "class_counts": dict(class_counts),
        "mnemonic_counts": dict(mnemonic_counts),
        "ordered_mnemonics": ordered_unique([str(item["mnemonic"]) for item in retired]),
        "hazards": {
            "raw_distance_1": dep_d1,
            "raw_distance_2": dep_d2,
            "load_use_distance_1": load_use,
            "branch_dep_distance_1": branch_dep_d1,
            "branch_dep_distance_2": branch_dep_d2,
            "jalr_dep_distance_1": jalr_dep_d1,
            "jalr_dep_distance_2": jalr_dep_d2,
            "branch_count": branch_count,
            "branch_taken": branch_taken,
            "branch_taken_ratio": (branch_taken / branch_count) if branch_count else 0.0,
            "jump_count": jump_count,
            "forwarding_pairs": {
                f"d{distance}_{prod}_{cons}": count
                for (distance, prod, cons), count in sorted(forwarding_pairs.items())
            },
        },
    }


def find_last_reg_producer(retired: list[dict[str, Any]], start_idx: int, reg_idx: int) -> int | None:
    for idx in range(start_idx - 1, -1, -1):
        item = retired[idx]
        if item["writes_rd"] and item["rd"] == reg_idx:
            return idx
    return None


def find_last_store_for_byte(retired: list[dict[str, Any]], start_idx: int, byte_addr: int) -> int | None:
    for idx in range(start_idx - 1, -1, -1):
        item = retired[idx]
        if item["is_store"] and byte_addr in item["memory_byte_addresses"]:
            return idx
    return None


def build_context_kept_pcs(
    retired: list[dict[str, Any]],
    predicate: Callable[[dict[str, Any]], bool],
) -> tuple[set[int], set[int]]:
    target_indices = [idx for idx, item in enumerate(retired) if predicate(item)]
    if not target_indices:
        raise RuntimeError("No retired instructions matched the requested focus predicate.")

    keep_dynamic: set[int] = set()

    def keep_with_support(idx: int) -> None:
        if idx in keep_dynamic:
            return

        keep_dynamic.add(idx)
        item = retired[idx]

        if item["uses_rs1"] and item["rs1"] != 0:
            producer_idx = find_last_reg_producer(retired, idx, int(item["rs1"]))
            if producer_idx is not None:
                keep_with_support(producer_idx)

        if item["uses_rs2"] and item["rs2"] != 0:
            producer_idx = find_last_reg_producer(retired, idx, int(item["rs2"]))
            if producer_idx is not None:
                keep_with_support(producer_idx)

        if item["is_load"]:
            for byte_addr in item["memory_byte_addresses"]:
                store_idx = find_last_store_for_byte(retired, idx, int(byte_addr))
                if store_idx is not None:
                    keep_with_support(store_idx)

    for idx in target_indices:
        keep_with_support(idx)

    changed = True
    while changed:
        changed = False
        max_keep_idx = max(keep_dynamic)
        for idx in range(max_keep_idx + 1):
            item = retired[idx]
            if not (item["is_branch"] or item["is_jump"]):
                continue
            if idx in keep_dynamic:
                continue
            keep_with_support(idx)
            changed = True

    kept_pcs = {int(retired[idx]["pc"]) for idx in keep_dynamic}
    return kept_pcs, keep_dynamic


def build_focus_program_image(program_words: list[int], kept_pcs: set[int]) -> list[int]:
    image = [NOP_INSTR] * max(256, len(program_words))
    for word_idx, word in enumerate(program_words):
        pc = word_idx * 4
        if pc in kept_pcs:
            image[word_idx] = word
    return image


def remove_sv_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    text = re.sub(r"//.*", "", text)
    return text


def split_top_level_commas(text: str) -> list[str]:
    items: list[str] = []
    depth = 0
    start = 0
    for idx, char in enumerate(text):
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth = max(0, depth - 1)
        elif char == "," and depth == 0:
            items.append(text[start:idx])
            start = idx + 1
    items.append(text[start:])
    return items


def find_module_source_path(source_files: list[pathlib.Path], module_name: str) -> pathlib.Path:
    module_pattern = re.compile(rf"\bmodule\s+{re.escape(module_name)}\b")
    for path in source_files:
        if path.suffix.lower() not in {".sv", ".v"}:
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        if module_pattern.search(text):
            return path
    raise FileNotFoundError(f"Could not locate source file for module `{module_name}`.")


def parse_ansi_module_ports(source_text: str, module_name: str) -> list[dict[str, str]]:
    cleaned = remove_sv_comments(source_text)
    module_match = re.search(rf"\bmodule\s+{re.escape(module_name)}\s*\(", cleaned)
    if not module_match:
        raise ValueError(f"Could not find ANSI module header for `{module_name}`.")

    cursor = module_match.end()
    depth = 1
    header_chars: list[str] = []
    while cursor < len(cleaned):
        char = cleaned[cursor]
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                break
        header_chars.append(char)
        cursor += 1

    if depth != 0:
        raise ValueError(f"Could not parse module header for `{module_name}`.")

    header = "".join(header_chars)
    items = split_top_level_commas(header)

    ports: list[dict[str, str]] = []
    current_direction = ""
    for raw_item in items:
        item = " ".join(raw_item.strip().split())
        if not item:
            continue

        direction_match = re.match(r"^(input|output|inout)\b(.*)$", item)
        if direction_match:
            current_direction = direction_match.group(1)
            item = direction_match.group(2).strip()
        if not current_direction:
            continue

        name_tokens = re.findall(r"[A-Za-z_][A-Za-z0-9_$]*", item)
        if not name_tokens:
            continue
        ports.append({"name": name_tokens[-1], "direction": current_direction})

    if not ports:
        raise ValueError(f"No ports were parsed for module `{module_name}`.")
    return ports


def focus_matches_filter(kind: str, focus_name: str, selected_focuses: set[str] | None) -> bool:
    if not selected_focuses:
        return True
    lowered = focus_name.lower()
    return lowered in selected_focuses or f"{kind}:{lowered}" in selected_focuses


def render_defparam_wrapper(
    *,
    wrapper_module_name: str,
    top_name: str,
    top_ports: list[dict[str, str]],
    clock_port: str,
    reset_port: str,
    instance_name: str,
    rom_param_path: str,
    mem_file_path: pathlib.Path,
) -> str:
    wrapper_ports: list[str] = []
    if clock_port:
        wrapper_ports.append(f"  input logic {clock_port}")
    if reset_port:
        wrapper_ports.append(f"  input logic {reset_port}")

    inst_lines: list[str] = []
    for port in top_ports:
        name = port["name"]
        direction = port["direction"]
        if name == clock_port or name == reset_port:
            conn = name
        elif direction == "input":
            conn = "'0"
        else:
            conn = ""
        inst_lines.append(f"    .{name}({conn})")

    joined_inst = ",\n".join(inst_lines)
    mem_file_win = wsl_to_windows(mem_file_path)

    return (
        "`timescale 1ns / 1ps\n\n"
        f"module {wrapper_module_name} (\n"
        + ",\n".join(wrapper_ports)
        + "\n);\n\n"
        f'  defparam {instance_name}.{rom_param_path} = "{mem_file_win}";\n\n'
        f"  {top_name} {instance_name} (\n"
        f"{joined_inst}\n"
        "  );\n\n"
        "endmodule\n"
    )


def prepare_focus_analysis_assets(
    contract: dict[str, Any],
    focus_cfg: dict[str, Any],
    output_dir: pathlib.Path,
    *,
    selected_focuses: set[str] | None = None,
) -> dict[str, Any]:
    project_root = pathlib.Path(contract["project_root"])
    output_dir.mkdir(parents=True, exist_ok=True)
    images_dir = output_dir / "focus_images"
    wrappers_dir = output_dir / "focus_wrappers"
    images_dir.mkdir(parents=True, exist_ok=True)
    wrappers_dir.mkdir(parents=True, exist_ok=True)

    mem_relpath = str(focus_cfg.get("instruction_mem_relpath", "src/InstructionFORTIMING.mem"))
    mem_path = project_root / mem_relpath
    if not mem_path.exists():
        raise FileNotFoundError(f"Instruction memory file was not found: {mem_path}")

    program_words = strip_mem_lines(mem_path)
    trace = trace_program_words(program_words)
    retired = list(trace["retired"])

    top_name = str(contract["top_name"])
    top_source_path = find_module_source_path(list(contract["source_files"]), top_name)
    top_ports = parse_ansi_module_ports(top_source_path.read_text(encoding="utf-8", errors="ignore"), top_name)
    instance_name = str(focus_cfg.get("wrapper_instance_name", "uDesign"))
    rom_param_path = str(focus_cfg["rom_param_path"])
    wrapper_prefix = str(focus_cfg.get("wrapper_module_prefix", "TimingFocusTop_"))

    focus_entries: list[dict[str, Any]] = []
    if bool(focus_cfg.get("emit_class_focus", True)):
        class_counts = dict(trace["class_counts"])
        for class_name in DEFAULT_CLASS_ORDER:
            if int(class_counts.get(class_name, 0)) <= 0:
                continue
            if not focus_matches_filter("class", class_name, selected_focuses):
                continue
            kept_pcs, keep_dynamic = build_context_kept_pcs(retired, lambda item, target=class_name: item["class_name"] == target)
            safe_name = sanitize_token(class_name.lower())
            mem_out = images_dir / f"class_{safe_name}.mem"
            mem_out.write_text("\n".join(f"{value:08x}" for value in build_focus_program_image(program_words, kept_pcs)) + "\n", encoding="utf-8")
            wrapper_module_name = f"{wrapper_prefix}{safe_name.upper()}"
            wrapper_path = wrappers_dir / f"{wrapper_module_name}.sv"
            wrapper_path.write_text(
                render_defparam_wrapper(
                    wrapper_module_name=wrapper_module_name,
                    top_name=top_name,
                    top_ports=top_ports,
                    clock_port=str(contract["clock_port"]),
                    reset_port=str(contract["reset_port"]),
                    instance_name=instance_name,
                    rom_param_path=rom_param_path,
                    mem_file_path=mem_out,
                ),
                encoding="utf-8",
            )
            focus_entries.append(
                {
                    "kind": "class",
                    "focus_name": class_name,
                    "focus_key": class_name,
                    "class_name": class_name,
                    "instruction_count": int(class_counts.get(class_name, 0)),
                    "kept_pc_count": len(kept_pcs),
                    "kept_dynamic_count": len(keep_dynamic),
                    "output_dir_name": f"class_{safe_name}",
                    "wrapper_module_name": wrapper_module_name,
                    "wrapper_path": str(wrapper_path.resolve()),
                    "mem_path": str(mem_out.resolve()),
                }
            )

    if bool(focus_cfg.get("emit_mnemonic_focus", True)):
        mnemonic_counts = dict(trace["mnemonic_counts"])
        for mnemonic in trace["ordered_mnemonics"]:
            if not focus_matches_filter("mnemonic", mnemonic, selected_focuses):
                continue
            class_name = MNEMONIC_CLASS_MAP.get(mnemonic.lower())
            if not class_name:
                continue
            kept_pcs, keep_dynamic = build_context_kept_pcs(retired, lambda item, target=mnemonic: item["mnemonic"] == target)
            safe_name = sanitize_token(mnemonic.lower())
            mem_out = images_dir / f"mnemonic_{safe_name}.mem"
            mem_out.write_text("\n".join(f"{value:08x}" for value in build_focus_program_image(program_words, kept_pcs)) + "\n", encoding="utf-8")
            wrapper_module_name = f"{wrapper_prefix}{safe_name.upper()}"
            wrapper_path = wrappers_dir / f"{wrapper_module_name}.sv"
            wrapper_path.write_text(
                render_defparam_wrapper(
                    wrapper_module_name=wrapper_module_name,
                    top_name=top_name,
                    top_ports=top_ports,
                    clock_port=str(contract["clock_port"]),
                    reset_port=str(contract["reset_port"]),
                    instance_name=instance_name,
                    rom_param_path=rom_param_path,
                    mem_file_path=mem_out,
                ),
                encoding="utf-8",
            )
            focus_entries.append(
                {
                    "kind": "mnemonic",
                    "focus_name": mnemonic,
                    "focus_key": mnemonic,
                    "class_name": class_name,
                    "instruction_count": int(mnemonic_counts.get(mnemonic, 0)),
                    "kept_pc_count": len(kept_pcs),
                    "kept_dynamic_count": len(keep_dynamic),
                    "output_dir_name": f"mnemonic_{safe_name}",
                    "wrapper_module_name": wrapper_module_name,
                    "wrapper_path": str(wrapper_path.resolve()),
                    "mem_path": str(mem_out.resolve()),
                }
            )

    metadata = {
        "analysis_mode": "instruction_focus",
        "project_name": contract["project_name"],
        "project_root": str(project_root),
        "top_name": top_name,
        "clock_port": str(contract["clock_port"]),
        "reset_port": str(contract["reset_port"]),
        "instruction_mem_path": str(mem_path.resolve()),
        "rom_param_path": rom_param_path,
        "top_source_path": str(top_source_path.resolve()),
        "focus_entries": focus_entries,
        "class_counts": dict(trace["class_counts"]),
        "mnemonic_counts": dict(trace["mnemonic_counts"]),
        "ordered_mnemonics": list(trace["ordered_mnemonics"]),
        "hazards": dict(trace["hazards"]),
        "retired_count": int(trace["retired_count"]),
        "selected_focuses": sorted(selected_focuses) if selected_focuses else [],
    }

    metadata_path = output_dir / "focus_analysis_metadata.json"
    metadata_path.write_text(json.dumps(metadata, indent=2), encoding="utf-8")
    return metadata


def load_focus_analysis_metadata(output_dir: pathlib.Path) -> dict[str, Any]:
    metadata_path = output_dir / "focus_analysis_metadata.json"
    if not metadata_path.exists():
        return {}
    return json.loads(metadata_path.read_text(encoding="utf-8"))
