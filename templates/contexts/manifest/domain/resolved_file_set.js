const { sortUnique, normalizeSlashes } = require("./manifest_utils");

function normalizeRows(rows) {
  return sortUnique(
    (rows || [])
      .map((row) => (typeof row === "string" ? normalizeSlashes(row.trim()) : ""))
      .filter(Boolean)
  );
}

function createResolvedFileSet(payload = {}) {
  return {
    src_files: normalizeRows(payload.src_files),
    tb_files: normalizeRows(payload.tb_files),
    inc_dirs: normalizeRows(payload.inc_dirs),
    xdc_files: normalizeRows(payload.xdc_files),
  };
}

module.exports = {
  createResolvedFileSet,
};
