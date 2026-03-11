const path = require("path");
const { writeJsonFile } = require("../../../shared/application/json_file_service");
const {
  appendRunEntry,
  collectSimulationRegressionRuns,
} = require("../../../shared/application/run_registry_service");
const {
  createArtifactRecord,
  createRegressionDashboardSummary,
  normalizeSlashes,
} = require("../../../shared/domain/run_contracts");

function toRelative(projectRoot, targetPath) {
  const root = path.resolve(projectRoot || process.cwd());
  const abs = path.resolve(targetPath || "");
  return normalizeSlashes(path.relative(root, abs));
}

function compareTimestamps(left, right) {
  const leftTs = Date.parse(left || "") || 0;
  const rightTs = Date.parse(right || "") || 0;
  return leftTs - rightTs;
}

function buildDashboardMarkdown(summary) {
  const lines = [
    "# Regression Dashboard",
    "",
    `- Project: ${summary.projectName || "-"}`,
    `- Top Module: ${summary.topModule || "-"}`,
    `- Total Runs: ${summary.totalRuns}`,
    `- Total Cases: ${summary.totalCases}`,
    `- Pass: ${summary.passCount}`,
    `- Fail: ${summary.failCount}`,
    `- Latest Run: ${summary.latestRunAt || "-"}`,
    "",
    "## Latest Status by TESTNAME",
    "",
    "| TESTNAME | Result | Checked | Errors | Reason | Run At | Log |",
    "|---|---|---:|---:|---|---|---|",
  ];

  const latestRows = Object.entries(summary.latestByTestName || {}).sort((a, b) => a[0].localeCompare(b[0]));
  if (latestRows.length === 0) {
    lines.push("| - | - | 0 | 0 | no_data | - | - |");
  } else {
    for (const [testName, row] of latestRows) {
      lines.push(
        `| ${testName} | ${row.pass ? "PASS" : "FAIL"} | ${Number(row.checkedCount || 0)} | ${Number(row.errorCount || 0)} | ${row.reason || "unknown"} | ${row.createdAt || "-"} | ${row.logPath || "-"} |`
      );
    }
  }

  lines.push("");
  lines.push("## Recent Failing Runs");
  lines.push("");
  lines.push("| Run At | Fail Count | Summary | Regression JSON |");
  lines.push("|---|---:|---|---|");

  const failingRuns = (summary.runs || [])
    .filter((run) => Number(run.failCount || 0) > 0)
    .sort((left, right) => compareTimestamps(right.createdAt, left.createdAt))
    .slice(0, 10);
  if (failingRuns.length === 0) {
    lines.push("| - | 0 | - | - |");
  } else {
    for (const run of failingRuns) {
      lines.push(
        `| ${run.createdAt || "-"} | ${Number(run.failCount || 0)} | ${run.summaryPath || "-"} | ${run.regressionSummaryJsonPath || "-"} |`
      );
    }
  }

  lines.push("");
  lines.push("## Failure Reasons");
  lines.push("");
  lines.push("| Reason | Count |");
  lines.push("|---|---:|");
  const reasonRows = Object.entries(summary.failureReasons || {}).sort((a, b) => Number(b[1]) - Number(a[1]) || a[0].localeCompare(b[0]));
  if (reasonRows.length === 0) {
    lines.push("| - | 0 |");
  } else {
    for (const [reason, count] of reasonRows) {
      lines.push(`| ${reason} | ${Number(count || 0)} |`);
    }
  }

  lines.push("");
  lines.push("## Linked Artifacts");
  lines.push("");
  for (const artifact of summary.artifacts || []) {
    lines.push(`- ${artifact.kind}: ${artifact.path}`);
  }

  return `${lines.join("\n")}\n`;
}

function buildDashboardData(projectRoot) {
  const root = path.resolve(projectRoot || process.cwd());
  const runs = collectSimulationRegressionRuns(root).sort((left, right) =>
    compareTimestamps(left.createdAt, right.createdAt)
  );

  const latestByTestName = {};
  const failureReasons = {};
  const summaryRuns = [];
  let projectName = "";
  let topModule = "";
  let passCount = 0;
  let failCount = 0;
  let totalCases = 0;
  let latestRunAt = "";

  for (const run of runs) {
    if (run.projectName) projectName = run.projectName;
    if (run.topModule) topModule = run.topModule;
    if (compareTimestamps(latestRunAt, run.createdAt) <= 0) {
      latestRunAt = run.createdAt || latestRunAt;
    }

    const normalizedRows = (run.regressionRows || []).map((row) => ({
      testName: String(row.testName || ""),
      pass: Boolean(row.pass),
      checkedCount: Number(row.checkedCount || 0),
      errorCount: Number.isFinite(Number(row.errorCount)) ? Number(row.errorCount) : 0,
      reason: String(row.reason || "unknown"),
      logPath: String(row.logPath || ""),
    }));
    const runPassCount = Number(run.passCount || normalizedRows.filter((row) => row.pass).length);
    const runFailCount = Number(run.failCount || normalizedRows.filter((row) => !row.pass).length);
    passCount += runPassCount;
    failCount += runFailCount;
    totalCases += normalizedRows.length;

    const runSummaryPath = run.summaryPath ? toRelative(root, run.summaryPath) : "";
    const regressionSummaryJsonPath = run.regressionSummaryJsonPath
      ? toRelative(root, run.regressionSummaryJsonPath)
      : "";
    summaryRuns.push({
      createdAt: run.createdAt || "",
      status: run.entry && run.entry.status ? run.entry.status : "",
      mode: run.mode || "regression",
      projectName: run.projectName || "",
      topModule: run.topModule || "",
      passCount: runPassCount,
      failCount: runFailCount,
      summaryPath: runSummaryPath,
      regressionSummaryJsonPath,
      rows: normalizedRows,
    });

    for (const row of normalizedRows) {
      const currentLatest = latestByTestName[row.testName];
      if (!currentLatest || compareTimestamps(currentLatest.createdAt, run.createdAt) <= 0) {
        latestByTestName[row.testName] = {
          pass: row.pass,
          checkedCount: row.checkedCount,
          errorCount: row.errorCount,
          reason: row.reason,
          createdAt: run.createdAt || "",
          logPath: row.logPath ? toRelative(root, row.logPath) : "",
        };
      }
      if (!row.pass) {
        failureReasons[row.reason] = Number(failureReasons[row.reason] || 0) + 1;
      }
    }
  }

  return {
    projectRoot: root,
    projectName,
    topModule,
    totalRuns: runs.length,
    totalCases,
    passCount,
    failCount,
    latestRunAt,
    latestByTestName,
    failureReasons,
    runs: summaryRuns,
  };
}

function writeRegressionDashboard(projectRoot) {
  const root = path.resolve(projectRoot || process.cwd());
  const jsonPath = path.join(root, "output", "regression_dashboard.json");
  const markdownPath = path.join(root, "output", "regression_dashboard.md");
  const artifacts = [
    createArtifactRecord({
      kind: "regression_dashboard_json",
      path: jsonPath,
      label: "regression_dashboard.json",
    }),
    createArtifactRecord({
      kind: "regression_dashboard_markdown",
      path: markdownPath,
      label: "regression_dashboard.md",
    }),
  ];
  const data = buildDashboardData(root);
  const summary = createRegressionDashboardSummary({
    projectRoot: root,
    status: data.totalRuns === 0 ? "warning" : (data.failCount > 0 ? "warning" : "ok"),
    projectName: data.projectName,
    topModule: data.topModule,
    totalRuns: data.totalRuns,
    totalCases: data.totalCases,
    passCount: data.passCount,
    failCount: data.failCount,
    latestRunAt: data.latestRunAt,
    latestByTestName: data.latestByTestName,
    failureReasons: data.failureReasons,
    warnings: data.totalRuns === 0 ? ["no_regression_runs_found"] : [],
    runs: data.runs,
    artifacts,
  });
  const writtenSummaryPath = writeJsonFile(jsonPath, summary);
  writeJsonFile(markdownPath, buildDashboardMarkdown(summary));

  appendRunEntry(root, {
    tool: "regression_dashboard",
    projectRoot: root,
    status: summary.status,
    outputs: artifacts,
    summaryPath: writtenSummaryPath,
    metadata: {
      totalRuns: summary.totalRuns,
      totalCases: summary.totalCases,
      passCount: summary.passCount,
      failCount: summary.failCount,
      topModule: summary.topModule,
    },
  });

  return {
    summary,
    summaryPath: writtenSummaryPath,
    markdownPath: normalizeSlashes(path.resolve(markdownPath)),
  };
}

module.exports = {
  buildDashboardData,
  writeRegressionDashboard,
};
