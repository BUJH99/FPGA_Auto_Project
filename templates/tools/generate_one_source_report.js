const fs = require('fs');
const path = require('path');

function parseModuleList(value) {
    if (!value) return null;
    const list = value
        .split(',')
        .map(item => item.trim())
        .filter(Boolean);
    if (list.length === 0) return null;
    return Array.from(new Set(list));
}

let hdlIndexer = null;
try {
    hdlIndexer = require('./hdl_indexer.js');
} catch {
    hdlIndexer = null;
}

function parseCliArgs(argv) {
    let projectArg = null;
    let listModules = false;
    let moduleListRaw = null;

    argv.forEach(arg => {
        if (arg === '--list-modules') {
            listModules = true;
            return;
        }
        if (arg.startsWith('--modules=')) {
            moduleListRaw = arg.slice('--modules='.length);
            return;
        }
        if (!arg.startsWith('--') && !projectArg) {
            projectArg = arg;
            return;
        }
        throw new Error(`Unknown argument: ${arg}`);
    });

    return {
        projectRoot: projectArg ? path.resolve(projectArg) : process.cwd(),
        listModules,
        selectedModuleNames: parseModuleList(moduleListRaw)
    };
}

const cli = parseCliArgs(process.argv.slice(2));
const projectRoot = cli.projectRoot;
const srcDir = path.join(projectRoot, 'src');
const tbDir = path.join(projectRoot, 'tb');
const outputDir = path.join(projectRoot, 'output');
const docsDir = path.join(outputDir, 'docs');
const reportMdPath = path.join(docsDir, 'report.md');
const githubCssPath = path.join(docsDir, 'github.css');

const invalidInstantiationKeywords = new Set([
    'module', 'endmodule', 'input', 'output', 'inout', 'wire', 'reg', 'logic',
    'always', 'always_ff', 'always_comb', 'always_latch', 'initial', 'assign',
    'if', 'else', 'for', 'while', 'case', 'casex', 'casez', 'endcase', 'begin', 'end',
    'parameter', 'localparam', 'function', 'endfunction', 'task', 'endtask',
    'generate', 'endgenerate', 'genvar', 'typedef', 'enum', 'struct', 'union'
]);

function normalizeSlashes(p) {
    return p.replace(/\\/g, '/');
}

function relFromProject(absPath) {
    return normalizeSlashes(path.relative(projectRoot, absPath));
}

function ensureDir(dirPath) {
    if (!fs.existsSync(dirPath)) {
        fs.mkdirSync(dirPath, { recursive: true });
    }
}

function ensureGithubCss() {
    // Always rewrite CSS so report style updates are reflected immediately.
    const css = [
        'body {',
        '  font-family: "Malgun Gothic", "Apple SD Gothic Neo", "Noto Sans KR", Arial, sans-serif;',
        '  font-size: 10.5pt;',
        '  line-height: 1.65;',
        '  color: #1a1d23;',
        '  max-width: 1100px;',
        '  margin: 0 auto;',
        '  padding: 32px 40px;',
        '  background: #ffffff;',
        '}',
        '',
        '/* ── Headings ─────────────────────────────────── */',
        'h1 {',
        '  font-size: 22pt;',
        '  color: #1F3864;',
        '  font-weight: 800;',
        '  border-bottom: 3px solid #1F3864;',
        '  padding-bottom: 10px;',
        '  margin-top: 1.5em;',
        '  margin-bottom: 0.6em;',
        '  letter-spacing: -0.5px;',
        '}',
        'h2 {',
        '  font-size: 15pt;',
        '  color: #2E5599;',
        '  font-weight: 700;',
        '  border-left: 5px solid #2E5599;',
        '  padding-left: 12px;',
        '  margin-top: 2em;',
        '  margin-bottom: 0.5em;',
        '}',
        'h3 {',
        '  font-size: 12pt;',
        '  color: #2F5496;',
        '  font-weight: 700;',
        '  margin-top: 1.4em;',
        '  margin-bottom: 0.4em;',
        '  padding-bottom: 3px;',
        '  border-bottom: 1px solid #c8d8f0;',
        '}',
        'h4 {',
        '  font-size: 10.5pt;',
        '  color: #4472C4;',
        '  font-weight: 600;',
        '  margin-top: 1.1em;',
        '  margin-bottom: 0.3em;',
        '}',
        '',
        '/* ── Body text ────────────────────────────────── */',
        'p  { margin: 0.5em 0; }',
        'li { margin: 0.25em 0; }',
        'ul, ol { padding-left: 1.6em; }',
        '',
        '/* ── Cover page table ─────────────────────────── */',
        '.cover-table { width: 60%; margin: 30px auto; border-collapse: collapse; font-size: 11pt; }',
        '.cover-table td { padding: 10px 18px; border: 1px solid #c5d0e0; }',
        '.cover-table td:first-child { background: #EEF2F9; font-weight: 700; width: 36%; color: #2E5599; }',
        '',
        '/* ── Data tables ──────────────────────────────── */',
        'table {',
        '  border-collapse: collapse;',
        '  width: 100%;',
        '  margin: 12px 0 22px;',
        '  font-size: 10pt;',
        '}',
        'th {',
        '  background: #2E5599;',
        '  color: #ffffff;',
        '  font-weight: 700;',
        '  padding: 8px 12px;',
        '  border: 1px solid #1F3864;',
        '  text-align: left;',
        '}',
        'td {',
        '  border: 1px solid #d0d9e8;',
        '  padding: 6px 12px;',
        '  vertical-align: top;',
        '}',
        'tr:nth-child(even) td { background: #f5f7fc; }',
        '',
        '/* ── Code ─────────────────────────────────────── */',
        'code {',
        '  font-family: "D2Coding", "Consolas", "Courier New", monospace;',
        '  font-size: 9.5pt;',
        '  background: #F0F4FA;',
        '  color: #2C3E70;',
        '  padding: 2px 6px;',
        '  border-radius: 4px;',
        '  border: 1px solid #d0d9ea;',
        '}',
        'pre {',
        '  background: #1e2233;',
        '  color: #e0e8ff;',
        '  padding: 16px 20px;',
        '  border-radius: 6px;',
        '  overflow-x: auto;',
        '  font-size: 9pt;',
        '  line-height: 1.55;',
        '  margin: 12px 0 20px;',
        '  border-left: 4px solid #4472C4;',
        '}',
        'pre code {',
        '  background: transparent;',
        '  border: none;',
        '  padding: 0;',
        '  color: inherit;',
        '  font-size: inherit;',
        '}',
        '',
        '/* ── Blockquote callout box ────────────────────── */',
        'blockquote {',
        '  background: #EEF4FF;',
        '  border-left: 5px solid #4472C4;',
        '  margin: 14px 0;',
        '  padding: 10px 18px;',
        '  border-radius: 0 6px 6px 0;',
        '  color: #2C3E70;',
        '  font-size: 10pt;',
        '}',
        '',
        '/* ── HR divider ────────────────────────────────── */',
        'hr {',
        '  border: none;',
        '  border-top: 2px solid #d0daea;',
        '  margin: 28px 0;',
        '}',
        '',
        '/* ── Images ────────────────────────────────────── */',
        'img { max-width: 100%; height: auto; border-radius: 4px; box-shadow: 0 1px 4px rgba(0,0,0,0.12); }',
        '',
        '/* ── Print ─────────────────────────────────────── */',
        '@media print {',
        '  body { max-width: none; padding: 20px; }',
        '  h1, h2 { page-break-after: avoid; }',
        '  pre, blockquote { page-break-inside: avoid; }',
        '}',
        ''
    ].join('\n');
    fs.writeFileSync(githubCssPath, css, 'utf8');
}

function stripComments(content) {
    const noBlock = content.replace(/\/\*[\s\S]*?\*\//g, '');
    return noBlock.replace(/\/\/.*$/gm, '');
}

function parseInfoBlock(rawContent, startTag, endTag) {
    const re = new RegExp(`\\[${startTag}\\]([\\s\\S]*?)\\[${endTag}\\]`, 'i');
    const match = rawContent.match(re);
    if (!match) return null;

    const body = match[1];
    const lines = body.split(/\r?\n/);
    const info = {
        name: null,
        target: null,
        role: null,
        summary: [],
        stateDescription: [],
        scenario: [],
        checkPoint: []
    };

    let currentSection = null;
    const pushToSection = (sectionName, text) => {
        if (!text) return;
        if (!Object.prototype.hasOwnProperty.call(info, sectionName)) return;
        info[sectionName].push(text);
    };

    lines.forEach(rawLine => {
        const line = rawLine.trim();
        if (!line) return;

        let m = line.match(/^Name\s*:\s*(.+)$/i);
        if (m) {
            info.name = m[1].trim();
            currentSection = null;
            return;
        }
        m = line.match(/^Target\s*:\s*(.+)$/i);
        if (m) {
            info.target = m[1].trim();
            currentSection = null;
            return;
        }
        m = line.match(/^Role\s*:\s*(.+)$/i);
        if (m) {
            info.role = m[1].trim();
            currentSection = null;
            return;
        }

        m = line.match(/^Summary\s*:\s*(.*)$/i);
        if (m) {
            currentSection = 'summary';
            pushToSection(currentSection, m[1].trim());
            return;
        }
        m = line.match(/^StateDescription\s*:\s*(.*)$/i);
        if (m) {
            currentSection = 'stateDescription';
            pushToSection(currentSection, m[1].trim());
            return;
        }
        m = line.match(/^Scenario\s*:\s*(.*)$/i);
        if (m) {
            currentSection = 'scenario';
            pushToSection(currentSection, m[1].trim());
            return;
        }
        m = line.match(/^CheckPoint\s*:\s*(.*)$/i);
        if (m) {
            currentSection = 'checkPoint';
            pushToSection(currentSection, m[1].trim());
            return;
        }

        const bullet = line.match(/^[-*]\s+(.+)$/);
        if (bullet && currentSection) {
            pushToSection(currentSection, bullet[1].trim());
            return;
        }

        if (currentSection) {
            pushToSection(currentSection, line);
        }
    });

    // Cleanup empty strings and duplicates while preserving order.
    ['summary', 'stateDescription', 'scenario', 'checkPoint'].forEach(section => {
        const dedup = [];
        const seen = new Set();
        info[section]
            .map(s => s.trim())
            .filter(Boolean)
            .forEach(s => {
                const key = s.toLowerCase();
                if (seen.has(key)) return;
                seen.add(key);
                dedup.push(s);
            });
        info[section] = dedup;
    });

    return info;
}

function parseModuleInfo(rawContent, fallbackName) {
    const parsed = parseInfoBlock(rawContent, 'MODULE_INFO_START', 'MODULE_INFO_END');
    if (!parsed) {
        return {
            name: fallbackName,
            role: null,
            summary: [],
            stateDescription: []
        };
    }
    return {
        name: parsed.name || fallbackName,
        role: parsed.role || null,
        summary: parsed.summary || [],
        stateDescription: parsed.stateDescription || []
    };
}

function parseTbInfo(rawContent, fallbackName) {
    const parsed = parseInfoBlock(rawContent, 'TB_INFO_START', 'TB_INFO_END');
    if (!parsed) {
        return {
            name: fallbackName,
            target: null,
            role: null,
            scenario: [],
            checkPoint: []
        };
    }
    return {
        name: parsed.name || fallbackName,
        target: parsed.target || null,
        role: parsed.role || null,
        scenario: parsed.scenario || [],
        checkPoint: parsed.checkPoint || []
    };
}

function escapeRegex(value) {
    return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function readVerilogModules() {
    if (!fs.existsSync(srcDir)) {
        throw new Error(`src directory not found: ${srcDir}`);
    }

    const files = fs
        .readdirSync(srcDir)
        .filter(name => /\.(v|sv)$/i.test(name))
        .sort((a, b) => a.localeCompare(b));

    const modules = files.map(fileName => {
        const absPath = path.join(srcDir, fileName);
        const raw = fs.readFileSync(absPath, 'utf8');
        const clean = stripComments(raw);
        const moduleMatch = clean.match(/\bmodule\s+(?:(?:automatic|static)\s+)?([A-Za-z_]\w*)\b/i);
        const moduleName = moduleMatch ? moduleMatch[1] : path.basename(fileName, path.extname(fileName));

        return {
            moduleName,
            fileName,
            absPath,
            relPath: relFromProject(absPath),
            raw,
            clean,
            ports: [],
            children: [],
            fsmDetected: false,
            moduleInfo: parseModuleInfo(raw, moduleName)
        };
    });

    return modules;
}

function buildSubBlockModules(allModules, selectedModuleNames, topModuleName) {
    const moduleByLower = new Map(
        allModules.map(mod => [mod.moduleName.toLowerCase(), mod])
    );
    const unknown = [];
    let modules = [];

    if (!Array.isArray(selectedModuleNames) || selectedModuleNames.length === 0) {
        modules = allModules.slice();
    } else {
        selectedModuleNames.forEach(name => {
            const key = String(name).trim().toLowerCase();
            if (!key) return;
            const found = moduleByLower.get(key);
            if (found) {
                modules.push(found);
            } else {
                unknown.push(name);
            }
        });
    }

    if (topModuleName) {
        const topKey = String(topModuleName).trim().toLowerCase();
        const topModule = moduleByLower.get(topKey);
        if (topModule) {
            modules = modules.filter(mod => mod.moduleName.toLowerCase() !== topKey);
            modules.unshift(topModule);
        }
    }

    const dedup = [];
    const seen = new Set();
    modules.forEach(mod => {
        const key = mod.moduleName.toLowerCase();
        if (seen.has(key)) return;
        seen.add(key);
        dedup.push(mod);
    });

    return { modules: dedup, unknown };
}

function parsePorts(moduleInfo) {
    const escapedModule = escapeRegex(moduleInfo.moduleName);
    const headerRegex = new RegExp(
        `\\bmodule\\s+${escapedModule}\\b\\s*(?:#\\s*\\([\\s\\S]*?\\)\\s*)?\\(([\\s\\S]*?)\\)\\s*;`,
        'm'
    );
    const headerMatch = moduleInfo.clean.match(headerRegex);
    const header = headerMatch ? headerMatch[1] : '';

    const ports = [];
    const seen = new Set();

    const lines = header.split(/\r?\n/);
    let currentDir = null;
    let currentType = 'wire';
    let currentWidth = '1';

    lines.forEach(lineRaw => {
        const line = lineRaw.trim();
        if (!line) return;

        let working = line.replace(/[()]/g, '').replace(/,$/, '').trim();
        if (!working) return;

        const dirMatch = working.match(/^(input|output|inout)\b/i);
        if (dirMatch) {
            currentDir = dirMatch[1].toLowerCase();
            currentType = 'wire';
            currentWidth = '1';
            working = working.slice(dirMatch[0].length).trim();
        } else if (!currentDir) {
            return;
        }

        const typeMatch = working.match(/^(wire|reg|logic)\b/i);
        if (typeMatch) {
            currentType = typeMatch[1].toLowerCase();
            currentWidth = '1';
            working = working.slice(typeMatch[0].length).trim();
        }

        working = working.replace(/^(signed|unsigned)\b/i, '').trim();

        const widthMatch = working.match(/^(\[[^\]]+\])/);
        if (widthMatch) {
            currentWidth = widthMatch[1].trim();
            working = working.slice(widthMatch[0].length).trim();
        }

        const names = working
            .split(',')
            .map(token => token.split('=')[0].trim().replace(/[);]+$/g, ''))
            .filter(Boolean);

        names.forEach(name => {
            if (seen.has(name)) return;
            seen.add(name);
            ports.push({
                name,
                direction: currentDir,
                type: currentType,
                width: currentWidth || '1'
            });
        });
    });

    moduleInfo.ports = ports;
}

function detectFsm(moduleInfo) {
    const content = moduleInfo.clean;
    const hasStateCase = /\bcase\s*\(\s*[A-Za-z_]\w*(?:state|cur)[A-Za-z_0-9]*\s*\)/i.test(content);
    const hasStateDecl = /\b(localparam|parameter)\b[\s\S]{0,260}\b[A-Za-z_]\w*(?:state|idle|init|run|wait|done)\w*\s*=/i.test(content);
    const hasNextStateAssign = /\b[A-Za-z_]\w*(?:next|nxt|_d)\w*\s*(?:<=|=)\s*[A-Za-z_]\w+/i.test(content);
    const hasAlways = /\balways\s*@|\balways_comb\b|\balways_ff\b/i.test(content);
    moduleInfo.fsmDetected = (hasAlways && hasStateCase) || (hasStateDecl && hasNextStateAssign);
}

function detectHierarchy(modules) {
    const knownModules = new Set(modules.map(m => m.moduleName));
    const moduleMap = new Map(modules.map(m => [m.moduleName, m]));

    modules.forEach(mod => {
        const children = [];
        const seen = new Set();
        const instRegex = /(^|\n)\s*([A-Za-z_]\w*)\s*(?:#\s*\([\s\S]*?\)\s*)?([A-Za-z_]\w*)\s*\(/g;
        let match;
        while ((match = instRegex.exec(mod.clean)) !== null) {
            const typeName = match[2];
            const instName = match[3];
            if (!knownModules.has(typeName)) continue;
            if (invalidInstantiationKeywords.has(typeName.toLowerCase())) continue;
            if (typeName === mod.moduleName) continue;

            const key = `${typeName}:${instName}`;
            if (seen.has(key)) continue;
            seen.add(key);
            children.push({ moduleName: typeName, instanceName: instName });
        }
        mod.children = children;
    });

    const instantiated = new Set();
    modules.forEach(mod => mod.children.forEach(ch => instantiated.add(ch.moduleName)));

    const rootCandidates = modules
        .map(m => m.moduleName)
        .filter(name => !instantiated.has(name))
        .sort((a, b) => a.localeCompare(b));

    const topModule = moduleMap.has('Top')
        ? 'Top'
        : (rootCandidates[0] || (modules[0] ? modules[0].moduleName : null));

    return { moduleMap, topModule, rootCandidates };
}

function findFirstExisting(paths) {
    for (const p of paths) {
        if (!p) continue;
        if (typeof p !== 'string') continue;
        if (fs.existsSync(p)) return p;
    }
    return null;
}

function findCaseInsensitiveInDir(dirPath, candidateNames) {
    if (!fs.existsSync(dirPath)) return null;
    const entries = fs.readdirSync(dirPath);
    const lowerMap = new Map(entries.map(name => [name.toLowerCase(), name]));

    for (const candidate of candidateNames) {
        const directPath = path.join(dirPath, candidate);
        if (fs.existsSync(directPath)) return directPath;

        const mapped = lowerMap.get(candidate.toLowerCase());
        if (mapped) return path.join(dirPath, mapped);
    }
    return null;
}

function findCaseInsensitiveDir(rootDir, dirName) {
    if (!fs.existsSync(rootDir)) return null;
    const entries = fs.readdirSync(rootDir, { withFileTypes: true });
    const hit = entries.find(entry => entry.isDirectory() && entry.name.toLowerCase() === dirName.toLowerCase());
    return hit ? path.join(rootDir, hit.name) : null;
}

function collectAssets(moduleName) {
    const simpleRootDir = path.join(outputDir, 'Diagram', 'Simple');
    const detailedRootDir = path.join(outputDir, 'Diagram', 'Detailed');
    const fsmRootDir = path.join(outputDir, 'fsm');

    const simpleModuleDir = findCaseInsensitiveDir(simpleRootDir, moduleName) || path.join(simpleRootDir, moduleName);
    const detailedModuleDir = findCaseInsensitiveDir(detailedRootDir, moduleName) || path.join(detailedRootDir, moduleName);
    const fsmModuleDir = findCaseInsensitiveDir(fsmRootDir, moduleName) || path.join(fsmRootDir, moduleName);

    const oldSimpleDir = simpleRootDir;
    const oldDetailedDir = detailedRootDir;
    const oldFsmSvgDir = path.join(outputDir, 'fsm', 'svg');
    const oldFsmDrawioDir = path.join(outputDir, 'fsm', 'drawio');
    const oldPngDir = path.join(outputDir, 'Diagram', 'png');

    const simple = findFirstExisting([
        findCaseInsensitiveInDir(simpleModuleDir, [
            `${moduleName}.png`,
            `${moduleName}.svg`,
            `${moduleName}.drawio`
        ]),
        findCaseInsensitiveInDir(oldSimpleDir, [
            `${moduleName}.png`,
            `${moduleName}.svg`,
            `${moduleName}.drawio`
        ]),
        findCaseInsensitiveInDir(oldPngDir, [
            `${moduleName}.png`,
            `${moduleName}_simple.png`
        ])
    ]);

    const detailed = findFirstExisting([
        findCaseInsensitiveInDir(detailedModuleDir, [
            `${moduleName}.png`,
            `${moduleName}.svg`,
            `${moduleName}.drawio`
        ]),
        findCaseInsensitiveInDir(oldDetailedDir, [
            `${moduleName}.png`,
            `${moduleName}.svg`,
            `${moduleName}.drawio`,
            `${moduleName}_detailed.svg`,
            `${moduleName}_detailed.drawio`
        ]),
        findCaseInsensitiveInDir(oldPngDir, [
            `${moduleName}_detailed.png`
        ])
    ]);

    const fsm = findFirstExisting([
        findCaseInsensitiveInDir(fsmModuleDir, [
            `${moduleName}_fsm.png`,
            `${moduleName}_fsm.svg`,
            `${moduleName}_fsm.drawio`
        ]),
        findCaseInsensitiveInDir(oldFsmSvgDir, [`${moduleName}_fsm.svg`]),
        findCaseInsensitiveInDir(oldFsmDrawioDir, [`${moduleName}_fsm.drawio`]),
        findCaseInsensitiveInDir(oldPngDir, [`${moduleName}_fsm.png`])
    ]);

    return {
        simple,
        detailed,
        fsm,
        hasFsmAsset: Boolean(fsm)
    };
}

function collectWaveformPaths(moduleName) {
    const waveformRootDir = path.join(projectRoot, 'waveform');
    const waveformModuleDir = findCaseInsensitiveDir(waveformRootDir, moduleName) || path.join(waveformRootDir, moduleName);

    let matchedTbFile = null;
    if (fs.existsSync(tbDir)) {
        const expectedBase = `tb_${moduleName}`.toLowerCase();
        const tbFiles = fs
            .readdirSync(tbDir)
            .filter(name => /\.(v|sv)$/i.test(name));
        matchedTbFile = tbFiles.find(name => path.basename(name, path.extname(name)).toLowerCase() === expectedBase) || null;
    }

    const tbBaseName = matchedTbFile
        ? path.basename(matchedTbFile, path.extname(matchedTbFile))
        : `tb_${moduleName}`;
    const expectedTb = matchedTbFile ? path.join(tbDir, matchedTbFile) : null;

    const candidates = [
        path.join(outputDir, `${moduleName}.vcd`),
        path.join(outputDir, `${tbBaseName}.vcd`),
        path.join(outputDir, `${tbBaseName}.gtkw`),
        path.join(outputDir, `${tbBaseName}.sim.log`),
        path.join(tbDir, `${tbBaseName}.out`),
        path.join(tbDir, `.run_${tbBaseName}.out`),
        path.join(outputDir, 'FINALReport', 'wavedrom_cases.json')
    ];

    const existing = candidates.filter(p => fs.existsSync(p)).map(relFromProject);
    const expected = (expectedTb && fs.existsSync(expectedTb))
        ? [
            relFromProject(expectedTb),
            normalizeSlashes(path.join('output', `${tbBaseName}.vcd`)),
            normalizeSlashes(path.join('output', `${tbBaseName}.gtkw`))
        ]
        : [];

    const imagePaths = fs.existsSync(waveformModuleDir)
        ? fs
            .readdirSync(waveformModuleDir, { withFileTypes: true })
            .filter(entry => entry.isFile() && /\.(png|jpg|jpeg|gif|webp|svg)$/i.test(entry.name))
            .map(entry => path.join(waveformModuleDir, entry.name))
            .sort((a, b) => a.localeCompare(b))
            .map(relFromProject)
        : [];

    return {
        existing,
        imagePaths,
        expected,
        tbSource: expectedTb && fs.existsSync(expectedTb) ? relFromProject(expectedTb) : null,
        tbName: tbBaseName
    };
}

const tbInfoCache = new Map();

function getTbInfoFromRelPath(tbRelPath) {
    if (!tbRelPath) return null;
    if (tbInfoCache.has(tbRelPath)) return tbInfoCache.get(tbRelPath);

    const absPath = path.join(projectRoot, tbRelPath);
    if (!fs.existsSync(absPath)) {
        tbInfoCache.set(tbRelPath, null);
        return null;
    }

    const raw = fs.readFileSync(absPath, 'utf8');
    const fallbackName = path.basename(absPath, path.extname(absPath));
    const info = parseTbInfo(raw, fallbackName);
    tbInfoCache.set(tbRelPath, info);
    return info;
}

function formatPortTable(ports) {
    if (!ports || ports.length === 0) {
        return [
            '| Name | Direction | Width | Description |',
            '|------|-----------|-------|-------------|',
            '| - | - | - | - |',
            ''
        ].join('\n');
    }

    const lines = [
        '| Name | Direction | Width | Description |',
        '|------|-----------|-------|-------------|'
    ];
    ports.forEach(p => {
        const direction = p.direction === 'input'
            ? 'Input'
            : (p.direction === 'output' ? 'Output' : 'Inout');
        const width = p.width && p.width !== '1' ? `${p.width}-bit` : '1-bit';
        lines.push(`| \`${p.name}\` | ${direction} | ${width} | - |`);
    });
    lines.push('');
    return lines.join('\n');
}

function buildDirectoryTreeSnippet() {
    const names = ['src', 'tb', 'constrs', 'ip', 'output', 'waveform', 'Presentation'];
    const present = names.filter(name => fs.existsSync(path.join(projectRoot, name)));
    if (present.length === 0) {
        return [
            'Project/',
            '└── src/'
        ].join('\n');
    }

    const lines = ['Project/'];
    present.forEach((name, index) => {
        const isLast = index === present.length - 1;
        lines.push(`${isLast ? '└──' : '├──'} ${name}/`);
    });
    return lines.join('\n');
}

function collectConstraintFiles() {
    const constrDir = path.join(projectRoot, 'constrs');
    if (!fs.existsSync(constrDir)) return [];
    return fs
        .readdirSync(constrDir, { withFileTypes: true })
        .filter(entry => entry.isFile() && /\.(xdc|sdc)$/i.test(entry.name))
        .map(entry => path.join(constrDir, entry.name))
        .sort((a, b) => a.localeCompare(b));
}

function buildHierarchyTree(topModule, moduleMap) {
    if (!topModule) return '`(module not found)`';
    const lines = [];
    const visit = (name, depth, stack) => {
        lines.push(`${'  '.repeat(depth)}- ${name}`);
        const mod = moduleMap.get(name);
        if (!mod) return;
        const children = mod.children
            .map(ch => ch.moduleName)
            .sort((a, b) => a.localeCompare(b));
        children.forEach(child => {
            if (stack.has(child)) {
                lines.push(`${'  '.repeat(depth + 1)}- ${child} (recursive)`);
                return;
            }
            const nextStack = new Set(stack);
            nextStack.add(child);
            visit(child, depth + 1, nextStack);
        });
    };
    visit(topModule, 0, new Set([topModule]));
    return lines.join('\n');
}

function pushVisualLine(lines, label, assetPath, missingHint, altText) {
    if (!assetPath) {
        lines.push(`- ${label}: (미생성) \`${missingHint}\``);
        return;
    }

    const rel = relFromProject(assetPath);
    const lower = rel.toLowerCase();
    if (
        lower.endsWith('.svg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif')
    ) {
        lines.push(`- ${label}: ![${altText}](${rel})`);
        return;
    }
    lines.push(`- ${label}: [${path.basename(rel)}](${rel})`);
}

function buildModuleDescriptionKR(mod, wave, hasFsm, isTopModule, tbInfo) {
    const info = mod.moduleInfo || {};
    const description = [];
    const childCount = mod.children.length;
    const childText = childCount > 0
        ? `${childCount}개의 하위 모듈을 연결하여 기능을 구성합니다.`
        : '리프(leaf) 계층으로 동작하며 단일 기능 블록에 가깝습니다.';

    if (info.role) {
        description.push(info.role);
    } else {
        description.push(`\`${mod.moduleName}\` 모듈은 ${isTopModule ? '시스템 통합을 담당하는 최상위 모듈' : '서브 기능을 담당하는 하위 모듈'}입니다.`);
    }
    description.push(childText);

    if (Array.isArray(info.summary) && info.summary.length > 0) {
        description.push(`요약: ${info.summary.join(' / ')}`);
    }

    if (hasFsm) {
        description.push('상태 기반 제어 패턴(FSM)이 감지되며, 상태 전이 흐름은 FSM 다이어그램과 함께 검토할 수 있습니다.');
        if (Array.isArray(info.stateDescription) && info.stateDescription.length > 0) {
            description.push(`상태 설명: ${info.stateDescription.join(' / ')}`);
        }
    } else {
        description.push('코드 패턴 기준으로 명시적 FSM 특징이 강하지 않아 조합/순차 로직 중심 블록으로 해석할 수 있습니다.');
    }

    if (wave.tbSource) {
        if (tbInfo && tbInfo.role) {
            description.push(`테스트벤치 요약: ${tbInfo.role}`);
        } else {
            description.push(`검증 관점에서는 \`${wave.tbSource}\` 테스트벤치를 기준으로 파형 및 로그를 함께 확인하는 것을 권장합니다.`);
        }
    } else {
        description.push(`현재 \`tb/tb_${mod.moduleName}.(v|sv)\` 규칙의 테스트벤치가 자동 매칭되지 않아, 수동 테스트벤치 연결 여부를 확인해야 합니다.`);
    }

    if (isTopModule) {
        description.push('Top 모듈은 본 보고서에서 유일하게 상세(Detail) 다이어그램을 포함하며, 나머지 모듈은 Simple/FSM 중심으로 정리합니다.');
    }

    return description.join('\n\n');
}

function buildMarkdown(allModules, subBlockModules, hierarchy) {
    const projectName = path.basename(projectRoot);
    const today = new Date().toLocaleDateString('ko-KR', { year: 'numeric', month: 'long', day: 'numeric' });
    const generatedAt = new Date().toISOString();
    const generatedAtKo = new Date().toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' });

    const uniqueModuleNames = Array.from(new Set(allModules.map(m => m.moduleName))).sort();
    
    const topModuleName = hierarchy.topModule;
    const topModuleObj = allModules.find(m => m.moduleName === topModuleName);
    const topClocks = topModuleObj 
        ? topModuleObj.ports.filter(p => /clk|clock/i.test(p.name)).map(p => p.name) 
        : [];
    const topResets = topModuleObj 
        ? topModuleObj.ports.filter(p => /rst|reset/i.test(p.name)).map(p => p.name) 
        : [];
    
    const topAssets = topModuleName ? collectAssets(topModuleName) : null;
    const tree = hierarchy.moduleMap ? buildHierarchyTree(topModuleName, hierarchy.moduleMap) : '(No Hierarchy Map)';
    const constraintFiles = collectConstraintFiles();

    const lines = [];

    // ── Cover Page ─────────────────────────────────────────────────
    lines.push(`# 📋 ${projectName} 설계 결과 보고서`);
    lines.push('');
    lines.push('---');
    lines.push('');
    lines.push('| 항목 | 내용 |');
    lines.push('| :--- | :--- |');
    lines.push('| **과목명** | 디지털 시스템 설계 |');
    lines.push(`| **프로젝트명** | **${projectName}** |`);
    lines.push(`| **최상위 모듈** | \`${hierarchy.topModule || '-'}\` |`);
    lines.push(`| **제출일** | ${today} |`);
    lines.push(`| **생성 시각** | ${generatedAtKo} |`);
    lines.push(`| **전체 모듈 수** | ${uniqueModuleNames.length}개 |`);
    lines.push('');
    lines.push('---');
    lines.push('');

    // ── TOC ────────────────────────────────────────────────────────
    lines.push('## 📑 목차 (Table of Contents)');
    lines.push('');
    lines.push('1. [개요 (Introduction)](#1-개요-introduction)');
    lines.push('   - [1.1 설계 목적 및 배경](#11-설계-목적-및-배경)');
    lines.push('   - [1.2 주요 기능 명세](#12-주요-기능-명세-specifications)');
    lines.push('   - [1.3 설계 환경](#13-설계-환경-design-environment)');
    lines.push('   - [1.4 시스템 데이터시트](#14-시스템-데이터시트-system-data-sheet)');
    lines.push('   - [1.5 프로젝트 디렉토리 구조](#15-프로젝트-디렉토리-구조-directory-structure)');
    lines.push('2. [전체 시스템 구조 (System Architecture)](#2-전체-시스템-구조-system-architecture)');
    lines.push('   - [2.1 최상위 블록도](#21-최상위-블록도-top-level-block-diagram)');
    lines.push('   - [2.2 계층 구조](#22-계층-구조-hierarchy)');
    lines.push('   - [2.3 클럭 및 리셋 아키텍처](#23-클럭-및-리셋-아키텍처-clock--reset-strategy)');
    lines.push('   - [2.4 전체 신호 흐름](#24-전체-신호-흐름-및-인터럽트-구조)');
    lines.push('   - [2.5 통합 레지스터 맵](#25-통합-레지스터-맵-global-register-map)');
    lines.push('3. [상세 모듈 설계 (Detailed Module Design)](#3-상세-모듈-설계-detailed-module-design)');
    lines.push('4. [검증 및 시뮬레이션 (Verification)](#4-검증-및-시뮬레이션-verification)');
    lines.push('5. [구현 및 합성 결과 (Implementation & Synthesis)](#5-구현-및-합성-결과-implementation--synthesis)');
    lines.push('6. [결론 및 고찰 (Conclusion)](#6-결론-및-고찰-conclusion)');
    lines.push('7. [부록 (Appendix)](#7-부록-appendix)');
    lines.push('');
    lines.push('---');
    lines.push('');

    // ── Section 1. 개요 ─────────────────────────────────────────────
    lines.push('## 1. 개요 (Introduction)');
    lines.push('');
    lines.push('### 1.1 설계 목적 및 배경');
    lines.push('');
    lines.push(`본 보고서는 **${projectName}** 프로젝트의 RTL 설계 결과를 자동 생성한 문서입니다.`);
    lines.push('소스 코드, 다이어그램, 시뮬레이션 결과를 토대로 설계의 구조 및 검증 상태를 체계적으로 정리합니다.');
    lines.push('');
    lines.push('> 💡 이 보고서는 자동 생성된 초안입니다. 각 섹션의 **수동 보완 필요** 항목을 직접 작성하여 완성도를 높이세요.');
    lines.push('');

    lines.push('### 1.2 주요 기능 명세 (Specifications)');
    lines.push('');
    lines.push('| 항목 | 값 |');
    lines.push('| :--- | :--- |');
    lines.push(`| 최상위 모듈 | \`${hierarchy.topModule || '-'}\` |`);
    lines.push(`| 전체 고유 모듈 수 | ${uniqueModuleNames.length}개 |`);
    if (allModules.length !== uniqueModuleNames.length) {
        lines.push(`| 스캔된 모듈 정의 수 (중복 포함) | ${allModules.length}개 |`);
    }
    lines.push(`| 상세 설계 기술 대상 | ${subBlockModules.length}개 (Top 포함) |`);
    lines.push('');
    lines.push('**모듈 목록:**');
    lines.push('');
    uniqueModuleNames.forEach(name => lines.push(`- \`${name}\``));
    lines.push('');

    lines.push('### 1.3 설계 환경 (Design Environment)');
    lines.push('');
    lines.push('| 항목 | 내용 |');
    lines.push('| :--- | :--- |');
    lines.push('| OS | Windows 10/11 |');
    lines.push('| 언어 | Verilog-2001 / SystemVerilog |');
    lines.push('| 합성 도구 | Xilinx Vivado |');
    lines.push('| 타깃 디바이스 | Basys3 (XC7A35T) / 프로젝트별 상이 |');
    lines.push('| 시뮬레이터 | Vivado Simulator / ModelSim |');
    lines.push('| 문서 생성 | Node.js + Pandoc + PowerShell |');
    lines.push('');

    lines.push('### 1.4 시스템 데이터시트 (System Data Sheet)');
    lines.push('');
    lines.push('**핵심 인터페이스 (Top 모듈 기준)**');
    lines.push('');
    lines.push('| 신호 종류 | 포트명 |');
    lines.push('| :--- | :--- |');
    lines.push(`| 🕐 Clock | ${topClocks.length > 0 ? topClocks.map(c => `\`${c}\``).join(', ') : '미검출'} |`);
    lines.push(`| 🔁 Reset | ${topResets.length > 0 ? topResets.map(r => `\`${r}\``).join(', ') : '미검출'} |`);
    lines.push('');
    lines.push('> ⚠️ **수동 보완 필요:** 동작 주파수, 전원 전압, I/O 전기적 특성은 타깃 디바이스 데이터시트 기준으로 직접 보완하세요.');
    lines.push('');

    lines.push('### 1.5 프로젝트 디렉토리 구조 (Directory Structure)');
    lines.push('');
    lines.push('```text');
    lines.push(buildDirectoryTreeSnippet());
    lines.push('```');
    lines.push('');

    lines.push('## 2. 전체 시스템 구조 (System Architecture)');
    lines.push('');

    lines.push('---');
    lines.push('');
    lines.push('## 2. 전체 시스템 구조 (System Architecture)');
    lines.push('');
    lines.push('### 2.1 최상위 블록도 (Top-level Block Diagram)');
    lines.push('');
    if (topAssets) {
        pushVisualLine(
            lines,
            'Top Detailed',
            topAssets.detailed,
            `output/Diagram/Detailed/${hierarchy.topModule}/${hierarchy.topModule}_detailed.svg`,
            `${hierarchy.topModule} detailed`
        );
        pushVisualLine(
            lines,
            'Top Simple',
            topAssets.simple,
            `output/Diagram/Simple/${hierarchy.topModule}/${hierarchy.topModule}.svg`,
            `${hierarchy.topModule} simple`
        );
    } else {
        lines.push('> ⚠️ Top 다이어그램 자산을 찾지 못했습니다. `code_schematic_draw.bat`를 먼저 실행하세요.');
    }
    lines.push('');
    lines.push('### 2.2 계층 구조 (Hierarchy)');
    lines.push('');
    lines.push('```text');
    lines.push(tree);
    lines.push('```');
    lines.push('');
    lines.push('### 2.3 클럭 및 리셋 아키텍처 (Clock & Reset Strategy)');
    lines.push('');
    lines.push('| 구분 | 신호명 | 비고 |');
    lines.push('| :--- | :--- | :--- |');
    if (topClocks.length > 0) {
        topClocks.forEach(c => lines.push(`| 🕐 Clock | \`${c}\` | Top 포트 기준 자동 검출 |`));
    } else {
        lines.push('| 🕐 Clock | *(미검출)* | source 내 `iClk` 규칙 확인 필요 |');
    }
    if (topResets.length > 0) {
        topResets.forEach(r => lines.push(`| 🔁 Reset | \`${r}\` | sync/async 여부는 always 블록 검토 |`));
    } else {
        lines.push('| 🔁 Reset | *(미검출)* | `iRst`/`iRstn` 규칙 확인 필요 |');
    }
    lines.push('');
    lines.push('### 2.4 전체 신호 흐름 및 인터럽트 구조');
    lines.push('');
    lines.push('상위 모듈에서 하위 모듈로 제어/데이터 신호가 전달되는 정적 계층 구조 기반으로 동작합니다.');
    lines.push('');
    lines.push('> ⚠️ **수동 보완 필요:** 인터럽트/예외 처리 신호는 모듈별 RTL 구현 기준으로 보완하세요.');
    lines.push('');
    lines.push('### 2.5 통합 레지스터 맵 (Global Register Map)');
    lines.push('');
    lines.push('| Offset | 이름 | Direction | Reset Value | 설명 |');
    lines.push('| :--- | :--- | :--- | :--- | :--- |');
    lines.push('| - | - | - | - | SW 접근 레지스터를 수동으로 채워주세요 |');
    lines.push('');

    lines.push('---');
    lines.push('');
    lines.push('## 3. 상세 모듈 설계 (Detailed Module Design)');
    lines.push('');
    lines.push('### 3.1 공통 설계 원칙 (Design Methodology)');
    lines.push('');
    lines.push('| 원칙 | 내용 |');
    lines.push('| :--- | :--- |');
    lines.push('| Naming | `iXxx` (입력) / `oXxx` (출력) / `w` (내부 wire) / `state` (FSM 상태) |');
    lines.push('| FSM 방식 | Moore FSM 권장 (출력이 현재 상태에만 의존) |');
    lines.push('| 리셋 | Active-Low Async Reset (`iRstn`) 기준 |');
    lines.push('| 로직 분리 | 조합(always @(*)) / 순차(always @(posedge)) 블록 분리 |');
    lines.push('');

    subBlockModules.forEach((mod, index) => {
        const assets = collectAssets(mod.moduleName);
        const wave = collectWaveformPaths(mod.moduleName);
        const tbInfo = getTbInfoFromRelPath(wave.tbSource);
        const modInfo = mod.moduleInfo || { summary: [], stateDescription: [] };
        const sectionNo = index + 1;
        const hasFsmAsset = Boolean(assets.fsm);
        const isTopModule = hierarchy.topModule && mod.moduleName.toLowerCase() === hierarchy.topModule.toLowerCase();

        lines.push(`---`);
        lines.push('');
        lines.push(`### 3.2.${sectionNo} \`${mod.moduleName}\` 모듈 설계`);
        lines.push('');

        // ─ 기능 개요 테이블
        lines.push('#### a. 기능 개요');
        lines.push('');
        lines.push('| 항목 | 내용 |');
        lines.push('| :--- | :--- |');
        lines.push(`| 소스 파일 | \`${mod.relPath}\` |`);
        lines.push(`| 하위 모듈 | ${mod.children.length > 0 ? mod.children.map(ch => `\`${ch.moduleName}\``).join(', ') : '-'} |`);
        lines.push(`| FSM 포함 | ${mod.fsmDetected ? '✅ 감지됨' : '❌ 미검출'} |`);
        lines.push(`| 역할 | ${modInfo.role || '수동 보완 필요'} |`);
        lines.push('');
        if (Array.isArray(modInfo.summary) && modInfo.summary.length > 0) {
            lines.push('**기능 요약:**');
            lines.push('');
            modInfo.summary.forEach(item => lines.push(`- ${item}`));
            lines.push('');
        } else {
            lines.push(`> ⚠️ \`${mod.moduleName}\` 모듈의 세부 기능 설명을 수동으로 보완하세요.`);
            lines.push('');
        }

        // ─ 블록도
        lines.push('#### b. 모듈 블록도 (Module Block Diagram)');
        lines.push('');
        pushVisualLine(
            lines,
            'Simple Diagram',
            assets.simple,
            `output/Diagram/Simple/${mod.moduleName}/${mod.moduleName}.svg`,
            `${mod.moduleName} simple`
        );
        if (isTopModule) {
            pushVisualLine(
                lines,
                'Detailed Diagram',
                assets.detailed,
                `output/Diagram/Detailed/${mod.moduleName}/${mod.moduleName}_detailed.svg`,
                `${mod.moduleName} detailed`
            );
        }
        lines.push('');

        // ─ 포트 테이블
        lines.push('#### c. 입출력 포트 정의 (I/O Port Table)');
        lines.push('');
        lines.push(formatPortTable(mod.ports));

        // ─ FSM
        lines.push('#### d. 상태 천이도 (FSM Diagram)');
        lines.push('');
        if (hasFsmAsset) {
            pushVisualLine(
                lines,
                'FSM Diagram',
                assets.fsm,
                `output/fsm/${mod.moduleName}/${mod.moduleName}_fsm.svg`,
                `${mod.moduleName} fsm`
            );
        } else if (mod.fsmDetected) {
            lines.push('> ⚠️ FSM 패턴이 감지되었으나 FSM 다이어그램 파일이 없습니다. `code_fsm_draw.bat`를 실행하세요.');
        } else {
            lines.push('- 명시적 FSM 패턴 미검출');
        }
        lines.push('');

        // ─ 타이밍/로직 분석
        lines.push('#### e. 핵심 로직 및 타이밍 분석 (Timing Analysis)');
        lines.push('');
        if (Array.isArray(modInfo.stateDescription) && modInfo.stateDescription.length > 0) {
            lines.push('**상태 설명:**');
            lines.push('');
            modInfo.stateDescription.forEach(item => lines.push(`- ${item}`));
            lines.push('');
        }
        lines.push('| 항목 | 내용 |');
        lines.push('| :--- | :--- |');
        lines.push(`| 테스트벤치 | ${wave.tbSource ? `\`${wave.tbSource}\`` : `\`tb/tb_${mod.moduleName}.(v|sv)\` 자동 매칭 실패`} |`);
        if (tbInfo && tbInfo.role) lines.push(`| TB 역할 | ${tbInfo.role} |`);
        lines.push(`| 파형 산출물 | ${wave.existing.length + wave.imagePaths.length}개 |`);
        lines.push('');
    });

    lines.push('---');
    lines.push('');
    lines.push('## 4. 검증 및 시뮬레이션 (Verification)');
    lines.push('');
    lines.push('### 4.1 테스트벤치 구성 및 검증 시나리오');
    lines.push('');
    lines.push('| 모듈 | TB 파일 | 시나리오 |');
    lines.push('| :--- | :--- | :--- |');
    subBlockModules.forEach(mod => {
        const wave = collectWaveformPaths(mod.moduleName);
        const tbInfo = getTbInfoFromRelPath(wave.tbSource);
        const tbFile = wave.tbSource ? `\`${wave.tbSource}\`` : '*(자동 매칭 실패)*';
        let scenario = '수동 보완 필요';
        if (tbInfo && Array.isArray(tbInfo.scenario) && tbInfo.scenario.length > 0) {
            scenario = tbInfo.scenario.join('; ');
        }
        lines.push(`| \`${mod.moduleName}\` | ${tbFile} | ${scenario} |`);
    });
    lines.push('');
    lines.push('### 4.2 시뮬레이션 결과 분석 (Waveform Analysis)');
    lines.push('');
    subBlockModules.forEach(mod => {
        const wave = collectWaveformPaths(mod.moduleName);
        if (wave.imagePaths.length > 0) {
            lines.push(`**\`${mod.moduleName}\` 파형 이미지:**`);
            lines.push('');
            wave.imagePaths.forEach((p, idx) => lines.push(`![${mod.moduleName} waveform ${idx + 1}](${p})`));
            lines.push('');
        } else if (wave.existing.length > 0) {
            lines.push(`**\`${mod.moduleName}\` 파형 산출물:**`);
            lines.push('');
            wave.existing.forEach(p => lines.push(`- \`${p}\``));
            lines.push('');
        }
    });
    lines.push('> ⚠️ 커버리지 리포트는 시뮬레이터 결과를 수동 첨부하세요.');
    lines.push('');
    lines.push('### 4.3 하드웨어 동작 검증 (In-System Validation)');
    lines.push('');
    lines.push('> ⚠️ **수동 보완 필요:** 오실로스코프/ILA 실측 결과를 이 섹션에 추가하세요.');
    lines.push('');

    lines.push('---');
    lines.push('');
    lines.push('## 5. 구현 및 합성 결과 (Implementation & Synthesis)');
    lines.push('');
    lines.push('### 5.1 하드웨어 제약 사항 (XDC/SDC)');
    lines.push('');
    if (constraintFiles.length > 0) {
        constraintFiles.forEach(abs => lines.push(`- \`${relFromProject(abs)}\``));
    } else {
        lines.push('> ⚠️ 제약 파일(.xdc/.sdc)이 `constrs/` 폴더에서 검출되지 않았습니다.');
    }
    lines.push('');
    lines.push('### 5.2 합성 및 구현 요약');
    lines.push('');
    lines.push('> ⚠️ **수동 보완 필요:** Vivado 합성 결과 (Warning/Error 목록, Optimization 내용)를 작성하세요.');
    lines.push('');
    lines.push('### 5.3 핀 제약 사항 및 I/O 표준');
    lines.push('');
    lines.push('| 핀 이름 | PACKAGE_PIN | IOSTANDARD | 기능 |');
    lines.push('| :--- | :--- | :--- | :--- |');
    lines.push('| - | - | - | XDC 파일 기준으로 수동 보완 |');
    lines.push('');
    lines.push('### 5.4 자원 소모량 (Resource Utilization)');
    lines.push('');
    lines.push('| 자원 | Used | Available | 비율 |');
    lines.push('| :--- | :--- | :--- | :--- |');
    lines.push('| LUT | - | - | 합성 리포트 반영 |');
    lines.push('| FF | - | - | 합성 리포트 반영 |');
    lines.push('| BRAM | - | - | 합성 리포트 반영 |');
    lines.push('| DSP | - | - | 합성 리포트 반영 |');
    lines.push('');
    lines.push('### 5.5 타이밍 리포트 (Timing Summary)');
    lines.push('');
    lines.push('| 지표 | 값 |');
    lines.push('| :--- | :--- |');
    lines.push('| WNS (Worst Negative Slack) | - |');
    lines.push('| TNS (Total Negative Slack) | - |');
    lines.push('| Fmax (최대 동작 주파수) | - |');
    lines.push('');
    lines.push('### 5.6 파워 리포트 (Power Report)');
    lines.push('');
    lines.push('| 구분 | 예상 전력 |');
    lines.push('| :--- | :--- |');
    lines.push('| 동적 전력 (Dynamic) | - |');
    lines.push('| 정적 전력 (Static) | - |');
    lines.push('| 전체 합계 | - |');
    lines.push('');

    lines.push('---');
    lines.push('');
    lines.push('## 6. 결론 및 고찰 (Conclusion)');
    lines.push('');
    lines.push('### 6.1 설계 결과 및 성능 평가');
    lines.push('');
    lines.push('자동 생성 보고서 기준으로 구조/자산 연계 상태를 확인했습니다.');
    lines.push('');
    lines.push('> ⚠️ **수동 보완 필요:** 설계 목표 달성 여부, 성능 측정 결과, 비교 분석 등을 직접 작성하세요.');
    lines.push('');
    lines.push('### 6.2 문제 해결 과정 (Troubleshooting)');
    lines.push('');
    lines.push('| 문제 | 원인 | 해결책 |');
    lines.push('| :--- | :--- | :--- |');
    lines.push('| 누락 자산 | 해당 배치 미실행 | 각 bat 단계 순서대로 재실행 |');
    lines.push('');
    lines.push('### 6.3 향후 개선 방향 및 소감');
    lines.push('');
    lines.push('> ⚠️ **수동 보완 필요:** 설계 경험, 배운 점, 개선 아이디어를 작성하세요.');
    lines.push('');

    lines.push('---');
    lines.push('');
    lines.push('## 7. 부록 (Appendix)');
    lines.push('');
    lines.push('### 7.1 소스 파일 목록');
    lines.push('');
    lines.push('| 모듈명 | 파일 경로 |');
    lines.push('| :--- | :--- |');
    allModules.forEach(mod => lines.push(`| \`${mod.moduleName}\` | \`${mod.relPath}\` |`));
    lines.push('');
    lines.push('### 7.2 제약 파일 목록');
    lines.push('');
    if (constraintFiles.length > 0) {
        constraintFiles.forEach(abs => lines.push(`- \`${relFromProject(abs)}\``));
    } else {
        lines.push('- *(없음)*');
    }
    lines.push('');
    lines.push('### 7.3 산출물 디렉토리');
    lines.push('');
    lines.push('| 종류 | 경로 |');
    lines.push('| :--- | :--- |');
    lines.push('| 다이어그램 (Simple/Detailed) | `output/Diagram/` |');
    lines.push('| FSM 다이어그램 | `output/fsm/` |');
    lines.push('| 보고서 문서 | `output/docs/` |');
    lines.push('');

    return lines.join('\n');
}

function main() {
    if (hdlIndexer && typeof hdlIndexer.buildIndex === 'function') {
        try {
            const index = hdlIndexer.buildIndex(projectRoot);
            const cacheDir = path.join(outputDir, 'cache');
            ensureDir(cacheDir);
            fs.writeFileSync(path.join(cacheDir, 'hdl_index.json'), JSON.stringify(index, null, 2), 'utf8');
        } catch (e) {
            console.warn(`[WARN] HDL index generation skipped: ${e.message}`);
        }
    }

    const allModules = readVerilogModules();

    if (cli.listModules) {
        const printed = new Set();
        allModules.forEach(mod => {
            if (printed.has(mod.moduleName)) return;
            printed.add(mod.moduleName);
            console.log(mod.moduleName);
        });
        return;
    }

    allModules.forEach(parsePorts);
    allModules.forEach(detectFsm);
    const hierarchy = detectHierarchy(allModules);

    const selected = buildSubBlockModules(allModules, cli.selectedModuleNames, hierarchy.topModule);
    const subBlockModules = selected.modules;
    if (subBlockModules.length === 0) {
        throw new Error('No modules selected for report generation.');
    }

    if (selected.unknown.length > 0) {
        console.warn(`[WARN] ignored unknown modules: ${selected.unknown.join(', ')}`);
    }

    ensureDir(docsDir);
    ensureGithubCss();

    const markdown = buildMarkdown(allModules, subBlockModules, hierarchy);
    fs.writeFileSync(reportMdPath, markdown, 'utf8');

    console.log(`[SUCCESS] report.md generated: ${reportMdPath}`);
    console.log(`[INFO] modules(all): ${allModules.length}`);
    console.log(`[INFO] modules(sub-block): ${subBlockModules.length}`);
    console.log(`[INFO] css: ${githubCssPath}`);
}

try {
    main();
} catch (err) {
    console.error(`[ERROR] ${err.message}`);
    process.exit(1);
}

