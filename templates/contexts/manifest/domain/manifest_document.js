const fs = require("fs");
const path = require("path");
const YAML = require("yaml");
const { MANIFEST_FILENAME } = require("./manifest_constants");
const {
  isNonEmptyString,
  isStringArray,
  normalizeSlashes,
} = require("./manifest_utils");
const { addError, addWarning } = require("./manifest_result");

function validateManifestShape(result, config) {
  const requiredChecks = [
    {
      ok: config && Object.prototype.hasOwnProperty.call(config, "version"),
      path: "version",
      message: "Missing required field: version",
    },
    {
      ok: config && config.project && Object.prototype.hasOwnProperty.call(config.project, "name"),
      path: "project.name",
      message: "Missing required field: project.name",
    },
    {
      ok: config && config.hdl && Object.prototype.hasOwnProperty.call(config.hdl, "top"),
      path: "hdl.top",
      message: "Missing required field: hdl.top",
    },
    {
      ok: config && config.hdl && Object.prototype.hasOwnProperty.call(config.hdl, "src_globs"),
      path: "hdl.src_globs",
      message: "Missing required field: hdl.src_globs",
    },
    {
      ok: config && config.hdl && Object.prototype.hasOwnProperty.call(config.hdl, "tb_globs"),
      path: "hdl.tb_globs",
      message: "Missing required field: hdl.tb_globs",
    },
  ];

  for (const check of requiredChecks) {
    if (!check.ok) {
      addError(result, "manifest_required_field", check.message, check.path);
    }
  }

  if (result.errors.length > 0) {
    return false;
  }

  if (!isNonEmptyString(String(config.version))) {
    addError(result, "manifest_type_error", "Field version must be a non-empty scalar", "version");
  }
  if (!isNonEmptyString(config.project.name)) {
    addError(result, "manifest_type_error", "Field project.name must be a non-empty string", "project.name");
  }
  if (!isNonEmptyString(config.hdl.top)) {
    addError(result, "manifest_type_error", "Field hdl.top must be a non-empty string", "hdl.top");
  }

  if (!isStringArray(config.hdl.src_globs) || config.hdl.src_globs.length === 0) {
    addError(result, "manifest_type_error", "Field hdl.src_globs must be a non-empty string array", "hdl.src_globs");
  }
  if (!isStringArray(config.hdl.tb_globs) || config.hdl.tb_globs.length === 0) {
    addError(result, "manifest_type_error", "Field hdl.tb_globs must be a non-empty string array", "hdl.tb_globs");
  }

  const optionalArrays = ["inc_globs", "xdc_globs", "exclude_globs"];
  for (const field of optionalArrays) {
    if (Object.prototype.hasOwnProperty.call(config.hdl, field) && !isStringArray(config.hdl[field])) {
      addError(result, "manifest_type_error", `Field hdl.${field} must be a string array`, `hdl.${field}`);
    }
  }

  return result.errors.length === 0;
}

function loadManifestDocument(projectRootAbs, result) {
  const manifestPath = path.join(projectRootAbs, MANIFEST_FILENAME);

  if (!fs.existsSync(manifestPath)) {
    addError(
      result,
      "manifest_missing",
      `Required manifest file is missing: ${MANIFEST_FILENAME}`,
      MANIFEST_FILENAME
    );
    return null;
  }

  result.manifest_path = normalizeSlashes(manifestPath);

  let parsed = null;
  try {
    const raw = fs.readFileSync(manifestPath, "utf8");
    parsed = YAML.parse(raw);
  } catch (err) {
    addError(result, "manifest_parse_error", err.message, MANIFEST_FILENAME);
    return null;
  }

  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    addError(result, "manifest_type_error", "Manifest root must be an object", MANIFEST_FILENAME);
    return null;
  }

  result.config = parsed;

  if (!validateManifestShape(result, parsed)) {
    return null;
  }

  for (const section of ["sim", "vivado", "report"]) {
    if (Object.prototype.hasOwnProperty.call(parsed, section)) {
      addWarning(
        result,
        "reserved_section_ignored",
        `Section ${section}.* is reserved in v0 and ignored by resolver`,
        section
      );
    }
  }

  return parsed;
}

module.exports = {
  loadManifestDocument,
};
