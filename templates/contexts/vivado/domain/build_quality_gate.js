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

function readJsonIfExists(filePath) {
  const abs = path.resolve(filePath);
  if (!fs.existsSync(abs)) return null;
  try {
    return JSON.parse(fs.readFileSync(abs, "utf8"));
  } catch {
    return null;
  }
}

function asNumber(value) {
  if (value === null || value === undefined || value === "") return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function deriveTimingStatusFromReport(reportStatus, wnsNs, tnsNs) {
  if (Number(reportStatus && reportStatus.timingPass) === 1) return "ok";
  if (Number(reportStatus && reportStatus.timingPass) === 0) return "failed";
  if (wnsNs === null) return "unknown";
  if (wnsNs < 0) return "failed";
  if (tnsNs !== null && tnsNs !== 0) return "failed";
  return "ok";
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

function resolveConfiguredOutputDir(projectRoot) {
  const configured = String(process.env.FPGA_CLAW_OUTPUT_DIR || "").trim();
  if (!configured) return path.join(projectRoot, "output");
  if (path.isAbsolute(configured) || /^[A-Za-z]:[\\/]/.test(configured)) return path.normalize(configured);
  return path.resolve(projectRoot, configured);
}

function buildQualityGate(projectRoot, buildLogPath) {
  const root = path.resolve(projectRoot || process.cwd());
  const outputDir = resolveConfiguredOutputDir(root);
  const reportsDir = path.join(outputDir, "reports");
  const checkpointsDir = path.join(outputDir, "checkpoints");
  const finalReportHtml = path.join(outputDir, "FINALReport", "Final_Build_Report.html");
  const finalReportData = readJsonIfExists(path.join(outputDir, "FINALReport", "report_data.json"));
  const logText = buildLogPath ? readTextIfExists(buildLogPath) : "";
  const powerFromLog = parseCheckedMetric(logText, "Total Power");
  const timingFromLog = parseCheckedMetric(logText, "WNS (Worst Negative Slack)");
  const cdcFromLog = parseCdcMetric(logText);
  const reportTiming = finalReportData && finalReportData.timing ? finalReportData.timing : {};
  const reportPower = finalReportData && finalReportData.power ? finalReportData.power : {};
  const reportCdc = finalReportData && finalReportData.cdc ? finalReportData.cdc : {};
  const reportStatus = finalReportData && finalReportData.status ? finalReportData.status : {};
  const wnsNs = timingFromLog.value !== null ? timingFromLog.value : asNumber(reportTiming.wns);
  const tnsNs = asNumber(reportTiming.tns);
  const timingStatus = timingFromLog.status !== "unknown"
    ? timingFromLog.status
    : deriveTimingStatusFromReport(reportStatus, wnsNs, tnsNs);
  const powerW = powerFromLog.value !== null ? powerFromLog.value : asNumber(reportPower.total);
  const powerStatus = powerFromLog.status !== "unknown" ? powerFromLog.status : (powerW !== null ? "ok" : "unknown");
  const cdcViolations = cdcFromLog.value !== null ? cdcFromLog.value : asNumber(reportCdc.violations);
  const cdcStatus = cdcFromLog.status !== "unknown" ? cdcFromLog.status : (cdcViolations !== null ? (cdcViolations === 0 ? "ok" : "failed") : "unknown");
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
        status: timingStatus,
        wnsNs,
      },
      power: {
        status: powerStatus,
        totalOnChipPowerW: powerW,
      },
      cdc: {
        status: cdcStatus,
        violationCount: cdcViolations,
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
