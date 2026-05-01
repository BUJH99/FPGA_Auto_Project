const fs = require("fs");
const path = require("path");
const { readJsonFile, writeJsonFile } = require("../../../shared/application/json_file_service");
const { appendRunEntry } = require("../../../shared/application/run_registry_service");
const { createArtifactRecord } = require("../../../shared/domain/run_contracts");
const { createVitisSummary, normalizeSlashes } = require("../domain/vitis_contracts");
const { defaultSummaryFile } = require("../domain/vitis_defaults");

function readJsonMaybe(filePath) {
  if (!filePath || !fs.existsSync(filePath)) return null;
  try {
    return readJsonFile(filePath, null);
  } catch {
    return null;
  }
}

function deriveStatus(rc, resultPayload, explicitStatus = "") {
  const requested = String(explicitStatus || "").trim().toLowerCase();
  if (requested) return requested;
  if (resultPayload && typeof resultPayload === "object" && resultPayload.status) {
    return String(resultPayload.status).trim().toLowerCase();
  }
  const parsed = Number(rc);
  if (Number.isFinite(parsed)) {
    return parsed === 0 ? "ok" : "failed";
  }
  return "unknown";
}

function artifactIfExists(kind, targetPath, label = "") {
  if (!targetPath || !fs.existsSync(targetPath)) return null;
  return createArtifactRecord({ kind, path: targetPath, label: label || path.basename(targetPath) });
}

function compactErrors(...groups) {
  const rows = [];
  for (const group of groups) {
    if (!Array.isArray(group)) continue;
    for (const value of group) {
      const text = String(value || "").trim();
      if (text) rows.push(text);
    }
  }
  return Array.from(new Set(rows));
}

function writeVitisSummary({
  projectRoot,
  manifestJsonPath = "",
  step,
  planPath = "",
  resultPath = "",
  summaryPath = "",
  logPath = "",
  status = "",
  rc = "",
  startedAt = "",
  finishedAt = "",
} = {}) {
  const root = path.resolve(projectRoot || process.cwd());
  const selectedStep = String(step || "").trim();
  const planPayload = readJsonMaybe(planPath);
  const resultPayload = readJsonMaybe(resultPath);
  const derivedStatus = deriveStatus(rc, resultPayload, status);
  const plan = planPayload && typeof planPayload === "object" ? planPayload : {};
  const result = resultPayload && typeof resultPayload === "object" ? resultPayload : {};
  const artifacts = [
    artifactIfExists("vitis_plan_json", planPath, "Vitis plan"),
    artifactIfExists("vitis_result_json", resultPath, "Vitis result"),
    artifactIfExists("vitis_log", logPath || (plan.paths && plan.paths.logPath), "Vitis log"),
    artifactIfExists("vivado_bitstream", plan.xsa && plan.xsa.bitPath, "Selected bitstream"),
    artifactIfExists("vitis_xsa", plan.xsa && plan.xsa.path, "XSA"),
    artifactIfExists("vitis_xpfm", plan.platform && plan.platform.xpfm, "Platform XPFM"),
  ].filter(Boolean);
  const outputRows = result.outputs && typeof result.outputs === "object" ? result.outputs : {};
  const warningRows = compactErrors(plan.warnings, result.warnings);
  const errorRows = compactErrors(plan.errors, result.errors);
  const summary = createVitisSummary({
    step: selectedStep,
    projectRoot: root,
    manifestJsonPath,
    status: derivedStatus,
    startedAt: startedAt || new Date().toISOString(),
    finishedAt: finishedAt || new Date().toISOString(),
    inputs: {
      planPath: normalizeSlashes(planPath),
      resultPath: normalizeSlashes(resultPath),
      application: plan.application || null,
      selectedApplications: Array.isArray(plan.selectedApplications) ? plan.selectedApplications : [],
      platform: plan.platform || {},
      xsa: plan.xsa || {},
    },
    outputs: outputRows,
    warnings: warningRows,
    errors: errorRows,
    artifacts,
    details: {
      rc: Number.isFinite(Number(rc)) ? Number(rc) : null,
      workspace: plan.workspace || "",
      run: plan.run || {},
      result,
    },
  });
  const resolvedSummaryPath = path.resolve(
    summaryPath || path.join(root, "output", "vitis", "summaries", defaultSummaryFile(selectedStep))
  );
  const writtenSummaryPath = writeJsonFile(resolvedSummaryPath, summary);

  appendRunEntry(root, {
    tool: "vitis",
    projectRoot: root,
    manifestJsonPath,
    status: summary.status,
    outputs: artifacts,
    summaryPath: writtenSummaryPath,
    metadata: {
      step: selectedStep,
      application: plan.application && plan.application.name ? plan.application.name : "",
      applications: Array.isArray(plan.selectedApplications)
        ? plan.selectedApplications.map((application) => application.name).filter(Boolean)
        : [],
      platform: plan.platform && plan.platform.name ? plan.platform.name : "",
    },
  });

  return {
    summary,
    summaryPath: writtenSummaryPath,
  };
}

module.exports = {
  writeVitisSummary,
};
