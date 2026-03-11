const assert = require("assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { writeJsonFile } = require("./json_file_service");
const {
  appendRunEntry,
  readRunSummaries,
  findLatestRunByTool,
  collectSimulationRegressionRuns,
} = require("./run_registry_service");
const {
  createRunSummary,
  createBuildSummary,
  createArtifactRecord,
} = require("../domain/run_contracts");

function withTempDir(prefix, fn) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  try {
    return fn(tempDir);
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
}

function runRunRegistrySelftest() {
  return withTempDir("fpga-run-registry-", (projectRoot) => {
    const simulationSummaryOne = createRunSummary({
      tool: "simulation_report",
      projectRoot,
      status: "ok",
      artifacts: [
        createArtifactRecord({
          kind: "regression_dashboard_json",
          path: path.join(projectRoot, "output", "history", "simulation_report", "r1", "regression_tb_TOP.json"),
        }),
      ],
      details: {
        mode: "regression",
        projectName: "registry_smoke",
        topModule: "TOP",
        passCount: 1,
        failCount: 0,
        regressionSummaryJsonPath: path.join(projectRoot, "output", "history", "simulation_report", "r1", "regression_tb_TOP.json"),
        regressionRows: [
          { testName: "SMOKE", pass: true, checkedCount: 2, errorCount: 0, reason: "ok", logPath: path.join(projectRoot, "log", "smoke.log") },
        ],
      },
    });
    const simulationSummaryTwo = createRunSummary({
      tool: "simulation_report",
      projectRoot,
      status: "failed",
      artifacts: [],
      details: {
        mode: "regression",
        projectName: "registry_smoke",
        topModule: "TOP",
        passCount: 0,
        failCount: 1,
        regressionRows: [
          { testName: "SMOKE", pass: false, checkedCount: 2, errorCount: 1, reason: "scoreboard_errors", logPath: path.join(projectRoot, "log", "smoke_2.log") },
        ],
      },
    });
    const buildSummary = createBuildSummary({
      tool: "vivado_build",
      projectRoot,
      status: "ok",
      details: {
        topModule: "TOP",
      },
    });

    const simulationSummaryPathOne = writeJsonFile(path.join(projectRoot, "output", "history", "simulation_report", "r1", "run_summary.json"), simulationSummaryOne);
    const simulationSummaryPathTwo = writeJsonFile(path.join(projectRoot, "output", "history", "simulation_report", "r2", "run_summary.json"), simulationSummaryTwo);
    const buildSummaryPath = writeJsonFile(path.join(projectRoot, "output", "history", "vivado_build", "b1", "build_summary.json"), buildSummary);

    appendRunEntry(projectRoot, {
      tool: "simulation_report",
      projectRoot,
      status: "ok",
      summaryPath: simulationSummaryPathOne,
      outputs: simulationSummaryOne.artifacts,
      createdAt: "2026-03-06T00:00:00.000Z",
    });
    appendRunEntry(projectRoot, {
      tool: "simulation_report",
      projectRoot,
      status: "failed",
      summaryPath: simulationSummaryPathTwo,
      outputs: simulationSummaryTwo.artifacts,
      createdAt: "2026-03-06T01:00:00.000Z",
    });
    appendRunEntry(projectRoot, {
      tool: "vivado_build",
      projectRoot,
      status: "ok",
      summaryPath: buildSummaryPath,
      outputs: buildSummary.artifacts,
      createdAt: "2026-03-06T02:00:00.000Z",
    });

    const allSummaries = readRunSummaries(projectRoot);
    assert.equal(allSummaries.length, 3);
    assert.ok(allSummaries.every((row) => row.summaryPath));

    const latestBuild = findLatestRunByTool(projectRoot, "vivado_build");
    assert.ok(latestBuild);
    assert.equal(latestBuild.summary.type, "build_summary");

    const regressionRuns = collectSimulationRegressionRuns(projectRoot);
    assert.equal(regressionRuns.length, 2);
    assert.equal(regressionRuns[1].regressionRows[0].reason, "scoreboard_errors");

    return {
      ok: true,
      summaryCount: allSummaries.length,
      regressionRuns: regressionRuns.length,
    };
  });
}

module.exports = {
  runRunRegistrySelftest,
};
