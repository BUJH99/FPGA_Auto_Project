const path = require("path");
const readline = require("readline");
const { loadStrictManifestContext } = require("../../../../shared/application/manifest_contract_loader");
const {
  createDocumentationContext,
  listDocumentationCandidates,
  selectDocumentationCandidates,
  generateDocumentationArtifacts,
} = require("../../application/report_doc_generation_service");

function usageAndExit() {
  console.error("Usage: node generate_doc.js <project_root> --manifest-json <path> [--all] [--select <1,2,3>]");
  process.exit(1);
}

function parseArgs(argv) {
  let projectArg = "";
  let manifestJsonArg = "";
  let selectArg = "";
  let selectAll = false;

  for (let i = 0; i < argv.length; i += 1) {
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
    if (arg === "--all") {
      selectAll = true;
      continue;
    }
    if (arg === "--select") {
      i += 1;
      if (i >= argv.length) usageAndExit();
      selectArg = argv[i];
      continue;
    }
    if (arg.startsWith("--select=")) {
      selectArg = arg.slice("--select=".length);
      continue;
    }
    if (arg.startsWith("--")) {
      usageAndExit();
    }
    if (!projectArg) {
      projectArg = arg;
      continue;
    }
    usageAndExit();
  }

  if (!manifestJsonArg) usageAndExit();
  return {
    projectRoot: projectArg ? path.resolve(projectArg) : process.cwd(),
    manifestJsonPath: path.resolve(manifestJsonArg),
    selectArg,
    selectAll,
  };
}

function main() {
  const cli = parseArgs(process.argv.slice(2));
  let manifestContext = null;
  try {
    manifestContext = loadStrictManifestContext(cli.projectRoot, cli.manifestJsonPath);
  } catch (err) {
    console.error(`[ERROR] ${err.message}`);
    process.exit(1);
    return;
  }

  const sourceFiles = (manifestContext.srcFiles || [])
    .filter((filePath) => /\.(v|sv)$/i.test(filePath))
    .sort((a, b) => a.localeCompare(b));
  const context = createDocumentationContext({
    projectRoot: cli.projectRoot,
    sourceFiles,
  });
  const candidates = listDocumentationCandidates(context);

  console.log(`Target Project Root: ${cli.projectRoot}`);
  console.log("Searching manifest-resolved HDL source files (.v/.sv)...");
  if (candidates.length === 0) {
    console.error("No manifest-resolved HDL source files found.");
    process.exit(1);
    return;
  }

  console.log("\nFound the following HDL files:");
  candidates.forEach((entry, index) => {
    console.log(`[${index + 1}] ${entry.relPath}`);
  });
  console.log("");

  const runGeneration = (selectionInput) => {
    const selectedEntries = selectDocumentationCandidates(selectionInput, candidates);
    if (selectedEntries.length === 0) {
      console.log("No valid files selected.");
      process.exit(1);
      return;
    }

    console.log(`\nGenerating docs for ${selectedEntries.length} files...`);
    const result = generateDocumentationArtifacts(context, selectedEntries, cli.manifestJsonPath);
    result.docItems.forEach((item) => {
      console.log(`Generated: ${item.docPath}`);
    });
    if (result.fsmIndexPath) {
      console.log(`Generated: ${result.fsmIndexPath}`);
    }
    console.log(`Summary: ${result.summaryPath}`);
    console.log("\nDone.");
    process.exit(0);
  };

  if (cli.selectAll) {
    runGeneration("all");
    return;
  }
  if (cli.selectArg) {
    runGeneration(cli.selectArg);
    return;
  }

  const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout,
  });
  rl.question('Enter file numbers to generate docs for (e.g., "1,3,5" or "all"): ', (answer) => {
    rl.close();
    runGeneration(answer);
  });
}

if (require.main === module) {
  main();
}
