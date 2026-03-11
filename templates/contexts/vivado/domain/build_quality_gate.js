const fs = require("fs");
const path = require("path");

function normalizeSlashes(value) {
  return String(value || "").replace(/\\/g, "/");
}

function readTextIfExists(filePath) {
  const abs = path.resolve(filePath);
  if (!fs.existsSync(abs)) return "";
  return fs.readFileSync(abs, "utf8");
}

function parseCheckedMetric(logText, label) {
  const escaped = String(label || "").replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const re = new RegExp(`${escaped}\\s*=\\s*([-+]?\\d+(?:\\.\\d+)?)\\s+\\S+\\s+\\.\\.\\.\\s+\\[(PASS|FAIL)\\]`, "i");
  const match = String(logText || "").match(re);
  if (!match) {
    return {
      value: null,
      status: "unknown",
    };
  }
  return {
    value: Number(match[1]),
    status: match[2].toLowerCase() === "pass" ? "ok" : "failed",
  };
}

function parseCdcMetric(logText) {
  const re = /CDC Violations\s*=\s*(\d+)\s+\S+\s+\.{3}\s+\[(PASS|FAIL)\]/i;
  const match = String(logText || "").match(re);
  if (!match) {
    return {
      value: null,
      status: "unknown",
    };
  }
  return {
    value: Number(match[1]),
    status: match[2].toLowerCase() === "pass" ? "ok" : "failed",
  };
}

function findArtifacts(rootDir, extension) {
  const root = path.resolve(rootDir);
  if (!fs.existsSync(root)) return [];

  const hits = [];
  const stack = [root];
  while (stack.length > 0) {
    const current = stack.pop();
    const entries = fs.readdirSync(current, { withFileTypes: true });
    for (const entry of entries) {
      const abs = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(abs);
        continue;
      }
      if (!entry.isFile()) continue;
      if (extension && path.extname(entry.name).toLowerCase() !== extension.toLowerCase()) continue;
      hits.push(abs);
    }
  }

  return hits.sort((a, b) => a.localeCompare(b));
}

function buildQualityGate(projectRoot, buildLogPath) {
  const root = path.resolve(projectRoot || process.cwd());
  const outputDir = path.join(root, "output");
  const reportsDir = path.join(outputDir, "reports");
  const checkpointsDir = path.join(outputDir, "checkpoints");
  const finalReportHtml = path.join(outputDir, "FINALReport", "Final_Build_Report.html");
  const logText = buildLogPath ? readTextIfExists(buildLogPath) : "";
  const power = parseCheckedMetric(logText, "Total Power");
  const timing = parseCheckedMetric(logText, "WNS (Worst Negative Slack)");
  const cdc = parseCdcMetric(logText);
  const bitstreams = findArtifacts(outputDir, ".bit");
  const reports = findArtifacts(reportsDir, ".rpt");
  const checkpoints = findArtifacts(checkpointsDir, ".dcp");

  return {
    projectRoot: normalizeSlashes(root),
    logPath: buildLogPath ? normalizeSlashes(path.resolve(buildLogPath)) : "",
    bitstreams,
    reports,
    checkpoints,
    finalReportHtml: fs.existsSync(finalReportHtml) ? normalizeSlashes(finalReportHtml) : "",
    qualityGate: {
      timing: {
        status: timing.status,
        wnsNs: timing.value,
      },
      power: {
        status: power.status,
        totalOnChipPowerW: power.value,
      },
      cdc: {
        status: cdc.status,
        violationCount: cdc.value,
      },
      bitstream: {
        status: bitstreams.length > 0 ? "ok" : "missing",
        count: bitstreams.length,
        primaryPath: bitstreams.length > 0 ? normalizeSlashes(bitstreams[0]) : "",
      },
    },
  };
}

module.exports = {
  buildQualityGate,
};
