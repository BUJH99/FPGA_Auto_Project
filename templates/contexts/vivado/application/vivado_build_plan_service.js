const fs = require("fs");
const path = require("path");
const { loadStrictManifestContext } = require("../../../shared/application/manifest_contract_loader");
const { readJsonFile, writeJsonFile } = require("../../../shared/application/json_file_service");
const {
  createVivadoBuildRequest,
  createVivadoBuildPlan,
} = require("../domain/vivado_build_contracts");

function toBoolean(value) {
  return value === true || value === "1" || value === 1;
}

function toNumber(value, fallback) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function cmdSetLine(name, value) {
  return `set "${name}=${String(value || "")}"`;
}

function buildPlanCommand(planPaths, request, plan) {
  return [
    "@echo off",
    cmdSetLine("BUILD_REQUEST_JSON", planPaths.requestPath),
    cmdSetLine("BUILD_PLAN_JSON", planPaths.planPath),
    cmdSetLine("BUILD_RESULT_JSON", planPaths.resultPath),
    cmdSetLine("BUILD_SUMMARY_JSON", planPaths.summaryPath),
    cmdSetLine("BUILD_PROJECT_ROOT", request.projectRoot),
    cmdSetLine("BUILD_MANIFEST_JSON", request.manifestJsonPath),
    cmdSetLine("BUILD_TOP_MODULE", request.topModule),
    cmdSetLine("BUILD_PART_NUMBER", request.partNumber),
    cmdSetLine("BUILD_PROJECT_NAME", request.projectName),
    cmdSetLine("BUILD_STRATEGY", request.strategy),
    cmdSetLine("BUILD_POWER_LIMIT_W", request.powerLimitW),
    cmdSetLine("BUILD_AUTO_PROGRAM", request.autoProgram ? "1" : "0"),
    cmdSetLine("BUILD_NO_PAUSE", request.noPause ? "1" : "0"),
    cmdSetLine("BUILD_SRC_LIST", plan.srcListPath),
    cmdSetLine("BUILD_XDC_LIST", plan.xdcListPath),
    cmdSetLine("BUILD_INC_LIST", plan.incListPath),
    "",
  ].join("\r\n");
}

function prepareVivadoBuild({
  projectRoot,
  manifestJsonPath,
  srcListPath = "",
  xdcListPath = "",
  incListPath = "",
  autoProgram = false,
  noPause = false,
} = {}) {
  const root = path.resolve(projectRoot || process.cwd());
  const manifestJsonAbs = path.resolve(manifestJsonPath || "");
  const manifestContext = loadStrictManifestContext(root, manifestJsonAbs);
  const config = manifestContext.snapshot && manifestContext.snapshot.config && typeof manifestContext.snapshot.config === "object"
    ? manifestContext.snapshot.config
    : {};
  const vivadoConfig = config.vivado && typeof config.vivado === "object" ? config.vivado : {};
  const outputDir = path.join(root, "output", "vivado");
  const planPaths = {
    requestPath: path.join(outputDir, "build_request.json"),
    planPath: path.join(outputDir, "build_plan.json"),
    commandPath: path.join(outputDir, "build_plan.cmd"),
    resultPath: path.join(outputDir, "build_result.json"),
    summaryPath: path.join(root, "output", "build_summary.json"),
  };
  const request = createVivadoBuildRequest({
    projectRoot: root,
    manifestJsonPath: manifestJsonAbs,
    projectName: vivadoConfig.project_name || manifestContext.snapshot.projectName || path.basename(root),
    topModule: vivadoConfig.top_module || manifestContext.snapshot.top || "Top",
    partNumber: vivadoConfig.part || "xc7a35tcpg236-1",
    strategy: vivadoConfig.strategy || "Default",
    powerLimitW: toNumber(vivadoConfig.power_limit_w, 2.5),
    autoProgram: toBoolean(autoProgram),
    noPause: toBoolean(noPause),
    resolvedSrcFiles: manifestContext.srcFiles,
    resolvedXdcFiles: manifestContext.xdcFiles,
    resolvedIncDirs: manifestContext.incDirs,
    srcListPath: srcListPath || "",
    xdcListPath: xdcListPath || "",
    incListPath: incListPath || "",
  });
  const requestPath = writeJsonFile(planPaths.requestPath, request);
  const plan = createVivadoBuildPlan({
    ...request,
    requestPath,
    resultPath: planPaths.resultPath,
    summaryPath: planPaths.summaryPath,
    commandPath: planPaths.commandPath,
    steps: [
      { name: "build", enabled: true },
      { name: "rtl_hierarchy_export", enabled: true },
      { name: "final_report_generation", enabled: true },
      { name: "summary_capture", enabled: true },
      { name: "program_device", enabled: true },
    ],
  });
  const planPath = writeJsonFile(planPaths.planPath, plan);
  fs.mkdirSync(path.dirname(planPaths.commandPath), { recursive: true });
  fs.writeFileSync(planPaths.commandPath, buildPlanCommand(planPaths, request, plan), "utf8");

  return {
    request,
    requestPath,
    plan,
    planPath,
    planCommandPath: planPaths.commandPath.replace(/\\/g, "/"),
    resultPath: planPaths.resultPath.replace(/\\/g, "/"),
    summaryPath: planPaths.summaryPath.replace(/\\/g, "/"),
  };
}

function readVivadoBuildPlan(buildPlanPath) {
  if (!buildPlanPath) return null;
  return readJsonFile(buildPlanPath, null);
}

module.exports = {
  prepareVivadoBuild,
  readVivadoBuildPlan,
};
