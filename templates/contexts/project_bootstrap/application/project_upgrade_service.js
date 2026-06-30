const fs = require("fs");
const path = require("path");
const YAML = require("yaml");
const { writeJsonFile } = require("../../../shared/application/json_file_service");
const { appendRunEntry } = require("../../../shared/application/run_registry_service");
const { loadManifestResult } = require("../../../shared/application/manifest_contract_loader");
const {
  createArtifactRecord,
  createMigrationSummary,
  normalizeSlashes,
} = require("../../../shared/domain/run_contracts");

const SCAFFOLD_DIRS = [
  "tb",
  "include",
  "inc",
  "constrs",
  "sw/common/include",
  "sw/common/src",
  "sw/apps/hello_world/src",
  "sw/apps/hello_world/include",
  "sw/apps/hello_world/data",
  "vitis/launch",
  "vitis/bsp_overrides",
  "output/vitis/xsa",
  "output/vitis/workspace",
  "output/vitis/platform",
  "output/vitis/apps",
  "output/vitis/summaries",
  "log/vitis",
];

const STARTER_MAIN_C = [
  "int main(void) {",
  "    return 0;",
  "}",
  "",
].join("\n");

const HARDWARE_JSON = {
  mode: "hardware",
  hw_server: "",
  device_index: null,
};
const PROJECT_LAUNCHER_FILE = "fpgaclaw.cmd";
const PROJECT_LAUNCHER_TEMPLATE = path.resolve(__dirname, "../../../project/fpgaclaw.cmd");

function isPlainObject(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function tsNow() {
  const now = new Date();
  const yyyy = now.getFullYear();
  const mm = String(now.getMonth() + 1).padStart(2, "0");
  const dd = String(now.getDate()).padStart(2, "0");
  const hh = String(now.getHours()).padStart(2, "0");
  const mi = String(now.getMinutes()).padStart(2, "0");
  const ss = String(now.getSeconds()).padStart(2, "0");
  return `${yyyy}${mm}${dd}_${hh}${mi}${ss}`;
}

function ensureDir(dirPath) {
  if (!fs.existsSync(dirPath)) {
    fs.mkdirSync(dirPath, { recursive: true });
  }
}

function renderProjectLauncher(repoRoot) {
  const template = fs.readFileSync(PROJECT_LAUNCHER_TEMPLATE, "utf8");
  return template.replace(/__FPGA_CLAW_REPO_ROOT__/g, path.resolve(repoRoot || process.cwd()));
}

function defaultVitisManifestSection() {
  return {
    workspace: "output/vitis/workspace",
    xsa: {
      path: "output/vitis/xsa/${project.name}.xsa",
      bit_path: "",
      bit_globs: [
        "output/*.bit",
        "output/vivado/**/*.runs/impl_1/*.bit",
        "output/vivado/**/*.runs/*/*.bit",
      ],
      vivado_project: "",
      impl_run: "impl_1",
      include_bitstream: true,
      fixed: true,
      validate: true,
    },
    platform: {
      name: "${project.name}_platform",
      xpfm: "output/vitis/workspace/${platform.name}/export/${platform.name}/${platform.name}.xpfm",
      os: "standalone",
      cpu: "auto",
      domain_name: "standalone_domain",
    },
    applications: [
      {
        name: "hello_world",
        template: "empty_application",
        domain: "standalone_domain",
        sources: [
          "sw/apps/hello_world/src/**/*",
          "sw/common/src/**/*",
        ],
        includes: [
          "sw/apps/hello_world/include",
          "sw/common/include",
        ],
        target: "hw",
      },
    ],
    run: {
      mode: "hardware",
      hw_server: "",
      device_index: null,
      auto: false,
    },
  };
}

function isEmptyString(value) {
  return typeof value === "string" && value.trim() === "";
}

function mergeMissingObject(target, defaults, basePath, changes, warnings) {
  if (!isPlainObject(target)) {
    warnings.push(`${basePath}:not_object`);
    return;
  }

  for (const [key, defaultValue] of Object.entries(defaults)) {
    const refPath = `${basePath}.${key}`;
    if (!Object.prototype.hasOwnProperty.call(target, key)) {
      target[key] = clone(defaultValue);
      changes.push(`manifest_added:${refPath}`);
      continue;
    }

    if (isPlainObject(defaultValue)) {
      if (isPlainObject(target[key])) {
        mergeMissingObject(target[key], defaultValue, refPath, changes, warnings);
      } else {
        warnings.push(`${refPath}:not_object_kept_existing`);
      }
      continue;
    }

    if (typeof defaultValue === "string" && defaultValue.trim() !== "" && isEmptyString(target[key])) {
      target[key] = defaultValue;
      changes.push(`manifest_repaired_empty:${refPath}`);
    }
  }
}

function mergeApplicationDefaults(vitisConfig, defaultApp, changes, warnings) {
  if (!Object.prototype.hasOwnProperty.call(vitisConfig, "applications")) {
    vitisConfig.applications = [clone(defaultApp)];
    changes.push("manifest_added:vitis.applications");
    return;
  }

  if (!Array.isArray(vitisConfig.applications)) {
    warnings.push("vitis.applications:not_array_kept_existing");
    return;
  }

  const match = vitisConfig.applications.find((entry) =>
    isPlainObject(entry) && String(entry.name || "").trim().toLowerCase() === "hello_world"
  );

  if (!match) {
    vitisConfig.applications.push(clone(defaultApp));
    changes.push("manifest_added:vitis.applications.hello_world");
    return;
  }

  mergeMissingObject(match, defaultApp, "vitis.applications.hello_world", changes, warnings);
}

function upgradeManifestConfig(config, changes, warnings) {
  if (!isPlainObject(config)) {
    throw new Error("fpga_auto.yml root must be an object");
  }

  const defaults = defaultVitisManifestSection();
  if (!Object.prototype.hasOwnProperty.call(config, "vitis")) {
    config.vitis = clone(defaults);
    changes.push("manifest_added:vitis");
    return;
  }

  if (!isPlainObject(config.vitis)) {
    warnings.push("vitis:not_object_kept_existing");
    return;
  }

  const defaultApp = defaults.applications[0];
  const shallowDefaults = { ...defaults };
  delete shallowDefaults.applications;
  mergeMissingObject(config.vitis, shallowDefaults, "vitis", changes, warnings);
  mergeApplicationDefaults(config.vitis, defaultApp, changes, warnings);
}

function listManagedProjects(projectRoot, selector = "") {
  const root = path.resolve(projectRoot || path.join(process.cwd(), "..", "Project"));
  const selected = String(selector || "").trim();

  if (selected) {
    const byPath = path.isAbsolute(selected) ? path.resolve(selected) : path.resolve(root, selected);
    return [byPath];
  }

  if (!fs.existsSync(root)) return [];
  return fs
    .readdirSync(root, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => path.join(root, entry.name))
    .filter((candidate) =>
      fs.existsSync(path.join(candidate, "src")) &&
      fs.existsSync(path.join(candidate, "fpga_auto.yml"))
    )
    .sort((left, right) => left.localeCompare(right));
}

function validateManagedProject(projectPath) {
  if (!fs.existsSync(projectPath) || !fs.statSync(projectPath).isDirectory()) {
    return "project_directory_missing";
  }
  if (!fs.existsSync(path.join(projectPath, "src"))) {
    return "src_directory_missing";
  }
  if (!fs.existsSync(path.join(projectPath, "fpga_auto.yml"))) {
    return "manifest_missing";
  }
  return "";
}

function planProjectUpgrade(projectPath, repoRoot = process.cwd()) {
  const root = path.resolve(projectPath);
  const dirs = SCAFFOLD_DIRS
    .map((row) => path.join(root, row))
    .filter((dirPath) => !fs.existsSync(dirPath))
    .map((dirPath) => normalizeSlashes(path.relative(root, dirPath)));
  const files = [];

  const mainPath = path.join(root, "sw", "apps", "hello_world", "src", "main.c");
  if (!fs.existsSync(mainPath)) {
    files.push("sw/apps/hello_world/src/main.c");
  }

  const hardwarePath = path.join(root, "vitis", "launch", "hardware.json");
  if (!fs.existsSync(hardwarePath)) {
    files.push("vitis/launch/hardware.json");
  }

  const launcherPath = path.join(root, PROJECT_LAUNCHER_FILE);
  const launcherText = renderProjectLauncher(repoRoot);
  if (!fs.existsSync(launcherPath) || fs.readFileSync(launcherPath, "utf8") !== launcherText) {
    files.push(PROJECT_LAUNCHER_FILE);
  }

  return { dirs, files };
}

function writeScaffold(projectPath, plan, changes, repoRoot = process.cwd()) {
  for (const relDir of plan.dirs) {
    ensureDir(path.join(projectPath, relDir));
    changes.push(`dir_created:${relDir}`);
  }

  if (plan.files.includes("sw/apps/hello_world/src/main.c")) {
    const mainPath = path.join(projectPath, "sw", "apps", "hello_world", "src", "main.c");
    ensureDir(path.dirname(mainPath));
    fs.writeFileSync(mainPath, STARTER_MAIN_C, "utf8");
    changes.push("file_created:sw/apps/hello_world/src/main.c");
  }

  if (plan.files.includes("vitis/launch/hardware.json")) {
    const hardwarePath = path.join(projectPath, "vitis", "launch", "hardware.json");
    ensureDir(path.dirname(hardwarePath));
    fs.writeFileSync(hardwarePath, `${JSON.stringify(HARDWARE_JSON, null, 2)}\n`, "utf8");
    changes.push("file_created:vitis/launch/hardware.json");
  }

  if (plan.files.includes(PROJECT_LAUNCHER_FILE)) {
    const launcherPath = path.join(projectPath, PROJECT_LAUNCHER_FILE);
    const existed = fs.existsSync(launcherPath);
    fs.writeFileSync(launcherPath, renderProjectLauncher(repoRoot), "utf8");
    changes.push(`${existed ? "file_updated" : "file_created"}:${PROJECT_LAUNCHER_FILE}`);
  }
}

function upgradeProject(projectPath, request) {
  const root = path.resolve(projectPath);
  const row = {
    name: path.basename(root),
    projectRoot: normalizeSlashes(root),
    status: "pending",
    plannedDirs: [],
    plannedFiles: [],
    changes: [],
    warnings: [],
    errors: [],
  };

  const validationError = validateManagedProject(root);
  if (validationError) {
    row.status = "failed";
    row.errors.push(validationError);
    return row;
  }

  try {
    const scaffoldPlan = planProjectUpgrade(root, request.repoRoot);
    row.plannedDirs = scaffoldPlan.dirs;
    row.plannedFiles = scaffoldPlan.files;

    const manifestPath = path.join(root, "fpga_auto.yml");
    const raw = fs.readFileSync(manifestPath, "utf8");
    const parsed = YAML.parse(raw);
    const hadVitisSection = isPlainObject(parsed) && Object.prototype.hasOwnProperty.call(parsed, "vitis");
    upgradeManifestConfig(parsed, row.changes, row.warnings);

    if (request.dryRun) {
      row.status = "dry_run";
      if (row.changes.length === 0 && scaffoldPlan.dirs.length === 0 && scaffoldPlan.files.length === 0) {
        row.changes.push("already_current");
      }
      return row;
    }

    writeScaffold(root, scaffoldPlan, row.changes, request.repoRoot);
    const manifestChanged = row.changes.some((change) => String(change || "").startsWith("manifest_"));
    if (manifestChanged) {
      const manifestText = hadVitisSection
        ? YAML.stringify(parsed)
        : `${raw.replace(/\s*$/g, "")}\n${YAML.stringify({ vitis: parsed.vitis })}`;
      fs.writeFileSync(manifestPath, manifestText, "utf8");
    }

    const resolved = loadManifestResult(root);
    if (Array.isArray(resolved.errors) && resolved.errors.length > 0) {
      row.status = "failed";
      row.errors.push(`manifest_validation_failed:${resolved.errors.map((entry) => entry.code).join(",")}`);
    } else {
      row.status = row.changes.length > 0 ? "upgraded" : "current";
      if (row.changes.length === 0) row.changes.push("already_current");
    }
  } catch (err) {
    row.status = "failed";
    row.errors.push(err.message);
  }

  return row;
}

function executeProjectUpgrade(requestInput = {}) {
  const request = {
    repoRoot: path.resolve(requestInput.repoRoot || process.cwd()),
    projectRoot: path.resolve(requestInput.projectRoot || path.join(requestInput.repoRoot || process.cwd(), "..", "Project")),
    project: String(requestInput.project || "").trim(),
    dryRun: Boolean(requestInput.dryRun),
  };
  const warnings = [];
  const projectRows = listManagedProjects(request.projectRoot, request.project);
  const results = projectRows.map((projectPath) => upgradeProject(projectPath, request));

  if (request.dryRun) {
    warnings.push("dry_run:no_files_modified");
  }
  if (projectRows.length === 0) {
    warnings.push("no_managed_projects_found");
  }

  return {
    schemaVersion: 1,
    policy: "in_place_vitis_scaffold_upgrade",
    repoRoot: normalizeSlashes(request.repoRoot),
    projectRoot: normalizeSlashes(request.projectRoot),
    project: request.project,
    dryRun: request.dryRun,
    scanned: projectRows.length,
    upgraded: results.filter((row) => row.status === "upgraded").length,
    current: results.filter((row) => row.status === "current").length,
    failed: results.filter((row) => row.status === "failed").length,
    results,
    warnings,
    reportFileName: `project_upgrade_report_${tsNow()}.json`,
  };
}

function writeProjectUpgradeReport(report, repoRoot) {
  const reportDir = path.join(repoRoot, "output", "project_upgrade");
  const fileName = report.reportFileName || `project_upgrade_report_${tsNow()}.json`;
  return writeJsonFile(path.join(reportDir, fileName), report);
}

function writeProjectUpgradeArtifacts(resultInput, repoRootInput = "") {
  const result = resultInput;
  const repoRoot = path.resolve(repoRootInput || result.repoRoot || process.cwd());
  const reportPath = writeProjectUpgradeReport(result, repoRoot);
  const summaryPath = path.join(repoRoot, "output", "project_upgrade", "project_upgrade_summary.json");
  const artifacts = [
    createArtifactRecord({
      kind: "project_upgrade_summary_json",
      path: summaryPath,
      label: "project_upgrade_summary.json",
    }),
    createArtifactRecord({
      kind: "project_upgrade_report_json",
      path: reportPath,
      label: path.basename(reportPath),
    }),
  ];
  const summary = createMigrationSummary({
    tool: "project_upgrade_vitis_scaffold",
    repoRoot,
    projectRoot: result.projectRoot,
    status: result.failed > 0 ? "failed" : (result.dryRun ? "warning" : "ok"),
    warnings: result.warnings,
    artifacts,
    request: {
      repoRoot: result.repoRoot,
      projectRoot: result.projectRoot,
      project: result.project,
      dryRun: result.dryRun,
    },
    discovery: {
      scanned: result.scanned,
      projectNames: result.results.map((row) => row.name),
    },
    details: {
      upgraded: result.upgraded,
      current: result.current,
      failed: result.failed,
      results: result.results,
      reportPath: normalizeSlashes(path.relative(repoRoot, reportPath)),
    },
  });
  const writtenSummaryPath = writeJsonFile(summaryPath, summary);
  appendRunEntry(repoRoot, {
    tool: "project_upgrade_vitis_scaffold",
    projectRoot: repoRoot,
    status: summary.status,
    outputs: artifacts,
    summaryPath: writtenSummaryPath,
  });

  return {
    reportPath: normalizeSlashes(reportPath),
    summaryPath: normalizeSlashes(writtenSummaryPath),
  };
}

module.exports = {
  SCAFFOLD_DIRS,
  STARTER_MAIN_C,
  HARDWARE_JSON,
  PROJECT_LAUNCHER_FILE,
  defaultVitisManifestSection,
  executeProjectUpgrade,
  planProjectUpgrade,
  renderProjectLauncher,
  upgradeManifestConfig,
  writeProjectUpgradeArtifacts,
};
