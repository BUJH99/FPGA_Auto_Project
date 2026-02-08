const fs = require("fs");
const xml2js = require("xml2js");

// Parse arguments: node svg2drawio.js <input.svg> <output.drawio>
const inputFile = process.argv[2] || "schematic.svg";
const outputFile = process.argv[3] || "schematic.drawio";

// SCALE FACTOR: Expand everything by 1.5x to retrieve space for text
const SCALE = 1.5;

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
      // Simple SVG processing (fallback)
      console.log("[JS] Detected simple SVG format");
      // ... (Existing simple logic if needed, but assuming NetlistSVG mostly)
      // Keeping it minimal for now as we focus on NetlistSVG
    } else {
      console.log("[JS] Detected netlistsvg format");

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
            style = "rounded=0;whiteSpace=wrap;html=1;fillColor=#ffffff;strokeColor=#000000;fontColor=#000000;";
          } else if (type === "inputExt" || type === "outputExt") {
            style = "text;html=1;align=center;verticalAlign=middle;resizable=0;points=[];autosize=1;strokeColor=none;fillColor=none;";
          } else {
            // Logic gates etc.
            if (["and", "or", "nand", "nor", "xor"].includes(type))
              style = `shape=mxgraph.electrical.logic_gates.${type};html=1;whiteSpace=wrap;`;
            else if (type === "not")
              style = "shape=mxgraph.electrical.logic_gates.inverter_2;html=1;whiteSpace=wrap;";
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
              "text;html=1;strokeColor=none;fillColor=none;align=center;verticalAlign=bottom;whiteSpace=nowrap;rounded=0;fontSize=12;fontStyle=1;",
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

          // Process Internal Ports (g.g)
          if (g.g && type === "generic") {
            g.g.forEach((childG) => {
              const childTransform = parseTransform(childG.$.transform);
              // childTransform is relative to parent, so it is already scaled by parseTransform

              let portName = "";
              let textAnchor = "start";
              if (childG.text && childG.text[0]) {
                portName = childG.text[0]._ || "";
                textAnchor = childG.text[0].$?.["text-anchor"] || "start";
              }

              if (portName) {
                const isOutputPort = childTransform.x > 0 || textAnchor === "end"; // x > 0 means right side usually

                // Port Label Position
                // x: relative to box
                const portY = transform.y + childTransform.y;

                // Determine Alignment
                // If output, align right. If input, align left.
                let labelStyle = "text;html=1;strokeColor=none;fillColor=none;verticalAlign=middle;whiteSpace=nowrap;rounded=0;fontSize=10;";
                let labelX, align;

                const labelW = portName.length * 6 + 40; // Approx

                if (isOutputPort) {
                  // Right aligned, inside box
                  // childTransform.x should be near 'width'
                  labelX = transform.x + width - labelW - 5;
                  align = "right";
                } else {
                  // Left aligned, inside box
                  labelX = transform.x + 5;
                  align = "left";
                }

                labelStyle += `align=${align};`;

                // Add Port Label
                const labelId = nextId();
                // Store metadata for bus width update later
                // We'll just assume format [N:0] comes from wire analysis later
                // Store direct reference in an object to update value later?
                // Or simpler: We can't easily link wire to port here without spatial search.
                // We'll do spatial search later.

                const portLabelCell = createMxCell(labelId, portName, labelStyle, true, "1", {
                  x: labelX,
                  y: portY - 6, // center vert
                  width: labelW,
                  height: 12
                });
                rootCells.push(portLabelCell);

                // Tag this cell for bus width update
                // attach custom property to cell object (not to XML $)
                // Store absolute location of the port CONNECTION POINT for matching
                portLabelCell._portInfo = {
                  x: transform.x + childTransform.x,
                  y: transform.y + childTransform.y,
                  name: portName
                };
              }
            });
          }
        });
      }

      // 2. Process Wires (svg.line) & Collect Bus Widths
      const wireEndpoints = new Map(); // "x,y" (SCALED) -> bitWidth

      if (svg.line) {
        svg.line.forEach((line) => {
          const attrs = line.$;
          // Scale coordinates
          const x1 = parseFloat(attrs.x1) * SCALE;
          const y1 = parseFloat(attrs.y1) * SCALE;
          const x2 = parseFloat(attrs.x2) * SCALE;
          const y2 = parseFloat(attrs.y2) * SCALE;

          let bitWidth = 1;
          if (attrs.class && attrs.class.startsWith("net_")) {
            bitWidth = attrs.class.split(",").length;
          }

          // Register endpoints
          const k1 = `${Math.round(x1)},${Math.round(y1)}`;
          const k2 = `${Math.round(x2)},${Math.round(y2)}`;

          wireEndpoints.set(k1, Math.max(wireEndpoints.get(k1) || 1, bitWidth));
          wireEndpoints.set(k2, Math.max(wireEndpoints.get(k2) || 1, bitWidth));

          const style = "endArrow=none;html=1;rounded=0;";
          const edge = createMxCell(nextId(), "", style, false, "1", {
            sourcePoint: { x: x1, y: y1 },
            targetPoint: { x: x2, y: y2 },
          });
          rootCells.push(edge);
        });
      }

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
