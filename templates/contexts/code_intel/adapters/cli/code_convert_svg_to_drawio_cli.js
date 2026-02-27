const fs = require("fs");
const xml2js = require("xml2js");

// Parse arguments: node svg2drawio.js <input.svg> <output.drawio>
const inputFile = process.argv[2] || "schematic.svg";
const outputFile = process.argv[3] || "schematic.drawio";

// SCALE FACTOR: Expand everything by 1.5x to retrieve space for text
const SCALE = 1.0;
const SIMPLE_PORT_CHAR_WIDTH = 8;
const SIMPLE_MODULE_CHAR_WIDTH = 11;
const SIMPLE_MIN_WIDTH = 200;
const SIMPLE_MAX_WIDTH = 700;
const SIMPLE_LABEL_PADDING = 32;
const LEGACY_SIMPLE_BOX_WIDTHS = [300, 400];
const PREFER_NATIVE_GATE_SHAPES = false;

console.log(`[JS] Converting ${inputFile} -> ${outputFile} with SCALE=${SCALE}`);

// Basic Draw.io XML Template
const builder = new xml2js.Builder({ renderOpts: { pretty: true } });

let g_nextId = 2;
function nextId() {
  return (g_nextId++).toString();
}

function createMxCell(id, value, style, vertex, parent, geom) {
  const cell = {
    $: {
      id,
      value,
      style,
      vertex: vertex ? "1" : undefined,
      edge: vertex ? undefined : "1",
      parent: parent || "1",
    },
    mxGeometry: [
      {
        $: {
          x: geom.x !== undefined ? geom.x : undefined,
          y: geom.y !== undefined ? geom.y : undefined,
          width: geom.width,
          height: geom.height,
          as: "geometry",
          relative: geom.relative ? "1" : undefined,
        },
      },
    ],
  };

  if (geom.sourcePoint) {
    cell.mxGeometry[0].mxPoint = [
      { $: { x: geom.sourcePoint.x, y: geom.sourcePoint.y, as: "sourcePoint" } },
      { $: { x: geom.targetPoint.x, y: geom.targetPoint.y, as: "targetPoint" } },
    ];
  }
  if (Array.isArray(geom.waypoints) && geom.waypoints.length > 0) {
    cell.mxGeometry[0].Array = [
      {
        $: { as: "points" },
        mxPoint: geom.waypoints.map((p) => ({ $: { x: p.x, y: p.y } })),
      },
    ];
  }
  return cell;
}

function parseTransform(transformStr) {
  let x = 0;
  let y = 0;
  if (transformStr) {
    const translateMatch = transformStr.match(/translate\(([^,]+),([^)]+)\)/);
    if (translateMatch) {
      x = parseFloat(translateMatch[1]);
      y = parseFloat(translateMatch[2]);
    }
  }
  // Apply Global Scale immediately
  return { x: x * SCALE, y: y * SCALE };
}

function isNear(a, b, tol = 0.75) {
  return Math.abs(a - b) <= tol;
}

function safeParseFloat(v, fallback = 0) {
  const n = parseFloat(v);
  return Number.isFinite(n) ? n : fallback;
}

function isNetlistJunctionCircle(attrs) {
  if (!attrs) return false;
  const className = attrs.class || "";
  const styleText = `${attrs.style || ""};fill:${attrs.fill || ""}`;
  const hasNetClass = className.startsWith("net_");
  const hasBlackFill = /fill\s*:\s*(#000(?:000)?|black)\b/i.test(styleText);
  const r = safeParseFloat(attrs.r, 0);
  return r > 0 && (hasNetClass || hasBlackFill);
}

function parseSimplePathGeometry(d) {
  if (!d || typeof d !== "string") return null;

  const q = d.match(/M\s*([-\d.]+)\s+([-\d.]+)\s+Q\s*([-\d.]+)\s+([-\d.]+),?\s*([-\d.]+)\s+([-\d.]+)/i);
  if (q) {
    return {
      type: "Q",
      x1: safeParseFloat(q[1]) * SCALE,
      y1: safeParseFloat(q[2]) * SCALE,
      cx1: safeParseFloat(q[3]) * SCALE,
      cy1: safeParseFloat(q[4]) * SCALE,
      x2: safeParseFloat(q[5]) * SCALE,
      y2: safeParseFloat(q[6]) * SCALE,
    };
  }

  const c = d.match(/M\s*([-\d.]+)\s+([-\d.]+)\s+C\s*([-\d.]+)\s+([-\d.]+),?\s*([-\d.]+)\s+([-\d.]+),?\s*([-\d.]+)\s+([-\d.]+)/i);
  if (c) {
    return {
      type: "C",
      x1: safeParseFloat(c[1]) * SCALE,
      y1: safeParseFloat(c[2]) * SCALE,
      cx1: safeParseFloat(c[3]) * SCALE,
      cy1: safeParseFloat(c[4]) * SCALE,
      cx2: safeParseFloat(c[5]) * SCALE,
      cy2: safeParseFloat(c[6]) * SCALE,
      x2: safeParseFloat(c[7]) * SCALE,
      y2: safeParseFloat(c[8]) * SCALE,
    };
  }

  return null;
}

function getSimpleLayoutProfile(svg) {
  const rects = svg.rect || [];
  if (!rects.length) return null;

  const texts = svg.text || [];
  const boxRect = rects.find((r) => ((r.$?.class || "").includes("box"))) || rects[0];
  if (!boxRect || !boxRect.$) return null;

  const boxX = parseFloat(boxRect.$.x || 0) * SCALE;
  const oldBoxWidth = parseFloat(boxRect.$.width || 0) * SCALE;
  if (!Number.isFinite(boxX) || !Number.isFinite(oldBoxWidth) || oldBoxWidth <= 0) {
    return null;
  }

  const moduleNameText = texts.find((t) => (t.$?.class || "").includes("module-name") && typeof t._ === "string");
  const moduleNameLen = moduleNameText ? moduleNameText._.length : 0;
  const maxPortLabelLen = texts
    .filter((t) => (t.$?.class || "").includes("port-label") && typeof t._ === "string")
    .reduce((maxLen, t) => Math.max(maxLen, t._.length), 0);

  const requiredWidthRaw = Math.max(
    maxPortLabelLen * SIMPLE_PORT_CHAR_WIDTH + SIMPLE_LABEL_PADDING,
    moduleNameLen * SIMPLE_MODULE_CHAR_WIDTH + 24
  );

  const newBoxWidthRaw = Math.max(SIMPLE_MIN_WIDTH, Math.min(SIMPLE_MAX_WIDTH, requiredWidthRaw));
  const shouldAdjustLegacyWidth = LEGACY_SIMPLE_BOX_WIDTHS.some((w) => isNear(oldBoxWidth, w * SCALE));
  const newBoxWidth = shouldAdjustLegacyWidth ? (newBoxWidthRaw * SCALE) : oldBoxWidth;
  const deltaWidth = newBoxWidth - oldBoxWidth;

  return {
    boxX,
    oldBoxWidth,
    newBoxWidth,
    deltaWidth,
    oldRightX: boxX + oldBoxWidth,
  };
}

function getLogicGateStyle(type) {
  const gateShapeMap = {
    and: "and",
    nand: "nand",
    or: "or",
    nor: "nor",
    xor: "xor",
    reduce_xor: "xor",
    reduce_and: "and",
    reduce_or: "or",
    reduce_bool: "or",
    reduce_xnor: "or",
  };

  if (type === "not") {
    return "shape=mxgraph.electrical.logic_gates.inverter;html=1;whiteSpace=wrap;";
  }

  const shapeName = gateShapeMap[type];
  if (!shapeName) return null;
  return `shape=mxgraph.electrical.logic_gates.${shapeName};html=1;whiteSpace=wrap;`;
}

function getCellBodyStyle(type, g) {
  if (PREFER_NATIVE_GATE_SHAPES) {
    const gateStyle = getLogicGateStyle(type);
    if (gateStyle) return gateStyle;
  }

  const circleTypes = new Set([
    "add", "sub", "mul", "div", "mod",
    "eq", "ne", "ge", "gt", "lt", "le",
    "eqx", "nex", "xnor",
  ]);
  if (circleTypes.has(type) || (Array.isArray(g.circle) && g.circle.length > 0)) {
    return "ellipse;whiteSpace=wrap;html=1;fillColor=#ffffff;strokeColor=#000000;";
  }

  const shiftTypes = new Set(["shiftx", "shl", "shr"]);
  if (shiftTypes.has(type)) {
    return "shape=parallelogram;perimeter=parallelogramPerimeter;whiteSpace=wrap;html=1;fillColor=#ffffff;strokeColor=#000000;";
  }

  // Default to rectangular body for FF/latch and other unsupported custom cells.
  return "rounded=0;whiteSpace=wrap;html=1;";
}

function escapeXmlAttrValue(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function parseInlineStyle(styleText) {
  const map = {};
  String(styleText || "")
    .split(";")
    .forEach((chunk) => {
      const idx = chunk.indexOf(":");
      if (idx < 0) return;
      const key = chunk.slice(0, idx).trim().toLowerCase();
      const val = chunk.slice(idx + 1).trim();
      if (!key) return;
      map[key] = val;
    });
  return map;
}

function sanitizeDrawableAttrs(attrs) {
  const out = {};
  Object.entries(attrs || {}).forEach(([k, v]) => {
    if (k === "class" || k === "id") return;
    if (k.startsWith("s:")) return;
    out[k] = String(v);
  });

  const styleMap = parseInlineStyle(out.style);
  if (!("stroke" in out) && !("stroke" in styleMap)) out.stroke = "#000000";
  if (!("fill" in out) && !("fill" in styleMap)) out.fill = "none";
  if (!("stroke-width" in out) && !("stroke-width" in styleMap)) out["stroke-width"] = "1";
  if (!("stroke-linecap" in out) && !("stroke-linecap" in styleMap)) out["stroke-linecap"] = "round";
  if (!("stroke-linejoin" in out) && !("stroke-linejoin" in styleMap)) out["stroke-linejoin"] = "round";

  return out;
}

function buildSvgElement(tag, attrs) {
  const attrText = Object.entries(attrs || {})
    .map(([k, v]) => `${k}="${escapeXmlAttrValue(v)}"`)
    .join(" ");
  return `<${tag}${attrText ? ` ${attrText}` : ""}/>`;
}

function buildGroupBodyImageStyle(g, rawWidth, rawHeight) {
  const drawableTags = ["path", "rect", "circle", "ellipse", "line", "polyline", "polygon"];
  const chunks = [];

  drawableTags.forEach((tag) => {
    const nodes = Array.isArray(g[tag]) ? g[tag] : [];
    nodes.forEach((node) => {
      const attrs = sanitizeDrawableAttrs(node.$ || {});
      if (!Object.keys(attrs).length) return;
      chunks.push(buildSvgElement(tag, attrs));
    });
  });

  if (!chunks.length) return null;
  const w = Number.isFinite(rawWidth) && rawWidth > 0 ? rawWidth : 40;
  const h = Number.isFinite(rawHeight) && rawHeight > 0 ? rawHeight : 40;
  const marginRaw = 8;

  const symbolSvg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="${-marginRaw} ${-marginRaw} ${w + marginRaw * 2} ${h + marginRaw * 2}">${chunks.join("")}</svg>`;
  const dataUri = `data:image/svg+xml,${encodeURIComponent(symbolSvg)}`;

  return {
    dataUri,
    marginRaw,
    widthRaw: w + marginRaw * 2,
    heightRaw: h + marginRaw * 2,
  };
}

function parseSvgTextNode(textNode) {
  if (!textNode) return null;
  const att = textNode.$ || {};
  const tspanLines = Array.isArray(textNode.tspan)
    ? textNode.tspan
      .map((span) => (typeof span === "string" ? span : (typeof span?._ === "string" ? span._ : "")))
      .map((x) => x.trim())
      .filter(Boolean)
    : [];

  let text = typeof textNode._ === "string" ? textNode._.trim() : "";
  if (!text && tspanLines.length > 0) {
    text = tspanLines.join("<br/>");
  }
  if (!text) return null;

  const className = att.class || "";
  const styleText = att.style || "";
  const styleAnchorMatch = styleText.match(/text-anchor\s*:\s*(start|middle|end)/i);
  const anchor = att["text-anchor"] || styleAnchorMatch?.[1]?.toLowerCase() || (className.includes("nodelabel") ? "middle" : "start");
  let align = "left";
  if (anchor === "middle") align = "center";
  if (anchor === "end") align = "right";
  const styleFontSizeMatch = styleText.match(/font-size\s*:\s*([0-9.]+)px/i);
  const fontSize = safeParseFloat(att["font-size"], safeParseFloat(styleFontSizeMatch?.[1], 10));

  return {
    text,
    x: safeParseFloat(att.x, 0) * SCALE,
    y: safeParseFloat(att.y, 0) * SCALE,
    align,
    className,
    fontSize: Math.max(8, fontSize),
  };
}

function escapeXmlTextContent(text) {
  if (typeof text !== "string") return text;
  // Keep valid entities intact, escape only raw XML-special chars in text nodes.
  return text
    .replace(/&(?!(?:amp|lt|gt|quot|apos|#\d+|#x[0-9A-Fa-f]+);)/g, "&amp;")
    .replace(/</g, "&lt;");
}

function sanitizeSvgTextNodes(svgXml) {
  if (typeof svgXml !== "string") return svgXml;
  // Only escape bare '&' characters that are NOT already part of a valid XML entity.
  // Do NOT escape '<' since <tspan> child tags inside <text> must remain as tags
  // so that xml2js can parse them as child nodes (not as raw text in t._).
  return svgXml.replace(/(<text\b[^>]*>)([\s\S]*?)(<\/text>)/g, (m, open, body, close) => {
    // Escape only bare & that are not already an entity reference
    const escaped = body.replace(/&(?!(?:amp|lt|gt|quot|apos|#\d+|#x[0-9A-Fa-f]+);)/g, "&amp;");
    return `${open}${escaped}${close}`;
  });
}

fs.readFile(inputFile, (err, data) => {
  if (err) {
    console.error("Error reading input file:", err);
    return;
  }

  const parser = new xml2js.Parser();
  const rawSvg = data.toString("utf8");
  const sanitizedSvg = sanitizeSvgTextNodes(rawSvg);
  parser.parseString(sanitizedSvg, (err, result) => {
    if (err) {
      console.error("Error parsing SVG:", err);
      return;
    }

    const svg = result.svg;
    const rootCells = [
      { $: { id: "0" } },
      { $: { id: "1", parent: "0" } },
    ];

    // Detect format
    const isNetlistSvg = !!(svg.g && svg.g[0] && svg.g[0].$["s:type"]);

    if (!isNetlistSvg) {
      // Simple SVG processing
      console.log("[JS] Detected simple SVG format");
      const simpleLayout = getSimpleLayoutProfile(svg);
      if (simpleLayout && Math.abs(simpleLayout.deltaWidth) > 0.01) {
        console.log(`[JS] Simple box width adjusted: ${simpleLayout.oldBoxWidth} -> ${simpleLayout.newBoxWidth}`);
      }

      if (svg.rect) {
        svg.rect.forEach((rect) => {
          const r = rect.$ || {};
          const className = r.class || "";
          // FSM SVG uses label background rectangles only for readability.
          // In Draw.io these look like extra unwanted signal boxes, so skip them.
          if (className.includes("label-bg")) {
            return;
          }
          const x = parseFloat(r.x) * SCALE;
          const y = parseFloat(r.y) * SCALE;
          let w = parseFloat(r.width) * SCALE;
          const h = parseFloat(r.height) * SCALE;
          if (simpleLayout && (r.class || "").includes("box")) {
            w = simpleLayout.newBoxWidth;
          }
          const style = "rounded=0;whiteSpace=wrap;html=1;fillColor=#ffffff;strokeColor=#000000;fontFamily=Helvetica;";

          rootCells.push(createMxCell(nextId(), "", style, true, "1", {
            x, y, width: w, height: h
          }));
        });
      }

      if (svg.ellipse) {
        svg.ellipse.forEach((e) => {
          const att = e.$ || {};
          const cx = safeParseFloat(att.cx) * SCALE;
          const cy = safeParseFloat(att.cy) * SCALE;
          const rx = safeParseFloat(att.rx) * SCALE;
          const ry = safeParseFloat(att.ry) * SCALE;
          if (rx <= 0 || ry <= 0) return;

          const style = "ellipse;whiteSpace=wrap;html=1;fillColor=#ffffff;strokeColor=#000000;";
          rootCells.push(createMxCell(nextId(), "", style, true, "1", {
            x: cx - rx,
            y: cy - ry,
            width: rx * 2,
            height: ry * 2,
          }));
        });
      }

      if (svg.text) {
        svg.text.forEach((t) => {
          const att = t.$ || {};
          const className = att.class || "";
          const classTokens = new Set(className.split(/\s+/).filter(Boolean));
          const tspanLines = Array.isArray(t.tspan)
            ? t.tspan
              .map((span) => (typeof span === "string" ? span : (typeof span?._ === "string" ? span._ : "")))
              .map((x) => x.trim())
              .filter(Boolean)
            : [];
          const multiline = tspanLines.length > 1;
          // t._ may contain raw "<tspan ...>text</tspan>" markup that draw.io cannot render.
          // Always prefer the xml2js-parsed tspanLines array when available.
          let txt = "";
          if (tspanLines.length) {
            txt = multiline ? tspanLines.join("<br/>") : tspanLines[0];
          } else if (typeof t._ === "string") {
            // Strip any residual <tspan> tags and get plain text
            txt = t._.replace(/<tspan[^>]*>([\s\S]*?)<\/tspan>/gi, "$1").replace(/\s+/g, " ").trim();
          }
          if (!txt) return;

          let x = safeParseFloat(att.x, NaN) * SCALE;
          let y = safeParseFloat(att.y, NaN) * SCALE;
          if ((!Number.isFinite(x) || !Number.isFinite(y)) && Array.isArray(t.tspan) && t.tspan[0] && t.tspan[0].$) {
            if (!Number.isFinite(x)) x = safeParseFloat(t.tspan[0].$.x, 0) * SCALE;
            if (!Number.isFinite(y)) y = safeParseFloat(t.tspan[0].$.y, 0) * SCALE;
          }
          if (!Number.isFinite(x)) x = 0;
          if (!Number.isFinite(y)) y = 0;

          // Some FSM SVG texts rely on CSS class-based text-anchor (not inline attr).
          // Preserve visual parity with SVG by inferring center alignment from class.
          let anchor = att["text-anchor"] || (att.class === "module-name" ? "middle" : "start");
          if (classTokens.has("node-text") || classTokens.has("label")) {
            anchor = "middle";
          }

          if (simpleLayout) {
            if (className.includes("module-name")) {
              x = simpleLayout.boxX + simpleLayout.newBoxWidth / 2;
            } else if (className.includes("port-label") && anchor === "end") {
              x += simpleLayout.deltaWidth;
            }
          }

          let align = "left";
          if (anchor === "middle") align = "center";
          if (anchor === "end") align = "right";

          // Font size heuristic
          let fontSize = 12;
          if (att.class === "module-name") fontSize = 16;
          const maxLineLen = multiline ? Math.max(...tspanLines.map((x) => x.length)) : txt.length;
          const w = Math.max(24, maxLineLen * 8);
          const h = multiline ? Math.max(20, tspanLines.length * 14) : 20;

          // Adjust x for alignment because Draw.io x is left-top usually
          let finalX = x;
          if (align === "center") finalX = x - w / 2;
          if (align === "right") finalX = x - w;

          const whiteSpace = multiline ? "wrap" : "nowrap";
          const style = `text;html=1;strokeColor=none;fillColor=none;align=${align};verticalAlign=middle;whiteSpace=${whiteSpace};rounded=0;fontSize=${fontSize};fontFamily=Helvetica;`;

          rootCells.push(createMxCell(nextId(), txt, style, true, "1", {
            x: finalX, y: y - h / 2, width: w, height: h
          }));
        });
      }

      if (svg.line) {
        svg.line.forEach((l) => {
          const att = l.$;
          let x1 = parseFloat(att.x1) * SCALE;
          const y1 = parseFloat(att.y1) * SCALE;
          let x2 = parseFloat(att.x2) * SCALE;
          const y2 = parseFloat(att.y2) * SCALE;

          if (simpleLayout && isNear(x1, simpleLayout.oldRightX) && x2 >= x1) {
            x1 += simpleLayout.deltaWidth;
            x2 += simpleLayout.deltaWidth;
          }

          const style = "endArrow=classic;html=1;rounded=0;";
          rootCells.push(createMxCell(nextId(), "", style, false, "1", {
            sourcePoint: { x: x1, y: y1 },
            targetPoint: { x: x2, y: y2 }
          }));
        });
      }

      if (svg.path) {
        svg.path.forEach((p) => {
          const att = p.$ || {};
          const geo = parseSimplePathGeometry(att.d);
          if (!geo) return;

          const style = "curved=1;endArrow=classic;html=1;rounded=0;";
          const geom = {
            sourcePoint: { x: geo.x1, y: geo.y1 },
            targetPoint: { x: geo.x2, y: geo.y2 },
          };
          if (geo.type === "Q") {
            geom.waypoints = [{ x: geo.cx1, y: geo.cy1 }];
          } else if (geo.type === "C") {
            geom.waypoints = [
              { x: geo.cx1, y: geo.cy1 },
              { x: geo.cx2, y: geo.cy2 },
            ];
          }
          rootCells.push(createMxCell(nextId(), "", style, false, "1", geom));
        });
      }

      if (svg.polygon) {
        // Arrows usually
        // We can try to replace polygons with actual arrows on lines, but for now just drawing them as shapes
        svg.polygon.forEach((p) => {
          const pointsStr = p.$.points;
          // points="x1,y1 x2,y2 ..."
          // Draw.io expects points in geometry or as a shape
          // Let's just create a triangle shape or path
          // For simplicity, skip polygons if they are just arrowheads, assuming lines cover it?
          // "generate_simple_svg.ps1" draws lines AND polygons for arrows.

          // To make it cleaner in DrawIO, we might want to attach arrow style to the lines instead?
          // But matching them is hard. Let's just draw the polygon.

          // Map points to absolute scale
          const pts = pointsStr.split(" ").map(pair => {
            const [px, py] = pair.split(",").map(parseFloat);
            return { x: px * SCALE, y: py * SCALE };
          });

          // Calculate bounding box
          const minX = Math.min(...pts.map(p => p.x));
          const minY = Math.min(...pts.map(p => p.y));
          const maxX = Math.max(...pts.map(p => p.x));
          const maxY = Math.max(...pts.map(p => p.y));
          const w = maxX - minX;
          const h = maxY - minY;

          // Normalize points relative to bbox
          // Draw.io custom shape is complex.
          // Alternative: Use a standard triangle if it looks like one.
          const style = "triangle;whiteSpace=wrap;html=1;fillColor=#000000;strokeColor=none;rotation=-90;"; // Verify rotation?
          // Actually, simply ignoring polygons might be cleaner if we can make lines have arrows.
          // But let's verify generate_simple_svg.ps1. It draws a line then a polygon.

          // Let's just try to map standard arrowHead if possible.
          // For now, let's LEAVE OUT polygons (arrowheads) and just trust lines?
          // Or better, logic to detect lines and add arrows.
          // Simple SVG: line x1,y1 -> x2,y2. 
          // If we assume input lines have arrows at x2,y2 and output lines have arrows at x2,y2?

          // Let's just process lines in Simple SVG mode to Have arrows by default if class='wire'?
          // generate_simple_svg.ps1 uses class="wire" for lines.
        });
      }

      // Update lines to have arrows for Simple Diagram
      // In generate_simple_svg.ps1, inputs are lines ending at the box. Outputs are lines starting from box.
      // Arrows are detached polygons.
      // Let's just force all lines in "Simple" mode to have endArrow=classic if they are wires?
      // But some might not be.
      // Let's just Iterate processed lines above and set endArrow=classic?

      // Re-visiting LINES loop:
      if (svg.line) {
        // Clear previous loop if I want to redo it correctly
      }
    } else {
      console.log("[JS] Detected netlistsvg format");
      const genericInputAnchors = [];
      const deferredOutputPortSymbols = [];
      const netClassEndpoints = new Map();
      const netWireCells = [];

      // 1. Process Modules (svg.g)
      if (svg.g) {
        svg.g.forEach((g) => {
          const attrs = g.$;
          const type = attrs["s:type"];
          const transform = parseTransform(attrs.transform);

          // Get Dimensions & Apply Scale
          const rawWidth = safeParseFloat(attrs["s:width"], 40);
          const rawHeight = safeParseFloat(attrs["s:height"], 40);
          let width = rawWidth * SCALE;
          let height = rawHeight * SCALE;

          // For generic/split/join modules, prefer internal body rect size when present.
          if ((type === "generic" || type === "split" || type === "join") && g.rect) {
            g.rect.forEach((rect) => {
              if (rect.$ && rect.$["s:generic"] === "body") {
                width = parseFloat(rect.$.width || 40) * SCALE;
                height = parseFloat(rect.$.height || 40) * SCALE;
              }
            });
          }

          let style = "rounded=0;whiteSpace=wrap;html=1;";
          let cellX = transform.x;
          let cellY = transform.y;
          let cellW = width;
          let cellH = height;
          let usesImageBody = false;
          const directTexts = Array.isArray(g.text) ? g.text.map(parseSvgTextNode).filter(Boolean) : [];
          const firstDirectText = directTexts.length > 0 ? directTexts[0].text : "";

          // specific styles
          if (type === "generic") {
            style = "rounded=0;whiteSpace=wrap;html=1;fillColor=#ffffff;strokeColor=#000000;fontColor=#000000;fontFamily=Helvetica;";
          } else {
            const bodyImage = buildGroupBodyImageStyle(g, rawWidth, rawHeight);
            if (bodyImage) {
              const margin = bodyImage.marginRaw * SCALE;
              usesImageBody = true;
              cellX = transform.x - margin;
              cellY = transform.y - margin;
              cellW = bodyImage.widthRaw * SCALE;
              cellH = bodyImage.heightRaw * SCALE;
              style = `shape=image;html=1;imageAspect=0;aspect=fixed;strokeColor=none;fillColor=none;image=${bodyImage.dataUri};`;
            } else if (type === "inputExt" || type === "outputExt") {
              style = "text;html=1;align=center;verticalAlign=middle;resizable=0;points=[];autosize=1;strokeColor=none;fillColor=none;fontFamily=Helvetica;";
            } else {
              style = getCellBodyStyle(type, g);
            }
          }

          const cellId = nextId();

          // Draw Main Box
          const vertex = createMxCell(cellId, "", style, true, "1", {
            x: cellX,
            y: cellY,
            width: cellW,
            height: cellH,
          });
          rootCells.push(vertex);

          // Module Name Label (Top Outside)
          if (firstDirectText && type === "generic") {
            const nameWidth = Math.max(width, firstDirectText.length * 8 + 20);
            rootCells.push(createMxCell(nextId(), firstDirectText,
              "text;html=1;strokeColor=none;fillColor=none;align=center;verticalAlign=bottom;whiteSpace=nowrap;rounded=0;fontSize=12;fontStyle=1;fontFamily=Helvetica;",
              true, "1", {
              x: transform.x + (width - nameWidth) / 2,
              y: transform.y - 20,
              width: nameWidth,
              height: 20
            }));
          } else if (firstDirectText && (type === "inputExt" || type === "outputExt")) {
            // For Ext ports, put text on the node
            vertex.$.value = firstDirectText;
            vertex.$.style += "fontSize=11;fontStyle=1;";
          } else if (type !== "generic") {
            // Preserve symbol text inside custom cell bodies (e.g. +, <=, ^~, SH, ===, ...).
            directTexts.forEach((txt) => {
              const plain = txt.text || "";
              if (!plain) return;
              const textLen = plain.replace(/<br\/>/g, "").length;
              const w = Math.max(10, textLen * Math.max(6, txt.fontSize * 0.55) + 6);
              const h = Math.max(12, txt.fontSize + 4);
              const absX = transform.x + txt.x;
              const absY = transform.y + txt.y;
              let finalX = absX;
              if (txt.align === "center") finalX = absX - w / 2;
              if (txt.align === "right") finalX = absX - w;

              rootCells.push(createMxCell(nextId(), plain,
                `text;html=1;strokeColor=none;fillColor=none;align=${txt.align};verticalAlign=middle;whiteSpace=nowrap;rounded=0;fontSize=${txt.fontSize};fontFamily=Helvetica;`,
                true, "1", {
                x: finalX,
                y: absY - h / 2,
                width: w,
                height: h,
              }));
            });
          }

          // Reproduce external port symbol strokes from netlistsvg:
          // - inputExt: plain short line (no arrowhead)
          // - outputExt: short line with one arrowhead
          if (!usesImageBody && type === "inputExt") {
            const sy = transform.y + 10 * SCALE;
            rootCells.push(createMxCell(nextId(), "", "startArrow=none;endArrow=none;edgeStyle=none;html=1;rounded=0;", false, "1", {
              sourcePoint: { x: transform.x + 10 * SCALE, y: sy },
              targetPoint: { x: transform.x + 30 * SCALE, y: sy },
            }));
          } else if (!usesImageBody && type === "outputExt") {
            const sy = transform.y + 10 * SCALE;
            rootCells.push(createMxCell(nextId(), "", "startArrow=none;endArrow=classic;edgeStyle=none;html=1;rounded=0;", false, "1", {
              sourcePoint: { x: transform.x, y: sy },
              targetPoint: { x: transform.x + 20 * SCALE, y: sy },
            }));
          }

          // Process Internal Ports (g.g)
          if (g.g && type === "generic") {
            const ports = [];

            g.g.forEach((childG) => {
              if (!childG.$) return;
              const childTransform = parseTransform(childG.$.transform);

              let portName = "";
              let textAnchor = "start";
              if (childG.text && childG.text[0]) {
                portName = childG.text[0]._ || "";
                textAnchor = childG.text[0].$?.["text-anchor"] || "start";
              }
              if (!portName) return;

              const isOutputPort = childTransform.x > 0 || textAnchor === "end"; // x>0 means right side in netlistsvg generic blocks
              ports.push({
                name: portName,
                isOutput: isOutputPort,
                relX: childTransform.x,
                relY: childTransform.y,
                wireX: transform.x + childTransform.x,
                wireY: transform.y + childTransform.y,
              });
            });

            ports.forEach((port) => {
              let labelStyle = "text;html=1;strokeColor=none;fillColor=none;verticalAlign=middle;whiteSpace=nowrap;rounded=0;fontSize=10;fontFamily=Helvetica;";
              const labelW = port.name.length * 6 + 40; // Approx

              let labelX;
              let align;
              if (port.isOutput) {
                labelX = transform.x + width - labelW - 5;
                align = "right";
              } else {
                labelX = transform.x + 5;
                align = "left";
              }
              labelStyle += `align=${align};`;

              const portY = transform.y + port.relY;
              const portSymbolStyle = "startArrow=none;endArrow=classic;edgeStyle=none;html=1;rounded=0;strokeWidth=1;endSize=6;";

              // Recreate netlistsvg per-port triangles on both input/output sides.
              // input  : x-5 -> x   (arrow points right into module boundary)
              // output : x   -> x+5 (arrow points right away from module boundary)
              if (port.isOutput) {
                deferredOutputPortSymbols.push({
                  x: transform.x + width,
                  y: portY,
                });
              } else {
                rootCells.push(createMxCell(nextId(), "", portSymbolStyle, false, "1", {
                  sourcePoint: { x: transform.x - 5, y: portY },
                  targetPoint: { x: transform.x, y: portY },
                }));
                genericInputAnchors.push({
                  x: transform.x + port.relX,
                  y: transform.y + port.relY,
                });
              }

              const portLabelCell = createMxCell(nextId(), port.name, labelStyle, true, "1", {
                x: labelX,
                y: portY - 6, // center vertically
                width: labelW,
                height: 12
              });
              rootCells.push(portLabelCell);

              // Keep wire anchor at the original net endpoint for bus-width probing.
              portLabelCell._portInfo = {
                x: port.wireX,
                y: port.wireY,
                name: port.name
              };
            });
          }

          // Render labeled port names for non-generic symbols as text cells.
          // This keeps D/Q/A/B/Y labels visible in Draw.io for custom skin cells.
          if (g.g && type !== "generic" && type !== "split" && type !== "join") {
            g.g.forEach((childG) => {
              if (!childG || !childG.$ || !Array.isArray(childG.text)) return;
              const childTransform = parseTransform(childG.$.transform);
              const wireX = transform.x + safeParseFloat(childG.$["s:x"], childTransform.x);
              const wireY = transform.y + safeParseFloat(childG.$["s:y"], childTransform.y);

              childG.text.forEach((t) => {
                const txt = parseSvgTextNode(t);
                if (!txt || !txt.text) return;
                const textLen = txt.text.replace(/<br\/>/g, "").length;
                const w = Math.max(10, textLen * Math.max(6, txt.fontSize * 0.55) + 6);
                const h = Math.max(12, txt.fontSize + 4);
                const absX = transform.x + childTransform.x + txt.x;
                const absY = transform.y + childTransform.y + txt.y;

                let finalX = absX;
                if (txt.align === "center") finalX = absX - w / 2;
                if (txt.align === "right") finalX = absX - w;

                const portLabelCell = createMxCell(nextId(), txt.text,
                  `text;html=1;strokeColor=none;fillColor=none;align=${txt.align};verticalAlign=middle;whiteSpace=nowrap;rounded=0;fontSize=${txt.fontSize};fontFamily=Helvetica;`,
                  true, "1", {
                  x: finalX,
                  y: absY - h / 2,
                  width: w,
                  height: h,
                });
                rootCells.push(portLabelCell);

                const plainName = txt.text.replace(/<br\/>/g, "").trim();
                if (plainName) {
                  portLabelCell._portInfo = {
                    x: wireX,
                    y: wireY,
                    name: plainName,
                  };
                }
              });
            });
          }

          // Render split/join child labels (bit indices / ranges), e.g. 0, 1, 0:11.
          if (g.g && (type === "split" || type === "join")) {
            g.g.forEach((childG) => {
              if (!childG || !childG.$ || !Array.isArray(childG.text)) return;
              const childTransform = parseTransform(childG.$.transform);

              childG.text.forEach((t) => {
                const tAtt = t.$ || {};
                const className = tAtt.class || "";

                let txt = typeof t._ === "string" ? t._.trim() : "";
                if (!txt && Array.isArray(t.tspan)) {
                  const lines = t.tspan
                    .map((span) => (typeof span === "string" ? span : (typeof span?._ === "string" ? span._ : "")))
                    .map((x) => x.trim())
                    .filter(Boolean);
                  if (lines.length > 0) {
                    txt = lines.join("<br/>");
                  }
                }
                if (!txt) return;

                const tx = safeParseFloat(tAtt.x, 0) * SCALE;
                const ty = safeParseFloat(tAtt.y, 0) * SCALE;
                const absX = transform.x + childTransform.x + tx;
                const absY = transform.y + childTransform.y + ty;

                let anchor = tAtt["text-anchor"] || "start";
                // skin.svg uses CSS class for split/join left labels instead of inline attr.
                if (!tAtt["text-anchor"] && className.includes("inputPortLabel")) {
                  anchor = "end";
                }

                let align = "left";
                if (anchor === "middle") align = "center";
                if (anchor === "end") align = "right";

                const textLen = txt.replace(/<br\/>/g, "").length;
                const w = Math.max(10, textLen * 7 + 2);
                const h = 12;

                let finalX = absX;
                if (align === "center") finalX = absX - w / 2;
                if (align === "right") finalX = absX - w;

                const whiteSpace = txt.includes("<br/>") ? "wrap" : "nowrap";
                const style = `text;html=1;strokeColor=none;fillColor=none;align=${align};verticalAlign=middle;whiteSpace=${whiteSpace};rounded=0;fontSize=10;fontFamily=Helvetica;`;
                rootCells.push(createMxCell(nextId(), txt, style, true, "1", {
                  x: finalX,
                  y: absY - 6,
                  width: w,
                  height: h,
                }));
              });
            });
          }
        });
      }

      // 2. Process Wires (svg.line) & Collect Bus Widths
      const wireEndpoints = new Map(); // "x,y" (SCALED) -> bitWidth

      if (svg.line) {
        svg.line.forEach((line) => {
          const attrs = line.$;
          const x1 = parseFloat(attrs.x1) * SCALE;
          const y1 = parseFloat(attrs.y1) * SCALE;
          const x2 = parseFloat(attrs.x2) * SCALE;
          const y2 = parseFloat(attrs.y2) * SCALE;

          let bitWidth = 1;
          if (attrs.class && attrs.class.startsWith("net_")) {
            bitWidth = attrs.class.split(",").length;
          }

          const k1 = `${Math.round(x1)},${Math.round(y1)}`;
          const k2 = `${Math.round(x2)},${Math.round(y2)}`;

          wireEndpoints.set(k1, Math.max(wireEndpoints.get(k1) || 1, bitWidth));
          wireEndpoints.set(k2, Math.max(wireEndpoints.get(k2) || 1, bitWidth));

          const netClass = attrs.class || "";
          if (netClass) {
            if (!netClassEndpoints.has(netClass)) netClassEndpoints.set(netClass, []);
            netClassEndpoints.get(netClass).push({ x: x1, y: y1 });
            netClassEndpoints.get(netClass).push({ x: x2, y: y2 });
          }

          // Preserve netlistsvg as-is: do not infer or add arrowheads on wires.
          const style = "startArrow=none;endArrow=none;html=1;rounded=0;";

          const edge = createMxCell(nextId(), "", style, false, "1", {
            sourcePoint: { x: x1, y: y1 },
            targetPoint: { x: x2, y: y2 },
          });
          netWireCells.push(edge);
        });
      }

      // Draw net wires behind symbols/labels to avoid false-looking extra input pins.
      if (netWireCells.length > 0) {
        rootCells.splice(2, 0, ...netWireCells);
      }

      // 2.5. Recreate net junction points from root-level circles.
      if (svg.circle) {
        const seenJunctions = new Set();
        svg.circle.forEach((circle) => {
          const attrs = circle.$ || {};
          if (!isNetlistJunctionCircle(attrs)) return;

          const cx = safeParseFloat(attrs.cx, NaN) * SCALE;
          const cy = safeParseFloat(attrs.cy, NaN) * SCALE;
          const r = safeParseFloat(attrs.r, NaN) * SCALE;
          if (!Number.isFinite(cx) || !Number.isFinite(cy) || !Number.isFinite(r) || r <= 0) return;

          const key = `${cx.toFixed(3)},${cy.toFixed(3)},${r.toFixed(3)}`;
          if (seenJunctions.has(key)) return;
          seenJunctions.add(key);

          rootCells.push(createMxCell(nextId(), "",
            "ellipse;whiteSpace=wrap;html=1;aspect=fixed;fillColor=#000000;strokeColor=#000000;",
            true, "1", {
            x: cx - r,
            y: cy - r,
            width: r * 2,
            height: r * 2,
          }));
        });
      }

      // Draw output-port triangles after line scan so we can skip symbols for
      // outputs that never drive any input-side anchor.
      const portSymbolStyle = "startArrow=none;endArrow=classic;edgeStyle=none;html=1;rounded=0;strokeWidth=1;endSize=6;";
      deferredOutputPortSymbols.forEach((port) => {
        const touchingNetClasses = [];
        netClassEndpoints.forEach((pts, cls) => {
          if (pts.some((p) => isNear(p.x, port.x, 1.5) && isNear(p.y, port.y, 1.5))) {
            touchingNetClasses.push(cls);
          }
        });

        let drivesAnyInput = false;
        for (const cls of touchingNetClasses) {
          const pts = netClassEndpoints.get(cls) || [];
          if (pts.some((p) => genericInputAnchors.some((a) => isNear(p.x, a.x, 1.5) && isNear(p.y, a.y, 1.5)))) {
            drivesAnyInput = true;
            break;
          }
        }

        // If this output net does not feed any input anchor, skip module-side arrow.
        if (!drivesAnyInput) return;

        // Keep the arrow completely outside module boundary.
        const outStartX = port.x + 4;
        const outEndX = outStartX + 5;
        rootCells.push(createMxCell(nextId(), "", portSymbolStyle, false, "1", {
          sourcePoint: { x: outStartX, y: port.y },
          targetPoint: { x: outEndX, y: port.y },
        }));
      });

      // 3. Update Port Labels with Bus Width
      rootCells.forEach(cell => {
        if (cell._portInfo) {
          const px = Math.round(cell._portInfo.x);
          const py = Math.round(cell._portInfo.y);

          // Check nearby wire endpoints (allow small error due to precision)
          let maxBw = 1;
          for (let dx = -2; dx <= 2; dx++) {
            for (let dy = -2; dy <= 2; dy++) {
              const k = `${px + dx},${py + dy}`;
              if (wireEndpoints.has(k)) {
                maxBw = Math.max(maxBw, wireEndpoints.get(k));
              }
            }
          }

          if (maxBw > 1) {
            cell.$.value = `${cell._portInfo.name} [${maxBw - 1}:0]`;
          }

          // Clean up internal prop
          delete cell._portInfo;
        }
      });
    }

    // Construct final XML
    const mxGraphModel = {
      mxGraphModel: {
        root: { mxCell: rootCells },
      },
    };

    const outXml = builder.buildObject({ mxfile: { diagram: mxGraphModel } });
    fs.writeFile(outputFile, outXml, (err) => {
      if (err) console.error("Error writing Draw.io file:", err);
      else console.log(`Successfully created ${outputFile}`);
    });
  });
});
