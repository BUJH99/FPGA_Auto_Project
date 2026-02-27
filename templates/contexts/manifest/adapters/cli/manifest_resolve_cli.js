const fs = require("fs");
const path = require("path");

const {
  EXIT_OK,
  EXIT_RUNTIME,
  EXIT_INPUT,
} = require("../../domain/manifest_constants");
const { normalizeSlashes } = require("../../domain/manifest_utils");
const {
  resolveManifestContext,
  deriveExitCode,
  writeJson,
  writeManifestLists,
} = require("../../application/manifest_context_service");
const { createResult, addError } = require("../../domain/manifest_result");

class CliError extends Error {
  constructor(message, exitCode, code = "usage_error", refPath = undefined) {
    super(message);
    this.name = "CliError";
    this.exitCode = exitCode;
    this.code = code;
    this.refPath = refPath;
  }
}

function usage() {
  return [
    "Usage:",
    "  node templates/contexts/manifest/adapters/cli/manifest_resolve_cli.js --project <dir> [--json] [--write <path>] [--emit-lists <dir>]",
    "  node templates/contexts/manifest/adapters/cli/manifest_resolve_cli.js --selftest",
  ].join("\n");
}

function parseArgs(argv) {
  const opts = {
    project: null,
    json: false,
    write: null,
    emitLists: null,
    selftest: false,
  };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--project") {
      i += 1;
      if (i >= argv.length) {
        throw new CliError("--project requires a value", EXIT_INPUT, "usage_error");
      }
      opts.project = argv[i];
      continue;
    }
    if (arg.startsWith("--project=")) {
      opts.project = arg.slice("--project=".length);
      continue;
    }
    if (arg === "--json") {
      opts.json = true;
      continue;
    }
    if (arg === "--write") {
      i += 1;
      if (i >= argv.length) {
        throw new CliError("--write requires a value", EXIT_INPUT, "usage_error");
      }
      opts.write = argv[i];
      continue;
    }
    if (arg.startsWith("--write=")) {
      opts.write = arg.slice("--write=".length);
      continue;
    }
    if (arg === "--emit-lists") {
      i += 1;
      if (i >= argv.length) {
        throw new CliError("--emit-lists requires a value", EXIT_INPUT, "usage_error");
      }
      opts.emitLists = argv[i];
      continue;
    }
    if (arg.startsWith("--emit-lists=")) {
      opts.emitLists = arg.slice("--emit-lists=".length);
      continue;
    }
    if (arg === "--selftest") {
      opts.selftest = true;
      continue;
    }
    throw new CliError(`Unknown argument: ${arg}\n${usage()}`, EXIT_INPUT, "usage_error");
  }

  if (!opts.selftest && !opts.project) {
    throw new CliError(`--project is required\n${usage()}`, EXIT_INPUT, "usage_error");
  }

  return opts;
}

function isSorted(arr) {
  for (let i = 1; i < arr.length; i++) {
    if (arr[i - 1].localeCompare(arr[i]) > 0) return false;
  }
  return true;
}

function collectCodes(rows) {
  return new Set((rows || []).map((row) => row.code));
}

function compareExactArray(actual, expected) {
  if (!Array.isArray(actual) || !Array.isArray(expected)) return false;
  if (actual.length !== expected.length) return false;
  for (let i = 0; i < actual.length; i++) {
    if (actual[i] !== expected[i]) return false;
  }
  return true;
}

function runSelftest() {
  const root = path.resolve(__dirname, "..", "..", "..", "..", "..", "tests", "manifest_smoke");
  if (!fs.existsSync(root)) {
    console.error(`[SELFTEST] fixture root not found: ${normalizeSlashes(root)}`);
    return EXIT_RUNTIME;
  }

  const fixtures = fs
    .readdirSync(root, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .sort((a, b) => a.localeCompare(b));

  let pass = 0;
  let fail = 0;

  for (const name of fixtures) {
    const fixtureDir = path.join(root, name);
    const expectPath = path.join(fixtureDir, "expect.json");

    if (!fs.existsSync(expectPath)) {
      console.error(`[FAIL] ${name}: missing expect.json`);
      fail += 1;
      continue;
    }

    let expected = null;
    try {
      expected = JSON.parse(fs.readFileSync(expectPath, "utf8"));
    } catch (err) {
      console.error(`[FAIL] ${name}: invalid expect.json (${err.message})`);
      fail += 1;
      continue;
    }

    const result = resolveManifestContext(fixtureDir);
    const rc = deriveExitCode(result);
    const reasons = [];

    if (typeof expected.exit_code === "number" && expected.exit_code !== rc) {
      reasons.push(`exit_code expected=${expected.exit_code} actual=${rc}`);
    }

    const errorCodes = collectCodes(result.errors);
    for (const code of expected.error_codes || []) {
      if (!errorCodes.has(code)) {
        reasons.push(`missing error code: ${code}`);
      }
    }

    const warningCodes = collectCodes(result.warnings);
    for (const code of expected.warning_codes || []) {
      if (!warningCodes.has(code)) {
        reasons.push(`missing warning code: ${code}`);
      }
    }

    if (!isSorted(result.resolved.src_files || [])) {
      reasons.push("resolved.src_files is not lexicographically sorted");
    }
    if (!isSorted(result.resolved.tb_files || [])) {
      reasons.push("resolved.tb_files is not lexicographically sorted");
    }

    if (expected.resolved) {
      for (const key of ["src_files", "tb_files", "inc_dirs", "xdc_files"]) {
        if (
          Object.prototype.hasOwnProperty.call(expected.resolved, key) &&
          !compareExactArray(result.resolved[key], expected.resolved[key])
        ) {
          reasons.push(
            `resolved.${key} mismatch expected=${JSON.stringify(expected.resolved[key])} actual=${JSON.stringify(result.resolved[key])}`
          );
        }
      }
    }

    if (reasons.length > 0) {
      console.error(`[FAIL] ${name}`);
      for (const reason of reasons) {
        console.error(`  - ${reason}`);
      }
      fail += 1;
    } else {
      console.log(`[PASS] ${name}`);
      pass += 1;
    }
  }

  console.log(`[SELFTEST] total=${pass + fail} pass=${pass} fail=${fail}`);
  return fail > 0 ? EXIT_RUNTIME : EXIT_OK;
}

function main() {
  try {
    const opts = parseArgs(process.argv.slice(2));

    if (opts.selftest) {
      process.exit(runSelftest());
      return;
    }

    const result = resolveManifestContext(opts.project);

    if (opts.emitLists) {
      writeManifestLists(opts.emitLists, result);
    }

    if (opts.write) {
      writeJson(opts.write, result);
    }

    if (opts.json || (!opts.write && !opts.emitLists)) {
      process.stdout.write(JSON.stringify(result, null, 2));
    }

    process.exit(deriveExitCode(result));
  } catch (err) {
    if (err instanceof CliError) {
      const payload = createResult(process.cwd());
      addError(payload, err.code || "usage_error", err.message, err.refPath);
      process.stdout.write(JSON.stringify(payload, null, 2));
      process.exit(err.exitCode || EXIT_INPUT);
      return;
    }

    console.error(`[ERROR] ${err.message}`);
    process.exit(EXIT_RUNTIME);
  }
}

if (require.main === module) {
  main();
}

module.exports = {
  resolveManifest: resolveManifestContext,
  deriveExitCode,
  writeManifestLists,
};
