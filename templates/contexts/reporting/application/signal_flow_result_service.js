const path = require("path");
const { writeJsonFile } = require("../../../shared/application/json_file_service");
const { appendRunEntry } = require("../../../shared/application/run_registry_service");
const {
  buildDefaultSignalFlowMarkdownRelativePath,
  createSignalFlowArtifactRecord,
  createSignalFlowPublicContract,
} = require("../domain/signal_flow_public_contract");

function resolveSignalFlowOutputPaths({
  projectRoot,
  topModule,
  signalQuery,
  outputPath = "",
} = {}) {
  const root = path.resolve(projectRoot || process.cwd());
  const markdownPath = outputPath
    ? path.resolve(outputPath)
    : path.join(
        root,
        buildDefaultSignalFlowMarkdownRelativePath({ topModule, signalQuery })
      );
  const contractPath = path.join(root, "output", "signal_flow.json");
  const primaryOutputPath = outputPath ? markdownPath : contractPath;

  return {
    projectRoot: root,
    markdownPath,
    contractPath,
    primaryOutputPath,
    usedExplicitOutput: Boolean(outputPath),
  };
}

function writeSignalFlowResultArtifacts({
  projectRoot,
  manifestJsonPath = "",
  topModule,
  signalQuery,
  outputPath = "",
  status = "generated",
  requestedTraceDepth = "",
  effectiveTraceDepth = 0,
  hierarchyDepth = 0,
  moduleCount = 0,
  hierarchyInstanceCount = 0,
  totalGraphEdges = 0,
  matchedNodes = [],
  upstreamRows = [],
  downstreamRows = [],
  upstreamModules = [],
  downstreamModules = [],
  upstreamTruncated = false,
  downstreamTruncated = false,
  warnings = [],
} = {}) {
  const outputs = resolveSignalFlowOutputPaths({
    projectRoot,
    topModule,
    signalQuery,
    outputPath,
  });

  const contract = createSignalFlowPublicContract({
    projectRoot: outputs.projectRoot,
    manifestJsonPath,
    topModule,
    signalQuery,
    status,
    requestedTraceDepth,
    effectiveTraceDepth,
    hierarchyDepth,
    moduleCount,
    hierarchyInstanceCount,
    totalGraphEdges,
    matchedNodes,
    upstreamRows,
    downstreamRows,
    upstreamModules,
    downstreamModules,
    upstreamTruncated,
    downstreamTruncated,
    warnings,
    primaryOutputPath: outputs.primaryOutputPath,
    markdownPath: outputs.markdownPath,
    artifacts: [
      createSignalFlowArtifactRecord({
        kind: "signal_flow_contract_json",
        path: outputs.contractPath,
        role: outputs.usedExplicitOutput ? "supporting" : "primary",
      }),
      createSignalFlowArtifactRecord({
        kind: "signal_flow_markdown",
        path: outputs.markdownPath,
        role: outputs.usedExplicitOutput ? "primary" : "supporting",
      }),
    ],
  });

  const contractPath = writeJsonFile(outputs.contractPath, contract);
  appendRunEntry(outputs.projectRoot, {
    tool: "signal_flow_report",
    projectRoot: outputs.projectRoot,
    manifestJsonPath,
    status,
    outputs: [
      {
        kind: "signal_flow_contract_json",
        path: contractPath,
      },
      {
        kind: "signal_flow_markdown",
        path: outputs.markdownPath,
      },
    ],
    summaryPath: contractPath,
    metadata: {
      topModule,
      signalQuery,
      matchedNodeCount: contract.matches.count,
      primaryOutputPath: outputs.primaryOutputPath,
    },
  });

  return {
    contract,
    contractPath,
    markdownPath: outputs.markdownPath,
    primaryOutputPath: outputs.primaryOutputPath,
    usedExplicitOutput: outputs.usedExplicitOutput,
  };
}

module.exports = {
  resolveSignalFlowOutputPaths,
  writeSignalFlowResultArtifacts,
};
