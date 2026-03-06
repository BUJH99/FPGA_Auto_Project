const path = require("path");
const {
  runDoctor,
  writeDoctorArtifacts,
} = require("../../application/toolkit_doctor_service");
const { loadStrictManifestContext } = require("../../application/manifest_contract_loader");
const { runDoctorSelftest } = require("../../application/toolkit_doctor_selftest");

function parseArgs(argv) {
  const opts = {
    projectRoot: process.cwd(),
    manifestJsonPath: "",
    pretty: false,
    json: false,
    writePath: "",
    selftest: false,
  };

  for (let i = 0; i < argv.length; i++) {
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
    if (arg === "--write") {
      opts.writePath = argv[++i] || "";
      continue;
    }
    if (arg.startsWith("--write=")) {
      opts.writePath = arg.slice("--write=".length);
      continue;
    }
    if (arg === "--pretty") {
      opts.pretty = true;
      continue;
    }
    if (arg === "--json") {
      opts.json = true;
      continue;
    }
    if (arg === "--selftest") {
      opts.selftest = true;
      continue;
    }
    throw new Error(`Unknown argument: ${arg}`);
  }

  opts.projectRoot = path.resolve(opts.projectRoot);
  if (opts.manifestJsonPath) {
    opts.manifestJsonPath = path.resolve(opts.manifestJsonPath);
  }
  if (opts.writePath) {
    opts.writePath = path.resolve(opts.writePath);
  }
  return opts;
}

function main() {
  try {
    const opts = parseArgs(process.argv.slice(2));
    if (opts.selftest) {
      const result = runDoctorSelftest();
      process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
      process.exit(0);
      return;
    }

    const report = runDoctor(opts.projectRoot, opts.manifestJsonPath, loadStrictManifestContext);
    const written = writeDoctorArtifacts(opts.projectRoot, opts.manifestJsonPath, report, opts.writePath);
    process.stdout.write(`${JSON.stringify(written.summary, null, (opts.pretty || opts.json) ? 2 : 0)}\n`);
    process.exit(written.summary.ok ? 0 : 1);
  } catch (err) {
    console.error(`[ERROR] ${err.message}`);
    process.exit(2);
  }
}

if (require.main === module) {
  main();
}
