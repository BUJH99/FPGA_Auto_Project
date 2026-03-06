function normalizeNumber(value, fallback) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function normalizeScenario(scenario, index) {
  const startNs = Math.max(0, Math.round(normalizeNumber(scenario.start_ns, 0)));
  const durationNs = Math.max(1, Math.round(normalizeNumber(scenario.duration_ns, 100000)));
  const stepNs = Math.max(1, Math.round(normalizeNumber(scenario.sample_step_ns, 100)));
  const signals = Array.from(new Set(Array.isArray(scenario.signals) ? scenario.signals.filter(Boolean) : []));

  return {
    ...scenario,
    id: scenario.id || `case_${index + 1}`,
    title: scenario.title || `CASE ${index + 1}`,
    start_ns: startNs,
    duration_ns: durationNs,
    sample_step_ns: stepNs,
    signals,
  };
}

function normalizeScenarios(rawScenarios) {
  return (Array.isArray(rawScenarios) ? rawScenarios : []).map(normalizeScenario);
}

function getMaxScenarioEndNs(scenarios) {
  return (scenarios || []).reduce((maxEnd, scenario) => {
    return Math.max(maxEnd, scenario.start_ns + scenario.duration_ns);
  }, 0);
}

module.exports = {
  getMaxScenarioEndNs,
  normalizeNumber,
  normalizeScenarios,
};
