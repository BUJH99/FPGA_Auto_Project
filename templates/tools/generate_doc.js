const fs = require('fs');
const path = require('path');

// Configuration
const projectRoot = process.argv[2] ? path.resolve(process.argv[2]) : path.join(__dirname, '../');

console.log(`Target Project Root: ${projectRoot}`);

const SRC_DIR = path.join(projectRoot, 'src');
const DOC_DIR = path.join(projectRoot, 'output/docs');
const OUTPUT_DIR = path.join(projectRoot, 'output');
const DIAGRAM_SIMPLE_DIR = path.join(projectRoot, 'output/Diagram/Simple');
const DIAGRAM_DETAILED_DIR = path.join(projectRoot, 'output/Diagram/Detailed');
const FSM_SVG_DIR = path.join(projectRoot, 'output/fsm/svg');
const FSM_DRAWIO_DIR = path.join(projectRoot, 'output/fsm/drawio');

// Ensure DOC_DIR exists
if (!fs.existsSync(DOC_DIR)) {
    fs.mkdirSync(DOC_DIR, { recursive: true });
}

// Helper: Extract detailed comments above a line
function extractComment(lines, index) {
    let comment = [];
    for (let i = index - 1; i >= 0; i--) {
        const line = lines[i].trim();
        if (line.startsWith('//')) {
            comment.unshift(line.replace(/^\/\/\s*/, ''));
        } else if (line.startsWith('*/')) {
            // detailed block comment end
            for (let j = i - 1; j >= 0; j--) {
                const bLine = lines[j].trim();
                if (bLine.startsWith('/*')) break;
                comment.unshift(bLine.replace(/^\*\s?/, ''));
                i = j; // skip processed lines
            }
        } else {
            break;
        }
    }
    return comment.join(' ');
}

function detectFsmInSource(content) {
    const hasStateCase = /\bcase\s*\(\s*[A-Za-z_]\w*(?:state|cur)[A-Za-z_0-9]*\s*\)/i.test(content);
    const hasStateDecl = /\b(localparam|parameter)\b[\s\S]{0,240}\b[A-Za-z_]\w*(?:state|idle|init|run|wait|done)\w*\s*=/i.test(content);
    const hasNextStateAssign = /\b[A-Za-z_]\w*(?:next|nxt|_d)\w*\s*(?:<=|=)\s*[A-Za-z_]\w+/i.test(content);
    const hasAlways = /\balways\s*@|\balways_comb\b/i.test(content);
    return (hasAlways && hasStateCase) || (hasStateDecl && hasNextStateAssign);
}

function appendFileLink(mdContent, docDir, targetPath, label, asImage) {
    if (!fs.existsSync(targetPath)) return mdContent;
    const relPath = path.relative(docDir, targetPath).replace(/\\/g, '/');
    if (asImage) {
        return mdContent + `- ${label}: ![${label}](${relPath})\n`;
    }
    return mdContent + `- ${label}: [${path.basename(targetPath)}](${relPath})\n`;
}

function appendSectionToc(mdContent, tocItems) {
    if (!tocItems || tocItems.length === 0) return mdContent;
    mdContent += `## Table of Contents\n\n`;
    tocItems.forEach(item => {
        mdContent += `- [${item.title}](#${item.anchor})\n`;
    });
    mdContent += `\n`;
    return mdContent;
}

function getSubmoduleSourceLink(moduleName) {
    const sourceCandidates = [
        path.join(SRC_DIR, `${moduleName}.v`),
        path.join(SRC_DIR, `${moduleName}.sv`)
    ];
    const sourcePath = sourceCandidates.find(p => fs.existsSync(p));
    if (!sourcePath) return null;
    return path.relative(DOC_DIR, sourcePath).replace(/\\/g, '/');
}

// Main Function
function generateMarkdown(filePath) {
    const content = fs.readFileSync(filePath, 'utf-8');
    const lines = content.split('\n');
    const fileName = path.basename(filePath);
    const moduleName = path.basename(filePath, path.extname(filePath));
    
    let mdContent = `# Module: ${moduleName}\n\n`;
    
    // Add link to source code
    const relativeSrcPath = path.relative(DOC_DIR, filePath).replace(/\\/g, '/');
    mdContent += `[View Source Code](${relativeSrcPath})\n\n`;
    
    // 1. Description (Top comments)
    let description = "";
    for (let i = 0; i < Math.min(20, lines.length); i++) {
        const line = lines[i].trim();
        if (line.startsWith('// Description:') || line.startsWith('// Purpose:')) {
            description = line.replace(/^\/\/\s*\w+:\s*/, '');
        }
    }
    if (description) {
        mdContent += `**Description**: ${description}\n\n`;
    }

    const fsmSvgPath = path.join(FSM_SVG_DIR, `${moduleName}_fsm.svg`);
    const fsmDrawioPath = path.join(FSM_DRAWIO_DIR, `${moduleName}_fsm.drawio`);
    const fsmAssetExists = fs.existsSync(fsmSvgPath) || fs.existsSync(fsmDrawioPath);
    const fsmDetected = detectFsmInSource(content);
    const enableFsmSection = fsmDetected || fsmAssetExists;

    mdContent = appendSectionToc(mdContent, [
        { title: 'Visuals', anchor: 'visuals' },
        ...(enableFsmSection ? [{ title: 'FSM Diagram', anchor: 'fsm-diagram' }] : []),
        { title: 'Parameters', anchor: 'parameters' },
        { title: 'Interface', anchor: 'interface' },
        { title: 'Signals', anchor: 'signals' },
        { title: 'Assign Statements', anchor: 'assign-statements' },
        { title: 'Always Blocks', anchor: 'always-blocks' },
        { title: 'Functions', anchor: 'functions' },
        { title: 'Sub-modules', anchor: 'sub-modules' }
    ]);

    // 2. Visuals (Simple / Detailed)
    mdContent += `## Visuals\n\n`;
    const simpleSvgPath = path.join(DIAGRAM_SIMPLE_DIR, `${moduleName}.svg`);
    const simpleDrawioPath = path.join(DIAGRAM_SIMPLE_DIR, `${moduleName}.drawio`);
    const detailedSvgPath = path.join(DIAGRAM_DETAILED_DIR, `${moduleName}_detailed.svg`);
    const detailedDrawioPath = path.join(DIAGRAM_DETAILED_DIR, `${moduleName}_detailed.drawio`);

    mdContent += `### Simple Diagram\n`;
    let hasSimpleAsset = false;
    if (fs.existsSync(simpleSvgPath)) {
        hasSimpleAsset = true;
        mdContent = appendFileLink(mdContent, DOC_DIR, simpleSvgPath, 'Simple SVG', true);
    }
    if (fs.existsSync(simpleDrawioPath)) {
        hasSimpleAsset = true;
        mdContent = appendFileLink(mdContent, DOC_DIR, simpleDrawioPath, 'Simple Draw.io', false);
    }
    if (!hasSimpleAsset) {
        mdContent += `- *Simple diagram assets not found.*\n`;
    }
    mdContent += `\n`;

    mdContent += `### Detailed Diagram\n`;
    let hasDetailedAsset = false;
    if (fs.existsSync(detailedSvgPath)) {
        hasDetailedAsset = true;
        mdContent = appendFileLink(mdContent, DOC_DIR, detailedSvgPath, 'Detailed SVG', true);
    }
    if (fs.existsSync(detailedDrawioPath)) {
        hasDetailedAsset = true;
        mdContent = appendFileLink(mdContent, DOC_DIR, detailedDrawioPath, 'Detailed Draw.io', false);
    }
    if (!hasDetailedAsset) {
        mdContent += `- *Detailed diagram assets not found.*\n`;
    }
    mdContent += `\n`;

    // FSM visuals are shown when source pattern is detected or FSM assets already exist.
    if (enableFsmSection) {
        mdContent += `## FSM Diagram\n\n`;
        let hasFsmAsset = false;
        if (fs.existsSync(fsmSvgPath)) {
            hasFsmAsset = true;
            mdContent = appendFileLink(mdContent, DOC_DIR, fsmSvgPath, 'FSM SVG', true);
        }
        if (fs.existsSync(fsmDrawioPath)) {
            hasFsmAsset = true;
            mdContent = appendFileLink(mdContent, DOC_DIR, fsmDrawioPath, 'FSM Draw.io', false);
        }
        if (!hasFsmAsset) {
            mdContent += `- *FSM was detected, but no generated FSM assets were found.*\n`;
            mdContent += `- *Run code_fsm_draw.bat to generate output/fsm/svg and output/fsm/drawio files.*\n`;
        }
        mdContent += `\n`;
    }

    // 3. Parameters
    mdContent += `## Parameters\n\n`;
    mdContent += `| Type | Name | Default Value | Description |\n`;
    mdContent += `|------|------|---------------|-------------|\n`;
    
    let hasParams = false;
    // Regex explanation:
    // Capture 1: keyword (parameter or localparam)
    // Capture 2: optional suffix (ter, eter for typos/variants)
    // Capture 3: optional type (integer, real, etc.)
    // Capture 4: name
    // Capture 5: value
    const paramRegex = /(?:^\s*|#\s*\(\s*)(parameter|localparam)(e?ter)?\s+(?:(integer|real|time|shortint|int|longint|byte|bit|logic|reg|signed|unsigned)\s+)?(\w+)\s*=\s*([^,;)\n]+)/gm;
    
    let match;
    while ((match = paramRegex.exec(content)) !== null) {
        hasParams = true;
        const mainKeyword = match[1]; // parameter or localparam
        const suffix = match[2] || ''; 
        const varType = match[3] || '';
        const name = match[4];
        const value = match[5].trim();
        
        const fullType = varType ? `${mainKeyword}${suffix} ${varType}` : `${mainKeyword}${suffix}`;

        // Find line number to get comment
        const lineNum = content.substring(0, match.index).split('\n').length - 1;
        const desc = extractComment(lines, lineNum);
        
        mdContent += `| \`${fullType}\` | \`${name}\` | \`${value}\` | ${desc} |\n`;
    }
    if (!hasParams) mdContent += `| - | - | - | - |\n`;
    mdContent += `\n`;

    // 4. Interface (Ports)
    mdContent += `## Interface\n\n`;
    mdContent += `| Port Name | Direction | Type | Width | Description |\n`;
    mdContent += `|-----------|-----------|------|-------|-------------|\n`;

    // Simplified Port Regex (Not perfect but works for standard coding styles)
    // Matches: input/output [reg/wire] [range] name
    // We scan line by line to capture comments better
    let hasPorts = false;
    const portNames = new Set(); // Keep track of ports to exclude from signals
    lines.forEach((line, idx) => {
        const portRegex = /^\s*(input|output|inout)\s+(?:(reg|wire|logic)\s+)?(?:\[(.*?)\]\s+)?(\w+)/;
        const m = line.match(portRegex);
        if (m) {
            hasPorts = true;
            const dir = m[1];
            const type = m[2] || 'wire';
            const width = m[3] || '1';
            const name = m[4];
            portNames.add(name);
            
            // Check for trailing comment usually used for ports
            let desc = "";
            if (line.includes('//')) {
                desc = line.split('//')[1].trim();
            } else {
                desc = extractComment(lines, idx);
            }
            
            mdContent += `| \`${name}\` | **${dir}** | ${type} | \`${width}\` | ${desc} |\n`;
        }
    });

    if (!hasPorts) mdContent += `| - | - | - | - | - |\n`;
    mdContent += `\n`;
    
    // 5. Signals (Internal)
    mdContent += `## Signals\n\n`;
    mdContent += `| Name | Type | Width | Description |\n`;
    mdContent += `|------|------|-------|-------------|\n`;
    
    let hasSignals = false;
    lines.forEach((line, idx) => {
        // Regex for internal signals: wire/reg/logic [range] name;
        // Exclude lines that start with input/output/inout (already handled)
        if (/^\s*(input|output|inout)/.test(line)) return;

        const signalRegex = /^\s*(wire|reg|logic)\s+(?:\[(.*?)\]\s+)?(\w+)/;
        const m = line.match(signalRegex);
        if (m) {
            const type = m[1];
            const width = m[2] || '1';
            const name = m[3];
            
            if (!portNames.has(name)) {
                hasSignals = true;
                 
                // Check for trailing comment
                let desc = "";
                if (line.includes('//')) {
                    desc = line.split('//')[1].trim();
                } else {
                    desc = extractComment(lines, idx);
                }
                
                mdContent += `| \`${name}\` | ${type} | \`${width}\` | ${desc} |\n`;
            }
        }
    });
    
    if (!hasSignals) mdContent += `| - | - | - | - |\n`;
    mdContent += `\n`;
    
    // 6. Assign Statements
    mdContent += `## Assign Statements\n\n`;
    mdContent += `| Target | Logic | Description |\n`;
    mdContent += `|--------|-------|-------------|\n`;
    
    let hasAssigns = false;
    lines.forEach((line, idx) => {
        const assignRegex = /^\s*assign\s+(.*?)\s*=\s*(.*?);/;
        const m = line.match(assignRegex);
        if (m) {
            hasAssigns = true;
            const target = m[1].trim();
            const logic = m[2].trim();
            
            // Check for trailing comment
            let desc = "";
            if (line.includes('//')) {
                desc = line.split('//')[1].trim();
            } else {
                desc = extractComment(lines, idx);
            }
            
            mdContent += `| \`${target}\` | \`${logic}\` | ${desc} |\n`;
        }
    });
    if (!hasAssigns) mdContent += `| - | - | - |\n`;
    mdContent += `\n`;

    // 7. Always Blocks
    mdContent += `## Always Blocks\n\n`;
    
    let alwaysCount = 0;
    // We need to re-scan lines carefully, so we can't just use forEach if we want to skip lines
    // But since we are building mdContent sequentially, we can just do a new pass or structural scan.
    // To allow skipping lines (consuming the block), let's use a standard for loop.
    
    // We will combine Always and Function scanning in this pass? 
    // No, the user wants sections. Let's do separate passes or just one pass that fills structured data, then print.
    // For simplicity, let's do a dedicated pass for each section, recognizing that it might be slightly inefficient (but fine for these file sizes).
    
    // ALWAYS BLOCKS PASS
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        // Match always @(...) or always @*
        const alwaysRegex = /^\s*always\s*@\s*(.*)/;
        const m = line.match(alwaysRegex);
        
        if (m) {
            const sensitivity = m[1].trim(); // Captures "(...)" or "*" partial
            const desc = extractComment(lines, i) || "Sequential Logic";
            
            let blockLines = [];
            let depth = 0;
            let foundBegin = false;
            let j = i;
            
            // Extract block content
            for (; j < lines.length; j++) {
                const l = lines[j];
                blockLines.push(l);
                
                // Remove comments for parsing 'begin'/'end' to avoid false positives
                // Simple stripping: // to end, and /* */ blocks (assuming simple single line for this regex)
                const cleanLine = l.split('//')[0].trim(); 
                
                // Count words exactly
                const begins = (cleanLine.match(/\bbegin\b/g) || []).length;
                const ends = (cleanLine.match(/\bend\b/g) || []).length;
                
                if (begins > 0) foundBegin = true;
                
                depth += (begins - ends);
                
                // Logic to break
                if (foundBegin) {
                    if (depth <= 0 && ends > 0) { // depth reached 0 after finding a begin
                         // We found the matching end
                         break;
                    }
                } else {
                    // No begin found yet
                    if (cleanLine.includes(';')) {
                        // Single statement always block (e.g., always @* a = b;)
                        // But wait, if 'begin' is on the NEXT line?
                        // If we haven't found a begin and we find a semicolon, it's done.
                        // UNLESS the semicolon is part of the sensitivity list (unlikely in Verilog 2001+)
                        // However, strictly speaking, 'always @(pos) begin' -> no semicolon yet.
                        // 'always @(pos) a <= b;' -> semicolon ends it.
                        
                        // If current line is just the always header, it shouldn't have a semi-colon usually, unless it's empty `always @(...) ;`
                        if (j === i && !cleanLine.includes(';')) {
                            // continue looking for begin or statement body
                        } else {
                             break;
                        }
                    }
                }
            }
            // If the loop finished without break, we just take what we got (likely EOF)
            
            alwaysCount++;
            mdContent += `### Always Block ${alwaysCount}\n`;
            mdContent += `- **Sensitivity**: \`${sensitivity}\`\n`;
            mdContent += `- **Description**: ${desc}\n\n`;
            mdContent += "```verilog\n";
            mdContent += blockLines.join('\n');
            mdContent += "\n```\n\n";
            
            // Move main loop index only if we are confident we consumed the block
            // However, since we are doing separate passes for separate sections, 
            // we technically don't need to skip i, but it prevents re-matching if we had complex logic.
            // For now, let's NOT skip 'i' in the outer loop to simplify, 
            // because our regex checks for 'always' keyword specifically. 
            // Skipping 'i' is safer to avoid overlapping matches logic.
            i = j; 
        }
    }

    if (alwaysCount === 0) mdContent += "*No always blocks defined.*\n\n";

    // 8. Functions
    mdContent += `## Functions\n\n`;
    
    let funcCount = 0;
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        const funcRegex = /^\s*function\s+(?:automatic\s+)?(?:(integer|real|time|shortint|int|longint|byte|bit|logic|reg|signed|unsigned|\[.*?\])\s+)?(\w+)/;
        const m = line.match(funcRegex);
        
        if (m) {
            const retType = m[1] || "default";
            const name = m[2];
            const desc = extractComment(lines, i);
            
            let blockLines = [];
            let j = i;
            for (; j < lines.length; j++) {
                blockLines.push(lines[j]);
                if (lines[j].trim().startsWith('endfunction')) break;
            }
            
            mdContent += `### Function: \`${name}\`\n`;
            mdContent += `- **Return Type**: \`${retType}\`\n`;
            mdContent += `- **Description**: ${desc}\n\n`;
            mdContent += "```verilog\n";
            mdContent += blockLines.join('\n');
            mdContent += "\n```\n\n";
            
            funcCount++;
            i = j;
        }
    }

    if (funcCount === 0) mdContent += "*No functions defined.*\n\n";
    
    // 5. Hierarchy / Dependencies
    // Regex for instantiations: ModuleName [#(params)] u_InstanceName
    mdContent += `## Sub-modules\n\n`;
    // Improved regex to handle optional parameters #( ... ) spanning multiple lines
    const instRegex = /^\s*(\w+)\s+(?:#\s*\([\s\S]*?\)\s*)?(\w+)/gm;
    let instMatch;
    let submodules = [];
    
    const invalidKeywords = new Set([
        'module', 'endmodule', 'primitive', 'endprimitive', 'config', 'endconfig',
        'library', 'design', 'instance', 'generate', 'endgenerate', 'genvar',
        'package', 'endpackage', 'program', 'endprogram', 'interface', 'endinterface',
        'function', 'endfunction', 'task', 'endtask',
        'always', 'initial', 'final', 'assign', 'defparam', 'alias',
        'input', 'output', 'inout', 'ref',
        'wire', 'tri', 'tri0', 'tri1', 'supply0', 'supply1', 'wand', 'triand', 'wor', 'trior', 
        'reg', 'logic', 'bit', 'byte', 'shortint', 'int', 'longint',
        'integer', 'real', 'realtime', 'time',
        'parameter', 'localparam', 'specparam',
        'if', 'else', 'case', 'casex', 'casez', 'endcase', 'default',
        'forever', 'repeat', 'while', 'for', 'do',
        'begin', 'end', 'fork', 'join', 'join_any', 'join_none',
        'wait', 'disable',
        'sequence', 'endsequence', 'property', 'endproperty', 'assert', 'cover', 'assume',
        'clocking', 'endclocking',
        'import', 'export', 'context', 'pure'
    ]);

    while ((instMatch = instRegex.exec(content)) !== null) {
        // instMatch[1] is the potential Module Name
        // instMatch[2] is the potential Instance Name
        if (!invalidKeywords.has(instMatch[1])) {
            const submoduleName = instMatch[1];
            const instanceName = instMatch[2];
            const sourceLink = getSubmoduleSourceLink(submoduleName);

            if (sourceLink) {
                submodules.push(`- [**${submoduleName}**](${sourceLink}) (${instanceName})`);
            } else {
                submodules.push(`- **${submoduleName}** (${instanceName})`);
            }
        }
    }
    
    if (submodules.length > 0) {
        mdContent += submodules.join('\n') + `\n\n`;
    } else {
        mdContent += `*No sub-modules instantiated.*\n\n`;
    }

    // Write file
    const outPath = path.join(DOC_DIR, `${moduleName}.md`);
    fs.writeFileSync(outPath, mdContent);
    console.log(`Generated: ${outPath}`);

    return {
        moduleName,
        docPath: outPath,
        hasSimpleSvg: fs.existsSync(simpleSvgPath),
        hasSimpleDrawio: fs.existsSync(simpleDrawioPath),
        simpleSvgPath,
        simpleDrawioPath,
        hasFsmSection: enableFsmSection,
        hasFsmSvg: fs.existsSync(fsmSvgPath),
        hasFsmDrawio: fs.existsSync(fsmDrawioPath),
        fsmSvgPath,
        fsmDrawioPath
    };
}

function generateFsmIndex(docItems) {
    const fsmItems = docItems.filter(item =>
        item &&
        item.hasFsmSection &&
        (item.hasFsmSvg || item.hasFsmDrawio)
    );
    if (fsmItems.length === 0) return;

    let indexMd = `# FSM Index\n\n`;
    indexMd += `자동 감지된 FSM 모듈의 다이어그램/문서 링크입니다.\n\n`;
    indexMd += `## Modules\n\n`;

    fsmItems
        .sort((a, b) => a.moduleName.localeCompare(b.moduleName))
        .forEach(item => {
            const docRel = path.relative(DOC_DIR, item.docPath).replace(/\\/g, '/');
            indexMd += `### ${item.moduleName}\n`;
            indexMd += `- Module Doc: [${path.basename(item.docPath)}](${docRel})\n`;
            if (item.hasSimpleSvg) {
                const simpleSvgRel = path.relative(DOC_DIR, item.simpleSvgPath).replace(/\\/g, '/');
                indexMd += `- Simple SVG: [${path.basename(item.simpleSvgPath)}](${simpleSvgRel})\n`;
            }
            if (item.hasSimpleDrawio) {
                const simpleDrawioRel = path.relative(DOC_DIR, item.simpleDrawioPath).replace(/\\/g, '/');
                indexMd += `- Simple Draw.io: [${path.basename(item.simpleDrawioPath)}](${simpleDrawioRel})\n`;
            }
            if (item.hasFsmSvg) {
                const svgRel = path.relative(DOC_DIR, item.fsmSvgPath).replace(/\\/g, '/');
                indexMd += `- FSM SVG: [${path.basename(item.fsmSvgPath)}](${svgRel})\n`;
                indexMd += `- Preview:\n\n![${item.moduleName} FSM](${svgRel})\n\n`;
            }
            if (item.hasFsmDrawio) {
                const drawioRel = path.relative(DOC_DIR, item.fsmDrawioPath).replace(/\\/g, '/');
                indexMd += `- FSM Draw.io: [${path.basename(item.fsmDrawioPath)}](${drawioRel})\n`;
            }
            indexMd += `\n`;
        });

    const outPath = path.join(DOC_DIR, 'fsm_index.md');
    fs.writeFileSync(outPath, indexMd);
    console.log(`Generated: ${outPath}`);
}

// Run for all .v/.sv files in src
const readline = require('readline');

const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout
});

console.log("Searching for HDL source files (.v/.sv) in: " + SRC_DIR);
if (fs.existsSync(SRC_DIR)) {
    const files = fs.readdirSync(SRC_DIR).filter(f => /\.(v|sv)$/i.test(f));
    
    if (files.length === 0) {
        console.log("No HDL source files found.");
        rl.close();
    } else {
        console.log("\nFound the following HDL files:");
        files.forEach((f, index) => {
            console.log(`[${index + 1}] ${f}`);
        });
        console.log("");

        rl.question('Enter file numbers to generate docs for (e.g., "1,3,5" or "all"): ', (answer) => {
            let selectedFiles = [];
            const input = answer.trim().toLowerCase();

            if (input === 'all' || input === '') {
                selectedFiles = files;
            } else {
                // Handle brackets [] if user types them, though instructions say comma separated
                const cleanInput = input.replace(/[\[\]]/g, '');
                const indices = cleanInput.split(',').map(s => parseInt(s.trim()));
                
                selectedFiles = files.filter((_, i) => indices.includes(i + 1));
            }

            if (selectedFiles.length === 0) {
                console.log("No valid files selected.");
            } else {
                console.log(`\nGenerating docs for ${selectedFiles.length} files...`);
                const results = [];
                selectedFiles.forEach(f => {
                    results.push(generateMarkdown(path.join(SRC_DIR, f)));
                });
                generateFsmIndex(results);
                console.log("\nDone.");
            }
            rl.close();
        });
    }
} else {
    console.error("Source directory not found!");
    rl.close();
}
