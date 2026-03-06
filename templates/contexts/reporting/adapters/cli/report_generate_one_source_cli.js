const path = require("path");
const { loadStrictManifestContext } = require("../../../../shared/application/manifest_contract_loader");
const {
  createOneSourceReportContext,
  listOneSourceModules,
  generateOneSourceReport,
} = require("../../application/report_one_source_service");

function parseModuleList(value) {
  if (!value) return null;
  const list = value
    .split(",")
    .map((item) => item.trim())
    .filter(Boolean);
  if (list.length === 0) return null;
  return Array.from(new Set(list));
}

function parseCliArgs(argv) {
  let projectArg = null;
  let listModules = false;
  let moduleListRaw = null;
  let manifestJsonArg = null;

  for (let i = 0; i < argv.length; i += 1) {
    const arg = String(argv[i] || "");
    if (arg === "--list-modules") {
      listModules = true;
      continue;
    }
    if (arg.startsWith("--manifest-json=")) {
      manifestJsonArg = arg.slice("--manifest-json=".length);
      continue;
    }
    if (arg === "--manifest-json") {
      i += 1;
      if (i >= argv.length) {
        throw new Error("--manifest-json requires a value");
      }
      manifestJsonArg = argv[i];
      continue;
    }
    if (arg.startsWith("--modules=")) {
      moduleListRaw = arg.slice("--modules=".length);
      continue;
    }
    if (!arg.startsWith("--") && !projectArg) {
      projectArg = arg;
      continue;
    }
    throw new Error(`Unknown argument: ${arg}`);
  }

  if (!manifestJsonArg) {
    throw new Error("--manifest-json=<path> is required in strict mode");
  }

  return {
    projectRoot: projectArg ? path.resolve(projectArg) : process.cwd(),
    listModules,
    selectedModuleNames: parseModuleList(moduleListRaw),
    manifestJsonPath: path.resolve(manifestJsonArg),
  };
}

function main() {
  try {
    const cli = parseCliArgs(process.argv.slice(2));
    const manifestContext = loadStrictManifestContext(cli.projectRoot, cli.manifestJsonPath);
    const context = createOneSourceReportContext({
      projectRoot: cli.projectRoot,
      sourceFiles: manifestContext.srcFiles || [],
      tbFiles: manifestContext.tbFiles || [],
    });

    if (cli.listModules) {
      listOneSourceModules(context).forEach((moduleName) => {
        console.log(moduleName);
      });
      return;
    }

    const result = generateOneSourceReport({
      context,
      manifestJsonPath: cli.manifestJsonPath,
      selectedModuleNames: cli.selectedModuleNames,
      generateHdlIndex: true,
    });

    if (result.unknownModules.length > 0) {
      console.warn(`[WARN] ignored unknown modules: ${result.unknownModules.join(", ")}`);
    }
    result.warnings
      .filter((warning) => warning.startsWith("hdl_index_generation_skipped:"))
      .forEach((warning) => console.warn(`[WARN] ${warning.slice("hdl_index_generation_skipped:".length).trim()}`));

    console.log(`[SUCCESS] report.md generated: ${result.reportMdPath}`);
    console.log(`[INFO] modules(all): ${result.moduleCountAll}`);
    console.log(`[INFO] modules(sub-block): ${result.moduleCountSelected}`);
    console.log(`[INFO] css: ${result.githubCssPath}`);
    console.log(`[INFO] summary: ${result.summaryPath}`);
    if (result.hdlIndexPath) {
      console.log(`[INFO] hdl index: ${result.hdlIndexPath}`);
    }
  } catch (err) {
    if (Array.isArray(err.unknownModules) && err.unknownModules.length > 0) {
      console.warn(`[WARN] ignored unknown modules: ${err.unknownModules.join(", ")}`);
    }
    console.error(`[ERROR] ${err.message}`);
    process.exit(1);
  }
}

if (require.main === module) {
  main();
}

module.exports = {
  parseCliArgs,
  main,
};
