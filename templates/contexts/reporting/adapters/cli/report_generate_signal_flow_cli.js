const fs = require("fs");
const path = require("path");

const DEFAULT_TRACE_DEPTH = 4;
const DEFAULT_HIERARCHY_DEPTH = 12;
const DEFAULT_EDGE_LIMIT = 180;
const DEFAULT_DETAIL_LIMIT = 320;

const IDENTIFIER_KEYWORDS = new Set([
  "always",
  "assign",
  "begin",
  "case",
  "default",
  "else",
  "end",
  "endcase",
  "endmodule",
  "for",
  "function",
  "if",
  "input",
  "inout",
  "localparam",
  "module",
  "negedge",
  "or",
  "output",
  "parameter",
  "posedge",
  "reg",
  "wire",
  "logic",
  "signed",
  "unsigned",
  "integer",
  "real",
  "time",
  "task",
  "while",
  "repeat",
  "generate",
  "endgenerate",
  "genvar",
  "initial",
  "typedef",
  "struct",
  "union",
  "enum",
  "automatic",
  "disable",
  "wait",
  "fork",
  "join",
  "join_any",
  "join_none",
  "package",
  "endpackage",
  "interface",
  "endinterface",
  "import",
  "export",
]);

function usage() {
  console.log("Usage:");
  console.log("  node templates/contexts/reporting/adapters/cli/report_generate_signal_flow_cli.js --project <path> --manifest-json <path> [--signal <name>] [--top <module>] [--depth <n|MAX>] [--hier-depth <n>] [--out <path>] [--list-signals] [--list-signals-raw]");
}

function argValue(args, key) {
  const idx = args.indexOf(key);
  if (idx < 0 || idx + 1 >= args.length) return null;
  return args[idx + 1];
}

function hasArg(args, key) {
  return args.includes(key);
}

function toInt(value, fallback, min, max) {
  if (value == null) return fallback;
  const parsed = parseInt(String(value), 10);
  if (!Number.isFinite(parsed)) return fallback;
  if (Number.isFinite(min) && parsed < min) return fallback;
  if (Number.isFinite(max) && parsed > max) return fallback;
  return parsed;
}

function parseTraceDepthArg(depthArg) {
  if (depthArg == null) {
    return {
      requestedDepth: DEFAULT_TRACE_DEPTH,
      requestedRaw: String(DEFAULT_TRACE_DEPTH),
      isMaxRequest: false,
    };
  }

  const raw = String(depthArg).trim();
  if (!raw) {
    return {
      requestedDepth: DEFAULT_TRACE_DEPTH,
      requestedRaw: String(DEFAULT_TRACE_DEPTH),
      isMaxRequest: false,
    };
  }

  if (/^max$/i.test(raw)) {
    return {
      requestedDepth: Number.MAX_SAFE_INTEGER,
      requestedRaw: "MAX",
      isMaxRequest: true,
    };
  }

  const parsed = parseInt(raw, 10);
  if (!Number.isFinite(parsed) || parsed < 1) {
    return {
      requestedDepth: DEFAULT_TRACE_DEPTH,
      requestedRaw: String(DEFAULT_TRACE_DEPTH),
      isMaxRequest: false,
    };
  }

  return {
    requestedDepth: parsed,
    requestedRaw: raw,
    isMaxRequest: false,
  };
}

function stripCommentsKeepLines(text) {
  let out = text.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "));
  out = out.replace(/\/\/.*$/gm, "");
  return out;
}

function skipWhitespace(text, index) {
  let i = index;
  while (i < text.length && /\s/.test(text[i])) i += 1;
  return i;
}

function isWordChar(ch) {
  return /[A-Za-z0-9_$]/.test(ch || "");
}

function startsKeyword(text, index, keyword) {
  if (index < 0 || index + keyword.length > text.length) return false;
  if (text.slice(index, index + keyword.length) !== keyword) return false;
  if (isWordChar(text[index - 1])) return false;
  if (isWordChar(text[index + keyword.length])) return false;
  return true;
}

function parseBalanced(text, start, openCh, closeCh) {
  if (text[start] !== openCh) return null;
  let depth = 0;
  let i = start;
  while (i < text.length) {
    const ch = text[i];
    if (ch === openCh) depth += 1;
    else if (ch === closeCh) {
      depth -= 1;
      if (depth === 0) {
        return {
          text: text.slice(start + 1, i),
          end: i + 1,
        };
      }
    }
    i += 1;
  }
  return null;
}

function splitTopLevel(text, delimiter) {
  const delim = delimiter || ",";
  const out = [];
  let token = "";
  let paren = 0;
  let bracket = 0;
  let brace = 0;
  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];
    if (ch === "(") paren += 1;
    else if (ch === ")") paren = Math.max(paren - 1, 0);
    else if (ch === "[") bracket += 1;
    else if (ch === "]") bracket = Math.max(bracket - 1, 0);
    else if (ch === "{") brace += 1;
    else if (ch === "}") brace = Math.max(brace - 1, 0);

    if (ch === delim && paren === 0 && bracket === 0 && brace === 0) {
      out.push(token);
      token = "";
      continue;
    }
    token += ch;
  }
  if (token.length > 0) out.push(token);
  return out;
}

function lineNumberFromIndex(text, index) {
  if (index <= 0) return 1;
  let line = 1;
  const end = Math.min(index, text.length);
  for (let i = 0; i < end; i += 1) {
    if (text.charCodeAt(i) === 10) line += 1;
  }
  return line;
}

function sanitizeExpr(text) {
  return String(text || "")
    .replace(/\s+/g, " ")
    .trim();
}

function extractIdentifiers(expr) {
  const ids = new Set();
  const text = String(expr || "");
  const re = /[A-Za-z_][A-Za-z0-9_$]*(?:\s*\[[^\]]+\])*/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    const name = m[0].replace(/\s+/g, "");
    const base = name.replace(/\[[^\]]+\]/g, "");
    if (IDENTIFIER_KEYWORDS.has(name.toLowerCase())) continue;
    if (IDENTIFIER_KEYWORDS.has(base.toLowerCase())) continue;
    if (/^\d/.test(name)) continue;
    const prev = m.index > 0 ? text[m.index - 1] : "";
    if (prev === "'" || prev === ".") continue;
    ids.add(name);
  }
  return [...ids];
}

function sanitizeFileLabel(filePath) {
  return filePath.replace(/\\/g, "/");
}

function extractDeclNamesFromSegment(segment) {
  const names = [];
  const chunks = splitTopLevel(segment, ",");
  for (const chunkRaw of chunks) {
    let chunk = chunkRaw.trim();
    if (!chunk) continue;
    chunk = chunk.replace(/=\s*.+$/g, " ");
    chunk = chunk.replace(/\[[^\]]*\]/g, " ");
    chunk = chunk.replace(
      /\b(wire|reg|logic|signed|unsigned|var|tri|tri0|tri1|supply0|supply1|bit|byte|shortint|int|longint|integer|time)\b/gi,
      " "
    );
    const m = chunk.match(/([A-Za-z_][A-Za-z0-9_$]*)\s*$/);
    if (m) names.push(m[1]);
  }
  return names;
}

function parseHeaderPorts(moduleText, moduleName) {
  const ports = new Map();
  const portOrder = [];
  const moduleNamePos = moduleText.indexOf(moduleName);
  if (moduleNamePos < 0) return { ports, portOrder };
  const headerEnd = moduleText.indexOf(";");
  if (headerEnd < 0) return { ports, portOrder };
  const header = moduleText.slice(moduleNamePos + moduleName.length, headerEnd + 1);
  let i = 0;
  i = skipWhitespace(header, i);

  if (header[i] === "#") {
    i += 1;
    i = skipWhitespace(header, i);
    if (header[i] === "(") {
      const params = parseBalanced(header, i, "(", ")");
      if (!params) return { ports, portOrder };
      i = params.end;
    }
  }

  i = skipWhitespace(header, i);
  if (header[i] !== "(") return { ports, portOrder };
  const portBlock = parseBalanced(header, i, "(", ")");
  if (!portBlock) return { ports, portOrder };

  let currentDir = null;
  const items = splitTopLevel(portBlock.text, ",");
  for (const rawItem of items) {
    const item = rawItem.trim();
    if (!item) continue;
    const dirMatch = item.match(/\b(input|output|inout)\b/i);
    if (dirMatch) currentDir = dirMatch[1].toLowerCase();

    const names = extractDeclNamesFromSegment(item);
    for (const name of names) {
      if (!ports.has(name) && currentDir) {
        ports.set(name, currentDir);
      } else if (!ports.has(name)) {
        ports.set(name, "unknown");
      }
      if (!portOrder.includes(name)) portOrder.push(name);
    }
  }

  return { ports, portOrder };
}

function parseBodyPorts(moduleText, ports, portOrder) {
  const headerEnd = moduleText.indexOf(";");
  const bodyText = headerEnd >= 0 ? moduleText.slice(headerEnd + 1) : moduleText;
  const declRe = /\b(input|output|inout)\b\s+([^;]+);/g;
  let m;
  while ((m = declRe.exec(bodyText)) !== null) {
    const dir = m[1].toLowerCase();
    const decl = m[2] || "";
    const names = extractDeclNamesFromSegment(decl);
    for (const name of names) {
      ports.set(name, dir);
      if (!portOrder.includes(name)) portOrder.push(name);
    }
  }
}

function parseInternalSignalKinds(moduleText, signalKinds) {
  const declRe = /\b(wire|reg|logic)\b\s+([^;]+);/g;
  let m;
  while ((m = declRe.exec(moduleText)) !== null) {
    const kind = m[1].toLowerCase();
    const decl = m[2] || "";
    const names = extractDeclNamesFromSegment(decl);
    for (const name of names) {
      if (!signalKinds.has(name)) {
        signalKinds.set(name, kind);
      }
    }
  }
}

function buildModuleSignalKinds(moduleText, ports) {
  const signalKinds = new Map();
  for (const [name, dir] of ports.entries()) {
    signalKinds.set(name, (dir || "unknown").toLowerCase());
  }
  parseInternalSignalKinds(moduleText, signalKinds);
  return signalKinds;
}

function extractAlwaysBlocks(moduleText) {
  const blocks = [];
  const alwaysRe = /\balways(?:\s*@\s*(?:\([^)]*\)|\*)|\s+_comb|\s+_ff|\s+_latch)?\b/g;
  let m;
  while ((m = alwaysRe.exec(moduleText)) !== null) {
    const start = m.index;
    let i = skipWhitespace(moduleText, alwaysRe.lastIndex);
    let end = i;

    if (startsKeyword(moduleText, i, "begin")) {
      let depth = 0;
      let p = i;
      while (p < moduleText.length) {
        if (startsKeyword(moduleText, p, "begin")) {
          depth += 1;
          p += 5;
          continue;
        }
        if (startsKeyword(moduleText, p, "end")) {
          depth -= 1;
          p += 3;
          if (depth <= 0) {
            end = p;
            break;
          }
          continue;
        }
        p += 1;
      }
      if (end <= i) end = moduleText.length;
    } else {
      while (end < moduleText.length && moduleText[end] !== ";") end += 1;
      if (end < moduleText.length) end += 1;
      if (end <= i) end = moduleText.length;
    }

    blocks.push({
      start,
      end,
      text: moduleText.slice(start, end),
    });
    alwaysRe.lastIndex = Math.max(alwaysRe.lastIndex, end);
  }
  return blocks;
}

function parseAssignments(moduleInfo) {
  const out = [];
  const moduleText = moduleInfo.text;
  const moduleStartLine = moduleInfo.startLine;

  const assignRe = /\bassign\s+([^;]+?)\s*=\s*([^;]+?)\s*;/g;
  let m;
  while ((m = assignRe.exec(moduleText)) !== null) {
    const lhsExpr = m[1] || "";
    const rhsExpr = m[2] || "";
    const lhsIds = extractIdentifiers(lhsExpr);
    const rhsIds = extractIdentifiers(rhsExpr);
    if (!lhsIds.length || !rhsIds.length) continue;
    out.push({
      kind: "assign",
      lhsIds,
      rhsIds,
      text: `assign ${sanitizeExpr(lhsExpr)} = ${sanitizeExpr(rhsExpr)};`,
      line: moduleStartLine + lineNumberFromIndex(moduleText, m.index) - 1,
      file: moduleInfo.file,
      moduleName: moduleInfo.name,
    });
  }

  const alwaysBlocks = extractAlwaysBlocks(moduleText);
  const stmtAssignRe = /([A-Za-z_][A-Za-z0-9_$]*(?:\s*\[[^\]]+\])?)\s*(<=|=)\s*([^;]+?)\s*;/g;
  for (const block of alwaysBlocks) {
    let am;
    while ((am = stmtAssignRe.exec(block.text)) !== null) {
      const lhsExpr = am[1] || "";
      const rhsExpr = am[3] || "";
      const lhsIds = extractIdentifiers(lhsExpr);
      const rhsIds = extractIdentifiers(rhsExpr);
      if (!lhsIds.length || !rhsIds.length) continue;
      const absIndex = block.start + am.index;
      out.push({
        kind: "always",
        lhsIds,
        rhsIds,
        text: `${sanitizeExpr(lhsExpr)} ${am[2]} ${sanitizeExpr(rhsExpr)};`,
        line: moduleStartLine + lineNumberFromIndex(moduleText, absIndex) - 1,
        file: moduleInfo.file,
        moduleName: moduleInfo.name,
      });
    }
  }

  return out;
}

function parseConnections(connectionText, childModuleInfo) {
  const namedConnections = [];
  const items = splitTopLevel(connectionText, ",");
  let hasNamed = false;
  for (const raw of items) {
    if (/^\s*\./.test(raw)) {
      hasNamed = true;
      break;
    }
  }

  if (hasNamed) {
    for (const raw of items) {
      const item = raw.trim();
      if (!item) continue;
      const m = item.match(/^\.\s*([A-Za-z_][A-Za-z0-9_$]*)\s*\(\s*([\s\S]*)\s*\)\s*$/);
      if (!m) continue;
      namedConnections.push({
        port: m[1],
        expr: sanitizeExpr(m[2]),
      });
    }
    return namedConnections;
  }

  const positional = items.map((s) => sanitizeExpr(s)).filter(Boolean);
  const order = childModuleInfo ? childModuleInfo.portOrder : [];
  for (let i = 0; i < positional.length; i += 1) {
    const portName = order[i] || `$${i + 1}`;
    namedConnections.push({
      port: portName,
      expr: positional[i],
    });
  }
  return namedConnections;
}

function parseInstances(moduleInfo, moduleNames, modulesByName) {
  const out = [];
  const moduleText = moduleInfo.text;
  const current = moduleInfo.name;
  const moduleStartLine = moduleInfo.startLine;

  for (const childName of moduleNames) {
    if (childName === current) continue;
    const escaped = childName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const re = new RegExp(
      `\\b${escaped}\\b\\s*(?:#\\s*\\([\\s\\S]*?\\)\\s*)?([A-Za-z_][A-Za-z0-9_$]*)\\s*\\(([\\s\\S]*?)\\)\\s*;`,
      "g"
    );
    let m;
    while ((m = re.exec(moduleText)) !== null) {
      const instanceName = m[1];
      const connectionText = m[2] || "";
      const childModuleInfo = modulesByName.get(childName) || null;
      const connections = parseConnections(connectionText, childModuleInfo);
      if (!connections.length) continue;
      out.push({
        childModule: childName,
        instanceName,
        connections,
        line: moduleStartLine + lineNumberFromIndex(moduleText, m.index) - 1,
        file: moduleInfo.file,
      });
    }
  }

  return out;
}

function parseModulesFromFile(filePath) {
  const raw = fs.readFileSync(filePath, "utf8");
  const clean = stripCommentsKeepLines(raw);
  const modules = [];
  const re = /\bmodule\s+([A-Za-z_][A-Za-z0-9_$]*)\b([\s\S]*?)\bendmodule\b/g;
  let m;
  while ((m = re.exec(clean)) !== null) {
    const name = m[1];
    const text = m[0];
    const startLine = lineNumberFromIndex(clean, m.index);

    const headerInfo = parseHeaderPorts(text, name);
    parseBodyPorts(text, headerInfo.ports, headerInfo.portOrder);

    modules.push({
      name,
      file: filePath,
      startLine,
      text,
      ports: headerInfo.ports,
      portOrder: headerInfo.portOrder,
      signalKinds: buildModuleSignalKinds(text, headerInfo.ports),
      assignments: [],
      instances: [],
    });
  }
  return modules;
}

function buildModuleDatabase(sourceFiles) {
  const warnings = [];
  const files = [...new Set((sourceFiles || []).map((row) => path.resolve(row)))].sort((a, b) => a.localeCompare(b));
  const moduleList = [];

  for (const filePath of files) {
    const parsed = parseModulesFromFile(filePath);
    for (const mod of parsed) moduleList.push(mod);
  }

  const modulesByName = new Map();
  for (const mod of moduleList) {
    if (modulesByName.has(mod.name)) {
      const prev = modulesByName.get(mod.name);
      warnings.push(
        `Duplicate module name '${mod.name}': ${sanitizeFileLabel(prev.file)} and ${sanitizeFileLabel(
          mod.file
        )}. Using the latter.`
      );
    }
    modulesByName.set(mod.name, mod);
  }

  const names = [...modulesByName.keys()];
  for (const name of names) {
    const mod = modulesByName.get(name);
    mod.assignments = parseAssignments(mod);
  }
  for (const name of names) {
    const mod = modulesByName.get(name);
    mod.instances = parseInstances(mod, names, modulesByName);
  }

  return {
    files,
    modulesByName,
    warnings,
  };
}

function resolveManifestSources(projectRoot, manifestJsonPath) {
  if (!manifestJsonPath) {
    throw new Error("--manifest-json is required in strict mode");
  }
  const abs = path.resolve(manifestJsonPath);
  if (!fs.existsSync(abs)) {
    throw new Error(`Manifest JSON not found: ${abs}`);
  }

  let parsed = null;
  try {
    parsed = JSON.parse(fs.readFileSync(abs, "utf8"));
  } catch (err) {
    throw new Error(`Failed to parse manifest JSON: ${err.message}`);
  }

  if (!parsed || typeof parsed !== "object") {
    throw new Error("Manifest JSON root must be object");
  }
  if (Array.isArray(parsed.errors) && parsed.errors.length > 0) {
    const codes = parsed.errors.map((e) => e.code).filter(Boolean).join(",");
    throw new Error(`Manifest JSON contains errors: ${codes || "unknown_error"}`);
  }

  const resolved = parsed.resolved && typeof parsed.resolved === "object" ? parsed.resolved : {};
  const srcRows = Array.isArray(resolved.src_files) ? resolved.src_files : [];
  const sourceFiles = srcRows
    .map((row) => String(row || "").trim())
    .filter((row) => row.length > 0)
    .map((row) => (path.isAbsolute(row) ? row : path.resolve(projectRoot, row)))
    .filter((absPath) => fs.existsSync(absPath))
    .filter((absPath) => /\.(v|sv)$/i.test(absPath))
    .sort((a, b) => a.localeCompare(b));

  if (sourceFiles.length === 0) {
    throw new Error("Manifest resolved no source files (.v/.sv)");
  }

  const top = parsed.config && parsed.config.hdl && typeof parsed.config.hdl.top === "string"
    ? parsed.config.hdl.top.trim()
    : "";

  return {
    top,
    sourceFiles,
  };
}

function buildHierarchy(modulesByName, topModule, maxDepth) {
  const warnings = [];
  const instances = new Map();
  const queue = [];

  const root = {
    path: topModule,
    moduleName: topModule,
    depth: 0,
    parentPath: null,
  };
  instances.set(root.path, root);
  queue.push(root);

  while (queue.length > 0) {
    const cur = queue.shift();
    const mod = modulesByName.get(cur.moduleName);
    if (!mod) continue;
    if (cur.depth >= maxDepth) {
      warnings.push(
        `Hierarchy depth limit reached at ${cur.path} (module ${cur.moduleName}). Increase --hier-depth if needed.`
      );
      continue;
    }

    for (const inst of mod.instances) {
      if (!modulesByName.has(inst.childModule)) continue;
      const childPath = `${cur.path}.${inst.instanceName}`;
      if (instances.has(childPath)) continue;
      const child = {
        path: childPath,
        moduleName: inst.childModule,
        depth: cur.depth + 1,
        parentPath: cur.path,
      };
      instances.set(childPath, child);
      queue.push(child);
    }
  }

  return {
    instances,
    warnings,
  };
}

function addEdge(edgeStore, edge) {
  const key = [
    edge.src,
    edge.dst,
    edge.kind,
    edge.file || "",
    edge.line || "",
    edge.detail || "",
  ].join("|");
  if (edgeStore.keys.has(key)) return;
  edgeStore.keys.add(key);
  edgeStore.edges.push(edge);
}

function buildSignalGraph(modulesByName, hierarchy) {
  const edgeStore = { edges: [], keys: new Set() };
  const nodes = new Set();

  const hierarchyEntries = [...hierarchy.instances.values()].sort((a, b) =>
    a.path.localeCompare(b.path)
  );

  for (const instNode of hierarchyEntries) {
    const mod = modulesByName.get(instNode.moduleName);
    if (!mod) continue;
    const basePath = instNode.path;

    for (const asn of mod.assignments) {
      for (const srcId of asn.rhsIds) {
        for (const dstId of asn.lhsIds) {
          const src = `${basePath}.${srcId}`;
          const dst = `${basePath}.${dstId}`;
          nodes.add(src);
          nodes.add(dst);
          addEdge(edgeStore, {
            src,
            dst,
            kind: asn.kind,
            moduleName: instNode.moduleName,
            instancePath: basePath,
            file: asn.file,
            line: asn.line,
            detail: asn.text,
          });
        }
      }
    }

    for (const childInst of mod.instances) {
      const childPath = `${basePath}.${childInst.instanceName}`;
      const childInfo = modulesByName.get(childInst.childModule);
      if (!childInfo) continue;
      if (!hierarchy.instances.has(childPath)) continue;

      for (const conn of childInst.connections) {
        const parentIds = extractIdentifiers(conn.expr);
        if (!parentIds.length) continue;
        const dir = (childInfo.ports.get(conn.port) || "unknown").toLowerCase();
        const childPortNode = `${childPath}.${conn.port}`;
        nodes.add(childPortNode);

        for (const parentId of parentIds) {
          const parentNode = `${basePath}.${parentId}`;
          nodes.add(parentNode);
          const detail = `${childInst.instanceName}.${conn.port}(${sanitizeExpr(conn.expr)})`;

          if (dir === "input") {
            addEdge(edgeStore, {
              src: parentNode,
              dst: childPortNode,
              kind: "port-in",
              moduleName: instNode.moduleName,
              instancePath: basePath,
              file: childInst.file,
              line: childInst.line,
              detail,
            });
          } else if (dir === "output") {
            addEdge(edgeStore, {
              src: childPortNode,
              dst: parentNode,
              kind: "port-out",
              moduleName: instNode.moduleName,
              instancePath: basePath,
              file: childInst.file,
              line: childInst.line,
              detail,
            });
          } else if (dir === "inout") {
            addEdge(edgeStore, {
              src: parentNode,
              dst: childPortNode,
              kind: "port-inout",
              moduleName: instNode.moduleName,
              instancePath: basePath,
              file: childInst.file,
              line: childInst.line,
              detail,
            });
            addEdge(edgeStore, {
              src: childPortNode,
              dst: parentNode,
              kind: "port-inout",
              moduleName: instNode.moduleName,
              instancePath: basePath,
              file: childInst.file,
              line: childInst.line,
              detail,
            });
          } else {
            addEdge(edgeStore, {
              src: parentNode,
              dst: childPortNode,
              kind: "port-unknown",
              moduleName: instNode.moduleName,
              instancePath: basePath,
              file: childInst.file,
              line: childInst.line,
              detail,
            });
            addEdge(edgeStore, {
              src: childPortNode,
              dst: parentNode,
              kind: "port-unknown",
              moduleName: instNode.moduleName,
              instancePath: basePath,
              file: childInst.file,
              line: childInst.line,
              detail,
            });
          }
        }
      }
    }
  }

  edgeStore.edges.forEach((edge, index) => {
    edge.id = `E${index + 1}`;
  });

  return {
    edges: edgeStore.edges,
    nodes,
  };
}

function buildAdjacency(edges) {
  const outMap = new Map();
  const inMap = new Map();
  for (const edge of edges) {
    if (!outMap.has(edge.src)) outMap.set(edge.src, []);
    if (!inMap.has(edge.dst)) inMap.set(edge.dst, []);
    outMap.get(edge.src).push(edge);
    inMap.get(edge.dst).push(edge);
  }
  return { outMap, inMap };
}

function getSignalLeaf(nodeName) {
  const parts = String(nodeName || "").split(".");
  return parts[parts.length - 1] || "";
}

function getSignalBase(signalLeaf) {
  return String(signalLeaf || "").replace(/\[[^\]]+\]/g, "");
}

function findSignalNodes(signalQuery, nodes) {
  const query = String(signalQuery || "").trim();
  if (!query) return [];
  const nodeList = [...nodes];

  const exact = [];
  if (query.includes(".")) {
    for (const node of nodeList) {
      if (node === query || node.endsWith(`.${query}`)) exact.push(node);
    }
  } else {
    for (const node of nodeList) {
      const leaf = getSignalLeaf(node);
      const base = getSignalBase(leaf);
      if (leaf === query || base === query) exact.push(node);
    }
  }
  if (exact.length > 0) return exact.sort();

  const fallback = [];
  const q = query.toLowerCase();
  if (query.includes(".")) {
    for (const node of nodeList) {
      const low = node.toLowerCase();
      if (low === q || low.endsWith(`.${q}`)) fallback.push(node);
    }
  } else {
    for (const node of nodeList) {
      const leaf = getSignalLeaf(node).toLowerCase();
      const base = getSignalBase(getSignalLeaf(node)).toLowerCase();
      if (leaf === q || base === q) fallback.push(node);
    }
  }
  return fallback.sort();
}

function findSignalSuggestions(signalQuery, nodes, limit) {
  const q = String(signalQuery || "").toLowerCase();
  const uniqueSignals = new Set();
  for (const node of nodes) {
    uniqueSignals.add(getSignalLeaf(node));
    uniqueSignals.add(getSignalBase(getSignalLeaf(node)));
  }
  const out = [];
  for (const sig of uniqueSignals) {
    const low = sig.toLowerCase();
    if (!q || low.includes(q) || q.includes(low)) out.push(sig);
  }
  out.sort((a, b) => a.localeCompare(b));
  return out.slice(0, limit || 20);
}

function bfsCollect(startNodes, adjacency, mode, depth, edgeLimit) {
  const visitedNodes = new Set(startNodes);
  const visitedEdges = new Set();
  const nodeDepth = new Map();
  for (const node of startNodes) nodeDepth.set(node, 0);
  let frontier = new Set(startNodes);
  let truncated = false;
  const collectedEdges = [];

  for (let d = 0; d < depth; d += 1) {
    if (frontier.size === 0) break;
    const next = new Set();
    for (const node of frontier) {
      const edges = adjacency.get(node) || [];
      for (const edge of edges) {
        if (!visitedEdges.has(edge.id)) {
          visitedEdges.add(edge.id);
          collectedEdges.push(edge);
          if (collectedEdges.length >= edgeLimit) {
            truncated = true;
            break;
          }
        }
        const neighbor = mode === "forward" ? edge.dst : edge.src;
        if (!visitedNodes.has(neighbor)) {
          visitedNodes.add(neighbor);
          next.add(neighbor);
          nodeDepth.set(neighbor, d + 1);
        }
      }
      if (truncated) break;
    }
    if (truncated) break;
    frontier = next;
  }

  return {
    edges: collectedEdges,
    nodes: visitedNodes,
    nodeDepth,
    truncated,
  };
}

function edgeLabel(edge) {
  if (edge.kind === "assign") return "assign";
  if (edge.kind === "always") return "always";
  if (edge.kind === "port-in") return `map:${edge.detail.split("(")[0]}`;
  if (edge.kind === "port-out") return `map:${edge.detail.split("(")[0]}`;
  if (edge.kind === "port-inout") return `inout:${edge.detail.split("(")[0]}`;
  if (edge.kind === "port-unknown") return `map?:${edge.detail.split("(")[0]}`;
  return edge.kind;
}

function escapeMermaidLabel(text) {
  return String(text || "")
    .replace(/"/g, '\\"')
    .replace(/\|/g, "/")
    .replace(/\[/g, "(")
    .replace(/\]/g, ")");
}

function buildMermaid(edges, highlightedNodes) {
  const nodes = new Set(highlightedNodes || []);
  for (const edge of edges) {
    nodes.add(edge.src);
    nodes.add(edge.dst);
  }

  if (edges.length === 0) {
    return [
      "```mermaid",
      "%%{init: {'theme': 'base', 'themeVariables': {'primaryColor': '#ffffff', 'secondaryColor': '#ffffff', 'tertiaryColor': '#ffffff', 'primaryTextColor': '#111111', 'primaryBorderColor': '#666666', 'lineColor': '#444444'}}}%%",
      "flowchart LR",
      "  X[\"No traced edges\"]:::nodeDefault",
      "  classDef nodeDefault fill:#ffffff,stroke:#666666,stroke-width:1px,color:#111111;",
      "  style X fill:#ffffff,stroke:#666666,stroke-width:1px,color:#111111",
      "```",
    ].join("\n");
  }

  const sortedNodes = [...nodes].sort((a, b) => a.localeCompare(b));
  const idMap = new Map();
  let counter = 1;
  for (const node of sortedNodes) {
    idMap.set(node, `N${counter}`);
    counter += 1;
  }

  const lines = [];
  lines.push("```mermaid");
  lines.push(
    "%%{init: {'theme': 'base', 'themeVariables': {'primaryColor': '#ffffff', 'secondaryColor': '#ffffff', 'tertiaryColor': '#ffffff', 'primaryTextColor': '#111111', 'primaryBorderColor': '#666666', 'lineColor': '#444444'}}}%%"
  );
  lines.push("flowchart LR");

  for (const node of sortedNodes) {
    const id = idMap.get(node);
    lines.push(`  ${id}["${escapeMermaidLabel(node)}"]:::nodeDefault`);
  }

  for (const edge of edges) {
    const fromId = idMap.get(edge.src);
    const toId = idMap.get(edge.dst);
    const label = escapeMermaidLabel(edgeLabel(edge));
    lines.push(`  ${fromId} -->|${label}| ${toId}`);
  }

  lines.push("  classDef nodeDefault fill:#ffffff,stroke:#666666,stroke-width:1px,color:#111111;");
  lines.push("  classDef targetNode fill:#ffffff,stroke:#b36b00,stroke-width:2px,color:#111111;");

  const allNodeIds = sortedNodes.map((node) => idMap.get(node)).filter(Boolean);
  for (const nodeId of allNodeIds) {
    lines.push(`  style ${nodeId} fill:#ffffff,stroke:#666666,stroke-width:1px,color:#111111`);
  }

  const highlight = [...new Set(highlightedNodes || [])]
    .filter((node) => idMap.has(node))
    .map((node) => idMap.get(node));
  if (highlight.length > 0) {
    lines.push(`  class ${highlight.join(",")} targetNode;`);
    for (const nodeId of highlight) {
      lines.push(`  style ${nodeId} fill:#ffffff,stroke:#b36b00,stroke-width:2px,color:#111111`);
    }
  }

  lines.push("```");
  return lines.join("\n");
}

function escapeMdCell(text) {
  return String(text || "")
    .replace(/\|/g, "\\|")
    .replace(/\r?\n/g, " ")
    .trim();
}

function relativePath(fromDir, target) {
  return path.relative(fromDir, target).replace(/\\/g, "/");
}

function buildEdgeRows(label, edges, projectRoot) {
  return edges.map((edge) => {
    const fileLabel = sanitizeFileLabel(relativePath(projectRoot, edge.file || ""));
    const loc = edge.line ? `${fileLabel}:${edge.line}` : fileLabel;
    return {
      direction: label,
      from: edge.src,
      to: edge.dst,
      kind: edge.kind,
      location: loc,
      detail: edge.detail || "",
    };
  });
}

function safeSignalTag(signalName) {
  const out = String(signalName || "")
    .trim()
    .replace(/[^A-Za-z0-9_.-]+/g, "_")
    .replace(/^_+|_+$/g, "");
  return out || "signal";
}

function getNodeModulePath(nodeName) {
  const text = String(nodeName || "");
  const idx = text.lastIndexOf(".");
  if (idx < 0) return "";
  return text.slice(0, idx);
}

function buildModuleTraversalOrder(traversal, hierarchy, mode) {
  const moduleDepth = new Map();
  for (const node of traversal.nodes || []) {
    const modulePath = getNodeModulePath(node);
    if (!modulePath) continue;
    const depth = traversal.nodeDepth && traversal.nodeDepth.has(node) ? traversal.nodeDepth.get(node) : 0;
    if (!moduleDepth.has(modulePath) || depth < moduleDepth.get(modulePath)) {
      moduleDepth.set(modulePath, depth);
    }
  }

  const list = [...moduleDepth.entries()].map(([modulePath, depth]) => {
    const info = hierarchy.instances.get(modulePath);
    const moduleName = info ? info.moduleName : "";
    return {
      modulePath,
      moduleName,
      depth,
    };
  });

  list.sort((a, b) => {
    if (mode === "upstream") {
      if (a.depth !== b.depth) return b.depth - a.depth;
    } else {
      if (a.depth !== b.depth) return a.depth - b.depth;
    }
    return a.modulePath.localeCompare(b.modulePath);
  });

  return list;
}

function renderMarkdown({
  projectRoot,
  topModule,
  signalQuery,
  depth,
  matchedNodes,
  upstream,
  downstream,
  hierarchy,
  warnings,
  outputPath,
  allEdges,
  modulesByName,
}) {
  const now = new Date().toISOString();
  let md = "";
  md += `# Signal Flow Trace: \`${signalQuery}\`\n\n`;
  md += `- Generated: \`${now}\`\n`;
  md += `- Project: \`${sanitizeFileLabel(projectRoot)}\`\n`;
  md += `- Top module: \`${topModule}\`\n`;
  md += `- Trace depth: \`${depth}\`\n`;
  md += `- Matched nodes: \`${matchedNodes.length}\`\n`;
  md += `- Modules parsed: \`${modulesByName.size}\`\n`;
  md += `- Graph edges: \`${allEdges.length}\`\n\n`;

  if (warnings.length > 0) {
    md += `## Warnings\n\n`;
    for (const warn of warnings) md += `- ${warn}\n`;
    md += `\n`;
  }

  md += `## Matched Signal Nodes\n\n`;
  for (const node of matchedNodes) {
    md += `- \`${node}\`\n`;
  }
  md += `\n`;

  md += `## Upstream Flow\n\n`;
  if (upstream.truncated) {
    md += `- Note: upstream trace reached edge limit and was truncated.\n\n`;
  }
  md += `${buildMermaid(upstream.edges, matchedNodes)}\n\n`;

  md += `## Downstream Flow\n\n`;
  if (downstream.truncated) {
    md += `- Note: downstream trace reached edge limit and was truncated.\n\n`;
  }
  md += `${buildMermaid(downstream.edges, matchedNodes)}\n\n`;

  const upstreamModules = buildModuleTraversalOrder(upstream, hierarchy, "upstream");
  const downstreamModules = buildModuleTraversalOrder(downstream, hierarchy, "downstream");

  md += `## Module Traversal Order\n\n`;
  md += `### Upstream Modules (Source -> Target)\n\n`;
  if (upstreamModules.length === 0) {
    md += `- No upstream modules traced.\n\n`;
  } else {
    for (let i = 0; i < upstreamModules.length; i += 1) {
      const item = upstreamModules[i];
      if (item.moduleName) {
        md += `${i + 1}. \`${item.modulePath}\` (\`${item.moduleName}\`)\n`;
      } else {
        md += `${i + 1}. \`${item.modulePath}\`\n`;
      }
    }
    md += `\n`;
  }

  md += `### Downstream Modules (Target -> Sink)\n\n`;
  if (downstreamModules.length === 0) {
    md += `- No downstream modules traced.\n\n`;
  } else {
    for (let i = 0; i < downstreamModules.length; i += 1) {
      const item = downstreamModules[i];
      if (item.moduleName) {
        md += `${i + 1}. \`${item.modulePath}\` (\`${item.moduleName}\`)\n`;
      } else {
        md += `${i + 1}. \`${item.modulePath}\`\n`;
      }
    }
    md += `\n`;
  }

  const rows = [
    ...buildEdgeRows("upstream", upstream.edges, projectRoot),
    ...buildEdgeRows("downstream", downstream.edges, projectRoot),
  ];

  md += `## Trace Edges\n\n`;
  if (rows.length === 0) {
    md += `No traced edges were found for this signal.\n`;
  } else {
    md += `| Direction | From | To | Type | Location | Detail |\n`;
    md += `|---|---|---|---|---|---|\n`;
    for (const row of rows.slice(0, DEFAULT_DETAIL_LIMIT)) {
      md += `| ${escapeMdCell(row.direction)} | \`${escapeMdCell(row.from)}\` | \`${escapeMdCell(
        row.to
      )}\` | \`${escapeMdCell(row.kind)}\` | \`${escapeMdCell(row.location)}\` | \`${escapeMdCell(
        row.detail
      )}\` |\n`;
    }
    if (rows.length > DEFAULT_DETAIL_LIMIT) {
      md += `\n- Detail rows truncated at ${DEFAULT_DETAIL_LIMIT} entries.\n`;
    }
  }

  const outDir = path.dirname(outputPath);
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(outputPath, md, "utf8");
}

function chooseTopModule(modulesByName) {
  if (modulesByName.has("TOP")) return "TOP";
  if (modulesByName.has("Top")) return "Top";

  const usage = new Map();
  for (const [name] of modulesByName) usage.set(name, 0);
  for (const [, mod] of modulesByName) {
    for (const inst of mod.instances || []) {
      usage.set(inst.childModule, (usage.get(inst.childModule) || 0) + 1);
    }
  }

  const roots = [...usage.entries()]
    .filter(([, count]) => count === 0)
    .map(([name]) => name)
    .sort((a, b) => a.localeCompare(b));
  if (roots.length > 0) return roots[0];

  const names = [...modulesByName.keys()].sort((a, b) => a.localeCompare(b));
  return names[0] || null;
}

function classifySignalKind(kindRaw) {
  const kind = String(kindRaw || "unknown").toLowerCase();
  if (kind === "input" || kind === "output" || kind === "inout") {
    return { bucket: kind, kind };
  }
  if (kind === "wire" || kind === "reg" || kind === "logic") {
    return { bucket: "internal", kind };
  }
  return { bucket: "unknown", kind };
}

function collectModuleSignalEntries(moduleInfo) {
  const entries = [...(moduleInfo.signalKinds || new Map()).entries()].map(([name, kindRaw]) => {
    const info = classifySignalKind(kindRaw);
    return {
      name,
      kind: info.kind,
      bucket: info.bucket,
    };
  });

  const bucketOrder = {
    input: 1,
    output: 2,
    inout: 3,
    internal: 4,
    unknown: 5,
  };

  entries.sort((a, b) => {
    const ao = bucketOrder[a.bucket] || 9;
    const bo = bucketOrder[b.bucket] || 9;
    if (ao !== bo) return ao - bo;
    return a.name.localeCompare(b.name);
  });

  return entries;
}

function printModuleSignals(moduleName, moduleInfo) {
  const entries = collectModuleSignalEntries(moduleInfo);

  const buckets = {
    input: [],
    output: [],
    inout: [],
    internal: [],
    unknown: [],
  };

  for (const item of entries) {
    if (item.bucket === "input") {
      buckets.input.push(item.name);
    } else if (item.bucket === "output") {
      buckets.output.push(item.name);
    } else if (item.bucket === "inout") {
      buckets.inout.push(item.name);
    } else if (item.bucket === "internal") {
      buckets.internal.push(`${item.name} (${item.kind})`);
    } else {
      buckets.unknown.push(`${item.name} (${item.kind})`);
    }
  }

  const total =
    buckets.input.length +
    buckets.output.length +
    buckets.inout.length +
    buckets.internal.length +
    buckets.unknown.length;

  console.log(`[INFO] Signal scan module: ${moduleName}`);
  console.log(`[INFO] Total signals: ${total}`);

  function printBucket(title, list) {
    if (!list.length) return;
    console.log(`\n[${title}]`);
    for (const item of list) {
      console.log(`- ${item}`);
    }
  }

  printBucket("INPUT", buckets.input);
  printBucket("OUTPUT", buckets.output);
  printBucket("INOUT", buckets.inout);
  printBucket("INTERNAL", buckets.internal);
  printBucket("UNKNOWN", buckets.unknown);
}

function main() {
  const args = process.argv.slice(2);
  const projectArg = argValue(args, "--project");
  const manifestJsonArg = argValue(args, "--manifest-json");
  const signalArg = argValue(args, "--signal");
  const topArg = argValue(args, "--top");
  const depthArg = argValue(args, "--depth");
  const hierDepthArg = argValue(args, "--hier-depth");
  const outArg = argValue(args, "--out");
  const listSignalsMode = hasArg(args, "--list-signals");
  const listSignalsRawMode = hasArg(args, "--list-signals-raw");

  if (!projectArg) {
    usage();
    process.exit(2);
  }

  const projectRoot = path.resolve(projectArg);
  let manifestContext = null;
  try {
    manifestContext = resolveManifestSources(projectRoot, manifestJsonArg);
  } catch (err) {
    console.error(`[ERROR] ${err.message}`);
    process.exit(2);
  }

  const traceDepthArg = parseTraceDepthArg(depthArg);
  const hierarchyDepth = toInt(hierDepthArg, DEFAULT_HIERARCHY_DEPTH, 1, 60);

  const db = buildModuleDatabase(manifestContext.sourceFiles);
  if (db.modulesByName.size === 0) {
    console.error("[ERROR] No Verilog modules were parsed from manifest-resolved sources.");
    process.exit(1);
  }

  let topModule = topArg ? String(topArg).trim() : "";
  if (!topModule && manifestContext.top) topModule = manifestContext.top;
  if (!topModule) topModule = chooseTopModule(db.modulesByName);
  if (!topModule || !db.modulesByName.has(topModule)) {
    console.error(`[ERROR] Top module not found: ${topModule || "(empty)"}`);
    const names = [...db.modulesByName.keys()].sort((a, b) => a.localeCompare(b));
    console.error(`[INFO] Available modules: ${names.join(", ")}`);
    process.exit(1);
  }

  if (listSignalsMode) {
    const moduleInfo = db.modulesByName.get(topModule);
    if (listSignalsRawMode) {
      const items = collectModuleSignalEntries(moduleInfo);
      for (const item of items) {
        console.log(`${item.name}|${item.kind}`);
      }
      process.exit(0);
    }
    printModuleSignals(topModule, moduleInfo);
    process.exit(0);
  }

  if (!signalArg) {
    usage();
    process.exit(2);
  }

  const signalQuery = String(signalArg).trim();

  const hierarchy = buildHierarchy(db.modulesByName, topModule, hierarchyDepth);
  const graph = buildSignalGraph(db.modulesByName, hierarchy);
  const adjacency = buildAdjacency(graph.edges);

  const graphMaxDepth = Math.max(1, graph.nodes.size);
  const traceDepth = Math.min(traceDepthArg.requestedDepth, graphMaxDepth);
  const edgeLimit = Math.max(DEFAULT_EDGE_LIMIT, graph.edges.length + 1);

  const matchedNodes = findSignalNodes(signalQuery, graph.nodes);
  if (matchedNodes.length === 0) {
    console.error(`[ERROR] Signal not found in hierarchy graph: ${signalQuery}`);
    const suggestions = findSignalSuggestions(signalQuery, graph.nodes, 20);
    if (suggestions.length > 0) {
      console.error(`[INFO] Similar signals: ${suggestions.join(", ")}`);
    }
    process.exit(1);
  }

  const upstream = bfsCollect(
    matchedNodes,
    adjacency.inMap,
    "backward",
    traceDepth,
    edgeLimit
  );
  const downstream = bfsCollect(
    matchedNodes,
    adjacency.outMap,
    "forward",
    traceDepth,
    edgeLimit
  );

  const defaultOutDir = path.join(projectRoot, "output", "signal", safeSignalTag(topModule));
  const outPath = outArg
    ? path.resolve(outArg)
    : path.join(defaultOutDir, `signal_flow_${safeSignalTag(signalQuery)}.md`);

  const warnings = [...db.warnings, ...hierarchy.warnings];
  renderMarkdown({
    projectRoot,
    topModule,
    signalQuery,
    depth: traceDepth,
    matchedNodes,
    upstream,
    downstream,
    hierarchy,
    warnings,
    outputPath: outPath,
    allEdges: graph.edges,
    modulesByName: db.modulesByName,
  });

  console.log(`[SUCCESS] Signal flow markdown generated.`);
  console.log(`[INFO] Output: ${outPath}`);
  console.log(`[INFO] Top: ${topModule}`);
  console.log(`[INFO] Trace depth request: ${traceDepthArg.requestedRaw}`);
  console.log(`[INFO] Effective trace depth: ${traceDepth} (graph max: ${graphMaxDepth})`);
  console.log(`[INFO] Signal matches: ${matchedNodes.length}`);
  console.log(`[INFO] Upstream edges: ${upstream.edges.length}${upstream.truncated ? " (truncated)" : ""}`);
  console.log(
    `[INFO] Downstream edges: ${downstream.edges.length}${downstream.truncated ? " (truncated)" : ""}`
  );
}

main();
