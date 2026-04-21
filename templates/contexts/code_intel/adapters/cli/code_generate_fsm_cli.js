const path = require("path");
const {
  parseFsmFromVerilog,
  parseFsmsFromVerilog,
  renderSvg,
  renderSvgGraphviz,
  collapseBidirectionalEdges,
  hasGraphvizDot,
} = require("../../application/fsm_extractor");

function usage() {
  console.log("Usage: node tools/generate_fsm_from_verilog.js --verilog <file.(v|sv)> --out <file.svg> [--module <name>] [--engine auto|native|graphviz] [--direction single|both]");
  console.log("   or: node tools/generate_fsm_from_verilog.js --verilog <file.(v|sv)> [--module <name>] --meta-only [--out-json <file.json>]");
}

function argValue(args, key) {
  const idx = args.indexOf(key);
  if (idx < 0 || idx + 1 >= args.length) return null;
  return args[idx + 1];
}

function indexedOutPath(outSvg, index, total) {
  if (total <= 1) return outSvg;
  const ext = path.extname(outSvg) || ".svg";
  const base = outSvg.slice(0, outSvg.length - ext.length);
  return `${base}_${index}${ext}`;
}

function renderOneFsm({ info, moduleName, outSvg, engineArg, directionArg, dotOk }) {
  let renderEdges = info.edges;
  if (directionArg !== "both") {
    const collapsed = collapseBidirectionalEdges(renderEdges, info.startState);
    renderEdges = collapsed.edges;
    if (collapsed.removed > 0) {
      console.log(`[INFO] ${info.curVar}: single-direction mode removed ${collapsed.removed} reverse edge(s).`);
    }
  }

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

  const renderArgs = {
    moduleName,
    nextVar: info.nextVar,
    startState: info.startState,
    states: info.states,
    edgeList: renderEdges,
    stateOutputs: info.stateOutputs || {},
    outFile: outSvg,
  };

  if (engine === "graphviz") {
    renderSvgGraphviz(renderArgs);
  } else {
    renderSvg(renderArgs);
  }

  console.log(`[SUCCESS] Parsed FSM ${info.index}: cur=${info.curVar}, next=${info.nextVar}, states=${info.states.length}, edges=${info.edges.length}`);
  if (renderEdges.length !== info.edges.length) {
    console.log(`[INFO] Rendered edges: ${renderEdges.length}`);
  }
  console.log(`[INFO] Render engine: ${engine}`);
  console.log(`[SUCCESS] Generated SVG: ${outSvg}`);
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

  const fs = require("fs");
  if (!fs.existsSync(verilogPath)) {
    console.error(`[ERROR] Verilog file not found: ${verilogPath}`);
    process.exit(2);
  }

  const result = parseFsmsFromVerilog(verilogPath);
  const emitMeta = (payload) => {
    const text = JSON.stringify(payload, null, 2);
    if (outJson) {
      fs.mkdirSync(path.dirname(outJson), { recursive: true });
      fs.writeFileSync(outJson, text, "utf8");
    } else {
      process.stdout.write(`${text}\n`);
    }
  };

  if (!result.ok) {
    if (metaOnly) {
      emitMeta({
        ok: false,
        module: moduleName,
        file: path.resolve(verilogPath),
        reason: result.reason || "FSM parse failed.",
        states: [],
        fsms: [],
        edges: 0,
      });
    }
    console.error(`[ERROR] ${result.reason}`);
    process.exit(1);
  }

  const fsms = result.fsms || [];
  const first = fsms[0] || parseFsmFromVerilog(verilogPath);

  if (metaOnly) {
    emitMeta({
      ok: true,
      module: moduleName,
      file: path.resolve(verilogPath),
      curVar: first.curVar || "",
      nextVar: first.nextVar || "",
      startState: first.startState || null,
      states: first.states || [],
      edges: Array.isArray(first.edges) ? first.edges.length : 0,
      fsmCount: fsms.length,
      fsms: fsms.map((info) => ({
        index: info.index,
        id: info.id,
        curVar: info.curVar || "",
        nextVar: info.nextVar || "",
        startState: info.startState || null,
        states: info.states || [],
        stateOutputs: info.stateOutputs || {},
        edges: Array.isArray(info.edges) ? info.edges.length : 0,
      })),
    });
    process.exit(0);
  }

  const dotOk = hasGraphvizDot();
  for (let i = 0; i < fsms.length; i += 1) {
    const info = fsms[i];
    const indexedOutSvg = indexedOutPath(outSvg, i, fsms.length);
    const indexedModuleName = fsms.length > 1 ? `${moduleName} FSM ${i}` : moduleName;
    renderOneFsm({
      info,
      moduleName: indexedModuleName,
      outSvg: indexedOutSvg,
      engineArg,
      directionArg,
      dotOk,
    });
  }

  console.log(`[SUCCESS] Generated FSM diagram count: ${fsms.length}`);
}

if (require.main === module) {
  main();
}

module.exports = {
  parseFsmFromVerilog,
  parseFsmsFromVerilog,
};
