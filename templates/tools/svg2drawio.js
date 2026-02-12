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
    xnor: "xnor",
    reduce_xnor: "xnor",
  };

  if (type === "not") {
    return "shape=mxgraph.electrical.logic_gates.inverter;html=1;whiteSpace=wrap;";
  }

  const shapeName = gateShapeMap[type];
  if (!shapeName) return null;
  return `shape=mxgraph.electrical.logic_gates.${shapeName};html=1;whiteSpace=wrap;`;
}

fs.readFile(inputFile, (err, data) => {
  if (err) {
    console.error("Error reading input file:", err);
    return;
  }

  const parser = new xml2js.Parser();
  parser.parseString(data, (err, result) => {
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
           let txt = typeof t._ === "string" ? t._ : "";
           if (!txt && tspanLines.length) {
             txt = multiline ? tspanLines.join("<br/>") : tspanLines[0];
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
           if (align === "center") finalX = x - w/2;
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

      // 1. Process Modules (svg.g)
      if (svg.g) {
        svg.g.forEach((g) => {
          const attrs = g.$;
          const type = attrs["s:type"];
          const transform = parseTransform(attrs.transform);

          // Get Dimensions & Apply Scale
          let width = parseFloat(attrs["s:width"] || 40) * SCALE;
          let height = parseFloat(attrs["s:height"] || 40) * SCALE;

          // For generic modules, check internal rect for size
          if (type === "generic" && g.rect) {
            g.rect.forEach((rect) => {
              if (rect.$ && rect.$["s:generic"] === "body") {
                width = parseFloat(rect.$.width || 40) * SCALE;
                height = parseFloat(rect.$.height || 40) * SCALE;
              }
            });
          }

          let style = "rounded=0;whiteSpace=wrap;html=1;";
          let value = "";
          if (g.text) {
            g.text.forEach((t) => { if (t._) value = t._; });
          }

          // specific styles
          if (type === "generic") {
            style = "rounded=0;whiteSpace=wrap;html=1;fillColor=#ffffff;strokeColor=#000000;fontColor=#000000;fontFamily=Helvetica;";
          } else if (type === "inputExt" || type === "outputExt") {
            style = "text;html=1;align=center;verticalAlign=middle;resizable=0;points=[];autosize=1;strokeColor=none;fillColor=none;fontFamily=Helvetica;";
          } else {
            // Logic gates etc.
            const gateStyle = getLogicGateStyle(type);
            if (gateStyle) style = gateStyle;
          }

          const cellId = nextId();

          // Draw Main Box
          const vertex = createMxCell(cellId, "", style, true, "1", {
            x: transform.x,
            y: transform.y,
            width,
            height,
          });
          rootCells.push(vertex);

          // Module Name Label (Top Outside)
          if (value && type === "generic") {
            const nameWidth = Math.max(width, value.length * 8 + 20);
            rootCells.push(createMxCell(nextId(), value,
              "text;html=1;strokeColor=none;fillColor=none;align=center;verticalAlign=bottom;whiteSpace=nowrap;rounded=0;fontSize=12;fontStyle=1;fontFamily=Helvetica;",
              true, "1", {
              x: transform.x + (width - nameWidth) / 2,
              y: transform.y - 20,
              width: nameWidth,
              height: 20
            }));
          } else if (value && (type === "inputExt" || type === "outputExt")) {
            // For Ext ports, put text on the node
            vertex.$.value = value;
            vertex.$.style += "fontSize=11;fontStyle=1;";
          }

          // Reproduce external port symbol strokes from netlistsvg:
          // - inputExt: plain short line (no arrowhead)
          // - outputExt: short line with one arrowhead
          if (type === "inputExt") {
            const sy = transform.y + 10 * SCALE;
            rootCells.push(createMxCell(nextId(), "", "startArrow=none;endArrow=none;edgeStyle=none;html=1;rounded=0;", false, "1", {
              sourcePoint: { x: transform.x + 10 * SCALE, y: sy },
              targetPoint: { x: transform.x + 30 * SCALE, y: sy },
            }));
          } else if (type === "outputExt") {
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
          rootCells.push(edge);
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
