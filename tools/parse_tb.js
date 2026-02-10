const fs = require('fs');
const path = require('path');

function usageAndExit() {
    console.error('Usage: node tools/parse_tb.js <path_to_tb_file.v>');
    process.exit(1);
}

const args = process.argv.slice(2);
if (args.length < 1) {
    usageAndExit();
}

const tbFile = path.resolve(args[0]);
if (!fs.existsSync(tbFile)) {
    console.error(`Error: Testbench file not found at ${tbFile}`);
    process.exit(1);
}

console.log(`Parsing testbench: ${tbFile}`);

const tbContent = fs.readFileSync(tbFile, 'utf-8');
const lines = tbContent.split(/\r?\n/);

function stripInlineComment(line) {
    return line.replace(/\/\/.*$/, '');
}

function unitToNs(unit) {
    const u = String(unit || '').toLowerCase();
    if (u === 'fs') return 1e-6;
    if (u === 'ps') return 1e-3;
    if (u === 'ns') return 1;
    if (u === 'us') return 1e3;
    if (u === 'ms') return 1e6;
    if (u === 's') return 1e9;
    return 1;
}

function parseTimescale(content) {
    const m = content.match(/`timescale\s+(\d+)\s*(fs|ps|ns|us|ms|s)\s*\/\s*(\d+)\s*(fs|ps|ns|us|ms|s)/i);
    if (!m) {
        return { unitValue: 1, unitName: 'ns', unitNs: 1 };
    }

    const unitValue = parseInt(m[1], 10);
    const unitName = m[2];
    return {
        unitValue,
        unitName,
        unitNs: unitValue * unitToNs(unitName)
    };
}

function safeEvalExpression(expr, valueMap) {
    if (expr == null) return NaN;

    let normalized = String(expr).trim();
    if (!normalized) return NaN;

    // Allow numeric separators like 100_000 while keeping identifier underscores.
    normalized = normalized.replace(/(\d)_(?=\d)/g, '$1');
    normalized = normalized.replace(/\b[a-zA-Z_][a-zA-Z0-9_]*\b/g, (name) => {
        if (Object.prototype.hasOwnProperty.call(valueMap, name)) {
            return String(valueMap[name]);
        }
        return '(0/0)';
    });

    if (/[^0-9eE+\-*/().\s]/.test(normalized)) {
        return NaN;
    }

    try {
        const value = Function(`"use strict"; return (${normalized});`)();
        if (typeof value !== 'number' || !Number.isFinite(value)) {
            return NaN;
        }
        return value;
    } catch {
        return NaN;
    }
}

function unique(items) {
    return [...new Set(items.filter(Boolean))];
}

function parseSignals(lineList) {
    const found = [];

    lineList.forEach((line) => {
        const code = stripInlineComment(line);
        const declMatch = code.match(/^\s*(reg|wire|logic)\b([^;]*);/);
        if (!declMatch) return;

        let body = declMatch[2];
        body = body.replace(/\[[^\]]+\]/g, ' ');
        body = body.replace(/\bsigned\b/g, ' ');

        body.split(',').forEach((part) => {
            const nameMatch = part.match(/([a-zA-Z_][a-zA-Z0-9_$]*)\s*(?:=\s*[^,]+)?$/);
            if (nameMatch) {
                found.push(nameMatch[1]);
            }
        });
    });

    return unique(found);
}

function parseParamMap(lineList) {
    const map = {};

    lineList.forEach((line) => {
        const code = stripInlineComment(line);
        const paramMatch = code.match(/\b(?:localparam|parameter)\b\s+(?:\[[^\]]+\]\s*)?([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*([^;]+);/);
        if (!paramMatch) return;

        const name = paramMatch[1];
        const expr = paramMatch[2].trim();
        const value = safeEvalExpression(expr, map);
        if (Number.isFinite(value)) {
            map[name] = value;
        }
    });

    return map;
}

function extractTopModuleName(content, fallback) {
    const m = content.match(/\bmodule\s+([a-zA-Z_][a-zA-Z0-9_$]*)\s*(?:#\s*\(|\()/);
    return m ? m[1] : fallback;
}

function slugify(text) {
    return String(text || '')
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, '_')
        .replace(/^_+|_+$/g, '')
        .slice(0, 40) || 'case';
}

function parseRuntimeToNs(runtimeExpr, paramMap, defaultUnitNs) {
    if (!runtimeExpr) return NaN;

    let expr = runtimeExpr.trim();
    let unitScaleNs = defaultUnitNs;

    const unitMatch = expr.match(/^(.*?)(fs|ps|ns|us|ms|s)\s*$/i);
    if (unitMatch && unitMatch[1].trim()) {
        expr = unitMatch[1].trim();
        unitScaleNs = unitToNs(unitMatch[2]);
    }

    const value = safeEvalExpression(expr, paramMap);
    if (!Number.isFinite(value)) return NaN;

    return value * unitScaleNs;
}

function parseTestDirectiveLine(codeLine) {
    const testMatch = codeLine.match(/\$display\s*\(\s*"[^"]*?\bTEST(?:\s+CASE)?\s*(?:([0-9]+|N))?\s*:\s*([^"]+)"/i);
    if (testMatch) {
        return {
            caseToken: testMatch[1] || '',
            title: testMatch[2].trim()
        };
    }

    // Backward compatibility for legacy CASE_BEGIN markers.
    const caseBeginMatch = codeLine.match(/\$display\s*\(\s*"@CASE_BEGIN\|[^|]*\|([^"]+)"/i);
    if (caseBeginMatch) {
        return {
            caseToken: '',
            title: caseBeginMatch[1].trim()
        };
    }

    return null;
}

function parseWaveDirective(rawLine) {
    const m = rawLine.match(/\/\/\s*@WAVE\s*:\s*(.+)$/i);
    if (!m) return [];

    const payload = m[1].split('//')[0];

    return unique(
        payload
            .split(',')
            .map((s) => s.trim())
            .filter(Boolean)
    );
}

function parseRuntimeDirective(rawLine) {
    const markerMatch = rawLine.match(/\/\/\s*@RUNTIME\s*:?\s*(BEGIN|END)\s*(?::\s*(.+))?$/i);
    if (markerMatch) {
        const exprPayload = markerMatch[2] ? markerMatch[2].split('//')[0].trim() : '';
        return {
            type: 'marker',
            marker: markerMatch[1].toUpperCase(),
            expr: exprPayload || null
        };
    }

    const exprMatch = rawLine.match(/\/\/\s*@RUNTIME\s*:\s*(.+)$/i);
    if (exprMatch) {
        return {
            type: 'expr',
            expr: exprMatch[1].trim()
        };
    }

    return null;
}

function estimateTimeAdvanceNs(codeLine, context) {
    let totalNs = 0;
    const code = codeLine.trim();
    if (!code) return 0;
    if (/\bforever\b/i.test(code)) return 0;

    const delayRegex = /#\s*(\([^)]*\)|[a-zA-Z0-9_]+(?:\s*[+\-*/]\s*[a-zA-Z0-9_]+)*)/g;
    let dMatch;
    while ((dMatch = delayRegex.exec(code)) !== null) {
        let expr = dMatch[1].trim();
        if (expr.startsWith('(') && expr.endsWith(')')) {
            expr = expr.slice(1, -1).trim();
        }

        const value = safeEvalExpression(expr, context.paramMap);
        if (Number.isFinite(value)) {
            totalNs += value * context.timescale.unitNs;
        }
    }

    const repeatPosedgeRegex = /repeat\s*\(\s*([^)]+)\s*\)\s*@\(\s*posedge\s+[a-zA-Z_][a-zA-Z0-9_$]*\s*\)/ig;
    let rpMatch;
    while ((rpMatch = repeatPosedgeRegex.exec(code)) !== null) {
        const repeatCount = safeEvalExpression(rpMatch[1], context.paramMap);
        if (Number.isFinite(repeatCount) && repeatCount > 0) {
            totalNs += repeatCount * context.clockPeriodNs;
        }
    }

    const withoutRepeatPosedge = code.replace(repeatPosedgeRegex, '');
    const posedgeMatches = withoutRepeatPosedge.match(/@\(\s*posedge\s+[a-zA-Z_][a-zA-Z0-9_$]*\s*\)/ig);
    if (posedgeMatches) {
        totalNs += posedgeMatches.length * context.clockPeriodNs;
    }

    if (/\buart_send_byte\s*\(/.test(code)) {
        const bitPeriod = Number.isFinite(context.paramMap.BIT_PERIOD) ? context.paramMap.BIT_PERIOD : 8680;
        totalNs += bitPeriod * 12 * context.timescale.unitNs;
    }

    if (/\bpress_button\s*\(/.test(code)) {
        totalNs += 40000;
    }

    return totalNs;
}

const timescale = parseTimescale(tbContent);
const paramMap = parseParamMap(lines);
const extractedSignals = parseSignals(lines);
const preferredSignals = extractedSignals.filter((s) => /^([iow]|tb_)/i.test(s));
const baseSignals = preferredSignals.length > 0 ? unique(preferredSignals) : extractedSignals;
const clockPeriodRaw = Number.isFinite(paramMap.CLK_PERIOD) ? paramMap.CLK_PERIOD : 10;
const clockPeriodNs = clockPeriodRaw * timescale.unitNs;

const context = {
    timescale,
    paramMap,
    clockPeriodNs
};

let currentTimeNs = 0;
let scenarioIndex = 1;
let currentScenario = null;
let pendingWaveSignals = [];
let pendingRuntimeNs = null;
let pendingRuntimeBeginNs = null;
let pendingRuntimeBeginOffsetNs = null;
let pendingRuntimeEndOffsetNs = null;
let caseHeaderPending = false;
let inTaskBlock = false;

const warnings = [];
const scenarios = [];

function getScenarioAnchorNs(scenario) {
    if (!scenario) return 0;
    if (Number.isFinite(scenario.case_anchor_ns)) return scenario.case_anchor_ns;
    if (Number.isFinite(scenario.start_ns)) return scenario.start_ns;
    return 0;
}

function finalizeCurrentScenario(finalTimeNs) {
    if (!currentScenario) return;

    if (Number.isFinite(currentScenario.runtime_begin_ns)) {
        currentScenario.start_ns = currentScenario.runtime_begin_ns;
    }

    const effectiveStartNs = Number.isFinite(currentScenario.start_ns) ? currentScenario.start_ns : 0;

    if (Number.isFinite(currentScenario.runtime_end_ns)) {
        const markedDurationNs = Math.round(currentScenario.runtime_end_ns - effectiveStartNs);
        if (markedDurationNs > 0) {
            currentScenario.duration_ns = markedDurationNs;
            currentScenario.runtime_from_directive = true;
        } else {
            warnings.push(`Invalid runtime window in ${currentScenario.title}: end must be greater than begin.`);
        }
    } else if (!currentScenario.runtime_from_directive) {
        const measured = Math.max(0, Math.round(finalTimeNs - effectiveStartNs));
        if (measured > 0) {
            currentScenario.duration_ns = measured;
        }
    }

    if (!Number.isFinite(currentScenario.duration_ns) || currentScenario.duration_ns <= 0) {
        currentScenario.duration_ns = Math.max(1000, Math.round(clockPeriodNs * 10));
    } else {
        currentScenario.duration_ns = Math.round(currentScenario.duration_ns);
    }

    currentScenario.start_ns = Math.max(0, Math.round(currentScenario.start_ns));
    if (Number.isFinite(currentScenario.runtime_begin_ns)) {
        currentScenario.runtime_begin_ns = Math.max(0, Math.round(currentScenario.runtime_begin_ns));
    }
    if (Number.isFinite(currentScenario.runtime_end_ns)) {
        currentScenario.runtime_end_ns = Math.max(0, Math.round(currentScenario.runtime_end_ns));
    }
    delete currentScenario.case_anchor_ns;
    currentScenario.signals = unique(currentScenario.signals);
}

for (let lineNo = 0; lineNo < lines.length; lineNo += 1) {
    const rawLine = lines[lineNo];
    const codeLine = stripInlineComment(rawLine).trim();

    if (inTaskBlock) {
        if (/\bendtask\b/i.test(codeLine)) {
            inTaskBlock = false;
        }
        continue;
    }

    if (/^\s*task\b/i.test(codeLine)) {
        if (!/\bendtask\b/i.test(codeLine)) {
            inTaskBlock = true;
        }
        continue;
    }

    const waveSignals = parseWaveDirective(rawLine);
    const runtimeDirective = parseRuntimeDirective(rawLine);

    if (/\/\/\s*(?:CASE|TEST)\b/i.test(rawLine)) {
        caseHeaderPending = true;
    }

    if (waveSignals.length > 0) {
        if (caseHeaderPending || !currentScenario) {
            pendingWaveSignals.push(...waveSignals);
        } else {
            currentScenario.signals.push(...waveSignals);
        }
    }

    if (runtimeDirective) {
        if (runtimeDirective.type === 'marker') {
            const hasExpr = typeof runtimeDirective.expr === 'string' && runtimeDirective.expr.length > 0;
            const parsedOffsetNs = hasExpr
                ? parseRuntimeToNs(runtimeDirective.expr, paramMap, timescale.unitNs)
                : NaN;

            if (hasExpr && (!Number.isFinite(parsedOffsetNs) || parsedOffsetNs < 0)) {
                warnings.push(`Invalid @RUNTIME ${runtimeDirective.marker} offset at line ${lineNo + 1}: ${runtimeDirective.expr}`);
            } else if (runtimeDirective.marker === 'BEGIN') {
                if (caseHeaderPending || !currentScenario) {
                    if (hasExpr) {
                        pendingRuntimeBeginOffsetNs = parsedOffsetNs;
                        pendingRuntimeBeginNs = null;
                    } else {
                        pendingRuntimeBeginNs = currentTimeNs;
                        pendingRuntimeBeginOffsetNs = null;
                    }
                } else if (hasExpr) {
                    const anchorNs = getScenarioAnchorNs(currentScenario);
                    const beginNs = anchorNs + parsedOffsetNs;
                    currentScenario.runtime_begin_ns = beginNs;
                    currentScenario.start_ns = beginNs;
                } else {
                    currentScenario.runtime_begin_ns = currentTimeNs;
                    currentScenario.start_ns = currentTimeNs;
                }
            } else if (runtimeDirective.marker === 'END') {
                if (!currentScenario || caseHeaderPending) {
                    if (hasExpr) {
                        pendingRuntimeEndOffsetNs = parsedOffsetNs;
                    } else {
                        warnings.push(`@RUNTIME END without active CASE at line ${lineNo + 1}`);
                    }
                } else {
                    if (hasExpr) {
                        const anchorNs = getScenarioAnchorNs(currentScenario);
                        currentScenario.runtime_end_ns = anchorNs + parsedOffsetNs;
                    } else {
                        currentScenario.runtime_end_ns = currentTimeNs;
                    }

                    const markerStartNs = Number.isFinite(currentScenario.runtime_begin_ns)
                        ? currentScenario.runtime_begin_ns
                        : currentScenario.start_ns;
                    const markerDurationNs = Math.max(0, currentScenario.runtime_end_ns - markerStartNs);
                    if (markerDurationNs > 0) {
                        currentScenario.duration_ns = markerDurationNs;
                        currentScenario.runtime_from_directive = true;
                    }
                }
            }
        } else if (runtimeDirective.type === 'expr') {
            const parsedRuntimeNs = parseRuntimeToNs(runtimeDirective.expr, paramMap, timescale.unitNs);
            if (Number.isFinite(parsedRuntimeNs) && parsedRuntimeNs > 0) {
                if (caseHeaderPending || !currentScenario) {
                    pendingRuntimeNs = parsedRuntimeNs;
                } else {
                    currentScenario.duration_ns = parsedRuntimeNs;
                    currentScenario.runtime_from_directive = true;
                }
            } else {
                warnings.push(`Invalid @RUNTIME at line ${lineNo + 1}: ${runtimeDirective.expr}`);
            }
        }
    }

    currentTimeNs += estimateTimeAdvanceNs(codeLine, context);

    const testInfo = parseTestDirectiveLine(codeLine);
    if (testInfo) {
        finalizeCurrentScenario(currentTimeNs);

        const caseLabel = testInfo.caseToken && String(testInfo.caseToken).toUpperCase() !== 'N'
            ? String(testInfo.caseToken)
            : String(scenarioIndex);
        const title = `CASE ${caseLabel}: ${testInfo.title}`;
        const scenarioId = `case_${scenarioIndex}_${slugify(testInfo.title)}`;

        const scenario = {
            id: scenarioId,
            title,
            start_ns: Math.round(currentTimeNs),
            case_anchor_ns: Math.round(currentTimeNs),
            duration_ns: Math.round(clockPeriodNs * 20),
            sample_step_ns: 100,
            signals: unique([...baseSignals, ...pendingWaveSignals])
        };

        if (Number.isFinite(pendingRuntimeBeginOffsetNs)) {
            const beginNs = scenario.case_anchor_ns + pendingRuntimeBeginOffsetNs;
            scenario.start_ns = Math.round(beginNs);
            scenario.runtime_begin_ns = beginNs;
        } else if (Number.isFinite(pendingRuntimeBeginNs)) {
            scenario.start_ns = Math.round(pendingRuntimeBeginNs);
            scenario.runtime_begin_ns = pendingRuntimeBeginNs;
        }

        if (Number.isFinite(pendingRuntimeEndOffsetNs)) {
            const endNs = scenario.case_anchor_ns + pendingRuntimeEndOffsetNs;
            scenario.runtime_end_ns = endNs;
            if (Number.isFinite(scenario.start_ns)) {
                const durationNs = Math.max(0, endNs - scenario.start_ns);
                if (durationNs > 0) {
                    scenario.duration_ns = durationNs;
                    scenario.runtime_from_directive = true;
                }
            }
        }

        if (Number.isFinite(pendingRuntimeNs) && pendingRuntimeNs > 0) {
            scenario.duration_ns = pendingRuntimeNs;
            scenario.runtime_from_directive = true;
        }

        scenarios.push(scenario);
        currentScenario = scenario;

        scenarioIndex += 1;
        pendingWaveSignals = [];
        pendingRuntimeNs = null;
        pendingRuntimeBeginNs = null;
        pendingRuntimeBeginOffsetNs = null;
        pendingRuntimeEndOffsetNs = null;
        caseHeaderPending = false;
    }
}

finalizeCurrentScenario(currentTimeNs);

const scenarioEndNs = scenarios.reduce((maxEnd, s) => {
    const endNs = (s.start_ns || 0) + (s.duration_ns || 0);
    return Math.max(maxEnd, endNs);
}, 0);

const requiredEndNs = Math.max(Math.round(currentTimeNs), Math.round(scenarioEndNs));
const simDurationNs = Math.max(100000, Math.ceil(requiredEndNs * 1.1) + 100000);

const projectPath = path.dirname(path.dirname(tbFile));
const projectName = path.basename(projectPath);
const topModule = extractTopModuleName(tbContent, path.basename(tbFile, path.extname(tbFile)));

const config = {
    config: {
        project_name: projectName,
        top_module: topModule,
        sim_duration_ns: simDurationNs,
        vcd_file: 'output/mcp_sim_wave.vcd',
        html_file: `output/view_wave_${path.basename(tbFile, path.extname(tbFile))}.html`
    },
    scenarios
};

const jsonPath = path.join(projectPath, 'sim_config.json');
fs.writeFileSync(jsonPath, JSON.stringify(config, null, 4));

console.log(`Generated sim_config.json with ${scenarios.length} scenarios.`);
console.log(`Review it at: ${jsonPath}`);

if (warnings.length > 0) {
    console.warn('\n[WARNINGS]');
    warnings.forEach((w) => console.warn(`- ${w}`));
}
