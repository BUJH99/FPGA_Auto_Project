const assert = require("assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const YAML = require("yaml");
const {
  executeLegacyProjectMigration,
  writeMigrationArtifacts,
} = require("./legacy_project_migration_service");

function writeFile(targetPath, contents) {
  fs.mkdirSync(path.dirname(targetPath), { recursive: true });
  fs.writeFileSync(targetPath, contents, "utf8");
}

function withTempDir(prefix, fn) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  const repoRoot = path.join(tempDir, "FPGA_Auto_Project");
  fs.mkdirSync(repoRoot, { recursive: true });
  try {
    return fn(repoRoot, tempDir);
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
}

function runLegacyProjectMigrationSelftest() {
  return withTempDir("fpga-migrate-", (repoRoot, workspaceRoot) => {
    writeFile(path.join(repoRoot, "alpha", "src", "TOP.v"), "module TOP; endmodule\n");
    writeFile(path.join(repoRoot, "alpha", "tb", "tb_TOP.v"), "module tb_TOP; TOP dut(); endmodule\n");

    const projectRoot = path.join(workspaceRoot, "Project");
    const report = executeLegacyProjectMigration({
      repoRoot,
      projectRoot,
      dryRun: false,
      inferGlobs: true,
    });

    assert.equal(report.scanned, 1);
    assert.equal(report.migrated, 1);
    assert.equal(report.failed, 0);

    const migratedRoot = path.join(projectRoot, "alpha");
    const manifestPath = path.join(migratedRoot, "fpga_auto.yml");
    assert.equal(fs.existsSync(manifestPath), true);

    const manifest = YAML.parse(fs.readFileSync(manifestPath, "utf8"));
    assert.equal(manifest.project.name, "alpha");
    assert.equal(manifest.hdl.top, "TOP");
    assert.ok(Array.isArray(manifest.hdl.src_globs));
    assert.ok(Array.isArray(manifest.hdl.tb_globs));

    const artifacts = writeMigrationArtifacts(report, repoRoot);
    assert.equal(fs.existsSync(artifacts.reportPath), true);
    assert.equal(fs.existsSync(artifacts.summaryPath), true);
    assert.equal(fs.existsSync(path.join(repoRoot, "output", "run_index.json")), true);

    return {
      ok: true,
      checks: ["migrate_infer_globs", "migration_summary_written"],
    };
  });
}

module.exports = {
  runLegacyProjectMigrationSelftest,
};
