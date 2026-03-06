const fs = require("fs");
const path = require("path");
const cp = require("child_process");
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

function checkTools() {
  return {
    node: findExecutable(["node", "node.exe"]),
    python: findExecutable(["python", "python3", "python.exe"]),
    vivado: findExecutable(["vivado", "vivado.bat"]),
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
    },
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
