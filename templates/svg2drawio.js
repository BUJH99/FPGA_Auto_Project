const fs = require("fs");
const xml2js = require("xml2js");

// Parse arguments: node svg2drawio.js <input.svg> <output.drawio>
const inputFile = process.argv[2] || "schematic.svg";
const outputFile = process.argv[3] || "schematic.drawio";

console.log(`[JS] Converting ${inputFile} -> ${outputFile}`);

// Basic Draw.io XML Template
const builder = new xml2js.Builder({ renderOpts: { pretty: true } });

function createMxCell(id, value, style, vertex, parent, geom) {
  const cell = {
    $: {
      id,
      value,
      style,
      vertex: vertex ? "1" : undefined,
      edge: vertex ? undefined : "1",
      parent,
    },
  };
  if (geom) {
    cell.mxGeometry = {
      $: {
        x: geom.x,
        y: geom.y,
        width: geom.width,
        height: geom.height,
        as: "geometry",
      },
    };
    if (!vertex) {
      // Edge points
      delete cell.mxGeometry.$;
      cell.mxGeometry = { $: { relative: "1", as: "geometry" } };
      if (geom.points) {
        cell.mxGeometry.Array = {
          $: { as: "points" },
          mxPoint: geom.points.map((p) => ({ $: { x: p.x, y: p.y } })),
        };
      }
      if (geom.sourcePoint)
        cell.mxGeometry.mxPoint = [
          {
            $: {
              x: geom.sourcePoint.x,
              y: geom.sourcePoint.y,
              as: "sourcePoint",
            },
          },
          {
            $: {
              x: geom.targetPoint.x,
              y: geom.targetPoint.y,
              as: "targetPoint",
            },
          },
        ];
    }
  }
  return cell;
}

fs.readFile(inputFile, "utf8", (err, data) => {
  if (err) {
    console.error("Error reading input file:", err);
    return;
  }

  xml2js.parseString(data, (err, result) => {
    if (err) {
      console.error("Error parsing SVG:", err);
      return;
    }

    const svg = result.svg;
    const rootCells = [{ $: { id: "0" } }, { $: { id: "1", parent: "0" } }];

    let idCounter = 2;
    const nextId = () => (idCounter++).toString();

    function parseTransform(transform) {
      if (!transform) return { x: 0, y: 0 };
      const translate = /translate\(([^,]+),([^)]+)\)/.exec(transform);
      if (translate)
        return { x: parseFloat(translate[1]), y: parseFloat(translate[2]) };
      return { x: 0, y: 0 };
    }

    // Check if this is a simple diagram (from generate_simple_svg.ps1)
    const isSimpleDiagram =
      svg.rect && svg.rect.some((r) => r.$ && r.$.class === "box");

    if (isSimpleDiagram) {
      console.log("[JS] Detected simple diagram format");

      // Parse simple diagram
      // Find the main box
      let moduleBox = null;
      if (svg.rect) {
        svg.rect.forEach((rect) => {
          if (rect.$ && rect.$.class === "box") {
            const x = parseFloat(rect.$.x);
            const y = parseFloat(rect.$.y);
            const width = parseFloat(rect.$.width);
            const height = parseFloat(rect.$.height);
            if (!moduleBox) {
              moduleBox = { x, y, width, height };
            }

            // Find module name
            let moduleName = "Module";
            if (svg.text) {
              svg.text.forEach((t) => {
                if (t.$ && t.$.class === "module-name" && t._) {
                  moduleName = t._;
                }
              });
            }

            // Create main box
            const style =
              "rounded=0;whiteSpace=wrap;html=1;fillColor=#ffffff;strokeColor=#000000;fontColor=#333333;";
            rootCells.push(
              createMxCell(nextId(), moduleName, style, true, "1", {
                x,
                y,
                width,
                height,
              }),
            );
          }
        });
      }

      // Parse wires and labels
      if (svg.line) {
        svg.line.forEach((line) => {
          if (line.$ && line.$.class === "wire") {
            const x1 = parseFloat(line.$.x1);
            const y1 = parseFloat(line.$.y1);
            const x2 = parseFloat(line.$.x2);
            const y2 = parseFloat(line.$.y2);

            const style = "endArrow=classic;html=1;rounded=0;";
            const edge = createMxCell(nextId(), "", style, false, "1", {
              sourcePoint: { x: x1, y: y1 },
              targetPoint: { x: x2, y: y2 },
            });
            rootCells.push(edge);
          }
        });
      }

      // Add port labels as text
      if (svg.text) {
        svg.text.forEach((t) => {
          if (t.$ && t.$.class === "port-label" && t._) {
            const label = t._;
            const anchor = t.$["text-anchor"] || "start";
            const isOutputLabel = anchor === "end";
            const rawY = parseFloat(t.$.y || 0);
            let labelWidth = Math.max(56, Math.min(180, label.length * 7 + 12));
            let labelX = parseFloat(t.$.x || 0) - 20;

            // Keep labels inside the module box while staying close to the port edge.
            if (moduleBox) {
              const edgePadding = 10;
              const maxLabelWidth = Math.max(20, moduleBox.width - edgePadding * 2);
              labelWidth = Math.min(labelWidth, maxLabelWidth);

              if (isOutputLabel) {
                labelX = moduleBox.x + moduleBox.width - edgePadding - labelWidth;
              } else {
                labelX = moduleBox.x + edgePadding;
              }
            }

            const labelY = rawY - 14; // Align the text center with the port wire.

            const style = `text;html=1;strokeColor=none;fillColor=none;align=${anchor === "end" ? "right" : "left"};verticalAlign=middle;whiteSpace=wrap;rounded=0;fontSize=12;`;
            rootCells.push(
              createMxCell(nextId(), label, style, true, "1", {
                x: labelX,
                y: labelY,
                width: labelWidth,
                height: 20,
              }),
            );
          }
        });
      }
    } else {
      console.log("[JS] Detected netlistsvg format");

      // Original netlistsvg parsing code
      if (svg.g) {
        svg.g.forEach((g) => {
          const attrs = g.$;
          const type = attrs["s:type"];
          const transform = parseTransform(attrs.transform);
          const width = parseFloat(attrs["s:width"] || 40);
          const height = parseFloat(attrs["s:height"] || 40);

          let style = "rounded=0;whiteSpace=wrap;html=1;";
          let value = "";

          if (g.text) {
            g.text.forEach((t) => {
              if (t._) value = t._;
            });
          }

          if (type === "generic") {
            style =
              "rounded=0;whiteSpace=wrap;html=1;fillColor=#ffffff;strokeColor=#666666;fontColor=#333333;";
          } else if (type === "not") {
            style =
              "text;html=1;align=center;verticalAlign=middle;whiteSpace=wrap;rounded=0;shape=mxgraph.electrical.logic_gates.inverter_2;";
          } else if (["and", "or", "nand", "nor", "xor"].includes(type)) {
            style = `shape=mxgraph.electrical.logic_gates.${type};html=1;whiteSpace=wrap;`;
          } else if (type === "inputExt") {
            style =
              "text;html=1;align=center;verticalAlign=middle;resizable=0;points=[];autosize=1;strokeColor=none;fillColor=none;";
          } else if (type === "outputExt") {
            style =
              "text;html=1;align=center;verticalAlign=middle;resizable=0;points=[];autosize=1;strokeColor=none;fillColor=none;";
          }

          const cellId = nextId();
          const vertex = createMxCell(cellId, value, style, true, "1", {
            x: transform.x,
            y: transform.y,
            width,
            height,
          });
          rootCells.push(vertex);

          if (g.g) {
            g.g.forEach((childG) => {
              const childTransform = parseTransform(childG.$.transform);
              const childX = transform.x + childTransform.x;
              const childY = transform.y + childTransform.y;

              let portName = "";
              if (childG.text) portName = childG.text[0]._;

              if (portName && type === "generic") {
                rootCells.push(
                  createMxCell(
                    nextId(),
                    portName,
                    "text;html=1;strokeColor=none;fillColor=none;align=center;verticalAlign=middle;whiteSpace=wrap;rounded=0;",
                    true,
                    "1",
                    {
                      x: childX - 10,
                      y: childY - 5,
                      width: 20,
                      height: 10,
                    },
                  ),
                );
              }
            });
          }
        });
      }

      if (svg.line) {
        svg.line.forEach((line) => {
          const attrs = line.$;
          const x1 = parseFloat(attrs.x1);
          const y1 = parseFloat(attrs.y1);
          const x2 = parseFloat(attrs.x2);
          const y2 = parseFloat(attrs.y2);

          const style = "endArrow=none;html=1;rounded=0;";
          const edge = createMxCell(nextId(), "", style, false, "1", {
            sourcePoint: { x: x1, y: y1 },
            targetPoint: { x: x2, y: y2 },
          });
          rootCells.push(edge);
        });
      }
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
