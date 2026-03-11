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

function boolWord(value) {
  return value ? "yes" : "no";
}

function formatToolState(toolName, toolInfo) {
  const info = toolInfo && typeof toolInfo === "object" ? toolInfo : {};
  const label = String(toolName || "").padEnd(6, " ");
  if (info.ok) {
    return `  - ${label}: OK (${String(info.resolved || info.command || "").trim() || "detected"})`;
  }
  return `  - ${label}: MISSING (${String(info.command || "").trim() || "unavailable"})`;
}

function formatWarnings(warnings) {
  if (!Array.isArray(warnings) || warnings.length === 0) {
    return ["  - none"];
  }
  return warnings.map((warning) => `  - ${String(warning || "").trim()}`);
}

function formatDoctorText(summary, summaryPath, extraWritePath = "") {
  const manifest = summary && summary.manifest && typeof summary.manifest === "object" ? summary.manifest : {};
  const resolved = summary && summary.resolved && typeof summary.resolved === "object" ? summary.resolved : {};
  const tbNaming = summary && summary.tbNaming && typeof summary.tbNaming === "object" ? summary.tbNaming : {};
  const paths = summary && summary.paths && typeof summary.paths === "object" ? summary.paths : {};
  const tools = summary && summary.tools && typeof summary.tools === "object" ? summary.tools : {};

  const lines = [
    "===============================================================================",
    "[DOCTOR] Toolkit Doctor Summary",
    "===============================================================================",
    `Project       : ${String(summary && summary.projectRoot ? summary.projectRoot : "")}`,
    `Status        : ${String(summary && summary.status ? summary.status : "unknown")} (ok=${boolWord(Boolean(summary && summary.ok))})`,
    `Manifest      : ${boolWord(Boolean(manifest.valid))}${manifest.path ? ` | ${String(manifest.path)}` : ""}`,
    `Top Module    : ${String(resolved.top || "-")}`,
    `Resolved      : src=${Number(resolved.srcCount || 0)} tb=${Number(resolved.tbCount || 0)} inc=${Number(resolved.incCount || 0)} xdc=${Number(resolved.xdcCount || 0)}`,
    `Top Present   : ${boolWord(Boolean(resolved.topModuleExists))}`,
    `TB Naming     : expected=${String(tbNaming.expectedBaseName || "-")} matched=${boolWord(Boolean(tbNaming.matched))}`,
    `Writable      : output_parent=${boolWord(Boolean(paths.outputParentWritable))} log_parent=${boolWord(Boolean(paths.logParentWritable))}`,
    "",
    "[Warnings]",
    ...formatWarnings(summary && summary.warnings),
    "",
    "[Tools]",
    formatToolState("node", tools.node),
    formatToolState("python", tools.python),
    formatToolState("vivado", tools.vivado),
    formatToolState("yosys", tools.yosys),
    "",
    "[Artifacts]",
    `  - summary : ${String(summaryPath || "")}`,
  ];

  if (extraWritePath) {
    lines.push(`  - copy    : ${String(extraWritePath)}`);
  }

  lines.push("===============================================================================");
  return `${lines.join("\n")}\n`;
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
    if (opts.json || opts.pretty) {
      process.stdout.write(`${JSON.stringify(written.summary, null, 2)}\n`);
    } else {
      process.stdout.write(formatDoctorText(written.summary, written.summaryPath, written.extraWritePath));
    }
    process.exit(written.summary.ok ? 0 : 1);
  } catch (err) {
    console.error(`[ERROR] ${err.message}`);
    process.exit(2);
  }
}

if (require.main === module) {
  main();
}
