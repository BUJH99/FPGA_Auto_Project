const assert = require("assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { writeBuildSummary } = require("./build_summary_service");
const { prepareVivadoBuild } = require("./vivado_build_plan_service");

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

function runBuildSummarySelftest() {
  return withTempDir("fpga-vivado-summary-", (projectRoot) => {
    writeFile(
      path.join(projectRoot, "fpga_auto.yml"),
      [
        'version: "1"',
        "project:",
        "  name: build_summary_smoke",
        "hdl:",
        "  top: TOP",
        "  src_globs:",
        "    - src/**/*.sv",
        "  tb_globs:",
        "    - tb/**/*.sv",
        "  inc_globs: []",
        "  xdc_globs: []",
        "  exclude_globs: []",
        "vivado:",
        "  part: xc7a35tcpg236-1",
        "  strategy: PerformanceOptimized",
        "  power_limit_w: 2.5",
        "",
      ].join("\n")
    );
    writeFile(path.join(projectRoot, "src", "TOP.sv"), "module TOP; endmodule\n");
    writeFile(path.join(projectRoot, "tb", "tb_TOP.sv"), "module tb_TOP; TOP dut(); endmodule\n");
    writeFile(
      path.join(projectRoot, "output", "manifest", "manifest_resolved.json"),
      JSON.stringify({
        schemaVersion: 1,
        config: {
          version: "1",
          project: { name: "build_summary_smoke" },
          hdl: {
            top: "TOP",
            src_globs: ["src/**/*.sv"],
            tb_globs: ["tb/**/*.sv"],
            inc_globs: [],
            xdc_globs: [],
            exclude_globs: [],
          },
          vivado: {
            part: "xc7a35tcpg236-1",
            strategy: "PerformanceOptimized",
            power_limit_w: 2.5,
          },
        },
        resolved: {
          src_files: ["src/TOP.sv"],
          tb_files: ["tb/tb_TOP.sv"],
          inc_dirs: [],
          xdc_files: [],
        },
        errors: [],
      }, null, 2)
    );
    writeFile(path.join(projectRoot, "output", "manifest", "manifest_src_files.lst"), "src/TOP.sv\n");
    writeFile(path.join(projectRoot, "output", "manifest", "manifest_xdc_files.lst"), "");
    writeFile(path.join(projectRoot, "output", "manifest", "manifest_inc_dirs.lst"), "");
    writeFile(path.join(projectRoot, "output", "TOP.bit"), "bit\n");
    writeFile(path.join(projectRoot, "output", "reports", "timing_summary.rpt"), "timing\n");
    const buildLogPath = path.join(projectRoot, "log", "vivado_full_build.log");
    writeFile(
      buildLogPath,
      [
        "    |-> CHECK: Total Power = 1.25 W ... [PASS]",
        "    |-> CHECK: WNS (Worst Negative Slack) = 0.12 ns ... [PASS]",
        "    |-> CHECK: CDC Violations = 0 paths ... [PASS]",
        "",
      ].join("\n")
    );

    const prepared = prepareVivadoBuild({
      projectRoot,
      manifestJsonPath: path.join(projectRoot, "output", "manifest", "manifest_resolved.json"),
      srcListPath: path.join(projectRoot, "output", "manifest", "manifest_src_files.lst"),
      xdcListPath: path.join(projectRoot, "output", "manifest", "manifest_xdc_files.lst"),
      incListPath: path.join(projectRoot, "output", "manifest", "manifest_inc_dirs.lst"),
      autoProgram: true,
    });
    const result = writeBuildSummary({
      projectRoot,
      manifestJsonPath: path.join(projectRoot, "output", "manifest", "manifest_resolved.json"),
      buildLogPath,
      buildPlanPath: prepared.planPath,
      programStatus: "SUCCESS",
      buildRc: 0,
      rtlRc: 0,
      reportRc: 0,
    });

    assert.equal(result.summary.status, "ok");
    assert.equal(result.summary.qualityGate.power.status, "ok");
    assert.equal(result.summary.qualityGate.timing.status, "ok");
    assert.equal(result.summary.qualityGate.bitstream.status, "ok");
    assert.equal(result.summary.details.partNumber, "xc7a35tcpg236-1");
    assert.equal(result.summary.details.strategy, "PerformanceOptimized");
    assert.equal(result.summary.details.programStatus, "SUCCESS");
    assert.ok(Array.isArray(result.summary.details.stepResults));
    assert.equal(result.summary.details.stepResults[0].name, "build");
    assert.ok(fs.existsSync(result.summaryPath));
    assert.ok(fs.existsSync(result.resultPath));
    assert.ok(fs.existsSync(path.join(projectRoot, "output", "run_index.json")));

    return {
      ok: true,
      summaryPath: result.summaryPath,
    };
  });
}

module.exports = {
  runBuildSummarySelftest,
};
