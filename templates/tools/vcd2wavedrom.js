const fs = require('fs');

const args = process.argv.slice(2);
if (args.length < 5) { // Need at least 5 args (vcd, out, start, dur, signals)
    console.error("Usage: node vcd2wavedrom.js <input.vcd> <output.json> <start_time_ns> <duration_ns> <signal_list> [sample_step_ns]");
    process.exit(1);
}

const vcdFile = args[0];
const outputFile = args[1];
const startTimeNs = parseFloat(args[2]);
const durationNs = parseFloat(args[3]);
const signalInput = args[4];
const sampleStepNs = args[5] ? parseFloat(args[5]) : 50; 

// Parse signals
const targetSignalNames = signalInput.split(',').map(s => s.trim()).filter(s => s.length > 0);

// Configuration
const TIME_SCALE_NS = 1000; // 1ns = 1000ps (VCD unit)
const SAMPLE_STEP = sampleStepNs * 1000;    // Convert ns to ps

// Calculate VCD time range (assuming 1ps timescale)
const vcdStartTime = startTimeNs * 1000;
const vcdEndTime = vcdStartTime + (durationNs * 1000);
const maxSamples = (durationNs * 1000) / SAMPLE_STEP;

if (maxSamples > 10000) {
    console.warn(`Warning: High sample count (${maxSamples}). JSON might be large.`);
}

const vcdContent = fs.readFileSync(vcdFile, 'utf-8');
const lines = vcdContent.split(/\r?\n/);

const signalMap = {}; // ID -> Name (Full Path or Matched Name)
const signalData = {}; // Name -> [{time, val}]

// Initialize signalData
targetSignalNames.forEach(sig => signalData[sig] = []);

let currentTime = 0;
let scopeStack = [];

// 1. Parse VCD
for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) continue;

    if (trimmed.startsWith('$scope')) {
        const parts = trimmed.split(/\s+/);
        scopeStack.push(parts[2]);
    } else if (trimmed.startsWith('$upscope')) {
        scopeStack.pop();
    } else if (trimmed.startsWith('$var')) {
        const parts = trimmed.split(/\s+/);
        // $var type size id name $end
        const id = parts[3];
        const leafName = parts[4];
        
        // Construct full path: scope.scope.name
        const fullPath = scopeStack.length > 0 ? scopeStack.join('.') + '.' + leafName : leafName;

        let matchedTarget = null;
        
        // Check against all target signals
        // We allow suffix match: e.g. "uGlobalTickGen.oTick100Hz" matches "tb_Top.uut.uGlobalTickGen.oTick100Hz"
        // Also exact leaf name match: "iClk100m" matches "tb_Top.iClk100m"
        
        for (const target of targetSignalNames) {
            if (fullPath === target || fullPath.endsWith('.' + target) || leafName === target) {
                matchedTarget = target; // Use the user's requested name as the key for output
                break;
            }
        }
        
        if (matchedTarget) {
            // If multiple IDs map to the same target (e.g. wire connected to reg), pick one.
            // Or better, just collect all updates? VCD usually has separate vars.
            // Let's just overwrite.
            signalMap[id] = matchedTarget;
        }
    } else if (trimmed.startsWith('#')) {
        currentTime = parseInt(trimmed.substring(1));
        if (currentTime > vcdEndTime) break; 
    } else if (trimmed.startsWith('$timescale')) {
       // Assuming 1ps
    } else if (!trimmed.startsWith('$')) {
        // Value change
        let val, id;
        if (trimmed.startsWith('b') || trimmed.startsWith('B')) {
            const parts = trimmed.split(/\s+/);
            val = parts[0].substring(1);
            id = parts[1];
        } else {
            val = trimmed[0];
            id = trimmed.substring(1);
        }

        if (signalMap[id]) {
            const name = signalMap[id];
            signalData[name].push({ time: currentTime, val: val });
        }
    }
}

// 2. Convert to WaveDrom
const output = { 
    signal: [], 
    head: { text: `Time: ${startTimeNs}ns - ${startTimeNs + durationNs}ns` }, 
    config: { hscale: 1 } 
};

// Helper to get value
function getValueAt(name, time) {
    const changes = signalData[name];
    let lastVal = 'x';
    for (const change of changes) {
        if (change.time > time) break;
        lastVal = change.val;
    }
    return lastVal;
}

// Process data
targetSignalNames.forEach(name => {
    let waveStr = "";
    let prevValChar = '';
    
    // Check if signal had any data
    if (!signalData[name]) {
         output.signal.push({ name: name, wave: "x" });
         return;
    }

    for (let i = 0; i <= maxSamples; i++) {
        const sampleTime = vcdStartTime + (i * SAMPLE_STEP);
        const val = getValueAt(name, sampleTime);
        
        let char;
        if (val === '0') char = '0';
        else if (val === '1') char = '1';
        else if (val && (val.toLowerCase().includes('x') || val.toLowerCase() === 'x')) char = 'x';
        else if (val && (val.toLowerCase().includes('z') || val.toLowerCase() === 'z')) char = 'z';
        else char = '='; // Bus value

        if (char === prevValChar && char !== '=') {
            waveStr += '.';
        } else {
            waveStr += char;
        }
        prevValChar = char;
    }

    const entry = { name: name, wave: waveStr };
    if (prevValChar === '=') entry.data = ["data"];
    output.signal.push(entry);
});

fs.writeFileSync(outputFile, JSON.stringify(output, null, 2));
console.log(`Generated WaveDrom JSON: ${outputFile}`);
