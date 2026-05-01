const fs = require("fs");
const path = require("path");
const {
  executeProjectUpgrade,
  writeProjectUpgradeArtifacts,
} = require("../../application/project_upgrade_service");

const EXIT_OK = 0;
const EXIT_FAIL = 1;
const EXIT_INPUT = 2;

function parseArgs(argv) {
  const opts = {
    repoRoot: path.resolve(__dirname, "..", "..", "..", "..", ".."),
    projectRoot: null,
    project: "",
    dryRun: false,
  };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--repo") {
      i += 1;
      if (i >= argv.length) throw new Error("--repo requires a value");
      opts.repoRoot = path.resolve(argv[i]);
      continue;
    }
    if (arg.startsWith("--repo=")) {
      opts.repoRoot = path.resolve(arg.slice("--repo=".length));
      continue;
    }
    if (arg === "--project-root") {
      i += 1;
      if (i >= argv.length) throw new Error("--project-root requires a value");
      opts.projectRoot = path.resolve(argv[i]);
      continue;
    }
    if (arg.startsWith("--project-root=")) {
      opts.projectRoot = path.resolve(arg.slice("--project-root=".length));
      continue;
    }
    if (arg === "--project") {
      i += 1;
      if (i >= argv.length) throw new Error("--project requires a value");
      opts.project = argv[i];
      continue;
    }
    if (arg.startsWith("--project=")) {
      opts.project = arg.slice("--project=".length);
      continue;
    }
    if (arg === "--dry-run") {
      opts.dryRun = true;
      continue;
    }
    throw new Error(`Unknown argument: ${arg}`);
  }

  if (!opts.projectRoot) {
    opts.projectRoot = path.resolve(opts.repoRoot, "..", "Project");
  }

  return opts;
}

function main() {
  let opts = null;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (err) {
    console.error(`[ERROR] ${err.message}`);
    process.exit(EXIT_INPUT);
    return;
  }

  if (!fs.existsSync(opts.repoRoot) || !fs.statSync(opts.repoRoot).isDirectory()) {
    console.error(`[ERROR] Repo root not found: ${opts.repoRoot}`);
    process.exit(EXIT_INPUT);
    return;
  }

  const report = executeProjectUpgrade(opts);
  const artifacts = writeProjectUpgradeArtifacts(report, opts.repoRoot);

  console.log(`[INFO] scanned=${report.scanned} upgraded=${report.upgraded} current=${report.current} failed=${report.failed}`);
  console.log(`[INFO] summary=${artifacts.summaryPath}`);
  console.log(`[INFO] report=${artifacts.reportPath}`);

  process.exit(report.failed > 0 ? EXIT_FAIL : EXIT_OK);
}

if (require.main === module) {
  main();
}

module.exports = {
  parseArgs,
};
