const { addError } = require("./manifest_result");

function isPlainObject(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function validateOptionalString(result, container, key, refPath) {
  if (!Object.prototype.hasOwnProperty.call(container, key)) return;
  if (typeof container[key] !== "string" || container[key].trim() === "") {
    addError(result, "manifest_type_error", `Field ${refPath} must be a non-empty string`, refPath);
  }
}

function validateOptionalStringAllowEmpty(result, container, key, refPath) {
  if (!Object.prototype.hasOwnProperty.call(container, key)) return;
  if (typeof container[key] !== "string") {
    addError(result, "manifest_type_error", `Field ${refPath} must be a string`, refPath);
  }
}

function validateOptionalBoolean(result, container, key, refPath) {
  if (!Object.prototype.hasOwnProperty.call(container, key)) return;
  if (typeof container[key] !== "boolean") {
    addError(result, "manifest_type_error", `Field ${refPath} must be a boolean`, refPath);
  }
}

function validateOptionalNumber(result, container, key, refPath) {
  if (!Object.prototype.hasOwnProperty.call(container, key)) return;
  if (!Number.isFinite(container[key])) {
    addError(result, "manifest_type_error", `Field ${refPath} must be a number`, refPath);
  }
}

function validateOptionalStringArray(result, container, key, refPath) {
  if (!Object.prototype.hasOwnProperty.call(container, key)) return;
  if (!Array.isArray(container[key]) || !container[key].every((item) => typeof item === "string")) {
    addError(result, "manifest_type_error", `Field ${refPath} must be a string array`, refPath);
  }
}

function validateScenarioRows(result, simConfig) {
  if (!Object.prototype.hasOwnProperty.call(simConfig, "scenarios")) return;
  if (!Array.isArray(simConfig.scenarios)) {
    addError(result, "manifest_type_error", "Field sim.scenarios must be an array", "sim.scenarios");
    return;
  }

  simConfig.scenarios.forEach((scenario, index) => {
    const base = `sim.scenarios[${index}]`;
    if (!isPlainObject(scenario)) {
      addError(result, "manifest_type_error", `Field ${base} must be an object`, base);
      return;
    }
    validateOptionalString(result, scenario, "id", `${base}.id`);
    validateOptionalString(result, scenario, "title", `${base}.title`);
    validateOptionalString(result, scenario, "description", `${base}.description`);
    validateOptionalNumber(result, scenario, "start_ns", `${base}.start_ns`);
    validateOptionalNumber(result, scenario, "duration_ns", `${base}.duration_ns`);
    validateOptionalNumber(result, scenario, "sample_step_ns", `${base}.sample_step_ns`);
    validateOptionalStringArray(result, scenario, "signals", `${base}.signals`);
  });
}

function validateOptionalObject(result, container, key, refPath) {
  if (!Object.prototype.hasOwnProperty.call(container, key)) return null;
  if (!isPlainObject(container[key])) {
    addError(result, "manifest_type_error", `Field ${refPath} must be an object`, refPath);
    return null;
  }
  return container[key];
}

function validateVitisApplications(result, vitisConfig) {
  if (!Object.prototype.hasOwnProperty.call(vitisConfig, "applications")) return;
  if (!Array.isArray(vitisConfig.applications)) {
    addError(result, "manifest_type_error", "Field vitis.applications must be an array", "vitis.applications");
    return;
  }

  vitisConfig.applications.forEach((application, index) => {
    const base = `vitis.applications[${index}]`;
    if (!isPlainObject(application)) {
      addError(result, "manifest_type_error", `Field ${base} must be an object`, base);
      return;
    }

    validateOptionalString(result, application, "name", `${base}.name`);
    validateOptionalString(result, application, "template", `${base}.template`);
    validateOptionalString(result, application, "domain", `${base}.domain`);
    validateOptionalString(result, application, "linker_script", `${base}.linker_script`);
    validateOptionalString(result, application, "target", `${base}.target`);
    validateOptionalStringArray(result, application, "sources", `${base}.sources`);
    validateOptionalStringArray(result, application, "includes", `${base}.includes`);
  });
}

function validateVitisSection(result, config) {
  if (!Object.prototype.hasOwnProperty.call(config, "vitis")) return;
  const vitisConfig = config.vitis;
  if (!isPlainObject(vitisConfig)) {
    addError(result, "manifest_type_error", "Field vitis must be an object", "vitis");
    return;
  }

  validateOptionalString(result, vitisConfig, "workspace", "vitis.workspace");

  const xsaConfig = validateOptionalObject(result, vitisConfig, "xsa", "vitis.xsa");
  if (xsaConfig) {
    validateOptionalString(result, xsaConfig, "path", "vitis.xsa.path");
    validateOptionalStringAllowEmpty(result, xsaConfig, "export_tcl", "vitis.xsa.export_tcl");
    validateOptionalStringAllowEmpty(result, xsaConfig, "generated_path", "vitis.xsa.generated_path");
    validateOptionalStringAllowEmpty(result, xsaConfig, "bit_path", "vitis.xsa.bit_path");
    validateOptionalStringAllowEmpty(result, xsaConfig, "vivado_project", "vitis.xsa.vivado_project");
    validateOptionalString(result, xsaConfig, "impl_run", "vitis.xsa.impl_run");
    validateOptionalStringArray(result, xsaConfig, "bit_globs", "vitis.xsa.bit_globs");
    validateOptionalBoolean(result, xsaConfig, "include_bitstream", "vitis.xsa.include_bitstream");
    validateOptionalBoolean(result, xsaConfig, "fixed", "vitis.xsa.fixed");
    validateOptionalBoolean(result, xsaConfig, "validate", "vitis.xsa.validate");
  }

  const platformConfig = validateOptionalObject(result, vitisConfig, "platform", "vitis.platform");
  if (platformConfig) {
    validateOptionalString(result, platformConfig, "name", "vitis.platform.name");
    validateOptionalString(result, platformConfig, "xpfm", "vitis.platform.xpfm");
    validateOptionalString(result, platformConfig, "os", "vitis.platform.os");
    validateOptionalString(result, platformConfig, "cpu", "vitis.platform.cpu");
    validateOptionalString(result, platformConfig, "domain_name", "vitis.platform.domain_name");
  }

  validateVitisApplications(result, vitisConfig);
  validateOptionalObject(result, vitisConfig, "run", "vitis.run");
}

function validateOptionalSections(result, config) {
  const sections = [
    ["sim", ["tool", "timescale", "top_module", "tb_file", "vcd_file", "html_file"]],
    ["vivado", ["part", "strategy", "top_module", "project_name"]],
    ["report", ["format", "output", "top_module", "signal_query"]],
  ];

  for (const [sectionName, stringFields] of sections) {
    if (!Object.prototype.hasOwnProperty.call(config, sectionName)) continue;
    const section = config[sectionName];
    if (!isPlainObject(section)) {
      addError(result, "manifest_type_error", `Field ${sectionName} must be an object`, sectionName);
      continue;
    }
    for (const fieldName of stringFields) {
      validateOptionalString(result, section, fieldName, `${sectionName}.${fieldName}`);
    }
  }

  if (isPlainObject(config.sim)) {
    validateOptionalStringArray(result, config.sim, "test_names", "sim.test_names");
    validateScenarioRows(result, config.sim);
  }
  if (isPlainObject(config.vivado)) {
    validateOptionalNumber(result, config.vivado, "power_limit_w", "vivado.power_limit_w");
  }
  if (isPlainObject(config.report)) {
    validateOptionalBoolean(result, config.report, "enable", "report.enable");
    validateOptionalStringArray(result, config.report, "modules", "report.modules");
  }

  validateVitisSection(result, config);
}

function validateManifestShape(result, config) {
  const requiredChecks = [
    {
      ok: config && Object.prototype.hasOwnProperty.call(config, "version"),
      path: "version",
      message: "Missing required field: version",
    },
    {
      ok: config && config.project && Object.prototype.hasOwnProperty.call(config.project, "name"),
      path: "project.name",
      message: "Missing required field: project.name",
    },
    {
      ok: config && config.hdl && Object.prototype.hasOwnProperty.call(config.hdl, "top"),
      path: "hdl.top",
      message: "Missing required field: hdl.top",
    },
    {
      ok: config && config.hdl && Object.prototype.hasOwnProperty.call(config.hdl, "src_globs"),
      path: "hdl.src_globs",
      message: "Missing required field: hdl.src_globs",
    },
    {
      ok: config && config.hdl && Object.prototype.hasOwnProperty.call(config.hdl, "tb_globs"),
      path: "hdl.tb_globs",
      message: "Missing required field: hdl.tb_globs",
    },
  ];

  for (const check of requiredChecks) {
    if (!check.ok) {
      addError(result, "manifest_required_field", check.message, check.path);
    }
  }

  if (result.errors.length > 0) {
    return false;
  }

  if (typeof config.version !== "string" || config.version.trim() === "") {
    addError(result, "manifest_type_error", "Field version must be a non-empty scalar", "version");
  }
  if (typeof config.project.name !== "string" || config.project.name.trim() === "") {
    addError(result, "manifest_type_error", "Field project.name must be a non-empty string", "project.name");
  }
  if (typeof config.hdl.top !== "string" || config.hdl.top.trim() === "") {
    addError(result, "manifest_type_error", "Field hdl.top must be a non-empty string", "hdl.top");
  }

  const requireStringArray = (value) =>
    Array.isArray(value) && value.length > 0 && value.every((item) => typeof item === "string");
  const allowStringArray = (value) =>
    Array.isArray(value) && value.every((item) => typeof item === "string");

  if (!requireStringArray(config.hdl.src_globs)) {
    addError(result, "manifest_type_error", "Field hdl.src_globs must be a non-empty string array", "hdl.src_globs");
  }
  if (!requireStringArray(config.hdl.tb_globs)) {
    addError(result, "manifest_type_error", "Field hdl.tb_globs must be a non-empty string array", "hdl.tb_globs");
  }

  const optionalArrays = ["inc_globs", "xdc_globs", "exclude_globs"];
  for (const field of optionalArrays) {
    if (Object.prototype.hasOwnProperty.call(config.hdl, field) && !allowStringArray(config.hdl[field])) {
      addError(result, "manifest_type_error", `Field hdl.${field} must be a string array`, `hdl.${field}`);
    }
  }

  validateOptionalSections(result, config);

  return result.errors.length === 0;
}

module.exports = {
  validateManifestShape,
};
