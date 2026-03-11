function createWaveArtifactSet(generatedFiles) {
  return {
    generatedFiles: Array.isArray(generatedFiles) ? generatedFiles : [],
    count: Array.isArray(generatedFiles) ? generatedFiles.length : 0,
  };
}

module.exports = {
  createWaveArtifactSet,
};
