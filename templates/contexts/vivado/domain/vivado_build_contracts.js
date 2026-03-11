const { normalizeSlashes } = require("../../../shared/domain/run_contracts");

function toNumber(value, fallback) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function normalizeStringList(rows) {
  if (!Array.isArray(rows)) return [];
  return Array.from(new Set(rows.map((row) => normalizeSlashes(String(row || "").trim())).filter(Boolean)))
    .sort((left, right) => left.localeCompare(right));
}

function createVivadoBuildRequest(payload = {}) {
  return {
    schemaVersion: 1,
    type: "vivado_build_request",
    createdAt: new Date().toISOString(),
    projectRoot: normalizeSlashes(payload.projectRoot || ""),
    manifestJsonPath: normalizeSlashes(payload.manifestJsonPath || ""),
    projectName: String(payload.projectName || ""),
    topModule: String(payload.topModule || ""),
    partNumber: String(payload.partNumber || ""),
    strategy: String(payload.strategy || "Default"),
    powerLimitW: toNumber(payload.powerLimitW, 2.5),
    autoProgram: Boolean(payload.autoProgram),
    noPause: Boolean(payload.noPause),
    resolvedSrcFiles: normalizeStringList(payload.resolvedSrcFiles),
    resolvedXdcFiles: normalizeStringList(payload.resolvedXdcFiles),
    resolvedIncDirs: normalizeStringList(payload.resolvedIncDirs),
    srcListPath: normalizeSlashes(payload.srcListPath || ""),
    xdcListPath: normalizeSlashes(payload.xdcListPath || ""),
    incListPath: normalizeSlashes(payload.incListPath || ""),
  };
}

function createVivadoBuildPlan(payload = {}) {
  return {
    schemaVersion: 1,
    type: "vivado_build_plan",
    createdAt: new Date().toISOString(),
    projectRoot: normalizeSlashes(payload.projectRoot || ""),
    manifestJsonPath: normalizeSlashes(payload.manifestJsonPath || ""),
    requestPath: normalizeSlashes(payload.requestPath || ""),
    resultPath: normalizeSlashes(payload.resultPath || ""),
    summaryPath: normalizeSlashes(payload.summaryPath || ""),
    commandPath: normalizeSlashes(payload.commandPath || ""),
    projectName: String(payload.projectName || ""),
    topModule: String(payload.topModule || ""),
    partNumber: String(payload.partNumber || ""),
    strategy: String(payload.strategy || "Default"),
    powerLimitW: toNumber(payload.powerLimitW, 2.5),
    autoProgram: Boolean(payload.autoProgram),
    noPause: Boolean(payload.noPause),
    srcListPath: normalizeSlashes(payload.srcListPath || ""),
    xdcListPath: normalizeSlashes(payload.xdcListPath || ""),
    incListPath: normalizeSlashes(payload.incListPath || ""),
    steps: Array.isArray(payload.steps) ? payload.steps.map((step) => ({
      name: String(step && step.name ? step.name : ""),
      enabled: step && Object.prototype.hasOwnProperty.call(step, "enabled") ? Boolean(step.enabled) : true,
    })) : [],
  };
}

function createVivadoBuildResult(payload = {}) {
  return {
    schemaVersion: 1,
    type: "vivado_build_result",
    generatedAt: new Date().toISOString(),
    projectRoot: normalizeSlashes(payload.projectRoot || ""),
    manifestJsonPath: normalizeSlashes(payload.manifestJsonPath || ""),
    buildPlanPath: normalizeSlashes(payload.buildPlanPath || ""),
    buildLogPath: normalizeSlashes(payload.buildLogPath || ""),
    projectName: String(payload.projectName || ""),
    topModule: String(payload.topModule || ""),
    partNumber: String(payload.partNumber || ""),
    strategy: String(payload.strategy || "Default"),
    powerLimitW: toNumber(payload.powerLimitW, 2.5),
    programStatus: String(payload.programStatus || "NOT_RUN"),
    stepResults: Array.isArray(payload.stepResults) ? payload.stepResults.map((step) => ({
      name: String(step && step.name ? step.name : ""),
      status: String(step && step.status ? step.status : "unknown"),
      rc: Number.isFinite(Number(step && step.rc)) ? Number(step.rc) : null,
    })) : [],
    reportDataPath: normalizeSlashes(payload.reportDataPath || ""),
  };
}

module.exports = {
  createVivadoBuildRequest,
  createVivadoBuildPlan,
  createVivadoBuildResult,
};
