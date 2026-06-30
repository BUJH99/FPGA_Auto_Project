#!/usr/bin/env node
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const readline = require("readline");
const YAML = require("yaml");

const SETTINGS_FILE_NAME = "fpga_claw.local.yml";

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function deepMerge(base, override) {
  const output = clone(base);
  if (!isPlainObject(override)) return output;
  for (const [key, value] of Object.entries(override)) {
    if (isPlainObject(value) && isPlainObject(output[key])) {
      output[key] = deepMerge(output[key], value);
    } else if (value !== undefined) {
      output[key] = clone(value);
    }
  }
  return output;
}

function defaultSettings() {
  return {
    version: 1,
    paths: {
      project_root: "../Project",
      log_dir: "log",
      output_dir: "output",
      template_dir: "templates",
      vivado_executable: "",
      editor: "code",
    },
    board: {
      default_board: "Ultra96v2",
      profile_path: "",
      part: "xczu3eg-sbva484-1-i",
      board_part: "Avnet-tria:Ultra96v2:part0:1.3",
      xdc: "",
      clock_mhz: 100,
      programmer: "auto",
      target_index: "",
      device_index: "",
    },
    telegram: {
      enabled: false,
      token_source: "env:TELEGRAM_BOT_TOKEN",
      allowed_user_ids: [],
      notify_events: ["success", "fail", "program_done"],
      max_log_lines: 80,
      allowed_commands: ["status", "run", "report"],
    },
    user: {
      remember_last_project: true,
      last_project: "",
      default_project: "",
      language: "ko",
      compact_menu: false,
      confirm_dangerous_actions: true,
    },
    archive: {
      bitstream_dir: "archive/bitstreams",
      backup_settings: true,
      keep_logs: 10,
      clean_preserve: ["output/vivado/**", "output/vitis/**"],
    },
  };
}

function parseArgs(argv) {
  const opts = {
    repoRoot: "",
    tui: false,
    emitBat: false,
    selftest: false,
    init: false,
    setPath: "",
    setValue: "",
    noBackup: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--repo-root") opts.repoRoot = argv[++i] || "";
    else if (arg.startsWith("--repo-root=")) opts.repoRoot = arg.slice("--repo-root=".length);
    else if (arg === "--tui") opts.tui = true;
    else if (arg === "--emit-bat") opts.emitBat = true;
    else if (arg === "--selftest") opts.selftest = true;
    else if (arg === "--init") opts.init = true;
    else if (arg === "--set") {
      opts.setPath = argv[++i] || "";
      opts.setValue = argv[++i] || "";
    } else if (arg.startsWith("--set=")) {
      const pair = arg.slice("--set=".length);
      const idx = pair.indexOf("=");
      opts.setPath = idx >= 0 ? pair.slice(0, idx) : pair;
      opts.setValue = idx >= 0 ? pair.slice(idx + 1) : "";
    } else if (arg === "--no-backup") {
      opts.noBackup = true;
    }
  }
  return opts;
}

function inferRepoRoot(opts) {
  if (opts.repoRoot) return path.resolve(opts.repoRoot);
  return path.resolve(__dirname, "../../../../..");
}

function settingsPath(repoRoot) {
  return path.join(repoRoot, SETTINGS_FILE_NAME);
}

function readYamlFile(filePath) {
  if (!filePath || !fs.existsSync(filePath)) return {};
  const text = fs.readFileSync(filePath, "utf8");
  if (!text.trim()) return {};
  const parsed = YAML.parse(text);
  return isPlainObject(parsed) ? parsed : {};
}

function isAbsoluteLike(value) {
  return path.isAbsolute(value) || /^[A-Za-z]:[\\/]/.test(value);
}

function normalizeSlashes(value) {
  return String(value || "").replace(/\\/g, "/");
}

function resolveSettingPath(repoRoot, rawValue, fallback = "") {
  const value = String(rawValue || fallback || "").trim();
  if (!value) return "";
  if (isAbsoluteLike(value)) return path.normalize(value);
  return path.resolve(repoRoot, value);
}

function resolveProjectPath(projectRoot, rawValue, fallback = "") {
  const value = String(rawValue || fallback || "").trim();
  if (!value) return "";
  if (isAbsoluteLike(value)) return path.normalize(value);
  return path.resolve(projectRoot, value);
}

function profileBoardWithResolvedPaths(profilePath, profileBoard) {
  const board = clone(profileBoard || {});
  const profileDir = path.dirname(profilePath);
  for (const key of ["xdc"]) {
    if (board[key] && !isAbsoluteLike(String(board[key]))) {
      board[key] = path.resolve(profileDir, String(board[key]));
    }
  }
  return board;
}

function explicitLocalBoardOverrides(localBoard) {
  if (!isPlainObject(localBoard)) return {};
  const defaults = defaultSettings().board;
  const out = {};
  for (const [key, value] of Object.entries(localBoard)) {
    if (key === "profile_path") continue;
    if (JSON.stringify(value) === JSON.stringify(defaults[key])) continue;
    out[key] = value;
  }
  return out;
}

function loadSettings(repoRoot) {
  const defaults = defaultSettings();
  const filePath = settingsPath(repoRoot);
  const local = readYamlFile(filePath);
  let settings = deepMerge(defaults, local);

  const profileRaw = settings.board && settings.board.profile_path ? String(settings.board.profile_path).trim() : "";
  if (profileRaw) {
    const profilePath = resolveSettingPath(repoRoot, profileRaw);
    if (fs.existsSync(profilePath)) {
      const profile = readYamlFile(profilePath);
      const profileBoard = isPlainObject(profile.board) ? profile.board : profile;
      settings.board = deepMerge(settings.board, profileBoardWithResolvedPaths(profilePath, profileBoard));
      settings.board = deepMerge(settings.board, explicitLocalBoardOverrides(local.board));
      settings.board.profile_path = profileRaw;
    }
  }
  return settings;
}

function settingsToYaml(settings) {
  return YAML.stringify(settings, { lineWidth: 0 });
}

function timestamp() {
  const d = new Date();
  const pad = (n) => String(n).padStart(2, "0");
  return [
    d.getFullYear(),
    pad(d.getMonth() + 1),
    pad(d.getDate()),
    "-",
    pad(d.getHours()),
    pad(d.getMinutes()),
    pad(d.getSeconds()),
  ].join("");
}

function saveSettings(repoRoot, settings, { backup = true } = {}) {
  const filePath = settingsPath(repoRoot);
  const shouldBackup = Boolean(settings.archive && settings.archive.backup_settings);
  if (backup && shouldBackup && fs.existsSync(filePath)) {
    const backupDir = path.join(repoRoot, ".fpga_claw", "settings_backups");
    fs.mkdirSync(backupDir, { recursive: true });
    fs.copyFileSync(filePath, path.join(backupDir, `${SETTINGS_FILE_NAME}.${timestamp()}.bak`));
  }
  fs.writeFileSync(filePath, settingsToYaml(settings), "utf8");
  return filePath;
}

function getByPath(root, dottedPath) {
  return String(dottedPath || "").split(".").reduce((value, key) => (value && value[key] !== undefined ? value[key] : undefined), root);
}

function parseScalarForExistingValue(rawValue, existingValue) {
  if (Array.isArray(existingValue)) {
    return String(rawValue || "")
      .split(",")
      .map((item) => item.trim())
      .filter(Boolean);
  }
  if (typeof existingValue === "boolean") {
    return /^(1|true|yes|on)$/i.test(String(rawValue || "").trim());
  }
  if (typeof existingValue === "number") {
    const n = Number(rawValue);
    return Number.isFinite(n) ? n : existingValue;
  }
  return String(rawValue || "");
}

function setByPath(root, dottedPath, rawValue) {
  const parts = String(dottedPath || "").split(".").filter(Boolean);
  if (!parts.length) throw new Error("--set requires a dotted setting path");
  let cursor = root;
  for (const key of parts.slice(0, -1)) {
    if (!isPlainObject(cursor[key])) cursor[key] = {};
    cursor = cursor[key];
  }
  const leaf = parts[parts.length - 1];
  cursor[leaf] = parseScalarForExistingValue(rawValue, cursor[leaf]);
}

function boolWord(value) {
  return value ? "1" : "0";
}

function listValue(value) {
  return Array.isArray(value) ? value.join(",") : String(value || "");
}

function escapeBatValue(value) {
  return String(value || "")
    .replace(/\^/g, "^^")
    .replace(/&/g, "^&")
    .replace(/\|/g, "^|")
    .replace(/</g, "^<")
    .replace(/>/g, "^>")
    .replace(/%/g, "%%");
}

function batSet(name, value) {
  return `set "${name}=${escapeBatValue(value)}"`;
}

function isVivadoLauncherPath(value) {
  const base = path.basename(String(value || "")).toLowerCase();
  return base === "vivado.bat" || base === "vivado.exe" || base === "vivado";
}

function emitBat(repoRoot, settings) {
  const projectRoot = resolveSettingPath(repoRoot, settings.paths.project_root, "../Project");
  const templateDir = resolveSettingPath(repoRoot, settings.paths.template_dir, "templates");
  const logDir = String(settings.paths.log_dir || "log");
  const outputDir = String(settings.paths.output_dir || "output");
  const vivadoExecutable = settings.paths.vivado_executable
    ? resolveSettingPath(repoRoot, settings.paths.vivado_executable)
    : "";
  const archiveDir = resolveSettingPath(repoRoot, settings.archive.bitstream_dir, "archive/bitstreams");
  const xdcPath = settings.board.xdc ? resolveProjectPath(projectRoot, settings.board.xdc) : "";
  const tokenSource = String(settings.telegram.token_source || "").trim();
  const lines = [
    batSet("FPGA_CLAW_SETTINGS_FILE", settingsPath(repoRoot)),
    batSet("FPGA_CLAW_REPO_ROOT", repoRoot),
    batSet("FPGA_AUTOMATION_REPO_ROOT", repoRoot),
    batSet("FPGA_MAIN_BAT_PATH", path.join(repoRoot, "MAIN.bat")),
    batSet("TEMPLATES_ROOT", templateDir),
    batSet("FPGA_CLAW_TEMPLATE_DIR", templateDir),
    batSet("FPGA_AUTOMATION_TEMPLATES_ROOT", templateDir),
    batSet("PROJECT_ROOT", projectRoot),
    batSet("FPGA_CLAW_PROJECT_ROOT", projectRoot),
    batSet("FPGA_PROJECT_ROOT", projectRoot),
    batSet("FPGA_CLAW_LOG_DIR", logDir),
    batSet("FPGA_CLAW_OUTPUT_DIR", outputDir),
    batSet("FPGA_CLAW_DEFAULT_BOARD", settings.board.default_board),
    batSet("FPGA_CLAW_BOARD_PROFILE", settings.board.profile_path),
    batSet("FPGA_CLAW_PART", settings.board.part),
    batSet("FPGA_CLAW_BOARD_PART", settings.board.board_part),
    batSet("FPGA_CLAW_XDC", xdcPath),
    batSet("FPGA_CLAW_CLOCK_MHZ", settings.board.clock_mhz),
    batSet("FPGA_CLAW_PROGRAMMER", settings.board.programmer),
    batSet("FPGA_TARGET_INDEX", settings.board.target_index),
    batSet("FPGA_DEVICE_INDEX", settings.board.device_index),
    batSet("FPGA_CLAW_REMEMBER_LAST_PROJECT", boolWord(settings.user.remember_last_project)),
    batSet("FPGA_CLAW_LAST_PROJECT", settings.user.last_project),
    batSet("FPGA_CLAW_DEFAULT_PROJECT", settings.user.default_project),
    batSet("FPGA_CLAW_LANGUAGE", settings.user.language),
    batSet("FPGA_CLAW_COMPACT_MENU", boolWord(settings.user.compact_menu)),
    batSet("FPGA_CLAW_CONFIRM_DANGEROUS_ACTIONS", boolWord(settings.user.confirm_dangerous_actions)),
    batSet("FPGA_CLAW_BITSTREAM_ARCHIVE_DIR", archiveDir),
    batSet("FPGA_CLAW_BACKUP_SETTINGS", boolWord(settings.archive.backup_settings)),
    batSet("FPGA_CLAW_KEEP_LOGS", settings.archive.keep_logs),
    batSet("FPGA_CLAW_CLEAN_PRESERVE", listValue(settings.archive.clean_preserve)),
    batSet("TELEGRAM_FPGA_CLAW_ENABLED", boolWord(settings.telegram.enabled)),
    batSet("TELEGRAM_ALLOWED_USER_IDS", listValue(settings.telegram.allowed_user_ids)),
    batSet("TELEGRAM_SIM_VIVADO_LOG_LINES", settings.telegram.max_log_lines),
    batSet("TELEGRAM_ALLOWED_COMMAND_GROUPS", listValue(settings.telegram.allowed_commands)),
    batSet("TELEGRAM_NOTIFY_EVENTS", listValue(settings.telegram.notify_events)),
  ];
  if (vivadoExecutable) {
    lines.push(batSet("FPGA_CLAW_VIVADO_EXECUTABLE", vivadoExecutable));
    lines.push(batSet("VIVADO_BIN", vivadoExecutable));
  }
  if (tokenSource.toLowerCase().startsWith("env_file:")) {
    lines.push(batSet("TELEGRAM_ENV_FILE", resolveSettingPath(repoRoot, tokenSource.slice("env_file:".length))));
  } else if (tokenSource.toLowerCase().startsWith("env:")) {
    const envName = tokenSource.slice("env:".length).trim();
    if (envName && envName !== "TELEGRAM_BOT_TOKEN") {
      lines.push(`if defined ${envName} set "TELEGRAM_BOT_TOKEN=%${envName}%"`);
    }
  }
  if (isVivadoLauncherPath(vivadoExecutable)) {
    lines.push(`for %%I in ("%VIVADO_BIN%") do set "VIVADO_BIN=%%~dpI"`);
  }
  return lines.join("\r\n") + "\r\n";
}

const FIELDS = {
  Paths: [
    ["paths.project_root", "Project root"],
    ["paths.log_dir", "Log directory"],
    ["paths.output_dir", "Output directory"],
    ["paths.template_dir", "Template path"],
    ["paths.vivado_executable", "Vivado executable"],
    ["paths.editor", "Default editor"],
  ],
  Board: [
    ["board.default_board", "Default board"],
    ["board.profile_path", "Board profile"],
    ["board.part", "FPGA part"],
    ["board.board_part", "Board part"],
    ["board.xdc", "Constraint file"],
    ["board.clock_mhz", "Clock MHz"],
    ["board.programmer", "Programmer"],
    ["board.target_index", "Target index"],
    ["board.device_index", "Device index"],
  ],
  Telegram: [
    ["telegram.enabled", "Enabled"],
    ["telegram.token_source", "Token source"],
    ["telegram.allowed_user_ids", "Allowed users"],
    ["telegram.notify_events", "Notify events"],
    ["telegram.max_log_lines", "Max log lines"],
    ["telegram.allowed_commands", "Allowed commands"],
  ],
  User: [
    ["user.remember_last_project", "Remember project"],
    ["user.last_project", "Last project"],
    ["user.default_project", "Default project"],
    ["user.language", "Menu language"],
    ["user.compact_menu", "Compact menu"],
    ["user.confirm_dangerous_actions", "Confirm danger"],
  ],
  Archive: [
    ["archive.bitstream_dir", "Bitstream archive"],
    ["archive.backup_settings", "Backup settings"],
    ["archive.keep_logs", "Keep logs"],
    ["archive.clean_preserve", "Clean preserve"],
  ],
};

function displayValue(value) {
  if (Array.isArray(value)) return value.join(", ");
  if (typeof value === "boolean") return value ? "ON" : "OFF";
  return String(value === undefined || value === null ? "" : value);
}

function padRight(value, width) {
  const text = String(value || "");
  if (text.length >= width) return text.slice(0, width);
  return text + " ".repeat(width - text.length);
}

function renderTui(settings, state, message = "") {
  const categories = Object.keys(FIELDS);
  const currentCategory = categories[state.categoryIndex];
  const rows = FIELDS[currentCategory];
  const output = [];
  output.push("\x1b[2J\x1b[H");
  output.push("\x1b[96mFPGAClaw Settings\x1b[0m");
  output.push("\x1b[90m" + "─".repeat(88) + "\x1b[0m");
  for (let i = 0; i < 18; i += 1) {
    const cat = categories[i] || "";
    const left = cat
      ? `${i === state.categoryIndex ? "\x1b[96m>" : " "} ${padRight(cat, 11)}\x1b[0m`
      : " ".repeat(14);
    const row = rows[i];
    let right = "";
    if (row) {
      const selected = i === state.rowIndex;
      const label = padRight(row[1], 18);
      const value = displayValue(getByPath(settings, row[0]));
      const color = selected ? "\x1b[96m" : typeof getByPath(settings, row[0]) === "boolean" && getByPath(settings, row[0]) ? "\x1b[92m" : "\x1b[97m";
      right = `${color}${selected ? "> " : "  "}${label} ${value}\x1b[0m`;
    }
    output.push(`\x1b[90m│\x1b[0m ${left} \x1b[90m│\x1b[0m ${right}`);
  }
  output.push("\x1b[90m" + "─".repeat(88) + "\x1b[0m");
  output.push("\x1b[90m[←→] section  [↑↓] field  [Enter] edit  [Space] toggle  [S] save  [Esc] back\x1b[0m");
  if (message) output.push(`\x1b[93m${message}\x1b[0m`);
  process.stdout.write(output.join("\n"));
}

function askLine(promptText) {
  return new Promise((resolve) => {
    if (process.stdin.isTTY) process.stdin.setRawMode(false);
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    rl.question(promptText, (answer) => {
      rl.close();
      if (process.stdin.isTTY) process.stdin.setRawMode(true);
      resolve(answer);
    });
  });
}

async function runTui(repoRoot) {
  let settings = loadSettings(repoRoot);
  const categories = Object.keys(FIELDS);
  const state = { categoryIndex: 0, rowIndex: 0 };
  if (!process.stdin.isTTY || !process.stdout.isTTY) {
    process.stdout.write(settingsToYaml(settings));
    return;
  }

  readline.emitKeypressEvents(process.stdin);
  process.stdin.setRawMode(true);
  process.stdout.write("\x1b[?25l");

  let message = "";
  const cleanup = () => {
    if (process.stdin.isTTY) process.stdin.setRawMode(false);
    process.stdout.write("\x1b[?25h\x1b[0m\n");
  };

  try {
    renderTui(settings, state, message);
    for (;;) {
      const key = await new Promise((resolve) => process.stdin.once("keypress", (_, k) => resolve(k || {})));
      message = "";
      const rows = FIELDS[categories[state.categoryIndex]];
      if (key.name === "escape" || (key.ctrl && key.name === "c")) break;
      if (key.name === "up") state.rowIndex = Math.max(0, state.rowIndex - 1);
      else if (key.name === "down") state.rowIndex = Math.min(rows.length - 1, state.rowIndex + 1);
      else if (key.name === "left") {
        state.categoryIndex = Math.max(0, state.categoryIndex - 1);
        state.rowIndex = 0;
      } else if (key.name === "right") {
        state.categoryIndex = Math.min(categories.length - 1, state.categoryIndex + 1);
        state.rowIndex = 0;
      } else if (key.name === "space") {
        const [fieldPath] = rows[state.rowIndex];
        const current = getByPath(settings, fieldPath);
        if (typeof current === "boolean") setByPath(settings, fieldPath, current ? "false" : "true");
      } else if (key.name === "return") {
        const [fieldPath, label] = rows[state.rowIndex];
        const current = getByPath(settings, fieldPath);
        if (typeof current === "boolean") {
          setByPath(settings, fieldPath, current ? "false" : "true");
        } else {
          process.stdout.write("\n");
          const answer = await askLine(`${label} [${displayValue(current)}]: `);
          if (answer.trim() !== "") setByPath(settings, fieldPath, answer);
        }
      } else if ((key.name || "").toLowerCase() === "s") {
        saveSettings(repoRoot, settings, { backup: true });
        message = `Saved: ${settingsPath(repoRoot)}`;
      }
      renderTui(settings, state, message);
    }
  } finally {
    cleanup();
  }
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function runSelftest() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "fpga-claw-settings-"));
  const settings = defaultSettings();
  settings.paths.project_root = "../Project";
  settings.board.profile_path = "boards/demo.yml";
  fs.mkdirSync(path.join(root, "boards"), { recursive: true });
  fs.writeFileSync(path.join(root, "boards", "demo.yml"), "part: xc7a35tcpg236-1\nxdc: demo.xdc\n", "utf8");
  fs.writeFileSync(path.join(root, "boards", "demo.xdc"), "# xdc\n", "utf8");
  saveSettings(root, settings, { backup: false });
  let loaded = loadSettings(root);
  assert(loaded.board.part === "xc7a35tcpg236-1", "board profile part did not merge");
  assert(path.isAbsolute(loaded.board.xdc), "profile xdc should resolve to an absolute path");
  loaded.paths.vivado_executable = "C:/Xilinx/Vivado/2024.2/bin/vivado.bat";
  saveSettings(root, loaded, { backup: true });
  const backupDir = path.join(root, ".fpga_claw", "settings_backups");
  assert(fs.existsSync(backupDir), "backup directory was not created");
  const bat = emitBat(root, loadSettings(root));
  assert(bat.includes("set \"PROJECT_ROOT="), "emit-bat did not include PROJECT_ROOT");
  assert(bat.includes("set \"VIVADO_BIN="), "emit-bat did not include VIVADO_BIN");
  setByPath(loaded, "telegram.allowed_user_ids", "1,2");
  assert(Array.isArray(loaded.telegram.allowed_user_ids) && loaded.telegram.allowed_user_ids.length === 2, "--set list parsing failed");
  fs.rmSync(root, { recursive: true, force: true });
  process.stdout.write("fpga_claw_settings_cli selftest: OK\n");
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.selftest) {
    runSelftest();
    return;
  }
  const repoRoot = inferRepoRoot(opts);
  if (opts.emitBat) {
    process.stdout.write(emitBat(repoRoot, loadSettings(repoRoot)));
    return;
  }
  if (opts.init) {
    const filePath = saveSettings(repoRoot, loadSettings(repoRoot), { backup: false });
    process.stdout.write(`${filePath}\n`);
    return;
  }
  if (opts.setPath) {
    const settings = loadSettings(repoRoot);
    setByPath(settings, opts.setPath, opts.setValue);
    saveSettings(repoRoot, settings, { backup: !opts.noBackup });
    return;
  }
  if (opts.tui) {
    await runTui(repoRoot);
    return;
  }
  process.stdout.write(settingsToYaml(loadSettings(repoRoot)));
}

main().catch((error) => {
  process.stderr.write(`[ERROR] ${error.message}\n`);
  process.exit(1);
});
