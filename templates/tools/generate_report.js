const fs = require('fs');
const { execSync } = require('child_process');
const path = require('path');

// 1. Get Config File Path from Argument
const args = process.argv.slice(2);
if (args.length < 1) {
    console.error("Usage: node generate_report.js <path_to_config.json>");
    process.exit(1);
}

const configPath = path.resolve(args[0]);
if (!fs.existsSync(configPath)) {
    console.error(`Error: Config file not found at ${configPath}`);
    process.exit(1);
}

// 2. Load Configuration
console.log(`Loading configuration from: ${configPath}`);
const config = JSON.parse(fs.readFileSync(configPath, 'utf-8'));
const projectRoot = path.dirname(configPath); // Config file location is the project root anchor
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

const simDurationNs = Math.max(
    normalizeNumber(cfg.sim_duration_ns, 0),
    maxScenarioEndNs + 10000
);
const simTime = simDurationNs > 0 ? `${simDurationNs / 1000000} ms` : '5 ms';
const topModule = cfg.top_module || 'tb_Top';
const projectName = cfg.project_name || path.basename(projectRoot);
const tbRelPath = cfg.tb_file || path.join('tb', `${topModule}${cfg.tb_file_ext || '.v'}`).replace(/\\/g, '/');
const vcdRelPath = cfg.vcd_file || 'output/mcp_sim_wave.vcd';
const htmlRelPath = cfg.html_file || `output/view_wave_${topModule}.html`;

// 2.1 Generate TCL Script
console.log("Generating Vivado TCL script...");
const tclPath = path.join(projectRoot, 'tcl', 'run_sim_autogen.tcl');

function collectFilesRecursive(rootDir, exts) {
    const out = [];
    if (!fs.existsSync(rootDir)) return out;
    const stack = [rootDir];
    while (stack.length > 0) {
        const cur = stack.pop();
        const entries = fs.readdirSync(cur, { withFileTypes: true });
        for (const e of entries) {
            const p = path.join(cur, e.name);
            if (e.isDirectory()) {
                stack.push(p);
                continue;
            }
            if (!e.isFile()) continue;
            const ext = path.extname(e.name).toLowerCase();
            if (exts.includes(ext)) out.push(p);
        }
    }
    return out.sort((a, b) => a.localeCompare(b));
}

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

function collectIncludeDirs(projectRootDir) {
    const roots = [path.join(projectRootDir, 'src'), path.join(projectRootDir, 'tb'), path.join(projectRootDir, 'include'), path.join(projectRootDir, 'inc')];
    const dirs = new Set();
    for (const root of roots) {
        if (!fs.existsSync(root)) continue;
        dirs.add(path.resolve(root));
        const stack = [root];
        while (stack.length > 0) {
            const cur = stack.pop();
            const entries = fs.readdirSync(cur, { withFileTypes: true });
            for (const e of entries) {
                const p = path.join(cur, e.name);
                if (e.isDirectory()) {
                    stack.push(p);
                    continue;
                }
                if (e.isFile() && /\.(svh|vh)$/i.test(e.name)) {
                    dirs.add(path.resolve(cur));
                }
            }
        }
    }
    return Array.from(dirs).sort((a, b) => a.localeCompare(b));
}

// Use forward slashes for TCL compatibility
const projDir = toTclPath(path.join(projectRoot, 'work'));
const srcDir = toTclPath(path.join(projectRoot, 'src'));
const tbDir = toTclPath(path.join(projectRoot, 'tb'));
const outDirFs = path.join(projectRoot, 'output');
const outDir = toTclPath(outDirFs);
const tbFileAbs = path.resolve(projectRoot, tbRelPath);
const srcFileList = collectFilesRecursive(path.join(projectRoot, 'src'), ['.v', '.sv']);
const tbFileList = collectFilesRecursive(path.join(projectRoot, 'tb'), ['.v', '.sv']);
if (tbFileList.length === 0 && fs.existsSync(tbFileAbs)) {
    tbFileList.push(tbFileAbs);
}
const includeDirs = collectIncludeDirs(projectRoot);
if (fs.existsSync(tbFileAbs) && !tbFileList.find((p) => path.resolve(p) === path.resolve(tbFileAbs))) {
    tbFileList.push(tbFileAbs);
}
const tbFileListTcl = toTclList(tbFileList);
const srcFileListTcl = toTclList(srcFileList);
const incDirListTcl = toTclList(includeDirs);

const tclContent = `# Auto-generated by generate_report.js
set project_name "mcp_sim_proj"
set project_dir "${projDir}"
set src_dir "${srcDir}"
set tb_dir "${tbDir}"
set out_dir "${outDir}"
set src_files [list ${srcFileListTcl}]
set tb_files [list ${tbFileListTcl}]
set include_dirs [list ${incDirListTcl}]

# Create/Reset Project
create_project -force $project_name $project_dir -part xc7a35tcpg236-1

# Add Sources
if {[llength $src_files] > 0} { add_files -norecurse $src_files }
if {[llength $tb_files] > 0} { add_files -fileset sim_1 -norecurse $tb_files }
if {[llength $include_dirs] > 0} {
    catch { set_property include_dirs $include_dirs [get_filesets sources_1] }
    catch { set_property include_dirs $include_dirs [get_filesets sim_1] }
}

# Set Top
set_property top ${topModule} [get_filesets sim_1]
update_compile_order -fileset sim_1

# Run Simulation
launch_simulation
set custom_vcd "$out_dir/mcp_sim_wave.vcd"
set custom_vcd_opened 0
if {[catch {open_vcd $custom_vcd} open_err]} {
    puts "WARNING: open_vcd skipped: $open_err"
} else {
    set custom_vcd_opened 1
    catch {log_vcd [get_objects -r /${topModule}/*]}
}
if {[catch {run ${simTime}} run_err]} {
    puts "Error during simulation run: $run_err"
}
if {$custom_vcd_opened} {
    catch {close_vcd}
}
catch {close_sim}

close_project
exit
`;

if (!fs.existsSync(path.dirname(tclPath))) {
    fs.mkdirSync(path.dirname(tclPath), { recursive: true });
}
fs.writeFileSync(tclPath, tclContent);
console.log(`TCL script generated: ${tclPath}`);
console.log(`HDL lang: ${cfg.hdl_lang || "unknown"}, TB file: ${tbRelPath}`);

// 2.2 Run Simulation (Vivado)
console.log("Running Vivado Simulation...");
const workDir = path.join(projectRoot, 'work');
if (!fs.existsSync(workDir)) {
    fs.mkdirSync(workDir, { recursive: true });
}
try {
    const vivadoCmd = `vivado -mode batch -source "${tclPath}"`;
    // Increase maxBuffer to handle large Vivado output
    execSync(vivadoCmd, { stdio: 'inherit', cwd: workDir, maxBuffer: 1024 * 1024 * 10 });
} catch (e) {
    console.error("Vivado simulation failed. Check logs.");
    // We might continue if VCD exists, but usually we stop.
    // process.exit(1); 
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
