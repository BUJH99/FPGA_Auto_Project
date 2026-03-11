const {
  normalizeArtifactPath,
  normalizeArtifactList,
  createRunSummary,
  createBuildSummary,
} = require("./run_contracts");

function createSignalFlowArtifact(input = {}) {
  return {
    schemaVersion: 1,
    kind: "signal_flow",
    generatedAt: input.generatedAt || new Date().toISOString(),
    projectName: input.projectName || "",
    topModule: input.topModule || "",
    signalQuery: input.signalQuery || "",
    matchedNodes: input.matchedNodes || [],
    warnings: input.warnings || [],
    upstream: input.upstream || { edges: [], truncated: false },
    downstream: input.downstream || { edges: [], truncated: false },
  };
}

module.exports = {
  createBuildSummary,
  createRunSummary,
  createSignalFlowArtifact,
  normalizeArtifactList,
  normalizeArtifactPath,
};
