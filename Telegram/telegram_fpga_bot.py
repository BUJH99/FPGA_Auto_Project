#!/usr/bin/env python3
"""Telegram bridge for FPGA automation scripts (MAIN.bat menu coverage)."""

from __future__ import annotations

import atexit
import json
import mimetypes
import os
import re
import shlex
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import urllib.parse
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
BOT_REPO_ROOT = SCRIPT_DIR.parent
DEFAULT_AUTOMATION_REPO_ROOT = BOT_REPO_ROOT
DEFAULT_ENV_PATH = SCRIPT_DIR / "telegram_fpga_bot.env"
DEFAULT_SECRET_PATH = BOT_REPO_ROOT.parent / "MOBILE_AGENT_TOKEN" / "TELEGRAMTOKEN_ID.txt"
LOCK_PATH = Path(tempfile.gettempdir()) / "telegram_fpga_bot.lock"
LOCK_HANDLE = None
VIVADO_LOG_FRESH_SLACK_SEC = 60.0
HIERARCHY_LOG_FRESH_SLACK_SEC = 30.0
SIM_VIVADO_PROMPT_TIMEOUT_SEC = 180
REPORT_ARTIFACT_RECENT_SLACK_SEC = 5.0


@dataclass(frozen=True)
class MenuEntry:
    menu_no: int
    script_rel: str
    script_path: Path


@dataclass
class Config:
    bot_token: str
    allowed_user_ids: set[int]
    allowed_usernames: set[str]
    allowed_chat_ids: set[int]
    automation_repo_root: Path
    automation_templates_root: Path
    main_bat_path: Path
    menu_registry: dict[int, MenuEntry]
    project_root: Path
    poll_timeout_sec: int
    command_timeout_sec: int
    skip_pending_updates: bool
    auto_delete_webhook_on_start: bool
    progress_interval_sec: int
    send_diagrams: bool
    max_diagram_files: int
    sim_vivado_log_lines: int
    sim_vivado_send_log_file: bool
    sim_vivado_auto_complete_on_replay: bool
    sim_vivado_replay_check_sec: int


@dataclass(frozen=True)
class JobRequest:
    command_name: str
    menu_no: int | None
    project_name: str | None
    script_path: Path
    cwd: Path
    cmd: tuple[str, ...]
    stdin_text: str | None
    artifact_paths: tuple[Path, ...]
    sim_vivado_close_gui: bool | None


class RuntimeState:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self.current_job: dict[str, object] | None = None
        self.last_job: dict[str, object] | None = None
        self.user_states: dict[int, dict[str, object]] = {}
        self.sim_vivado_prompts: dict[str, dict[str, object]] = {}

    def try_start_job(self, job: dict[str, object]) -> bool:
        with self._lock:
            if self.current_job is not None:
                return False
            self.current_job = job
            return True

    def finish_job(self, result: dict[str, object]) -> None:
        with self._lock:
            self.current_job = None
            self.last_job = result

    def snapshot(self) -> tuple[dict[str, object] | None, dict[str, object] | None]:
        with self._lock:
            current = dict(self.current_job) if self.current_job else None
            last = dict(self.last_job) if self.last_job else None
        return current, last
        
    def get_user_state(self, user_id: int) -> dict[str, object]:
        with self._lock:
            if user_id not in self.user_states:
                self.user_states[user_id] = {}
            return self.user_states[user_id]
            
    def update_user_state(self, user_id: int, updates: dict[str, object]) -> None:
        with self._lock:
            if user_id not in self.user_states:
                self.user_states[user_id] = {}
            self.user_states[user_id].update(updates)

    def clear_user_state(self, user_id: int) -> None:
        with self._lock:
            if user_id in self.user_states:
                self.user_states.pop(user_id)

    def register_sim_vivado_prompt(self, token: str, payload: dict[str, object]) -> None:
        with self._lock:
            self.sim_vivado_prompts[token] = payload

    def get_sim_vivado_prompt(self, token: str) -> dict[str, object] | None:
        with self._lock:
            return self.sim_vivado_prompts.get(token)

    def resolve_sim_vivado_prompt(self, token: str, decision: str) -> bool:
        with self._lock:
            prompt = self.sim_vivado_prompts.get(token)
            if prompt is None:
                return False
            prompt["decision"] = decision
            prompt["resolved"] = True
            event_obj = prompt.get("event")
            if isinstance(event_obj, threading.Event):
                event_obj.set()
            return True

    def pop_sim_vivado_prompt(self, token: str) -> None:
        with self._lock:
            self.sim_vivado_prompts.pop(token, None)


STATE = RuntimeState()


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

HIERARCHY_SCOPE_CALLBACK_CODES: dict[str, str] = {
    "src": "src",
    "tb_only": "tb",
}


def load_env_file(path: Path) -> None:
    if not path.exists():
        return

    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if value.startswith(("'", '"')) and value.endswith(("'", '"')) and len(value) >= 2:
            value = value[1:-1]
        if key:
            os.environ.setdefault(key, value)


def set_env_if_blank(key: str, value: str) -> None:
    current = os.getenv(key)
    if current is None or not current.strip():
        os.environ[key] = value


def next_non_empty_line(lines: list[str], start_idx: int) -> str:
    for idx in range(start_idx, len(lines)):
        candidate = lines[idx].strip()
        if candidate and not candidate.startswith("#"):
            return candidate
    return ""


def clean_secret_value(raw: str) -> str:
    value = raw.strip()
    while len(value) >= 2:
        if value[0] == "<" and value[-1] == ">":
            value = value[1:-1].strip()
            continue
        if value[0] == '"' and value[-1] == '"':
            value = value[1:-1].strip()
            continue
        if value[0] == "'" and value[-1] == "'":
            value = value[1:-1].strip()
            continue
        break
    return value


def normalize_username(raw: str) -> str:
    username = clean_secret_value(raw)
    if username.startswith("@"):
        username = username[1:]
    return username.lower()


def parse_username_set(raw: str, var_name: str) -> set[str]:
    values: set[str] = set()
    cleaned = raw.strip()
    if not cleaned:
        return values

    for token in cleaned.split(","):
        item = normalize_username(token)
        if not item:
            continue
        if re.search(r"\s", item):
            raise ValueError(f"{var_name} has invalid username value: {token.strip()}")
        values.add(item)
    return values


def parse_user_tokens(raw: str) -> tuple[set[int], set[str]]:
    user_ids: set[int] = set()
    usernames: set[str] = set()
    for token in raw.split(","):
        item = clean_secret_value(token)
        if not item:
            continue
        if re.fullmatch(r"-?\d+", item):
            user_ids.add(int(item))
        else:
            uname = normalize_username(item)
            if uname:
                usernames.add(uname)
    return user_ids, usernames


def load_secret_file_defaults(path: Path) -> None:
    if not path.exists():
        return

    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    token_value = ""
    user_ids: set[int] = set()
    usernames: set[str] = set()

    token_key_pattern = re.compile(
        r"^(api\s*token|bot\s*token|telegram[_\s]*bot[_\s]*token|token)\s*[:=]?\s*(.*)$",
        re.IGNORECASE,
    )
    user_key_pattern = re.compile(
        r"^(id|user\s*id|telegram[_\s]*user[_\s]*id|username|user)\s*[:=]?\s*(.*)$",
        re.IGNORECASE,
    )

    for idx, raw in enumerate(lines):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue

        token_match = token_key_pattern.match(line)
        if token_match:
            value = clean_secret_value(token_match.group(2).strip() or next_non_empty_line(lines, idx + 1))
            if value:
                token_value = value
            continue

        user_match = user_key_pattern.match(line)
        if user_match:
            value = clean_secret_value(user_match.group(2).strip() or next_non_empty_line(lines, idx + 1))
            if value:
                ids, names = parse_user_tokens(value)
                user_ids.update(ids)
                usernames.update(names)
            continue

        maybe_token = clean_secret_value(line)
        if not token_value and re.fullmatch(r"\d{5,}:[A-Za-z0-9_-]{20,}", maybe_token):
            token_value = maybe_token

    if token_value:
        set_env_if_blank("TELEGRAM_BOT_TOKEN", token_value)
    if user_ids:
        set_env_if_blank("TELEGRAM_ALLOWED_USER_IDS", ",".join(str(x) for x in sorted(user_ids)))
    if usernames:
        set_env_if_blank("TELEGRAM_ALLOWED_USERNAMES", ",".join(sorted(usernames)))


def get_secret_file_candidates() -> list[Path]:
    override = os.getenv("TELEGRAM_SECRET_FILE", "").strip()
    if override:
        return [Path(override).expanduser()]
    return [DEFAULT_SECRET_PATH]


def load_secret_defaults() -> None:
    for path in get_secret_file_candidates():
        if not path.exists():
            continue
        load_secret_file_defaults(path)
        return


def parse_int_set(raw: str, var_name: str) -> set[int]:
    values: set[int] = set()
    cleaned = raw.strip()
    if not cleaned:
        return values

    for token in cleaned.split(","):
        item = token.strip()
        if not item:
            continue
        if not re.fullmatch(r"-?\d+", item):
            raise ValueError(f"{var_name} has invalid integer value: {item}")
        values.add(int(item))
    return values


def parse_bool(value: str | None, default: bool) -> bool:
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "y", "on"}


def parse_positive_int(raw: str, label: str) -> tuple[int | None, str | None]:
    if not re.fullmatch(r"\d+", raw.strip()):
        return None, f"{label} must be a positive integer."
    value = int(raw)
    if value <= 0:
        return None, f"{label} must be greater than zero."
    return value, None


def release_instance_lock() -> None:
    global LOCK_HANDLE
    if LOCK_HANDLE is None:
        return
    if os.name == "nt":
        try:
            import msvcrt

            LOCK_HANDLE.seek(0)
            msvcrt.locking(LOCK_HANDLE.fileno(), msvcrt.LK_UNLCK, 1)
        except Exception:
            pass
    try:
        LOCK_HANDLE.close()
    except Exception:
        pass
    LOCK_HANDLE = None


def acquire_instance_lock() -> None:
    global LOCK_HANDLE
    if LOCK_HANDLE is not None:
        return

    LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
    fh = LOCK_PATH.open("a+", encoding="utf-8")
    if os.name == "nt":
        import msvcrt

        try:
            fh.seek(0)
            msvcrt.locking(fh.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError:
            fh.close()
            raise RuntimeError("Another telegram_fpga_bot.py instance is already running.")

    fh.seek(0)
    fh.truncate()
    fh.write(str(os.getpid()))
    fh.flush()

    LOCK_HANDLE = fh
    atexit.register(release_instance_lock)


def parse_main_menu_registry(main_bat_path: Path, templates_root: Path) -> dict[int, MenuEntry]:
    if not main_bat_path.exists():
        raise RuntimeError(f"MAIN.bat not found: {main_bat_path}")

    pattern = re.compile(r'^\s*set\s+"CMD_(\d+)=(.+)"\s*$', re.IGNORECASE)
    registry: dict[int, MenuEntry] = {}

    for raw in main_bat_path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = pattern.match(raw)
        if not m:
            continue

        menu_no = int(m.group(1))
        script_rel = m.group(2).strip()
        script_path = (templates_root / script_rel.replace("\\", "/")).resolve()
        registry[menu_no] = MenuEntry(menu_no=menu_no, script_rel=script_rel, script_path=script_path)

    missing = sorted(set(range(1, 20)) - set(registry.keys()))
    if missing:
        raise RuntimeError(f"MAIN.bat menu map is incomplete. Missing CMD entries: {missing}")

    return registry


def load_config() -> Config:
    env_path = Path(os.getenv("TELEGRAM_ENV_FILE", str(DEFAULT_ENV_PATH))).expanduser()
    load_env_file(env_path)

    load_secret_defaults()

    bot_token = os.getenv("TELEGRAM_BOT_TOKEN", "").strip()
    if not bot_token:
        raise RuntimeError("Missing TELEGRAM_BOT_TOKEN. Set env/.env or TELEGRAMTOKEN_ID.txt")

    allowed_user_ids = parse_int_set(os.getenv("TELEGRAM_ALLOWED_USER_IDS", "").strip(), "TELEGRAM_ALLOWED_USER_IDS")
    allowed_usernames = parse_username_set(
        os.getenv("TELEGRAM_ALLOWED_USERNAMES", "").strip(), "TELEGRAM_ALLOWED_USERNAMES"
    )
    if not allowed_user_ids and not allowed_usernames:
        raise RuntimeError(
            "Missing allow-list. Set TELEGRAM_ALLOWED_USER_IDS or TELEGRAM_ALLOWED_USERNAMES, or provide ID in TELEGRAMTOKEN_ID.txt"
        )

    allowed_chat_ids = parse_int_set(os.getenv("TELEGRAM_ALLOWED_CHAT_IDS", "").strip(), "TELEGRAM_ALLOWED_CHAT_IDS")

    automation_repo_root = Path(
        os.getenv("FPGA_AUTOMATION_REPO_ROOT", str(DEFAULT_AUTOMATION_REPO_ROOT))
    ).expanduser()
    automation_templates_root = Path(
        os.getenv("FPGA_AUTOMATION_TEMPLATES_ROOT", str(automation_repo_root / "templates"))
    ).expanduser()
    main_bat_path = Path(os.getenv("FPGA_MAIN_BAT_PATH", str(automation_repo_root / "MAIN.bat"))).expanduser()
    menu_registry = parse_main_menu_registry(main_bat_path, automation_templates_root)

    project_root = Path(os.getenv("FPGA_PROJECT_ROOT", str(automation_repo_root / "Project"))).expanduser()
    poll_timeout_sec = int(os.getenv("TELEGRAM_POLL_TIMEOUT_SEC", "25"))
    command_timeout_sec = int(os.getenv("TELEGRAM_CMD_TIMEOUT_SEC", "7200"))
    skip_pending_updates = parse_bool(os.getenv("TELEGRAM_SKIP_PENDING_UPDATES"), True)
    auto_delete_webhook_on_start = parse_bool(os.getenv("TELEGRAM_AUTO_DELETE_WEBHOOK_ON_START"), True)
    progress_interval_sec = int(os.getenv("TELEGRAM_PROGRESS_INTERVAL_SEC", "10"))
    if progress_interval_sec < 5:
        progress_interval_sec = 5
    send_diagrams = parse_bool(os.getenv("TELEGRAM_SEND_DIAGRAMS"), True)
    max_diagram_files = int(os.getenv("TELEGRAM_MAX_DIAGRAM_FILES", "3"))
    if max_diagram_files < 0:
        max_diagram_files = 0
    if max_diagram_files > 10:
        max_diagram_files = 10
    sim_vivado_log_lines = int(os.getenv("TELEGRAM_SIM_VIVADO_LOG_LINES", "120"))
    if sim_vivado_log_lines < 0:
        sim_vivado_log_lines = 0
    if sim_vivado_log_lines > 500:
        sim_vivado_log_lines = 500
    sim_vivado_send_log_file = parse_bool(os.getenv("TELEGRAM_SIM_VIVADO_SEND_LOG_FILE"), True)
    sim_vivado_auto_complete_on_replay = parse_bool(
        os.getenv("TELEGRAM_SIM_VIVADO_AUTO_COMPLETE_ON_REPLAY"),
        True,
    )
    sim_vivado_replay_check_sec = int(os.getenv("TELEGRAM_SIM_VIVADO_REPLAY_CHECK_SEC", "5"))
    if sim_vivado_replay_check_sec < 2:
        sim_vivado_replay_check_sec = 2
    if sim_vivado_replay_check_sec > 30:
        sim_vivado_replay_check_sec = 30

    return Config(
        bot_token=bot_token,
        allowed_user_ids=allowed_user_ids,
        allowed_usernames=allowed_usernames,
        allowed_chat_ids=allowed_chat_ids,
        automation_repo_root=automation_repo_root,
        automation_templates_root=automation_templates_root,
        main_bat_path=main_bat_path,
        menu_registry=menu_registry,
        project_root=project_root,
        poll_timeout_sec=poll_timeout_sec,
        command_timeout_sec=command_timeout_sec,
        skip_pending_updates=skip_pending_updates,
        auto_delete_webhook_on_start=auto_delete_webhook_on_start,
        progress_interval_sec=progress_interval_sec,
        send_diagrams=send_diagrams,
        max_diagram_files=max_diagram_files,
        sim_vivado_log_lines=sim_vivado_log_lines,
        sim_vivado_send_log_file=sim_vivado_send_log_file,
        sim_vivado_auto_complete_on_replay=sim_vivado_auto_complete_on_replay,
        sim_vivado_replay_check_sec=sim_vivado_replay_check_sec,
    )

def telegram_api(config: Config, method: str, payload: dict) -> object:
    url = f"https://api.telegram.org/bot{config.bot_token}/{method}"
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url=url, data=data, headers={"Content-Type": "application/json"})

    try:
        with urllib.request.urlopen(req, timeout=70) as resp:
            body = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        detail = ""
        try:
            err_body = exc.read().decode("utf-8", errors="replace")
            parsed_err = json.loads(err_body)
            detail = str(parsed_err.get("description", "")).strip()
        except Exception:
            detail = ""
        if detail:
            raise RuntimeError(f"Telegram API {method} failed: HTTP {exc.code} ({detail})") from exc
        raise RuntimeError(f"Telegram API {method} failed: HTTP {exc.code}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Telegram API network error: {exc}") from exc

    parsed = json.loads(body)
    if not parsed.get("ok"):
        desc = parsed.get("description", "unknown error")
        raise RuntimeError(f"Telegram API {method} failed: {desc}")
    return parsed.get("result")


def telegram_api_multipart(
    config: Config,
    method: str,
    fields: dict[str, str | int],
    file_field: str,
    file_path: Path,
) -> object:
    url = f"https://api.telegram.org/bot{config.bot_token}/{method}"
    boundary = f"----telegram-bot-{uuid.uuid4().hex}"
    body = bytearray()

    for key, value in fields.items():
        body.extend(f"--{boundary}\r\n".encode("utf-8"))
        body.extend(f'Content-Disposition: form-data; name="{key}"\r\n\r\n'.encode("utf-8"))
        body.extend(str(value).encode("utf-8"))
        body.extend(b"\r\n")

    mime_type = mimetypes.guess_type(file_path.name)[0] or "application/octet-stream"
    body.extend(f"--{boundary}\r\n".encode("utf-8"))
    body.extend(
        f'Content-Disposition: form-data; name="{file_field}"; filename="{file_path.name}"\r\n'.encode("utf-8")
    )
    body.extend(f"Content-Type: {mime_type}\r\n\r\n".encode("utf-8"))
    body.extend(file_path.read_bytes())
    body.extend(b"\r\n")
    body.extend(f"--{boundary}--\r\n".encode("utf-8"))

    headers = {"Content-Type": f"multipart/form-data; boundary={boundary}"}
    req = urllib.request.Request(url=url, data=bytes(body), headers=headers, method="POST")

    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            resp_body = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        detail = ""
        try:
            err_body = exc.read().decode("utf-8", errors="replace")
            parsed_err = json.loads(err_body)
            detail = str(parsed_err.get("description", "")).strip()
        except Exception:
            detail = ""
        if detail:
            raise RuntimeError(f"Telegram API {method} failed: HTTP {exc.code} ({detail})") from exc
        raise RuntimeError(f"Telegram API {method} failed: HTTP {exc.code}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Telegram API network error: {exc}") from exc

    parsed = json.loads(resp_body)
    if not parsed.get("ok"):
        desc = parsed.get("description", "unknown error")
        raise RuntimeError(f"Telegram API {method} failed: {desc}")
    return parsed.get("result")


def html_escape(text: object) -> str:
    return str(text).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def send_text(config: Config, chat_id: int, text: str, parse_mode: str | None = "HTML", reply_markup: dict | None = None) -> None:
    safe = text.rstrip() or "(empty)"
    chunks = split_text(safe, 3500)
    for i, chunk in enumerate(chunks):
        payload: dict[str, object] = {"chat_id": chat_id, "text": chunk}
        if parse_mode:
            payload["parse_mode"] = parse_mode
        if reply_markup is not None and i == len(chunks) - 1:
            payload["reply_markup"] = reply_markup
        telegram_api(config, "sendMessage", payload)

def edit_message_text(config: Config, chat_id: int, message_id: int, text: str, parse_mode: str | None = "HTML", reply_markup: dict | None = None) -> None:
    payload: dict[str, object] = {"chat_id": chat_id, "message_id": message_id, "text": text}
    if parse_mode:
        payload["parse_mode"] = parse_mode
    if reply_markup is not None:
        payload["reply_markup"] = reply_markup
    try:
        telegram_api(config, "editMessageText", payload)
    except Exception as exc:
        print(f"[WARN] editMessageText failed: {exc}")

def answer_callback_query(
    config: Config,
    callback_query_id: str,
    text: str | None = None,
    show_alert: bool = False,
) -> None:
    payload: dict[str, object] = {"callback_query_id": callback_query_id}
    if text:
        payload["text"] = text
    if show_alert:
        payload["show_alert"] = True
    try:
        telegram_api(config, "answerCallbackQuery", payload)
    except Exception as exc:
        pass


def safe_send_text(config: Config, chat_id: int, text: str, parse_mode: str | None = "HTML", reply_markup: dict | None = None) -> None:
    try:
        send_text(config, chat_id, text, parse_mode=parse_mode, reply_markup=reply_markup)
    except Exception as exc:
        print(f"[WARN] sendMessage failed: {exc}")


def send_photo(config: Config, chat_id: int, file_path: Path, caption: str | None = None) -> None:
    payload: dict[str, str | int] = {"chat_id": chat_id}
    if caption:
        payload["caption"] = caption
        payload["parse_mode"] = "HTML"
    telegram_api_multipart(config, "sendPhoto", payload, "photo", file_path)


def send_document(config: Config, chat_id: int, file_path: Path, caption: str | None = None) -> None:
    payload: dict[str, str | int] = {"chat_id": chat_id}
    if caption:
        payload["caption"] = caption
        payload["parse_mode"] = "HTML"
    telegram_api_multipart(config, "sendDocument", payload, "document", file_path)


def safe_send_photo(config: Config, chat_id: int, file_path: Path, caption: str | None = None) -> None:
    try:
        send_photo(config, chat_id, file_path, caption)
    except Exception as exc:
        print(f"[WARN] sendPhoto failed ({file_path}): {exc}")


def safe_send_document(config: Config, chat_id: int, file_path: Path, caption: str | None = None) -> None:
    try:
        send_document(config, chat_id, file_path, caption)
    except Exception as exc:
        print(f"[WARN] sendDocument failed ({file_path}): {exc}")


def split_text(text: str, chunk_size: int) -> list[str]:
    if len(text) <= chunk_size:
        return [text]

    out: list[str] = []
    cursor = 0
    while cursor < len(text):
        out.append(text[cursor : cursor + chunk_size])
        cursor += chunk_size
    return out


def terminate_process_tree(pid: int) -> None:
    if pid <= 0:
        return
    if os.name != "nt":
        return
    try:
        subprocess.run(
            ["taskkill", "/PID", str(pid), "/T", "/F"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except Exception:
        pass


def get_updates(config: Config, offset: int | None, timeout_sec: int) -> list[dict]:
    payload: dict[str, object] = {
        "timeout": timeout_sec,
        "allowed_updates": ["message", "callback_query"],
        "limit": 50,
    }
    if offset is not None:
        payload["offset"] = offset

    result = telegram_api(config, "getUpdates", payload)
    if not isinstance(result, list):
        return []
    return [item for item in result if isinstance(item, dict)]


def skip_backlog_if_needed(config: Config) -> int | None:
    if not config.skip_pending_updates:
        return None

    updates = get_updates(config, offset=None, timeout_sec=0)
    if not updates:
        return None
    latest = max(int(u.get("update_id", 0)) for u in updates)
    return latest + 1


def ensure_polling_ready(config: Config) -> None:
    if not config.auto_delete_webhook_on_start:
        return
    telegram_api(
        config,
        "deleteWebhook",
        {"drop_pending_updates": bool(config.skip_pending_updates)},
    )


def is_conflict_error(exc: Exception) -> bool:
    msg = str(exc).lower()
    return "http 409" in msg or "conflict" in msg


def discover_projects(project_root: Path) -> list[Path]:
    if not project_root.exists() or not project_root.is_dir():
        return []

    projects: list[Path] = []
    for child in sorted(project_root.iterdir(), key=lambda p: p.name.lower()):
        if not child.is_dir():
            continue
        if (child / "src").is_dir() and (child / "fpga_auto.yml").is_file():
            projects.append(child)
    return projects


def build_projects_index_lines(projects: list[Path]) -> list[str]:
    return [f"[{idx}] {proj.name}" for idx, proj in enumerate(projects, start=1)]


def resolve_project(project_root: Path, raw_name: str) -> tuple[Path | None, str | None]:
    target = raw_name.strip().strip('"').strip("'")
    if not target:
        return None, "Project name is required."

    projects = discover_projects(project_root)
    if not projects:
        return None, f"No valid projects found under: {project_root}"

    exact = [p for p in projects if p.name.lower() == target.lower()]
    if len(exact) == 1:
        return exact[0], None

    # Numeric shortcut: allow project index shown by /projects.
    if re.fullmatch(r"\d+", target):
        idx = int(target)
        if 1 <= idx <= len(projects):
            return projects[idx - 1], None
        lines = build_projects_index_lines(projects)
        return (
            None,
            "Project index out of range.\n"
            f"Valid range: 1~{len(projects)}\n"
            "Available:\n"
            + "\n".join(lines),
        )

    prefix = [p for p in projects if p.name.lower().startswith(target.lower())]
    if len(prefix) == 1:
        return prefix[0], None

    if len(prefix) > 1:
        names = ", ".join(p.name for p in prefix)
        return None, f"Ambiguous project name '{raw_name}'. Matches: {names}"

    lines = build_projects_index_lines(projects)
    return (
        None,
        f"Project '{raw_name}' not found.\n"
        "Use exact/prefix name or project index from /projects.\n"
        "Available:\n"
        + "\n".join(lines),
    )


def format_status(current: dict[str, object] | None, last: dict[str, object] | None) -> str:
    lines = ["🤖 <b>[Bot Status]</b>"]
    if current is None:
        lines.append("💤 <i>State:</i> <code>Idle</code>")
    else:
        started = float(current.get("started_at", time.time()))
        elapsed = int(time.time() - started)
        lines.append("⚙️ <i>State:</i> <code>Busy</code>")
        lines.append(f"🔹 <i>Command:</i> <code>{html_escape(current.get('command'))}</code>")
        if current.get("menu_no") is not None:
            lines.append(f"🔹 <i>Menu:</i> <code>{current.get('menu_no')}</code>")
        if current.get("project"):
            lines.append(f"🔹 <i>Project:</i> <code>{html_escape(current.get('project'))}</code>")
        if current.get("menu_no") == 5 and current.get("sim_vivado_close_gui") is not None:
            lines.append(f"🔹 <i>close_gui:</i> <code>{current.get('sim_vivado_close_gui')}</code>")
        lines.append(f"⏱ <i>Elapsed:</i> <code>{elapsed}s</code>")

    if last is None:
        lines.append("🕒 <b>Last Job:</b> <code>None</code>")
    else:
        lines.append(
            f"🕒 <b>Last Job:</b> <code>{html_escape(last.get('command'))}</code> | rc=<code>{last.get('return_code')}</code> | <code>{last.get('duration_sec')}s</code>"
        )
        if last.get("menu_no") is not None:
            lines.append(f"  └ <i>Menu:</i> <code>{last.get('menu_no')}</code>")
        if last.get("project"):
            lines.append(f"  └ <i>Project:</i> <code>{html_escape(last.get('project'))}</code>")
        lines.append(f"  └ <i>At:</i> <code>{last.get('finished_at_utc')}</code>")

    return "\n".join(lines)


def get_main_menu_keyboard() -> dict[str, object]:
    return {
        "keyboard": [
            [{"text": "🚀 Select Project"}],
            [{"text": "📊 Status"}, {"text": "🕒 Last"}, {"text": "❓ Help"}],
        ],
        "resize_keyboard": True,
        "is_persistent": True,
    }

def build_help(category: str = "core") -> tuple[str, dict[str, object]]:
    keyboard = {
        "inline_keyboard": [
            [
                {"text": "📌 Core" if category == "core" else "Core", "callback_data": "help_core"},
                {"text": "🛠 Build" if category == "build" else "Build", "callback_data": "help_build"},
            ],
            [
                {"text": "🏃 Sim" if category == "sim" else "Sim", "callback_data": "help_sim"},
                {"text": "📊 Docs/Vis" if category == "docs" else "Docs/Vis", "callback_data": "help_docs"},
            ]
        ]
    }

    if category == "core":
        text = "\n".join([
            "🤖 <b>[FPGA Telegram Bot]</b>",
            "",
            "📌 <b>Core commands:</b>",
            "🔸 /run - <i>Interactive Project Wizard 🪄</i>",
            "🔸 /projects - <i>list valid projects</i>",
            "🔸 /status - <i>show running status</i>",
            "🔸 /last - <i>show last job result</i>",
            "🔸 /task &lt;menu_no&gt; &lt;proj&gt; [args] - <i>run MAIN menu (1~19)</i>",
            "🔸 /setup_project &lt;name&gt; [v|sv] - <i>run setup</i>",
            "🔸 /help - <i>show this help</i>",
        ])
    elif category == "build":
        text = "\n".join([
            "🛠 <b>Build & Generation:</b>",
            "🔹 /build | /build_program | /program",
            "🔹 /vivado_gui &lt;proj&gt; | /finalize_bd | /retarget_ip",
            "🔹 /tb_scaffold &lt;proj&gt; (--all | --dut &lt;name&gt;) [--force]",
        ])
    elif category == "sim":
        text = "\n".join([
            "🏃 <b>Simulation & Test:</b>",
            "🔹 /run - <i>Interactive Wizard 🪄</i>",
            "🔹 /sim_vivado &lt;proj&gt; &lt;f_idx&gt; &lt;tb_idx&gt; [--close-gui|--keep-gui]",
            "🔹 /sim_auto_report &lt;proj&gt; &lt;tb_idx&gt;",
            "🔹 /sim_iverilog &lt;proj&gt; (--all | --tb &lt;name&gt;)",
            "",
            "💡 <i>Tip: sim_vivado default is <code>--close-gui</code></i>"
        ])
    else: # docs
        text = "\n".join([
            "📊 <b>Documentation & Visuals:</b>",
            "🔹 /schematic &lt;proj&gt; &lt;modules&gt;",
            "🔹 /hierarchy &lt;proj&gt; [src|tb]",
            "🔹 /fsm &lt;proj&gt; &lt;modules&gt;",
            "🔹 /presentation &lt;proj&gt; [clean_assets]",
            "🔹 /vcd_svg &lt;proj&gt;",
            "🔹 /vcd_wavedrom &lt;proj&gt; [--step N] [--max-signals N] [--html|--no-html]",
            "🔹 /report_html &lt;proj&gt; | /report_docs &lt;proj&gt;",
            "🔹 /open_presentation &lt;proj&gt;",
            "",
            "💡 <i>Tip: Diagram commands return images automatically.</i>"
        ])

    return text, keyboard


def normalize_command(raw_cmd: str) -> str:
    cmd = raw_cmd.strip().lower()
    if "@" in cmd:
        cmd = cmd.split("@", 1)[0]
    return cmd


def parse_cli_tokens(raw_args: str) -> list[str]:
    stripped = raw_args.strip()
    if not stripped:
        return []
    try:
        return shlex.split(stripped)
    except ValueError:
        return stripped.split()


def parse_module_selection(raw: str) -> tuple[str | None, str | None]:
    candidate = raw.strip()
    if not candidate:
        return None, "modules is required. Use ALL, numbers like 1,3,5, or module names like foo,bar"
    if candidate.upper() == "ALL":
        return "ALL", None

    normalized = re.sub(r"[,\s]+", " ", candidate).strip()
    if not normalized:
        return None, "modules is required. Use ALL, numbers like 1,3,5, or module names like foo,bar"

    tokens = [t for t in normalized.split(" ") if t]
    if not tokens:
        return None, "modules is required. Use ALL, numbers like 1,3,5, or module names like foo,bar"

    if all(re.fullmatch(r"\d+", token) for token in tokens):
        return normalized, None

    if all(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_$]*", token) for token in tokens):
        return normalized, None

    return None, "Invalid modules. Use ALL, numbers like 1,3,5, or module names like foo,bar"


def parse_yes_no_token(raw: str) -> bool | None:
    token = raw.strip().lower()
    if token in {"y", "yes", "1", "true", "clean_assets", "clean-assets"}:
        return True
    if token in {"n", "no", "0", "false"}:
        return False
    return None


def parse_sim_vivado_close_choice(raw: str) -> bool | None:
    token = raw.strip().lower()
    if token in {"--close-gui", "--close", "--gui-off", "close", "y", "yes", "1"}:
        return True
    if token in {"--keep-gui", "--keep", "--gui-on", "keep", "n", "no", "0"}:
        return False
    return None


def format_stdin(lines: list[str]) -> str | None:
    if not lines:
        return None
    return "\r\n".join(lines) + "\r\n"


def is_diagram_menu(menu_no: int | None) -> bool:
    return menu_no in {1, 3, 8, 9}


def is_report_menu(menu_no: int | None) -> bool:
    return menu_no in {10, 11}


def is_system_skin_svg(path: Path) -> bool:
    return path.suffix.lower() == ".svg" and path.stem.lower().startswith("skin_")


def collect_recent_diagram_files(roots: tuple[Path, ...], started_ts: float, limit: int) -> list[Path]:
    if limit <= 0:
        return []

    cutoff_ts = started_ts - 2.0
    by_path: dict[Path, float] = {}
    supported = {".svg", ".png", ".jpg", ".jpeg", ".webp"}

    for root in roots:
        if not root.exists():
            continue

        if root.is_file():
            if root.suffix.lower() not in supported:
                continue
            try:
                mtime = root.stat().st_mtime
            except OSError:
                continue
            if mtime >= cutoff_ts:
                by_path[root] = mtime
            continue

        try:
            iterator = root.rglob("*")
        except Exception:
            continue

        for path in iterator:
            if not path.is_file():
                continue
            if path.suffix.lower() not in supported:
                continue
            if is_system_skin_svg(path):
                continue
            try:
                mtime = path.stat().st_mtime
            except OSError:
                continue
            if mtime >= cutoff_ts:
                prev = by_path.get(path)
                if prev is None or mtime > prev:
                    by_path[path] = mtime

    ranked = sorted(by_path.items(), key=lambda item: item[1], reverse=True)
    return [item[0] for item in ranked[:limit]]


def collect_schematic_diagram_files(roots: tuple[Path, ...], started_ts: float) -> list[Path]:
    cutoff_ts = started_ts - 2.0
    output_root: Path | None = None

    for root in roots:
        if root.name.lower() == "output":
            output_root = root
            break
    if output_root is None:
        for root in roots:
            if (root / "Diagram").exists():
                output_root = root
                break
    if output_root is None:
        return []

    simple_dir = output_root / "Diagram" / "Simple"
    detailed_dir = output_root / "Diagram" / "Detailed"
    module_paths: dict[str, dict[str, Path]] = {}

    if simple_dir.exists():
        for path in simple_dir.glob("*.svg"):
            if not path.is_file():
                continue
            if is_system_skin_svg(path):
                continue
            key = path.stem.lower()
            bucket = module_paths.setdefault(key, {})
            bucket["simple"] = path

    if detailed_dir.exists():
        for path in detailed_dir.glob("*.svg"):
            if not path.is_file():
                continue
            if is_system_skin_svg(path):
                continue
            stem = path.stem
            key = stem[:-9].lower() if stem.lower().endswith("_detailed") else stem.lower()
            bucket = module_paths.setdefault(key, {})
            bucket["detailed"] = path

    if not module_paths:
        return []

    fresh: list[Path] = []
    fallback: list[Path] = []
    for module_key in sorted(module_paths.keys()):
        bucket = module_paths[module_key]
        ordered = [bucket[kind] for kind in ("simple", "detailed") if kind in bucket]
        for path in ordered:
            try:
                mtime = path.stat().st_mtime
            except OSError:
                mtime = 0.0
            if mtime >= cutoff_ts:
                fresh.append(path)
            else:
                fallback.append(path)

    return fresh if fresh else fallback


def render_svg_preview(svg_path: Path) -> Path | None:
    png_sidecar = svg_path.with_suffix(".png")
    if png_sidecar.exists() and png_sidecar.is_file():
        try:
            if png_sidecar.stat().st_mtime >= (svg_path.stat().st_mtime - 2.0):
                return png_sidecar
        except OSError:
            pass

    try:
        import cairosvg  # type: ignore
    except Exception:
        return None

    temp_preview = Path(tempfile.gettempdir()) / f"{svg_path.stem}_{uuid.uuid4().hex[:8]}.png"
    try:
        cairosvg.svg2png(url=str(svg_path), write_to=str(temp_preview))
    except Exception:
        try:
            temp_preview.unlink(missing_ok=True)
        except Exception:
            pass
        return None
    return temp_preview


def send_diagram_artifacts(config: Config, chat_id: int, job: JobRequest, started_ts: float) -> None:
    if not config.send_diagrams:
        return
    if not is_diagram_menu(job.menu_no):
        return

    if job.menu_no == 1:
        targets = collect_schematic_diagram_files(job.artifact_paths, started_ts)
        if not targets:
            targets = collect_recent_diagram_files(job.artifact_paths, started_ts, config.max_diagram_files)
    else:
        targets = collect_recent_diagram_files(job.artifact_paths, started_ts, config.max_diagram_files)
    if not targets:
        return

    safe_send_text(config, chat_id, f"📎 [ARTIFACTS] diagrams={len(targets)}")
    for path in targets:
        suffix = path.suffix.lower()
        caption = f"{job.command_name} | {path.name}"

        if suffix in {".png", ".jpg", ".jpeg", ".webp"}:
            safe_send_photo(config, chat_id, path, caption)
            continue

        if suffix == ".svg":
            temp_preview: Path | None = None
            preview = render_svg_preview(path)
            if preview is not None:
                temp_preview = preview if preview != path.with_suffix(".png") else None
                safe_send_photo(config, chat_id, preview, f"{job.command_name} | {path.stem}.png")
            safe_send_document(config, chat_id, path, caption)
            if temp_preview is not None:
                try:
                    temp_preview.unlink(missing_ok=True)
                except Exception:
                    pass


def collect_recent_report_files(job: JobRequest, started_ts: float) -> list[Path]:
    if not is_report_menu(job.menu_no):
        return []

    output_root: Path | None = None
    for root in job.artifact_paths:
        if root.name.lower() == "output":
            output_root = root
            break
    if output_root is None:
        return []

    cutoff_ts = started_ts - REPORT_ARTIFACT_RECENT_SLACK_SEC
    entries: list[tuple[float, Path]] = []

    if job.menu_no == 10:
        report_dir = output_root / "FINALReport"
        if report_dir.exists():
            for path in report_dir.rglob("*"):
                if not path.is_file():
                    continue
                if path.suffix.lower() not in {".html", ".htm", ".pdf", ".md"}:
                    continue
                try:
                    mtime = path.stat().st_mtime
                except OSError:
                    continue
                if mtime >= cutoff_ts:
                    entries.append((mtime, path))
        entries.sort(key=lambda x: x[0], reverse=True)
        return [p for _, p in entries[:5]]

    if job.menu_no == 11:
        docs_dir = output_root / "docs"
        if docs_dir.exists():
            for path in docs_dir.glob("*.md"):
                if not path.is_file():
                    continue
                try:
                    mtime = path.stat().st_mtime
                except OSError:
                    continue
                if mtime >= cutoff_ts:
                    entries.append((mtime, path))
        entries.sort(key=lambda x: x[0], reverse=True)
        return [p for _, p in entries]

    return []


def send_report_artifacts(config: Config, chat_id: int, job: JobRequest, started_ts: float) -> None:
    if not is_report_menu(job.menu_no):
        return

    files = collect_recent_report_files(job, started_ts)
    if not files:
        return

    safe_send_text(config, chat_id, f"📎 [ARTIFACTS] reports={len(files)}")
    for file_path in files:
        safe_send_document(config, chat_id, file_path, f"{job.command_name} | {file_path.name}")


def extract_hierarchy_log_candidates_from_run_log(run_log: Path) -> list[Path]:
    if not run_log.exists():
        return []

    lines = read_log_tail_lines(run_log, max_bytes=400_000)
    if not lines:
        return []

    out: list[Path] = []
    seen: set[Path] = set()
    file_re = re.compile(r"^\[INFO\]\s+Hierarchy log file\s*:\s*(.+?)\s*$", re.IGNORECASE)
    dir_re = re.compile(r"^\[INFO\]\s+Hierarchy logs?\s*:\s*(.+?)\s*$", re.IGNORECASE)

    for raw in lines:
        line = raw.strip()
        m_file = file_re.match(line)
        if m_file:
            path = Path(m_file.group(1).strip().strip('"'))
            if path not in seen:
                seen.add(path)
                out.append(path)
            continue

        m_dir = dir_re.match(line)
        if m_dir:
            directory = Path(m_dir.group(1).strip().strip('"'))
            for path in sorted(directory.glob("hierarchy*.log")):
                if path in seen:
                    continue
                seen.add(path)
                out.append(path)

    return out


def list_recent_hierarchy_logs(
    job: JobRequest,
    started_ts: float,
    run_log: Path | None = None,
    require_fresh: bool = False,
) -> list[Path]:
    candidates: list[Path] = []
    seen: set[Path] = set()
    hinted_set: set[Path] = set()

    if run_log is not None:
        for path in extract_hierarchy_log_candidates_from_run_log(run_log):
            if path in seen:
                continue
            seen.add(path)
            hinted_set.add(path)
            candidates.append(path)

    for root in job.artifact_paths:
        if root.name.lower() != "log":
            continue
        hierarchy_root = root / "hierarchy"
        if not hierarchy_root.exists():
            continue
        for path in sorted(hierarchy_root.glob("hierarchy*.log")):
            if path in seen:
                continue
            seen.add(path)
            candidates.append(path)

    if not candidates:
        return []

    scored: list[tuple[int, int, float, Path]] = []
    for path in candidates:
        try:
            mtime = path.stat().st_mtime
        except OSError:
            continue

        hinted = 1 if path in hinted_set else 0
        fresh = 1 if mtime >= (started_ts - HIERARCHY_LOG_FRESH_SLACK_SEC) else 0
        if require_fresh and fresh == 0 and hinted == 0:
            continue
        scored.append((hinted, fresh, mtime, path))

    if not scored:
        return []

    scored.sort(key=lambda item: (item[0], item[1], item[2]), reverse=True)
    return [item[3] for item in scored]


def find_recent_hierarchy_log(
    job: JobRequest,
    started_ts: float,
    run_log: Path | None = None,
    require_fresh: bool = False,
) -> Path | None:
    logs = list_recent_hierarchy_logs(job, started_ts, run_log=run_log, require_fresh=require_fresh)
    return logs[0] if logs else None


def extract_vivado_log_candidates_from_run_log(run_log: Path) -> list[Path]:
    if not run_log.exists():
        return []
    lines = read_log_tail_lines(run_log, max_bytes=400_000)
    if not lines:
        return []

    out: list[Path] = []
    seen: set[Path] = set()
    file_re = re.compile(r"^\[INFO\]\s+Vivado log file\s*:\s*(.+?)\s*$", re.IGNORECASE)
    dir_re = re.compile(r"^\[INFO\]\s+Vivado logs?\s*:\s*(.+?)\s*$", re.IGNORECASE)

    for raw in lines:
        line = raw.strip()
        m_file = file_re.match(line)
        if m_file:
            p = Path(m_file.group(1).strip().strip('"'))
            if p not in seen:
                seen.add(p)
                out.append(p)
            continue

        m_dir = dir_re.match(line)
        if m_dir:
            d = Path(m_dir.group(1).strip().strip('"'))
            for name in ("vivado_sim.log", "vivado.log"):
                p = d / name
                if p not in seen:
                    seen.add(p)
                    out.append(p)
    return out


def is_log_fresh_for_run(log_path: Path, started_ts: float, slack_sec: float = VIVADO_LOG_FRESH_SLACK_SEC) -> bool:
    try:
        mtime = log_path.stat().st_mtime
    except OSError:
        return False
    return mtime >= (started_ts - slack_sec)


def list_recent_vivado_sim_logs(
    job: JobRequest,
    started_ts: float,
    run_log: Path | None = None,
    require_fresh: bool = False,
) -> list[Path]:
    candidates: list[Path] = []
    seen: set[Path] = set()
    hinted_set: set[Path] = set()

    if run_log is not None:
        hinted = extract_vivado_log_candidates_from_run_log(run_log)
        for path in hinted:
            if path in seen:
                continue
            seen.add(path)
            hinted_set.add(path)
            candidates.append(path)

    for root in job.artifact_paths:
        root_name = root.name.lower()
        if root_name not in {"log", "vivado_sim", "tb"}:
            continue
        if not root.exists():
            continue

        search_root = root / "vivado_sim" if root_name == "log" else root
        if not search_root.exists():
            continue

        preferred = search_root / "vivado_sim.log"
        if preferred.is_file() and preferred not in seen:
            seen.add(preferred)
            candidates.append(preferred)

        if root_name == "tb":
            for path in sorted(search_root.rglob("vivado_sim*.log")):
                if not path.is_file() or path in seen:
                    continue
                seen.add(path)
                candidates.append(path)
            continue

        for path in sorted(search_root.glob("*.log")):
            if not path.is_file() or path in seen:
                continue
            seen.add(path)
            candidates.append(path)

    if not candidates:
        return []

    scored: list[tuple[int, int, int, float, Path]] = []
    for path in candidates:
        try:
            mtime = path.stat().st_mtime
        except OSError:
            continue
        fresh = 1 if mtime >= (started_ts - VIVADO_LOG_FRESH_SLACK_SEC) else 0
        if require_fresh and fresh == 0 and path not in hinted_set:
            continue
        hinted = 1 if path in hinted_set else 0
        name = path.name.lower()
        priority = 2 if name == "vivado_sim.log" else 1 if name.startswith("vivado_sim") else 0
        scored.append((fresh, hinted, priority, mtime, path))

    if not scored:
        return []
    scored.sort(key=lambda item: (item[0], item[1], item[2], item[3]), reverse=True)
    return [item[4] for item in scored]


def find_recent_vivado_sim_log(
    job: JobRequest,
    started_ts: float,
    run_log: Path | None = None,
    require_fresh: bool = False,
) -> Path | None:
    logs = list_recent_vivado_sim_logs(
        job,
        started_ts,
        run_log=run_log,
        require_fresh=require_fresh,
    )
    return logs[0] if logs else None


def read_log_tail_lines(log_path: Path, max_bytes: int = 1_000_000) -> list[str]:
    try:
        with log_path.open("rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            start = max(0, size - max_bytes)
            fh.seek(start, os.SEEK_SET)
            blob = fh.read()
    except OSError:
        return []

    text = blob.decode("utf-8", errors="replace")
    lines = text.splitlines()
    if start > 0 and lines:
        lines = lines[1:]
    return lines


def extract_hierarchy_lines(log_path: Path) -> list[str]:
    lines = read_log_tail_lines(log_path)
    if not lines:
        return []

    hier_lines: list[str] = []
    capture = False
    start_markers = (
        "+--",
        "\\--",
        "[SV Declarations]",
        "[TB Folders]",
        "[TB Folder]",
        "No modules found.",
        "No TB folders found.",
        "No TB top modules/programs found.",
    )

    for raw in lines:
        clean_line = raw.rstrip("\r\n")
        stripped = clean_line.strip()

        if not capture and any(marker in clean_line for marker in start_markers):
            capture = True

        if not capture:
            continue

        if (
            "------------------------------------------------------------" in clean_line
            or stripped.startswith("Command")
            or stripped.startswith("**********************")
            or stripped.startswith("Transcript started")
            or stripped.startswith("Transcript stopped")
        ):
            break

        hier_lines.append(html_escape(clean_line))

    while hier_lines and not hier_lines[-1].strip():
        hier_lines.pop()
    return hier_lines


def extract_replay_log_excerpt(log_path: Path, max_lines: int) -> tuple[list[str], bool, bool]:
    lines = read_log_tail_lines(log_path)
    if not lines:
        return [], False, False

    marker_idx = -1
    for idx, line in enumerate(lines):
        if "Auto replay: restart + run all" in line:
            marker_idx = idx

    if marker_idx < 0:
        for idx, line in enumerate(lines):
            lower = line.lower()
            if "restart" in lower and "run all" in lower:
                marker_idx = idx

    excerpt = lines[marker_idx:] if marker_idx >= 0 else lines
    truncated = False
    if max_lines > 0 and len(excerpt) > max_lines:
        excerpt = excerpt[-max_lines:]
        truncated = True

    return excerpt, marker_idx >= 0, truncated


def parse_replay_state_from_lines(lines: list[str]) -> str | None:
    for line in reversed(lines):
        lower = line.lower()
        if "auto replay completed" in lower:
            return "success"
        if "run all completed" in lower and "auto replay" in lower:
            return "success"
        if "run all failed" in lower and "auto replay" in lower:
            return "fail"
        if "restart failed" in lower and "auto replay" in lower:
            return "fail"
        if "keeping vivado gui open by user choice" in lower:
            return "success"
        if "close request sent to vivado" in lower:
            return "success"
    return None


def filter_sim_vivado_key_lines(lines: list[str], max_lines: int = 80) -> list[str]:
    out: list[str] = []
    for raw in lines:
        line = raw.strip()
        if not line:
            continue
        if line.startswith("#"):
            continue
        if "INFO: [Wavedata" in line:
            continue

        keep = False
        if "[TB][INFO]" in line:
            keep = True
        elif line.startswith("[INFO] Auto replay"):
            keep = True
        elif line.startswith("[WARNING] Auto replay"):
            keep = True
        elif "[ERROR]" in line or "[FAILURE]" in line:
            keep = True
        elif line.startswith("$finish called"):
            keep = True
        elif line.startswith("[SUCCESS] Vivado simulation launched"):
            keep = True

        if keep:
            out.append(line)

    if len(out) > max_lines:
        out = out[-max_lines:]
    return out


def build_sim_vivado_summary_text(log_path: Path, excerpt_lines: list[str], marker_found: bool, truncated: bool) -> str:
    run_case_re = re.compile(r"\[TB\]\[INFO\]\s+RUN CASE\s+(\d+)\s*/\s*(\d+)", re.IGNORECASE)
    test_re = re.compile(r"\[TB\]\[INFO\]\s+Selected TESTNAME=([^\s]+)", re.IGNORECASE)
    env_re = re.compile(
        r"\[TB\]\[INFO\]\s+ENV report:\s+checked=(\d+)\s+errors=(\d+)\s+coverage=([0-9.]+)%",
        re.IGNORECASE,
    )

    cleaned = filter_sim_vivado_key_lines(excerpt_lines, max_lines=120)
    replay_state = "unknown"
    case_rows: list[dict[str, str]] = []
    warnings: list[str] = []
    errors: list[str] = []
    finish_line = ""

    for line in cleaned:
        lower = line.lower()
        if "auto replay run all completed" in lower:
            replay_state = "completed"
        elif "auto replay run all failed" in lower or "auto replay restart failed" in lower:
            replay_state = "failed"

        if "[WARNING]" in line:
            warnings.append(line)
        if "[ERROR]" in line or "[FAILURE]" in line:
            errors.append(line)
        if line.startswith("$finish called"):
            finish_line = line

        m_case = run_case_re.search(line)
        if m_case:
            case_rows.append(
                {
                    "idx": m_case.group(1),
                    "total": m_case.group(2),
                    "test": "?",
                    "checked": "-",
                    "errors": "-",
                    "coverage": "-",
                }
            )
            continue

        m_test = test_re.search(line)
        if m_test and case_rows:
            case_rows[-1]["test"] = m_test.group(1)
            continue

        m_env = env_re.search(line)
        if m_env and case_rows:
            case_rows[-1]["checked"] = m_env.group(1)
            case_rows[-1]["errors"] = m_env.group(2)
            case_rows[-1]["coverage"] = m_env.group(3)

    lines: list[str] = ["📊 <b>[SIM_VIVADO_SUMMARY]</b>"]
    lines.append(f"📄 <i>log_file:</i> <code>{html_escape(log_path.name)}</code>")
    lines.append(f"🔍 <i>source:</i> <code>{'after marker' if marker_found else 'tail fallback'}</code>")
    
    replay_emoji = "✅" if replay_state == "completed" else "❌" if replay_state == "failed" else "❓"
    lines.append(f"{replay_emoji} <i>replay:</i> <b>{replay_state}</b>")
    if truncated:
        lines.append("⚠️ <i>note:</i> <code>excerpt truncated</code>")

    if case_rows:
        total = case_rows[-1].get("total", str(len(case_rows)))
        lines.append(f"📋 <i>cases:</i> <code>{len(case_rows)}/{total}</code>")
    lines.append("")

    if case_rows:
        lines.append("📝 <b>Case Results:</b>")
        for row in case_rows:
            lines.append(
                f"  #<code>{html_escape(row['idx'])}</code> <b>{html_escape(row['test'])}</b> | errs=<code>{html_escape(row['errors'])}</code> | cov=<code>{html_escape(row['coverage'])}%</code> | chk=<code>{html_escape(row['checked'])}</code>"
            )
        lines.append("")

    if finish_line:
        lines.append(f"🏁 <i>finish:</i> <code>{html_escape(finish_line)}</code>")
    if warnings:
        lines.append(f"⚠️ <b>warnings:</b> {len(warnings)}")
        lines.append("<pre>")
        lines.extend([html_escape(w) for w in warnings[-3:]])
        lines.append("</pre>")
    if errors:
        lines.append(f"❌ <b>errors:</b> {len(errors)}")
        lines.append("<pre>")
        lines.extend([html_escape(e) for e in errors[-5:]])
        lines.append("</pre>")
    if not case_rows and not warnings and not errors:
        lines.append("<i>No parsed summary fields found in excerpt.</i>")

    return "\n".join(lines)


def detect_replay_completion_from_run_log(run_log: Path) -> str | None:
    if not run_log.exists():
        return None
    lines = read_log_tail_lines(run_log, max_bytes=600_000)
    if not lines:
        return None
    return parse_replay_state_from_lines(lines)


def detect_replay_completion_from_vivado_logs(
    job: JobRequest,
    started_ts: float,
    run_log: Path | None = None,
) -> tuple[str | None, Path | None]:
    candidates = list_recent_vivado_sim_logs(
        job,
        started_ts,
        run_log=run_log,
        require_fresh=True,
    )
    for log_path in candidates:
        if not log_path.exists():
            continue
        lines = read_log_tail_lines(log_path, max_bytes=900_000)
        if not lines:
            continue
        replay_state = parse_replay_state_from_lines(lines)
        if replay_state is not None:
            return replay_state, log_path
    return None, None


def find_sim_vivado_prompt_ipc_flags(
    job: JobRequest,
    started_ts: float,
    run_log: Path | None = None,
) -> tuple[Path | None, Path | None, Path | None]:
    search_roots: list[Path] = []
    seen_roots: set[Path] = set()

    hinted_logs = extract_vivado_log_candidates_from_run_log(run_log) if run_log is not None else []
    for log_path in hinted_logs:
        parent = log_path.parent
        if parent not in seen_roots:
            seen_roots.add(parent)
            search_roots.append(parent)

    recent_logs = list_recent_vivado_sim_logs(job, started_ts, run_log=run_log, require_fresh=False)
    for log_path in recent_logs[:5]:
        parent = log_path.parent
        if parent not in seen_roots:
            seen_roots.add(parent)
            search_roots.append(parent)

    for root in job.artifact_paths:
        root_name = root.name.lower()
        candidate = root / "vivado_sim" if root_name == "log" else root
        if candidate not in seen_roots:
            seen_roots.add(candidate)
            search_roots.append(candidate)

    best_req: Path | None = None
    best_close: Path | None = None
    best_keep: Path | None = None
    best_mtime = -1.0

    for base in search_roots:
        if not base.exists():
            continue
        try:
            iterator = base.rglob("close_prompt_*")
        except Exception:
            continue
        for prompt_dir in iterator:
            if not prompt_dir.is_dir():
                continue
            request_flag = prompt_dir / "request.flag"
            close_flag = prompt_dir / "close.flag"
            keep_flag = prompt_dir / "keep.flag"
            if not request_flag.exists():
                continue
            try:
                req_mtime = request_flag.stat().st_mtime
            except OSError:
                req_mtime = 0.0
            if req_mtime > best_mtime:
                best_mtime = req_mtime
                best_req = request_flag
                best_close = close_flag
                best_keep = keep_flag

    return best_req, best_close, best_keep


def touch_signal_file(path: Path | None) -> bool:
    if path is None:
        return False
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch(exist_ok=True)
        return True
    except Exception:
        return False


def send_sim_vivado_replay_logs(
    config: Config,
    chat_id: int,
    job: JobRequest,
    started_ts: float,
    run_log: Path | None = None,
) -> None:
    if job.menu_no != 5:
        return
    if config.sim_vivado_log_lines <= 0 and not config.sim_vivado_send_log_file:
        return

    log_path = find_recent_vivado_sim_log(
        job,
        started_ts,
        run_log=run_log,
        require_fresh=False,
    )
    if log_path is None:
        hinted = extract_vivado_log_candidates_from_run_log(run_log) if run_log is not None else []
        hinted_existing = next((p for p in hinted if p.exists() and p.is_file()), None)
        if hinted_existing is not None:
            log_path = hinted_existing
        elif hinted:
            safe_send_text(
                config,
                chat_id,
                "⚠️ <b>[SIM_VIVADO_LOG]</b> current-run Vivado log not updated yet.\n"
                f"<i>hinted_log:</i> <code>{html_escape(hinted[0].name)}</code>",
            )
            return
        else:
            safe_send_text(config, chat_id, "⚠️ <b>[SIM_VIVADO_LOG]</b> current-run Vivado log file not found.")
            return

    excerpt_lines: list[str] = []
    marker_found = False
    truncated = False
    if config.sim_vivado_log_lines > 0:
        excerpt_lines, marker_found, truncated = extract_replay_log_excerpt(log_path, config.sim_vivado_log_lines)

    if excerpt_lines:
        summary_text = build_sim_vivado_summary_text(
            log_path=log_path,
            excerpt_lines=excerpt_lines,
            marker_found=marker_found,
            truncated=truncated,
        )
        safe_send_text(config, chat_id, summary_text)
    else:
        safe_send_text(
            config,
            chat_id,
            "\n".join(
                [
                    "📊 <b>[SIM_VIVADO_SUMMARY]</b>",
                    f"📄 <i>log_file:</i> <code>{html_escape(log_path.name)}</code>",
                    "<i>No excerpt lines available.</i>",
                ]
            ),
        )

    if config.sim_vivado_send_log_file:
        safe_send_document(config, chat_id, log_path, f"sim_vivado log | {log_path.name}")


def normalize_hierarchy_scope(raw: str) -> str | None:
    return HIERARCHY_SCOPE_ALIASES.get(raw.strip().lower())


def hierarchy_scope_from_callback(scope_code: str) -> str | None:
    for scope_name, callback_code in HIERARCHY_SCOPE_CALLBACK_CODES.items():
        if callback_code == scope_code:
            return scope_name
    return None


def build_menu_invocation(
    config: Config,
    menu_no: int,
    project_path: Path,
    extra_tokens: list[str],
    command_name: str,
) -> tuple[JobRequest | None, str | None]:
    entry = config.menu_registry.get(menu_no)
    if entry is None:
        return None, f"Menu {menu_no} is not available in MAIN.bat mapping."

    if not entry.script_path.exists():
        return None, f"Mapped script not found for menu {menu_no}: {entry.script_path}"

    script_args: list[str] = [str(project_path)]
    stdin_lines: list[str] = []
    tokens = [t for t in extra_tokens if t.strip()]
    sim_vivado_close_gui: bool | None = None

    usage = MENU_USAGE.get(menu_no, f"Usage: /task {menu_no} <project> [args...]")

    if menu_no in {1, 3}:
        if not tokens:
            return None, usage
        modules, err = parse_module_selection(" ".join(tokens))
        if err:
            return None, f"{usage}\n{err}"
        stdin_lines.extend([modules or "", ""])

    elif menu_no == 2:
        scope_flag = ""
        flags: list[str] = []

        for token in tokens:
            lower = token.lower()
            normalized_scope = normalize_hierarchy_scope(lower)
            if normalized_scope:
                if scope_flag:
                    return None, f"{usage}\nOnly one scope can be specified."
                scope_flag = normalized_scope
            elif lower in {"--once", "--tb-only"}:
                flags.append(lower)
            else:
                return None, usage

        if scope_flag:
            scope_flag_cli = HIERARCHY_SCOPE_FLAGS.get(scope_flag, "")
            if scope_flag_cli:
                flags.append(scope_flag_cli)

        if "--once" not in flags:
            flags.insert(0, "--once")

        script_args.extend(flags)

    elif menu_no == 4:
        if len(tokens) > 1:
            return None, usage
        if not tokens:
            script_args.append("N")
        else:
            decision = parse_yes_no_token(tokens[0])
            if decision is None:
                return None, usage
            script_args.append("Y" if decision else "N")
        stdin_lines.append("")

    elif menu_no == 5:
        if len(tokens) < 2 or len(tokens) > 3:
            return None, usage
        folder_idx, err = parse_positive_int(tokens[0], "folder_idx")
        if err:
            return None, f"{usage}\n{err}"
        tb_idx, err = parse_positive_int(tokens[1], "tb_idx")
        if err:
            return None, f"{usage}\n{err}"
        # Default for bot mode: close GUI after replay unless user explicitly keeps it.
        sim_vivado_close_gui = True
        if len(tokens) == 3:
            parsed_choice = parse_sim_vivado_close_choice(tokens[2])
            if parsed_choice is None:
                return None, f"{usage}\nclose-gui option must be --close-gui or --keep-gui."
            sim_vivado_close_gui = parsed_choice
        # Keep final close prompt undecided until replay completion (Telegram button decision).
        stdin_lines.extend([str(folder_idx), str(tb_idx)])

    elif menu_no == 6:
        if len(tokens) != 1:
            return None, usage
        tb_idx, err = parse_positive_int(tokens[0], "tb_idx")
        if err:
            return None, f"{usage}\n{err}"
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
            script_args.append("--all")
        else:
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
                value, err = parse_positive_int(tokens[i + 1], lower)
                if err:
                    return None, f"{usage}\n{err}"
                script_args.extend([lower, str(value)])
                i += 1
            elif lower.startswith("--step="):
                value, err = parse_positive_int(token.split("=", 1)[1], "--step")
                if err:
                    return None, f"{usage}\n{err}"
                script_args.extend(["--step", str(value)])
            elif lower.startswith("--max-signals="):
                value, err = parse_positive_int(token.split("=", 1)[1], "--max-signals")
                if err:
                    return None, f"{usage}\n{err}"
                script_args.extend(["--max-signals", str(value)])
            else:
                return None, usage
            i += 1

        if "--no-pause" not in [a.lower() for a in script_args]:
            script_args.append("--no-pause")

    elif menu_no in {10, 11, 12, 14, 15, 18}:
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
            script_args.append("--all")
        else:
            script_args.extend(["--dut", dut_name])
        if force_write:
            script_args.append("--force")
        script_args.append("--no-pause")

    else:
        return None, f"Menu {menu_no} is not supported."

    stdin_text = format_stdin(stdin_lines)
    cmd = tuple(["cmd.exe", "/c", str(entry.script_path), *script_args])
    artifacts = (project_path / "log", project_path / "output")
    if menu_no == 5:
        artifacts = (project_path / "tb",) + artifacts

    return (
        JobRequest(
            command_name=command_name,
            menu_no=menu_no,
            project_name=project_path.name,
            script_path=entry.script_path,
            cwd=config.automation_repo_root,
            cmd=cmd,
            stdin_text=stdin_text,
            artifact_paths=artifacts,
            sim_vivado_close_gui=sim_vivado_close_gui,
        ),
        None,
    )


def build_setup_project_invocation(
    config: Config,
    project_name: str,
    hdl_ext: str,
) -> tuple[JobRequest | None, str | None]:
    name = project_name.strip()
    if not name:
        return None, "Usage: /setup_project <name> [v|sv]"
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
        return None, "Project name can only contain letters, digits, underscore, dot, and dash."

    ext = hdl_ext.strip().lower() if hdl_ext else "v"
    if ext not in {"v", "sv"}:
        return None, "Usage: /setup_project <name> [v|sv]"

    script_path = (
        config.automation_templates_root
        / "contexts"
        / "project_bootstrap"
        / "adapters"
        / "bat"
        / "project_create.bat"
    ).resolve()
    if not script_path.exists():
        return None, f"Setup script not found: {script_path}"

    cmd = (
        "cmd.exe",
        "/c",
        str(script_path),
        name,
        f"--hdl-ext={ext}",
        "--no-pause",
    )

    return (
        JobRequest(
            command_name="setup_project",
            menu_no=None,
            project_name=name,
            script_path=script_path,
            cwd=config.automation_repo_root,
            cmd=cmd,
            stdin_text=None,
            artifact_paths=(config.project_root / name,),
            sim_vivado_close_gui=None,
        ),
        None,
    )

def launch_job_async(config: Config, chat_id: int, job: JobRequest) -> None:
    job_info = {
        "command": job.command_name,
        "menu_no": job.menu_no,
        "project": job.project_name,
        "started_at": time.time(),
        "sim_vivado_close_gui": job.sim_vivado_close_gui,
    }

    if not STATE.try_start_job(job_info):
        current, _ = STATE.snapshot()
        send_text(config, chat_id, "Another task is already running.\n" + format_status(current, None))
        return

    worker = threading.Thread(
        target=run_job_worker,
        args=(config, chat_id, job),
        daemon=True,
    )
    worker.start()


def run_job_worker(config: Config, chat_id: int, job: JobRequest) -> None:
    start_ts = time.time()
    duration = 0
    result_rc = -1
    finished_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")

    sanitized = re.sub(r"[^A-Za-z0-9_-]", "_", job.command_name)[:40]
    if not sanitized:
        sanitized = "task"
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    run_log = Path(tempfile.gettempdir()) / f"telegram_fpga_{sanitized}_{timestamp}.log"

    timed_out = False
    sim_vivado_replay_state: str | None = None
    sim_vivado_replay_source: str | None = None
    sim_vivado_auto_completed = False
    sim_vivado_controller_detached = False
    sim_vivado_close_decision: str | None = None

    try:
        if os.name != "nt":
            safe_send_text(config, chat_id, "This bot launcher must run on Windows (cmd.exe required).")
            return

        if not job.script_path.exists():
            safe_send_text(config, chat_id, f"Script not found: {job.script_path}")
            return

        start_lines = [f"🚀 <b>[START]</b> <i>command=</i><code>{html_escape(job.command_name)}</code>"]
        if job.menu_no is not None:
            start_lines.append(f"🔹 <i>menu=</i><code>{job.menu_no}</code>")
        if job.project_name:
            start_lines.append(f"🔹 <i>project=</i><code>{html_escape(job.project_name)}</code>")
        start_lines.append(f"🔹 <i>script=</i><code>{html_escape(job.script_path.name)}</code>")
        safe_send_text(config, chat_id, "\n".join(start_lines))

        with run_log.open("w", encoding="utf-8", errors="replace") as out:
            proc = subprocess.Popen(
                list(job.cmd),
                cwd=str(job.cwd),
                stdout=out,
                stderr=subprocess.STDOUT,
                stdin=subprocess.PIPE if job.stdin_text is not None else None,
                text=True,
                encoding="utf-8",
                errors="replace",
                env=os.environ.copy(),
            )

            sim_vivado_stdin = proc.stdin if (job.menu_no == 5 and proc.stdin is not None) else None
            if job.stdin_text is not None and proc.stdin is not None:
                proc.stdin.write(job.stdin_text)
                proc.stdin.flush()
                if job.menu_no != 5:
                    proc.stdin.close()

            last_progress = time.time()
            last_replay_check = 0.0

            while True:
                rc = proc.poll()
                now = time.time()
                elapsed = int(now - start_ts)

                if rc is not None:
                    result_rc = int(rc)
                    break

                if elapsed >= config.command_timeout_sec:
                    timed_out = True
                    proc.kill()
                    try:
                        proc.wait(timeout=5)
                    except Exception:
                        pass
                    result_rc = 124
                    break

                if (
                    job.menu_no == 5
                    and config.sim_vivado_auto_complete_on_replay
                    and (now - last_replay_check) >= config.sim_vivado_replay_check_sec
                ):
                    last_replay_check = now
                    replay_state = detect_replay_completion_from_run_log(run_log)
                    replay_source = "run_log"
                    replay_log_path: Path | None = run_log
                    request_flag, close_flag, keep_flag = find_sim_vivado_prompt_ipc_flags(
                        job,
                        start_ts,
                        run_log=run_log,
                    )
                    if replay_state is None and request_flag is not None and request_flag.exists():
                        replay_state = "success"
                        replay_source = "prompt_ipc"
                        replay_log_path = request_flag
                    if replay_state is None:
                        replay_state, replay_log_path = detect_replay_completion_from_vivado_logs(
                            job,
                            start_ts,
                            run_log=run_log,
                        )
                        replay_source = "vivado_log"
                    if replay_state is not None:
                        sim_vivado_replay_state = replay_state
                        sim_vivado_replay_source = replay_source
                        sim_vivado_auto_completed = True
                        if replay_state != "success":
                            safe_send_text(
                                config,
                                chat_id,
                                "\n".join(
                                    [
                                        "❌ <b>[INFO]</b> sim_vivado replay failed.",
                                        f"🔹 <i>source=</i><code>{html_escape(replay_source)}</code>",
                                        f"📄 <i>log=</i><code>{html_escape(replay_log_path.name if replay_log_path else '(unknown)')}</code>",
                                    ]
                                ),
                            )
                            result_rc = 1
                            break

                        if request_flag is None or close_flag is None or keep_flag is None:
                            request_flag, close_flag, keep_flag = find_sim_vivado_prompt_ipc_flags(
                                job,
                                start_ts,
                                run_log=run_log,
                            )
                        prompt_token = uuid.uuid4().hex[:10]
                        prompt_event = threading.Event()
                        STATE.register_sim_vivado_prompt(
                            prompt_token,
                            {
                                "event": prompt_event,
                                "decision": None,
                                "resolved": False,
                                "request_flag": request_flag,
                                "close_flag": close_flag,
                                "keep_flag": keep_flag,
                            },
                        )
                        prompt_markup = {
                            "inline_keyboard": [
                                [
                                    {"text": "🛑 Close GUI", "callback_data": f"simgui_c_{prompt_token}"},
                                    {"text": "🖥 Keep GUI", "callback_data": f"simgui_k_{prompt_token}"},
                                ]
                            ]
                        }
                        safe_send_text(
                            config,
                            chat_id,
                            "\n".join(
                                [
                                    "✨ <b>[INFO]</b> run all completed.",
                                    f"🔹 <i>source=</i><code>{html_escape(replay_source)}</code>",
                                    f"📄 <i>log=</i><code>{html_escape(replay_log_path.name if replay_log_path else '(unknown)')}</code>",
                                    "<b>Close Vivado GUI now?</b>",
                                ]
                            ),
                            reply_markup=prompt_markup,
                        )

                        chosen_decision: str | None = None
                        if prompt_event.wait(timeout=SIM_VIVADO_PROMPT_TIMEOUT_SEC):
                            prompt_state = STATE.get_sim_vivado_prompt(prompt_token)
                            if prompt_state is not None:
                                raw_decision = str(prompt_state.get("decision", "")).strip().lower()
                                if raw_decision in {"close", "keep"}:
                                    chosen_decision = raw_decision

                        if chosen_decision is None:
                            chosen_decision = "close" if job.sim_vivado_close_gui is not False else "keep"
                            safe_send_text(
                                config,
                                chat_id,
                                f"ℹ️ <b>[INFO]</b> No button response. Applying default: <code>{chosen_decision}</code>",
                            )

                        sim_vivado_close_decision = chosen_decision
                        STATE.pop_sim_vivado_prompt(prompt_token)

                        decision_written = False
                        if sim_vivado_stdin is not None and not sim_vivado_stdin.closed:
                            try:
                                sim_vivado_stdin.write("y\r\n" if chosen_decision == "close" else "n\r\n")
                                sim_vivado_stdin.flush()
                                sim_vivado_stdin.close()
                                decision_written = True
                            except Exception:
                                decision_written = False

                        if chosen_decision == "close":
                            sent_flag = decision_written or touch_signal_file(close_flag)
                            if not sent_flag:
                                terminate_process_tree(proc.pid)
                            try:
                                proc.wait(timeout=15)
                            except Exception:
                                terminate_process_tree(proc.pid)
                                try:
                                    proc.wait(timeout=8)
                                except Exception:
                                    pass
                        else:
                            if not decision_written:
                                touch_signal_file(keep_flag)
                            sim_vivado_controller_detached = True

                        result_rc = 0
                        break

                if (now - last_progress) >= config.progress_interval_sec:
                    progress_lines = [f"⏳ <b>[PROGRESS]</b> <i>command=</i><code>{html_escape(job.command_name)}</code>", f"⏱ <i>elapsed=</i><code>{elapsed}s</code>"]
                    if job.menu_no is not None:
                        progress_lines.append(f"🔹 <i>menu=</i><code>{job.menu_no}</code>")
                    if job.project_name:
                        progress_lines.append(f"🔹 <i>project=</i><code>{html_escape(job.project_name)}</code>")
                    safe_send_text(config, chat_id, "\n".join(progress_lines))
                    last_progress = now

                time.sleep(1)

        duration = int(time.time() - start_ts)
        finished_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")
        current_command_log: Path | None = None
        current_command_log_label = "run_log"
        if job.menu_no == 2:
            current_command_log = find_recent_hierarchy_log(
                job,
                start_ts,
                run_log=run_log,
                require_fresh=not timed_out,
            )
            if current_command_log is not None:
                current_command_log_label = "log"

        if timed_out:
            status_lines = [
                f"⏰ <b>[TIMEOUT]</b> <i>command=</i><code>{html_escape(job.command_name)}</code>",
                f"⏱ <i>limit=</i><code>{config.command_timeout_sec}s</code> <i>elapsed=</i><code>{duration}s</code>",
                f"📄 <i>{html_escape(current_command_log_label)}=</i><code>{html_escape((current_command_log or run_log).name)}</code>",
            ]
        else:
            status = "✅ <b>[SUCCESS]</b>" if result_rc == 0 else "❌ <b>[FAIL]</b>"
            status_lines = [
                f"{status} <i>command=</i><code>{html_escape(job.command_name)}</code>",
                f"🔹 <i>rc=</i><code>{result_rc}</code> ⏱ <i>elapsed=</i><code>{duration}s</code>",
                f"📄 <i>{html_escape(current_command_log_label)}=</i><code>{html_escape((current_command_log or run_log).name)}</code>",
            ]

        if job.menu_no is not None:
            status_lines.append(f"🔹 <i>menu=</i><code>{job.menu_no}</code>")
        if job.project_name:
            status_lines.append(f"🔹 <i>project=</i><code>{html_escape(job.project_name)}</code>")
        if job.menu_no == 5 and job.sim_vivado_close_gui is not None:
            status_lines.append(f"🔹 <i>close_gui=</i><code>{job.sim_vivado_close_gui}</code>")
        if job.menu_no == 5 and sim_vivado_close_decision:
            status_lines.append(f"🔹 <i>close_decision=</i><code>{html_escape(sim_vivado_close_decision)}</code>")
        if sim_vivado_auto_completed:
            status_lines.append(f"🔹 <i>sim_vivado_replay=</i><code>{html_escape(str(sim_vivado_replay_state))}</code>")
            if sim_vivado_replay_source:
                status_lines.append(f"🔹 <i>sim_vivado_replay_source=</i><code>{html_escape(sim_vivado_replay_source)}</code>")
            if sim_vivado_controller_detached:
                status_lines.append("🔹 <i>controller_detached=</i><code>1</code>")
            status_lines.append("🔹 <i>auto_complete=</i><code>1</code>")

        for path in job.artifact_paths:
            status_lines.append(f"📎 <i>artifact=</i><code>{html_escape(path.name)}</code>")

        markup = None
        if not timed_out and result_rc == 0 and job.menu_no == 2 and job.project_name:
            scope = "src"
            if "--tb-only" in job.cmd:
                scope = "tb"
                
            s1 = "🟢 [S1] src only" if scope == "src" else "⚪ [S1] src only"
            s3 = "🟢 [S3] tb only" if scope == "tb" else "⚪ [S3] tb only"

            markup = {
                "inline_keyboard": [
                    [
                        {"text": s1, "callback_data": f"hier_src_{job.project_name}"},
                        {"text": s3, "callback_data": f"hier_tb_{job.project_name}"}
                    ],
                ]
            }

            if scope == "tb":
                project_path, project_error = resolve_project(config.project_root, job.project_name)
                if project_error is None and project_path is not None:
                    tb_folder_targets = find_vivado_tb_targets(config, project_path)
                    folder_buttons: list[dict[str, str]] = []
                    for folder_target in tb_folder_targets:
                        folder_idx = int(folder_target.get("folder_idx", 0))
                        display_name = get_hierarchy_tb_folder_label(folder_target)
                        folder_buttons.append(
                            {
                                "text": f"📂 [{folder_idx}] {display_name}",
                                "callback_data": f"hier_tbf_{folder_idx}_{job.project_name}",
                            }
                        )
                    if folder_buttons:
                        markup["inline_keyboard"].extend(
                            build_inline_keyboard_rows(folder_buttons, row_size=1)["inline_keyboard"]
                        )

            markup["inline_keyboard"].append(
                [
                    {"text": "🔄 Refresh", "callback_data": f"hier_ref_{scope}_{job.project_name}"},
                    {"text": "❌ Quit", "callback_data": "hier_quit"},
                ]
            )
            
            hierarchy_text_log = run_log if run_log.exists() else current_command_log
            if hierarchy_text_log is None and current_command_log is not None and current_command_log.exists():
                hierarchy_text_log = current_command_log
            if hierarchy_text_log is not None and hierarchy_text_log.exists():
                try:
                    hier_lines = extract_hierarchy_lines(hierarchy_text_log)
                    if not hier_lines and current_command_log is not None and current_command_log != hierarchy_text_log:
                        hier_lines = extract_hierarchy_lines(current_command_log)
                    if hier_lines:
                        status_lines.append("")
                        status_lines.append("🌳 <b>Hierarchy:</b>")
                        status_lines.append("<pre>")
                        status_lines.extend(hier_lines)
                        status_lines.append("</pre>")
                except Exception as e:
                    status_lines.append(f"<i>Failed to parse hierarchy output: {e}</i>")

        safe_send_text(config, chat_id, "\n".join(status_lines), reply_markup=markup)
        if not timed_out:
            send_sim_vivado_replay_logs(config, chat_id, job, start_ts, run_log=run_log)
        if not timed_out and result_rc == 0:
            send_diagram_artifacts(config, chat_id, job, start_ts)
            send_report_artifacts(config, chat_id, job, start_ts)

    except Exception as exc:
        safe_send_text(config, chat_id, f"🚨 <b>[ERROR]</b> Failed to execute command: <code>{html_escape(exc)}</code>")
    finally:
        STATE.finish_job(
            {
                "command": job.command_name,
                "menu_no": job.menu_no,
                "project": job.project_name,
                "sim_vivado_close_gui": job.sim_vivado_close_gui,
                "sim_vivado_close_decision": sim_vivado_close_decision,
                "sim_vivado_controller_detached": sim_vivado_controller_detached,
                "return_code": result_rc,
                "duration_sec": duration,
                "finished_at_utc": finished_at,
                "timed_out": timed_out,
            }
        )


def parse_task_command(config: Config, args_text: str) -> tuple[JobRequest | None, str | None]:
    tokens = parse_cli_tokens(args_text)
    if len(tokens) < 2:
        return None, "Usage: /task <menu_no> <project> [args...]"

    if not re.fullmatch(r"\d+", tokens[0]):
        return None, "Usage: /task <menu_no> <project> [args...]"

    menu_no = int(tokens[0])
    if menu_no < 1 or menu_no > 19:
        return None, "menu_no must be between 1 and 19."

    project_path, error = resolve_project(config.project_root, tokens[1])
    if error:
        return None, error
    if project_path is None:
        return None, "Failed to resolve project path."

    request, error = build_menu_invocation(
        config=config,
        menu_no=menu_no,
        project_path=project_path,
        extra_tokens=tokens[2:],
        command_name="task",
    )
    if error:
        return None, error
    return request, None


def parse_alias_command(config: Config, command: str, args_text: str) -> tuple[JobRequest | None, str | None]:
    tokens = parse_cli_tokens(args_text)

    if command in {
        "/build",
        "/build_program",
        "/program",
        "/report_html",
        "/report_docs",
        "/vivado_gui",
        "/finalize_bd",
        "/retarget_ip",
        "/open_presentation",
        "/vcd_svg",
    }:
        usage_map = {
            "/build": "Usage: /build <project>",
            "/build_program": "Usage: /build_program <project>",
            "/program": "Usage: /program <project>",
            "/report_html": "Usage: /report_html <project>",
            "/report_docs": "Usage: /report_docs <project>",
            "/vivado_gui": "Usage: /vivado_gui <project>",
            "/finalize_bd": "Usage: /finalize_bd <project>",
            "/retarget_ip": "Usage: /retarget_ip <project>",
            "/open_presentation": "Usage: /open_presentation <project>",
            "/vcd_svg": "Usage: /vcd_svg <project>",
        }
        if len(tokens) != 1:
            return None, usage_map[command]

        menu_map = {
            "/build": 13,
            "/build_program": 17,
            "/program": 16,
            "/report_html": 10,
            "/report_docs": 11,
            "/vivado_gui": 12,
            "/finalize_bd": 14,
            "/retarget_ip": 15,
            "/open_presentation": 18,
            "/vcd_svg": 8,
        }
        menu_no = menu_map[command]

        project_path, error = resolve_project(config.project_root, tokens[0])
        if error:
            return None, error
        if project_path is None:
            return None, "Failed to resolve project path."

        return build_menu_invocation(config, menu_no, project_path, [], command[1:])

    if command in {"/schematic", "/fsm"}:
        if len(tokens) < 2:
            return None, f"Usage: {command} <project> <modules: ALL|1,3,5|module_a,module_b>"

        project_path, error = resolve_project(config.project_root, tokens[0])
        if error:
            return None, error
        if project_path is None:
            return None, "Failed to resolve project path."

        menu_no = 1 if command == "/schematic" else 3
        return build_menu_invocation(config, menu_no, project_path, [" ".join(tokens[1:])], command[1:])

    if command == "/hierarchy":
        if len(tokens) < 1 or len(tokens) > 2:
            return None, "Usage: /hierarchy <project> [src|tb|tb_only|tb-only]"

        project_path, error = resolve_project(config.project_root, tokens[0])
        if error:
            return None, error
        if project_path is None:
            return None, "Failed to resolve project path."

        extras: list[str] = []
        if len(tokens) == 2:
            extras.append(tokens[1])

        return build_menu_invocation(config, 2, project_path, extras, "hierarchy")

    if command == "/presentation":
        if len(tokens) < 1 or len(tokens) > 2:
            return None, "Usage: /presentation <project> [clean_assets]"

        project_path, error = resolve_project(config.project_root, tokens[0])
        if error:
            return None, error
        if project_path is None:
            return None, "Failed to resolve project path."

        extras = []
        if len(tokens) == 2:
            extras = [tokens[1]]

        return build_menu_invocation(config, 4, project_path, extras, "presentation")

    if command == "/sim_vivado":
        if len(tokens) < 3 or len(tokens) > 4:
            return None, "Usage: /sim_vivado <project> <folder_idx> <tb_idx> [--close-gui|--keep-gui]"

        project_path, error = resolve_project(config.project_root, tokens[0])
        if error:
            return None, error
        if project_path is None:
            return None, "Failed to resolve project path."

        return build_menu_invocation(config, 5, project_path, tokens[1:], "sim_vivado")

    if command == "/sim_auto_report":
        if len(tokens) != 2:
            return None, "Usage: /sim_auto_report <project> <tb_idx>"

        project_path, error = resolve_project(config.project_root, tokens[0])
        if error:
            return None, error
        if project_path is None:
            return None, "Failed to resolve project path."

        return build_menu_invocation(config, 6, project_path, [tokens[1]], "sim_auto_report")

    if command == "/sim_iverilog":
        if len(tokens) < 2:
            return None, "Usage: /sim_iverilog <project> (--all | --tb <name>)"

        project_path, error = resolve_project(config.project_root, tokens[0])
        if error:
            return None, error
        if project_path is None:
            return None, "Failed to resolve project path."

        return build_menu_invocation(config, 7, project_path, tokens[1:], "sim_iverilog")

    if command == "/vcd_wavedrom":
        if len(tokens) < 1:
            return None, "Usage: /vcd_wavedrom <project> [--step N] [--max-signals N] [--html|--no-html]"

        project_path, error = resolve_project(config.project_root, tokens[0])
        if error:
            return None, error
        if project_path is None:
            return None, "Failed to resolve project path."

        return build_menu_invocation(config, 9, project_path, tokens[1:], "vcd_wavedrom")

    if command == "/tb_scaffold":
        if len(tokens) < 2:
            return None, "Usage: /tb_scaffold <project> (--all | --dut <name>) [--force]"

        project_path, error = resolve_project(config.project_root, tokens[0])
        if error:
            return None, error
        if project_path is None:
            return None, "Failed to resolve project path."

        return build_menu_invocation(config, 19, project_path, tokens[1:], "tb_scaffold")

    if command == "/setup_project":
        if len(tokens) < 1 or len(tokens) > 2:
            return None, "Usage: /setup_project <name> [v|sv]"
        hdl_ext = tokens[1] if len(tokens) == 2 else "v"
        return build_setup_project_invocation(config, tokens[0], hdl_ext)

    return None, "Unknown command. Use /help"


def process_message(config: Config, message: dict) -> None:
    text = str(message.get("text", "")).strip()
    if not text.startswith("/"):
        return

    chat = message.get("chat") or {}
    chat_id = int(chat.get("id", 0))

    user = message.get("from") or {}
    user_id = int(user.get("id", 0))
    user_name = normalize_username(str(user.get("username", "")) or "")

    allowed = user_id in config.allowed_user_ids or (user_name and user_name in config.allowed_usernames)
    if not allowed:
        if chat_id:
            send_text(config, chat_id, "Access denied: user_id/username is not allowed.")
        return

    if config.allowed_chat_ids and chat_id not in config.allowed_chat_ids:
        send_text(config, chat_id, "Access denied: chat_id is not allowed.")
        return

    if text in {"📊 Status", "🕒 Last", "🚀 Select Project", "❓ Help"}:
        # Map localized persistent keyboard names to commands
        map_cmd = {"📊 Status": "/status", "🕒 Last": "/last", "🚀 Select Project": "/run", "❓ Help": "/help"}
        command = map_cmd[text]
        args = ""
    else:
        first, _, rest = text.partition(" ")
        command = normalize_command(first)
        args = rest.strip()

    if command == "/start":
        help_text, help_kb = build_help()
        send_text(config, chat_id, help_text, reply_markup=get_main_menu_keyboard())
        return

    if command == "/help":
        help_text, help_kb = build_help()
        send_text(config, chat_id, help_text, reply_markup=help_kb)
        return

    if command == "/projects":
        projects = discover_projects(config.project_root)
        if not projects:
            send_text(config, chat_id, f"No valid projects under: {config.project_root}")
            return
        lines = ["📂 <b>[Projects]</b>"] + [f"🔹 <code>{html_escape(line)}</code>" for line in build_projects_index_lines(projects)]
        lines.append("")
        lines.append("💡 <i>Tip: You can use project index in all commands (e.g., /build 1, /task 13 2).</i>")
        send_text(config, chat_id, "\n".join(lines))
        return

    if command == "/status":
        current, last = STATE.snapshot()
        send_text(config, chat_id, format_status(current, last))
        return

    if command == "/hierarchy":
        hierarchy_tokens = parse_cli_tokens(args)
        if len(hierarchy_tokens) == 2 and normalize_hierarchy_scope(hierarchy_tokens[1]) == "tb_only":
            text, markup, error = prepare_hierarchy_tb_folder_picker(config, hierarchy_tokens[0])
            if error:
                send_text(config, chat_id, error)
            elif text is not None and markup is not None:
                send_text(config, chat_id, text, reply_markup=markup)
            else:
                send_text(config, chat_id, "Failed to prepare TB folder list.")
            return

    if command == "/last":
        _, last = STATE.snapshot()
        if last is None:
            send_text(config, chat_id, "ℹ️ No previous job result.")
        else:
            lines = [
                "🕒 [Last Job]",
                f"🔹 command: {last.get('command')}",
                f"🔹 menu: {last.get('menu_no')}",
                f"🔹 project: {last.get('project')}",
                f"🔹 close_gui: {last.get('sim_vivado_close_gui')}" if last.get("menu_no") == 5 else "",
                f"🔹 close_decision: {last.get('sim_vivado_close_decision')}" if last.get("menu_no") == 5 else "",
                f"🔹 controller_detached: {last.get('sim_vivado_controller_detached')}"
                if last.get("menu_no") == 5
                else "",
                f"🔹 rc: {last.get('return_code')}",
                f"⏱ duration: {last.get('duration_sec')}s",
                f"📅 finished_at_utc: {last.get('finished_at_utc')}",
            ]
            send_text(config, chat_id, "\n".join([x for x in lines if x]))
        return

    if command == "/task":
        request, error = parse_task_command(config, args)
    elif command == "/run" or command == "/sim":
        handle_project_wizard(config, chat_id, user_id)
        return
    else:
        request, error = parse_alias_command(config, command, args)

    if error:
        send_text(config, chat_id, error)
        return
    if request is None:
        send_text(config, chat_id, "Failed to build execution request.")
        return

    launch_job_async(config, chat_id, request)
    
def find_hdl_modules(project_path: Path) -> list[str]:
    modules = set()
    mod_re = re.compile(r'\bmodule\s+([a-zA-Z_]\w*)\b')
    for folder in ("src", "tb", "include", "inc"):
        search_dir = project_path / folder
        if not search_dir.exists():
            continue
        for ext in ("*.v", "*.sv", "*.svh"):
            for f in search_dir.rglob(ext):
                try:
                    text = f.read_text(encoding="utf-8", errors="ignore")
                    clean = re.sub(r'//.*', '', text)
                    clean = re.sub(r'/\*.*?\*/', '', clean, flags=re.DOTALL)
                    for m in mod_re.finditer(clean):
                        modules.add(m.group(1))
                except Exception:
                    pass
    return sorted(list(modules))


def find_schematic_modules(config: Config, project_path: Path) -> list[str]:
    templates_root = config.automation_templates_root
    manifest_ctx = templates_root / "shared" / "adapters" / "bat" / "bootstrap_manifest_context.bat"
    run_schematic_ps = (
        templates_root
        / "contexts"
        / "code_intel"
        / "adapters"
        / "powershell"
        / "code_run_schematic_jobs.ps1"
    )
    hdl_indexer = (
        templates_root
        / "contexts"
        / "code_intel"
        / "adapters"
        / "cli"
        / "code_index_hdl_cli.js"
    )

    if not (manifest_ctx.exists() and run_schematic_ps.exists() and hdl_indexer.exists()):
        return find_hdl_modules(project_path)

    try:
        manifest_proc = subprocess.run(
            ["cmd.exe", "/c", str(manifest_ctx), str(project_path)],
            cwd=str(config.automation_repo_root),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=120,
        )
    except Exception:
        return find_hdl_modules(project_path)

    if manifest_proc.returncode != 0:
        return find_hdl_modules(project_path)

    manifest_dir = project_path / "output" / "manifest"
    manifest_json = manifest_dir / "manifest_resolved.json"
    manifest_src = manifest_dir / "manifest_src_files.lst"
    manifest_inc = manifest_dir / "manifest_inc_dirs.lst"
    if not (manifest_json.exists() and manifest_src.exists() and manifest_inc.exists()):
        return find_hdl_modules(project_path)

    try:
        mod_proc = subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(run_schematic_ps),
                "-ProjectPath",
                str(project_path),
                "-ListModulesOnly",
                "-HdlIndexerPath",
                str(hdl_indexer),
                "-ManifestJson",
                str(manifest_json),
                "-ManifestSrcList",
                str(manifest_src),
                "-ManifestIncList",
                str(manifest_inc),
            ],
            cwd=str(config.automation_repo_root),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=120,
        )
    except Exception:
        return find_hdl_modules(project_path)

    if mod_proc.returncode != 0:
        return find_hdl_modules(project_path)

    out: list[str] = []
    seen: set[str] = set()
    for raw in mod_proc.stdout.splitlines():
        line = raw.strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_$]*", line):
            continue
        key = line.lower()
        if key in seen:
            continue
        seen.add(key)
        out.append(line)

    return out if out else find_hdl_modules(project_path)


def strip_hdl_comments(text: str) -> str:
    clean = re.sub(r"/\*[\s\S]*?\*/", "", text)
    clean = re.sub(r"//.*$", "", clean, flags=re.MULTILINE)
    return clean


def get_decl_regex(decl_type: str) -> re.Pattern[str] | None:
    patterns = {
        "module": r"\bmodule\s+(?:automatic\s+|static\s+)?([A-Za-z_][A-Za-z0-9_$]*)\b",
        "program": r"\bprogram\s+(?:automatic\s+|static\s+)?([A-Za-z_][A-Za-z0-9_$]*)\b",
        "package": r"\bpackage\s+([A-Za-z_][A-Za-z0-9_$]*)\b",
        "interface": r"\binterface\s+([A-Za-z_][A-Za-z0-9_$]*)\b",
        "class": r"\bclass\s+(?:automatic\s+|static\s+)?([A-Za-z_][A-Za-z0-9_$]*)\b",
        "checker": r"\bchecker\s+([A-Za-z_][A-Za-z0-9_$]*)\b",
    }
    pattern = patterns.get(decl_type)
    if pattern is None:
        return None
    return re.compile(pattern, flags=re.IGNORECASE | re.MULTILINE)


def get_project_relative_path(project_path: Path, target_path: Path) -> str:
    try:
        return os.path.relpath(target_path, project_path).replace("\\", "/")
    except Exception:
        return target_path.name


def get_manifest_src_files(project_path: Path) -> list[Path]:
    manifest_src = project_path / "output" / "manifest" / "manifest_src_files.lst"
    if not manifest_src.exists():
        return []

    out: list[Path] = []
    seen: set[Path] = set()
    try:
        rows = manifest_src.read_text(encoding="utf-8", errors="ignore").splitlines()
    except Exception:
        return []

    for raw in rows:
        rel = raw.strip()
        if not rel:
            continue
        candidate = (project_path / rel).resolve()
        if not candidate.exists() or not candidate.is_file():
            continue
        if candidate.suffix.lower() not in {".v", ".sv", ".svh"}:
            continue
        if candidate in seen:
            continue
        seen.add(candidate)
        out.append(candidate)
    return out


def get_hierarchy_rtl_source_files(project_path: Path) -> list[Path]:
    manifest_files = get_manifest_src_files(project_path)
    if manifest_files:
        return sorted(manifest_files, key=lambda path: str(path).lower())

    src_dir = project_path / "src"
    if not src_dir.exists():
        return []
    return sorted(
        [path for path in src_dir.rglob("*") if path.is_file() and path.suffix.lower() in {".v", ".sv", ".svh"}],
        key=lambda path: str(path).lower(),
    )


def build_hierarchy_rtl_module_catalog(project_path: Path) -> dict[str, dict[str, object]]:
    module_re = get_decl_regex("module")
    if module_re is None:
        return {}

    catalog: dict[str, dict[str, object]] = {}
    for src_file in get_hierarchy_rtl_source_files(project_path):
        try:
            raw = src_file.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            continue
        clean = strip_hdl_comments(raw)
        for match in module_re.finditer(clean):
            module_name = match.group(1).strip()
            key = module_name.lower()
            if key in catalog:
                continue
            line = clean[: match.start()].count("\n") + 1
            catalog[key] = {
                "name": module_name,
                "path": src_file,
                "rel_path": get_project_relative_path(project_path, src_file),
                "line": line,
            }
    return catalog


def get_decl_block_text(decl_type: str, decl_name: str, decl_path: Path) -> str:
    try:
        raw = decl_path.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return ""

    clean = strip_hdl_comments(raw)
    escaped_name = re.escape(decl_name)
    if decl_type == "module":
        pattern = re.compile(
            rf"\bmodule\s+(?:automatic\s+|static\s+)?{escaped_name}\b[\s\S]*?\bendmodule\b",
            flags=re.IGNORECASE | re.MULTILINE,
        )
    elif decl_type == "program":
        pattern = re.compile(
            rf"\bprogram\s+(?:automatic\s+|static\s+)?{escaped_name}\b[\s\S]*?\bendprogram\b",
            flags=re.IGNORECASE | re.MULTILINE,
        )
    else:
        return clean

    match = pattern.search(clean)
    return match.group(0) if match else clean


def get_tb_folder_source_files(folder_path: Path) -> list[Path]:
    direct = sorted(
        [path for path in folder_path.glob("*") if path.is_file() and path.suffix.lower() in {".v", ".sv"}],
        key=lambda path: str(path).lower(),
    )
    if direct:
        return direct
    return sorted(
        [path for path in folder_path.rglob("*") if path.is_file() and path.suffix.lower() in {".v", ".sv"}],
        key=lambda path: str(path).lower(),
    )


def get_tb_top_entries_for_folder(project_path: Path, folder_path: Path) -> list[dict[str, object]]:
    entries: list[dict[str, object]] = []
    decl_types = ("module", "program")

    for source_file in get_tb_folder_source_files(folder_path):
        try:
            raw = source_file.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            continue

        clean = strip_hdl_comments(raw)
        matches: list[tuple[int, str, str]] = []
        for decl_type in decl_types:
            decl_re = get_decl_regex(decl_type)
            if decl_re is None:
                continue
            for match in decl_re.finditer(clean):
                matches.append((match.start(), decl_type, match.group(1).strip()))

        for offset, decl_type, decl_name in sorted(matches, key=lambda item: (item[0], item[1], item[2].lower())):
            entries.append(
                {
                    "type": decl_type,
                    "name": decl_name,
                    "path": source_file,
                    "rel_path": get_project_relative_path(project_path, source_file),
                    "line": clean[:offset].count("\n") + 1,
                }
            )

    return entries


def get_direct_dut_entries_for_top(top_entry: dict[str, object], rtl_catalog: dict[str, dict[str, object]]) -> list[dict[str, object]]:
    block_text = get_decl_block_text(
        str(top_entry.get("type", "")),
        str(top_entry.get("name", "")),
        Path(str(top_entry.get("path", ""))),
    )
    if not block_text:
        return []

    out: list[dict[str, object]] = []
    seen: set[str] = set()
    for module_key in sorted(rtl_catalog.keys()):
        module_info = rtl_catalog[module_key]
        module_name = str(module_info.get("name", ""))
        if not module_name:
            continue
        inst_re = re.compile(
            rf"\b{re.escape(module_name)}\b\s*(?:#\s*\([\s\S]*?\)\s*)?([A-Za-z_][A-Za-z0-9_$]*)\s*\(",
            flags=re.IGNORECASE | re.MULTILINE,
        )
        if not inst_re.search(block_text):
            continue
        if module_key in seen:
            continue
        seen.add(module_key)
        out.append(module_info)
    return out


def get_tb_folder_sv_declarations(project_path: Path, folder_path: Path) -> list[dict[str, object]]:
    decl_types = ("package", "interface", "program", "class", "checker")
    entries: list[dict[str, object]] = []

    for source_file in sorted(
        [path for path in folder_path.rglob("*") if path.is_file() and path.suffix.lower() in {".sv", ".svh"}],
        key=lambda path: str(path).lower(),
    ):
        try:
            raw = source_file.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            continue
        clean = strip_hdl_comments(raw)
        rel_path = get_project_relative_path(project_path, source_file)

        for decl_type in decl_types:
            decl_re = get_decl_regex(decl_type)
            if decl_re is None:
                continue
            for match in decl_re.finditer(clean):
                entries.append(
                    {
                        "type": decl_type,
                        "name": match.group(1).strip(),
                        "rel_path": rel_path,
                        "line": clean[: match.start()].count("\n") + 1,
                    }
                )

    return sorted(entries, key=lambda item: (str(item["rel_path"]).lower(), int(item["line"]), str(item["name"]).lower()))


def get_tb_top_candidate(tb_file: Path) -> str:
    try:
        raw = tb_file.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return ""
    clean = strip_hdl_comments(raw)
    match = re.search(
        r"\b(?:module|program)\s+(?:(?:automatic|static)\s+)?([A-Za-z_][A-Za-z0-9_$]*)\b",
        clean,
        flags=re.IGNORECASE,
    )
    if not match:
        return ""
    return match.group(1).strip()


def run_manifest_context(config: Config, project_path: Path) -> bool:
    manifest_ctx = config.automation_templates_root / "shared" / "adapters" / "bat" / "bootstrap_manifest_context.bat"
    if not manifest_ctx.exists():
        return False

    try:
        manifest_proc = subprocess.run(
            ["cmd.exe", "/c", str(manifest_ctx), str(project_path)],
            cwd=str(config.automation_repo_root),
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=120,
        )
    except Exception:
        return False

    return manifest_proc.returncode == 0


def read_manifest_tb_entries(project_path: Path) -> list[dict[str, object]]:
    manifest_tb = project_path / "output" / "manifest" / "manifest_tb_files.lst"
    if not manifest_tb.exists():
        return []

    try:
        lines = manifest_tb.read_text(encoding="utf-8", errors="ignore").splitlines()
    except Exception:
        return []

    entries: list[dict[str, object]] = []
    for raw in lines:
        rel = raw.strip()
        if not rel:
            continue

        candidate = (project_path / rel).resolve()
        if not candidate.exists() or not candidate.is_file():
            continue
        if candidate.suffix.lower() not in {".v", ".sv"}:
            continue

        try:
            folder_rel = os.path.relpath(candidate.parent, project_path).replace("\\", "/")
        except Exception:
            folder_rel = "tb"
        if folder_rel in {".", ""}:
            folder_rel = "tb"

        try:
            file_rel = os.path.relpath(candidate, project_path).replace("\\", "/")
        except Exception:
            file_rel = candidate.name

        top_candidate = get_tb_top_candidate(candidate)
        entries.append(
            {
                "manifest_idx": len(entries) + 1,
                "path": str(candidate),
                "folder_display": folder_rel,
                "file_display": file_rel,
                "tb_name": candidate.name,
                "tb_stem": candidate.stem,
                "top_candidate": top_candidate,
                "has_top": bool(top_candidate),
            }
        )

    return entries


def read_tb_entries_fallback(project_path: Path) -> list[dict[str, object]]:
    tb_root = project_path / "tb"
    if not tb_root.exists():
        return []

    entries: list[dict[str, object]] = []
    for candidate in sorted(
        [path for path in tb_root.rglob("*") if path.is_file() and path.suffix.lower() in {".v", ".sv"}],
        key=lambda path: str(path).lower(),
    ):
        folder_rel = get_project_relative_path(project_path, candidate.parent)
        if folder_rel in {".", ""}:
            folder_rel = "tb"
        file_rel = get_project_relative_path(project_path, candidate)
        top_candidate = get_tb_top_candidate(candidate)
        entries.append(
            {
                "manifest_idx": len(entries) + 1,
                "path": str(candidate),
                "folder_display": folder_rel,
                "file_display": file_rel,
                "tb_name": candidate.name,
                "tb_stem": candidate.stem,
                "top_candidate": top_candidate,
                "has_top": bool(top_candidate),
            }
        )

    return entries


def get_tb_entries(config: Config, project_path: Path) -> list[dict[str, object]]:
    run_manifest_context(config, project_path)
    entries = read_manifest_tb_entries(project_path)
    if entries:
        return entries
    return read_tb_entries_fallback(project_path)


def build_vivado_tb_targets_from_entries(entries: list[dict[str, object]]) -> list[dict[str, object]]:
    unique_by_path: dict[str, dict[str, object]] = {}
    for entry in entries:
        path_key = str(entry.get("path", "")).lower()
        if path_key and path_key not in unique_by_path:
            unique_by_path[path_key] = dict(entry)

    unique_entries = sorted(unique_by_path.values(), key=lambda item: str(item.get("path", "")).lower())
    by_folder: dict[str, list[dict[str, object]]] = {}
    for entry in unique_entries:
        folder = str(entry.get("folder_display", "tb"))
        by_folder.setdefault(folder, []).append(entry)

    targets: list[dict[str, object]] = []
    folder_names = sorted(by_folder.keys(), key=lambda value: value.lower())
    for folder_idx, folder_name in enumerate(folder_names, start=1):
        folder_entries = sorted(
            by_folder.get(folder_name, []),
            key=lambda item: str(item.get("file_display", "")).lower(),
        )
        top_entries = [item for item in folder_entries if bool(item.get("has_top"))]
        tb_select = top_entries if top_entries else folder_entries
        if not tb_select:
            continue

        tb_targets: list[dict[str, object]] = []
        for tb_idx, entry in enumerate(tb_select, start=1):
            tb_targets.append(
                {
                    "tb_idx": tb_idx,
                    "file_display": str(entry.get("file_display", "")),
                    "tb_name": str(entry.get("tb_name", "")),
                    "tb_stem": str(entry.get("tb_stem", "")),
                    "top_candidate": str(entry.get("top_candidate", "")),
                    "has_top": bool(entry.get("has_top")),
                    "folder_display": folder_name,
                }
            )

        label = folder_name.split("/")[-1] if "/" in folder_name else folder_name
        targets.append(
            {
                "folder_idx": folder_idx,
                "folder_display": folder_name,
                "label": label,
                "tb_count": len(tb_targets),
                "tb_targets": tb_targets,
            }
        )

    label_count: dict[str, int] = {}
    for target in targets:
        label = str(target.get("label", ""))
        label_count[label] = label_count.get(label, 0) + 1
    for target in targets:
        label = str(target.get("label", ""))
        folder_display = str(target.get("folder_display", ""))
        target["display_name"] = label if label_count.get(label, 0) == 1 else folder_display

    return targets


def build_auto_report_tb_targets_from_entries(entries: list[dict[str, object]]) -> list[dict[str, object]]:
    targets: list[dict[str, object]] = []
    for entry in entries:
        targets.append(
            {
                "tb_idx": int(entry.get("manifest_idx", 0)),
                "file_display": str(entry.get("file_display", "")),
                "folder_display": str(entry.get("folder_display", "")),
                "tb_name": str(entry.get("tb_name", "")),
                "tb_stem": str(entry.get("tb_stem", "")),
                "top_candidate": str(entry.get("top_candidate", "")),
                "has_top": bool(entry.get("has_top")),
            }
        )
    return targets


def find_vivado_tb_targets(config: Config, project_path: Path) -> list[dict[str, object]]:
    return build_vivado_tb_targets_from_entries(get_tb_entries(config, project_path))


def find_auto_report_tb_targets(config: Config, project_path: Path) -> list[dict[str, object]]:
    return build_auto_report_tb_targets_from_entries(get_tb_entries(config, project_path))


def build_hierarchy_tb_folder_detail_text(
    config: Config,
    project_path: Path,
    folder_target: dict[str, object],
) -> str:
    folder_display = str(folder_target.get("folder_display", "tb"))
    folder_path = (project_path / folder_display).resolve()
    rtl_catalog = build_hierarchy_rtl_module_catalog(project_path)
    top_entries = get_tb_top_entries_for_folder(project_path, folder_path)
    decl_entries = get_tb_folder_sv_declarations(project_path, folder_path)

    lines: list[str] = []
    lines.append("🌳 <b>Hierarchy:</b>")
    lines.append("<pre>")
    lines.append(f" [TB Folder] {html_escape(folder_display)}")
    lines.append("")

    if not top_entries:
        lines.append("No TB top modules/programs found.")
    else:
        for top_idx, top_entry in enumerate(top_entries, start=1):
            top_name = str(top_entry.get("name", ""))
            top_type = str(top_entry.get("type", "module"))
            label = f"program {top_name}" if top_type == "program" else top_name
            rel_path = str(top_entry.get("rel_path", ""))
            lines.append(f"+-- [{top_idx:>2}] {html_escape(label)} ({html_escape(rel_path)})")

            dut_entries = get_direct_dut_entries_for_top(top_entry, rtl_catalog)
            for dut_idx, dut_entry in enumerate(dut_entries):
                conn = "\\--" if dut_idx == (len(dut_entries) - 1) else "+--"
                dut_name = str(dut_entry.get('name', ''))
                dut_rel_path = str(dut_entry.get('rel_path', ''))
                lines.append(f"    {conn} {html_escape(dut_name)} ({html_escape(dut_rel_path)})")

    if decl_entries:
        lines.append("")
        lines.append(" [SV Declarations]")
        for decl in decl_entries:
            lines.append(
                f" +-- {html_escape(str(decl.get('type', '')))} {html_escape(str(decl.get('name', '')))} ({html_escape(str(decl.get('rel_path', '')))})"
            )

    lines.append("</pre>")
    return "\n".join(lines)


def get_hierarchy_tb_folder_label(folder_target: dict[str, object]) -> str:
    folder_idx = int(folder_target.get("folder_idx", 0))
    return str(folder_target.get("folder_display") or folder_target.get("display_name") or f"tb/{folder_idx}")


def build_hierarchy_tb_folder_picker_text(
    project_name: str,
    folder_targets: list[dict[str, object]],
) -> str:
    lines: list[str] = []
    lines.append("🌳 <b>Hierarchy:</b>")
    lines.append(f"📂 <b>Project:</b> <code>{html_escape(project_name)}</code>")
    lines.append("<pre>")

    if not folder_targets:
        lines.append("No TB folders found.")
    else:
        lines.append(" [TB Folders]")
        for idx, folder_target in enumerate(folder_targets):
            folder_idx = int(folder_target.get("folder_idx", idx + 1))
            label = get_hierarchy_tb_folder_label(folder_target)
            conn = "\\--" if idx == (len(folder_targets) - 1) else "+--"
            lines.append(f"{conn} [{folder_idx:>2}] {html_escape(label)}")

    lines.append("</pre>")
    return "\n".join(lines)


def build_hierarchy_tb_folder_picker_markup(
    project_name: str,
    folder_targets: list[dict[str, object]],
) -> dict[str, object]:
    markup = {
        "inline_keyboard": [
            [
                {"text": "⚪ [S1] src only", "callback_data": f"hier_src_{project_name}"},
                {"text": "🟢 [S3] tb only", "callback_data": f"hier_tb_{project_name}"},
            ],
        ]
    }

    folder_buttons: list[dict[str, str]] = []
    for idx, folder_target in enumerate(folder_targets):
        folder_idx = int(folder_target.get("folder_idx", idx + 1))
        folder_buttons.append(
            {
                "text": f"📂 [{folder_idx}] {get_hierarchy_tb_folder_label(folder_target)}",
                "callback_data": f"hier_tbf_{folder_idx}_{project_name}",
            }
        )

    if folder_buttons:
        markup["inline_keyboard"].extend(build_inline_keyboard_rows(folder_buttons, row_size=1)["inline_keyboard"])

    markup["inline_keyboard"].append([{"text": "❌ Quit", "callback_data": "hier_quit"}])
    return markup


def prepare_hierarchy_tb_folder_picker(
    config: Config,
    project_token: str,
) -> tuple[str | None, dict[str, object] | None, str | None]:
    project_path, error = resolve_project(config.project_root, project_token)
    if error:
        return None, None, error
    if project_path is None:
        return None, None, "Failed to resolve project path."

    project_name = project_path.name
    folder_targets = find_vivado_tb_targets(config, project_path)
    text = build_hierarchy_tb_folder_picker_text(project_name, folder_targets)
    markup = build_hierarchy_tb_folder_picker_markup(project_name, folder_targets)
    return text, markup, None


def render_schem_mod_wizard(config: Config, chat_id: int, message_id: int, proj_name: str, available: list[str], selected: set[str], category: str) -> None:
    keyboard = {"inline_keyboard": []}
    row = []

    for mod in available:
        indicator = "✅" if mod in selected else "⬜"
        row.append({"text": f"{indicator} {mod}", "callback_data": f"wiz_smod_t_{mod}"})
        if len(row) == 2:
            keyboard["inline_keyboard"].append(row)
            row = []
    if row:
        keyboard["inline_keyboard"].append(row)

    keyboard["inline_keyboard"].append([
        {"text": "✨ Select ALL", "callback_data": "wiz_smod_all"},
        {"text": "🗑️ Clear", "callback_data": "wiz_smod_clear"}
    ])
    keyboard["inline_keyboard"].append([
        {"text": "🔙 Back", "callback_data": f"wiz_cat_{category}"},
        {"text": "🚀 Confirm", "callback_data": "wiz_smod_confirm"}
    ])
    
    sel_text = ", ".join(sorted(list(selected))) if selected else "None"
    if len(sel_text) > 100: sel_text = sel_text[:97] + "..."
    
    text = f"🧙‍♂️ <b>[Schematic Wizard]</b>\n\n<b>Project:</b> <code>{html_escape(proj_name)}</code>\n\n<b>Selected:</b> <code>{html_escape(sel_text)}</code>\n\n<b>Step 4:</b> Target Modules:"
    edit_message_text(config, chat_id, message_id, text, reply_markup=keyboard)


def build_inline_keyboard_rows(buttons: list[dict[str, str]], row_size: int = 2) -> dict[str, object]:
    keyboard = {"inline_keyboard": []}
    row: list[dict[str, str]] = []
    for button in buttons:
        row.append(button)
        if len(row) == row_size:
            keyboard["inline_keyboard"].append(row)
            row = []
    if row:
        keyboard["inline_keyboard"].append(row)
    return keyboard


def render_vivado_folder_wizard(
    config: Config,
    chat_id: int,
    message_id: int,
    proj_name: str,
    category: str,
    targets: list[dict[str, object]],
) -> None:
    buttons: list[dict[str, str]] = []
    for idx, target in enumerate(targets, start=1):
        folder_idx = int(target.get("folder_idx", idx))
        display_name = str(target.get("display_name") or target.get("folder_display") or f"folder_{idx}")
        buttons.append(
            {
                "text": f"📂 [{folder_idx}] {display_name}",
                "callback_data": f"wiz_vsimf_{idx}",
            }
        )

    keyboard = build_inline_keyboard_rows(buttons)
    keyboard["inline_keyboard"].append([{"text": "🔙 Back", "callback_data": f"wiz_cat_{category}"}])

    text = (
        f"🧙‍♂️ <b>[Simulation Wizard]</b>\n\n"
        f"<b>Project:</b> <code>{html_escape(proj_name)}</code>\n\n"
        f"<b>Step 4:</b> Select Testbench Folder:"
    )
    edit_message_text(config, chat_id, message_id, text, reply_markup=keyboard)


def render_vivado_tb_wizard(
    config: Config,
    chat_id: int,
    message_id: int,
    proj_name: str,
    folder_state_idx: int,
    folder_target: dict[str, object],
) -> None:
    buttons: list[dict[str, str]] = []
    tb_targets = folder_target.get("tb_targets", [])
    if not isinstance(tb_targets, list):
        tb_targets = []

    for tb_pos, tb_target in enumerate(tb_targets, start=1):
        tb_idx = int(tb_target.get("tb_idx", tb_pos))
        title = str(tb_target.get("top_candidate") or tb_target.get("tb_stem") or tb_target.get("tb_name") or f"tb_{tb_idx}")
        buttons.append(
            {
                "text": f"📜 [{tb_idx}] {title}",
                "callback_data": f"wiz_vsimt_{folder_state_idx}_{tb_pos}",
            }
        )

    keyboard = build_inline_keyboard_rows(buttons)
    keyboard["inline_keyboard"].append([{"text": "🔙 Back", "callback_data": "wiz_act_5"}])

    folder_display = str(folder_target.get("folder_display", "tb"))
    text = (
        f"🧙‍♂️ <b>[Simulation Wizard]</b>\n\n"
        f"<b>Project:</b> <code>{html_escape(proj_name)}</code>\n"
        f"<b>Folder:</b> <code>{html_escape(folder_display)}</code>\n\n"
        f"<b>Step 5:</b> Select Testbench Index:"
    )
    edit_message_text(config, chat_id, message_id, text, reply_markup=keyboard)


def render_auto_report_tb_wizard(
    config: Config,
    chat_id: int,
    message_id: int,
    proj_name: str,
    category: str,
    targets: list[dict[str, object]],
) -> None:
    buttons: list[dict[str, str]] = []
    for idx, target in enumerate(targets, start=1):
        tb_idx = int(target.get("tb_idx", idx))
        title = str(target.get("top_candidate") or target.get("tb_stem") or target.get("tb_name") or f"tb_{tb_idx}")
        buttons.append(
            {
                "text": f"📜 [{tb_idx}] {title}",
                "callback_data": f"wiz_sar_{idx}",
            }
        )

    keyboard = build_inline_keyboard_rows(buttons)
    keyboard["inline_keyboard"].append([{"text": "🔙 Back", "callback_data": f"wiz_cat_{category}"}])

    text = (
        f"🧙‍♂️ <b>[Simulation Wizard]</b>\n\n"
        f"<b>Project:</b> <code>{html_escape(proj_name)}</code>\n\n"
        f"<b>Step 4:</b> Select Auto Report Testbench:"
    )
    edit_message_text(config, chat_id, message_id, text, reply_markup=keyboard)


def render_hierarchy_scope_wizard(
    config: Config,
    chat_id: int,
    message_id: int,
    proj_name: str,
    category: str,
) -> None:
    keyboard = {
        "inline_keyboard": [
            [
                {"text": "1. src only", "callback_data": "wiz_hier_src"},
                {"text": "3. tb only", "callback_data": "wiz_hier_tb"},
            ],
            [
                {"text": "🔙 Back", "callback_data": f"wiz_cat_{category}"},
            ],
        ]
    }
    text = (
        f"🧙‍♂️ <b>[Hierarchy Wizard]</b>\n\n"
        f"<b>Project:</b> <code>{html_escape(proj_name)}</code>\n\n"
        f"<b>Step 4:</b> Select hierarchy scope:"
    )
    edit_message_text(config, chat_id, message_id, text, reply_markup=keyboard)


def execute_wizard_command(
    config: Config,
    chat_id: int,
    message_id: int,
    query_id: str,
    user_id: int,
    user_name: str,
    synthetic_cmd: str,
    status_text: str,
) -> None:
    STATE.clear_user_state(user_id)
    edit_message_text(
        config,
        chat_id,
        message_id,
        f"🪄 <b>Wizard Complete:</b> Executing:\n<code>{html_escape(synthetic_cmd)}</code>",
    )
    answer_callback_query(config, query_id, text=status_text)
    process_message(
        config,
        {
            "message_id": message_id,
            "from": {"id": user_id, "username": user_name},
            "chat": {"id": chat_id},
            "text": synthetic_cmd,
        },
    )

def handle_project_wizard(config: Config, chat_id: int, user_id: int, message_id: int | None = None) -> None:
    projects = discover_projects(config.project_root)
    if not projects:
        send_text(config, chat_id, f"No valid projects under: {config.project_root}")
        return
        
    STATE.update_user_state(user_id, {"wizard": "project", "step": "project"})
    
    keyboard = {"inline_keyboard": []}
    row: list[dict[str, str]] = []
    for proj in projects:
        row.append({"text": f"📁 {proj.name}", "callback_data": f"wiz_proj_{proj.name}"})
        if len(row) == 2:
            keyboard["inline_keyboard"].append(row)
            row = []
    if row:
        keyboard["inline_keyboard"].append(row)
        
    text = "🧙‍♂️ <b>[Interactive Wizard]</b>\n\n<b>Step 1/3:</b> Select a Project:"
    if message_id:
        edit_message_text(config, chat_id, message_id, text, reply_markup=keyboard)
    else:
        send_text(config, chat_id, text, reply_markup=keyboard)

def process_callback_query(config: Config, callback: dict) -> None:
    query_id = callback.get("id", "")
    data = callback.get("data", "")
    message = callback.get("message", {})
    chat_id = int(message.get("chat", {}).get("id", 0))
    message_id = int(message.get("message_id", 0))
    
    user = callback.get("from") or {}
    user_id = int(user.get("id", 0))
    user_name = normalize_username(str(user.get("username", "")) or "")

    allowed = user_id in config.allowed_user_ids or (user_name and user_name in config.allowed_usernames)
    if not allowed:
        answer_callback_query(config, query_id, text="Access denied.")
        return

    if data.startswith("simgui_"):
        parts = data.split("_", 2)
        if len(parts) != 3:
            answer_callback_query(config, query_id, text="Invalid selection.")
            return
        action_code = parts[1]
        token = parts[2]
        decision = "close" if action_code == "c" else "keep" if action_code == "k" else ""
        if not decision:
            answer_callback_query(config, query_id, text="Invalid selection.")
            return
        resolved = STATE.resolve_sim_vivado_prompt(token, decision)
        if not resolved:
            answer_callback_query(config, query_id, text="Selection expired.")
            return
        answer_callback_query(config, query_id, text=f"Selected: {decision}")
        return

    if data.startswith("help_"):
        cat = data.split("_")[1]
        help_text, help_kb = build_help(category=cat)
        edit_message_text(config, chat_id, message_id, help_text, reply_markup=help_kb)
        answer_callback_query(config, query_id)
        return

    if data.startswith("hier_"):
        if data == "hier_quit":
            edit_message_text(config, chat_id, message_id, "<i>Hierarchy viewer closed.</i>")
            answer_callback_query(config, query_id)
            return

        if data.startswith("hier_tb_"):
            proj = data[len("hier_tb_"):]
            text, markup, error = prepare_hierarchy_tb_folder_picker(config, proj)
            if error:
                answer_callback_query(config, query_id, text=error)
                return
            if text is None or markup is None:
                answer_callback_query(config, query_id, text="Failed to prepare TB folder list.")
                return
            edit_message_text(config, chat_id, message_id, text, reply_markup=markup)
            answer_callback_query(config, query_id, text="Choose TB folder.")
            return

        if data.startswith("hier_tbf_"):
            payload = data[len("hier_tbf_"):]
            if "_" not in payload:
                answer_callback_query(config, query_id, text="Invalid TB folder selection.")
                return
            folder_idx_raw, proj = payload.split("_", 1)
            if not folder_idx_raw.isdigit():
                answer_callback_query(config, query_id, text="Invalid TB folder selection.")
                return

            project_path, error = resolve_project(config.project_root, proj)
            if error or project_path is None:
                answer_callback_query(config, query_id, text="Project not found.")
                return

            tb_folder_targets = find_vivado_tb_targets(config, project_path)
            folder_target = next(
                (target for target in tb_folder_targets if int(target.get("folder_idx", 0)) == int(folder_idx_raw)),
                None,
            )
            if folder_target is None:
                answer_callback_query(config, query_id, text="TB folder no longer exists.")
                return

            detail_text = build_hierarchy_tb_folder_detail_text(config, project_path, folder_target)
            folder_idx = int(folder_target.get("folder_idx", 0))
            detail_markup = {
                "inline_keyboard": [
                    [
                        {"text": "⚪ [S1] src only", "callback_data": f"hier_src_{proj}"},
                        {"text": "🟢 [S3] tb only", "callback_data": f"hier_tb_{proj}"},
                    ],
                    [
                        {"text": "🔙 Folder List", "callback_data": f"hier_tb_{proj}"},
                        {"text": "🔄 Refresh", "callback_data": f"hier_tbf_{folder_idx}_{proj}"},
                    ],
                    [
                        {"text": "❌ Quit", "callback_data": "hier_quit"},
                    ],
                ]
            }
            edit_message_text(config, chat_id, message_id, detail_text, reply_markup=detail_markup)
            answer_callback_query(config, query_id, text="TB folder opened.")
            return

        parts = data.split("_", 2)
        if len(parts) >= 3:
            action = parts[1]
            if action == "ref":
                scope_code = parts[2].split("_")[0]
                proj = data[len(f"hier_ref_{scope_code}_"):]
                scope_arg = hierarchy_scope_from_callback(scope_code)
            else:
                proj = data[len(f"hier_{action}_"):]
                scope_arg = hierarchy_scope_from_callback(action)

            if not scope_arg:
                answer_callback_query(config, query_id, text="Unknown hierarchy scope.")
                return

            synthetic_cmd = f"/hierarchy {proj} {scope_arg}"

            edit_message_text(config, chat_id, message_id, f"🪄 <b>Hierarchy Viewer:</b> Executing:\n<code>{html_escape(synthetic_cmd)}</code>")
            answer_callback_query(config, query_id, text="Updating hierarchy...")
            process_message(config, {"message_id": message_id, "from": {"id": user_id, "username": user_name}, "chat": {"id": chat_id}, "text": synthetic_cmd})
        return

    if not data.startswith("wiz_"):
        answer_callback_query(config, query_id)
        return

    state = STATE.get_user_state(user_id)
    if state.get("wizard") != "project":
        answer_callback_query(config, query_id, text="Wizard expired. Start again with /run")
        edit_message_text(config, chat_id, message_id, "<i>Wizard expired.</i>")
        return

    if data == "wiz_start":
        handle_project_wizard(config, chat_id, user_id, message_id=message_id)
        answer_callback_query(config, query_id)
        return

    if data.startswith("wiz_proj_"):
        proj_name = data[len("wiz_proj_"):]
        STATE.update_user_state(user_id, {"step": "category", "project": proj_name})

        keyboard = {
            "inline_keyboard": [
                [
                    {"text": "🛠 Build & FPGA", "callback_data": "wiz_cat_build"},
                    {"text": "🏃 Sim & Test", "callback_data": "wiz_cat_sim"},
                ],
                [
                    {"text": "🖼 Visuals", "callback_data": "wiz_cat_vis"},
                    {"text": "📊 Reports", "callback_data": "wiz_cat_rep"},
                ],
                [{"text": "🔙 Back", "callback_data": "wiz_start"}],
            ]
        }
        text = (
            f"🧙‍♂️ <b>[Interactive Wizard]</b>\n\n"
            f"<b>Project:</b> <code>{html_escape(proj_name)}</code>\n\n"
            f"<b>Step 2/3:</b> Select Category:"
        )
        edit_message_text(config, chat_id, message_id, text, reply_markup=keyboard)
        answer_callback_query(config, query_id)
        return

    if data.startswith("wiz_cat_"):
        category = data[len("wiz_cat_"):]
        proj_name = str(state.get("project", ""))
        STATE.update_user_state(user_id, {"step": "action", "category": category})

        keyboard = {"inline_keyboard": []}
        if category == "build":
            keyboard["inline_keyboard"] = [
                [{"text": "13. Run Build", "callback_data": "wiz_act_13"}, {"text": "16. Program FPGA", "callback_data": "wiz_act_16"}],
                [{"text": "17. Build + Program", "callback_data": "wiz_act_17"}],
                [{"text": "12. Launch GUI", "callback_data": "wiz_act_12"}, {"text": "14. Finalize BD", "callback_data": "wiz_act_14"}],
                [{"text": "15. Retarget IP", "callback_data": "wiz_act_15"}],
            ]
        elif category == "sim":
            keyboard["inline_keyboard"] = [
                [{"text": "5. Vivado Sim", "callback_data": "wiz_act_5"}, {"text": "6. Auto Sim+Rep", "callback_data": "wiz_act_6"}],
                [{"text": "7. Icarus Sim", "callback_data": "wiz_act_7"}, {"text": "19. Create TB Scaffold", "callback_data": "wiz_act_19"}],
            ]
        elif category == "vis":
            keyboard["inline_keyboard"] = [
                [{"text": "1. Schematic", "callback_data": "wiz_act_1"}, {"text": "2. Hierarchy", "callback_data": "wiz_act_2"}],
                [{"text": "3. FSM", "callback_data": "wiz_act_3"}, {"text": "8. VCD SVG", "callback_data": "wiz_act_8"}],
                [{"text": "9. VCD WaveDrom", "callback_data": "wiz_act_9"}],
            ]
        elif category == "rep":
            keyboard["inline_keyboard"] = [
                [{"text": "4. Gen Presentation", "callback_data": "wiz_act_4"}, {"text": "18. Open Presentation", "callback_data": "wiz_act_18"}],
                [{"text": "10. Report Generator", "callback_data": "wiz_act_10"}, {"text": "11. Legacy Docs", "callback_data": "wiz_act_11"}],
            ]

        keyboard["inline_keyboard"].append([{"text": "🔙 Back", "callback_data": f"wiz_proj_{proj_name}"}])
        text = (
            f"🧙‍♂️ <b>[Interactive Wizard]</b>\n\n"
            f"<b>Project:</b> <code>{html_escape(proj_name)}</code>\n\n"
            f"<b>Step 3/3:</b> Select Action:"
        )
        edit_message_text(config, chat_id, message_id, text, reply_markup=keyboard)
        answer_callback_query(config, query_id)
        return

    if data.startswith("wiz_act_"):
        act_num = data[len("wiz_act_"):]
        proj_name = str(state.get("project", ""))
        category = str(state.get("category", ""))

        if act_num == "5":
            proj_path, _ = resolve_project(config.project_root, proj_name)
            targets = find_vivado_tb_targets(config, proj_path) if proj_path else []
            if not targets:
                answer_callback_query(config, query_id, text="No testbench folders found.", show_alert=True)
                return

            STATE.update_user_state(user_id, {"step": "vivado_folder", "action": act_num, "vivado_targets": targets})
            render_vivado_folder_wizard(config, chat_id, message_id, proj_name, category, targets)
            answer_callback_query(config, query_id)
            return

        if act_num == "6":
            proj_path, _ = resolve_project(config.project_root, proj_name)
            targets = find_auto_report_tb_targets(config, proj_path) if proj_path else []
            if not targets:
                answer_callback_query(config, query_id, text="No auto-report targets found.", show_alert=True)
                return

            STATE.update_user_state(user_id, {"step": "auto_report_tb", "action": act_num, "auto_report_targets": targets})
            render_auto_report_tb_wizard(config, chat_id, message_id, proj_name, category, targets)
            answer_callback_query(config, query_id)
            return

        if act_num == "7":
            STATE.update_user_state(user_id, {"step": "tb_flag_7", "action": act_num})
            keyboard = {
                "inline_keyboard": [
                    [{"text": "🏃 All TBs", "callback_data": "wiz_flag_7_all"}],
                    [{"text": "🔙 Back", "callback_data": f"wiz_cat_{category}"}],
                ]
            }
            text = (
                f"🧙‍♂️ <b>[Simulation Wizard]</b>\n\n"
                f"<b>Project:</b> <code>{html_escape(proj_name)}</code>\n\n"
                f"📝 <i>Wizard currently supports --all for Icarus mode. Enter manually if a specific TB is needed.</i>\n\n"
                f"<b>Step 4:</b> Target:"
            )
            edit_message_text(config, chat_id, message_id, text, reply_markup=keyboard)
            answer_callback_query(config, query_id)
            return

        if act_num == "19":
            STATE.update_user_state(user_id, {"step": "tb_flag_19", "action": act_num})
            keyboard = {
                "inline_keyboard": [
                    [{"text": "🧱 Generate Scaffold ALL", "callback_data": "wiz_flag_19_all"}],
                    [{"text": "🔙 Back", "callback_data": f"wiz_cat_{category}"}],
                ]
            }
            text = (
                f"🧙‍♂️ <b>[TB Scaffold Wizard]</b>\n\n"
                f"<b>Project:</b> <code>{html_escape(proj_name)}</code>\n\n"
                f"📝 <i>Wizard currently supports --all for scaffold generation. Enter manually if a specific DUT is needed.</i>\n\n"
                f"<b>Step 4:</b> Target:"
            )
            edit_message_text(config, chat_id, message_id, text, reply_markup=keyboard)
            answer_callback_query(config, query_id)
            return

        if act_num == "1":
            proj_path, _ = resolve_project(config.project_root, proj_name)
            modules = find_schematic_modules(config, proj_path) if proj_path else []
            STATE.update_user_state(user_id, {"step": "schem_mod", "action": act_num, "available": modules, "selected": set()})
            render_schem_mod_wizard(config, chat_id, message_id, proj_name, modules, set(), category)
            answer_callback_query(config, query_id)
            return

        if act_num == "2":
            STATE.update_user_state(user_id, {"step": "hierarchy_scope", "action": act_num})
            render_hierarchy_scope_wizard(config, chat_id, message_id, proj_name, category)
            answer_callback_query(config, query_id)
            return

        synthetic_cmd = ""
        if act_num == "13":
            synthetic_cmd = f"/build {proj_name}"
        elif act_num == "16":
            synthetic_cmd = f"/program {proj_name}"
        elif act_num == "17":
            synthetic_cmd = f"/build_program {proj_name}"
        elif act_num == "12":
            synthetic_cmd = f"/vivado_gui {proj_name}"
        elif act_num == "14":
            synthetic_cmd = f"/finalize_bd {proj_name}"
        elif act_num == "15":
            synthetic_cmd = f"/retarget_ip {proj_name}"
        elif act_num == "3":
            synthetic_cmd = f"/fsm {proj_name} ALL"
        elif act_num == "8":
            synthetic_cmd = f"/vcd_svg {proj_name}"
        elif act_num == "9":
            synthetic_cmd = f"/vcd_wavedrom {proj_name} --no-html"
        elif act_num == "4":
            synthetic_cmd = f"/presentation {proj_name}"
        elif act_num == "18":
            synthetic_cmd = f"/open_presentation {proj_name}"
        elif act_num == "10":
            synthetic_cmd = f"/report_html {proj_name}"
        elif act_num == "11":
            synthetic_cmd = f"/report_docs {proj_name}"

        if synthetic_cmd:
            execute_wizard_command(
                config,
                chat_id,
                message_id,
                query_id,
                user_id,
                user_name,
                synthetic_cmd,
                "Executing action...",
            )
        return

    if data.startswith("wiz_hier_"):
        scope_code = data[len("wiz_hier_"):]
        proj_name = str(state.get("project", ""))
        scope_arg = hierarchy_scope_from_callback(scope_code)
        if not scope_arg:
            answer_callback_query(config, query_id, text="Unknown hierarchy scope.")
            return

        if scope_arg == "tb_only":
            STATE.clear_user_state(user_id)
            text, markup, error = prepare_hierarchy_tb_folder_picker(config, proj_name)
            if error:
                answer_callback_query(config, query_id, text=error)
                return
            if text is None or markup is None:
                answer_callback_query(config, query_id, text="Failed to prepare TB folder list.")
                return
            edit_message_text(config, chat_id, message_id, text, reply_markup=markup)
            answer_callback_query(config, query_id, text="Choose TB folder.")
            return

        synthetic_cmd = f"/hierarchy {proj_name} {scope_arg}"
        execute_wizard_command(
            config,
            chat_id,
            message_id,
            query_id,
            user_id,
            user_name,
            synthetic_cmd,
            "Executing hierarchy...",
        )
        return

    if data.startswith("wiz_flag_"):
        flag_info = data[len("wiz_flag_"):]
        proj_name = str(state.get("project", ""))
        if flag_info == "7_all":
            synthetic_cmd = f"/sim_iverilog {proj_name} --all"
        elif flag_info == "19_all":
            synthetic_cmd = f"/tb_scaffold {proj_name} --all"
        else:
            answer_callback_query(config, query_id, text="Unknown wizard flag.")
            return

        execute_wizard_command(
            config,
            chat_id,
            message_id,
            query_id,
            user_id,
            user_name,
            synthetic_cmd,
            "Executing action...",
        )
        return

    if data.startswith("wiz_smod_"):
        action_data = data[len("wiz_smod_"):]
        proj_name = str(state.get("project", ""))
        category = str(state.get("category", ""))
        available = state.get("available", [])
        selected = state.setdefault("selected", set())
        if not isinstance(selected, set):
            selected = set(selected)
            state["selected"] = selected

        if action_data == "noop":
            answer_callback_query(config, query_id)
            return

        if action_data == "all":
            selected.clear()
            for mod in available:
                selected.add(str(mod))
            render_schem_mod_wizard(config, chat_id, message_id, proj_name, available, selected, category)
            answer_callback_query(config, query_id, text=f"Selected {len(selected)} modules")
            return

        if action_data == "clear":
            selected.clear()
            render_schem_mod_wizard(config, chat_id, message_id, proj_name, available, selected, category)
            answer_callback_query(config, query_id)
            return

        if action_data == "confirm":
            if not selected:
                answer_callback_query(config, query_id, text="Please select at least one module!", show_alert=True)
                return
            available_list = [str(mod) for mod in available]
            if available_list:
                selected_in_order = [mod for mod in available_list if mod in selected]
                if len(selected_in_order) == len(available_list):
                    module_arg = "ALL"
                else:
                    selected_indices = [str(idx + 1) for idx, mod in enumerate(available_list) if mod in selected]
                    if not selected_indices:
                        answer_callback_query(config, query_id, text="Please select at least one module!", show_alert=True)
                        return
                    module_arg = ",".join(selected_indices)
                synthetic_cmd = f"/schematic {proj_name} {module_arg}"
            else:
                synthetic_cmd = f"/schematic {proj_name} {','.join(sorted(selected))}"

            execute_wizard_command(
                config,
                chat_id,
                message_id,
                query_id,
                user_id,
                user_name,
                synthetic_cmd,
                "Executing action...",
            )
            return

        if action_data.startswith("t_"):
            mod = action_data[2:]
            if mod in selected:
                selected.remove(mod)
            else:
                selected.add(mod)
            render_schem_mod_wizard(config, chat_id, message_id, proj_name, available, selected, category)
            answer_callback_query(config, query_id)
            return

    if data.startswith("wiz_vsimf_"):
        match = re.fullmatch(r"wiz_vsimf_(\d+)", data)
        if not match:
            answer_callback_query(config, query_id, text="Invalid folder selection.")
            return

        folder_state_idx = int(match.group(1))
        proj_name = str(state.get("project", ""))
        targets = state.get("vivado_targets", [])
        if not isinstance(targets, list) or folder_state_idx < 1 or folder_state_idx > len(targets):
            answer_callback_query(config, query_id, text="Folder selection expired.", show_alert=True)
            return

        folder_target = targets[folder_state_idx - 1]
        folder_idx = int(folder_target.get("folder_idx", 0))
        STATE.update_user_state(user_id, {"step": "vivado_tb", "folder_state_idx": folder_state_idx, "folder_idx": folder_idx})
        render_vivado_tb_wizard(config, chat_id, message_id, proj_name, folder_state_idx, folder_target)
        answer_callback_query(config, query_id)
        return

    if data.startswith("wiz_vsimt_"):
        match = re.fullmatch(r"wiz_vsimt_(\d+)_(\d+)", data)
        if not match:
            answer_callback_query(config, query_id, text="Invalid testbench selection.")
            return

        folder_state_idx = int(match.group(1))
        tb_state_idx = int(match.group(2))
        proj_name = str(state.get("project", ""))
        targets = state.get("vivado_targets", [])
        if not isinstance(targets, list) or folder_state_idx < 1 or folder_state_idx > len(targets):
            answer_callback_query(config, query_id, text="Target expired. Re-open action 5.", show_alert=True)
            return

        folder_target = targets[folder_state_idx - 1]
        tb_targets = folder_target.get("tb_targets", [])
        if not isinstance(tb_targets, list) or tb_state_idx < 1 or tb_state_idx > len(tb_targets):
            answer_callback_query(config, query_id, text="TB selection expired.", show_alert=True)
            return

        tb_target = tb_targets[tb_state_idx - 1]
        folder_idx = str(folder_target.get("folder_idx", ""))
        tb_idx = str(tb_target.get("tb_idx", ""))
        if not (re.fullmatch(r"\d+", folder_idx) and re.fullmatch(r"\d+", tb_idx)):
            answer_callback_query(config, query_id, text="Invalid target mapping.", show_alert=True)
            return

        STATE.update_user_state(
            user_id,
            {
                "step": "gui",
                "folder_state_idx": folder_state_idx,
                "folder_idx": int(folder_idx),
                "tb": int(tb_idx),
            },
        )
        keyboard = {
            "inline_keyboard": [
                [
                    {"text": "🖥️ GUI Open", "callback_data": "wiz_gui_keep"},
                    {"text": "🚫 GUI Close (Fast)", "callback_data": "wiz_gui_close"},
                ],
                [{"text": "🔙 Back", "callback_data": f"wiz_vsimf_{folder_state_idx}"}],
            ]
        }
        text = (
            f"🧙‍♂️ <b>[Simulation Wizard]</b>\n\n"
            f"<b>Project:</b> <code>{html_escape(proj_name)}</code>\n"
            f"<b>Folder:</b> <code>{html_escape(folder_idx)}</code>\n"
            f"<b>TB:</b> <code>{html_escape(tb_idx)}</code>\n\n"
            f"<b>Step 6:</b> Vivado GUI Mode:"
        )
        edit_message_text(config, chat_id, message_id, text, reply_markup=keyboard)
        answer_callback_query(config, query_id)
        return

    if data.startswith("wiz_sar_"):
        match = re.fullmatch(r"wiz_sar_(\d+)", data)
        if not match:
            answer_callback_query(config, query_id, text="Invalid auto-report selection.")
            return

        target_state_idx = int(match.group(1))
        proj_name = str(state.get("project", ""))
        targets = state.get("auto_report_targets", [])
        if not isinstance(targets, list) or target_state_idx < 1 or target_state_idx > len(targets):
            answer_callback_query(config, query_id, text="Auto-report target expired.", show_alert=True)
            return

        target = targets[target_state_idx - 1]
        tb_idx = str(target.get("tb_idx", ""))
        if not re.fullmatch(r"\d+", tb_idx):
            answer_callback_query(config, query_id, text="Invalid auto-report target.", show_alert=True)
            return

        execute_wizard_command(
            config,
            chat_id,
            message_id,
            query_id,
            user_id,
            user_name,
            f"/sim_auto_report {proj_name} {tb_idx}",
            "Executing action...",
        )
        return

    if data.startswith("wiz_gui_"):
        gui_mode = data[len("wiz_gui_"):]
        gui_flag = "--keep-gui" if gui_mode == "keep" else "--close-gui"
        proj_name = str(state.get("project", ""))
        folder_idx = str(state.get("folder_idx", ""))
        tb_idx = str(state.get("tb", ""))
        if not (re.fullmatch(r"\d+", folder_idx) and re.fullmatch(r"\d+", tb_idx)):
            answer_callback_query(config, query_id, text="Simulation target expired.", show_alert=True)
            return

        execute_wizard_command(
            config,
            chat_id,
            message_id,
            query_id,
            user_id,
            user_name,
            f"/sim_vivado {proj_name} {folder_idx} {tb_idx} {gui_flag}",
            "Executing simulation...",
        )
        return

    answer_callback_query(config, query_id)

def run_loop(config: Config) -> None:
    offset: int | None = None

    # Register Bot Commands Menu natively
    try:
        telegram_api(config, "setMyCommands", {
            "commands": [
                {"command": "start", "description": "Show interactive main menu"},
                {"command": "status", "description": "Check currently running job"},
                {"command": "last", "description": "Check last job result"},
                {"command": "projects", "description": "List available projects"},
                {"command": "help", "description": "Show paginated help menu"}
            ]
        })
    except Exception as exc:
        print(f"[WARN] Failed to set bot commands: {exc}")

    while True:
        try:
            if offset is None:
                offset = skip_backlog_if_needed(config)
            updates = get_updates(config, offset=offset, timeout_sec=config.poll_timeout_sec)
            for update in updates:
                update_id = int(update.get("update_id", 0))
                offset = update_id + 1

                if "callback_query" in update:
                    process_callback_query(config, update["callback_query"])
                    continue

                message = update.get("message")
                if not isinstance(message, dict):
                    continue
                process_message(config, message)
        except KeyboardInterrupt:
            print("Stopped by user.")
            return
        except Exception as exc:
            if is_conflict_error(exc):
                print("[WARN] Telegram 409 conflict. Another polling instance may be running, or webhook mode is active.")
                print("[WARN] Ensure only one bot process is running for this token.")
                offset = None
                time.sleep(5)
                continue
            print(f"[WARN] polling loop error: {exc}")
            time.sleep(2)


def main() -> None:
    try:
        acquire_instance_lock()
    except Exception as exc:
        print(f"[ERROR] {exc}")
        raise SystemExit(1)

    config = load_config()
    print("Telegram FPGA bot started.")
    print(f"Automation repo root: {config.automation_repo_root}")
    print(f"Automation templates root: {config.automation_templates_root}")
    print(f"MAIN.bat: {config.main_bat_path}")
    print(f"Mapped MAIN commands: {len(config.menu_registry)}")
    print(f"Project root: {config.project_root}")
    print(f"Allowed user ids: {sorted(config.allowed_user_ids)}")
    print(f"Allowed usernames: {sorted(config.allowed_usernames)}")
    print(f"Diagram attachments: enabled={config.send_diagrams}, max_files={config.max_diagram_files}")
    print(
        "sim_vivado replay logs: "
        f"lines={config.sim_vivado_log_lines}, send_file={config.sim_vivado_send_log_file}"
    )
    print(
        "sim_vivado auto-complete: "
        f"enabled={config.sim_vivado_auto_complete_on_replay}, "
        f"check_sec={config.sim_vivado_replay_check_sec}"
    )

    try:
        ensure_polling_ready(config)
        if config.auto_delete_webhook_on_start:
            print("[INFO] Webhook cleared. Long polling mode enabled.")
    except Exception as exc:
        print(f"[WARN] Failed to clear webhook on start: {exc}")

    run_loop(config)


if __name__ == "__main__":
    main()
