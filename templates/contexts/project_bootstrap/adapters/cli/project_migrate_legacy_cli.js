const fs = require("fs");
const path = require("path");
const {
  ensureDir,
  executeLegacyProjectMigration,
  writeMigrationArtifacts,
} = require("../../application/legacy_project_migration_service");
const {
  runLegacyProjectMigrationSelftest,
} = require("../../application/legacy_project_migration_selftest");

const EXIT_OK = 0;
const EXIT_FAIL = 1;
const EXIT_INPUT = 2;

function parseArgs(argv) {
  const opts = {
    repoRoot: path.resolve(__dirname, "..", "..", "..", "..", ".."),
    projectRoot: null,
    dryRun: false,
    inferGlobs: false,
    selftest: false,
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
    if (arg === "--dry-run") {
      opts.dryRun = true;
      continue;
    }
    if (arg === "--infer-globs") {
      opts.inferGlobs = true;
      continue;
    }
    if (arg === "--selftest") {
      opts.selftest = true;
      continue;
    }
    throw new Error(`Unknown argument: ${arg}`);
  }

  if (!opts.projectRoot) {
    opts.projectRoot = path.join(opts.repoRoot, "Project");
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

  if (opts.selftest) {
    try {
      const result = runLegacyProjectMigrationSelftest();
      process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
      process.exit(EXIT_OK);
    } catch (err) {
      console.error(`[ERROR] ${err.message}`);
      process.exit(EXIT_FAIL);
    }
    return;
  }

  if (!fs.existsSync(opts.repoRoot) || !fs.statSync(opts.repoRoot).isDirectory()) {
    console.error(`[ERROR] Repo root not found: ${opts.repoRoot}`);
    process.exit(EXIT_INPUT);
    return;
  }

  ensureDir(opts.projectRoot);
  const report = executeLegacyProjectMigration(opts);
  const artifacts = writeMigrationArtifacts(report, opts.repoRoot);

  console.log(`[INFO] scanned=${report.scanned} migrated=${report.migrated} failed=${report.failed}`);
  console.log(`[INFO] summary=${artifacts.summaryPath}`);
  console.log(`[INFO] report=${artifacts.reportPath}`);

  process.exit(report.failed > 0 ? EXIT_FAIL : EXIT_OK);
}

if (require.main === module) {
  main();
}
