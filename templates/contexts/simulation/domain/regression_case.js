function createRegressionCase(input) {
  const reason = input.reason || "ok";
  return {
    testName: input.testName,
    pass: reason === "ok",
    checkedCount: input.checkedCount || 0,
    errorCount: Number.isFinite(input.errorCount) ? input.errorCount : NaN,
    reason,
    logPath: input.logPath || "",
  };
}

module.exports = {
  createRegressionCase,
};
