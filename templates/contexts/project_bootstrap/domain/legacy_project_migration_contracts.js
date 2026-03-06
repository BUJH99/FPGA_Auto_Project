const path = require("path");
const { normalizeSlashes } = require("./legacy_project_candidate");

function createLegacyProjectMigrationRequest(payload = {}) {
  const repoRoot = path.resolve(payload.repoRoot || process.cwd());
  const projectRoot = path.resolve(payload.projectRoot || path.join(repoRoot, "Project"));
  return {
    repoRoot: normalizeSlashes(repoRoot),
    projectRoot: normalizeSlashes(projectRoot),
    dryRun: Boolean(payload.dryRun),
    inferGlobs: Boolean(payload.inferGlobs),
    skipDirs: Array.isArray(payload.skipDirs) ? payload.skipDirs.map((row) => String(row || "").trim()).filter(Boolean) : [],
  };
}

function createLegacyProjectDiscoveryResult(payload = {}) {
  return {
    repoRoot: normalizeSlashes(payload.repoRoot || ""),
    skipDirs: Array.isArray(payload.skipDirs) ? payload.skipDirs.map((row) => String(row || "").trim()).filter(Boolean) : [],
    candidates: Array.isArray(payload.candidates) ? payload.candidates : [],
    scanned: Number(payload.scanned || 0),
  };
}

function createLegacyProjectMigrationResult(payload = {}) {
  return {
    policy: String(payload.policy || "copy_and_verify"),
    repoRoot: normalizeSlashes(payload.repoRoot || ""),
    projectRoot: normalizeSlashes(payload.projectRoot || ""),
    dryRun: Boolean(payload.dryRun),
    inferGlobs: Boolean(payload.inferGlobs),
    scanned: Number(payload.scanned || 0),
    migrated: Number(payload.migrated || 0),
    failed: Number(payload.failed || 0),
    discoveredProjects: Array.isArray(payload.discoveredProjects) ? payload.discoveredProjects : [],
    results: Array.isArray(payload.results) ? payload.results : [],
    warnings: Array.isArray(payload.warnings) ? payload.warnings.map((row) => String(row || "").trim()).filter(Boolean) : [],
    reportFileName: String(payload.reportFileName || ""),
  };
}

module.exports = {
  createLegacyProjectMigrationRequest,
  createLegacyProjectDiscoveryResult,
  createLegacyProjectMigrationResult,
};
