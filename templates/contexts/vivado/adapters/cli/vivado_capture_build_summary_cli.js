const path = require("path");
const { writeBuildSummary } = require("../../application/build_summary_service");
const { prepareVivadoBuild } = require("../../application/vivado_build_plan_service");
const { runBuildSummarySelftest } = require("../../application/build_summary_selftest");

function parseArgs(argv) {
  const opts = {
    stage: "capture",
    projectRoot: process.cwd(),
    manifestJsonPath: "",
    buildLogPath: "",
    outputPath: "",
    buildPlanPath: "",
    buildResultPath: "",
    srcListPath: "",
    xdcListPath: "",
    incListPath: "",
    programStatus: "NOT_RUN",
    buildRc: -1,
    rtlRc: -1,
    reportRc: -1,
    autoProgram: false,
    noPause: false,
    pretty: false,
    selftest: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--project") {
      opts.projectRoot = argv[++i] || opts.projectRoot;
      continue;
    }
    if (arg === "--stage") {
      opts.stage = argv[++i] || opts.stage;
      continue;
    }
    if (arg.startsWith("--stage=")) {
      opts.stage = arg.slice("--stage=".length);
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
    if (arg === "--build-log") {
      opts.buildLogPath = argv[++i] || "";
      continue;
    }
    if (arg.startsWith("--build-log=")) {
      opts.buildLogPath = arg.slice("--build-log=".length);
      continue;
    }
    if (arg === "--build-plan-json") {
      opts.buildPlanPath = argv[++i] || "";
      continue;
    }
    if (arg.startsWith("--build-plan-json=")) {
      opts.buildPlanPath = arg.slice("--build-plan-json=".length);
      continue;
    }
    if (arg === "--build-result-json") {
      opts.buildResultPath = argv[++i] || "";
      continue;
    }
    if (arg.startsWith("--build-result-json=")) {
      opts.buildResultPath = arg.slice("--build-result-json=".length);
      continue;
    }
    if (arg === "--src-list") {
      opts.srcListPath = argv[++i] || "";
      continue;
    }
    if (arg.startsWith("--src-list=")) {
      opts.srcListPath = arg.slice("--src-list=".length);
      continue;
    }
    if (arg === "--xdc-list") {
      opts.xdcListPath = argv[++i] || "";
      continue;
    }
    if (arg.startsWith("--xdc-list=")) {
      opts.xdcListPath = arg.slice("--xdc-list=".length);
      continue;
    }
    if (arg === "--inc-list") {
      opts.incListPath = argv[++i] || "";
      continue;
    }
    if (arg.startsWith("--inc-list=")) {
      opts.incListPath = arg.slice("--inc-list=".length);
      continue;
    }
    if (arg === "--write") {
      opts.outputPath = argv[++i] || "";
      continue;
    }
    if (arg.startsWith("--write=")) {
      opts.outputPath = arg.slice("--write=".length);
      continue;
    }
    if (arg === "--program-status") {
      opts.programStatus = argv[++i] || opts.programStatus;
      continue;
    }
    if (arg.startsWith("--program-status=")) {
      opts.programStatus = arg.slice("--program-status=".length);
      continue;
    }
    if (arg === "--build-rc") {
      opts.buildRc = Number(argv[++i] || "-1");
      continue;
    }
    if (arg.startsWith("--build-rc=")) {
      opts.buildRc = Number(arg.slice("--build-rc=".length));
      continue;
    }
    if (arg === "--rtl-rc") {
      opts.rtlRc = Number(argv[++i] || "-1");
      continue;
    }
    if (arg.startsWith("--rtl-rc=")) {
      opts.rtlRc = Number(arg.slice("--rtl-rc=".length));
      continue;
    }
    if (arg === "--report-rc") {
      opts.reportRc = Number(argv[++i] || "-1");
      continue;
    }
    if (arg.startsWith("--report-rc=")) {
      opts.reportRc = Number(arg.slice("--report-rc=".length));
      continue;
    }
    if (arg === "--auto-program") {
      opts.autoProgram = true;
      continue;
    }
    if (arg === "--no-pause") {
      opts.noPause = true;
      continue;
    }
    if (arg === "--pretty" || arg === "--json") {
      opts.pretty = true;
      continue;
    }
    if (arg === "--selftest") {
      opts.selftest = true;
      continue;
    }
    throw new Error(`Unknown argument: ${arg}`);
  }

  opts.projectRoot = path.resolve(opts.projectRoot);
  if (opts.manifestJsonPath) opts.manifestJsonPath = path.resolve(opts.manifestJsonPath);
  if (opts.buildLogPath) opts.buildLogPath = path.resolve(opts.buildLogPath);
  if (opts.buildPlanPath) opts.buildPlanPath = path.resolve(opts.buildPlanPath);
  if (opts.buildResultPath) opts.buildResultPath = path.resolve(opts.buildResultPath);
  if (opts.srcListPath) opts.srcListPath = path.resolve(opts.srcListPath);
  if (opts.xdcListPath) opts.xdcListPath = path.resolve(opts.xdcListPath);
  if (opts.incListPath) opts.incListPath = path.resolve(opts.incListPath);
  if (opts.outputPath) opts.outputPath = path.resolve(opts.outputPath);
  return opts;
}

function main() {
  try {
    const opts = parseArgs(process.argv.slice(2));
    if (opts.selftest) {
      process.stdout.write(`${JSON.stringify(runBuildSummarySelftest(), null, 2)}\n`);
      process.exit(0);
      return;
    }

    if (String(opts.stage || "capture").toLowerCase() === "prepare") {
      const result = prepareVivadoBuild(opts);
      process.stdout.write(`${JSON.stringify({ requestPath: result.requestPath, planPath: result.planPath, planCommandPath: result.planCommandPath, plan: result.plan }, null, opts.pretty ? 2 : 0)}\n`);
      process.exit(0);
      return;
    }

    const result = writeBuildSummary(opts);
    process.stdout.write(`${JSON.stringify(result.summary, null, opts.pretty ? 2 : 0)}\n`);
    process.exit(result.summary.status === "failed" ? 1 : 0);
  } catch (err) {
    console.error(`[ERROR] ${err.message}`);
    process.exit(2);
  }
}

if (require.main === module) {
  main();
}
