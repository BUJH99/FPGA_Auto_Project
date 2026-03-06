const path = require("path");
const simulationRunService = require("./simulation_run_service");

function findFirstArtifact(runResult, matcher) {
  for (const row of runResult.generatedFiles || []) {
    if (matcher(row && row.file)) {
      return row.file;
    }
  }
  return "";
}

function runSimulationReport(params) {
  const result = simulationRunService.runSimulationReport(
    params.configPath,
    params.manifestJsonPath
  );
  const projectRoot = path.resolve(params.projectRoot || path.dirname(params.configPath));
  const runResult = result.runResult || {};

  return {
    ok: result.exitCode === 0,
    mode: result.mode === "single_run" ? "single" : result.mode,
    exitCode: result.exitCode,
    htmlFile: runResult.htmlFile || "",
    runSummaryPath: result.summaryPath || path.join(projectRoot, "output", "run_summary.json"),
    runIndexPath: path.join(projectRoot, "output", "run_index.json"),
    regressionSummaryPath: result.regressionSummaryPath || runResult.latestRegressionSummaryPath || findFirstArtifact(runResult, (filePath) => /\.md$/i.test(filePath || "")),
    regressionSummaryJsonPath: result.regressionSummaryJsonPath || runResult.latestRegressionSummaryJsonPath || "",
    regressionDashboardPath: result.regressionDashboardPath || runResult.regressionDashboardPath || "",
    regressionDashboardMarkdownPath: result.regressionDashboardMarkdownPath || runResult.regressionDashboardMarkdownPath || "",
    regressionRows: runResult.regressionRows || [],
    generatedFiles: runResult.generatedFiles || [],
    context: null,
  };
}

module.exports = {
  runSimulationReport,
  buildVivadoTclContent: simulationRunService.buildVivadoTclContent,
  parseRunLog: simulationRunService.parseRunLog,
  writeRegressionSummary: simulationRunService.writeRegressionSummary,
};
