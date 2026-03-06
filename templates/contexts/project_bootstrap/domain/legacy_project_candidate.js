function normalizeSlashes(value) {
  return String(value || "").replace(/\\/g, "/");
}

const DEFAULT_SKIP_DIRS = Object.freeze([
  "templates",
  ".git",
  ".agent",
  "tools",
  "Project",
  "docs",
  "tests",
  "node_modules",
]);

function createLegacyProjectCandidate(name, absPath) {
  return Object.freeze({
    name: String(name || "").trim(),
    absPath: normalizeSlashes(absPath),
  });
}

module.exports = {
  DEFAULT_SKIP_DIRS,
  createLegacyProjectCandidate,
  normalizeSlashes,
};
