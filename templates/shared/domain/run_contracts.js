const path = require("path");

function normalizeSlashes(value) {
  return String(value || "").replace(/\\/g, "/");
}

function normalizeArtifactPath(projectRoot, targetPath) {
  const root = path.resolve(projectRoot || process.cwd());
  const value = String(targetPath || "");
  if (!value) return "";
  const abs = path.isAbsolute(value) ? path.resolve(value) : path.resolve(root, value);
  return normalizeSlashes(path.relative(root, abs));
}

function toIsoTimestamp(value = new Date()) {
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

function normalizeStatus(status, fallback = "unknown") {
  const value = String(status || "").trim().toLowerCase();
  return value || fallback;
}

function normalizeStringArray(values) {
  if (!Array.isArray(values)) return [];
  return Array.from(
    new Set(
      values
        .map((value) => String(value || "").trim())
        .filter(Boolean)
        .map((value) => normalizeSlashes(value))
    )
  ).sort((a, b) => a.localeCompare(b));
}

function createArtifactRecord({
  kind,
  path,
  label = "",
  status = "generated",
} = {}) {
  return {
    kind: String(kind || "artifact"),
    path: normalizeSlashes(path),
    label: String(label || ""),
    status: normalizeStatus(status, "generated"),
  };
}

function normalizeArtifactList(projectRoot, items) {
  return (items || [])
    .filter(Boolean)
    .map((item) => {
      if (typeof item === "string") {
        return createArtifactRecord({
          kind: "file",
          path: normalizeArtifactPath(projectRoot, item),
        });
      }

      return createArtifactRecord({
        kind: item.kind || "artifact",
        path: normalizeArtifactPath(projectRoot, item.path),
        label: item.label || "",
        status: item.status || "generated",
      });
    });
}

function createRunSummary({
  tool,
  projectRoot,
  manifestJsonPath = "",
  status = "unknown",
  startedAt = new Date(),
  finishedAt = new Date(),
  warnings = [],
  artifacts = [],
  details = {},
} = {}) {
  return {
    schemaVersion: 1,
    type: "run_summary",
    tool: String(tool || "unknown"),
    projectRoot: normalizeSlashes(projectRoot),
    manifestJsonPath: normalizeSlashes(manifestJsonPath),
    status: normalizeStatus(status),
    startedAt: toIsoTimestamp(startedAt),
    finishedAt: toIsoTimestamp(finishedAt),
    warnings: normalizeStringArray(warnings),
    artifacts: Array.isArray(artifacts) ? artifacts.map((artifact) => createArtifactRecord(artifact)) : [],
    details: details && typeof details === "object" ? details : {},
  };
}

function createBuildSummary({
  tool = "build",
  projectRoot,
  status = "unknown",
  manifestJsonPath = "",
  artifacts = [],
  warnings = [],
  qualityGate = {},
  details = {},
} = {}) {
  return {
    schemaVersion: 1,
    type: "build_summary",
    tool,
    projectRoot: normalizeSlashes(projectRoot),
    manifestJsonPath: normalizeSlashes(manifestJsonPath),
    status: normalizeStatus(status),
    generatedAt: toIsoTimestamp(),
    warnings: normalizeStringArray(warnings),
    artifacts: Array.isArray(artifacts) ? artifacts.map((artifact) => createArtifactRecord(artifact)) : [],
    qualityGate: qualityGate && typeof qualityGate === "object" ? qualityGate : {},
    details: details && typeof details === "object" ? details : {},
  };
}

function createMigrationSummary({
  tool = "project_bootstrap_migration",
  repoRoot,
  projectRoot,
  status = "unknown",
  warnings = [],
  artifacts = [],
  request = {},
  discovery = {},
  details = {},
} = {}) {
  return {
    schemaVersion: 1,
    type: "migration_summary",
    tool,
    repoRoot: normalizeSlashes(repoRoot),
    projectRoot: normalizeSlashes(projectRoot),
    status: normalizeStatus(status),
    generatedAt: toIsoTimestamp(),
    warnings: normalizeStringArray(warnings),
    artifacts: Array.isArray(artifacts) ? artifacts.map((artifact) => createArtifactRecord(artifact)) : [],
    request: request && typeof request === "object" ? request : {},
    discovery: discovery && typeof discovery === "object" ? discovery : {},
    details: details && typeof details === "object" ? details : {},
  };
}

function createDoctorSummary({
  tool = "toolkit_doctor",
  projectRoot,
  manifestJsonPath = "",
  status = "unknown",
  ok = false,
  warnings = [],
  checks = {},
  details = {},
} = {}) {
  return {
    schemaVersion: 1,
    type: "doctor_summary",
    tool,
    projectRoot: normalizeSlashes(projectRoot),
    manifestJsonPath: normalizeSlashes(manifestJsonPath),
    status: normalizeStatus(status),
    ok: Boolean(ok),
    generatedAt: toIsoTimestamp(),
    warnings: normalizeStringArray(warnings),
    checks: checks && typeof checks === "object" ? checks : {},
    details: details && typeof details === "object" ? details : {},
  };
}

function createSignalFlowSummary({
  projectRoot,
  topModule,
  signalQuery,
  status = "generated",
  matchedNodes = [],
  upstreamEdges = 0,
  downstreamEdges = 0,
  warnings = [],
  outputPath = "",
} = {}) {
  return {
    schemaVersion: 1,
    type: "signal_flow_summary",
    projectRoot: normalizeSlashes(projectRoot),
    topModule: String(topModule || ""),
    signalQuery: String(signalQuery || ""),
    status: normalizeStatus(status, "generated"),
    generatedAt: toIsoTimestamp(),
    matchedNodes: normalizeStringArray(matchedNodes),
    upstreamEdges: Number(upstreamEdges) || 0,
    downstreamEdges: Number(downstreamEdges) || 0,
    warnings: normalizeStringArray(warnings),
    outputPath: normalizeSlashes(outputPath),
  };
}

function createRegressionDashboardSummary({
  tool = "regression_dashboard",
  projectRoot,
  status = "unknown",
  projectName = "",
  topModule = "",
  totalRuns = 0,
  totalCases = 0,
  passCount = 0,
  failCount = 0,
  latestRunAt = "",
  latestByTestName = {},
  failureReasons = {},
  warnings = [],
  runs = [],
  artifacts = [],
} = {}) {
  return {
    schemaVersion: 1,
    type: "regression_dashboard_summary",
    tool,
    projectRoot: normalizeSlashes(projectRoot),
    status: normalizeStatus(status),
    generatedAt: toIsoTimestamp(),
    projectName: String(projectName || ""),
    topModule: String(topModule || ""),
    totalRuns: Number(totalRuns) || 0,
    totalCases: Number(totalCases) || 0,
    passCount: Number(passCount) || 0,
    failCount: Number(failCount) || 0,
    latestRunAt: String(latestRunAt || ""),
    latestByTestName: latestByTestName && typeof latestByTestName === "object" ? latestByTestName : {},
    failureReasons: failureReasons && typeof failureReasons === "object" ? failureReasons : {},
    warnings: normalizeStringArray(warnings),
    runs: Array.isArray(runs) ? runs : [],
    artifacts: Array.isArray(artifacts) ? artifacts.map((artifact) => createArtifactRecord(artifact)) : [],
  };
}

function createRunRegistryEntry({
  tool,
  projectRoot,
  manifestJsonPath = "",
  status = "unknown",
  outputs = [],
  summaryPath = "",
  metadata = {},
  createdAt = new Date(),
} = {}) {
  return {
    schemaVersion: 1,
    tool: String(tool || "unknown"),
    projectRoot: normalizeSlashes(projectRoot),
    manifestJsonPath: normalizeSlashes(manifestJsonPath),
    status: normalizeStatus(status),
    outputs: Array.isArray(outputs) ? outputs.map((artifact) => createArtifactRecord(artifact)) : [],
    summaryPath: normalizeSlashes(summaryPath),
    metadata: metadata && typeof metadata === "object" ? metadata : {},
    createdAt: toIsoTimestamp(createdAt),
  };
}

module.exports = {
  normalizeSlashes,
  normalizeArtifactPath,
  normalizeArtifactList,
  createArtifactRecord,
  createRunSummary,
  createBuildSummary,
  createMigrationSummary,
  createDoctorSummary,
  createSignalFlowSummary,
  createRegressionDashboardSummary,
  createRunRegistryEntry,
};
