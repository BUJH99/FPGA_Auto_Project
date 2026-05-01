#!/usr/bin/env node
const path = require("path");
const { listVitisChoices, prepareVitisPlan, VALID_STEPS } = require("../../application/vitis_plan_service");

function parseArgs(argv) {
  const opts = {
    projectRoot: process.cwd(),
    manifestJsonPath: "",
    step: "",
    appName: "",
    appNames: [],
    allApps: false,
    target: "",
    runRequested: false,
    xsaSelector: "",
    bitSelector: "",
    platformSelector: "",
    timestamp: "",
    listKind: "",
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
    if (arg === "--app") {
      const value = argv[++i] || "";
      opts.appName = opts.appName || value;
      opts.appNames.push(value);
      continue;
    }
    if (arg.startsWith("--app=")) {
      const value = arg.slice("--app=".length);
      opts.appName = opts.appName || value;
      opts.appNames.push(value);
      continue;
    }
    if (arg === "--apps") {
      opts.appNames.push(argv[++i] || "");
      continue;
    }
    if (arg.startsWith("--apps=")) {
      opts.appNames.push(arg.slice("--apps=".length));
      continue;
    }
    if (arg === "--all-apps" || arg === "--all-applications") {
      opts.allApps = true;
      continue;
    }
    if (arg === "--target") {
      opts.target = argv[++i] || "";
      continue;
    }
    if (arg.startsWith("--target=")) {
      opts.target = arg.slice("--target=".length);
      continue;
    }
    if (arg === "--run") {
      opts.runRequested = true;
      continue;
    }
    if (arg === "--xsa") {
      opts.xsaSelector = argv[++i] || "";
      continue;
    }
    if (arg.startsWith("--xsa=")) {
      opts.xsaSelector = arg.slice("--xsa=".length);
      continue;
    }
    if (arg === "--bit" || arg === "--bitstream") {
      opts.bitSelector = argv[++i] || "";
      continue;
    }
    if (arg.startsWith("--bit=")) {
      opts.bitSelector = arg.slice("--bit=".length);
      continue;
    }
    if (arg.startsWith("--bitstream=")) {
      opts.bitSelector = arg.slice("--bitstream=".length);
      continue;
    }
    if (arg === "--platform") {
      opts.platformSelector = argv[++i] || "";
      continue;
    }
    if (arg.startsWith("--platform=")) {
      opts.platformSelector = arg.slice("--platform=".length);
      continue;
    }
    if (arg === "--timestamp") {
      opts.timestamp = argv[++i] || "";
      continue;
    }
    if (arg.startsWith("--timestamp=")) {
      opts.timestamp = arg.slice("--timestamp=".length);
      continue;
    }
    if (arg === "--list") {
      opts.listKind = argv[++i] || "";
      continue;
    }
    if (arg.startsWith("--list=")) {
      opts.listKind = arg.slice("--list=".length);
      continue;
    }
    if (arg === "--pretty" || arg === "--json") {
      opts.pretty = true;
      continue;
    }
    throw new Error(`Unknown argument: ${arg}`);
  }

  if (!opts.manifestJsonPath) {
    throw new Error("--manifest-json is required");
  }
  if (!opts.listKind && !VALID_STEPS.has(opts.step)) {
    throw new Error(`--step must be one of: ${Array.from(VALID_STEPS).join(", ")}`);
  }
  opts.projectRoot = path.resolve(opts.projectRoot);
  opts.manifestJsonPath = path.resolve(opts.manifestJsonPath);
  return opts;
}

function listDisplayLabel(choice) {
  if (choice.kind === "platform") {
    if (choice.hasXpfm && choice.fileName) return choice.fileName;
    if (choice.hasComponentDir && choice.name) return `${choice.name} (component, needs build)`;
    return path.basename(choice.xpfm || choice.path || "") || choice.name || "";
  }
  if (choice.fileName) return choice.fileName;
  if (choice.kind === "application") {
    return choice.name || "";
  }
  return choice.relativePath || choice.name || "";
}

function main() {
  try {
    const opts = parseArgs(process.argv.slice(2));
    if (opts.listKind) {
      const result = listVitisChoices({
        projectRoot: opts.projectRoot,
        manifestJsonPath: opts.manifestJsonPath,
        kind: opts.listKind,
      });
      if (opts.pretty) {
        process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
      } else {
        for (const choice of result.choices) {
          const value = choice.path || choice.xpfm || choice.name || "";
          process.stdout.write(`${choice.index}|${choice.name || ""}|${value}|${listDisplayLabel(choice)}\n`);
        }
      }
      process.exit(0);
    }
    const result = prepareVitisPlan(opts);
    process.stdout.write(`${JSON.stringify(result, null, opts.pretty ? 2 : 0)}\n`);
    process.exit(0);
  } catch (err) {
    console.error(`[ERROR] ${err.message}`);
    process.exit(2);
  }
}

if (require.main === module) {
  main();
}
