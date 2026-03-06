const fs = require("fs");
const path = require("path");
const {
  buildIndex,
  writeIndex,
} = require("../../code_intel/application/hdl_index_builder");
const {
  ensureDir,
  writeJsonFile,
} = require("../../../shared/application/json_file_service");
const { appendRunEntry } = require("../../../shared/application/run_registry_service");
const {
  createRunSummary,
  createArtifactRecord,
} = require("../../../shared/domain/run_contracts");
const {
  normalizeSlashes,
  relFromProject,
  parseTbInfo,
  analyzeOneSourceDocuments,
  buildHierarchyTree,
  buildDirectoryTreeSnippet,
  renderOneSourceMarkdown,
} = require("../domain/one_source_report_domain");

const DIRECTORY_TREE_NAMES = ["src", "tb", "constrs", "ip", "output", "waveform", "Presentation"];

function normalizeFileList(values) {
  return Array.from(
    new Set(
      (values || [])
        .map((value) => path.resolve(value))
        .filter((value) => /\.(v|sv)$/i.test(value))
    )
  ).sort((a, b) => a.localeCompare(b));
}

function createOneSourceReportContext({ projectRoot, sourceFiles = [], tbFiles = [] } = {}) {
  const root = path.resolve(projectRoot || process.cwd());
  const normalizedSourceFiles = normalizeFileList(sourceFiles);
  const normalizedTbFiles = normalizeFileList(tbFiles);

  return {
    projectRoot: root,
    sourceFiles: normalizedSourceFiles,
    tbFiles: normalizedTbFiles,
    tbInfoCache: new Map(),
    directories: {
      outputDir: path.join(root, "output"),
      docsDir: path.join(root, "output", "docs"),
      reportMdPath: path.join(root, "output", "docs", "report.md"),
      githubCssPath: path.join(root, "output", "docs", "github.css"),
      cacheDir: path.join(root, "output", "cache"),
    },
  };
}

function readSourceDocuments(context) {
  return (context.sourceFiles || []).map((absPath) => ({
    absPath,
    raw: fs.readFileSync(absPath, "utf8"),
  }));
}

function listOneSourceModules(context) {
  const sourceDocuments = readSourceDocuments(context);
  const analysis = analyzeOneSourceDocuments({
    projectRoot: context.projectRoot,
    sourceDocuments,
  });
  return Array.from(new Set(analysis.allModules.map((mod) => mod.moduleName))).sort((a, b) => a.localeCompare(b));
}

function ensureGithubCss(context) {
  ensureDir(context.directories.docsDir);
  const css = [
    "body {",
    '  font-family: "Malgun Gothic", "Apple SD Gothic Neo", "Noto Sans KR", Arial, sans-serif;',
    "  font-size: 10.5pt;",
    "  line-height: 1.65;",
    "  color: #1a1d23;",
    "  max-width: 1100px;",
    "  margin: 0 auto;",
    "  padding: 32px 40px;",
    "  background: #ffffff;",
    "}",
    "",
    "/* Headings */",
    "h1 {",
    "  font-size: 22pt;",
    "  color: #1F3864;",
    "  font-weight: 800;",
    "  border-bottom: 3px solid #1F3864;",
    "  padding-bottom: 10px;",
    "  margin-top: 1.5em;",
    "  margin-bottom: 0.6em;",
    "  letter-spacing: -0.5px;",
    "}",
    "h2 {",
    "  font-size: 15pt;",
    "  color: #2E5599;",
    "  font-weight: 700;",
    "  border-left: 5px solid #2E5599;",
    "  padding-left: 12px;",
    "  margin-top: 2em;",
    "  margin-bottom: 0.5em;",
    "}",
    "h3 {",
    "  font-size: 12pt;",
    "  color: #2F5496;",
    "  font-weight: 700;",
    "  margin-top: 1.4em;",
    "  margin-bottom: 0.4em;",
    "  padding-bottom: 3px;",
    "  border-bottom: 1px solid #c8d8f0;",
    "}",
    "h4 {",
    "  font-size: 10.5pt;",
    "  color: #4472C4;",
    "  font-weight: 600;",
    "  margin-top: 1.1em;",
    "  margin-bottom: 0.3em;",
    "}",
    "",
    "p { margin: 0.5em 0; }",
    "li { margin: 0.25em 0; }",
    "ul, ol { padding-left: 1.6em; }",
    "",
    ".cover-table { width: 60%; margin: 30px auto; border-collapse: collapse; font-size: 11pt; }",
    ".cover-table td { padding: 10px 18px; border: 1px solid #c5d0e0; }",
    ".cover-table td:first-child { background: #EEF2F9; font-weight: 700; width: 36%; color: #2E5599; }",
    "",
    "table {",
    "  border-collapse: collapse;",
    "  width: 100%;",
    "  margin: 12px 0 22px;",
    "  font-size: 10pt;",
    "}",
    "th {",
    "  background: #2E5599;",
    "  color: #ffffff;",
    "  font-weight: 700;",
    "  padding: 8px 12px;",
    "  border: 1px solid #1F3864;",
    "  text-align: left;",
    "}",
    "td {",
    "  border: 1px solid #d0d9e8;",
    "  padding: 6px 12px;",
    "  vertical-align: top;",
    "}",
    "tr:nth-child(even) td { background: #f5f7fc; }",
    "",
    "code {",
    '  font-family: "D2Coding", "Consolas", "Courier New", monospace;',
    "  font-size: 9.5pt;",
    "  background: #F0F4FA;",
    "  color: #2C3E70;",
    "  padding: 2px 6px;",
    "  border-radius: 4px;",
    "  border: 1px solid #d0d9ea;",
    "}",
    "pre {",
    "  background: #1e2233;",
    "  color: #e0e8ff;",
    "  padding: 16px 20px;",
    "  border-radius: 6px;",
    "  overflow-x: auto;",
    "  font-size: 9pt;",
    "  line-height: 1.55;",
    "  margin: 12px 0 20px;",
    "  border-left: 4px solid #4472C4;",
    "}",
    "pre code {",
    "  background: transparent;",
    "  border: none;",
    "  padding: 0;",
    "  color: inherit;",
    "  font-size: inherit;",
    "}",
    "",
    "blockquote {",
    "  background: #EEF4FF;",
    "  border-left: 5px solid #4472C4;",
    "  margin: 14px 0;",
    "  padding: 10px 18px;",
    "  border-radius: 0 6px 6px 0;",
    "  color: #2C3E70;",
    "  font-size: 10pt;",
    "}",
    "",
    "hr {",
    "  border: none;",
    "  border-top: 2px solid #d0daea;",
    "  margin: 28px 0;",
    "}",
    "",
    "img { max-width: 100%; height: auto; border-radius: 4px; box-shadow: 0 1px 4px rgba(0,0,0,0.12); }",
    "",
    "@media print {",
    "  body { max-width: none; padding: 20px; }",
    "  h1, h2 { page-break-after: avoid; }",
    "  pre, blockquote { page-break-inside: avoid; }",
    "}",
    "",
  ].join("\n");
  fs.writeFileSync(context.directories.githubCssPath, css, "utf8");
  return context.directories.githubCssPath;
}

function findFirstExisting(paths) {
  for (const targetPath of paths) {
    if (!targetPath) continue;
    if (typeof targetPath !== "string") continue;
    if (fs.existsSync(targetPath)) return targetPath;
  }
  return null;
}

function findCaseInsensitiveInDir(dirPath, candidateNames) {
  if (!fs.existsSync(dirPath)) return null;
  const entries = fs.readdirSync(dirPath);
  const lowerMap = new Map(entries.map((name) => [name.toLowerCase(), name]));

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
  const hit = entries.find((entry) => entry.isDirectory() && entry.name.toLowerCase() === dirName.toLowerCase());
  return hit ? path.join(rootDir, hit.name) : null;
}

function toProjectRelative(context, targetPath) {
  if (!targetPath) return "";
  return relFromProject(context.projectRoot, targetPath);
}

function collectAssets(context, moduleName) {
  const outputDir = context.directories.outputDir;
  const simpleRootDir = path.join(outputDir, "Diagram", "Simple");
  const detailedRootDir = path.join(outputDir, "Diagram", "Detailed");
  const fsmRootDir = path.join(outputDir, "fsm");

  const simpleModuleDir = findCaseInsensitiveDir(simpleRootDir, moduleName) || path.join(simpleRootDir, moduleName);
  const detailedModuleDir = findCaseInsensitiveDir(detailedRootDir, moduleName) || path.join(detailedRootDir, moduleName);
  const fsmModuleDir = findCaseInsensitiveDir(fsmRootDir, moduleName) || path.join(fsmRootDir, moduleName);

  const oldFsmSvgDir = path.join(outputDir, "fsm", "svg");
  const oldFsmDrawioDir = path.join(outputDir, "fsm", "drawio");
  const oldPngDir = path.join(outputDir, "Diagram", "png");

  const simple = findFirstExisting([
    findCaseInsensitiveInDir(simpleModuleDir, [
      `${moduleName}.png`,
      `${moduleName}.svg`,
      `${moduleName}.drawio`,
    ]),
    findCaseInsensitiveInDir(simpleRootDir, [
      `${moduleName}.png`,
      `${moduleName}.svg`,
      `${moduleName}.drawio`,
    ]),
    findCaseInsensitiveInDir(oldPngDir, [
      `${moduleName}.png`,
      `${moduleName}_simple.png`,
    ]),
  ]);

  const detailed = findFirstExisting([
    findCaseInsensitiveInDir(detailedModuleDir, [
      `${moduleName}.png`,
      `${moduleName}.svg`,
      `${moduleName}.drawio`,
    ]),
    findCaseInsensitiveInDir(detailedRootDir, [
      `${moduleName}.png`,
      `${moduleName}.svg`,
      `${moduleName}.drawio`,
      `${moduleName}_detailed.svg`,
      `${moduleName}_detailed.drawio`,
    ]),
    findCaseInsensitiveInDir(oldPngDir, [`${moduleName}_detailed.png`]),
  ]);

  const fsm = findFirstExisting([
    findCaseInsensitiveInDir(fsmModuleDir, [
      `${moduleName}_fsm.png`,
      `${moduleName}_fsm.svg`,
      `${moduleName}_fsm.drawio`,
    ]),
    findCaseInsensitiveInDir(oldFsmSvgDir, [`${moduleName}_fsm.svg`]),
    findCaseInsensitiveInDir(oldFsmDrawioDir, [`${moduleName}_fsm.drawio`]),
    findCaseInsensitiveInDir(oldPngDir, [`${moduleName}_fsm.png`]),
  ]);

  return {
    simple: simple ? toProjectRelative(context, simple) : null,
    detailed: detailed ? toProjectRelative(context, detailed) : null,
    fsm: fsm ? toProjectRelative(context, fsm) : null,
  };
}

function collectWaveformPaths(context, moduleName) {
  const waveformRootDir = path.join(context.projectRoot, "waveform");
  const waveformModuleDir = findCaseInsensitiveDir(waveformRootDir, moduleName) || path.join(waveformRootDir, moduleName);
  const expectedBase = `tb_${moduleName}`.toLowerCase();
  const matchedTbPath = (context.tbFiles || []).find((absPath) => {
    const base = path.basename(absPath, path.extname(absPath)).toLowerCase();
    return base === expectedBase;
  }) || null;

  const tbBaseName = matchedTbPath
    ? path.basename(matchedTbPath, path.extname(matchedTbPath))
    : `tb_${moduleName}`;
  const tbLogDir = matchedTbPath ? path.dirname(matchedTbPath) : context.projectRoot;
  const outputDir = context.directories.outputDir;

  const candidates = [
    path.join(outputDir, `${moduleName}.vcd`),
    path.join(outputDir, `${tbBaseName}.vcd`),
    path.join(outputDir, `${tbBaseName}.gtkw`),
    path.join(outputDir, `${tbBaseName}.sim.log`),
    path.join(tbLogDir, `${tbBaseName}.out`),
    path.join(tbLogDir, `.run_${tbBaseName}.out`),
    path.join(outputDir, "FINALReport", "wavedrom_cases.json"),
  ];

  const existing = candidates
    .filter((targetPath) => fs.existsSync(targetPath))
    .map((targetPath) => toProjectRelative(context, targetPath));

  const expected = matchedTbPath && fs.existsSync(matchedTbPath)
    ? [
        toProjectRelative(context, matchedTbPath),
        normalizeSlashes(path.join("output", `${tbBaseName}.vcd`)),
        normalizeSlashes(path.join("output", `${tbBaseName}.gtkw`)),
      ]
    : [];

  const imagePaths = fs.existsSync(waveformModuleDir)
    ? fs.readdirSync(waveformModuleDir, { withFileTypes: true })
      .filter((entry) => entry.isFile() && /\.(png|jpg|jpeg|gif|webp|svg)$/i.test(entry.name))
      .map((entry) => path.join(waveformModuleDir, entry.name))
      .sort((a, b) => a.localeCompare(b))
      .map((targetPath) => toProjectRelative(context, targetPath))
    : [];

  return {
    existing,
    imagePaths,
    expected,
    tbSource: matchedTbPath && fs.existsSync(matchedTbPath) ? toProjectRelative(context, matchedTbPath) : null,
    tbName: tbBaseName,
  };
}

function getTbInfoFromRelPath(context, tbRelPath) {
  if (!tbRelPath) return null;
  if (context.tbInfoCache.has(tbRelPath)) return context.tbInfoCache.get(tbRelPath);

  const absPath = path.resolve(context.projectRoot, tbRelPath);
  if (!fs.existsSync(absPath)) {
    context.tbInfoCache.set(tbRelPath, null);
    return null;
  }

  const raw = fs.readFileSync(absPath, "utf8");
  const fallbackName = path.basename(absPath, path.extname(absPath));
  const info = parseTbInfo(raw, fallbackName);
  context.tbInfoCache.set(tbRelPath, info);
  return info;
}

function collectConstraintFiles(context) {
  const constrDir = path.join(context.projectRoot, "constrs");
  if (!fs.existsSync(constrDir)) return [];
  return fs.readdirSync(constrDir, { withFileTypes: true })
    .filter((entry) => entry.isFile() && /\.(xdc|sdc)$/i.test(entry.name))
    .map((entry) => normalizeSlashes(path.join("constrs", entry.name)))
    .sort((a, b) => a.localeCompare(b));
}

function listPresentProjectDirectories(context) {
  return DIRECTORY_TREE_NAMES.filter((dirName) => fs.existsSync(path.join(context.projectRoot, dirName)));
}

function generateHdlIndexCache(context, manifestJsonPath) {
  const outPath = path.join(context.directories.cacheDir, "hdl_index.json");
  ensureDir(context.directories.cacheDir);
  const index = buildIndex(context.projectRoot, { manifestJsonPath });
  writeIndex(index, outPath);
  return outPath;
}

function writeOneSourceSummary(context, manifestJsonPath, result) {
  const summaryPath = path.join(context.directories.outputDir, "report_one_source_summary.json");
  const artifacts = [
    createArtifactRecord({
      kind: "report_markdown",
      path: normalizeSlashes(path.join("output", "docs", "report.md")),
      label: "report.md",
    }),
    createArtifactRecord({
      kind: "report_stylesheet",
      path: normalizeSlashes(path.join("output", "docs", "github.css")),
      label: "github.css",
    }),
  ];

  if (result.hdlIndexPath) {
    artifacts.push(
      createArtifactRecord({
        kind: "hdl_index_cache",
        path: normalizeSlashes(path.join("output", "cache", "hdl_index.json")),
        label: "hdl_index.json",
      })
    );
  }

  const summary = createRunSummary({
    tool: "report_one_source",
    projectRoot: normalizeSlashes(context.projectRoot),
    manifestJsonPath: normalizeSlashes(manifestJsonPath),
    status: "ok",
    warnings: result.warnings,
    artifacts,
    details: {
      topModule: result.topModule || "",
      moduleCountAll: result.moduleCountAll,
      moduleCountSelected: result.moduleCountSelected,
      selectedModuleNames: result.selectedModuleNames,
      unknownModules: result.unknownModules,
    },
  });
  const writtenSummaryPath = writeJsonFile(summaryPath, summary);

  appendRunEntry(context.projectRoot, {
    tool: "report_one_source",
    projectRoot: context.projectRoot,
    manifestJsonPath,
    status: "ok",
    outputs: artifacts,
    summaryPath: writtenSummaryPath,
    metadata: {
      topModule: result.topModule || "",
      moduleCountAll: result.moduleCountAll,
      moduleCountSelected: result.moduleCountSelected,
    },
  });

  return writtenSummaryPath;
}

function createReportModel(context, analysis) {
  const topModule = analysis.hierarchy.topModule;
  const topModuleObj = analysis.allModules.find((mod) => mod.moduleName === topModule) || null;
  const topClocks = topModuleObj
    ? topModuleObj.ports.filter((port) => /clk|clock/i.test(port.name)).map((port) => port.name)
    : [];
  const topResets = topModuleObj
    ? topModuleObj.ports.filter((port) => /rst|reset/i.test(port.name)).map((port) => port.name)
    : [];

  const modules = analysis.selectedModules.map((mod) => {
    const wave = collectWaveformPaths(context, mod.moduleName);
    return {
      ...mod,
      isTopModule: Boolean(topModule) && mod.moduleName.toLowerCase() === topModule.toLowerCase(),
      assets: collectAssets(context, mod.moduleName),
      wave,
      tbInfo: getTbInfoFromRelPath(context, wave.tbSource),
    };
  });

  return {
    projectName: path.basename(context.projectRoot),
    todayKo: new Date().toLocaleDateString("ko-KR", { year: "numeric", month: "long", day: "numeric" }),
    generatedAtIso: new Date().toISOString(),
    generatedAtKo: new Date().toLocaleString("ko-KR", { timeZone: "Asia/Seoul" }),
    topModule,
    allModules: analysis.allModules,
    modules,
    topClocks,
    topResets,
    topAssets: topModule ? collectAssets(context, topModule) : null,
    hierarchyTree: buildHierarchyTree(topModule, analysis.hierarchy.moduleMap),
    directoryTree: buildDirectoryTreeSnippet(listPresentProjectDirectories(context)),
    constraintFiles: collectConstraintFiles(context),
  };
}

function generateOneSourceReport({
  context,
  manifestJsonPath = "",
  selectedModuleNames = null,
  generateHdlIndex = true,
} = {}) {
  const sourceDocuments = readSourceDocuments(context);
  const analysis = analyzeOneSourceDocuments({
    projectRoot: context.projectRoot,
    sourceDocuments,
    selectedModuleNames,
  });

  if (analysis.selectedModules.length === 0) {
    const err = new Error("No modules selected for report generation.");
    err.unknownModules = analysis.unknownModules;
    throw err;
  }

  ensureDir(context.directories.docsDir);
  const warnings = [];
  if (analysis.unknownModules.length > 0) {
    warnings.push(`ignored unknown modules: ${analysis.unknownModules.join(", ")}`);
  }

  let hdlIndexPath = "";
  if (generateHdlIndex) {
    try {
      hdlIndexPath = generateHdlIndexCache(context, manifestJsonPath);
    } catch (err) {
      warnings.push(`hdl_index_generation_skipped: ${err.message}`);
    }
  }

  ensureGithubCss(context);
  const reportModel = createReportModel(context, analysis);
  const markdown = renderOneSourceMarkdown(reportModel);
  fs.writeFileSync(context.directories.reportMdPath, markdown, "utf8");

  const selectedNames = reportModel.modules.map((mod) => mod.moduleName);
  const result = {
    reportMdPath: context.directories.reportMdPath,
    githubCssPath: context.directories.githubCssPath,
    hdlIndexPath,
    topModule: reportModel.topModule || "",
    moduleCountAll: analysis.allModules.length,
    moduleCountSelected: analysis.selectedModules.length,
    selectedModuleNames: selectedNames,
    unknownModules: analysis.unknownModules,
    warnings,
  };
  result.summaryPath = writeOneSourceSummary(context, manifestJsonPath, result);
  return result;
}

module.exports = {
  createOneSourceReportContext,
  listOneSourceModules,
  generateOneSourceReport,
};
