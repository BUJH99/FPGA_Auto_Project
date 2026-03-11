const fs = require("fs");
const path = require("path");
const {
  normalizeArtifactList,
  normalizeArtifactPath,
  normalizeSlashes,
  createRunRegistryEntry,
} = require("../domain/run_contracts");

function ensureDir(dirPath) {
  if (!fs.existsSync(dirPath)) {
    fs.mkdirSync(dirPath, { recursive: true });
  }
}

function writeJson(targetPath, payload) {
  const abs = path.resolve(targetPath);
  ensureDir(path.dirname(abs));
  fs.writeFileSync(abs, `${JSON.stringify(payload, null, 2)}\n`, "utf8");
  return abs;
}

function createEmptyRunIndex(projectRoot) {
  const root = path.resolve(projectRoot || process.cwd());
  return {
    schemaVersion: 1,
    kind: "run_index",
    projectRoot: normalizeSlashes(root),
    updatedAt: new Date().toISOString(),
    runs: [],
  };
}

function resolveRunIndexPath(projectRoot) {
  const root = path.resolve(projectRoot || process.cwd());
  return path.join(root, "output", "run_index.json");
}

function readRunIndex(projectRoot) {
  const indexPath = resolveRunIndexPath(projectRoot);
  if (!fs.existsSync(indexPath)) {
    return createEmptyRunIndex(projectRoot);
  }

  try {
    const parsed = JSON.parse(fs.readFileSync(indexPath, "utf8"));
    if (parsed && typeof parsed === "object" && Array.isArray(parsed.runs)) {
      return parsed;
    }
  } catch {
    // Fall through to empty payload.
  }

  return createEmptyRunIndex(projectRoot);
}

function resolveSummaryAbsolutePath(projectRoot, summaryPath) {
  const root = path.resolve(projectRoot || process.cwd());
  const value = String(summaryPath || "").trim();
  if (!value) return "";
  return path.isAbsolute(value) ? path.resolve(value) : path.resolve(root, value);
}

function readRunSummaries(projectRoot, opts = {}) {
  const root = path.resolve(projectRoot || process.cwd());
  const toolFilter = String(opts.tool || "").trim();
  const runIndex = readRunIndex(root);

  return (runIndex.runs || [])
    .filter((entry) => !toolFilter || String(entry.tool || "") === toolFilter)
    .map((entry) => {
      const summaryAbsPath = resolveSummaryAbsolutePath(root, entry.summaryPath || "");
      let summary = null;
      if (summaryAbsPath && fs.existsSync(summaryAbsPath)) {
        try {
          summary = JSON.parse(fs.readFileSync(summaryAbsPath, "utf8"));
        } catch {
          summary = null;
        }
      }
      return {
        entry,
        summary,
        summaryPath: summaryAbsPath,
      };
    });
}

function findLatestRunByTool(projectRoot, tool) {
  const summaries = readRunSummaries(projectRoot, { tool });
  if (summaries.length === 0) return null;
  return summaries.reduce((latest, current) => {
    if (!latest) return current;
    const latestTs = Date.parse(latest.entry && latest.entry.createdAt ? latest.entry.createdAt : "") || 0;
    const currentTs = Date.parse(current.entry && current.entry.createdAt ? current.entry.createdAt : "") || 0;
    return currentTs >= latestTs ? current : latest;
  }, null);
}

function findRegressionJsonArtifact(root, summary, entry) {
  const artifactRows = [];
  if (summary && Array.isArray(summary.artifacts)) artifactRows.push(...summary.artifacts);
  if (entry && Array.isArray(entry.outputs)) artifactRows.push(...entry.outputs);

  for (const artifact of artifactRows) {
    const kind = String((artifact && artifact.kind) || "");
    const artifactPath = artifact && artifact.path ? path.resolve(root, artifact.path) : "";
    if (!artifactPath || !fs.existsSync(artifactPath)) continue;
    if (kind === "regression_dashboard_json") return artifactPath;
    if (/regression_.*\.json$/i.test(artifactPath)) return artifactPath;
  }

  return "";
}

function collectSimulationRegressionRuns(projectRoot) {
  const root = path.resolve(projectRoot || process.cwd());
  const summaries = readRunSummaries(root, { tool: "simulation_report" });

  return summaries
    .map(({ entry, summary, summaryPath }) => {
      const details = summary && summary.details && typeof summary.details === "object"
        ? summary.details
        : {};
      const createdAt = String((entry && entry.createdAt) || (summary && (summary.finishedAt || summary.generatedAt)) || "");
      let regressionRows = Array.isArray(details.regressionRows) ? details.regressionRows : [];

      if (regressionRows.length === 0) {
        const regressionJsonPath = findRegressionJsonArtifact(root, summary, entry);
        if (regressionJsonPath) {
          try {
            const parsed = JSON.parse(fs.readFileSync(regressionJsonPath, "utf8"));
            if (parsed && Array.isArray(parsed.rows)) {
              regressionRows = parsed.rows;
            }
          } catch {
            regressionRows = [];
          }
        }
      }

      return {
        createdAt,
        summaryPath,
        entry,
        summary,
        projectName: String(details.projectName || ""),
        topModule: String(details.topModule || ""),
        mode: String(details.mode || ""),
        passCount: Number(details.passCount || 0),
        failCount: Number(details.failCount || 0),
        regressionSummaryJsonPath: String(details.regressionSummaryJsonPath || ""),
        regressionRows: Array.isArray(regressionRows) ? regressionRows : [],
      };
    })
    .filter((row) => row.regressionRows.length > 0);
}

function appendRunIndex(projectRoot, summary) {
  const root = path.resolve(projectRoot || process.cwd());
  const outputDir = path.join(root, "output");
  const indexPath = resolveRunIndexPath(root);
  ensureDir(outputDir);

  const payload = readRunIndex(root);

  const normalizedSummary = {
    ...summary,
    outputs: normalizeArtifactList(root, summary.outputs || []),
    summaryPath: normalizeArtifactPath(root, summary.summaryPath || ""),
  };
  payload.updatedAt = new Date().toISOString();
  payload.runs.push(normalizedSummary);
  writeJson(indexPath, payload);
  return indexPath;
}

function appendRunEntry(projectRoot, entry) {
  const summary = createRunRegistryEntry({
    tool: entry.tool || "unknown",
    projectRoot,
    manifestJsonPath: entry.manifestJsonPath || "",
    status: entry.status || "unknown",
    outputs: entry.outputs || [],
    summaryPath: entry.summaryPath || "",
    metadata: entry.metadata || {},
    createdAt: entry.createdAt || new Date().toISOString(),
  });
  return appendRunIndex(projectRoot, summary);
}

module.exports = {
  appendRunEntry,
  appendRunIndex,
  createEmptyRunIndex,
  resolveRunIndexPath,
  readRunIndex,
  readRunSummaries,
  findLatestRunByTool,
  collectSimulationRegressionRuns,
  ensureDir,
  writeJson,
};
