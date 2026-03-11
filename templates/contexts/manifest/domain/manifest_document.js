const fs = require("fs");
const path = require("path");
const YAML = require("yaml");
const { MANIFEST_FILENAME } = require("./manifest_constants");
const { normalizeSlashes } = require("./manifest_utils");
const { addError } = require("./manifest_result");
const { validateManifestShape } = require("./manifest_shape_validator");

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

  return parsed;
}

module.exports = {
  loadManifestDocument,
};
