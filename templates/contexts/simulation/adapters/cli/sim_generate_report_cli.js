const fs = require('fs');
const { execSync } = require('child_process');
const path = require('path');
const { loadStrictManifestContext } = require('../../../manifest/application/strict_manifest_loader');

function usageAndExit() {
    console.error("Usage: node generate_report.js <path_to_config.json> --manifest-json <path>");
    process.exit(1);
}

function parseArgs(argv) {
    let configArg = '';
    let manifestJsonArg = '';

    for (let i = 0; i < argv.length; i++) {
        const arg = String(argv[i] || '');
        if (arg === '--manifest-json') {
            i += 1;
            if (i >= argv.length) usageAndExit();
            manifestJsonArg = argv[i];
            continue;
        }
        if (arg.startsWith('--manifest-json=')) {
            manifestJsonArg = arg.slice('--manifest-json='.length);
            continue;
        }
        if (arg.startsWith('--')) {
            usageAndExit();
        }
        if (!configArg) {
            configArg = arg;
            continue;
        }
        usageAndExit();
    }

    if (!configArg || !manifestJsonArg) usageAndExit();
    return {
        configPath: path.resolve(configArg),
        manifestJsonPath: path.resolve(manifestJsonArg),
    };
}

function uniqueStrings(rows) {
    const seen = new Set();
    const out = [];
    for (const row of rows || []) {
        const v = String(row || '').trim();
        if (!v || seen.has(v)) continue;
        seen.add(v);
        out.push(v);
    }
    return out;
}

function slugify(text) {
    return String(text || '')
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, '_')
        .replace(/^_+|_+$/g, '')
        .slice(0, 64) || 'run';
}

function uniqueSortedPaths(rows) {
    return Array.from(new Set((rows || []).map((p) => path.resolve(p))))
        .sort((a, b) => a.localeCompare(b));
}

function isPathWithin(parentAbs, targetAbs) {
    const parent = path.resolve(parentAbs);
    const target = path.resolve(targetAbs);
    const rel = path.relative(parent, target);
    return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}

// 1. Get arguments
const args = parseArgs(process.argv.slice(2));
const configPath = args.configPath;
if (!fs.existsSync(configPath)) {
    console.error(`Error: Config file not found at ${configPath}`);
    process.exit(1);
}

// 2. Load Configuration
console.log(`Loading configuration from: ${configPath}`);
const config = JSON.parse(fs.readFileSync(configPath, 'utf-8'));
const projectRoot = path.dirname(configPath); // Config file location is the project root anchor
let manifestContext = null;
try {
    manifestContext = loadStrictManifestContext(projectRoot, args.manifestJsonPath);
} catch (err) {
    console.error(`Error: ${err.message}`);
    process.exit(1);
}

const cfg = config.config || {};
const rawScenarios = Array.isArray(config.scenarios) ? config.scenarios : [];

const normalizeNumber = (value, fallback) => {
    const n = Number(value);
    return Number.isFinite(n) ? n : fallback;
};

const normalizedScenarios = rawScenarios.map((scenario, index) => {
    const startNs = Math.max(0, Math.round(normalizeNumber(scenario.start_ns, 0)));
    const durationNs = Math.max(1, Math.round(normalizeNumber(scenario.duration_ns, 100000)));
    const stepNs = Math.max(1, Math.round(normalizeNumber(scenario.sample_step_ns, 100)));
    const title = scenario.title || `CASE ${index + 1}`;
    const id = scenario.id || `case_${index + 1}`;
    const signals = Array.from(new Set(Array.isArray(scenario.signals) ? scenario.signals.filter(Boolean) : []));

    return {
        ...scenario,
        id,
        title,
        start_ns: startNs,
        duration_ns: durationNs,
        sample_step_ns: stepNs,
        signals
    };
});

const maxScenarioEndNs = normalizedScenarios.reduce((maxEnd, scenario) => {
    return Math.max(maxEnd, scenario.start_ns + scenario.duration_ns);
}, 0);

const requestedTestNames = uniqueStrings(Array.isArray(cfg.test_names) ? cfg.test_names : []);

const simDurationNs = Math.max(
    normalizeNumber(cfg.sim_duration_ns, 0),
    maxScenarioEndNs + 10000
);
const simTime = simDurationNs > 0 ? `${simDurationNs / 1000000} ms` : '5 ms';
const topModule = cfg.top_module || manifestContext.snapshot.top || 'tb_Top';
const projectName = cfg.project_name || manifestContext.snapshot.projectName || path.basename(projectRoot);
const tbRelPath = cfg.tb_file || (manifestContext.result.resolved.tb_files && manifestContext.result.resolved.tb_files[0]) || '';
const vcdRelPath = cfg.vcd_file || 'output/mcp_sim_wave.vcd';
const htmlRelPath = cfg.html_file || `output/view_wave_${topModule}.html`;

// 2.1 Generate TCL Script
console.log("Generating Vivado TCL script...");
const tclPath = path.join(projectRoot, 'tcl', 'run_sim_autogen.tcl');

function toTclPath(p) {
    return String(p).replace(/\\/g, '/');
}

function toTclList(paths) {
    return paths.map((p) => `{${toTclPath(p)}}`).join(' ');
}

function findLatestFileRecursive(rootDir, ext) {
    if (!fs.existsSync(rootDir)) return null;
    let latest = null;
    const stack = [rootDir];
    while (stack.length > 0) {
        const cur = stack.pop();
        const entries = fs.readdirSync(cur, { withFileTypes: true });
        for (const entry of entries) {
            const abs = path.join(cur, entry.name);
            if (entry.isDirectory()) {
                stack.push(abs);
                continue;
            }
            if (!entry.isFile()) continue;
            if (path.extname(entry.name).toLowerCase() !== ext) continue;
            const mtimeMs = fs.statSync(abs).mtimeMs;
            if (!latest || mtimeMs > latest.mtimeMs) {
                latest = { path: abs, mtimeMs };
            }
        }
    }
    return latest ? latest.path : null;
}

function findFallbackVcd(projectRootDir) {
    const roots = [
        path.join(projectRootDir, 'output'),
        path.join(projectRootDir, 'work'),
        path.join(projectRootDir, 'vivado_project'),
        projectRootDir
    ];
    for (const root of roots) {
        const hit = findLatestFileRecursive(root, '.vcd');
        if (hit) return hit;
    }
    return null;
}

// Use forward slashes for TCL compatibility
const outDirFs = path.join(projectRoot, 'output');
const outDir = toTclPath(outDirFs);
const tbFileAbs = path.resolve(projectRoot, tbRelPath);
const tbDirAbs = path.dirname(tbFileAbs);
const srcFileList = uniqueSortedPaths((manifestContext.srcFiles || [])
    .filter((p) => /\.(v|sv)$/i.test(p))
    .map((p) => path.resolve(p)));
let tbFileList = uniqueSortedPaths((manifestContext.tbFiles || [])
    .filter((p) => /\.(v|sv)$/i.test(p))
    .map((p) => path.resolve(p)));
if (tbFileList.length === 0 && fs.existsSync(tbFileAbs)) {
    tbFileList.push(tbFileAbs);
}
if (srcFileList.length === 0) {
    console.error('Error: manifest resolved src_files is empty.');
    process.exit(1);
}
if (fs.existsSync(tbFileAbs) && !tbFileList.find((p) => path.resolve(p) === path.resolve(tbFileAbs))) {
    tbFileList.push(tbFileAbs);
}
if (tbFileList.length === 0) {
    console.error('Error: manifest resolved tb_files is empty.');
    process.exit(1);
}

// Restrict TB compile scope to the selected testbench folder.
const tbFileListBeforeFilter = tbFileList.length;
if (fs.existsSync(tbDirAbs)) {
    const scopedTbFiles = tbFileList.filter((p) => isPathWithin(tbDirAbs, p));
    if (scopedTbFiles.length > 0) {
        tbFileList = uniqueSortedPaths(scopedTbFiles);
    }
}
if (fs.existsSync(tbFileAbs) && !tbFileList.find((p) => path.resolve(p) === path.resolve(tbFileAbs))) {
    tbFileList.push(path.resolve(tbFileAbs));
}
tbFileList = uniqueSortedPaths(tbFileList);
console.log(`[Info] TB scope filter: ${tbFileListBeforeFilter} -> ${tbFileList.length} files (folder: ${tbDirAbs})`);

const tbRootAbs = path.join(projectRoot, 'tb');
const manifestIncDirs = uniqueSortedPaths((manifestContext.incDirs || []).map((p) => path.resolve(p)));
const includeDirs = uniqueSortedPaths([
    ...manifestIncDirs.filter((dir) => {
        // Keep non-tb include dirs and selected tb subtree only.
        return !isPathWithin(tbRootAbs, dir) || isPathWithin(tbDirAbs, dir);
    }),
    ...srcFileList.map((p) => path.dirname(p)),
    ...tbFileList.map((p) => path.dirname(p))
]);

const tbFileListTcl = toTclList(tbFileList);
const srcFileListTcl = toTclList(srcFileList);
const incDirListTcl = toTclList(includeDirs);

function buildVivadoTclContent(params) {
    const safeTestName = params.testName
        ? String(params.testName).replace(/[^A-Za-z0-9_.-]/g, '_')
        : '';
    const plusArgLine = safeTestName
        ? `set_property -name XSIM.SIMULATE.XSIM.MORE_OPTIONS -value "-testplusarg TESTNAME=${safeTestName}" -objects $fs`
        : '';

    return `# Auto-generated by sim_generate_report_cli.js
set project_name "${params.projectName}"
set project_dir "${toTclPath(params.projectDir)}"
set src_files [list ${toTclList(params.srcFiles)}]
set tb_files [list ${toTclList(params.tbFiles)}]
set include_dirs [list ${toTclList(params.includeDirs)}]

# Create/Reset Project
create_project -force $project_name $project_dir -part xc7a35tcpg236-1

# Add Sources
if {[llength $src_files] > 0} { add_files -norecurse $src_files }
if {[llength $tb_files] > 0} { add_files -fileset sim_1 -norecurse $tb_files }
if {[llength $include_dirs] > 0} {
    catch { set_property include_dirs $include_dirs [get_filesets sources_1] }
    catch { set_property include_dirs $include_dirs [get_filesets sim_1] }
}

# Set Top / Sim options
set fs [get_filesets sim_1]
set_property top ${params.topModule} $fs
set_property XSIM.SIMULATE.RUNTIME {${params.simTime}} $fs
${plusArgLine}
update_compile_order -fileset sim_1

# Run Simulation
launch_simulation
if {[catch {run ${params.simTime}} run_err]} {
    puts "Error during simulation run: $run_err"
}
catch {close_sim}
close_project
exit
`;
}

function runVivadoBatch(tclFilePath, logFilePath, journalFilePath, workDir) {
    try {
        const vivadoCmd = `vivado -mode batch -source "${tclFilePath}" -log "${logFilePath}" -journal "${journalFilePath}" -notrace`;
        execSync(vivadoCmd, { stdio: 'inherit', cwd: workDir, maxBuffer: 1024 * 1024 * 10 });
        return { ok: true };
    } catch (err) {
        return { ok: false, error: err };
    }
}

function parseRunLog(logFilePath) {
    const summary = {
        hasEnvReport: false,
        checkedCount: 0,
        errorCount: NaN,
        hasFatal: false,
    };
    if (!fs.existsSync(logFilePath)) return summary;

    const raw = fs.readFileSync(logFilePath, 'utf-8');
    const matches = [...raw.matchAll(/ENV report:\s*checked=(\d+)\s+errors=(\d+)/g)];
    if (matches.length > 0) {
        const last = matches[matches.length - 1];
        summary.hasEnvReport = true;
        summary.checkedCount = Number(last[1]);
        summary.errorCount = Number(last[2]);
    }
    summary.hasFatal = /\$fatal|\[ASSERT\]|Scoreboard mismatches found|Coverage closure failed/i.test(raw);
    return summary;
}

function writeRegressionSummary(summaryPath, rows) {
    const lines = [];
    lines.push('# Vivado Regression Summary');
    lines.push('');
    lines.push('| TESTNAME | Result | Checked | Errors | Reason |');
    lines.push('|---|---:|---:|---:|---|');
    for (const row of rows) {
        lines.push(`| ${row.testName} | ${row.pass ? 'PASS' : 'FAIL'} | ${row.checkedCount} | ${Number.isFinite(row.errorCount) ? row.errorCount : '-'} | ${row.reason} |`);
    }
    lines.push('');
    const passCount = rows.filter((r) => r.pass).length;
    lines.push(`- Total: ${rows.length}`);
    lines.push(`- Pass: ${passCount}`);
    lines.push(`- Fail: ${rows.length - passCount}`);
    lines.push('');
    fs.writeFileSync(summaryPath, lines.join('\n'), 'utf-8');
}

const tclDir = path.dirname(tclPath);
const workDir = path.join(projectRoot, 'work');
const simLogDir = path.join(projectRoot, 'log', 'vivado_sim');
if (!fs.existsSync(tclDir)) fs.mkdirSync(tclDir, { recursive: true });
if (!fs.existsSync(workDir)) fs.mkdirSync(workDir, { recursive: true });
if (!fs.existsSync(outDirFs)) fs.mkdirSync(outDirFs, { recursive: true });
if (!fs.existsSync(simLogDir)) fs.mkdirSync(simLogDir, { recursive: true });

console.log(`HDL lang: ${cfg.hdl_lang || "unknown"}, TB file: ${tbRelPath}`);

if (requestedTestNames.length > 0) {
    console.log(`[Info] TESTNAME regression mode enabled: ${requestedTestNames.join(', ')}`);
    const regressionRows = [];

    for (let i = 0; i < requestedTestNames.length; i += 1) {
        const testName = requestedTestNames[i];
        const runSlug = `${String(i + 1).padStart(2, '0')}_${slugify(testName)}`;
        const runTclPath = path.join(tclDir, `run_sim_${runSlug}.tcl`);
        const runProjectDir = path.join(projectRoot, 'work', 'regression', runSlug);
        const runLogPath = path.join(simLogDir, `vivado_regression_${runSlug}.log`);
        const runJouPath = path.join(simLogDir, `vivado_regression_${runSlug}.jou`);
        const runProjectName = `mcp_reg_${runSlug}`;

        const runTcl = buildVivadoTclContent({
            projectName: runProjectName,
            projectDir: runProjectDir,
            srcFiles: srcFileList,
            tbFiles: tbFileList,
            includeDirs,
            topModule,
            simTime,
            testName,
        });
        fs.writeFileSync(runTclPath, runTcl, 'utf-8');

        console.log(`[Regression] Running TESTNAME=${testName}`);
        const runResult = runVivadoBatch(runTclPath, runLogPath, runJouPath, workDir);
        const logResult = parseRunLog(runLogPath);

        let reason = 'ok';
        if (!runResult.ok) reason = 'vivado_failed';
        else if (!logResult.hasEnvReport) reason = 'missing_env_report';
        else if (!Number.isFinite(logResult.errorCount) || logResult.errorCount !== 0) reason = 'scoreboard_errors';
        else if (logResult.hasFatal) reason = 'fatal_or_assert';

        const pass = reason === 'ok';
        regressionRows.push({
            testName,
            pass,
            checkedCount: logResult.checkedCount,
            errorCount: logResult.errorCount,
            reason,
            logPath: runLogPath,
        });

        console.log(`[Regression] ${testName}: ${pass ? 'PASS' : 'FAIL'} (reason=${reason})`);
    }

    const summaryPath = path.join(outDirFs, `regression_${path.basename(tbFileAbs, path.extname(tbFileAbs))}.md`);
    writeRegressionSummary(summaryPath, regressionRows);
    console.log(`Regression summary: ${summaryPath}`);

    const failCount = regressionRows.filter((r) => !r.pass).length;
    if (failCount > 0) {
        console.error(`Vivado regression failed: ${failCount}/${regressionRows.length} tests failed.`);
        process.exit(1);
    }

    console.log(`Vivado regression passed: ${regressionRows.length}/${regressionRows.length}.`);
    process.exit(0);
}

const projDir = path.join(projectRoot, 'work');
const tclContent = buildVivadoTclContent({
    projectName: 'mcp_sim_proj',
    projectDir: projDir,
    srcFiles: srcFileList,
    tbFiles: tbFileList,
    includeDirs,
    topModule,
    simTime,
    testName: '',
});

fs.writeFileSync(tclPath, tclContent, 'utf-8');
console.log(`TCL script generated: ${tclPath}`);

// 2.2 Run Simulation (Vivado)
console.log("Running Vivado Simulation...");
const singleRunLogPath = path.join(simLogDir, 'vivado_sim.log');
const singleRunJouPath = path.join(simLogDir, 'vivado_sim.jou');
const singleRunResult = runVivadoBatch(tclPath, singleRunLogPath, singleRunJouPath, workDir);
if (!singleRunResult.ok) {
    console.error("Vivado simulation failed. Check logs.");
    process.exit(1);
}

// 3. Resolve Paths (Relative to Config File)
const toolsDir = __dirname; // Assuming this script is in /tools
const vcd2wavedromScript = path.join(toolsDir, 'vcd2wavedrom.js');

let vcdFile = path.resolve(projectRoot, vcdRelPath);
const htmlFile = path.resolve(projectRoot, htmlRelPath);
const outputDir = path.dirname(htmlFile);

// Ensure output directory exists
if (!fs.existsSync(outDirFs)) {
    fs.mkdirSync(outDirFs, { recursive: true });
}
if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
}

// 4. Check VCD Existence
if (!fs.existsSync(vcdFile)) {
    const fallbackVcd = findFallbackVcd(projectRoot);
    if (fallbackVcd) {
        fs.mkdirSync(path.dirname(vcdFile), { recursive: true });
        try {
            fs.copyFileSync(fallbackVcd, vcdFile);
            console.warn(`[WARN] Primary VCD not found. Copied fallback VCD: ${fallbackVcd}`);
        } catch {
            vcdFile = fallbackVcd;
            console.warn(`[WARN] Primary VCD not found. Using fallback VCD directly: ${fallbackVcd}`);
        }
    }
}
if (!fs.existsSync(vcdFile)) {
    console.error(`Error: VCD file not found at ${vcdFile}`);
    console.error("Simulation may have completed without VCD output. Check testbench dump settings.");
    process.exit(1);
}

// 5. Process Scenarios (Generate JSONs)
console.log(`Processing ${normalizedScenarios.length} scenarios for project: ${projectName}`);
const generatedFiles = [];

normalizedScenarios.forEach(scenario => {
    if (scenario.signals.length === 0) {
        console.warn(`[${scenario.title}] skipped: no signals.`);
        return;
    }

    const jsonFilename = `wave_${scenario.id}.json`;
    const outFile = path.join(outDirFs, jsonFilename);
    const signals = scenario.signals.join(',');
    
    // Command: node vcd2wavedrom.js input output start duration signals step
    const cmd = `node "${vcd2wavedromScript}" "${vcdFile}" "${outFile}" ${scenario.start_ns} ${scenario.duration_ns} "${signals}" ${scenario.sample_step_ns}`;
    
    console.log(`[${scenario.title}] Extracting waveform...`);
    try {
        execSync(cmd, { stdio: 'inherit' });
        if (fs.existsSync(outFile)) {
            generatedFiles.push({
                file: outFile,
                title: scenario.title,
                description: scenario.description || "",
                start_ns: scenario.start_ns,
                duration_ns: scenario.duration_ns
            });
        }
    } catch (e) {
        console.error(`Failed to process scenario ${scenario.id}:`, e.message);
    }
});

// 6. Generate HTML Report
console.log("Compiling HTML report...");

let htmlContent = `<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>${projectName} - Simulation Report</title>
<script src="https://cdnjs.cloudflare.com/ajax/libs/wavedrom/3.5.0/skins/default.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/wavedrom/3.5.0/wavedrom.min.js"></script>
<style>
body { font-family: 'Segoe UI', Arial, sans-serif; margin: 0; padding: 20px; background-color: #f4f7f6; color: #333; }
.header { text-align: center; margin-bottom: 40px; padding-bottom: 20px; border-bottom: 1px solid #ddd; }
.header h1 { margin: 0; color: #2c3e50; }
.header p { color: #7f8c8d; }
.wave-card { 
    background: white; 
    border-radius: 8px; 
    box-shadow: 0 2px 10px rgba(0,0,0,0.05); 
    padding: 20px; 
    margin-bottom: 30px; 
}
.wave-card h2 { margin-top: 0; font-size: 1.2rem; color: #2980b9; border-left: 4px solid #3498db; padding-left: 10px; }
.wave-card p { color: #666; font-size: 0.9rem; margin-bottom: 15px; }
.wave-view { overflow-x: auto; padding: 10px 0; }
</style>
</head>
<body onload="WaveDrom.ProcessAll()">
<div class="header">
    <h1>${projectName}</h1>
    <p>Simulation Report | Generated on ${new Date().toLocaleString()}</p>
</div>
`;

generatedFiles.forEach(item => {
    const jsonData = fs.readFileSync(item.file, 'utf-8');
    const endNs = item.start_ns + item.duration_ns;
    const runtimeInfo = `Runtime: ${item.duration_ns} ns (Window: ${item.start_ns} ns ~ ${endNs} ns)`;
    htmlContent += `
    <div class="wave-card">
        <h2>${item.title}</h2>
        <p>${runtimeInfo}</p>
        ${item.description ? `<p>${item.description}</p>` : ''}
        <div class="wave-view">
            <script type="WaveDrom">
            ${jsonData}
            </script>
        </div>
    </div>
    `;
});

if (generatedFiles.length === 0) {
    htmlContent += `
    <div class="wave-card">
        <h2>No Waveforms</h2>
        <p>No scenario produced output JSON. Check TEST/@WAVE/@RUNTIME BEGIN:time and END:time directives in your testbench.</p>
    </div>
    `;
}

htmlContent += `
</body>
</html>`;

fs.writeFileSync(htmlFile, htmlContent);
console.log(`\nSUCCESS: Report generated at: ${htmlFile}`);
