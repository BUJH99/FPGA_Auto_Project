const fs = require("fs");
const path = require("path");
const { normalizeSlashes } = require("../domain/run_contracts");

function ensureDir(dirPath) {
  if (!fs.existsSync(dirPath)) {
    fs.mkdirSync(dirPath, { recursive: true });
  }
}

function readJsonFile(filePath, fallback = null) {
  const abs = path.resolve(filePath);
  if (!fs.existsSync(abs)) {
    return fallback;
  }

  const raw = fs.readFileSync(abs, "utf8");
  return JSON.parse(raw);
}

function writeJsonFile(filePath, payload) {
  const abs = path.resolve(filePath);
  ensureDir(path.dirname(abs));
  fs.writeFileSync(abs, `${JSON.stringify(payload, null, 2)}\n`, "utf8");
  return normalizeSlashes(abs);
}

module.exports = {
  ensureDir,
  readJsonFile,
  writeJsonFile,
};
