function normalizeSlashes(value) {
  return String(value || "").replace(/\\/g, "/");
}

function normalizeStatus(value, fallback = "unknown") {
  const status = String(value || "").trim().toLowerCase();
  return status || fallback;
}

function normalizeStringArray(values) {
  if (!Array.isArray(values)) return [];
  return Array.from(new Set(values.map((value) => normalizeSlashes(String(value || "").trim())).filter(Boolean)))
    .sort((left, right) => left.localeCompare(right));
}

function createVitisPlan(payload = {}) {
  return {
    schemaVersion: 1,
    type: "vitis_plan",
    createdAt: new Date().toISOString(),
    step: String(payload.step || ""),
    projectRoot: normalizeSlashes(payload.projectRoot || ""),
    manifestJsonPath: normalizeSlashes(payload.manifestJsonPath || ""),
    projectName: String(payload.projectName || ""),
    timestamp: String(payload.timestamp || ""),
    workspace: normalizeSlashes(payload.workspace || ""),
    xsa: {
      path: normalizeSlashes(payload.xsa && payload.xsa.path),
      includeBitstream: Boolean(payload.xsa && payload.xsa.includeBitstream),
      fixed: Boolean(payload.xsa && payload.xsa.fixed),
      validate: Boolean(payload.xsa && payload.xsa.validate),
      exportTcl: normalizeSlashes(payload.xsa && payload.xsa.exportTcl),
      generatedPath: normalizeSlashes(payload.xsa && payload.xsa.generatedPath),
      bitPath: normalizeSlashes(payload.xsa && payload.xsa.bitPath),
      vivadoProject: normalizeSlashes(payload.xsa && payload.xsa.vivadoProject),
      implRun: String(payload.xsa && payload.xsa.implRun || "impl_1"),
      bitSelected: payload.xsa && typeof payload.xsa.bitSelected === "object" ? payload.xsa.bitSelected : null,
      bitCandidates: payload.xsa && Array.isArray(payload.xsa.bitCandidates) ? payload.xsa.bitCandidates : [],
      selected: payload.xsa && typeof payload.xsa.selected === "object" ? payload.xsa.selected : null,
      candidates: payload.xsa && Array.isArray(payload.xsa.candidates) ? payload.xsa.candidates : [],
    },
    platform: {
      name: String(payload.platform && payload.platform.name || ""),
      xpfm: normalizeSlashes(payload.platform && payload.platform.xpfm),
      os: String(payload.platform && payload.platform.os || "standalone"),
      cpu: String(payload.platform && payload.platform.cpu || "auto"),
      domainName: String(payload.platform && payload.platform.domainName || "standalone_domain"),
      selected: payload.platform && typeof payload.platform.selected === "object" ? payload.platform.selected : null,
      candidates: payload.platform && Array.isArray(payload.platform.candidates) ? payload.platform.candidates : [],
    },
    application: payload.application || null,
    selectedApplications: Array.isArray(payload.selectedApplications) ? payload.selectedApplications : [],
    applications: Array.isArray(payload.applications) ? payload.applications : [],
    run: payload.run && typeof payload.run === "object" ? payload.run : {},
    vivado: payload.vivado && typeof payload.vivado === "object" ? payload.vivado : {},
    paths: payload.paths && typeof payload.paths === "object" ? payload.paths : {},
    warnings: normalizeStringArray(payload.warnings),
    errors: normalizeStringArray(payload.errors),
  };
}

function createVitisSummary(payload = {}) {
  return {
    schemaVersion: 1,
    type: "vitis_summary",
    tool: "vitis",
    step: String(payload.step || ""),
    projectRoot: normalizeSlashes(payload.projectRoot || ""),
    manifestJsonPath: normalizeSlashes(payload.manifestJsonPath || ""),
    status: normalizeStatus(payload.status),
    startedAt: payload.startedAt || new Date().toISOString(),
    finishedAt: payload.finishedAt || new Date().toISOString(),
    inputs: payload.inputs && typeof payload.inputs === "object" ? payload.inputs : {},
    outputs: payload.outputs && typeof payload.outputs === "object" ? payload.outputs : {},
    warnings: normalizeStringArray(payload.warnings),
    errors: normalizeStringArray(payload.errors),
    artifacts: Array.isArray(payload.artifacts) ? payload.artifacts : [],
    details: payload.details && typeof payload.details === "object" ? payload.details : {},
  };
}

module.exports = {
  normalizeSlashes,
  normalizeStatus,
  normalizeStringArray,
  createVitisPlan,
  createVitisSummary,
};
