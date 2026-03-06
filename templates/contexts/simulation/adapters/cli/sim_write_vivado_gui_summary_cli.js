const fs = require("fs");
const path = require("path");
const { writeJsonFile } = require("../../../../shared/application/json_file_service");
const { appendRunEntry } = require("../../../../shared/application/run_registry_service");
const {
  createArtifactRecord,
  createRunSummary,
  normalizeArtifactPath,
  normalizeSlashes,
} = require("../../../../shared/domain/run_contracts");

function usageAndExit() {
  console.error(
    "Usage: node sim_write_vivado_gui_summary_cli.js --project-root <path> [--tool <tool>] [--manifest-json <path>] [--status <status>] " +
      "[--folder-idx <n>] [--folder-name <name>] [--tb-idx <n>] [--tb-name <name>] [--tb-file <path>] " +
      "[--replay-state <state>] [--vivado-log-path <path>] [--vivado-journal-path <path>] " +
      "[--close-prompt-dir <path>] [--close-decision <decision>] " +
      "[--started-at <iso>] [--finished-at <iso>]"
  );
  process.exit(1);
}

function parseArgs(argv) {
  const out = {
    projectRoot: "",
    tool: "vivado_sim_gui",
    manifestJsonPath: "",
    status: "unknown",
    folderIdx: "",
    folderName: "",
    tbIdx: "",
    tbName: "",
    tbFile: "",
    replayState: "",
    vivadoLogPath: "",
    vivadoJournalPath: "",
    closePromptDir: "",
    closeDecision: "",
    startedAt: "",
    finishedAt: "",
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = String(argv[i] || "");
    if (!arg.startsWith("--")) usageAndExit();
    const key = arg.slice(2);
    i += 1;
    if (i >= argv.length) usageAndExit();
    const value = String(argv[i] || "");
    switch (key) {
      case "project":
      case "project-root":
        out.projectRoot = value;
        break;
      case "tool":
        out.tool = value || "vivado_sim_gui";
        break;
      case "manifest-json":
        out.manifestJsonPath = value;
        break;
      case "status":
        out.status = value || "unknown";
        break;
      case "folder-idx":
        out.folderIdx = value;
        break;
      case "folder-name":
        out.folderName = value;
        break;
      case "tb-idx":
        out.tbIdx = value;
        break;
      case "tb-name":
        out.tbName = value;
        break;
      case "tb-file":
        out.tbFile = value;
        break;
      case "replay-state":
        out.replayState = value;
        break;
      case "vivado-log":
      case "vivado-log-path":
        out.vivadoLogPath = value;
        break;
      case "vivado-journal-path":
        out.vivadoJournalPath = value;
        break;
      case "close-prompt-dir":
        out.closePromptDir = value;
        break;
      case "close-decision":
        out.closeDecision = value;
        break;
      case "started-at":
        out.startedAt = value;
        break;
      case "finished-at":
        out.finishedAt = value;
        break;
      default:
        usageAndExit();
    }
  }

  if (!out.projectRoot) usageAndExit();
  return out;
}

function createRunStamp(dateValue) {
  const date = dateValue ? new Date(dateValue) : new Date();
  const pad = (value, width = 2) => String(value).padStart(width, "0");
  return [
    date.getFullYear(),
    pad(date.getMonth() + 1),
    pad(date.getDate()),
    "_",
    pad(date.getHours()),
    pad(date.getMinutes()),
    pad(date.getSeconds()),
    "_",
    pad(date.getMilliseconds(), 3),
  ].join("");
}

function toNumberOrZero(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const projectRoot = path.resolve(args.projectRoot);
  const tool = String(args.tool || "vivado_sim_gui").trim() || "vivado_sim_gui";
  const finishedAt = args.finishedAt || new Date().toISOString();
  const startedAt = args.startedAt || finishedAt;
  const runStamp = createRunStamp(finishedAt);
  const historyDir = path.join(projectRoot, "output", "history", tool, runStamp);
  const warnings = [];
  const artifacts = [];

  const vivadoLogPath = args.vivadoLogPath ? path.resolve(args.vivadoLogPath) : "";
  const vivadoJournalPath = args.vivadoJournalPath ? path.resolve(args.vivadoJournalPath) : "";
  if (vivadoLogPath && fs.existsSync(vivadoLogPath)) {
    artifacts.push(
      createArtifactRecord({
        kind: "vivado_log",
        path: normalizeArtifactPath(projectRoot, vivadoLogPath),
        label: path.basename(vivadoLogPath),
      })
    );
  } else if (vivadoLogPath) {
    warnings.push("vivado_log_missing");
  }
  if (vivadoJournalPath && fs.existsSync(vivadoJournalPath)) {
    artifacts.push(
      createArtifactRecord({
        kind: "vivado_journal",
        path: normalizeArtifactPath(projectRoot, vivadoJournalPath),
        label: path.basename(vivadoJournalPath),
      })
    );
  } else if (vivadoJournalPath) {
    warnings.push("vivado_journal_missing");
  }

  const summary = createRunSummary({
    tool,
    projectRoot,
    manifestJsonPath: normalizeSlashes(args.manifestJsonPath || ""),
    status: args.status,
    startedAt,
    finishedAt,
    warnings,
    artifacts,
    details: {
      folder_idx: toNumberOrZero(args.folderIdx),
      folderIdx: toNumberOrZero(args.folderIdx),
      folder_name: String(args.folderName || ""),
      folderName: String(args.folderName || ""),
      tb_idx: toNumberOrZero(args.tbIdx),
      tbIdx: toNumberOrZero(args.tbIdx),
      tb_name: String(args.tbName || ""),
      tbName: String(args.tbName || ""),
      tb_file: normalizeSlashes(args.tbFile || ""),
      tbFile: normalizeSlashes(args.tbFile || ""),
      replay_state: String(args.replayState || ""),
      replayState: String(args.replayState || ""),
      vivado_log_path: vivadoLogPath ? normalizeArtifactPath(projectRoot, vivadoLogPath) : "",
      vivadoLogPath: vivadoLogPath ? normalizeArtifactPath(projectRoot, vivadoLogPath) : "",
      vivado_journal_path: vivadoJournalPath ? normalizeArtifactPath(projectRoot, vivadoJournalPath) : "",
      close_prompt_dir: args.closePromptDir ? normalizeArtifactPath(projectRoot, args.closePromptDir) : "",
      closePromptDir: args.closePromptDir ? normalizeArtifactPath(projectRoot, args.closePromptDir) : "",
      close_decision: String(args.closeDecision || ""),
      closeDecision: String(args.closeDecision || ""),
    },
  });

  const historySummaryPath = writeJsonFile(path.join(historyDir, "run_summary.json"), summary);
  const outputSummaryPath = writeJsonFile(path.join(projectRoot, "output", "run_summary.json"), summary);
  const runIndexPath = appendRunEntry(projectRoot, {
    tool,
    projectRoot,
    manifestJsonPath: args.manifestJsonPath || "",
    status: args.status,
    outputs: artifacts,
    summaryPath: historySummaryPath,
    metadata: {
      folder_idx: toNumberOrZero(args.folderIdx),
      folder_name: String(args.folderName || ""),
      tb_idx: toNumberOrZero(args.tbIdx),
      tb_name: String(args.tbName || ""),
      replay_state: String(args.replayState || ""),
      close_decision: String(args.closeDecision || ""),
      vivado_log_path: vivadoLogPath ? normalizeArtifactPath(projectRoot, vivadoLogPath) : "",
      tbName: String(args.tbName || ""),
      replayState: String(args.replayState || ""),
      closeDecision: String(args.closeDecision || ""),
    },
    createdAt: finishedAt,
  });

  console.log(`[INFO] summary=${normalizeSlashes(outputSummaryPath)}`);
  console.log(`[INFO] run_summary=${normalizeSlashes(outputSummaryPath)}`);
  console.log(`[INFO] run_summary_history=${normalizeSlashes(historySummaryPath)}`);
  console.log(`[INFO] run_index=${normalizeSlashes(runIndexPath)}`);
}

if (require.main === module) {
  try {
    main();
  } catch (err) {
    console.error(`Error: ${err.message}`);
    process.exit(1);
  }
}
