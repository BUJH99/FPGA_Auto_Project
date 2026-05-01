function sanitizeName(value, fallback = "project") {
  const raw = String(value || "").trim();
  const cleaned = raw.replace(/[^A-Za-z0-9_.-]+/g, "_").replace(/^_+|_+$/g, "");
  return cleaned || fallback;
}

function interpolateTemplate(value, variables = {}) {
  return String(value || "")
    .replace(/\$\{project\.name\}/g, String(variables.projectName || ""))
    .replace(/\$\{timestamp\}/g, String(variables.timestamp || ""))
    .replace(/\$\{platform\.name\}/g, String(variables.platformName || ""))
    .replace(/\$\{platformName\}/g, String(variables.platformName || ""))
    .replace(/\$\{app\.name\}/g, String(variables.appName || ""))
    .replace(/\$\{appName\}/g, String(variables.appName || ""));
}

function defaultWorkspace() {
  return "output/vitis/workspace";
}

function defaultXsaPath(projectName) {
  return `output/vitis/xsa/${sanitizeName(projectName)}.xsa`;
}

function defaultBitGlobs(projectName) {
  const name = sanitizeName(projectName);
  return [
    `output/${name}.bit`,
    "output/*.bit",
    "output/vivado/**/*.runs/impl_1/*.bit",
    "output/vivado/**/*.runs/*/*.bit",
  ];
}

function defaultPlatformName(projectName) {
  return `${sanitizeName(projectName)}_platform`;
}

function defaultPlatformXpfm(platformName) {
  const name = sanitizeName(platformName, "platform");
  return `output/vitis/workspace/${name}/export/${name}/${name}.xpfm`;
}

function defaultApplicationSources(appName) {
  const name = sanitizeName(appName, "app");
  return [`sw/apps/${name}/src/**/*`, "sw/common/src/**/*"];
}

function defaultApplicationIncludes(appName) {
  const name = sanitizeName(appName, "app");
  return [`sw/apps/${name}/include`, "sw/common/include"];
}

function defaultSummaryFile(step) {
  const names = {
    export_xsa: "xsa_export_summary.json",
    create_platform: "platform_create_summary.json",
    create_application: "app_create_summary.json",
    build_platform: "platform_build_summary.json",
    build_application: "app_build_summary.json",
    run_application: "app_run_summary.json",
    full_flow: "full_flow_summary.json",
  };
  return names[step] || `${String(step || "vitis")}_summary.json`;
}

module.exports = {
  sanitizeName,
  interpolateTemplate,
  defaultWorkspace,
  defaultXsaPath,
  defaultBitGlobs,
  defaultPlatformName,
  defaultPlatformXpfm,
  defaultApplicationSources,
  defaultApplicationIncludes,
  defaultSummaryFile,
};
