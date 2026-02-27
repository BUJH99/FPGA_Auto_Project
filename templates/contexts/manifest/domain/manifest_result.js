const { normalizeSlashes } = require("./manifest_utils");

function createResult(projectRootAbs) {
  return {
    manifest_path: null,
    project_root: normalizeSlashes(projectRootAbs),
    config: {},
    resolved: {
      src_files: [],
      tb_files: [],
      inc_dirs: [],
      xdc_files: [],
    },
    errors: [],
    warnings: [],
  };
}

function addError(result, code, message, refPath) {
  const row = { code, message };
  if (refPath) row.path = refPath;
  result.errors.push(row);
}

function addWarning(result, code, message, refPath) {
  const row = { code, message };
  if (refPath) row.path = refPath;
  result.warnings.push(row);
}

module.exports = {
  createResult,
  addError,
  addWarning,
};
