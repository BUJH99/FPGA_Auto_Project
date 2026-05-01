const fs = require("fs");
const path = require("path");
const YAML = require("yaml");
const { readJsonFile } = require("../../../shared/application/json_file_service");
const { loadManifestResult } = require("../../../shared/application/manifest_contract_loader");

function isPlainObject(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function normalizeSlashes(value) {
  return String(value || "").replace(/\\/g, "/");
}

function uniqueStrings(values) {
  return Array.from(new Set((values || [])
    .map((value) => normalizeSlashes(String(value || "").trim()))
    .filter(Boolean)));
}

function pathIsInside(child, parent) {
  const rel = path.relative(path.resolve(parent), path.resolve(child));
  return rel === "" || Boolean(rel && !rel.startsWith("..") && !path.isAbsolute(rel));
}

function projectRelativePath(projectRoot, rawPath) {
  const value = String(rawPath || "").trim();
  if (!value) return "";
  const normalized = normalizeSlashes(value);
  if (!path.isAbsolute(value)) return normalized;
  if (!pathIsInside(value, projectRoot)) return normalized;
  return normalizeSlashes(path.relative(path.resolve(projectRoot), path.resolve(value)));
}

function manifestApplicationFromPlan(projectRoot, app) {
  const row = {
    name: String(app.name || "").trim(),
    template: String(app.template || "empty_application").trim() || "empty_application",
    domain: String(app.domain || "").trim(),
    sources: uniqueStrings(app.sourceGlobs || []),
    includes: uniqueStrings((app.includes || []).map((item) => projectRelativePath(projectRoot, item))),
    target: String(app.target || "hw").trim() || "hw",
  };
  const linkerScript = projectRelativePath(projectRoot, app.linkerScript || "");
  if (linkerScript) row.linker_script = linkerScript;
  if (!row.domain) delete row.domain;
  if (row.sources.length === 0) delete row.sources;
  if (row.includes.length === 0) delete row.includes;
  return row;
}

function setMissingField(target, key, value) {
  if (value === undefined || value === null || value === "") return false;
  if (Array.isArray(value) && value.length === 0) return false;
  if (!Object.prototype.hasOwnProperty.call(target, key)) {
    target[key] = value;
    return true;
  }
  if (Array.isArray(value) && Array.isArray(target[key]) && target[key].length === 0) {
    target[key] = value;
    return true;
  }
  if (typeof value === "string" && typeof target[key] === "string" && target[key].trim() === "") {
    target[key] = value;
    return true;
  }
  return false;
}

function mergeApplication(target, defaults) {
  let changed = false;
  for (const key of ["template", "domain", "sources", "includes", "linker_script", "target"]) {
    changed = setMissingField(target, key, defaults[key]) || changed;
  }
  return changed;
}

function successfulApplicationNames(result) {
  if (!result || String(result.status || "").toLowerCase() !== "ok") return [];
  const outputs = isPlainObject(result.outputs) ? result.outputs : {};
  return uniqueStrings(outputs.applicationNames || []);
}

function selectedApplications(plan, result) {
  const allowed = new Set(successfulApplicationNames(result).map((name) => name.toLowerCase()));
  const rows = Array.isArray(plan.selectedApplications) ? plan.selectedApplications : [];
  if (allowed.size === 0) return rows;
  return rows.filter((app) => allowed.has(String(app.name || "").toLowerCase()));
}

function ensureVitisApplications(config) {
  if (!isPlainObject(config)) {
    throw new Error("fpga_auto.yml root must be an object");
  }
  if (!Object.prototype.hasOwnProperty.call(config, "vitis")) {
    config.vitis = { applications: [] };
  }
  if (!isPlainObject(config.vitis)) {
    throw new Error("fpga_auto.yml field vitis must be an object to sync Vitis applications");
  }
  if (!Object.prototype.hasOwnProperty.call(config.vitis, "applications")) {
    config.vitis.applications = [];
  }
  if (!Array.isArray(config.vitis.applications)) {
    throw new Error("fpga_auto.yml field vitis.applications must be an array to sync Vitis applications");
  }
  return config.vitis.applications;
}

function syncVitisApplications({
  projectRoot,
  planPath,
  resultPath,
} = {}) {
  const root = path.resolve(projectRoot || process.cwd());
  const manifestPath = path.join(root, "fpga_auto.yml");
  const plan = readJsonFile(planPath, {});
  const result = readJsonFile(resultPath, {});
  if (String(plan.step || "") !== "create_application") {
    return { status: "skipped", reason: "not_create_application", added: [], updated: [] };
  }
  if (String(result.status || "").toLowerCase() !== "ok") {
    return { status: "skipped", reason: "result_not_ok", added: [], updated: [] };
  }

  const appsToSync = selectedApplications(plan, result)
    .map((app) => manifestApplicationFromPlan(root, app))
    .filter((app) => app.name);
  if (appsToSync.length === 0) {
    return { status: "skipped", reason: "no_applications", added: [], updated: [] };
  }

  const raw = fs.readFileSync(manifestPath, "utf8");
  const parsed = YAML.parse(raw);
  const hadVitisSection = isPlainObject(parsed) && Object.prototype.hasOwnProperty.call(parsed, "vitis");
  const applications = ensureVitisApplications(parsed);
  const added = [];
  const updated = [];

  for (const app of appsToSync) {
    const existing = applications.find((entry) =>
      isPlainObject(entry) && String(entry.name || "").trim().toLowerCase() === app.name.toLowerCase()
    );
    if (!existing) {
      applications.push(app);
      added.push(app.name);
      continue;
    }
    if (mergeApplication(existing, app)) {
      updated.push(app.name);
    }
  }

  if (added.length === 0 && updated.length === 0) {
    return { status: "current", manifestPath: normalizeSlashes(manifestPath), added, updated };
  }

  const manifestText = hadVitisSection
    ? YAML.stringify(parsed)
    : `${raw.replace(/\s*$/g, "")}\n${YAML.stringify({ vitis: parsed.vitis })}`;
  fs.writeFileSync(manifestPath, manifestText, "utf8");

  const resolved = loadManifestResult(root);
  const errors = Array.isArray(resolved.errors) ? resolved.errors : [];
  if (errors.length > 0) {
    throw new Error(`manifest_validation_failed:${errors.map((entry) => entry.code).join(",")}`);
  }

  return {
    status: "updated",
    manifestPath: normalizeSlashes(manifestPath),
    added,
    updated,
  };
}

module.exports = {
  manifestApplicationFromPlan,
  syncVitisApplications,
};
