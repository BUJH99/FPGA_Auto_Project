const assert = require("assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const {
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

  withTempDir("fpga-doctor-vivado-", (vivadoBin) => {
    writeFile(path.join(vivadoBin, "vivado.bat"), "@echo off\r\necho Vivado stub\r\n");
    const previousVivadoBin = process.env.VIVADO_BIN;
    process.env.VIVADO_BIN = vivadoBin;
    try {
      withTempDir("fpga-doctor-", (projectRoot) => {
        writeFile(
          path.join(projectRoot, "fpga_auto.yml"),
          [
            'version: "0"',
            "project:",
            "  name: doctor_vivado_override",
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
        assert.equal(report.tools.vivado.ok, true);
        assert.ok(String(report.tools.vivado.resolved || "").toLowerCase().endsWith("vivado.bat"));
      });
    } finally {
      if (typeof previousVivadoBin === "string") {
        process.env.VIVADO_BIN = previousVivadoBin;
      } else {
        delete process.env.VIVADO_BIN;
      }
    }
    checks.push("vivado_env_override");
  });

  return {
    ok: true,
    checks,
  };
}

module.exports = {
  runDoctorSelftest,
};
