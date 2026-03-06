const fs = require("fs");
const path = require("path");
const { loadStrictManifestContext } = require("../../../../shared/application/manifest_contract_loader");
const { runSimulationReport } = require("../../application/simulation_execution_service");

function usageAndExit() {
  console.error("Usage: node generate_report.js <path_to_config.json> --manifest-json <path>");
  process.exit(1);
}

function parseArgs(argv) {
  let configArg = "";
  let manifestJsonArg = "";

  for (let i = 0; i < argv.length; i++) {
    const arg = String(argv[i] || "");
    if (arg === "--manifest-json") {
      i += 1;
      if (i >= argv.length) usageAndExit();
      manifestJsonArg = argv[i];
      continue;
    }
    if (arg.startsWith("--manifest-json=")) {
      manifestJsonArg = arg.slice("--manifest-json=".length);
      continue;
    }
    if (arg.startsWith("--")) {
      usageAndExit();
    }
    if (!configArg) {
      configArg = arg;
      continue;
    }
    usageAndExit();
  }

  if (!configArg || !manifestJsonArg) usageAndExit();
  return {
    configPath: path.resolve(configArg),
    manifestJsonPath: path.resolve(manifestJsonArg),
  };
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!fs.existsSync(args.configPath)) {
    console.error(`Error: Config file not found at ${args.configPath}`);
    process.exit(1);
  }

  const config = JSON.parse(fs.readFileSync(args.configPath, "utf8"));
  const projectRoot = path.dirname(args.configPath);

  let manifestContext = null;
  try {
    manifestContext = loadStrictManifestContext(projectRoot, args.manifestJsonPath);
  } catch (err) {
    console.error(`Error: ${err.message}`);
    process.exit(1);
  }

  try {
    const result = runSimulationReport({
      projectRoot,
      configPath: args.configPath,
      manifestJsonPath: args.manifestJsonPath,
      config,
      manifestContext,
    });

    if (result.mode === "regression") {
      console.log(`Regression summary: ${result.regressionSummaryPath}`);
      console.log(`Regression summary JSON: ${result.regressionSummaryJsonPath}`);
      console.log(`Regression dashboard: ${result.regressionDashboardPath}`);
      console.log(`Regression dashboard markdown: ${result.regressionDashboardMarkdownPath}`);
      console.log(`Run summary: ${result.runSummaryPath}`);
      console.log(`Run index: ${result.runIndexPath}`);
    } else {
      console.log(`SUCCESS: Report generated at: ${result.htmlFile}`);
      console.log(`Run summary: ${result.runSummaryPath}`);
      console.log(`Run index: ${result.runIndexPath}`);
    }

    process.exit(result.exitCode);
  } catch (err) {
    console.error(`Error: ${err.message}`);
    process.exit(1);
  }
}

if (require.main === module) {
  main();
}
