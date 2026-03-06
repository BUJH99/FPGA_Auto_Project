const path = require("path");

function uniqueStrings(rows) {
  const seen = new Set();
  const out = [];
  for (const row of rows || []) {
    const value = String(row || "").trim();
    if (!value || seen.has(value)) continue;
    seen.add(value);
    out.push(value);
  }
  return out;
}

function normalizeNumber(value, fallback) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function normalizeScenario(scenario, index) {
  return {
    ...scenario,
    id: scenario.id || `case_${index + 1}`,
    title: scenario.title || `CASE ${index + 1}`,
    start_ns: Math.max(0, Math.round(normalizeNumber(scenario.start_ns, 0))),
    duration_ns: Math.max(1, Math.round(normalizeNumber(scenario.duration_ns, 100000))),
    sample_step_ns: Math.max(1, Math.round(normalizeNumber(scenario.sample_step_ns, 100))),
    signals: Array.from(new Set(Array.isArray(scenario.signals) ? scenario.signals.filter(Boolean) : [])),
  };
}

function normalizeScenarios(rows) {
  return (rows || []).map((scenario, index) => normalizeScenario(scenario || {}, index));
}

function slugify(text) {
  return String(text || "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 64) || "run";
}

function uniqueSortedPaths(rows) {
  return Array.from(new Set((rows || []).map((row) => path.resolve(row))))
    .sort((a, b) => a.localeCompare(b));
}

function isPathWithin(parentAbs, targetAbs) {
  const parent = path.resolve(parentAbs);
  const target = path.resolve(targetAbs);
  const rel = path.relative(parent, target);
  return rel === "" || (!rel.startsWith("..") && !path.isAbsolute(rel));
}

function createRegressionRow(payload) {
  return {
    testName: payload.testName,
    pass: Boolean(payload.pass),
    checkedCount: Number(payload.checkedCount || 0),
    errorCount: Number.isFinite(payload.errorCount) ? payload.errorCount : Number(payload.errorCount),
    reason: payload.reason || "unknown",
    logPath: payload.logPath || "",
  };
}

function createSimulationRunRequest(payload = {}) {
  return {
    configPath: payload.configPath || "",
    manifestJsonPath: payload.manifestJsonPath || "",
    projectRoot: payload.projectRoot || "",
    cfg: payload.cfg && typeof payload.cfg === "object" ? payload.cfg : {},
    scenarios: Array.isArray(payload.scenarios) ? payload.scenarios : [],
  };
}

function createWaveArtifactSet(payload = {}) {
  return {
    file: payload.file || "",
    title: payload.title || "",
    description: payload.description || "",
    start_ns: Number(payload.start_ns || 0),
    duration_ns: Number(payload.duration_ns || 0),
    jsonData: payload.jsonData || "",
  };
}

function createSimulationRunResult(payload = {}) {
  return {
    projectName: payload.projectName || "",
    topModule: payload.topModule || "",
    tbFile: payload.tbFile || "",
    htmlFile: payload.htmlFile || "",
    vcdFile: payload.vcdFile || "",
    generatedFiles: Array.isArray(payload.generatedFiles) ? payload.generatedFiles : [],
    regressionRows: Array.isArray(payload.regressionRows) ? payload.regressionRows : [],
    warnings: Array.isArray(payload.warnings) ? payload.warnings : [],
    status: payload.status || "unknown",
    mode: payload.mode || "",
    runStamp: payload.runStamp || "",
    regressionSummaryPath: payload.regressionSummaryPath || "",
    regressionSummaryJsonPath: payload.regressionSummaryJsonPath || "",
    latestRegressionSummaryPath: payload.latestRegressionSummaryPath || "",
    latestRegressionSummaryJsonPath: payload.latestRegressionSummaryJsonPath || "",
    regressionDashboardPath: payload.regressionDashboardPath || "",
    regressionDashboardMarkdownPath: payload.regressionDashboardMarkdownPath || "",
  };
}

function createRunSummary(payload) {
  return {
    tool: "simulation.report",
    generatedAt: new Date().toISOString(),
    projectRoot: payload.projectRoot,
    projectName: payload.projectName,
    topModule: payload.topModule,
    status: payload.status || "ok",
    configPath: payload.configPath,
    manifestJsonPath: payload.manifestJsonPath,
    outputs: payload.outputs || {},
    requestedTests: payload.requestedTests || [],
    regression: payload.regression || null,
    scenarios: payload.scenarios || [],
    warnings: payload.warnings || [],
  };
}

module.exports = {
  uniqueStrings,
  normalizeNumber,
  normalizeScenario,
  normalizeScenarios,
  slugify,
  uniqueSortedPaths,
  isPathWithin,
  createRegressionRow,
  createSimulationRunRequest,
  createWaveArtifactSet,
  createSimulationRunResult,
  createRunSummary,
};
