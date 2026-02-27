const fs = require("fs");
const path = require("path");
const { FileCatalog } = require("./file_catalog");
const { normalizeSlashes } = require("./manifest_utils");

function assertObject(value, name) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`Manifest snapshot field must be object: ${name}`);
  }
}

class ManifestSnapshot {
  constructor(payload, sourcePath = "") {
    assertObject(payload, "root");

    if (payload.manifest_path !== null && typeof payload.manifest_path !== "string") {
      throw new Error("Manifest snapshot field must be string|null: manifest_path");
    }
    if (typeof payload.project_root !== "string" || payload.project_root.trim() === "") {
      throw new Error("Manifest snapshot field must be non-empty string: project_root");
    }

    assertObject(payload.config || {}, "config");
    assertObject(payload.resolved || {}, "resolved");

    this.sourcePath = sourcePath ? normalizeSlashes(path.resolve(sourcePath)) : "";
    this.payload = payload;
    this.manifestPath = payload.manifest_path;
    this.projectRoot = normalizeSlashes(payload.project_root);
    this.config = payload.config || {};
    this.catalog = FileCatalog.fromResolved(payload.resolved || {});
    this.errors = Array.isArray(payload.errors) ? payload.errors : [];
    this.warnings = Array.isArray(payload.warnings) ? payload.warnings : [];

    Object.freeze(this.errors);
    Object.freeze(this.warnings);
    Object.freeze(this.config);
    Object.freeze(this);
  }

  static fromFile(snapshotPath) {
    const abs = path.resolve(snapshotPath);
    const raw = fs.readFileSync(abs, "utf8");
    const parsed = JSON.parse(raw);
    return new ManifestSnapshot(parsed, abs);
  }

  static fromResult(result) {
    return new ManifestSnapshot(result);
  }

  get projectName() {
    if (this.config && this.config.project && typeof this.config.project.name === "string") {
      return this.config.project.name;
    }
    return "";
  }

  get top() {
    if (this.config && this.config.hdl && typeof this.config.hdl.top === "string") {
      return this.config.hdl.top;
    }
    return "";
  }

  hasErrors() {
    return this.errors.length > 0;
  }

  toResult() {
    return {
      manifest_path: this.manifestPath,
      project_root: this.projectRoot,
      config: this.config,
      resolved: this.catalog.toJSON(),
      errors: [...this.errors],
      warnings: [...this.warnings],
    };
  }
}

module.exports = {
  ManifestSnapshot,
};
