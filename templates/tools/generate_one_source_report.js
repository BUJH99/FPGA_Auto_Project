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
        '  font-size: 11pt;',
        '  line-height: 1.6;',
        '  color: #1f2328;',
        '  max-width: 1100px;',
        '  margin: 0 auto;',
        '  padding: 24px;',
        '}',
        'h1, h2, h3, h4 { color: #0b2e59; margin-top: 1.2em; margin-bottom: 0.5em; }',
        'h1 { font-size: 22pt; }',
        'h2 { font-size: 12pt; }',
        'h3 { font-size: 11pt; }',
        'h4 { font-size: 10pt; }',
        'p, li, td, th { font-size: 10.5pt; }',
        'table { border-collapse: collapse; width: 100%; margin: 12px 0 20px; }',
        'th, td { border: 1px solid #d0d7de; padding: 6px 10px; text-align: left; }',
        'th { background: #f6f8fa; }',
        'blockquote {',
        '  border-left: 4px solid #afb8c1;',
        '  margin: 10px 0;',
        '  padding: 2px 12px;',
        '  color: #57606a;',
        '}',
        'img { max-width: 100%; height: auto; }',
        'code { background: #f6f8fa; padding: 2px 5px; border-radius: 4px; }',
        '.cover-page {',
        '  text-align: center;',
        '  padding-top: 80px;',
        '  min-height: 88vh;',
        '}',
        '.cover-page .cover-subtitle {',
        '  margin-top: 8px;',
        '  color: #455a64;',
        '  font-size: 12pt;',
        '}',
        '.cover-page .cover-meta {',
        '  margin-top: 20px;',
        '  font-size: 10.5pt;',
        '  color: #607d8b;',
        '}',
        '@media print {',
        '  body { max-width: none; }',
        '  .cover-page { page-break-after: always; }',
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
        const moduleMatch = clean.match(/\bmodule\s+([A-Za-z_]\w*)\b/);
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
            '| Port | Direction | Type | Width |',
            '|------|-----------|------|-------|',
            '| - | - | - | - |',
            ''
        ].join('\n');
    }

    const lines = [
        '| Port | Direction | Type | Width |',
        '|------|-----------|------|-------|'
    ];
    ports.forEach(p => {
        lines.push(`| \`${p.name}\` | ${p.direction} | ${p.type} | \`${p.width}\` |`);
    });
    lines.push('');
    return lines.join('\n');
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
        description.push(`현재 \`tb/tb_${mod.moduleName}.v\` 규칙의 테스트벤치가 자동 매칭되지 않아, 수동 테스트벤치 연결 여부를 확인해야 합니다.`);
    }

    if (isTopModule) {
        description.push('Top 모듈은 본 보고서에서 유일하게 상세(Detail) 다이어그램을 포함하며, 나머지 모듈은 Simple/FSM 중심으로 정리합니다.');
    }

    return description.join('\n\n');
}

function buildMarkdown(allModules, subBlockModules, hierarchy) {
    const now = new Date();
    const generatedAt = now.toISOString().replace(/\.\d{3}Z$/, 'Z');
    const generatedAtKo = now.toLocaleString('ko-KR', { hour12: false });
    const projectName = path.basename(projectRoot);
    const tree = buildHierarchyTree(hierarchy.topModule, hierarchy.moduleMap);
    const topAssets = hierarchy.topModule ? collectAssets(hierarchy.topModule) : null;

    const lines = [];
    lines.push('---');
    lines.push(`title: "${projectName} 하드웨어 설계 보고서"`);
    lines.push('author: "자동 생성 초안 (검토/수정 필요)"');
    lines.push(`date: "${generatedAtKo}"`);
    lines.push('lang: "ko-KR"');
    lines.push('toc: true');
    lines.push('toc-depth: 3');
    lines.push('---');
    lines.push('');
    lines.push('# 표지');
    lines.push('');
    lines.push(`## ${projectName} 하드웨어 설계 보고서`);
    lines.push('');
    lines.push('- 문서 종류: One Source Multi Use 자동 생성 초안');
    lines.push(`- 프로젝트명: ${projectName}`);
    lines.push(`- 소스 경로: \`${relFromProject(srcDir)}\``);
    lines.push(`- 생성 시각(ISO): ${generatedAt}`);
    lines.push(`- 생성 시각(로컬): ${generatedAtKo}`);
    lines.push('- 비고: 본 문서는 자동 생성 초안이며, 최종 제출 전 사람이 내용을 검토/수정해야 합니다.');
    lines.push('');
    lines.push('\\newpage');
    lines.push('');
    lines.push('## 1.1 개요');
    lines.push('');
    lines.push('### 1.1.1 문서 목적');
    lines.push('');
    lines.push(`본 문서는 \`${relFromProject(srcDir)}\`에 존재하는 HDL 모듈 구조를 기반으로, 다이어그램/FSM/테스트벤치/파형 경로를 한 번에 정리하는 자동 생성 보고서입니다.`);
    lines.push('');
    lines.push('### 1.1.2 설계 특징');
    lines.push('');
    lines.push(`- 최상위(Top) 후보 모듈: \`${hierarchy.topModule || '-'}\``);
    lines.push(`- 전체 모듈 수: ${allModules.length}`);
    lines.push(`- 서브 블록 설명 대상 수: ${subBlockModules.length} (Top 우선 포함)`);
    lines.push('- 소스 단일화: `report.md`를 사람이 수정 후 `report.html`, `report.docx`를 생성');
    lines.push('- 인터페이스 표(입출력 포트 표)는 제외하고, Simple Diagram 중심으로 모듈 구조를 설명');
    lines.push('');
    lines.push('## 1.2 전체 블록');
    lines.push('');
    lines.push('### 1.2.1 블록 다이어그램');
    lines.push('');
    lines.push('- 모듈 계층 트리:');
    lines.push('');
    lines.push('```text');
    lines.push(tree);
    lines.push('```');
    lines.push('');
    if (topAssets) {
        pushVisualLine(
            lines,
            'Top Simple Diagram',
            topAssets.simple,
            `output/Diagram/Simple/${hierarchy.topModule}/${hierarchy.topModule}.png`,
            `${hierarchy.topModule} simple`
        );
        pushVisualLine(
            lines,
            'Top 상세(Detail) 다이어그램',
            topAssets.detailed,
            `output/Diagram/Detailed/${hierarchy.topModule}/${hierarchy.topModule}.png`,
            `${hierarchy.topModule} detailed`
        );
    }
    lines.push('');
    lines.push('### 1.2.2 인터페이스 표현(Simple Diagram 대체)');
    lines.push('');
    lines.push('- 모듈별 입출력 포트 표는 이번 버전에서 의도적으로 제외합니다.');
    lines.push('- 대신 각 모듈의 Simple Diagram을 기본 인터페이스 설명 수단으로 사용합니다.');
    lines.push('');
    lines.push('### 1.2.3 메모리 목록');
    lines.push('');
    lines.push('> RAM/ROM/FIFO/Register File 등 메모리 관련 블록을 사용하는 경우, 본 절에 수동으로 보완해 주세요.');
    lines.push('');
    lines.push('### 1.2.4 레지스터 맵');
    lines.push('');
    lines.push('> SW에서 접근하는 레지스터가 존재하면 본 절에 주소/필드/설명을 수동으로 정리해 주세요.');
    lines.push('');
    lines.push('## 1.3 서브 블록 설명');
    lines.push('');
    lines.push('| 모듈 | 소스 경로 | 직접 하위 모듈 |');
    lines.push('|------|-----------|------------------|');
    subBlockModules.forEach(mod => {
        const children = mod.children.length > 0
            ? mod.children.map(ch => `${ch.moduleName}(${ch.instanceName})`).join(', ')
            : '-';
        lines.push(`| \`${mod.moduleName}\` | \`${mod.relPath}\` | ${children} |`);
    });
    lines.push('');

    subBlockModules.forEach((mod, index) => {
        const assets = collectAssets(mod.moduleName);
        const wave = collectWaveformPaths(mod.moduleName);
        const tbInfo = getTbInfoFromRelPath(wave.tbSource);
        const modInfo = mod.moduleInfo || { summary: [], stateDescription: [] };
        const sectionNo = index + 1;
        const hasFsmAsset = Boolean(assets.fsm);
        const hasWaveArtifacts = wave.existing.length > 0;
        const hasWaveImages = wave.imagePaths.length > 0;
        const hasTbSource = Boolean(wave.tbSource);
        const hasFsmMention = mod.fsmDetected || hasFsmAsset;
        const isTopModule = hierarchy.topModule && mod.moduleName.toLowerCase() === hierarchy.topModule.toLowerCase();

        lines.push(`### 1.3.${sectionNo} Sub block #${sectionNo}: ${mod.moduleName}`);
        lines.push('');
        lines.push(`- 소스: \`${mod.relPath}\``);
        lines.push(`- 직접 하위 모듈: ${mod.children.length > 0 ? mod.children.map(ch => `\`${ch.moduleName}\``).join(', ') : '-'}`);
        lines.push('');
        lines.push('#### 다이어그램');
        lines.push('');
        pushVisualLine(
            lines,
            'Simple 다이어그램',
            assets.simple,
            `output/Diagram/Simple/${mod.moduleName}/${mod.moduleName}.png`,
            `${mod.moduleName} simple`
        );
        if (isTopModule) {
            pushVisualLine(
                lines,
                '상세(Detail) 다이어그램',
                assets.detailed,
                `output/Diagram/Detailed/${mod.moduleName}/${mod.moduleName}.png`,
                `${mod.moduleName} detailed`
            );
        }
        if (hasFsmAsset) {
            pushVisualLine(
                lines,
                'FSM 다이어그램',
                assets.fsm,
                `output/fsm/${mod.moduleName}/${mod.moduleName}_fsm.png`,
                `${mod.moduleName} fsm`
            );
        }
        lines.push('');

        if (hasTbSource || hasWaveArtifacts || hasWaveImages) {
            lines.push('#### 테스트벤치 및 파형');
            lines.push('');
            if (hasTbSource) {
                lines.push(`- 테스트벤치 파일: \`${wave.tbSource}\``);
                if (tbInfo && tbInfo.role) {
                    lines.push(`- 테스트벤치 역할: ${tbInfo.role}`);
                }
                if (tbInfo && Array.isArray(tbInfo.scenario) && tbInfo.scenario.length > 0) {
                    lines.push('테스트 시나리오:');
                    tbInfo.scenario.forEach(item => lines.push(`- ${item}`));
                }
                if (tbInfo && Array.isArray(tbInfo.checkPoint) && tbInfo.checkPoint.length > 0) {
                    lines.push('체크포인트:');
                    tbInfo.checkPoint.forEach(item => lines.push(`- ${item}`));
                }
            }
            if (hasWaveArtifacts) {
                lines.push('- 생성된 파형/시뮬레이션 산출물:');
                wave.existing.forEach(p => lines.push(`- \`${p}\``));
            }
            if (hasWaveImages) {
                lines.push('- 파형 이미지:');
                wave.imagePaths.forEach((p, idx) => lines.push(`- ![${mod.moduleName} waveform ${idx + 1}](${p})`));
            }
            lines.push('');
        }
        lines.push('#### 모듈 설명(코드 상단 MODULE_INFO 기반)');
        lines.push('');
        if (modInfo.role) {
            lines.push(`- 역할: ${modInfo.role}`);
        }
        if (Array.isArray(modInfo.summary) && modInfo.summary.length > 0) {
            lines.push('요약:');
            modInfo.summary.forEach(item => lines.push(`- ${item}`));
        }
        if (Array.isArray(modInfo.stateDescription) && modInfo.stateDescription.length > 0) {
            lines.push('상태 설명:');
            modInfo.stateDescription.forEach(item => lines.push(`- ${item}`));
        }
        if (!modInfo.role && (!Array.isArray(modInfo.summary) || modInfo.summary.length === 0)) {
            lines.push(buildModuleDescriptionKR(mod, wave, hasFsmMention, Boolean(isTopModule), tbInfo));
        }
        lines.push('');
    });

    lines.push('## 1.4 추가 작업');
    lines.push('');
    lines.push('- 시뮬레이션/합성 후 성능(지연, 처리량, 자원) 요약을 추가합니다.');
    lines.push('- Corner case 테스트 시나리오 및 기대 동작을 테스트벤치 설명에 보강합니다.');
    lines.push('- 발표/제출 목적에 맞춰 문장 및 캡션을 사람이 최종 편집합니다.');
    lines.push('');
    lines.push('## 1.5 부록');
    lines.push('');
    lines.push('- 다이어그램 루트: `output/Diagram`');
    lines.push('- FSM 루트: `output/fsm`');
    lines.push('- 시뮬레이션 산출물 루트: `output`');
    lines.push('');

    return lines.join('\n');
}

function main() {
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

