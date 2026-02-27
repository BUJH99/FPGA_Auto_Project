const path = require("path");
const { resolveProjectContextFromManifestJson } = require("./manifest_context_service");

function normalizeSlashes(p) {
  return String(p || "").replace(/\\/g, "/");
}

function sortUnique(rows) {
  return Array.from(new Set(rows.map((row) => normalizeSlashes(row)))).sort((a, b) =>
    a.localeCompare(b)
  );
}

function toAbsRows(base, rows) {
  return sortUnique((rows || []).map((row) => path.resolve(base, row)));
}

function parentDirs(rows) {
  const dirs = [];
  for (const filePath of rows || []) {
    dirs.push(path.dirname(filePath));
  }
  return sortUnique(dirs);
}

function formatErrorCodes(errors) {
  const codes = (errors || []).map((row) => row && row.code).filter(Boolean);
  return codes.length > 0 ? codes.join(",") : "unknown_error";
}

function loadStrictManifestContext(projectRootInput, manifestJsonPath) {
  if (!manifestJsonPath) {
    throw new Error("--manifest-json is required in strict mode");
  }

  const projectRoot = path.resolve(projectRootInput || process.cwd());
  const manifestJsonAbs = path.resolve(manifestJsonPath);
  const ctx = resolveProjectContextFromManifestJson(manifestJsonAbs);
  const result = ctx.result || {};
  const errors = Array.isArray(result.errors) ? result.errors : [];

  if (errors.length > 0) {
    throw new Error(`manifest_has_errors:${formatErrorCodes(errors)}`);
  }
  if (!ctx.snapshot) {
    throw new Error("manifest_snapshot_unavailable");
  }

  const resolved = result.resolved || {};
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
    snapshot: ctx.snapshot,
    result,
    srcFiles,
    tbFiles,
    incDirs,
    xdcFiles,
  };
}

module.exports = {
  loadStrictManifestContext,
};
