const path = require("path");
const { writeRegressionDashboard } = require("../../application/regression_dashboard_service");

function parseArgs(argv) {
  const opts = {
    projectRoot: process.cwd(),
    pretty: false,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = String(argv[index] || "");
    if (arg === "--project") {
      opts.projectRoot = argv[++index] || opts.projectRoot;
      continue;
    }
    if (arg.startsWith("--project=")) {
      opts.projectRoot = arg.slice("--project=".length);
      continue;
    }
    if (arg === "--pretty" || arg === "--json") {
      opts.pretty = true;
      continue;
    }
    throw new Error(`Unknown argument: ${arg}`);
  }

  opts.projectRoot = path.resolve(opts.projectRoot);
  return opts;
}

function main() {
  try {
    const opts = parseArgs(process.argv.slice(2));
    const result = writeRegressionDashboard(opts.projectRoot);
    process.stdout.write(`${JSON.stringify(result.summary, null, opts.pretty ? 2 : 0)}\n`);
    process.exit(result.summary.failCount > 0 ? 1 : 0);
  } catch (err) {
    console.error(`[ERROR] ${err.message}`);
    process.exit(2);
  }
}

if (require.main === module) {
  main();
}
