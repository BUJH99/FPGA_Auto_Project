const fs = require("fs");
const path = require("path");

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

function detectParserProvider() {
  try {
    const Parser = require("tree-sitter");
    const Verilog = require("tree-sitter-verilog");
    const parser = new Parser();
    parser.setLanguage(Verilog);
    return {
      name: "tree-sitter-verilog",
      parse(text) {
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
  const declRe = /\b(module|interface|package|program)\s+([A-Za-z_][A-Za-z0-9_$]*)\b/g;
  let m;
  while ((m = declRe.exec(cleanText)) !== null) {
    declarations.push({
      type: m[1],
      name: m[2],
      offset: m.index,
    });
  }
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

function parseInstances(cleanText, moduleNames) {
  const instances = [];
  for (const modName of moduleNames) {
    const re = new RegExp(
      `\\b${modName}\\b\\s*(?:#\\s*\\([\\s\\S]*?\\)\\s*)?([A-Za-z_][A-Za-z0-9_$]*)\\s*\\(`,
      "g"
    );
    let m;
    while ((m = re.exec(cleanText)) !== null) {
      instances.push({ moduleName: modName, instName: m[1] || "" });
    }
  }
  return instances;
}

function inferProjectLanguage(fileInfos) {
  const hasV = fileInfos.some((f) => f.ext === ".v");
  const hasSv = fileInfos.some((f) => f.ext === ".sv" || f.ext === ".svh");
  if (hasV && hasSv) return "mixed";
  if (hasSv) return "systemverilog";
  return "verilog";
}

function buildIndex(projectRoot, opts = {}) {
  const parserProvider = detectParserProvider();
  const warnings = [];
  const files = [];
  const srcDir = path.join(projectRoot, "src");
  const tbDir = path.join(projectRoot, "tb");
  const includeDir = path.join(projectRoot, "include");
  const incDir = path.join(projectRoot, "inc");

  collectFiles(srcDir, "rtl", files, warnings);
  collectFiles(tbDir, "tb", files, warnings);
  collectFiles(includeDir, "header", files, warnings);
  collectFiles(incDir, "header", files, warnings);

  files.sort((a, b) => a.absPath.localeCompare(b.absPath));

  const fileRecords = [];
  const allDecls = [];
  const includeDirs = new Set();
  const hdlDirs = new Set();

  for (const f of files) {
    const raw = fs.readFileSync(f.absPath, "utf8");
    const clean = stripCommentsPreserveLines(raw);
    const decls = parseDeclarations(clean);
    const features = detectSvFeatures(clean);
    const includes = parseIncludes(raw);
    const fileWarnings = [];
    let ast = null;
    if (parserProvider) {
      try {
        const tree = parserProvider.parse(raw);
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
    rec.instances = rec.role === "header" ? [] : parseInstances(clean, moduleNames)
      .filter((inst) => !rec.declarations.some((d) => d.name === inst.moduleName));
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

  const graph = {};
  for (const mod of moduleNames) graph[mod] = [];
  for (const rec of fileRecords) {
    for (const inst of rec.instances || []) {
      const parents = rec.declarations.filter((d) => d.type === "module").map((d) => d.name);
      for (const p of parents) {
        if (!graph[p]) graph[p] = [];
        graph[p].push(inst.moduleName);
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
      warnings: warnings.length + fileRecords.reduce((n, f) => n + (f.warnings || []).length, 0),
    },
    files: fileRecords,
    declarations: {
      modules: moduleNames,
      interfaces: interfaceNames,
      packages: packageNames,
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
