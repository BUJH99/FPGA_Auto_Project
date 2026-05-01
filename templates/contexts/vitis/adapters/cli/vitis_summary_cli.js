#!/usr/bin/env node
const path = require("path");
const { writeVitisSummary } = require("../../application/vitis_summary_service");

function parseArgs(argv) {
  const opts = {
    projectRoot: process.cwd(),
    manifestJsonPath: "",
    step: "",
    planPath: "",
    resultPath: "",
    summaryPath: "",
    logPath: "",
    status: "",
    rc: "",
    startedAt: "",
    finishedAt: "",
    pretty: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--project") {
      opts.projectRoot = argv[++i] || opts.projectRoot;
      continue;
    }
    if (arg.startsWith("--project=")) {
      opts.projectRoot = arg.slice("--project=".length);
      continue;
    }
    if (arg === "--manifest-json") {
      opts.manifestJsonPath = argv[++i] || "";
      continue;
    }
    if (arg.startsWith("--manifest-json=")) {
      opts.manifestJsonPath = arg.slice("--manifest-json=".length);
      continue;
    }
    if (arg === "--step") {
      opts.step = argv[++i] || "";
      continue;
    }
    if (arg.startsWith("--step=")) {
      opts.step = arg.slice("--step=".length);
      continue;
    }
    if (arg === "--plan-json") {
      opts.planPath = argv[++i] || "";
      continue;
    }
    if (arg.startsWith("--plan-json=")) {
      opts.planPath = arg.slice("--plan-json=".length);
      continue;
    }
    if (arg === "--result-json") {
      opts.resultPath = argv[++i] || "";
      continue;
    }
    if (arg.startsWith("--result-json=")) {
      opts.resultPath = arg.slice("--result-json=".length);
      continue;
    }
    if (arg === "--summary-json") {
      opts.summaryPath = argv[++i] || "";
      continue;
    }
    if (arg.startsWith("--summary-json=")) {
      opts.summaryPath = arg.slice("--summary-json=".length);
      continue;
    }
    if (arg === "--log") {
      opts.logPath = argv[++i] || "";
      continue;
    }
    if (arg.startsWith("--log=")) {
      opts.logPath = arg.slice("--log=".length);
      continue;
    }
    if (arg === "--status") {
      opts.status = argv[++i] || "";
      continue;
    }
    if (arg.startsWith("--status=")) {
      opts.status = arg.slice("--status=".length);
      continue;
    }
    if (arg === "--rc") {
      opts.rc = argv[++i] || "";
      continue;
    }
    if (arg.startsWith("--rc=")) {
      opts.rc = arg.slice("--rc=".length);
      continue;
    }
    if (arg === "--started-at") {
      opts.startedAt = argv[++i] || "";
      continue;
    }
    if (arg.startsWith("--started-at=")) {
      opts.startedAt = arg.slice("--started-at=".length);
      continue;
    }
    if (arg === "--finished-at") {
      opts.finishedAt = argv[++i] || "";
      continue;
    }
    if (arg.startsWith("--finished-at=")) {
      opts.finishedAt = arg.slice("--finished-at=".length);
      continue;
    }
    if (arg === "--pretty" || arg === "--json") {
      opts.pretty = true;
      continue;
    }
    throw new Error(`Unknown argument: ${arg}`);
  }

  opts.projectRoot = path.resolve(opts.projectRoot);
  if (opts.manifestJsonPath) opts.manifestJsonPath = path.resolve(opts.manifestJsonPath);
  if (opts.planPath) opts.planPath = path.resolve(opts.planPath);
  if (opts.resultPath) opts.resultPath = path.resolve(opts.resultPath);
  if (opts.summaryPath) opts.summaryPath = path.resolve(opts.summaryPath);
  if (opts.logPath) opts.logPath = path.resolve(opts.logPath);
  return opts;
}

function main() {
  try {
    const opts = parseArgs(process.argv.slice(2));
    const result = writeVitisSummary(opts);
    process.stdout.write(`${JSON.stringify(result.summary, null, opts.pretty ? 2 : 0)}\n`);
    console.log(`[INFO] summary=${result.summaryPath}`);
    console.log(`[INFO] run_summary=${result.summaryPath}`);
    process.exit(result.summary.status === "failed" ? 1 : 0);
  } catch (err) {
    console.error(`[ERROR] ${err.message}`);
    process.exit(2);
  }
}

if (require.main === module) {
  main();
}
