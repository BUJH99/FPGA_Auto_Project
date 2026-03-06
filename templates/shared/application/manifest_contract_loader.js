const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

function normalizeSlashes(value) {
  return String(value || "").replace(/\\/g, "/");
}

function sortUnique(rows) {
  return Array.from(
    new Set((rows || []).map((row) => normalizeSlashes(row)).filter(Boolean))
  ).sort((a, b) => a.localeCompare(b));
}

function toAbsRows(base, rows) {
  return sortUnique((rows || []).map((row) => path.resolve(base, row)));
}

function parentDirs(rows) {
  return sortUnique((rows || []).map((row) => path.dirname(row)));
}

function formatErrorCodes(errors) {
  const codes = (errors || []).map((row) => row && row.code).filter(Boolean);
  return codes.length > 0 ? codes.join(",") : "unknown_error";
}

function parseManifestResultPayload(raw, sourceLabel) {
  let parsed = null;
  try {
    parsed = JSON.parse(String(raw || ""));
  } catch (err) {
    throw new Error(`manifest_contract_parse_failed:${sourceLabel}:${err.message}`);
  }

  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`manifest_contract_type_error:${sourceLabel}`);
  }

  return parsed;
}

function readManifestResultFromJson(manifestJsonPath) {
  const abs = path.resolve(manifestJsonPath);
  const raw = fs.readFileSync(abs, "utf8");
  return parseManifestResultPayload(raw, abs);
}

function runManifestResolveCli(projectRoot) {
  const root = path.resolve(projectRoot || process.cwd());
  const cliPath = path.resolve(
    __dirname,
    "..",
    "..",
    "contexts",
    "manifest",
    "adapters",
    "cli",
    "manifest_resolve_cli.js"
  );
  const args = [cliPath, "--project", root, "--json"];

  try {
    const stdout = execFileSync(process.execPath, args, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    return parseManifestResultPayload(stdout, cliPath);
  } catch (err) {
    const stdout = String(err && err.stdout ? err.stdout : "");
    if (stdout.trim()) {
      return parseManifestResultPayload(stdout, cliPath);
    }
    throw new Error(`manifest_contract_resolution_failed:${err.message}`);
  }
}

function loadManifestResult(projectRootInput, manifestJsonPath = "") {
  if (manifestJsonPath) {
    return readManifestResultFromJson(manifestJsonPath);
  }
  return runManifestResolveCli(projectRootInput);
}

function createSnapshotView(result) {
  const config = result && result.config && typeof result.config === "object" ? result.config : {};
  const project = config.project && typeof config.project === "object" ? config.project : {};
  const hdl = config.hdl && typeof config.hdl === "object" ? config.hdl : {};
  return {
    config,
    projectName: typeof project.name === "string" ? project.name : "",
    top: typeof hdl.top === "string" ? hdl.top : "",
  };
}

function resolveProjectContext(projectRootInput, manifestJsonPath = "") {
  const projectRoot = path.resolve(projectRootInput || process.cwd());
  const result = loadManifestResult(projectRoot, manifestJsonPath);
  const resolved = result && result.resolved && typeof result.resolved === "object" ? result.resolved : {};
  const errors = Array.isArray(result && result.errors) ? result.errors : [];
  const snapshot = createSnapshotView(result || {});

  return {
    ok: errors.length === 0,
    result,
    snapshot,
    catalog: {
      src_files: Array.isArray(resolved.src_files) ? [...resolved.src_files] : [],
      tb_files: Array.isArray(resolved.tb_files) ? [...resolved.tb_files] : [],
      inc_dirs: Array.isArray(resolved.inc_dirs) ? [...resolved.inc_dirs] : [],
      xdc_files: Array.isArray(resolved.xdc_files) ? [...resolved.xdc_files] : [],
    },
  };
}

function loadStrictManifestContext(projectRootInput, manifestJsonPath = "") {
  if (!manifestJsonPath) {
    throw new Error("--manifest-json is required in strict mode");
  }

  const projectRoot = path.resolve(projectRootInput || process.cwd());
  const manifestJsonAbs = path.resolve(manifestJsonPath);
  const result = loadManifestResult(projectRoot, manifestJsonAbs);
  const errors = Array.isArray(result && result.errors) ? result.errors : [];

  if (errors.length > 0) {
    throw new Error(`manifest_has_errors:${formatErrorCodes(errors)}`);
  }

  const snapshot = createSnapshotView(result || {});
  if (!snapshot) {
    throw new Error("manifest_snapshot_unavailable");
  }

  const resolved = result && result.resolved && typeof result.resolved === "object" ? result.resolved : {};
  const srcFiles = toAbsRows(projectRoot, resolved.src_files);
  const tbFiles = toAbsRows(projectRoot, resolved.tb_files);
  const incDirsFromManifest = toAbsRows(projectRoot, resolved.inc_dirs);
  const xdcFiles = toAbsRows(projectRoot, resolved.xdc_files);
  const incDirs = sortUnique([
    ...incDirsFromManifest,
    ...parentDirs(srcFiles),
    ...parentDirs(tbFiles),
  ]);

  return {
    projectRoot,
    manifestJsonPath: normalizeSlashes(manifestJsonAbs),
    snapshot,
    result,
    srcFiles,
    tbFiles,
    incDirs,
    xdcFiles,
  };
}

module.exports = {
  loadManifestResult,
  loadStrictManifestContext,
  resolveProjectContext,
};
