const assert = require("assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const {
  checkTools,
  findVivadoInstall,
  runDoctor,
  writeDoctorArtifacts,
} = require("./toolkit_doctor_service");

function writeFile(targetPath, contents) {
  fs.mkdirSync(path.dirname(targetPath), { recursive: true });
  fs.writeFileSync(targetPath, contents, "utf8");
}

function withTempDir(prefix, fn) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  try {
    return fn(tempDir);
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
}

function runDoctorSelftest() {
  const checks = [];

  withTempDir("fpga-doctor-", (projectRoot) => {
    writeFile(
      path.join(projectRoot, "fpga_auto.yml"),
      [
        'version: "0"',
        "project:",
        "  name: doctor_smoke",
        "hdl:",
        "  top: TOP",
        "  src_globs:",
        "    - src/**/*.v",
        "  tb_globs:",
        "    - tb/**/*.v",
        "  inc_globs: []",
        "  xdc_globs: []",
        "  exclude_globs: []",
        "",
      ].join("\n")
    );
    writeFile(path.join(projectRoot, "src", "TOP.v"), "module TOP; endmodule\n");
    writeFile(path.join(projectRoot, "tb", "tb_TOP.v"), "module tb_TOP; TOP dut(); endmodule\n");

    const report = runDoctor(projectRoot);
    assert.equal(report.manifest.exists, true);
    assert.equal(report.manifest.valid, true);
    assert.equal(report.resolved.ok, true);
    assert.equal(report.resolved.srcCount, 1);
    assert.equal(report.resolved.tbCount, 1);
    assert.equal(report.ok, true);
    assert.equal(report.status, "warning");
    assert.ok(Array.isArray(report.warnings));
    assert.ok(report.warnings.includes("optional_section_missing:sim"));
    const written = writeDoctorArtifacts(projectRoot, "", report);
    assert.ok(fs.existsSync(written.summaryPath));
    assert.ok(fs.existsSync(path.join(projectRoot, "output", "run_index.json")));
    checks.push("valid_manifest_project");
  });

  withTempDir("fpga-doctor-", (projectRoot) => {
    const report = runDoctor(projectRoot);
    assert.equal(report.manifest.exists, false);
    assert.equal(report.manifest.valid, false);
    assert.equal(report.resolved.ok, false);
    assert.equal(report.ok, false);
    assert.equal(report.status, "failed");
    checks.push("missing_manifest_project");
  });

  withTempDir("fpga-doctor-", (tempRoot) => {
    const amdRoot = path.join(tempRoot, "AMDDesignTools");
    const vivadoBin = path.join(amdRoot, "2025.2", "Vivado", "bin");
    writeFile(path.join(vivadoBin, "vivado.bat"), "@echo off\n");

    const resolved = findVivadoInstall({
      platform: "win32",
      env: {},
      scanRoots: [amdRoot],
    });
    assert.equal(resolved, vivadoBin);

    const tools = checkTools({
      platform: "win32",
      env: {},
      scanRoots: [amdRoot],
      execFileSync() {
        throw new Error("not-on-path");
      },
    });
    assert.equal(tools.vivado.ok, true);
    assert.equal(tools.vivado.resolved, vivadoBin);
    assert.equal(tools.vivado.source, "fallback");
    checks.push("vivado_amd_tool_root");
  });

  return {
    ok: true,
    checks,
  };
}

module.exports = {
  runDoctorSelftest,
};
