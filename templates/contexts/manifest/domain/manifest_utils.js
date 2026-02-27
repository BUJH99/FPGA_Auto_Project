const fs = require("fs");

function normalizeSlashes(p) {
  return String(p || "").replace(/\\/g, "/");
}

function ensureDir(dirPath) {
  if (!fs.existsSync(dirPath)) {
    fs.mkdirSync(dirPath, { recursive: true });
  }
}

function sortUnique(items) {
  return [...new Set(items)].sort((a, b) => a.localeCompare(b));
}

function isNonEmptyString(v) {
  return typeof v === "string" && v.trim() !== "";
}

function isStringArray(v) {
  return Array.isArray(v) && v.every((x) => typeof x === "string");
}

module.exports = {
  normalizeSlashes,
  ensureDir,
  sortUnique,
  isNonEmptyString,
  isStringArray,
};
