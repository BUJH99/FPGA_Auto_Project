const fs = require("fs");
const path = require("path");
const YAML = require("yaml");
const { writeJsonFile } = require("../../../shared/application/json_file_service");
const { appendRunEntry } = require("../../../shared/application/run_registry_service");
const { loadManifestResult } = require("../../../shared/application/manifest_contract_loader");
const {
  createArtifactRecord,
  createMigrationSummary,
} = require("../../../shared/domain/run_contracts");
const {
  DEFAULT_SKIP_DIRS,
  createLegacyProjectCandidate,
  normalizeSlashes,
} = require("../domain/legacy_project_candidate");
const {
  createLegacyProjectMigrationRequest,
  createLegacyProjectDiscoveryResult,
  createLegacyProjectMigrationResult,
} = require("../domain/legacy_project_migration_contracts");
const {
  inferManifestConfig,
} = require("../domain/manifest_inference_policy");

function ensureDir(dirPath) {
  if (!fs.existsSync(dirPath)) {
    fs.mkdirSync(dirPath, { recursive: true });
  }
}

function walkFiles(rootDir) {
  const out = [];
  if (!fs.existsSync(rootDir)) return out;

  const stack = [rootDir];
  while (stack.length > 0) {
    const cur = stack.pop();
    const entries = fs.readdirSync(cur, { withFileTypes: true });
    entries.sort((a, b) => a.name.localeCompare(b.name));
    for (const entry of entries) {
      const abs = path.join(cur, entry.name);
      if (entry.isDirectory()) {
        stack.push(abs);
        continue;
      }
      if (!entry.isFile()) continue;
      out.push(normalizeSlashes(path.relative(rootDir, abs)));
    }
  }

  return out.sort((a, b) => a.localeCompare(b));
}

function discoverLegacyProjects(requestInput, skipDirs = DEFAULT_SKIP_DIRS) {
  const request = requestInput && typeof requestInput === "object" && Object.prototype.hasOwnProperty.call(requestInput, "repoRoot")
    ? createLegacyProjectMigrationRequest(requestInput)
    : createLegacyProjectMigrationRequest({ repoRoot: requestInput, skipDirs });
  const skip = new Set(request.skipDirs.length > 0 ? request.skipDirs : DEFAULT_SKIP_DIRS);
  const dirs = fs
    .readdirSync(request.repoRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort((a, b) => a.localeCompare(b));

  const candidates = dirs
    .filter((name) => !skip.has(name))
    .map((name) => ({
      name,
      abs: path.join(request.repoRoot, name),
    }))
    .filter((project) => fs.existsSync(path.join(project.abs, "src")))
    .map((project) => createLegacyProjectCandidate(project.name, project.abs));

  return createLegacyProjectDiscoveryResult({
    repoRoot: request.repoRoot,
    skipDirs: Array.from(skip),
    candidates,
    scanned: candidates.length,
  });
}

function writeManifestFromTemplate(targetProject, projectName, repoRoot, opts = {}) {
  const manifestPath = path.join(targetProject, "fpga_auto.yml");
  if (opts.inferGlobs) {
    const manifest = inferManifestConfig(projectName, walkFiles(targetProject));
    fs.writeFileSync(manifestPath, YAML.stringify(manifest), "utf8");
    return "manifest_created_inferred";
  }

  const tplPath = path.join(repoRoot, "templates", "manifest", "fpga_auto.template.yml");
  if (!fs.existsSync(tplPath)) {
    throw new Error(`Manifest template missing: ${tplPath}`);
  }
  const tpl = fs.readFileSync(tplPath, "utf8");
  fs.writeFileSync(manifestPath, tpl.replace(/__PROJECT_NAME__/g, projectName), "utf8");
  return "manifest_created_from_template";
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

function analyzeMigrationCandidate(request, project) {
  const sourceAbs = project.absPath.replace(/\//g, path.sep);
  const target = path.join(request.projectRoot.replace(/\//g, path.sep), project.name);
  const row = {
    name: project.name,
    source: normalizeSlashes(sourceAbs),
    target: normalizeSlashes(target),
    status: "pending",
    notes: [],
  };

  if (fs.existsSync(target)) {
    row.status = "failed";
    row.notes.push("target_already_exists");
    return row;
  }

  const sourceManifestPath = path.join(sourceAbs, "fpga_auto.yml");
  if (fs.existsSync(sourceManifestPath)) {
    row.notes.push("source_manifest_exists");
  } else if (request.inferGlobs) {
    row.notes.push("manifest_plan:infer_globs");
  } else {
    row.notes.push("manifest_plan:template");
  }

  return row;
}

function executeLegacyProjectMigration(requestInput) {
  const request = createLegacyProjectMigrationRequest(requestInput);
  const discovery = discoverLegacyProjects(request);
  const results = [];
  const warnings = [];

  for (const project of discovery.candidates) {
    const row = analyzeMigrationCandidate(request, project);
    const sourceAbs = row.source.replace(/\//g, path.sep);
    const target = row.target.replace(/\//g, path.sep);

    try {
      if (row.status === "failed") {
        results.push(row);
        continue;
      }

      if (!request.dryRun) {
        fs.cpSync(sourceAbs, target, { recursive: true, errorOnExist: true, force: false });
        if (!fs.existsSync(path.join(target, "fpga_auto.yml"))) {
          row.notes.push(writeManifestFromTemplate(target, project.name, request.repoRoot, request));
        }

        const resolved = loadManifestResult(target);
        if (Array.isArray(resolved.errors) && resolved.errors.length > 0) {
          row.status = "failed";
          row.notes.push(`manifest_validation_failed:${(resolved.errors || []).map((entry) => entry.code).join(",")}`);
        } else {
          row.status = "migrated";
          row.notes.push("copied_and_validated");
        }
      } else {
        row.status = "dry_run";
        row.notes.push("copy_skipped");
        row.notes.push("validation_plan:post_copy_manifest_resolve");
      }
    } catch (err) {
      row.status = "failed";
      row.notes.push(err.message);
    }

    results.push(row);
  }

  if (request.dryRun) {
    warnings.push("dry_run:no_files_copied");
  }

  return createLegacyProjectMigrationResult({
    policy: "copy_and_verify",
    repoRoot: request.repoRoot,
    projectRoot: request.projectRoot,
    dryRun: request.dryRun,
    inferGlobs: request.inferGlobs,
    scanned: discovery.scanned,
    migrated: results.filter((row) => row.status === "migrated").length,
    failed: results.filter((row) => row.status === "failed").length,
    discoveredProjects: discovery.candidates,
    results,
    warnings,
    reportFileName: `migration_report_${tsNow()}.json`,
  });
}

function writeMigrationReport(report, repoRoot) {
  const reportDir = path.join(repoRoot, "output", "migration");
  const fileName = report.reportFileName || report.report_file_name || `migration_report_${tsNow()}.json`;
  return writeJsonFile(path.join(reportDir, fileName), report);
}

function writeMigrationArtifacts(resultInput, repoRootInput = "") {
  const result = resultInput && typeof resultInput === "object" && Object.prototype.hasOwnProperty.call(resultInput, "repoRoot")
    ? resultInput
    : createLegacyProjectMigrationResult(resultInput);
  const repoRoot = path.resolve(repoRootInput || result.repoRoot || process.cwd());
  const reportPath = writeMigrationReport(result, repoRoot);
  const summaryPath = path.join(repoRoot, "output", "migration", "migration_summary.json");
  const artifacts = [
    createArtifactRecord({
      kind: "migration_summary_json",
      path: summaryPath,
      label: "migration_summary.json",
    }),
    createArtifactRecord({
      kind: "migration_report_json",
      path: reportPath,
      label: path.basename(reportPath),
    }),
  ];
  const summary = createMigrationSummary({
    repoRoot,
    projectRoot: result.projectRoot,
    status: result.failed > 0 ? "failed" : (result.dryRun ? "warning" : "ok"),
    warnings: result.warnings,
    artifacts,
    request: {
      repoRoot: result.repoRoot,
      projectRoot: result.projectRoot,
      dryRun: result.dryRun,
      inferGlobs: result.inferGlobs,
    },
    discovery: {
      scanned: result.scanned,
      candidateCount: Array.isArray(result.discoveredProjects) ? result.discoveredProjects.length : 0,
      candidateNames: Array.isArray(result.discoveredProjects)
        ? result.discoveredProjects.map((row) => row.name).sort((a, b) => a.localeCompare(b))
        : [],
    },
    details: {
      migrated: result.migrated,
      failed: result.failed,
      results: result.results,
      reportPath: normalizeSlashes(path.relative(repoRoot, reportPath)),
    },
  });
  const writtenSummaryPath = writeJsonFile(summaryPath, summary);
  appendRunEntry(repoRoot, {
    tool: "project_bootstrap_migration",
    projectRoot: repoRoot,
    status: summary.status,
    outputs: artifacts,
    summaryPath: writtenSummaryPath,
    metadata: {
      projectRoot: result.projectRoot,
      scanned: result.scanned,
      migrated: result.migrated,
      failed: result.failed,
    },
  });

  return {
    summary,
    summaryPath: writtenSummaryPath,
    reportPath,
  };
}

module.exports = {
  ensureDir,
  discoverLegacyProjects,
  executeLegacyProjectMigration,
  runLegacyProjectMigration: executeLegacyProjectMigration,
  writeMigrationReport,
  writeMigrationArtifacts,
};
