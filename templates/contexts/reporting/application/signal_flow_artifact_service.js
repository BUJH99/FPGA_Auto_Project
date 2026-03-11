const { writeSignalFlowResultArtifacts } = require("./signal_flow_result_service");

function writeSignalFlowArtifacts(payload = {}) {
  return writeSignalFlowResultArtifacts(payload).contractPath;
}

module.exports = {
  writeSignalFlowArtifacts,
  writeSignalFlowResultArtifacts,
};
