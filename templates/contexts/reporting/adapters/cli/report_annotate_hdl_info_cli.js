const fs = require('fs');
const path = require('path');
const { loadStrictManifestContext } = require('../../../../shared/application/manifest_contract_loader');

function usageAndExit() {
    console.error('Usage: node annotate_hdl_info.js <ProjectDir> --manifest-json <path> [--include-legacy]');
    process.exit(1);
}

function parseArgs(argv) {
    let projectArg = '';
    let manifestJsonArg = '';
    let includeLegacy = false;

    for (let i = 0; i < argv.length; i++) {
        const arg = String(argv[i] || '');
        if (arg === '--include-legacy') {
            includeLegacy = true;
            continue;
        }
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
        if (!projectArg) {
            projectArg = arg;
            continue;
        }
        usageAndExit();
    }

    if (!projectArg || !manifestJsonArg) usageAndExit();
    return {
        projectRoot: path.resolve(projectArg),
        manifestJsonPath: path.resolve(manifestJsonArg),
        includeLegacy,
    };
}

const cli = parseArgs(process.argv.slice(2));
const projectRoot = cli.projectRoot;
const includeLegacy = cli.includeLegacy;
let manifestContext = null;
try {
    manifestContext = loadStrictManifestContext(projectRoot, cli.manifestJsonPath);
} catch (err) {
    console.error(`[ERROR] ${err.message}`);
    process.exit(1);
}

function normalizeSlashes(p) {
    return p.replace(/\\/g, '/');
}

function walkVerilogFiles(dirPath, options = {}) {
    const skipLegacy = options.skipLegacy !== false;
    const result = [];
    if (!fs.existsSync(dirPath)) return result;

    const stack = [dirPath];
    while (stack.length > 0) {
        const current = stack.pop();
        const entries = fs.readdirSync(current, { withFileTypes: true });
        entries.sort((a, b) => a.name.localeCompare(b.name));

        for (const entry of entries) {
            const absPath = path.join(current, entry.name);
            if (entry.isDirectory()) {
                if (skipLegacy && entry.name.toLowerCase() === 'legacy') continue;
                stack.push(absPath);
                continue;
            }
            if (entry.isFile() && /\.(v|sv)$/i.test(entry.name)) {
                result.push(absPath);
            }
        }
    }

    result.sort((a, b) => a.localeCompare(b));
    return result;
}

function stripComments(content) {
    const noBlock = content.replace(/\/\*[\s\S]*?\*\//g, '');
    return noBlock.replace(/\/\/.*$/gm, '');
}

function detectModuleName(content, fallbackName) {
    const clean = stripComments(content);
    const moduleMatch = clean.match(/\bmodule\s+(?:(?:automatic|static)\s+)?([A-Za-z_]\w*)\b/i);
    return moduleMatch ? moduleMatch[1] : fallbackName;
}

function detectFsm(cleanContent) {
    const hasStateCase = /\bcase\s*\(\s*[A-Za-z_]\w*(?:state|fsm|cur|next)[A-Za-z_0-9]*\s*\)/i.test(cleanContent);
    const hasStateDecl = /\b(localparam|parameter|typedef\s+enum)\b[\s\S]{0,500}\b[A-Za-z_]\w*(?:state|idle|init|run|wait|done)\w*\b/i.test(cleanContent);
    const hasAlways = /\balways\s*@|\balways_comb\b|\balways_ff\b/i.test(cleanContent);
    return (hasAlways && hasStateCase) || hasStateDecl;
}

function addState(states, token) {
    if (!token) return;
    const clean = token.trim();
    if (!clean) return;
    if (!/^[A-Za-z_]\w*$/.test(clean)) return;
    if (/^(default|begin|end)$/i.test(clean)) return;
    if (!states.includes(clean)) states.push(clean);
}

function extractStateNames(cleanContent) {
    const states = [];

    const enumRegex = /\btypedef\s+enum\b[\s\S]*?\{([\s\S]*?)\}\s*[A-Za-z_]\w*(?:state|fsm)\w*/gi;
    let enumMatch;
    while ((enumMatch = enumRegex.exec(cleanContent)) !== null) {
        const body = enumMatch[1];
        const rawTokens = body.split(',');
        for (const token of rawTokens) {
            const symbol = token.split('=')[0].trim();
            addState(states, symbol);
        }
    }

    const paramRegex = /\b(?:localparam|parameter)\b([^;]*);/gi;
    let paramMatch;
    while ((paramMatch = paramRegex.exec(cleanContent)) !== null) {
        const decl = paramMatch[1];
        const pairRegex = /([A-Za-z_]\w*)\s*=/g;
        let pairMatch;
        while ((pairMatch = pairRegex.exec(decl)) !== null) {
            const symbol = pairMatch[1];
            if (/(^S_|\bSTATE\b|IDLE|INIT|RUN|WAIT|DONE|START|STOP|REQ|RESP|TX|RX)/i.test(symbol)) {
                addState(states, symbol);
            }
        }
    }

    const caseRegex = /\bcase\s*\(\s*([^)]+)\s*\)\s*([\s\S]*?)\bendcase\b/gi;
    let caseMatch;
    while ((caseMatch = caseRegex.exec(cleanContent)) !== null) {
        const selector = caseMatch[1];
        if (!/(state|fsm|cur|next)/i.test(selector)) continue;
        const body = caseMatch[2];
        const labelRegex = /^\s*([A-Za-z_]\w*)\s*:/gm;
        let labelMatch;
        while ((labelMatch = labelRegex.exec(body)) !== null) {
            addState(states, labelMatch[1]);
        }
    }

    return states;
}

function describeState(stateName) {
    const upper = stateName.toUpperCase();
    if (upper.includes('IDLE')) return 'Idle/default wait state';
    if (upper.includes('INIT')) return 'Initialization state';
    if (upper.includes('READY')) return 'Ready for next transaction/event';
    if (upper.includes('START')) return 'Transaction start control state';
    if (upper.includes('RUN') || upper.includes('WORK')) return 'Main operation state';
    if (upper.includes('WAIT') || upper.includes('HOLD')) return 'Wait/hold until condition is met';
    if (upper.includes('REQ')) return 'Request issue/hold state';
    if (upper.includes('RESP') || upper.includes('ACK')) return 'Response/ack handling state';
    if (upper.includes('TX')) return 'Transmit datapath control state';
    if (upper.includes('RX')) return 'Receive datapath control state';
    if (upper.includes('DONE') || upper.includes('FINISH')) return 'Completion and cleanup state';
    if (upper.includes('ERROR') || upper.includes('ERR')) return 'Error handling/recovery state';
    return 'Describe entry condition, action, and exit condition';
}

function buildModuleInfoBlock(moduleName, hasFsm, stateNames) {
    const lines = [];
    lines.push('/*');
    lines.push('[MODULE_INFO_START]');
    lines.push(`Name: ${moduleName}`);
    lines.push(`Role: RTL module implementing ${moduleName}`);
    lines.push('Summary:');
    lines.push('  - Implements required data/control logic for this block');
    lines.push('  - Uses synthesizable combinational/sequential logic partition');
    if (hasFsm) {
        lines.push('  - Includes FSM-like control behavior for operation sequencing');
        lines.push('StateDescription:');
        if (stateNames.length > 0) {
            stateNames.forEach(state => {
                lines.push(`  - ${state}: ${describeState(state)}`);
            });
        } else {
            lines.push('  - (No explicit state symbol extracted) Fill states manually');
        }
    }
    lines.push('[MODULE_INFO_END]');
    lines.push('*/');
    return lines.join('\n');
}

function parseSrcModuleNames(srcFiles) {
    const names = new Set();
    for (const filePath of srcFiles) {
        const raw = fs.readFileSync(filePath, 'utf8');
        const fallback = path.basename(filePath, path.extname(filePath));
        names.add(detectModuleName(raw, fallback));
    }
    return names;
}

function detectTbName(content, fallbackName) {
    const clean = stripComments(content);
    const match = clean.match(/\b(?:module|program)\s+(?:(?:automatic|static)\s+)?([A-Za-z_]\w*)\b/i);
    return match ? match[1] : fallbackName;
}

function detectTargetModule(tbName, cleanTb, srcModuleNames) {
    if (tbName.toLowerCase().startsWith('tb_')) {
        const byName = tbName.slice(3);
        const hit = [...srcModuleNames].find(name => name.toLowerCase() === byName.toLowerCase());
        if (hit) return hit;
    }

    const instRegex = /(^|\n)\s*([A-Za-z_]\w*)\s*(?:#\s*\([\s\S]*?\)\s*)?([A-Za-z_]\w*)\s*\(/g;
    let match;
    while ((match = instRegex.exec(cleanTb)) !== null) {
        const typeName = match[2];
        if (srcModuleNames.has(typeName)) return typeName;
    }
    return 'Unknown';
}

function extractTbScenarios(rawTb) {
    const scenarios = [];
    const seen = new Set();
    const seenKey = new Set();
    const lines = rawTb.split(/\r?\n/);

    for (const line of lines) {
        const trimmed = line.trim();
        const caseMatch = trimmed.match(/^\/\/\s*(?:Case|CASE|Scenario|SCENARIO)\s*[:#-]?\s*(.+)$/);
        if (caseMatch) {
            const text = caseMatch[1].trim();
            const key = `case:${text.toLowerCase()}`;
            const isNoise = /^[\W_]+$/.test(text);
            if (text && !isNoise && !seen.has(text) && !seenKey.has(key)) {
                seen.add(text);
                seenKey.add(key);
                scenarios.push(text);
            }
        }
    }

    const taskRegex = /\btask\s+(?:automatic\s+)?([A-Za-z_]\w*)/g;
    let taskMatch;
    while ((taskMatch = taskRegex.exec(rawTb)) !== null) {
        const taskName = taskMatch[1];
        if (!taskName || /^dump/i.test(taskName)) continue;
        const text = `${taskName}: task-based stimulus/check sequence`;
        const key = `task:${taskName.toLowerCase()}`;
        if (!seen.has(text) && !seenKey.has(key)) {
            seen.add(text);
            seenKey.add(key);
            scenarios.push(text);
        }
    }

    const callRegex = /\b(run_[A-Za-z_]\w*)\s*\(/g;
    let callMatch;
    while ((callMatch = callRegex.exec(rawTb)) !== null) {
        const callName = callMatch[1];
        const text = `${callName}: grouped testcase execution`;
        const taskKey = `task:${callName.toLowerCase()}`;
        const key = `call:${callName.toLowerCase()}`;
        if (!seen.has(text) && !seenKey.has(taskKey) && !seenKey.has(key)) {
            seen.add(text);
            seenKey.add(key);
            scenarios.push(text);
        }
    }

    if (scenarios.length === 0) {
        scenarios.push('Apply and release reset, then check DUT initialization');
        scenarios.push('Apply core stimuli and check output behavior');
        scenarios.push('Cover boundary/error cases with PASS/FAIL criteria');
    }

    return scenarios.slice(0, 8);
}

function buildTbInfoBlock(tbName, targetModule, scenarios, rawTb) {
    const hasPassFail = /\[\s*(PASS|FAIL)\s*\]/i.test(rawTb) || /\bPASS\b|\bFAIL\b/i.test(rawTb);
    const lines = [];
    lines.push('/*');
    lines.push('[TB_INFO_START]');
    lines.push(`Name: ${tbName}`);
    lines.push(`Target: ${targetModule}`);
    lines.push(`Role: Testbench for validating ${targetModule}`);
    lines.push('Scenario:');
    scenarios.forEach(item => {
        lines.push(`  - ${item}`);
    });
    lines.push('CheckPoint:');
    lines.push('  - Verify DUT reset and default outputs first');
    lines.push('  - Compare key outputs/internal probes against expected behavior');
    if (hasPassFail) {
        lines.push('  - Use PASS/FAIL logs to judge each testcase');
    } else {
        lines.push('  - Add explicit expected-value checks for auto-judgement');
    }
    lines.push('[TB_INFO_END]');
    lines.push('*/');
    return lines.join('\n');
}

function stripLeadingLegacyComments(content) {
    let text = content;

    while (true) {
        const blockMatch = text.match(/^(\s*\/\*[\s\S]*?\*\/\s*)/);
        if (blockMatch) {
            const block = blockMatch[1];
            // Keep the generated info block if it is already present.
            if (/\[(MODULE|TB)_INFO_START\]/.test(block)) {
                break;
            }
            text = text.slice(block.length);
            continue;
        }

        const lineMatch = text.match(/^(\s*(?:\/\/[^\n]*(?:\n|$))+)/);
        if (lineMatch) {
            text = text.slice(lineMatch[1].length);
            continue;
        }

        break;
    }

    return text.replace(/^\s*\n/, '');
}

function replaceOrInsertBlock(content, blockText, type, eol) {
    const normalized = content.replace(/\r\n/g, '\n');
    const moduleRegex = /\/\*\s*\[MODULE_INFO_START][\s\S]*?\[MODULE_INFO_END]\s*\*\/\s*/m;
    const tbRegex = /\/\*\s*\[TB_INFO_START][\s\S]*?\[TB_INFO_END]\s*\*\/\s*/m;
    const targetRegex = type === 'module' ? moduleRegex : tbRegex;

    const withoutInfo = normalized.replace(targetRegex, '');
    const withoutLegacyHeader = stripLeadingLegacyComments(withoutInfo);
    const updated = `${blockText}\n\n${withoutLegacyHeader}`;

    return updated.replace(/\n/g, eol);
}

function annotateSrcFiles(srcFiles) {
    let changed = 0;
    const details = [];

    for (const filePath of srcFiles) {
        const raw = fs.readFileSync(filePath, 'utf8');
        const eol = raw.includes('\r\n') ? '\r\n' : '\n';
        const fallback = path.basename(filePath, path.extname(filePath));
        const moduleName = detectModuleName(raw, fallback);
        const clean = stripComments(raw);
        const hasFsm = detectFsm(clean);
        const stateNames = hasFsm ? extractStateNames(clean) : [];

        const block = buildModuleInfoBlock(moduleName, hasFsm, stateNames);
        const updated = replaceOrInsertBlock(raw, block, 'module', eol);

        if (updated !== raw) {
            fs.writeFileSync(filePath, updated, 'utf8');
            changed += 1;
        }

        details.push({
            file: filePath,
            module: moduleName,
            fsm: hasFsm,
            stateCount: stateNames.length
        });
    }

    return { changed, details };
}

function annotateTbFiles(tbFiles, srcModuleNames) {
    let changed = 0;
    const details = [];

    for (const filePath of tbFiles) {
        const raw = fs.readFileSync(filePath, 'utf8');
        const eol = raw.includes('\r\n') ? '\r\n' : '\n';
        const fallback = path.basename(filePath, path.extname(filePath));
        const tbName = detectTbName(raw, fallback);
        const clean = stripComments(raw);
        const targetModule = detectTargetModule(tbName, clean, srcModuleNames);
        const scenarios = extractTbScenarios(raw);

        const block = buildTbInfoBlock(tbName, targetModule, scenarios, raw);
        const updated = replaceOrInsertBlock(raw, block, 'tb', eol);

        if (updated !== raw) {
            fs.writeFileSync(filePath, updated, 'utf8');
            changed += 1;
        }

        details.push({
            file: filePath,
            tb: tbName,
            target: targetModule,
            scenarioCount: scenarios.length
        });
    }

    return { changed, details };
}

function main() {
    const srcFiles = (manifestContext.srcFiles || [])
        .filter((filePath) => /\.(v|sv)$/i.test(filePath))
        .sort((a, b) => a.localeCompare(b));
    const tbFiles = (manifestContext.tbFiles || [])
        .filter((filePath) => /\.(v|sv)$/i.test(filePath))
        .filter((filePath) => includeLegacy || !/\/legacy\//i.test(normalizeSlashes(filePath)))
        .sort((a, b) => a.localeCompare(b));
    if (srcFiles.length === 0) {
        throw new Error('manifest_resolved_empty:src_files');
    }

    const srcModuleNames = parseSrcModuleNames(srcFiles);

    const srcResult = annotateSrcFiles(srcFiles);
    const tbResult = annotateTbFiles(tbFiles, srcModuleNames);

    console.log('[SUCCESS] HDL info annotation completed.');
    console.log(`[INFO] Project: ${projectRoot}`);
    console.log(`[INFO] src files: ${srcFiles.length}, updated: ${srcResult.changed}`);
    console.log(`[INFO] tb files: ${tbFiles.length}, updated: ${tbResult.changed}`);
    if (!includeLegacy) {
        console.log('[INFO] tb/legacy is skipped by default. Use --include-legacy to include it.');
    }

    console.log('');
    console.log('[SRC SUMMARY]');
    srcResult.details.forEach(item => {
        const rel = normalizeSlashes(path.relative(projectRoot, item.file));
        const fsmText = item.fsm ? `FSM:yes(${item.stateCount})` : 'FSM:no';
        console.log(`- ${rel} -> ${item.module} / ${fsmText}`);
    });

    console.log('');
    console.log('[TB SUMMARY]');
    tbResult.details.forEach(item => {
        const rel = normalizeSlashes(path.relative(projectRoot, item.file));
        console.log(`- ${rel} -> ${item.tb} / target:${item.target} / scenarios:${item.scenarioCount}`);
    });
}

try {
    main();
} catch (error) {
    console.error(`[ERROR] ${error.message}`);
    process.exit(1);
}
