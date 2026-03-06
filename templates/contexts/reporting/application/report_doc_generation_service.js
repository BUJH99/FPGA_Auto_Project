const fs = require("fs");
const path = require("path");
const {
  createRunSummary,
  createArtifactRecord,
} = require("../../../shared/domain/run_contracts");
const { writeJsonFile } = require("../../../shared/application/json_file_service");
const { appendRunEntry } = require("../../../shared/application/run_registry_service");

function normalizeSlashes(value) {
  return String(value || "").replace(/\\/g, "/");
}

function createDocumentationContext({ projectRoot, sourceFiles = [] } = {}) {
  const root = path.resolve(projectRoot || process.cwd());
  const normalizedSourceFiles = [...new Set((sourceFiles || []).map((filePath) => path.resolve(filePath)))]
    .filter((filePath) => /\.(v|sv)$/i.test(filePath))
    .sort((a, b) => a.localeCompare(b));
  const sourceByBasenameLower = new Map();
  normalizedSourceFiles.forEach((absPath) => {
    const key = path.basename(absPath).toLowerCase();
    if (!sourceByBasenameLower.has(key)) {
      sourceByBasenameLower.set(key, absPath);
    }
  });

  return {
    projectRoot: root,
    sourceFiles: normalizedSourceFiles,
    sourceByBasenameLower,
    directories: {
      docDir: path.join(root, "output", "docs"),
      simpleDiagramDir: path.join(root, "output", "Diagram", "Simple"),
      detailedDiagramDir: path.join(root, "output", "Diagram", "Detailed"),
      fsmSvgDir: path.join(root, "output", "fsm", "svg"),
      fsmDrawioDir: path.join(root, "output", "fsm", "drawio"),
      outputDir: path.join(root, "output"),
    },
  };
}

function listDocumentationCandidates(context) {
  return (context.sourceFiles || []).map((absPath) => ({
    absPath,
    relPath: path.relative(context.projectRoot, absPath).replace(/\\/g, "/"),
  }));
}

function selectDocumentationCandidates(input, candidates) {
  const rows = Array.isArray(candidates) ? candidates : [];
  const normalized = String(input || "").trim().toLowerCase();

  if (!normalized || normalized === "all") {
    return rows;
  }

  const cleanInput = normalized.replace(/[\[\]]/g, "");
  const tokens = cleanInput.split(/[,\s]+/).filter(Boolean);
  const indices = tokens
    .map((token) => parseInt(token, 10))
    .filter((value) => Number.isInteger(value) && value > 0);

  return rows.filter((_, index) => indices.includes(index + 1));
}

function ensureDir(dirPath) {
  if (!fs.existsSync(dirPath)) {
    fs.mkdirSync(dirPath, { recursive: true });
  }
}

function extractComment(lines, index) {
  const comment = [];
  for (let i = index - 1; i >= 0; i -= 1) {
    const line = lines[i].trim();
    if (line.startsWith("//")) {
      comment.unshift(line.replace(/^\/\/\s*/, ""));
    } else if (line.startsWith("*/")) {
      for (let j = i - 1; j >= 0; j -= 1) {
        const blockLine = lines[j].trim();
        if (blockLine.startsWith("/*")) break;
        comment.unshift(blockLine.replace(/^\*\s?/, ""));
        i = j;
      }
    } else {
      break;
    }
  }
  return comment.join(" ");
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
  const relPath = path.relative(docDir, targetPath).replace(/\\/g, "/");
  if (asImage) {
    return `${mdContent}- ${label}: ![${label}](${relPath})\n`;
  }
  return `${mdContent}- ${label}: [${path.basename(targetPath)}](${relPath})\n`;
}

function appendSectionToc(mdContent, tocItems) {
  if (!tocItems || tocItems.length === 0) return mdContent;
  let out = `${mdContent}## Table of Contents\n\n`;
  tocItems.forEach((item) => {
    out += `- [${item.title}](#${item.anchor})\n`;
  });
  return `${out}\n`;
}

function getSubmoduleSourceLink(context, moduleName) {
  const sourceCandidates = [`${moduleName}.v`, `${moduleName}.sv`];
  let sourcePath = null;
  sourceCandidates.forEach((candidate) => {
    if (sourcePath) return;
    const hit = context.sourceByBasenameLower.get(candidate.toLowerCase());
    if (hit) sourcePath = hit;
  });
  if (!sourcePath) return null;
  return path.relative(context.directories.docDir, sourcePath).replace(/\\/g, "/");
}

function generateMarkdown(context, filePath) {
  const content = fs.readFileSync(filePath, "utf8");
  const lines = content.split("\n");
  const moduleName = path.basename(filePath, path.extname(filePath));
  const {
    docDir,
    simpleDiagramDir,
    detailedDiagramDir,
    fsmSvgDir,
    fsmDrawioDir,
  } = context.directories;

  let mdContent = `# Module: ${moduleName}\n\n`;
  const relativeSrcPath = path.relative(docDir, filePath).replace(/\\/g, "/");
  mdContent += `[View Source Code](${relativeSrcPath})\n\n`;

  let description = "";
  for (let i = 0; i < Math.min(20, lines.length); i += 1) {
    const line = lines[i].trim();
    if (line.startsWith("// Description:") || line.startsWith("// Purpose:")) {
      description = line.replace(/^\/\/\s*\w+:\s*/, "");
    }
  }
  if (description) {
    mdContent += `**Description**: ${description}\n\n`;
  }

  const fsmSvgPath = path.join(fsmSvgDir, `${moduleName}_fsm.svg`);
  const fsmDrawioPath = path.join(fsmDrawioDir, `${moduleName}_fsm.drawio`);
  const fsmAssetExists = fs.existsSync(fsmSvgPath) || fs.existsSync(fsmDrawioPath);
  const fsmDetected = detectFsmInSource(content);
  const enableFsmSection = fsmDetected || fsmAssetExists;

  mdContent = appendSectionToc(mdContent, [
    { title: "Visuals", anchor: "visuals" },
    ...(enableFsmSection ? [{ title: "FSM Diagram", anchor: "fsm-diagram" }] : []),
    { title: "Parameters", anchor: "parameters" },
    { title: "Interface", anchor: "interface" },
    { title: "Signals", anchor: "signals" },
    { title: "Assign Statements", anchor: "assign-statements" },
    { title: "Always Blocks", anchor: "always-blocks" },
    { title: "Functions", anchor: "functions" },
    { title: "Sub-modules", anchor: "sub-modules" },
  ]);

  mdContent += "## Visuals\n\n";
  const simpleSvgPath = path.join(simpleDiagramDir, `${moduleName}.svg`);
  const simpleDrawioPath = path.join(simpleDiagramDir, `${moduleName}.drawio`);
  const detailedSvgPath = path.join(detailedDiagramDir, `${moduleName}_detailed.svg`);
  const detailedDrawioPath = path.join(detailedDiagramDir, `${moduleName}_detailed.drawio`);

  mdContent += "### Simple Diagram\n";
  let hasSimpleAsset = false;
  if (fs.existsSync(simpleSvgPath)) {
    hasSimpleAsset = true;
    mdContent = appendFileLink(mdContent, docDir, simpleSvgPath, "Simple SVG", true);
  }
  if (fs.existsSync(simpleDrawioPath)) {
    hasSimpleAsset = true;
    mdContent = appendFileLink(mdContent, docDir, simpleDrawioPath, "Simple Draw.io", false);
  }
  if (!hasSimpleAsset) mdContent += "- *Simple diagram assets not found.*\n";
  mdContent += "\n";

  mdContent += "### Detailed Diagram\n";
  let hasDetailedAsset = false;
  if (fs.existsSync(detailedSvgPath)) {
    hasDetailedAsset = true;
    mdContent = appendFileLink(mdContent, docDir, detailedSvgPath, "Detailed SVG", true);
  }
  if (fs.existsSync(detailedDrawioPath)) {
    hasDetailedAsset = true;
    mdContent = appendFileLink(mdContent, docDir, detailedDrawioPath, "Detailed Draw.io", false);
  }
  if (!hasDetailedAsset) mdContent += "- *Detailed diagram assets not found.*\n";
  mdContent += "\n";

  if (enableFsmSection) {
    mdContent += "## FSM Diagram\n\n";
    let hasFsmAsset = false;
    if (fs.existsSync(fsmSvgPath)) {
      hasFsmAsset = true;
      mdContent = appendFileLink(mdContent, docDir, fsmSvgPath, "FSM SVG", true);
    }
    if (fs.existsSync(fsmDrawioPath)) {
      hasFsmAsset = true;
      mdContent = appendFileLink(mdContent, docDir, fsmDrawioPath, "FSM Draw.io", false);
    }
    if (!hasFsmAsset) {
      mdContent += "- *FSM was detected, but no generated FSM assets were found.*\n";
      mdContent += "- *Run code_fsm_draw.bat to generate output/fsm/svg and output/fsm/drawio files.*\n";
    }
    mdContent += "\n";
  }

  mdContent += "## Parameters\n\n";
  mdContent += "| Type | Name | Default Value | Description |\n";
  mdContent += "|------|------|---------------|-------------|\n";
  let hasParams = false;
  const paramRegex = /(?:^\s*|#\s*\(\s*)(parameter|localparam)(e?ter)?\s+(?:(integer|real|time|shortint|int|longint|byte|bit|logic|reg|signed|unsigned)\s+)?(\w+)\s*=\s*([^,;)\n]+)/gm;
  let match = null;
  while ((match = paramRegex.exec(content)) !== null) {
    hasParams = true;
    const mainKeyword = match[1];
    const suffix = match[2] || "";
    const varType = match[3] || "";
    const name = match[4];
    const value = match[5].trim();
    const fullType = varType ? `${mainKeyword}${suffix} ${varType}` : `${mainKeyword}${suffix}`;
    const lineNum = content.substring(0, match.index).split("\n").length - 1;
    const desc = extractComment(lines, lineNum);
    mdContent += `| \`${fullType}\` | \`${name}\` | \`${value}\` | ${desc} |\n`;
  }
  if (!hasParams) mdContent += "| - | - | - | - |\n";
  mdContent += "\n";

  mdContent += "## Interface\n\n";
  mdContent += "| Port Name | Direction | Type | Width | Description |\n";
  mdContent += "|-----------|-----------|------|-------|-------------|\n";
  let hasPorts = false;
  const portNames = new Set();
  lines.forEach((line, index) => {
    const portRegex = /^\s*(input|output|inout)\s+(?:(reg|wire|logic)\s+)?(?:\[(.*?)\]\s+)?(\w+)/;
    const portMatch = line.match(portRegex);
    if (!portMatch) return;
    hasPorts = true;
    const dir = portMatch[1];
    const type = portMatch[2] || "wire";
    const width = portMatch[3] || "1";
    const name = portMatch[4];
    portNames.add(name);
    const desc = line.includes("//") ? line.split("//")[1].trim() : extractComment(lines, index);
    mdContent += `| \`${name}\` | **${dir}** | ${type} | \`${width}\` | ${desc} |\n`;
  });
  if (!hasPorts) mdContent += "| - | - | - | - | - |\n";
  mdContent += "\n";

  mdContent += "## Signals\n\n";
  mdContent += "| Name | Type | Width | Description |\n";
  mdContent += "|------|------|-------|-------------|\n";
  let hasSignals = false;
  lines.forEach((line, index) => {
    if (/^\s*(input|output|inout)/.test(line)) return;
    const signalRegex = /^\s*(wire|reg|logic)\s+(?:\[(.*?)\]\s+)?(\w+)/;
    const signalMatch = line.match(signalRegex);
    if (!signalMatch) return;
    const type = signalMatch[1];
    const width = signalMatch[2] || "1";
    const name = signalMatch[3];
    if (portNames.has(name)) return;
    hasSignals = true;
    const desc = line.includes("//") ? line.split("//")[1].trim() : extractComment(lines, index);
    mdContent += `| \`${name}\` | ${type} | \`${width}\` | ${desc} |\n`;
  });
  if (!hasSignals) mdContent += "| - | - | - | - |\n";
  mdContent += "\n";

  mdContent += "## Assign Statements\n\n";
  mdContent += "| Target | Logic | Description |\n";
  mdContent += "|--------|-------|-------------|\n";
  let hasAssigns = false;
  lines.forEach((line, index) => {
    const assignMatch = line.match(/^\s*assign\s+(.*?)\s*=\s*(.*?);/);
    if (!assignMatch) return;
    hasAssigns = true;
    const desc = line.includes("//") ? line.split("//")[1].trim() : extractComment(lines, index);
    mdContent += `| \`${assignMatch[1].trim()}\` | \`${assignMatch[2].trim()}\` | ${desc} |\n`;
  });
  if (!hasAssigns) mdContent += "| - | - | - |\n";
  mdContent += "\n";

  mdContent += "## Always Blocks\n\n";
  let alwaysCount = 0;
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    const alwaysMatch = line.match(/^\s*always\s*@\s*(.*)/);
    if (!alwaysMatch) continue;

    const sensitivity = alwaysMatch[1].trim();
    const desc = extractComment(lines, i) || "Sequential Logic";
    const blockLines = [];
    let depth = 0;
    let foundBegin = false;
    let j = i;

    for (; j < lines.length; j += 1) {
      const blockLine = lines[j];
      blockLines.push(blockLine);
      const cleanLine = blockLine.split("//")[0].trim();
      const begins = (cleanLine.match(/\bbegin\b/g) || []).length;
      const ends = (cleanLine.match(/\bend\b/g) || []).length;
      if (begins > 0) foundBegin = true;
      depth += begins - ends;
      if (foundBegin) {
        if (depth <= 0 && ends > 0) break;
      } else if (cleanLine.includes(";")) {
        if (!(j === i && !cleanLine.includes(";"))) break;
      }
    }

    alwaysCount += 1;
    mdContent += `### Always Block ${alwaysCount}\n`;
    mdContent += `- **Sensitivity**: \`${sensitivity}\`\n`;
    mdContent += `- **Description**: ${desc}\n\n`;
    mdContent += "```verilog\n";
    mdContent += `${blockLines.join("\n")}\n`;
    mdContent += "```\n\n";
    i = j;
  }
  if (alwaysCount === 0) mdContent += "*No always blocks defined.*\n\n";

  mdContent += "## Functions\n\n";
  let funcCount = 0;
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    const funcMatch = line.match(/^\s*function\s+(?:automatic\s+)?(?:(integer|real|time|shortint|int|longint|byte|bit|logic|reg|signed|unsigned|\[.*?\])\s+)?(\w+)/);
    if (!funcMatch) continue;
    const retType = funcMatch[1] || "default";
    const name = funcMatch[2];
    const desc = extractComment(lines, i);
    const blockLines = [];
    let j = i;
    for (; j < lines.length; j += 1) {
      blockLines.push(lines[j]);
      if (lines[j].trim().startsWith("endfunction")) break;
    }
    mdContent += `### Function: \`${name}\`\n`;
    mdContent += `- **Return Type**: \`${retType}\`\n`;
    mdContent += `- **Description**: ${desc}\n\n`;
    mdContent += "```verilog\n";
    mdContent += `${blockLines.join("\n")}\n`;
    mdContent += "```\n\n";
    funcCount += 1;
    i = j;
  }
  if (funcCount === 0) mdContent += "*No functions defined.*\n\n";

  mdContent += "## Sub-modules\n\n";
  const instRegex = /^\s*(\w+)\s+(?:#\s*\([\s\S]*?\)\s*)?(\w+)/gm;
  const invalidKeywords = new Set([
    "module", "endmodule", "primitive", "endprimitive", "config", "endconfig",
    "library", "design", "instance", "generate", "endgenerate", "genvar",
    "package", "endpackage", "program", "endprogram", "interface", "endinterface",
    "function", "endfunction", "task", "endtask", "always", "initial", "final",
    "assign", "defparam", "alias", "input", "output", "inout", "ref", "wire",
    "tri", "tri0", "tri1", "supply0", "supply1", "wand", "triand", "wor", "trior",
    "reg", "logic", "bit", "byte", "shortint", "int", "longint", "integer", "real",
    "realtime", "time", "parameter", "localparam", "specparam", "if", "else", "case",
    "casex", "casez", "endcase", "default", "forever", "repeat", "while", "for", "do",
    "begin", "end", "fork", "join", "join_any", "join_none", "wait", "disable",
    "sequence", "endsequence", "property", "endproperty", "assert", "cover", "assume",
    "clocking", "endclocking", "import", "export", "context", "pure",
  ]);
  const submodules = [];
  let instMatch = null;
  while ((instMatch = instRegex.exec(content)) !== null) {
    if (invalidKeywords.has(instMatch[1])) continue;
    const submoduleName = instMatch[1];
    const instanceName = instMatch[2];
    const sourceLink = getSubmoduleSourceLink(context, submoduleName);
    if (sourceLink) {
      submodules.push(`- [**${submoduleName}**](${sourceLink}) (${instanceName})`);
    } else {
      submodules.push(`- **${submoduleName}** (${instanceName})`);
    }
  }
  mdContent += submodules.length > 0
    ? `${submodules.join("\n")}\n\n`
    : "*No sub-modules instantiated.*\n\n";

  ensureDir(docDir);
  const outPath = path.join(docDir, `${moduleName}.md`);
  fs.writeFileSync(outPath, mdContent, "utf8");

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
    fsmDrawioPath,
  };
}

function generateFsmIndex(context, docItems) {
  const fsmItems = (docItems || []).filter((item) =>
    item &&
    item.hasFsmSection &&
    (item.hasFsmSvg || item.hasFsmDrawio)
  );
  if (fsmItems.length === 0) return "";

  const { docDir } = context.directories;
  let indexMd = "# FSM Index\n\n";
  indexMd += "자동 감지된 FSM 모듈의 다이어그램/문서 링크입니다.\n\n";
  indexMd += "## Modules\n\n";

  fsmItems
    .sort((a, b) => a.moduleName.localeCompare(b.moduleName))
    .forEach((item) => {
      const docRel = path.relative(docDir, item.docPath).replace(/\\/g, "/");
      indexMd += `### ${item.moduleName}\n`;
      indexMd += `- Module Doc: [${path.basename(item.docPath)}](${docRel})\n`;
      if (item.hasSimpleSvg) {
        const rel = path.relative(docDir, item.simpleSvgPath).replace(/\\/g, "/");
        indexMd += `- Simple SVG: [${path.basename(item.simpleSvgPath)}](${rel})\n`;
      }
      if (item.hasSimpleDrawio) {
        const rel = path.relative(docDir, item.simpleDrawioPath).replace(/\\/g, "/");
        indexMd += `- Simple Draw.io: [${path.basename(item.simpleDrawioPath)}](${rel})\n`;
      }
      if (item.hasFsmSvg) {
        const rel = path.relative(docDir, item.fsmSvgPath).replace(/\\/g, "/");
        indexMd += `- FSM SVG: [${path.basename(item.fsmSvgPath)}](${rel})\n`;
        indexMd += `- Preview:\n\n![${item.moduleName} FSM](${rel})\n\n`;
      }
      if (item.hasFsmDrawio) {
        const rel = path.relative(docDir, item.fsmDrawioPath).replace(/\\/g, "/");
        indexMd += `- FSM Draw.io: [${path.basename(item.fsmDrawioPath)}](${rel})\n`;
      }
      indexMd += "\n";
    });

  const outPath = path.join(docDir, "fsm_index.md");
  fs.writeFileSync(outPath, indexMd, "utf8");
  return outPath;
}

function writeDocumentationSummary(context, manifestJsonPath, docItems, fsmIndexPath) {
  const summaryPath = path.join(context.directories.outputDir, "report_doc_summary.json");
  const artifacts = docItems.map((item) =>
    createArtifactRecord({ kind: "module_doc_markdown", path: item.docPath, label: item.moduleName })
  );
  if (fsmIndexPath) {
    artifacts.push(createArtifactRecord({ kind: "fsm_index_markdown", path: fsmIndexPath }));
  }

  const summary = createRunSummary({
    tool: "report_doc",
    projectRoot: context.projectRoot,
    manifestJsonPath,
    status: "ok",
    artifacts,
    details: {
      documentCount: docItems.length,
      fsmIndexPath: normalizeSlashes(fsmIndexPath),
    },
  });
  const writtenSummaryPath = writeJsonFile(summaryPath, summary);
  appendRunEntry(context.projectRoot, {
    tool: "report_doc",
    projectRoot: context.projectRoot,
    manifestJsonPath,
    status: "ok",
    outputs: artifacts,
    summaryPath: writtenSummaryPath,
    metadata: {
      projectName: path.basename(context.projectRoot),
      regressionCount: 0,
    },
  });
  return writtenSummaryPath;
}

function generateDocumentationArtifacts(context, selectedEntries, manifestJsonPath = "") {
  ensureDir(context.directories.docDir);
  const docItems = [];
  (selectedEntries || []).forEach((entry) => {
    const filePath = typeof entry === "string" ? entry : entry.absPath;
    docItems.push(generateMarkdown(context, filePath));
  });
  const fsmIndexPath = generateFsmIndex(context, docItems);
  const summaryPath = writeDocumentationSummary(context, manifestJsonPath, docItems, fsmIndexPath);

  return {
    docItems,
    fsmIndexPath,
    summaryPath,
  };
}

module.exports = {
  createDocumentationContext,
  listDocumentationCandidates,
  selectDocumentationCandidates,
  generateDocumentationArtifacts,
};
