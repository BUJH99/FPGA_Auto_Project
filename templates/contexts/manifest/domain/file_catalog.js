const path = require("path");
const { sortUnique, normalizeSlashes } = require("./manifest_utils");

function normalizeArray(rows) {
  if (!Array.isArray(rows)) return Object.freeze([]);
  const filtered = rows
    .map((row) => (typeof row === "string" ? normalizeSlashes(row.trim()) : ""))
    .filter((row) => row.length > 0);
  return Object.freeze(sortUnique(filtered));
}

class FileCatalog {
  constructor(resolved = {}) {
    this.src_files = normalizeArray(resolved.src_files);
    this.tb_files = normalizeArray(resolved.tb_files);
    this.inc_dirs = normalizeArray(resolved.inc_dirs);
    this.xdc_files = normalizeArray(resolved.xdc_files);
    Object.freeze(this);
  }

  static fromResolved(resolved = {}) {
    return new FileCatalog(resolved);
  }

  toJSON() {
    return {
      src_files: [...this.src_files],
      tb_files: [...this.tb_files],
      inc_dirs: [...this.inc_dirs],
      xdc_files: [...this.xdc_files],
    };
  }

  toAbsolute(projectRoot) {
    const base = path.resolve(projectRoot || process.cwd());
    const toAbs = (rows) => rows.map((row) => normalizeSlashes(path.resolve(base, row)));

    return {
      src_files: toAbs(this.src_files),
      tb_files: toAbs(this.tb_files),
      inc_dirs: toAbs(this.inc_dirs),
      xdc_files: toAbs(this.xdc_files),
    };
  }

  deriveIncludeDirsFromSources() {
    const dirs = new Set(this.inc_dirs);

    const addParent = (rows) => {
      for (const row of rows) {
        const parent = normalizeSlashes(path.dirname(row));
        if (parent && parent !== ".") {
          dirs.add(parent);
        }
      }
    };

    addParent(this.src_files);
    addParent(this.tb_files);

    return sortUnique([...dirs]);
  }

  assertNonEmpty(kind) {
    const allowed = ["src_files", "tb_files", "inc_dirs", "xdc_files"];
    if (!allowed.includes(kind)) {
      throw new Error(`Unknown file catalog kind: ${kind}`);
    }
    const rows = this[kind] || [];
    if (rows.length === 0) {
      const err = new Error(`Manifest resolved list is empty: ${kind}`);
      err.code = "manifest_resolved_empty";
      err.path = kind;
      throw err;
    }
    return rows;
  }
}

module.exports = {
  FileCatalog,
};
