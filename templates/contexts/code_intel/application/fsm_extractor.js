const fs = require("fs");
const path = require("path");
const cp = require("child_process");

function usage() {
  console.log("Usage: node tools/generate_fsm_from_verilog.js --verilog <file.(v|sv)> --out <file.svg> [--module <name>] [--engine auto|native|graphviz] [--direction single|both]");
  console.log("   or: node tools/generate_fsm_from_verilog.js --verilog <file.(v|sv)> [--module <name>] --meta-only [--out-json <file.json>]");
}

function argValue(args, key) {
  const idx = args.indexOf(key);
  if (idx < 0 || idx + 1 >= args.length) return null;
  return args[idx + 1];
}

function escapeXml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

function stripComments(src) {
  let out = src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "));
  out = out.replace(/\/\/.*$/gm, "");
  return out;
}

function countWord(text, word) {
  const re = new RegExp(`\\b${word}\\b`, "gi");
  let c = 0;
  while (re.exec(text)) c++;
  return c;
}

function normalizeCond(cond) {
  return cond.replace(/\s+/g, " ").trim();
}

function combineCond(a, b) {
  if (!a) return b || "";
  if (!b) return a || "";
  if (a === "else") return b;
  if (b === "else") return a;
  return `(${a}) && (${b})`;
}

function trimOuterParens(s) {
  let out = s.trim();
  while (out.startsWith("(") && out.endsWith(")")) {
    let depth = 0;
    let ok = true;
    for (let i = 0; i < out.length; i++) {
      const ch = out[i];
      if (ch === "(") depth++;
      else if (ch === ")") depth--;
      if (depth === 0 && i < out.length - 1) {
        ok = false;
        break;
      }
    }
    if (!ok) break;
    out = out.slice(1, -1).trim();
  }
  return out;
}

function prettifyCond(cond) {
  let s = normalizeCond(cond || "");
  if (!s) return "next cycle";

  s = s.replace(/\s+/g, " ");
  s = s.replace(/!\(\s*!\s*([^)]+)\s*\)/g, "$1");
  s = s.replace(/!\(\s*([^)]+?)\s*==\s*([^)]+?)\s*\)/g, "($1 != $2)");
  s = s.replace(/!\(\s*([^)]+?)\s*!=\s*([^)]+?)\s*\)/g, "($1 == $2)");
  s = s.replace(/\s*&&\s*/g, " && ");
  s = s.replace(/\s*\|\|\s*/g, " || ");
  s = s.replace(/^else\s*&&\s*/g, "");
  s = s.replace(/\s*&&\s*else$/g, "");
  s = s.replace(/\belse\s*&&\s*/g, "");
  s = s.replace(/\s*&&\s*else\b/g, "");
  s = s.replace(/\(\s*else\s*\)\s*&&\s*/g, "");
  s = s.replace(/\s*&&\s*\(\s*else\s*\)/g, "");
  s = s.replace(/\(\s*else\s*\)/g, "else");
  s = s.replace(/\b([A-Za-z_]\w*)\s*==\s*1'b1\b/g, "$1");
  s = s.replace(/\b([A-Za-z_]\w*)\s*!=\s*1'b0\b/g, "$1");
  s = s.replace(/\b([A-Za-z_]\w*)\s*==\s*1'b0\b/g, "!$1");
  s = s.replace(/\b([A-Za-z_]\w*)\s*!=\s*1'b1\b/g, "!$1");
  s = trimOuterParens(s);
  if (!s) return "else";
  return s;
}

function parseBalanced(str, start, openCh, closeCh) {
  if (str[start] !== openCh) return null;
  let depth = 0;
  let i = start;
  while (i < str.length) {
    const ch = str[i];
    if (ch === openCh) depth++;
    else if (ch === closeCh) {
      depth--;
      if (depth === 0) {
        return {
          text: str.slice(start + 1, i),
          end: i + 1,
        };
      }
    }
    i++;
  }
  return null;
}

function isWordBoundary(str, idx) {
  if (idx < 0 || idx >= str.length) return true;
  return !/[A-Za-z0-9_]/.test(str[idx]);
}

function startsKeyword(str, i, kw) {
  if (i + kw.length > str.length) return false;
  if (str.slice(i, i + kw.length) !== kw) return false;
  return isWordBoundary(str, i - 1) && isWordBoundary(str, i + kw.length);
}

function skipWs(str, i) {
  while (i < str.length && /\s/.test(str[i])) i++;
  return i;
}

function parseStatements(blockText, nextVar) {
  const str = blockText;
  let i = 0;

  function parseUntilSemicolon(pos) {
    let p = pos;
    let paren = 0;
    while (p < str.length) {
      const ch = str[p];
      if (ch === "(") paren++;
      else if (ch === ")") paren = Math.max(paren - 1, 0);
      else if (ch === ";" && paren === 0) {
        return {
          text: str.slice(pos, p + 1),
          end: p + 1,
        };
      }
      p++;
    }
    return { text: str.slice(pos), end: str.length };
  }

  function consumeKeyword(pos, kw) {
    if (!startsKeyword(str, pos, kw)) return null;
    return pos + kw.length;
  }

  function parseStatement(pos) {
    let p = skipWs(str, pos);
    if (p >= str.length) return { node: null, end: p };

    let q = consumeKeyword(p, "begin");
    if (q != null) {
      const body = [];
      p = q;
      while (p < str.length) {
        p = skipWs(str, p);
        if (startsKeyword(str, p, "end")) {
          p += 3;
          return {
            node: { type: "block", body },
            end: p,
          };
        }
        const parsed = parseStatement(p);
        if (!parsed.node) {
          p = parsed.end;
          continue;
        }
        body.push(parsed.node);
        p = parsed.end;
      }
      return { node: { type: "block", body }, end: p };
    }

    q = consumeKeyword(p, "if");
    if (q != null) {
      p = skipWs(str, q);
      if (str[p] !== "(") {
        const skipped = parseUntilSemicolon(p);
        return { node: { type: "noop" }, end: skipped.end };
      }
      const condBlock = parseBalanced(str, p, "(", ")");
      if (!condBlock) {
        return { node: { type: "noop" }, end: str.length };
      }
      const cond = normalizeCond(condBlock.text);
      p = condBlock.end;

      const thenParsed = parseStatement(p);
      let elseNode = null;
      p = thenParsed.end;
      p = skipWs(str, p);

      if (startsKeyword(str, p, "else")) {
        p += 4;
        const elseParsed = parseStatement(p);
        elseNode = elseParsed.node;
        p = elseParsed.end;
      }

      return {
        node: {
          type: "if",
          cond,
          then: thenParsed.node || { type: "noop" },
          else: elseNode,
        },
        end: p,
      };
    }

    q = consumeKeyword(p, "case");
    if (q != null) {
      p = skipWs(str, q);
      if (str[p] === "(") {
        const caseExpr = parseBalanced(str, p, "(", ")");
        p = caseExpr ? caseExpr.end : p;
      }
      let depth = 1;
      while (p < str.length && depth > 0) {
        if (startsKeyword(str, p, "case")) {
          depth++;
          p += 4;
          continue;
        }
        if (startsKeyword(str, p, "endcase")) {
          depth--;
          p += 7;
          continue;
        }
        p++;
      }
      return { node: { type: "noop" }, end: p };
    }

    const plain = parseUntilSemicolon(p);
    const assignRe = new RegExp(`\\b${nextVar}\\b\\s*(?:<=|=)\\s*([A-Za-z_]\\w*)\\b`);
    const m = plain.text.match(assignRe);
    if (m) {
      return {
        node: {
          type: "assign",
          to: m[1],
        },
        end: plain.end,
      };
    }
    return { node: { type: "noop" }, end: plain.end };
  }

  const nodes = [];
  while (i < str.length) {
    const parsed = parseStatement(i);
    if (!parsed.node) break;
    nodes.push(parsed.node);
    if (parsed.end <= i) break;
    i = parsed.end;
  }
  return { type: "block", body: nodes };
}

function extractAlwaysBlocks(src) {
  const blocks = [];
  const re = /(?:always\s*@\s*(?:\([^)]*\)|\*)|always_comb|always_ff|always_latch)\s*begin/gi;
  let m;
  while ((m = re.exec(src)) !== null) {
    const startBegin = m[0].toLowerCase().lastIndexOf("begin");
    const beginPos = m.index + startBegin;
    let i = beginPos + 5;
    let depth = 1;
    while (i < src.length && depth > 0) {
      if (startsKeyword(src, i, "begin")) {
        depth++;
        i += 5;
        continue;
      }
      if (startsKeyword(src, i, "end")) {
        depth--;
        i += 3;
        continue;
      }
      i++;
    }
    blocks.push({
      beginPos,
      endPos: i,
      text: src.slice(beginPos, i),
      header: src.slice(m.index, beginPos).trim(),
    });
  }
  return blocks;
}

function pushStateVarCandidate(candidates, seen, curVar, nextVar) {
  if (!curVar || !nextVar || curVar === nextVar) return;
  const key = `${curVar}\0${nextVar}`;
  if (seen.has(key)) return;
  seen.add(key);
  candidates.push({ curVar, nextVar });
}

function detectStateVarCandidates(cleanSrc, alwaysBlocks) {
  const candidates = [];
  const seen = new Set();
  const regNames = new Set();
  const regDeclRe = /\b(?:reg|logic)\b\s*(?:\[[^\]]+\]\s*)?([^;]+);/g;
  let m;
  while ((m = regDeclRe.exec(cleanSrc)) !== null) {
    const decl = m[1] || "";
    const parts = decl.split(",");
    for (const p of parts) {
      const mm = p.trim().match(/^([A-Za-z_]\w*)/);
      if (mm) regNames.add(mm[1]);
    }
  }

  const regs = [...regNames];
  for (const cur of regs) {
    const curLow = cur.toLowerCase();
    if (!/cur|state/.test(curLow)) continue;
    const preferred = [
      `${cur}_d`,
      `${cur}d`,
      `${cur}_next`,
      `${cur}_nxt`,
      `next_${cur}`,
      `nxt_${cur}`,
    ];
    for (const cand of preferred) {
      if (regNames.has(cand)) pushStateVarCandidate(candidates, seen, cur, cand);
    }
  }

  for (const blk of alwaysBlocks) {
    if (!/posedge|negedge/i.test(blk.header || "")) continue;
    const assignRe = /\b([A-Za-z_]\w*)\b\s*<=\s*([A-Za-z_]\w*)\b\s*;/g;
    let am;
    while ((am = assignRe.exec(blk.text)) !== null) {
      const lhs = am[1];
      const rhs = am[2];
      const lhsLow = lhs.toLowerCase();
      const rhsLow = rhs.toLowerCase();
      if (lhs === rhs) continue;
      if (!/cur|state/.test(lhsLow)) continue;
      const rhsLooksNext =
        /next|nxt/.test(rhsLow) ||
        rhsLow.endsWith("_d") ||
        rhsLow === `${lhsLow}_d` ||
        rhsLow === `${lhsLow}d`;
      if (rhsLooksNext) pushStateVarCandidate(candidates, seen, lhs, rhs);
    }
  }

  for (const blk of alwaysBlocks) {
    const caseM = blk.text.match(/case\s*\(\s*([A-Za-z_]\w*)\s*\)/);
    if (!caseM) continue;
    const curVar = caseM[1];
    const assignRe = new RegExp(`\\b([A-Za-z_]\\w*)\\b\\s*(?:<=|=)\\s*\\b${curVar}\\b\\s*;`);
    const a = blk.text.match(assignRe);
    if (a) {
      pushStateVarCandidate(candidates, seen, curVar, a[1]);
    }
  }

  return candidates;
}

function detectStateVars(cleanSrc, alwaysBlocks) {
  const candidates = detectStateVarCandidates(cleanSrc, alwaysBlocks);
  return candidates[0] || null;
}

function findNextStateBlock(alwaysBlocks, curVar, nextVar) {
  let best = null;
  for (const blk of alwaysBlocks) {
    if (!new RegExp(`\\b${nextVar}\\b`).test(blk.text)) continue;
    const hasCase = new RegExp(`\\bcase\\s*\\(\\s*${curVar}\\s*\\)`).test(blk.text);
    const score =
      (hasCase ? 20 : 0) +
      (new RegExp(`\\b${nextVar}\\s*(?:<=|=)\\s*${curVar}\\b`).test(blk.text) ? 10 : 0) +
      (blk.text.match(new RegExp(`\\b${nextVar}\\s*(?:<=|=)`, "g")) || []).length;
    if (!best || score > best.score) {
      best = { block: blk, score };
    }
  }
  return best ? best.block : null;
}

function extractCaseBody(blockText, curVar) {
  const caseRe = new RegExp(`\\bcase\\s*\\(\\s*${curVar}\\s*\\)`, "m");
  const m = blockText.match(caseRe);
  if (!m) return null;
  const caseStart = m.index;
  let i = caseStart + m[0].length;
  let depth = 1;
  while (i < blockText.length && depth > 0) {
    if (startsKeyword(blockText, i, "case")) {
      depth++;
      i += 4;
      continue;
    }
    if (startsKeyword(blockText, i, "endcase")) {
      depth--;
      if (depth === 0) {
        return blockText.slice(caseStart + m[0].length, i);
      }
      i += 7;
      continue;
    }
    i++;
  }
  return null;
}

function extractCaseItems(caseBody) {
  const lines = caseBody.split(/\r?\n/);
  const items = [];
  let cur = null;
  let depth = 0;
  let caseDepth = 0;

  for (const rawLine of lines) {
    const line = rawLine;
    const trimmed = line.trim();
    const topLevel = depth === 0 && caseDepth === 0;
    const m = topLevel ? trimmed.match(/^([A-Za-z_]\w*|default)\s*:\s*(.*)$/) : null;
    if (m) {
      if (cur) items.push(cur);
      cur = { label: m[1], text: (m[2] || "") + "\n" };
      depth += countWord(m[2], "begin") - countWord(m[2], "end");
      caseDepth += countWord(m[2], "case") - countWord(m[2], "endcase");
      if (depth < 0) depth = 0;
      if (caseDepth < 0) caseDepth = 0;
      continue;
    }
    if (cur) cur.text += line + "\n";
    depth += countWord(trimmed, "begin") - countWord(trimmed, "end");
    caseDepth += countWord(trimmed, "case") - countWord(trimmed, "endcase");
    if (depth < 0) depth = 0;
    if (caseDepth < 0) caseDepth = 0;
  }
  if (cur) items.push(cur);
  return items;
}

function parseStates(blockText, caseItems, nextVar, curVar) {
  const st = new Set();
  for (const it of caseItems) {
    if (it.label.toLowerCase() !== "default") st.add(it.label);
  }

  function addStateToken(tok) {
    if (!tok) return;
    if (tok === curVar || tok === nextVar) return;
    st.add(tok);
  }

  const assignRe = new RegExp(`\\b${nextVar}\\b\\s*(?:<=|=)\\s*([A-Za-z_]\\w*)\\b`, "g");
  let m;
  while ((m = assignRe.exec(blockText)) !== null) {
    addStateToken(m[1]);
  }

  const cmpRe1 = new RegExp(`\\b${curVar}\\b\\s*(?:==|!=)\\s*([A-Za-z_]\\w*)\\b`, "g");
  while ((m = cmpRe1.exec(blockText)) !== null) {
    addStateToken(m[1]);
  }

  const cmpRe2 = new RegExp(`([A-Za-z_]\\w*)\\b\\s*(?:==|!=)\\s*\\b${curVar}\\b`, "g");
  while ((m = cmpRe2.exec(blockText)) !== null) {
    addStateToken(m[1]);
  }

  return st;
}

function addEdge(edgeMap, from, to, cond) {
  if (!from || !to) return;
  const k = `${from}->${to}`;
  if (!edgeMap.has(k)) {
    edgeMap.set(k, { from, to, conds: [] });
  }
  const label = prettifyCond(cond);
  if (!edgeMap.get(k).conds.includes(label)) {
    edgeMap.get(k).conds.push(label);
  }
}

function collectEdgesFromAst(ast, fromState, pathCond, edgeMap, validStates) {
  if (!ast) return;
  if (ast.type === "block") {
    for (const n of ast.body || []) {
      collectEdgesFromAst(n, fromState, pathCond, edgeMap, validStates);
    }
    return;
  }
  if (ast.type === "assign") {
    if (validStates.has(ast.to)) {
      addEdge(edgeMap, fromState, ast.to, pathCond);
    }
    return;
  }
  if (ast.type === "if") {
    const thenCond = combineCond(pathCond, ast.cond);
    collectEdgesFromAst(ast.then, fromState, thenCond, edgeMap, validStates);
    if (ast.else) {
      const elseCond = combineCond(pathCond, "else");
      collectEdgesFromAst(ast.else, fromState, elseCond, edgeMap, validStates);
    }
  }
}

function parseStateCond(cond, curVar, validStates) {
  const c = normalizeCond(cond || "");
  if (!c) return null;
  const reEq1 = new RegExp(`\\b${curVar}\\b\\s*==\\s*([A-Za-z_]\\w*)\\b`);
  const reEq2 = new RegExp(`([A-Za-z_]\\w*)\\b\\s*==\\s*\\b${curVar}\\b`);
  const reNe1 = new RegExp(`\\b${curVar}\\b\\s*!=\\s*([A-Za-z_]\\w*)\\b`);
  const reNe2 = new RegExp(`([A-Za-z_]\\w*)\\b\\s*!=\\s*\\b${curVar}\\b`);

  let m = c.match(reEq1) || c.match(reEq2);
  if (m && validStates.has(m[1])) return { op: "eq", st: m[1] };
  m = c.match(reNe1) || c.match(reNe2);
  if (m && validStates.has(m[1])) return { op: "ne", st: m[1] };
  return null;
}

function applyStateCond(baseStates, parsed) {
  const base = new Set(baseStates);
  if (!parsed) return { thenSet: new Set(base), elseSet: new Set(base) };
  if (parsed.op === "eq") {
    const thenSet = new Set(base.has(parsed.st) ? [parsed.st] : []);
    const elseSet = new Set([...base].filter((s) => s !== parsed.st));
    return { thenSet, elseSet };
  }
  const thenSet = new Set([...base].filter((s) => s !== parsed.st));
  const elseSet = new Set(base.has(parsed.st) ? [parsed.st] : []);
  return { thenSet, elseSet };
}

function collectEdgesFromAstWithState(ast, curVar, allStates, pathCond, edgeMap, validStates, activeStates) {
  if (!ast) return;
  const current = activeStates || new Set(allStates);

  if (ast.type === "block") {
    for (const n of ast.body || []) {
      collectEdgesFromAstWithState(n, curVar, allStates, pathCond, edgeMap, validStates, current);
    }
    return;
  }

  if (ast.type === "assign") {
    if (!validStates.has(ast.to)) return;
    for (const from of current) {
      addEdge(edgeMap, from, ast.to, pathCond);
    }
    return;
  }

  if (ast.type === "if") {
    const thenCond = combineCond(pathCond, ast.cond);
    const parsed = parseStateCond(ast.cond, curVar, validStates);
    const { thenSet, elseSet } = applyStateCond(current, parsed);
    if (thenSet.size > 0) {
      collectEdgesFromAstWithState(ast.then, curVar, allStates, thenCond, edgeMap, validStates, thenSet);
    }
    if (ast.else && elseSet.size > 0) {
      const elseCond = combineCond(pathCond, "else");
      collectEdgesFromAstWithState(ast.else, curVar, allStates, elseCond, edgeMap, validStates, elseSet);
    }
  }
}

function truncateLabelPart(s, limit = 34) {
  const t = (s || "").replace(/\s+/g, " ").trim();
  if (!t) return "";
  if (t.length <= limit) return t;
  return `${t.slice(0, Math.max(limit - 3, 1)).trim()}...`;
}

function wrapPlainLabel(s, limit = 34) {
  const t = (s || "").replace(/\s+/g, " ").trim();
  if (!t) return [];
  if (t.length <= limit) return [t];
  return [truncateLabelPart(t, limit)];
}

function wrapLabel(text, limit = 34) {
  const s = (text || "").replace(/\s+/g, " ").trim();
  if (!s) return [];

  if (!/&&|\|\|/.test(s)) {
    return wrapPlainLabel(s, limit);
  }

  const tokens = s.split(/\s*(&&|\|\|)\s*/).filter((x) => x && x.trim());
  if (tokens.length <= 1) {
    return wrapPlainLabel(s, limit);
  }

  const lines = [];
  lines.push(...wrapPlainLabel(tokens[0], limit));
  for (let i = 1; i < tokens.length; i += 2) {
    const op = (tokens[i] || "").trim();
    const rhs = (tokens[i + 1] || "").trim();
    const chunk = `${op} ${rhs}`.trim();
    lines.push(truncateLabelPart(chunk, limit));
  }

  if (lines.length > 4) {
    const keep = lines.slice(0, 4);
    keep[3] = truncateLabelPart(`${keep[3]} ...`, limit);
    return keep;
  }
  return lines;
}

function cleanExpr(expr) {
  return (expr || "")
    .replace(/\s+/g, " ")
    .replace(/^\((.*)\)$/g, "$1")
    .trim();
}

function formatOutputLine(lhs, rhs) {
  let r = cleanExpr(rhs);
  r = r.replace(/\b1'b1\b/g, "1");
  r = r.replace(/\b1'b0\b/g, "0");
  return `${lhs}=${r}`;
}

function outputLineSortKey(line) {
  if (/=1$/.test(line)) return `0:${line}`;
  if (/=0$/.test(line)) return `2:${line}`;
  return `1:${line}`;
}

function addStateOutput(map, state, line) {
  if (!state || !line) return;
  if (!map.has(state)) map.set(state, []);
  const arr = map.get(state);
  if (!arr.includes(line)) arr.push(line);
}

function parseSimpleAssignments(blockText) {
  const assigns = [];
  const re = /\b([A-Za-z_]\w*)\b\s*=\s*([^;]+);/g;
  let m;
  while ((m = re.exec(blockText)) !== null) {
    assigns.push({
      lhs: m[1],
      rhs: cleanExpr(m[2]),
    });
  }
  return assigns;
}

function parseStatePredicate(rhs, curVar, validStates) {
  const expr = trimOuterParens(cleanExpr(rhs));
  const eq1 = new RegExp(`^\\b${curVar}\\b\\s*==\\s*([A-Za-z_]\\w*)\\b$`);
  const eq2 = new RegExp(`^([A-Za-z_]\\w*)\\b\\s*==\\s*\\b${curVar}\\b$`);
  const ne1 = new RegExp(`^\\b${curVar}\\b\\s*!=\\s*([A-Za-z_]\\w*)\\b$`);
  const ne2 = new RegExp(`^([A-Za-z_]\\w*)\\b\\s*!=\\s*\\b${curVar}\\b$`);
  let m = expr.match(eq1) || expr.match(eq2);
  if (m && validStates.has(m[1])) return { op: "eq", state: m[1] };
  m = expr.match(ne1) || expr.match(ne2);
  if (m && validStates.has(m[1])) return { op: "ne", state: m[1] };
  return null;
}

function extractStateOutputs(alwaysBlocks, curVar, nextVar, states) {
  const validStates = new Set(states || []);
  const outputs = new Map();

  for (const blk of alwaysBlocks) {
    if (!/\balways_comb\b|always\s*@\s*\*/i.test(blk.header || "")) continue;
    if (!new RegExp(`\\b${curVar}\\b`).test(blk.text)) continue;

    const assigns = parseSimpleAssignments(blk.text)
      .filter((a) => a.lhs !== nextVar && !/NxtState$/i.test(a.lhs));
    if (!assigns.length) continue;

    const predicateAssigns = [];
    const unconditionalAssigns = [];
    for (const a of assigns) {
      const pred = parseStatePredicate(a.rhs, curVar, validStates);
      if (pred) {
        predicateAssigns.push({ ...a, pred });
      } else {
        unconditionalAssigns.push(a);
      }
    }

    const activeStates = new Set();
    for (const a of predicateAssigns) {
      if (a.pred.op === "eq") {
        addStateOutput(outputs, a.pred.state, `${a.lhs}=1`);
        activeStates.add(a.pred.state);
      } else {
        addStateOutput(outputs, a.pred.state, `${a.lhs}=0`);
        for (const st of validStates) {
          if (st !== a.pred.state) {
            addStateOutput(outputs, st, `${a.lhs}=1`);
            activeStates.add(st);
          }
        }
      }
    }

    for (const a of unconditionalAssigns) {
      const targets = activeStates.size ? activeStates : validStates;
      for (const st of targets) {
        addStateOutput(outputs, st, formatOutputLine(a.lhs, a.rhs));
      }
    }
  }

  const out = {};
  for (const st of validStates) {
    const lines = outputs.get(st) || [];
    if (lines.length) {
      out[st] = lines
        .slice()
        .sort((a, b) => outputLineSortKey(a).localeCompare(outputLineSortKey(b)))
        .slice(0, 5);
    }
  }
  return out;
}

function pickEdgeLabel(conds) {
  if (!conds || !conds.length) return "next cycle";
  const clean = conds.map((c) => prettifyCond(c));
  const canon = clean.map((c) => {
    let t = c;
    t = t.replace(/\(\s*else\s*\)/g, "else");
    t = t.replace(/\belse\s*&&\s*/g, "");
    t = t.replace(/\s*&&\s*else\b/g, "");
    t = t.replace(/\belse\b/g, "");
    t = t.replace(/\s+/g, " ").trim();
    t = t.replace(/^&&\s*/g, "").replace(/\s*&&$/g, "").trim();
    return t || "else";
  });

  const nonElse = canon.filter((c) => c !== "else");

  if (nonElse.length === 1 && canon.length === 2) {
    return nonElse[0];
  }

  const pool = nonElse.length ? nonElse : canon;
  const picked = pool.slice().sort((a, b) => a.length - b.length)[0];
  if (pool.length > 1) {
    return `${picked}  ( +${pool.length - 1} )`;
  }
  return picked;
}

function shouldHideLabel(label) {
  const t = (label || "").trim().toLowerCase();
  return !t || t === "next cycle" || t === "else";
}

function pickSingleDirectionEdge(a, b, startState) {
  if (startState) {
    if (a.from === startState && b.from !== startState) return a;
    if (b.from === startState && a.from !== startState) return b;
  }
  const ac = (a.conds || []).length;
  const bc = (b.conds || []).length;
  if (ac !== bc) return ac >= bc ? a : b;
  const ak = `${a.from}->${a.to}`;
  const bk = `${b.from}->${b.to}`;
  return ak.localeCompare(bk) <= 0 ? a : b;
}

function collapseBidirectionalEdges(edgeList, startState) {
  const pairMap = new Map();
  const selfEntries = [];
  let removed = 0;

  edgeList.forEach((e, idx) => {
    const edge = {
      from: e.from,
      to: e.to,
      conds: Array.isArray(e.conds) ? [...e.conds] : [],
    };
    if (edge.from === edge.to) {
      selfEntries.push({ edge, idx });
      return;
    }

    const a = edge.from < edge.to ? edge.from : edge.to;
    const b = edge.from < edge.to ? edge.to : edge.from;
    const pairKey = `${a}|${b}`;

    if (!pairMap.has(pairKey)) {
      pairMap.set(pairKey, { edge, idx });
      return;
    }

    const prev = pairMap.get(pairKey);
    if (prev.edge.from === edge.to && prev.edge.to === edge.from) {
      const picked = pickSingleDirectionEdge(prev.edge, edge, startState);
      if (picked === prev.edge) {
        removed += 1;
      } else {
        pairMap.set(pairKey, { edge, idx });
        removed += 1;
      }
      return;
    }

    for (const c of edge.conds) {
      if (!prev.edge.conds.includes(c)) prev.edge.conds.push(c);
    }
  });

  const merged = [
    ...selfEntries,
    ...[...pairMap.values()],
  ].sort((x, y) => x.idx - y.idx).map((x) => x.edge);

  return { edges: merged, removed };
}

function qPoint(p0, p1, p2, t) {
  const u = 1 - t;
  const x = u * u * p0.x + 2 * u * t * p1.x + t * t * p2.x;
  const y = u * u * p0.y + 2 * u * t * p1.y + t * t * p2.y;
  return { x, y };
}

function cPoint(p0, p1, p2, p3, t) {
  const u = 1 - t;
  const x = u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x;
  const y = u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y;
  return { x, y };
}

function sampleQuadratic(p0, p1, p2, steps = 28) {
  const pts = [];
  for (let i = 0; i <= steps; i++) {
    pts.push(qPoint(p0, p1, p2, i / steps));
  }
  return pts;
}

function sampleCubic(p0, p1, p2, p3, steps = 30) {
  const pts = [];
  for (let i = 0; i <= steps; i++) {
    pts.push(cPoint(p0, p1, p2, p3, i / steps));
  }
  return pts;
}

function labelBox(centerX, centerY, lines, fontSize = 11) {
  const maxLen = Math.max(1, ...lines.map((l) => (l || "").length));
  const w = Math.max(44, Math.round(maxLen * (fontSize * 0.66) + 12));
  const h = Math.max(18, Math.round(lines.length * 14 + 8));
  return {
    x: centerX - w / 2,
    y: centerY - h / 2,
    w,
    h,
    cx: centerX,
    cy: centerY,
  };
}

function pointInExpandedRect(px, py, rect, pad = 0) {
  return (
    px >= rect.x - pad &&
    px <= rect.x + rect.w + pad &&
    py >= rect.y - pad &&
    py <= rect.y + rect.h + pad
  );
}

function rectOverlap(a, b, pad = 0) {
  return !(
    a.x + a.w + pad < b.x ||
    b.x + b.w + pad < a.x ||
    a.y + a.h + pad < b.y ||
    b.y + b.h + pad < a.y
  );
}

function rectHitsPath(rect, points, pad = 3) {
  for (const p of points) {
    if (pointInExpandedRect(p.x, p.y, rect, pad)) return true;
  }
  return false;
}

function chooseLabelPlacement(baseX, baseY, nx, ny, tx, ty, lines, pathSamples, usedRects, blockedRects) {
  const normalOffsets = [16, -16, 28, -28, 42, -42, 58, -58, 76, -76];
  const tangentOffsets = [0, 12, -12, 24, -24];
  let best = null;

  for (const no of normalOffsets) {
    for (const to of tangentOffsets) {
      const cx = baseX + nx * no + tx * to;
      const cy = baseY + ny * no + ty * to;
      const rect = labelBox(cx, cy, lines, 10);
      let score = 0;

      for (const pts of pathSamples) {
        if (rectHitsPath(rect, pts, 5)) score += 24;
      }
      for (const r of blockedRects) {
        if (rectOverlap(rect, r, 5)) score += 40;
      }
      for (const r of usedRects) {
        if (rectOverlap(rect, r, 6)) score += 46;
      }

      score += Math.abs(no) * 0.1 + Math.abs(to) * 0.08;
      if (!best || score < best.score) {
        best = { score, cx, cy, rect };
        if (score === 0) return best;
      }
    }
  }
  return best || { score: 9999, cx: baseX, cy: baseY, rect: labelBox(baseX, baseY, lines, 10) };
}

function layoutStates(states, startState, edges, stateOutputs = {}) {
  const sorted = states.slice().sort();
  const outAdj = new Map();
  const inDeg = new Map();
  for (const s of sorted) {
    outAdj.set(s, new Set());
    inDeg.set(s, 0);
  }
  for (const e of edges) {
    if (!outAdj.has(e.from)) outAdj.set(e.from, new Set());
    outAdj.get(e.from).add(e.to);
    inDeg.set(e.to, (inDeg.get(e.to) || 0) + 1);
  }

  const scoreState = (s) => (outAdj.get(s)?.size || 0) + (inDeg.get(s) || 0);
  const root = startState && sorted.includes(startState) ? startState : (sorted[0] || null);
  const remaining = new Set(sorted);
  const order = [];

  if (root && remaining.has(root)) {
    order.push(root);
    remaining.delete(root);
  }

  while (remaining.size) {
    const cur = order.length ? order[order.length - 1] : null;
    let pick = null;
    if (cur && outAdj.has(cur)) {
      const candidates = [...outAdj.get(cur)].filter((s) => remaining.has(s));
      if (candidates.length) {
        candidates.sort((a, b) => {
          const ds = scoreState(b) - scoreState(a);
          if (ds !== 0) return ds;
          return a.localeCompare(b);
        });
        pick = candidates[0];
      }
    }
    if (!pick) {
      const rem = [...remaining];
      rem.sort((a, b) => {
        const ds = scoreState(b) - scoreState(a);
        if (ds !== 0) return ds;
        return a.localeCompare(b);
      });
      pick = rem[0];
    }
    order.push(pick);
    remaining.delete(pick);
  }

  const n = Math.max(order.length, 1);
  const baseNodeH = 48;
  const widths = new Map();
  const heights = new Map();
  let maxW = 0;
  for (const s of order) {
    const outputLines = Array.isArray(stateOutputs[s]) ? stateOutputs[s] : [];
    const outputMaxLen = outputLines.reduce((acc, line) => Math.max(acc, String(line).length), 0);
    const w = Math.max(96, Math.min(260, Math.max(s.length * 10 + 40, outputMaxLen * 6.7 + 34)));
    const h = baseNodeH + outputLines.length * 13;
    widths.set(s, w);
    heights.set(s, h);
    maxW = Math.max(maxW, w);
  }

  const radiusX = Math.max(170, n * 40 + maxW * 0.2);
  const radiusY = Math.max(130, n * 32);
  const centerX = radiusX + maxW + 85;
  const centerY = radiusY + 110;

  const nodes = new Map();
  const indexMap = new Map();
  const orderMap = new Map();

  for (let i = 0; i < order.length; i++) {
    const st = order[i];
    const angle = (-Math.PI / 2) + ((2 * Math.PI * i) / n);
    const w = widths.get(st);
    const h = heights.get(st) || baseNodeH;
    const cx = centerX + radiusX * Math.cos(angle);
    const cy = centerY + radiusY * Math.sin(angle);
    nodes.set(st, {
      x: cx - w / 2,
      y: cy - h / 2,
      w,
      h,
      cx,
      cy,
      rx: w / 2,
      ry: h / 2,
    });
    indexMap.set(st, i);
    orderMap.set(st, i);
  }

  const width = Math.ceil(centerX + radiusX + maxW + 90);
  const height = Math.ceil(centerY + radiusY + 110);
  return { nodes, width, height, indexMap, orderMap, orderList: order, centerX, centerY, total: n };
}

function ellipseBoundary(cx, cy, rx, ry, dx, dy) {
  const den = Math.sqrt((dx * dx) / (rx * rx) + (dy * dy) / (ry * ry)) || 1;
  const t = 1 / den;
  return {
    x: cx + dx * t,
    y: cy + dy * t,
  };
}

function renderSvg({
  moduleName,
  nextVar,
  startState,
  states,
  edgeList,
  outFile,
  stateOutputs = {},
}) {
  const { nodes, width, height, orderMap, orderList, centerX, centerY, total } = layoutStates(states, startState, edgeList, stateOutputs);
  const edgeKeySet = new Set(edgeList.map((e) => `${e.from}->${e.to}`));
  const pairCurveSign = new Map();

  function pairKeyOf(a, b) {
    return a < b ? `${a}|${b}` : `${b}|${a}`;
  }

  for (const e of edgeList) {
    if (e.from === e.to) continue;
    if (!edgeKeySet.has(`${e.to}->${e.from}`)) continue;
    const pk = pairKeyOf(e.from, e.to);
    if (pairCurveSign.has(pk)) continue;
    const a = nodes.get(e.from);
    const b = nodes.get(e.to);
    if (!a || !b) {
      pairCurveSign.set(pk, 1);
      continue;
    }
    const dx = b.cx - a.cx;
    const dy = b.cy - a.cy;
    const len = Math.sqrt(dx * dx + dy * dy) || 1;
    const px = -dy / len;
    const py = dx / len;
    const mx = (a.cx + b.cx) / 2;
    const my = (a.cy + b.cy) / 2;
    const rvx = mx - centerX;
    const rvy = my - centerY;
    const dot = rvx * px + rvy * py;
    pairCurveSign.set(pk, dot >= 0 ? 1 : -1);
  }

  const outMap = new Map();
  for (const e of edgeList) {
    if (!outMap.has(e.from)) outMap.set(e.from, []);
    outMap.get(e.from).push(e);
  }
  for (const [k, arr] of outMap.entries()) {
    arr.sort((a, b) => `${a.to}`.localeCompare(`${b.to}`));
    outMap.set(k, arr);
  }

  const edgeGeoms = [];
  for (const e of edgeList) {
    const a = nodes.get(e.from);
    const b = nodes.get(e.to);
    if (!a || !b) continue;

    const labelRaw = pickEdgeLabel(e.conds);
    const wrapped = shouldHideLabel(labelRaw) ? [] : wrapLabel(labelRaw, 34);

    if (e.from === e.to) {
      let vx = a.cx - centerX;
      let vy = a.cy - centerY;
      let vlen = Math.sqrt(vx * vx + vy * vy);
      if (vlen < 1e-6) {
        vx = 1;
        vy = -1;
        vlen = Math.sqrt(2);
      }
      const ox = vx / vlen;
      const oy = vy / vlen;
      const nx = -oy;
      const ny = ox;
      const base = ellipseBoundary(a.cx, a.cy, a.rx, a.ry, ox, oy);
      const loopR = Math.max(8, Math.min(12, Math.min(a.rx, a.ry) * 0.34));
      const sx = base.x + nx * (loopR * 0.52);
      const sy = base.y + ny * (loopR * 0.52);
      const tx = base.x - nx * (loopR * 0.52);
      const ty = base.y - ny * (loopR * 0.52);
      const loopDepth = loopR * 2.25;
      const c1x = base.x + ox * loopDepth + nx * (loopR * 1.15);
      const c1y = base.y + oy * loopDepth + ny * (loopR * 1.15);
      const c2x = base.x + ox * loopDepth - nx * (loopR * 1.15);
      const c2y = base.y + oy * loopDepth - ny * (loopR * 1.15);
      const d = `M ${sx.toFixed(2)} ${sy.toFixed(2)} C ${c1x.toFixed(2)} ${c1y.toFixed(2)}, ${c2x.toFixed(2)} ${c2y.toFixed(2)}, ${tx.toFixed(2)} ${ty.toFixed(2)}`;
      edgeGeoms.push({
        d,
        samples: sampleCubic(
          { x: sx, y: sy },
          { x: c1x, y: c1y },
          { x: c2x, y: c2y },
          { x: tx, y: ty },
          30
        ),
        labelLines: wrapped,
        baseX: base.x + ox * (loopDepth + loopR * 1.4),
        baseY: base.y + oy * (loopDepth + loopR * 1.4),
        nx: ox,
        ny: oy,
        tx: nx,
        ty: ny,
      });
      continue;
    }

    const dx = b.cx - a.cx;
    const dy = b.cy - a.cy;
    const len = Math.sqrt(dx * dx + dy * dy) || 1;
    const s = ellipseBoundary(a.cx, a.cy, a.rx, a.ry, dx, dy);
    const t = ellipseBoundary(b.cx, b.cy, b.rx, b.ry, -dx, -dy);
    const px = -dy / len;
    const py = dx / len;
    const outEdges = outMap.get(e.from) || [];
    const outIdx = Math.max(0, outEdges.findIndex((x) => x.from === e.from && x.to === e.to));
    const fan = (outIdx - (outEdges.length - 1) / 2) * 16;
    const iFrom = orderMap.get(e.from) || 0;
    const iTo = orderMap.get(e.to) || 0;
    const stepCw = (iTo - iFrom + total) % total;
    const stepCcw = (iFrom - iTo + total) % total;
    const hop = Math.min(stepCw, stepCcw);
    const cwShort = stepCw <= stepCcw;
    const dir = cwShort ? 1 : -1;
    const mx = (s.x + t.x) / 2;
    const my = (s.y + t.y) / 2;

    let cx;
    let cy;
    let lx;
    let ly;

    const longJumpThreshold = Math.max(2, Math.floor(total / 3));
    let labelNx = px;
    let labelNy = py;
    let labelTx = dx / len;
    let labelTy = dy / len;
    if (hop >= longJumpThreshold) {
      let vx = mx - centerX;
      let vy = my - centerY;
      let vlen = Math.sqrt(vx * vx + vy * vy);
      if (vlen < 1e-6) {
        vx = px;
        vy = py;
        vlen = 1;
      }
      const ox = vx / vlen;
      const oy = vy / vlen;
      const bulge = 28 + hop * 10;
      cx = mx + ox * bulge + px * (fan * 0.7);
      cy = my + oy * bulge + py * (fan * 0.7);
      lx = 0.25 * s.x + 0.5 * cx + 0.25 * t.x + ox * 9;
      ly = 0.25 * s.y + 0.5 * cy + 0.25 * t.y + oy * 9;
      labelNx = ox;
      labelNy = oy;
      labelTx = px;
      labelTy = py;
    } else {
      const hasReverse = edgeKeySet.has(`${e.to}->${e.from}`);
      let curve;
      if (hasReverse) {
        const pk = pairKeyOf(e.from, e.to);
        const sign = pairCurveSign.get(pk) || 1;
        const separation = 42 + hop * 7;
        curve = sign * separation + fan * 0.6;
      } else {
        curve = dir * (14 + hop * 5) + fan;
      }
      cx = mx + px * curve;
      cy = my + py * curve;
      lx = 0.25 * s.x + 0.5 * cx + 0.25 * t.x + px * 10;
      ly = 0.25 * s.y + 0.5 * cy + 0.25 * t.y + py * 10;
    }

    let rvx = lx - centerX;
    let rvy = ly - centerY;
    const rvlen = Math.sqrt(rvx * rvx + rvy * rvy);
    if (rvlen > 1e-6) {
      rvx /= rvlen;
      rvy /= rvlen;
      lx += rvx * 10;
      ly += rvy * 10;
    }

    const d = `M ${s.x.toFixed(2)} ${s.y.toFixed(2)} Q ${cx.toFixed(2)} ${cy.toFixed(2)}, ${t.x.toFixed(2)} ${t.y.toFixed(2)}`;
    edgeGeoms.push({
      d,
      samples: sampleQuadratic({ x: s.x, y: s.y }, { x: cx, y: cy }, { x: t.x, y: t.y }, 28),
      labelLines: wrapped,
      baseX: lx,
      baseY: ly,
      nx: labelNx,
      ny: labelNy,
      tx: labelTx,
      ty: labelTy,
    });
  }

  const nodeRects = orderList.map((st) => {
    const n = nodes.get(st);
    return {
      x: n.x - 6,
      y: n.y - 6,
      w: n.w + 12,
      h: n.h + 12,
    };
  });
  const pathSamples = edgeGeoms.map((g) => g.samples);
  const usedLabelRects = [];
  const labelItems = [];

  for (const g of edgeGeoms) {
    if (!g.labelLines.length) continue;
    const placed = chooseLabelPlacement(
      g.baseX,
      g.baseY,
      g.nx,
      g.ny,
      g.tx,
      g.ty,
      g.labelLines,
      pathSamples,
      usedLabelRects,
      nodeRects
    );
    usedLabelRects.push(placed.rect);
    labelItems.push({
      lines: g.labelLines,
      x: placed.cx,
      y: placed.cy,
      rect: placed.rect,
    });
  }

  const lines = [];
  lines.push('<?xml version="1.0" encoding="UTF-8"?>');
  lines.push(`<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">`);
  lines.push(`<defs><marker id="arrow" markerWidth="10" markerHeight="7" refX="9" refY="3.5" orient="auto" markerUnits="strokeWidth"><polygon points="0 0, 10 3.5, 0 7" fill="#000"/></marker></defs>`);
  lines.push(`<style>
  .node{fill:#ffffff;stroke:#000;stroke-width:1.2}
  .node-start{fill:#ffffff;stroke:#000;stroke-width:2.2}
  .node-text{font-family:Helvetica,Arial,sans-serif;font-size:13px;font-weight:600;text-anchor:middle;dominant-baseline:middle;fill:#000}
  .node-output{font-family:Helvetica,Arial,sans-serif;font-size:10px;font-weight:400;text-anchor:middle;dominant-baseline:middle;fill:#333}
  .edge{stroke:#000;stroke-width:1.2;fill:none}
  .label-bg{fill:#fff;fill-opacity:0.95;stroke:none}
  .label{font-family:Helvetica,Arial,sans-serif;font-size:11px;fill:#000;text-anchor:middle;dominant-baseline:middle}
  </style>`);

  for (const g of edgeGeoms) {
    lines.push(`<path class="edge" d="${g.d}" marker-end="url(#arrow)"/>`);
  }

  for (const st of orderList) {
    const n = nodes.get(st);
    if (!n) continue;
    const cls = st === startState ? "node-start" : "node";
    lines.push(`<ellipse class="${cls}" cx="${n.cx.toFixed(2)}" cy="${n.cy.toFixed(2)}" rx="${n.rx.toFixed(2)}" ry="${n.ry.toFixed(2)}"/>`);
    const outputLines = Array.isArray(stateOutputs[st]) ? stateOutputs[st] : [];
    const titleY = outputLines.length ? n.cy - ((outputLines.length + 1) * 6.5) : n.cy;
    lines.push(`<text class="node-text" x="${n.cx.toFixed(2)}" y="${titleY.toFixed(2)}">${escapeXml(st)}</text>`);
    outputLines.forEach((line, idx) => {
      const y = titleY + 16 + idx * 13;
      lines.push(`<text class="node-output" x="${n.cx.toFixed(2)}" y="${y.toFixed(2)}">${escapeXml(line)}</text>`);
    });
  }

  for (const lb of labelItems) {
    lines.push(`<rect class="label-bg" x="${lb.rect.x.toFixed(2)}" y="${lb.rect.y.toFixed(2)}" width="${lb.rect.w.toFixed(2)}" height="${lb.rect.h.toFixed(2)}" rx="2" ry="2"/>`);
    const firstY = lb.y - ((lb.lines.length - 1) * 14) / 2;
    lines.push(`<text class="label" x="${lb.x.toFixed(2)}" y="${firstY.toFixed(2)}">`);
    lb.lines.forEach((w, idx) => lines.push(`<tspan x="${lb.x.toFixed(2)}" dy="${idx === 0 ? 0 : 14}">${escapeXml(w)}</tspan>`));
    lines.push(`</text>`);
  }

  lines.push(`</svg>`);
  fs.mkdirSync(path.dirname(outFile), { recursive: true });
  fs.writeFileSync(outFile, lines.join("\n"), "utf8");
}

function hasGraphvizDot() {
  try {
    const r = cp.spawnSync("dot", ["-V"], { encoding: "utf8" });
    return !r.error && r.status === 0;
  } catch {
    return false;
  }
}

function escapeDotLabel(s) {
  return String(s)
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')
    .replace(/\n/g, "\\n");
}

function renderSvgGraphviz({
  startState,
  states,
  edgeList,
  outFile,
  stateOutputs = {},
}) {
  const stateList = states.slice().sort();
  const dot = [];
  dot.push("digraph FSM {");
  dot.push('graph [layout=circo, overlap=false, splines=curved, outputorder=edgesfirst, pad="0.25"];');
  dot.push('node [shape=ellipse, style="filled", fillcolor="white", color="black", fontname="Helvetica", fontsize=12, penwidth=1.2];');
  dot.push('edge [color="black", fontname="Helvetica", fontsize=10, arrowsize=0.8, penwidth=1.1, labelfloat=true];');
  dot.push('label="";');

  for (const st of stateList) {
    const attrs = [];
    if (st === startState) attrs.push("penwidth=2.2");
    const outputLines = Array.isArray(stateOutputs[st]) ? stateOutputs[st] : [];
    if (outputLines.length) {
      attrs.push(`label="${escapeDotLabel([st, ...outputLines].join("\n"))}"`);
    }
    dot.push(`"${escapeDotLabel(st)}" [${attrs.join(", ")}];`);
  }

  for (const e of edgeList) {
    const labelRaw = pickEdgeLabel(e.conds);
    const wrapped = shouldHideLabel(labelRaw) ? [] : wrapLabel(labelRaw, 34);
    const attrs = [];
    if (wrapped.length) {
      attrs.push(`label="${escapeDotLabel(wrapped.join("\n"))}"`);
    }
    dot.push(`"${escapeDotLabel(e.from)}" -> "${escapeDotLabel(e.to)}" [${attrs.join(", ")}];`);
  }

  dot.push("}");

  const tmpDot = `${outFile}.dot.tmp`;
  fs.mkdirSync(path.dirname(outFile), { recursive: true });
  fs.writeFileSync(tmpDot, dot.join("\n"), "utf8");
  try {
    cp.execFileSync("dot", ["-Kcirco", "-Tsvg", tmpDot, "-o", outFile], { stdio: "pipe" });
  } finally {
    if (fs.existsSync(tmpDot)) fs.unlinkSync(tmpDot);
  }
}

function parseFsmFromStateVars(alwaysBlocks, vars, index = 0) {
  const block = findNextStateBlock(alwaysBlocks, vars.curVar, vars.nextVar);
  if (!block) {
    return { ok: false, reason: `Next-state combinational block not found for ${vars.curVar}/${vars.nextVar}.` };
  }

  const caseBody = extractCaseBody(block.text, vars.curVar);
  const caseItems = caseBody ? extractCaseItems(caseBody) : [];

  const stateSet = parseStates(block.text, caseItems, vars.nextVar, vars.curVar);
  const edgeMap = new Map();
  let startState = null;

  if (caseItems.length) {
    const listedStates = new Set();
    let defaultItem = null;

    for (const item of caseItems) {
      const from = item.label;
      if (from.toLowerCase() === "default") {
        defaultItem = item;
        continue;
      }
      listedStates.add(from);
      if (!startState) startState = from;
      const ast = parseStatements(item.text, vars.nextVar);
      collectEdgesFromAst(ast, from, "", edgeMap, stateSet);
    }

    if (defaultItem) {
      const missing = [...stateSet].filter((s) => !listedStates.has(s));
      if (!startState && missing.length) startState = missing[0];
      if (missing.length) {
        const ast = parseStatements(defaultItem.text, vars.nextVar);
        for (const from of missing) {
          collectEdgesFromAst(ast, from, "", edgeMap, stateSet);
        }
      }
    }
  } else {
    const allStates = [...stateSet];
    if (!allStates.length) {
      return { ok: false, reason: `No states parsed for ${vars.curVar}.` };
    }
    startState = allStates[0];
    const ast = parseStatements(block.text, vars.nextVar);
    collectEdgesFromAstWithState(ast, vars.curVar, allStates, "", edgeMap, stateSet, null);
  }

  if (!edgeMap.size) {
    return { ok: false, reason: "No transitions parsed from next-state assignments." };
  }

  const states = [...stateSet];
  const edges = [...edgeMap.values()];
  const stateOutputs = extractStateOutputs(alwaysBlocks, vars.curVar, vars.nextVar, states);
  return {
    ok: true,
    index,
    id: `fsm_${index}`,
    curVar: vars.curVar,
    nextVar: vars.nextVar,
    states,
    edges,
    startState,
    stateOutputs,
  };
}

function parseFsmsFromVerilog(filePath) {
  const srcRaw = fs.readFileSync(filePath, "utf8");
  const src = stripComments(srcRaw);
  const alwaysBlocks = extractAlwaysBlocks(src);
  if (!alwaysBlocks.length) {
    return { ok: false, reason: "No always @(*) begin ... end block found.", fsms: [] };
  }

  const candidates = detectStateVarCandidates(src, alwaysBlocks);
  if (!candidates.length) {
    return { ok: false, reason: "State vars not detected.", fsms: [] };
  }

  const fsms = [];
  const skipped = [];
  for (const vars of candidates) {
    const parsed = parseFsmFromStateVars(alwaysBlocks, vars, fsms.length);
    if (parsed.ok) {
      fsms.push({
        ...parsed,
        index: fsms.length,
        id: `fsm_${fsms.length}`,
      });
    } else {
      skipped.push({
        curVar: vars.curVar,
        nextVar: vars.nextVar,
        reason: parsed.reason || "FSM parse failed.",
      });
    }
  }

  if (!fsms.length) {
    return {
      ok: false,
      reason: skipped[0]?.reason || "No transitions parsed from detected state variables.",
      fsms: [],
      skipped,
    };
  }

  return { ok: true, fsms, skipped };
}

function parseFsmFromVerilog(filePath) {
  const result = parseFsmsFromVerilog(filePath);
  if (!result.ok) return { ok: false, reason: result.reason };
  return result.fsms[0];
}

function main() {
  const args = process.argv.slice(2);
  const verilogPath = argValue(args, "--verilog");
  const outSvg = argValue(args, "--out");
  const outJson = argValue(args, "--out-json");
  const metaOnly = args.includes("--meta-only");
  const moduleName = argValue(args, "--module") || "fsm";
  const engineArg = (argValue(args, "--engine") || "auto").toLowerCase();
  const directionArg = (argValue(args, "--direction") || "both").toLowerCase();

  if (!verilogPath || (!metaOnly && !outSvg)) {
    usage();
    process.exit(2);
  }

  if (!fs.existsSync(verilogPath)) {
    console.error(`[ERROR] Verilog file not found: ${verilogPath}`);
    process.exit(2);
  }

  const info = parseFsmFromVerilog(verilogPath);
  const emitMeta = (payload) => {
    const text = JSON.stringify(payload, null, 2);
    if (outJson) {
      fs.mkdirSync(path.dirname(outJson), { recursive: true });
      fs.writeFileSync(outJson, text, "utf8");
    } else {
      process.stdout.write(`${text}\n`);
    }
  };

  if (!info.ok) {
    if (metaOnly) {
      emitMeta({
        ok: false,
        module: moduleName,
        file: path.resolve(verilogPath),
        reason: info.reason || "FSM parse failed.",
        states: [],
        edges: 0,
      });
    }
    console.error(`[ERROR] ${info.reason}`);
    process.exit(1);
  }

  if (metaOnly) {
    emitMeta({
      ok: true,
      module: moduleName,
      file: path.resolve(verilogPath),
      curVar: info.curVar || "",
      nextVar: info.nextVar || "",
      startState: info.startState || null,
      states: info.states || [],
      stateOutputs: info.stateOutputs || {},
      edges: Array.isArray(info.edges) ? info.edges.length : 0,
    });
    process.exit(0);
  }

  let renderEdges = info.edges;
  if (directionArg !== "both") {
    const collapsed = collapseBidirectionalEdges(renderEdges, info.startState);
    renderEdges = collapsed.edges;
    if (collapsed.removed > 0) {
      console.log(`[INFO] Single-direction mode: removed ${collapsed.removed} reverse edge(s).`);
    }
  }

  const dotOk = hasGraphvizDot();
  let engine = engineArg;
  if (!["auto", "native", "graphviz"].includes(engine)) {
    engine = "auto";
  }
  if (engine === "auto") {
    engine = dotOk && info.edges.length > info.states.length * 1.6 ? "graphviz" : "native";
  }
  if (engine === "graphviz" && !dotOk) {
    console.error("[WARN] Graphviz 'dot' not found. Falling back to native renderer.");
    engine = "native";
  }

  if (engine === "graphviz") {
    renderSvgGraphviz({
      moduleName,
      nextVar: info.nextVar,
      startState: info.startState,
      states: info.states,
      edgeList: renderEdges,
      stateOutputs: info.stateOutputs || {},
      outFile: outSvg,
    });
  } else {
    renderSvg({
      moduleName,
      nextVar: info.nextVar,
      startState: info.startState,
      states: info.states,
      edgeList: renderEdges,
      stateOutputs: info.stateOutputs || {},
      outFile: outSvg,
    });
  }

  console.log(`[SUCCESS] Parsed FSM from source: states=${info.states.length}, edges=${info.edges.length}`);
  if (renderEdges.length !== info.edges.length) {
    console.log(`[INFO] Rendered edges: ${renderEdges.length}`);
  }
  console.log(`[INFO] Render engine: ${engine}`);
  console.log(`[SUCCESS] Generated SVG: ${outSvg}`);
  process.exit(0);
}

if (require.main === module) {
  main();
}

module.exports = {
  parseFsmFromVerilog,
  parseFsmsFromVerilog,
  renderSvg,
  renderSvgGraphviz,
  collapseBidirectionalEdges,
  hasGraphvizDot,
  main,
};
