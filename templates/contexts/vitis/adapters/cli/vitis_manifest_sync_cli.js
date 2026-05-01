#!/usr/bin/env node
const path = require("path");
const { syncVitisApplications } = require("../../application/vitis_manifest_sync_service");

function parseArgs(argv) {
  const opts = {
    projectRoot: process.cwd(),
    planPath: "",
    resultPath: "",
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
    if (arg === "--pretty" || arg === "--json") {
      opts.pretty = true;
      continue;
    }
    throw new Error(`Unknown argument: ${arg}`);
  }

  if (!opts.planPath) throw new Error("--plan-json is required");
  if (!opts.resultPath) throw new Error("--result-json is required");
  opts.projectRoot = path.resolve(opts.projectRoot);
  opts.planPath = path.resolve(opts.planPath);
  opts.resultPath = path.resolve(opts.resultPath);
  return opts;
}

function main() {
  try {
    const opts = parseArgs(process.argv.slice(2));
    const result = syncVitisApplications(opts);
    process.stdout.write(`${JSON.stringify(result, null, opts.pretty ? 2 : 0)}\n`);
    if (result.status === "updated") {
      console.log(`[INFO] manifest=${result.manifestPath}`);
    }
    process.exit(0);
  } catch (err) {
    console.error(`[ERROR] ${err.message}`);
    process.exit(1);
  }
}

if (require.main === module) {
  main();
}

module.exports = {
  parseArgs,
};
