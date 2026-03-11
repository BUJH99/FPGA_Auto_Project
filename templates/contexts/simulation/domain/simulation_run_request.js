const path = require("path");
const { normalizeNumber } = require("./scenario_window");

function uniqueStrings(rows) {
  const seen = new Set();
  const out = [];
  for (const row of rows || []) {
    const value = String(row || "").trim();
    if (!value || seen.has(value)) continue;
    seen.add(value);
    out.push(value);
  }
  return out;
}

function createSimulationRunRequest(config, manifestContext, projectRoot, maxScenarioEndNs) {
  const cfg = config.config || {};
  const simDurationNs = Math.max(
    normalizeNumber(cfg.sim_duration_ns, 0),
    maxScenarioEndNs + 10000
  );

  return {
    projectRoot,
    projectName: cfg.project_name || manifestContext.snapshot.projectName || path.basename(projectRoot),
    topModule: cfg.top_module || manifestContext.snapshot.top || "tb_Top",
    tbRelPath: cfg.tb_file || (manifestContext.result.resolved.tb_files && manifestContext.result.resolved.tb_files[0]) || "",
    vcdRelPath: cfg.vcd_file || "output/mcp_sim_wave.vcd",
    htmlRelPath: cfg.html_file || `output/view_wave_${cfg.top_module || manifestContext.snapshot.top || "tb_Top"}.html`,
    simDurationNs,
    simTime: simDurationNs > 0 ? `${simDurationNs / 1000000} ms` : "5 ms",
    requestedTestNames: uniqueStrings(Array.isArray(cfg.test_names) ? cfg.test_names : []),
  };
}

module.exports = {
  createSimulationRunRequest,
};
