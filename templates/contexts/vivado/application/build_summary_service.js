const path = require("path");
const { buildQualityGate } = require("../domain/build_quality_gate");
const { resolveProjectContext } = require("../../../shared/application/manifest_contract_loader");
const { readJsonFile, writeJsonFile } = require("../../../shared/application/json_file_service");
const { appendRunEntry } = require("../../../shared/application/run_registry_service");
const {
  createBuildSummary,
  createArtifactRecord,
} = require("../../../shared/domain/run_contracts");
const { createVivadoBuildResult } = require("../domain/vivado_build_contracts");
const { readVivadoBuildPlan } = require("./vivado_build_plan_service");

function rcStepStatus(rc) {
  const parsed = Number(rc);
  if (!Number.isFinite(parsed) || parsed < 0) return "not_run";
  return parsed === 0 ? "ok" : "failed";
}

function normalizeProgramStatus(programStatus) {
  return String(programStatus || "NOT_RUN").trim().toUpperCase() || "NOT_RUN";
}

function programStepStatus(programStatus) {
  switch (normalizeProgramStatus(programStatus)) {
    case "SUCCESS":
      return "ok";
    case "SKIPPED":
    case "SKIPPED_BY_USER":
      return "skipped";
    case "NOT_RUN":
    case "NOT_AVAILABLE":
      return "not_run";
    case "FAILED":
      return "failed";
    default:
      return "unknown";
  }
}

function deriveBuildStatus(qualityGate, stepResults, programStatus) {
  if (!qualityGate || !qualityGate.bitstream) return "unknown";
  if (qualityGate.bitstream.status !== "ok") return "failed";
  if (qualityGate.timing && qualityGate.timing.status === "failed") return "failed";
  if (qualityGate.power && qualityGate.power.status === "failed") return "failed";
  if (qualityGate.cdc && qualityGate.cdc.status === "failed") return "warning";
  const auxiliaryStepFailed = (stepResults || []).some((step) =>
    ["rtl_hierarchy_export", "final_report_generation"].includes(step.name) && step.status === "failed"
  );
  if (auxiliaryStepFailed) return "warning";
  if (programStepStatus(programStatus) === "failed") return "warning";
  return "ok";
}

function buildArtifactRows(projectRoot, gate, extraArtifacts = []) {
  const rows = [];
  for (const filePath of gate.bitstreams || []) {
    rows.push(createArtifactRecord({ kind: "bitstream", path: filePath }));
  }
  for (const filePath of gate.reports || []) {
    rows.push(createArtifactRecord({ kind: "vivado_report", path: filePath }));
  }
  for (const filePath of gate.checkpoints || []) {
    rows.push(createArtifactRecord({ kind: "design_checkpoint", path: filePath }));
  }
  if (gate.finalReportHtml) {
    rows.push(createArtifactRecord({ kind: "final_build_report_html", path: gate.finalReportHtml }));
  }
  if (gate.logPath) {
    rows.push(createArtifactRecord({ kind: "vivado_build_log", path: gate.logPath }));
  }
  for (const artifact of extraArtifacts) {
    rows.push(createArtifactRecord(artifact));
  }
  return rows;
}

function buildStepResults({ buildRc = -1, rtlRc = -1, reportRc = -1, programStatus = "NOT_RUN" } = {}) {
  return [
    { name: "build", status: rcStepStatus(buildRc), rc: Number.isFinite(Number(buildRc)) ? Number(buildRc) : null },
    { name: "rtl_hierarchy_export", status: rcStepStatus(rtlRc), rc: Number.isFinite(Number(rtlRc)) ? Number(rtlRc) : null },
    { name: "final_report_generation", status: rcStepStatus(reportRc), rc: Number.isFinite(Number(reportRc)) ? Number(reportRc) : null },
    { name: "summary_capture", status: "ok", rc: 0 },
    { name: "program_device", status: programStepStatus(programStatus), rc: null },
  ];
}

function readFinalReportData(projectRoot) {
  const reportDataPath = path.join(projectRoot, "output", "FINALReport", "report_data.json");
  let reportData = null;
  try {
    reportData = readJsonFile(reportDataPath, null);
  } catch {
    reportData = null;
  }
  return {
    reportDataPath,
    reportData,
  };
}

function summarizeFinalReportData(reportData) {
  if (!reportData || typeof reportData !== "object") {
    return null;
  }

  const modules = Array.isArray(reportData.modules) ? reportData.modules : [];
  return {
    meta: reportData.meta || {},
    status: reportData.status || {},
    timing: reportData.timing || {},
    power: reportData.power || {},
    utilization: reportData.utilization || {},
    cdc: reportData.cdc || {},
    blockDiagram: reportData.blockDiagram || {},
    moduleCount: modules.length,
  };
}

function writeBuildSummary({
  projectRoot,
  manifestJsonPath = "",
  buildLogPath = "",
  outputPath = "",
  buildPlanPath = "",
  buildResultPath = "",
  programStatus = "NOT_RUN",
  buildRc = -1,
  rtlRc = -1,
  reportRc = -1,
} = {}) {
  const root = path.resolve(projectRoot || process.cwd());
  const manifestContext = resolveProjectContext(root, manifestJsonPath);
  const buildPlan = readVivadoBuildPlan(buildPlanPath);
  const gate = buildQualityGate(root, buildLogPath);
  const normalizedProgramStatus = normalizeProgramStatus(programStatus);
  const stepResults = buildStepResults({
    buildRc,
    rtlRc,
    reportRc,
    programStatus: normalizedProgramStatus,
  });
  const vivadoConfig = manifestContext.snapshot && manifestContext.snapshot.config && manifestContext.snapshot.config.vivado
    && typeof manifestContext.snapshot.config.vivado === "object"
    ? manifestContext.snapshot.config.vivado
    : {};
  const projectName = buildPlan && buildPlan.projectName
    ? buildPlan.projectName
    : (manifestContext.snapshot.projectName || path.basename(root));
  const topModule = buildPlan && buildPlan.topModule
    ? buildPlan.topModule
    : (manifestContext.snapshot.top || "");
  const partNumber = buildPlan && buildPlan.partNumber
    ? buildPlan.partNumber
    : String(vivadoConfig.part || "");
  const strategy = buildPlan && buildPlan.strategy
    ? buildPlan.strategy
    : String(vivadoConfig.strategy || "Default");
  const powerLimitW = buildPlan && Number.isFinite(Number(buildPlan.powerLimitW))
    ? Number(buildPlan.powerLimitW)
    : (Number.isFinite(Number(vivadoConfig.power_limit_w)) ? Number(vivadoConfig.power_limit_w) : 2.5);
  const { reportDataPath, reportData } = readFinalReportData(root);
  const resultPayload = createVivadoBuildResult({
    projectRoot: root,
    manifestJsonPath,
    buildPlanPath,
    buildLogPath,
    projectName,
    topModule,
    partNumber,
    strategy,
    powerLimitW,
    programStatus: normalizedProgramStatus,
    stepResults,
    reportDataPath: reportData ? reportDataPath : "",
  });
  const resolvedResultPath = buildResultPath
    ? path.resolve(buildResultPath)
    : (buildPlan && buildPlan.resultPath ? path.resolve(buildPlan.resultPath) : path.join(root, "output", "vivado", "build_result.json"));
  const writtenResultPath = writeJsonFile(resolvedResultPath, resultPayload);
  const extraArtifacts = [];
  if (buildPlanPath) {
    extraArtifacts.push({ kind: "vivado_build_plan_json", path: buildPlanPath, label: path.basename(buildPlanPath) });
  }
  if (buildPlan && buildPlan.requestPath) {
    extraArtifacts.push({ kind: "vivado_build_request_json", path: buildPlan.requestPath, label: path.basename(buildPlan.requestPath) });
  }
  extraArtifacts.push({ kind: "vivado_build_result_json", path: writtenResultPath, label: path.basename(writtenResultPath) });
  if (reportData) {
    extraArtifacts.push({ kind: "final_report_data_json", path: reportDataPath, label: path.basename(reportDataPath) });
  }
  const artifacts = buildArtifactRows(root, gate, extraArtifacts);
  const summary = createBuildSummary({
    tool: "vivado_build",
    projectRoot: root,
    manifestJsonPath,
    status: deriveBuildStatus(gate.qualityGate, stepResults, normalizedProgramStatus),
    artifacts,
    warnings: [],
    qualityGate: gate.qualityGate,
    details: {
      projectName,
      topModule,
      partNumber,
      strategy,
      powerLimitW,
      programStatus: normalizedProgramStatus,
      stepResults,
      buildPlanPath: buildPlanPath || "",
      buildResultPath: writtenResultPath,
      logPath: gate.logPath,
      reportCount: gate.reports.length,
      checkpointCount: gate.checkpoints.length,
      finalReport: summarizeFinalReportData(reportData),
    },
  });
  const summaryPath = writeJsonFile(
    outputPath
      ? path.resolve(outputPath)
      : (buildPlan && buildPlan.summaryPath ? path.resolve(buildPlan.summaryPath) : path.join(root, "output", "build_summary.json")),
    summary
  );

  appendRunEntry(root, {
    tool: "vivado_build",
    projectRoot: root,
    manifestJsonPath,
    status: summary.status,
    outputs: artifacts,
    summaryPath,
    metadata: {
      projectName,
      topModule,
      partNumber,
      strategy,
      programStatus: normalizedProgramStatus,
    },
  });

  return {
    summary,
    summaryPath,
    result: resultPayload,
    resultPath: writtenResultPath,
  };
}

module.exports = {
  writeBuildSummary,
};
