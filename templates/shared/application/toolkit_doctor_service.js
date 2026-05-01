const fs = require("fs");
const path = require("path");
const cp = require("child_process");
const fg = require("fast-glob");
const {
  loadManifestResult,
  loadStrictManifestContext,
  resolveProjectContext,
} = require("./manifest_contract_loader");
const { writeJsonFile } = require("./json_file_service");
const { appendRunEntry } = require("./run_registry_service");
const {
  createArtifactRecord,
  createDoctorSummary,
} = require("../domain/run_contracts");

function findExecutable(candidates) {
  for (const candidate of candidates) {
    try {
      const cmd = process.platform === "win32" ? "where" : "which";
      const out = cp.execFileSync(cmd, [candidate], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
      const first = String(out || "").split(/\r?\n/).find(Boolean);
      if (first) {
        return { ok: true, command: candidate, resolved: first.trim() };
      }
    } catch {
      // Continue
    }
  }
  return { ok: false, command: candidates[0] || "" };
}

function normalizeExecutableDir(rawValue) {
  const value = String(rawValue || "").trim();
  if (!value) return "";
  const resolved = path.resolve(value);
  if (!fs.existsSync(resolved)) return "";
  try {
    const stat = fs.statSync(resolved);
    if (stat.isDirectory()) return resolved;
    if (stat.isFile()) return path.dirname(resolved);
  } catch {
    return "";
  }
  return "";
}

function findExecutableInDir(dirPath, candidates) {
  const baseDir = normalizeExecutableDir(dirPath);
  if (!baseDir) return { ok: false, command: candidates[0] || "" };
  for (const candidate of candidates) {
    const fullPath = path.join(baseDir, candidate);
    if (fs.existsSync(fullPath)) {
      return { ok: true, command: candidate, resolved: fullPath };
    }
  }
  return { ok: false, command: candidates[0] || "" };
}

function findLatestVivadoBin(rootPath, trailingSegments) {
  if (!rootPath || !Array.isArray(trailingSegments) || trailingSegments.length === 0) return "";
  if (!fs.existsSync(rootPath)) return "";
  let entries = [];
  try {
    entries = fs.readdirSync(rootPath, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .sort((left, right) => right.localeCompare(left, undefined, { numeric: true, sensitivity: "base" }));
  } catch {
    return "";
  }

  for (const entry of entries) {
    const candidateDir = path.join(rootPath, entry, ...trailingSegments);
    if (findExecutableInDir(candidateDir, ["vivado.bat", "vivado.exe", "vivado"]).ok) {
      return candidateDir;
    }
  }
  return "";
}

function findLatestToolBin(rootPath, trailingSegments, executableCandidates) {
  if (!rootPath || !Array.isArray(trailingSegments) || trailingSegments.length === 0) return "";
  if (!fs.existsSync(rootPath)) return "";
  let entries = [];
  try {
    entries = fs.readdirSync(rootPath, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .map((entry) => entry.name)
      .sort((left, right) => right.localeCompare(left, undefined, { numeric: true, sensitivity: "base" }));
  } catch {
    return "";
  }

  for (const entry of entries) {
    const candidateDir = path.join(rootPath, entry, ...trailingSegments);
    if (findExecutableInDir(candidateDir, executableCandidates).ok) {
      return candidateDir;
    }
  }
  return "";
}

function listPreferredVivadoBins(env = process.env) {
  const ordered = [];
  const seen = new Set();

  function pushCandidate(candidateDir) {
    const normalized = normalizeExecutableDir(candidateDir);
    if (!normalized) return;
    const key = normalized.toLowerCase();
    if (seen.has(key)) return;
    seen.add(key);
    ordered.push(normalized);
  }

  pushCandidate(env.VIVADO_BIN);

  if (process.platform === "win32") {
    const systemDrive = String(env.SystemDrive || "C:");
    pushCandidate(findLatestVivadoBin(path.join(systemDrive, "AMDDesignTools"), ["Vivado", "bin"]));
    pushCandidate(findLatestVivadoBin(path.join(systemDrive, "Xilinx", "Vivado"), ["bin"]));
  }

  return ordered;
}

function findVivadoExecutable() {
  for (const preferredBin of listPreferredVivadoBins()) {
    const resolved = findExecutableInDir(preferredBin, ["vivado.bat", "vivado.exe", "vivado"]);
    if (resolved.ok) {
      return resolved;
    }
  }
  return findExecutable(["vivado", "vivado.bat"]);
}

function listPreferredVitisBins(env = process.env) {
  const ordered = [];
  const seen = new Set();

  function pushCandidate(candidateDir) {
    const normalized = normalizeExecutableDir(candidateDir);
    if (!normalized) return;
    const key = normalized.toLowerCase();
    if (seen.has(key)) return;
    seen.add(key);
    ordered.push(normalized);
  }

  pushCandidate(env.VITIS_BIN);

  if (process.platform === "win32") {
    const systemDrive = String(env.SystemDrive || "C:");
    pushCandidate(findLatestToolBin(path.join(systemDrive, "AMDDesignTools"), ["Vitis", "bin"], ["vitis.bat", "vitis.exe", "vitis"]));
    pushCandidate(findLatestToolBin(path.join(systemDrive, "Xilinx", "Vitis"), ["bin"], ["vitis.bat", "vitis.exe", "vitis"]));
  }

  return ordered;
}

function findVitisExecutable() {
  for (const preferredBin of listPreferredVitisBins()) {
    const resolved = findExecutableInDir(preferredBin, ["vitis.bat", "vitis.exe", "vitis"]);
    if (resolved.ok) {
      return resolved;
    }
  }
  return findExecutable(["vitis", "vitis.bat"]);
}

function captureToolVersion(toolCheck, args = ["-version"]) {
  if (!toolCheck || !toolCheck.ok) return "";
  const command = toolCheck.resolved || toolCheck.command || "";
  if (!command) return "";
  try {
    const out = cp.execFileSync(command, args, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 8000,
    });
    return String(out || "").split(/\r?\n/).map((line) => line.trim()).filter(Boolean)[0] || "";
  } catch (err) {
    const stdout = String(err && err.stdout ? err.stdout : "").trim();
    const stderr = String(err && err.stderr ? err.stderr : "").trim();
    return (stdout || stderr).split(/\r?\n/).map((line) => line.trim()).filter(Boolean)[0] || "";
  }
}

function checkTools() {
  const vitis = findVitisExecutable();
  if (vitis.ok) {
    vitis.version = captureToolVersion(vitis, ["-version"]);
  }
  return {
    node: findExecutable(["node", "node.exe"]),
    python: findExecutable(["python", "python3", "python.exe"]),
    vivado: findVivadoExecutable(),
    vitis,
    yosys: findExecutable(["yowasp-yosys", "yosys"]),
  };
}

function nearestExistingParent(targetPath) {
  let current = path.resolve(targetPath);
  while (current && !fs.existsSync(current)) {
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
  return current && fs.existsSync(current) ? current : "";
}

function isWritableLocation(targetPath) {
  const base = nearestExistingParent(targetPath);
  if (!base) return false;
  try {
    fs.accessSync(base, fs.constants.W_OK);
    return true;
  } catch {
    return false;
  }
}

function hasOptionalSection(config, sectionName) {
  return Boolean(config && typeof config === "object" && Object.prototype.hasOwnProperty.call(config, sectionName));
}

function basenameWithoutExt(filePath) {
  return path.basename(String(filePath || ""), path.extname(String(filePath || "")));
}

function interpolateProjectName(value, projectName) {
  return String(value || "").replace(/\$\{project\.name\}/g, projectName || "");
}

function resolveProjectRelativePath(projectRoot, rawValue) {
  const value = String(rawValue || "").trim();
  if (!value) return "";
  const interpolated = interpolateProjectName(value, path.basename(projectRoot));
  return path.isAbsolute(interpolated) ? path.resolve(interpolated) : path.resolve(projectRoot, interpolated);
}

function defaultVitisPlatformName(projectName) {
  return `${projectName || "project"}_platform`;
}

function defaultVitisXsaPath(projectRoot, projectName) {
  return path.join(projectRoot, "output", "vitis", "xsa", `${projectName || path.basename(projectRoot)}.xsa`);
}

function defaultVitisWorkspace(projectRoot) {
  return path.join(projectRoot, "output", "vitis", "workspace");
}

function defaultVitisXpfmPath(projectRoot, platformName) {
  return path.join(projectRoot, "output", "vitis", "workspace", platformName, "export", platformName, `${platformName}.xpfm`);
}

function normalizeStringRows(rows) {
  if (!Array.isArray(rows)) return [];
  return rows.map((row) => String(row || "").trim()).filter(Boolean);
}

function collectVitisChecks(projectRoot, config) {
  const root = path.resolve(projectRoot || process.cwd());
  const projectConfig = config && config.project && typeof config.project === "object" ? config.project : {};
  const projectName = String(projectConfig.name || path.basename(root));
  const vitisConfig = config && config.vitis && typeof config.vitis === "object" ? config.vitis : null;
  const platformConfig = vitisConfig && vitisConfig.platform && typeof vitisConfig.platform === "object" ? vitisConfig.platform : {};
  const xsaConfig = vitisConfig && vitisConfig.xsa && typeof vitisConfig.xsa === "object" ? vitisConfig.xsa : {};
  const platformName = interpolateProjectName(platformConfig.name || defaultVitisPlatformName(projectName), projectName);
  const workspacePath = resolveProjectRelativePath(root, vitisConfig && vitisConfig.workspace ? vitisConfig.workspace : "output/vitis/workspace");
  const xsaPath = resolveProjectRelativePath(root, xsaConfig.path || `output/vitis/xsa/${projectName}.xsa`);
  const xpfmPath = resolveProjectRelativePath(
    root,
    platformConfig.xpfm || path.relative(root, defaultVitisXpfmPath(root, platformName))
  );
  const applications = vitisConfig && Array.isArray(vitisConfig.applications) ? vitisConfig.applications : [];

  const appRows = applications.map((application, index) => {
    const app = application && typeof application === "object" ? application : {};
    const name = String(app.name || `app_${index + 1}`);
    const sourceGlobs = normalizeStringRows(app.sources);
    const matches = sourceGlobs.length > 0
      ? fg.sync(sourceGlobs.map((row) => interpolateProjectName(row, projectName)), {
        cwd: root,
        onlyFiles: true,
        dot: false,
        unique: true,
      }).sort((left, right) => left.localeCompare(right))
      : [];
    return {
      name,
      sourceGlobs,
      sourceMatchCount: matches.length,
      sourceMatches: matches.slice(0, 25),
      includes: normalizeStringRows(app.includes),
      target: String(app.target || "hw"),
    };
  });

  return {
    present: Boolean(vitisConfig),
    workspace: {
      path: workspacePath.replace(/\\/g, "/"),
      parentWritable: isWritableLocation(workspacePath),
    },
    xsa: {
      path: xsaPath.replace(/\\/g, "/"),
      exists: fs.existsSync(xsaPath),
    },
    platform: {
      name: platformName,
      xpfm: xpfmPath.replace(/\\/g, "/"),
      xpfmExists: fs.existsSync(xpfmPath),
      os: String(platformConfig.os || "standalone"),
      cpu: String(platformConfig.cpu || "auto"),
      domainName: String(platformConfig.domain_name || "standalone_domain"),
    },
    applications: appRows,
    run: vitisConfig && vitisConfig.run && typeof vitisConfig.run === "object"
      ? {
        mode: String(vitisConfig.run.mode || "hardware"),
        hwServer: String(vitisConfig.run.hw_server || ""),
        deviceIndex: Object.prototype.hasOwnProperty.call(vitisConfig.run, "device_index") ? vitisConfig.run.device_index : null,
        complete: Boolean(String(vitisConfig.run.hw_server || "").trim()) &&
          Object.prototype.hasOwnProperty.call(vitisConfig.run, "device_index"),
      }
      : { mode: "hardware", hwServer: "", deviceIndex: null, complete: false },
  };
}

function buildDoctorWarnings(report) {
  const warnings = [];
  const optionalSections = report.optionalSections || {};
  for (const [sectionName, value] of Object.entries(optionalSections)) {
    if (!value.present) {
      warnings.push(`optional_section_missing:${sectionName}`);
    }
  }

  for (const [toolName, toolCheck] of Object.entries(report.tools || {})) {
    if (!toolCheck || toolCheck.ok) continue;
    warnings.push(`tool_missing:${toolName}`);
  }

  if (report.tbNaming && !report.tbNaming.matched) {
    warnings.push(`tb_naming_mismatch:${report.tbNaming.expectedBaseName}`);
  }
  if (report.resolved && !report.resolved.topModuleExists && report.resolved.top) {
    warnings.push(`top_module_not_found:${report.resolved.top}`);
  }
  if (report.paths && !report.paths.outputParentWritable) {
    warnings.push("output_parent_not_writable");
  }
  if (report.paths && !report.paths.logParentWritable) {
    warnings.push("log_parent_not_writable");
  }
  if (report.outputDirs && !report.outputDirs.output) {
    warnings.push("output_dir_missing");
  }
  if (report.outputDirs && !report.outputDirs.log) {
    warnings.push("log_dir_missing");
  }
  if (report.resolved && report.resolved.xdcCount === 0) {
    warnings.push("xdc_missing");
  }
  if (report.vitis && report.vitis.present) {
    if (report.vitis.workspace && !report.vitis.workspace.parentWritable) {
      warnings.push("vitis_workspace_parent_not_writable");
    }
    if (report.vitis.applications && report.vitis.applications.some((app) => app.sourceGlobs.length > 0 && app.sourceMatchCount === 0)) {
      warnings.push("vitis_app_source_glob_no_match");
    }
    if (report.vitis.applications && report.vitis.applications.length > 0 && report.vitis.platform && !report.vitis.platform.xpfmExists) {
      warnings.push("vitis_platform_xpfm_missing");
    }
    if (report.vitis.xsa && !report.vitis.xsa.exists) {
      warnings.push("vitis_xsa_missing");
    }
    if (report.vitis.run && !report.vitis.run.complete) {
      warnings.push("vitis_run_config_incomplete");
    }
  }

  return warnings;
}

function runDoctor(projectRoot, manifestJsonPath, loader) {
  const root = path.resolve(projectRoot || process.cwd());
  const manifestPath = path.join(root, "fpga_auto.yml");
  const strictLoader = typeof loader === "function" ? loader : loadStrictManifestContext;
  const projectContext = resolveProjectContext(root, manifestJsonPath || "");
  const snapshotConfig = projectContext.snapshot && projectContext.snapshot.config && typeof projectContext.snapshot.config === "object"
    ? projectContext.snapshot.config
    : {};
  const catalog = projectContext.catalog || {};
  const report = {
    schemaVersion: 1,
    kind: "doctor_summary",
    generatedAt: new Date().toISOString(),
    projectRoot: root.replace(/\\/g, "/"),
    ok: false,
    status: "failed",
    manifest: {
      exists: fs.existsSync(manifestPath),
      path: manifestPath.replace(/\\/g, "/"),
      valid: false,
      error: "",
    },
    tools: checkTools(),
    resolved: {
      srcCount: 0,
      tbCount: 0,
      incCount: 0,
      xdcCount: 0,
      top: "",
      topModuleExists: false,
      ok: false,
      error: "",
    },
    outputDirs: {
      output: fs.existsSync(path.join(root, "output")),
      log: fs.existsSync(path.join(root, "log")),
      src: fs.existsSync(path.join(root, "src")),
      tb: fs.existsSync(path.join(root, "tb")),
    },
    optionalSections: {
      sim: { present: hasOptionalSection(snapshotConfig, "sim") },
      vivado: { present: hasOptionalSection(snapshotConfig, "vivado") },
      report: { present: hasOptionalSection(snapshotConfig, "report") },
      vitis: { present: hasOptionalSection(snapshotConfig, "vitis") },
    },
    vitis: collectVitisChecks(root, snapshotConfig),
    tbNaming: {
      expectedBaseName: "",
      matched: false,
      matchedFile: "",
    },
    paths: {
      outputParentWritable: isWritableLocation(path.join(root, "output", "doctor_summary.json")),
      logParentWritable: isWritableLocation(path.join(root, "log", "doctor.log")),
    },
    warnings: [],
  };

  if (manifestJsonPath) {
    try {
      const ctx = strictLoader(root, manifestJsonPath);
      report.resolved = {
        srcCount: (ctx.srcFiles || []).length,
        tbCount: (ctx.tbFiles || []).length,
        incCount: (ctx.incDirs || []).length,
        xdcCount: (ctx.xdcFiles || []).length,
        top: (ctx.snapshot && ctx.snapshot.top) || "",
        topModuleExists: false,
        ok: true,
        error: "",
      };
      report.manifest.valid = true;
    } catch (err) {
      report.resolved.error = err.message;
      report.manifest.error = err.message;
    }
  } else {
    try {
      const ctx = resolveProjectContext(root);
      report.resolved = {
        srcCount: (ctx.catalog && ctx.catalog.src_files && ctx.catalog.src_files.length) || 0,
        tbCount: (ctx.catalog && ctx.catalog.tb_files && ctx.catalog.tb_files.length) || 0,
        incCount: (ctx.catalog && ctx.catalog.inc_dirs && ctx.catalog.inc_dirs.length) || 0,
        xdcCount: (ctx.catalog && ctx.catalog.xdc_files && ctx.catalog.xdc_files.length) || 0,
        top: (ctx.snapshot && ctx.snapshot.top) || "",
        topModuleExists: false,
        ok: Boolean(ctx.ok),
        error: ctx.ok ? "" : (ctx.result.errors || []).map((row) => row.code || row.message || String(row)).join(","),
      };
      report.manifest.valid = Boolean(report.manifest.exists && ctx.ok);
      report.manifest.error = report.resolved.error;
    } catch (err) {
      report.resolved.error = err.message;
      report.manifest.error = err.message;
    }
  }

  const resolvedSrcFiles = Array.isArray(catalog.src_files) ? catalog.src_files : [];
  const resolvedTbFiles = Array.isArray(catalog.tb_files) ? catalog.tb_files : [];
  const topName = String(report.resolved.top || "").trim();
  if (topName) {
    report.resolved.topModuleExists = resolvedSrcFiles.some(
      (filePath) => basenameWithoutExt(filePath).toLowerCase() === topName.toLowerCase()
    );
    report.tbNaming.expectedBaseName = `tb_${topName}`;
    const matchedTb = resolvedTbFiles.find(
      (filePath) => basenameWithoutExt(filePath).toLowerCase() === `tb_${topName}`.toLowerCase()
    );
    report.tbNaming.matched = Boolean(matchedTb);
    report.tbNaming.matchedFile = matchedTb ? String(matchedTb).replace(/\\/g, "/") : "";
  }

  const hardFail = !report.manifest.valid || !report.resolved.ok || report.resolved.srcCount === 0;
  report.ok = !hardFail;
  report.warnings = buildDoctorWarnings(report);
  report.status = hardFail ? "failed" : (report.warnings.length > 0 ? "warning" : "ok");

  const summary = createDoctorSummary({
    projectRoot: root,
    manifestJsonPath: manifestJsonPath || "",
    status: report.status,
    ok: report.ok,
    warnings: report.warnings,
    checks: {
      manifest: report.manifest,
      tools: report.tools,
      resolved: report.resolved,
      optionalSections: report.optionalSections,
      vitis: report.vitis,
      tbNaming: report.tbNaming,
      paths: report.paths,
    },
    details: {
      outputDirs: report.outputDirs,
    },
  });

  return {
    ...summary,
    manifest: report.manifest,
    tools: report.tools,
    resolved: report.resolved,
    outputDirs: report.outputDirs,
    optionalSections: report.optionalSections,
    vitis: report.vitis,
    tbNaming: report.tbNaming,
    paths: report.paths,
  };
}

function writeDoctorArtifacts(projectRoot, manifestJsonPath = "", report, writePath = "") {
  const root = path.resolve(projectRoot || process.cwd());
  const summaryPath = path.join(root, "output", "doctor_summary.json");
  const summary = report && typeof report === "object" ? report : runDoctor(root, manifestJsonPath);
  const writtenSummaryPath = writeJsonFile(summaryPath, summary);
  const outputs = [
    createArtifactRecord({
      kind: "doctor_summary_json",
      path: writtenSummaryPath,
      label: "doctor_summary.json",
      status: "generated",
    }),
  ];

  let extraWritePath = "";
  if (writePath) {
    extraWritePath = writeJsonFile(writePath, summary);
    outputs.push(createArtifactRecord({
      kind: "doctor_report_json",
      path: extraWritePath,
      label: path.basename(extraWritePath),
      status: "generated",
    }));
  }

  appendRunEntry(root, {
    tool: "toolkit_doctor",
    projectRoot: root,
    manifestJsonPath,
    status: summary.status,
    outputs,
    summaryPath: writtenSummaryPath,
    metadata: {
      ok: summary.ok,
      topModule: summary.resolved && summary.resolved.top ? summary.resolved.top : "",
      srcCount: summary.resolved && summary.resolved.srcCount ? summary.resolved.srcCount : 0,
      tbCount: summary.resolved && summary.resolved.tbCount ? summary.resolved.tbCount : 0,
    },
  });

  return {
    summary,
    summaryPath: writtenSummaryPath,
    extraWritePath,
  };
}

module.exports = {
  runDoctor,
  writeDoctorArtifacts,
};
