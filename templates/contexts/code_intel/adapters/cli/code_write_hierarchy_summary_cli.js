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
    "Usage: node code_write_hierarchy_summary_cli.js --project-root <path> [--manifest-json <path>] [--status <status>] " +
      "[--scope <src|include_tb|tb_only>] [--tb-folder <path>] [--log-path <path>] " +
      "[--browse-once] [--tree-line-count <n>] [--started-at <iso>] [--finished-at <iso>]"
  );
  process.exit(1);
}

function parseArgs(argv) {
  const out = {
    projectRoot: "",
    manifestJsonPath: "",
    status: "unknown",
    scope: "src_only",
    tbFolder: "",
    logPath: "",
    browseOnce: false,
    treeLineCount: NaN,
    startedAt: "",
    finishedAt: "",
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = String(argv[i] || "");
    if (!arg.startsWith("--")) usageAndExit();
    const key = arg.slice(2);

    if (key === "browse-once") {
      out.browseOnce = true;
      continue;
    }

    i += 1;
    if (i >= argv.length) usageAndExit();
    const value = String(argv[i] || "");
    switch (key) {
      case "project":
      case "project-root":
        out.projectRoot = value;
        break;
      case "manifest-json":
        out.manifestJsonPath = value;
        break;
      case "status":
        out.status = value || "unknown";
        break;
      case "scope":
        out.scope = value || "src_only";
        break;
      case "tb-folder":
        out.tbFolder = value;
        break;
      case "log-path":
        out.logPath = value;
        break;
      case "tree-line-count":
        out.treeLineCount = Number(value);
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

function countHierarchyTreeLines(logPath) {
  if (!logPath || !fs.existsSync(logPath)) return 0;
  const lines = fs.readFileSync(logPath, "utf8").split(/\r?\n/);
  const startMarkers = [
    "+--",
    "\\--",
    "[SV Declarations]",
    "[TB Folders]",
    "[TB Folder]",
    "No modules found.",
    "No TB folders found.",
    "No TB top modules/programs found.",
  ];

  let capture = false;
  let count = 0;
  for (const rawLine of lines) {
    const line = String(rawLine || "");
    const stripped = line.trim();
    if (!capture && startMarkers.some((marker) => line.includes(marker))) {
      capture = true;
    }
    if (!capture) continue;
    if (
      line.includes("------------------------------------------------------------") ||
      stripped.startsWith("Command") ||
      stripped.startsWith("Transcript started") ||
      stripped.startsWith("Transcript stopped")
    ) {
      break;
    }
    if (stripped) count += 1;
  }
  return count;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const projectRoot = path.resolve(args.projectRoot);
  const finishedAt = args.finishedAt || new Date().toISOString();
  const startedAt = args.startedAt || finishedAt;
  const runStamp = createRunStamp(finishedAt);
  const historyDir = path.join(projectRoot, "output", "history", "hierarchy_view", runStamp);
  const warnings = [];
  const artifacts = [];
  const logPath = args.logPath ? path.resolve(args.logPath) : "";

  if (logPath && fs.existsSync(logPath)) {
    artifacts.push(
      createArtifactRecord({
        kind: "hierarchy_log",
        path: normalizeArtifactPath(projectRoot, logPath),
        label: path.basename(logPath),
      })
    );
  } else if (logPath) {
    warnings.push("hierarchy_log_missing");
  }

  const treeLineCount = Number.isFinite(args.treeLineCount)
    ? Math.max(0, Math.round(args.treeLineCount))
    : countHierarchyTreeLines(logPath);

  const summary = createRunSummary({
    tool: "hierarchy_view",
    projectRoot,
    manifestJsonPath: normalizeSlashes(args.manifestJsonPath || ""),
    status: args.status,
    startedAt,
    finishedAt,
    warnings,
    artifacts,
    details: {
      scope: String(args.scope || "src_only"),
      tb_folder: normalizeSlashes(args.tbFolder || ""),
      tbFolder: normalizeSlashes(args.tbFolder || ""),
      log_path: logPath ? normalizeArtifactPath(projectRoot, logPath) : "",
      logPath: logPath ? normalizeArtifactPath(projectRoot, logPath) : "",
      tree_line_count: treeLineCount,
      treeLineCount: treeLineCount,
      browse_once: Boolean(args.browseOnce),
      browseOnce: Boolean(args.browseOnce),
    },
  });

  const historySummaryPath = writeJsonFile(path.join(historyDir, "run_summary.json"), summary);
  const outputSummaryPath = writeJsonFile(path.join(projectRoot, "output", "run_summary.json"), summary);
  const runIndexPath = appendRunEntry(projectRoot, {
    tool: "hierarchy_view",
    projectRoot,
    manifestJsonPath: args.manifestJsonPath || "",
    status: args.status,
    outputs: artifacts,
    summaryPath: historySummaryPath,
    metadata: {
      scope: String(args.scope || "src_only"),
      tb_folder: normalizeSlashes(args.tbFolder || ""),
      tbFolder: normalizeSlashes(args.tbFolder || ""),
      tree_line_count: treeLineCount,
      treeLineCount: treeLineCount,
      log_path: logPath ? normalizeArtifactPath(projectRoot, logPath) : "",
      browse_once: Boolean(args.browseOnce),
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
