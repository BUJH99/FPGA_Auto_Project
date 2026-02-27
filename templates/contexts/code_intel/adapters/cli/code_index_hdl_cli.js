const fs = require("fs");
const path = require("path");

let manifestResolver = null;
try {
  manifestResolver = require("../../../manifest/application/manifest_context_service");
} catch {
  manifestResolver = null;
}

function parseArgs(argv) {
  const opts = {
    projectRoot: null,
    write: false,
    out: null,
    list: null,
    pretty: false,
    strict: false,
  };

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--write") {
      opts.write = true;
      continue;
    }
    if (a === "--pretty") {
      opts.pretty = true;
      continue;
    }
    if (a === "--strict") {
      opts.strict = true;
      continue;
    }
    if (a === "--out") {
      opts.out = argv[++i];
      continue;
    }
    if (a.startsWith("--out=")) {
      opts.out = a.slice("--out=".length);
      continue;
    }
    if (a === "--list-rtl") {
      opts.list = "rtl";
      continue;
    }
    if (a === "--list-tb") {
      opts.list = "tb";
      continue;
    }
    if (a === "--list-hdl") {
      opts.list = "hdl";
      continue;
    }
    if (a === "--list-include-dirs") {
      opts.list = "includeDirs";
      continue;
    }
    if (a === "--json") {
      opts.list = null;
      continue;
    }
    if (!a.startsWith("--") && !opts.projectRoot) {
      opts.projectRoot = a;
      continue;
    }
    throw new Error(`Unknown argument: ${a}`);
  }

  opts.projectRoot = path.resolve(opts.projectRoot || process.cwd());
  return opts;
}

function normalizeSlashes(p) {
  return p.replace(/\\/g, "/");
}

function rel(base, abs) {
  return normalizeSlashes(path.relative(base, abs));
}

function ensureDir(dirPath) {
  if (!fs.existsSync(dirPath)) fs.mkdirSync(dirPath, { recursive: true });
}

function stripCommentsPreserveLines(text) {
  const noBlock = text.replace(/\/\*[\s\S]*?\*\//g, (m) => {
    return m.replace(/[^\n]/g, " ");
  });
  return noBlock.replace(/\/\/.*$/gm, "");
}

function stripPreprocessorDirectivesPreserveLines(text) {
  return text.replace(/^\s*`[^\r\n]*/gm, (m) => m.replace(/[^\r\n]/g, " "));
}

function detectParserProvider() {
  try {
    const Parser = require("tree-sitter");
    const Verilog = require("tree-sitter-verilog");
    return {
      name: "tree-sitter-verilog",
      parse(text) {
        const parser = new Parser();
        parser.setLanguage(Verilog);
        return parser.parse(text);
      },
    };
  } catch {
    return null;
  }
}

function collectFiles(rootDir, roleHint, result, warnings) {
  if (!fs.existsSync(rootDir)) return;
  const stack = [rootDir];
  while (stack.length > 0) {
    const cur = stack.pop();
    let entries = [];
    try {
      entries = fs.readdirSync(cur, { withFileTypes: true });
    } catch (e) {
      warnings.push({
        type: "read_dir_failed",
        path: normalizeSlashes(cur),
        message: e.message,
      });
      continue;
    }
    entries.sort((a, b) => a.name.localeCompare(b.name));
    for (const entry of entries) {
      const abs = path.join(cur, entry.name);
      if (entry.isDirectory()) {
        stack.push(abs);
        continue;
      }
      if (!entry.isFile()) continue;
      if (!/\.(v|sv|svh)$/i.test(entry.name)) continue;
      const ext = path.extname(entry.name).toLowerCase();
      const kind = ext === ".svh" ? "header" : (roleHint === "tb" ? "tb" : "rtl");
      result.push({
        absPath: abs,
        ext,
        kind,
      });
    }
  }
}

function parseDeclarations(cleanText) {
  const declarations = [];
  const patterns = [
    { type: "module", re: /\bmodule\s+(?:automatic\s+|static\s+)?([A-Za-z_][A-Za-z0-9_$]*)\b/g },
    { type: "interface", re: /\binterface\s+([A-Za-z_][A-Za-z0-9_$]*)\b/g },
    { type: "package", re: /\bpackage\s+([A-Za-z_][A-Za-z0-9_$]*)\b/g },
    { type: "program", re: /\bprogram\s+(?:automatic\s+|static\s+)?([A-Za-z_][A-Za-z0-9_$]*)\b/g },
    { type: "class", re: /\bclass\s+(?:automatic\s+|static\s+)?([A-Za-z_][A-Za-z0-9_$]*)\b/g },
    { type: "checker", re: /\bchecker\s+([A-Za-z_][A-Za-z0-9_$]*)\b/g },
  ];

  for (const { type, re } of patterns) {
    let m;
    while ((m = re.exec(cleanText)) !== null) {
      declarations.push({
        type,
        name: m[1],
        offset: m.index,
      });
    }
  }
  declarations.sort((a, b) =>
    (a.offset - b.offset) || a.type.localeCompare(b.type) || a.name.localeCompare(b.name)
  );
  return declarations;
}

function parseIncludes(rawText) {
  const includes = [];
  const re = /`include\s+"([^"]+)"/g;
  let m;
  while ((m = re.exec(rawText)) !== null) {
    includes.push(m[1]);
  }
  return includes;
}

function detectSvFeatures(cleanText) {
  return {
    always_ff: /\balways_ff\b/.test(cleanText),
    always_comb: /\balways_comb\b/.test(cleanText),
    always_latch: /\balways_latch\b/.test(cleanText),
    typedef_enum: /\btypedef\s+enum\b/.test(cleanText),
    logic: /\blogic\b/.test(cleanText),
    modport: /\bmodport\b/.test(cleanText),
    import_pkg: /\bimport\s+[A-Za-z_][A-Za-z0-9_$]*\s*::/.test(cleanText),
  };
}

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function parseInstances(cleanText, moduleNames) {
  const instances = [];
  for (const modName of moduleNames) {
    const escapedModName = escapeRegExp(modName);
    const re = new RegExp(
      `\\b${escapedModName}\\b\\s*(?:#\\s*\\([\\s\\S]*?\\)\\s*)?([A-Za-z_][A-Za-z0-9_$]*)\\s*\\(`,
      "g"
    );
    let m;
    while ((m = re.exec(cleanText)) !== null) {
      instances.push({ moduleName: modName, instName: m[1] || "" });
    }
  }
  return instances;
}

function parseModuleBlocks(cleanText) {
  const blocks = [];
  const re = /\bmodule\s+(?:automatic\s+|static\s+)?([A-Za-z_][A-Za-z0-9_$]*)\b[\s\S]*?\bendmodule\b/g;
  let m;
  while ((m = re.exec(cleanText)) !== null) {
    blocks.push({
      moduleName: m[1],
      text: m[0],
      offset: m.index,
    });
  }
  return blocks;
}

function inferProjectLanguage(fileInfos) {
  const hasV = fileInfos.some((f) => f.ext === ".v");
  const hasSv = fileInfos.some((f) => f.ext === ".sv" || f.ext === ".svh");
  if (hasV && hasSv) return "mixed";
  if (hasSv) return "systemverilog";
  return "verilog";
}

function containsInterfaceInstantiation(text, interfaceNames) {
  for (const name of interfaceNames) {
    const escaped = escapeRegExp(name);
    const re = new RegExp(`\\b${escaped}\\b\\s+[A-Za-z_][A-Za-z0-9_$]*\\s*\\(`);
    if (re.test(text)) return true;
  }
  return false;
}

function buildIndex(projectRoot, opts = {}) {
  const parserProvider = detectParserProvider();
  const warnings = [];
  let files = [];

  const addResolvedFileEntries = (entries, roleHint) => {
    for (const relPath of entries || []) {
      const abs = path.resolve(projectRoot, relPath);
      if (!fs.existsSync(abs)) {
        warnings.push({
          type: "manifest_resolved_missing",
          path: normalizeSlashes(relPath),
          message: `Manifest-resolved path does not exist: ${relPath}`,
        });
        continue;
      }
      let st = null;
      try {
        st = fs.statSync(abs);
      } catch (e) {
        warnings.push({
          type: "manifest_resolved_stat_failed",
          path: normalizeSlashes(relPath),
          message: e.message,
        });
        continue;
      }
      if (!st.isFile()) continue;
      if (!/\.(v|sv|svh)$/i.test(abs)) continue;
      const ext = path.extname(abs).toLowerCase();
      const kind = ext === ".svh" ? "header" : (roleHint === "tb" ? "tb" : "rtl");
      files.push({ absPath: abs, ext, kind });
    }
  };

  if (!manifestResolver || typeof manifestResolver.resolveManifestContext !== "function") {
    throw new Error("Manifest context service is unavailable for hdl_indexer.");
  }
  const manifestResult = manifestResolver.resolveManifestContext(projectRoot);
  const manifestRc = typeof manifestResolver.deriveExitCode === "function"
    ? manifestResolver.deriveExitCode(manifestResult)
    : (manifestResult.errors && manifestResult.errors.length > 0 ? 2 : 0);
  if (manifestRc !== 0 || (manifestResult.errors && manifestResult.errors.length > 0)) {
    const codes = (manifestResult.errors || []).map((e) => e.code).join(", ");
    throw new Error(`Manifest resolution failed for hdl_indexer: ${codes || "unknown_error"}`);
  }

  addResolvedFileEntries(manifestResult.resolved.src_files, "rtl");
  addResolvedFileEntries(manifestResult.resolved.tb_files, "tb");

  const resolvedIncDirs = Array.isArray(manifestResult.resolved.inc_dirs)
    ? manifestResult.resolved.inc_dirs
    : [];
  for (const incRel of resolvedIncDirs) {
    const incAbs = path.resolve(projectRoot, incRel);
    if (!fs.existsSync(incAbs)) continue;
    collectFiles(incAbs, "header", files, warnings);
  }

  files.sort((a, b) => a.absPath.localeCompare(b.absPath));
  const seenAbsPaths = new Set();
  files = files.filter((f) => {
    const norm = normalizeSlashes(f.absPath).toLowerCase();
    if (seenAbsPaths.has(norm)) return false;
    seenAbsPaths.add(norm);
    return true;
  });

  const fileRecords = [];
  const allDecls = [];
  const includeDirs = new Set();
  const hdlDirs = new Set();
  const astInputByPath = new Map();

  for (const f of files) {
    const raw = fs.readFileSync(f.absPath, "utf8");
    const clean = stripCommentsPreserveLines(raw);
    const decls = parseDeclarations(clean);
    const features = detectSvFeatures(clean);
    const includes = parseIncludes(raw);
    const fileWarnings = [];
    let ast = null;
    let astInputForChecks = "";
    if (parserProvider) {
      try {
        const astInput = stripPreprocessorDirectivesPreserveLines(clean);
        astInputForChecks = astInput;
        const tree = parserProvider.parse(astInput);
        ast = {
          provider: parserProvider.name,
          hasError: Boolean(tree.rootNode && tree.rootNode.hasError && tree.rootNode.hasError()),
        };
        if (ast.hasError) {
          fileWarnings.push({
            type: "ast_syntax_error",
            message: "AST parser reported syntax errors",
          });
        }
      } catch (e) {
        fileWarnings.push({
          type: "ast_parse_failed",
          message: e.message,
        });
      }
    } else {
      fileWarnings.push({
        type: "ast_provider_missing",
        message: "Optional AST parser dependencies (tree-sitter, tree-sitter-verilog) are not installed",
      });
    }

    const rec = {
      path: rel(projectRoot, f.absPath),
      absPath: normalizeSlashes(f.absPath),
      ext: f.ext,
      language: f.ext === ".v" ? "verilog" : "systemverilog",
      role: f.kind,
      includes,
      declarations: decls.map((d) => ({ type: d.type, name: d.name })),
      features,
      ast,
      warnings: fileWarnings,
    };
    fileRecords.push(rec);
    if (astInputForChecks) astInputByPath.set(rec.path, astInputForChecks);
    for (const d of decls) {
      allDecls.push({ ...d, file: rec.path });
    }
    hdlDirs.add(normalizeSlashes(path.dirname(f.absPath)));
    if (f.ext === ".svh") includeDirs.add(normalizeSlashes(path.dirname(f.absPath)));
  }

  const moduleNames = Array.from(
    new Set(allDecls.filter((d) => d.type === "module").map((d) => d.name))
  ).sort((a, b) => a.localeCompare(b));

  for (const rec of fileRecords) {
    const raw = fs.readFileSync(rec.absPath, "utf8");
    const clean = stripCommentsPreserveLines(raw);
    if (rec.role === "header") {
      rec.instances = [];
      continue;
    }

    const moduleBlocks = parseModuleBlocks(clean);
    if (moduleBlocks.length === 0) {
      rec.instances = parseInstances(clean, moduleNames);
      continue;
    }

    const scopedInstances = [];
    for (const block of moduleBlocks) {
      const found = parseInstances(block.text, moduleNames);
      for (const inst of found) {
        scopedInstances.push({
          parentName: block.moduleName,
          moduleName: inst.moduleName,
          instName: inst.instName,
        });
      }
    }
    rec.instances = scopedInstances;
  }

  const declMap = new Map();
  for (const d of allDecls) {
    const key = `${d.type}:${d.name}`.toLowerCase();
    if (declMap.has(key)) {
      warnings.push({
        type: "duplicate_declaration",
        declarationType: d.type,
        name: d.name,
        files: [declMap.get(key).file, d.file],
      });
    } else {
      declMap.set(key, d);
    }
  }

  const interfaceNames = Array.from(
    new Set(allDecls.filter((d) => d.type === "interface").map((d) => d.name))
  ).sort((a, b) => a.localeCompare(b));
  const packageNames = Array.from(
    new Set(allDecls.filter((d) => d.type === "package").map((d) => d.name))
  ).sort((a, b) => a.localeCompare(b));
  const programNames = Array.from(
    new Set(allDecls.filter((d) => d.type === "program").map((d) => d.name))
  ).sort((a, b) => a.localeCompare(b));
  const classNames = Array.from(
    new Set(allDecls.filter((d) => d.type === "class").map((d) => d.name))
  ).sort((a, b) => a.localeCompare(b));
  const checkerNames = Array.from(
    new Set(allDecls.filter((d) => d.type === "checker").map((d) => d.name))
  ).sort((a, b) => a.localeCompare(b));

  // tree-sitter-verilog has known false-positives on some SV interface instantiation patterns.
  // Downgrade those to non-fatal warnings so strict remains practical while still catching real syntax breaks.
  for (const rec of fileRecords) {
    if (!rec.warnings || rec.warnings.length === 0) continue;
    const hasAstSyntaxError = rec.warnings.some((w) => w.type === "ast_syntax_error");
    if (!hasAstSyntaxError) continue;
    const astInput = astInputByPath.get(rec.path) || "";
    if (!astInput) continue;
    if (!containsInterfaceInstantiation(astInput, interfaceNames)) continue;
    rec.warnings = rec.warnings.filter((w) => w.type !== "ast_syntax_error");
    rec.warnings.push({
      type: "ast_syntax_degraded",
      message: "AST parser limitation around interface instantiation; downgraded from syntax error",
    });
  }

  const graph = {};
  for (const mod of moduleNames) graph[mod] = [];
  for (const rec of fileRecords) {
    for (const inst of rec.instances || []) {
      const parents = inst.parentName ? [inst.parentName]
        : rec.declarations.filter((d) => d.type === "module").map((d) => d.name);
      for (const p of parents) {
        if (!graph[p]) graph[p] = [];
        if (inst.moduleName !== p) {
          graph[p].push(inst.moduleName);
        }
      }
    }
  }
  Object.keys(graph).forEach((k) => {
    graph[k] = Array.from(new Set(graph[k])).sort((a, b) => a.localeCompare(b));
  });

  const index = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    projectRoot: normalizeSlashes(projectRoot),
    parser: {
      astProvider: parserProvider ? parserProvider.name : null,
      astAvailable: Boolean(parserProvider),
      strictRequested: Boolean(opts.strict),
    },
    summary: {
      hdlLanguage: inferProjectLanguage(fileRecords),
      totalFiles: fileRecords.length,
      rtlFiles: fileRecords.filter((f) => f.role === "rtl").length,
      tbFiles: fileRecords.filter((f) => f.role === "tb").length,
      headerFiles: fileRecords.filter((f) => f.role === "header").length,
      modules: moduleNames.length,
      interfaces: interfaceNames.length,
      packages: packageNames.length,
      programs: programNames.length,
      classes: classNames.length,
      checkers: checkerNames.length,
      warnings: warnings.length + fileRecords.reduce((n, f) => n + (f.warnings || []).length, 0),
    },
    files: fileRecords,
    declarations: {
      modules: moduleNames,
      interfaces: interfaceNames,
      packages: packageNames,
      programs: programNames,
      classes: classNames,
      checkers: checkerNames,
      all: allDecls.map((d) => ({ type: d.type, name: d.name, file: d.file })),
    },
    graph: {
      moduleInstances: graph,
    },
    includeDirs: Array.from(includeDirs).sort((a, b) => a.localeCompare(b)),
    hdlDirs: Array.from(hdlDirs).sort((a, b) => a.localeCompare(b)),
    warnings,
  };

  if (opts.strict) {
    const strictAstIssues = fileRecords.flatMap((f) =>
      (f.warnings || [])
        .filter((w) => ["ast_provider_missing", "ast_parse_failed", "ast_syntax_error"].includes(w.type))
        .map((w) => ({ file: f.path, ...w }))
    );
    if (strictAstIssues.length > 0) {
      const counts = strictAstIssues.reduce((acc, item) => {
        acc[item.type] = (acc[item.type] || 0) + 1;
        return acc;
      }, {});
      const summary = Object.keys(counts)
        .sort()
        .map((k) => `${k}=${counts[k]}`)
        .join(", ");
      throw new Error(`Strict mode failed: ${strictAstIssues.length} AST issue(s) (${summary})`);
    }
  }
  return index;
}

function writeIndex(index, outPath) {
  ensureDir(path.dirname(outPath));
  fs.writeFileSync(outPath, JSON.stringify(index, null, 2));
}

function printList(index, listType) {
  let lines = [];
  if (listType === "rtl") {
    lines = index.files.filter((f) => f.role === "rtl").map((f) => f.path);
  } else if (listType === "tb") {
    lines = index.files.filter((f) => f.role === "tb" && (f.ext === ".v" || f.ext === ".sv")).map((f) => f.path);
  } else if (listType === "hdl") {
    lines = index.files.filter((f) => f.ext === ".v" || f.ext === ".sv").map((f) => f.path);
  } else if (listType === "includeDirs") {
    lines = index.includeDirs.map((p) => rel(index.projectRoot, p));
  }
  lines.forEach((l) => console.log(l));
}

function main() {
  try {
    const opts = parseArgs(process.argv.slice(2));
    const index = buildIndex(opts.projectRoot, opts);
    const outPath = path.resolve(opts.projectRoot, opts.out || "output/cache/hdl_index.json");

    if (opts.write || opts.out) {
      writeIndex(index, outPath);
      console.error(`[INFO] HDL index written: ${normalizeSlashes(outPath)}`);
      console.error(`[INFO] Files=${index.summary.totalFiles}, modules=${index.summary.modules}, warnings=${index.summary.warnings}`);
    }

    if (opts.list) {
      printList(index, opts.list);
      return;
    }

    process.stdout.write(JSON.stringify(index, null, opts.pretty ? 2 : 0));
  } catch (e) {
    console.error(`[ERROR] ${e.message}`);
    process.exit(1);
  }
}

if (require.main === module) {
  main();
}

module.exports = {
  buildIndex,
};
