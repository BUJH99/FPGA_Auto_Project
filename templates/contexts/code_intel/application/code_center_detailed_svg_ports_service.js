const fs = require("fs");
const xml2js = require("xml2js");

const inputFile = process.argv[2];
const outputFile = process.argv[3] || inputFile;

if (!inputFile) {
  console.error("Usage: node center_detailed_svg_ports.js <input.svg> [output.svg]");
  process.exit(1);
}

function parseTransform(transformStr) {
  if (!transformStr) {
    return null;
  }

  const match = transformStr.match(/translate\(\s*([-+]?\d*\.?\d+)\s*(?:,|\s)\s*([-+]?\d*\.?\d+)\s*\)/);
  if (!match) {
    return null;
  }

  return {
    x: parseFloat(match[1]),
    y: parseFloat(match[2]),
  };
}

function formatNumber(value) {
  if (!Number.isFinite(value)) {
    return "0";
  }
  const rounded = Math.round(value * 1000) / 1000;
  return Number.isInteger(rounded) ? `${rounded}` : `${rounded}`;
}

function toTranslate(x, y) {
  return `translate(${formatNumber(x)},${formatNumber(y)})`;
}

function nearlyEqual(a, b, epsilon = 1.5) {
  return Math.abs(a - b) <= epsilon;
}

function getCenter(points) {
  return (points[0].relY + points[points.length - 1].relY) / 2;
}

function recenterPorts(svgRoot) {
  const endpointMoves = [];
  let shiftedModuleCount = 0;

  const modules = svgRoot.g || [];
  modules.forEach((moduleG) => {
    if (!moduleG.$ || moduleG.$["s:type"] !== "generic") {
      return;
    }

    const moduleTransform = parseTransform(moduleG.$.transform);
    if (!moduleTransform) {
      return;
    }

    const bodyRect = (moduleG.rect || []).find((rect) => rect.$ && rect.$["s:generic"] === "body");
    const moduleWidth = parseFloat(
      (bodyRect && bodyRect.$ && bodyRect.$.width) || moduleG.$["s:width"] || "0"
    );

    const ports = [];
    (moduleG.g || []).forEach((portG) => {
      if (!portG.$ || !portG.$["s:pid"]) {
        return;
      }

      const portTransform = parseTransform(portG.$.transform);
      if (!portTransform) {
        return;
      }

      const pid = `${portG.$["s:pid"]}`.toLowerCase();
      const isOutput = portTransform.x > moduleWidth / 2 || pid.startsWith("out");

      ports.push({
        node: portG,
        relX: portTransform.x,
        relY: portTransform.y,
        isOutput,
      });
    });

    if (ports.length === 0) {
      return;
    }

    const inputs = ports.filter((p) => !p.isOutput).sort((a, b) => a.relY - b.relY);
    const outputs = ports.filter((p) => p.isOutput).sort((a, b) => a.relY - b.relY);

    if (inputs.length === 0 || outputs.length === 0 || inputs.length === outputs.length) {
      return;
    }

    const fixed = inputs.length > outputs.length ? inputs : outputs;
    const moving = inputs.length > outputs.length ? outputs : inputs;

    const delta = getCenter(fixed) - getCenter(moving);
    if (Math.abs(delta) < 0.01) {
      return;
    }

    moving.forEach((port) => {
      const oldRelY = port.relY;
      const newRelY = oldRelY + delta;

      port.node.$.transform = toTranslate(port.relX, newRelY);
      port.node.$["s:y"] = formatNumber(newRelY);

      endpointMoves.push({
        oldX: moduleTransform.x + port.relX,
        oldY: moduleTransform.y + oldRelY,
        deltaY: delta,
      });

      port.relY = newRelY;
    });

    shiftedModuleCount += 1;
  });

  return { endpointMoves, shiftedModuleCount };
}

function retargetWireEndpoints(svgRoot, endpointMoves) {
  if (!endpointMoves.length) {
    return 0;
  }

  const findMove = (x, y) => endpointMoves.find((m) => nearlyEqual(x, m.oldX) && nearlyEqual(y, m.oldY));
  let updatedEndpoints = 0;
  let addedBridgeSegments = 0;
  const lines = svgRoot.line || [];
  const bridges = [];

  lines.forEach((line) => {
    if (!line.$) {
      return;
    }

    const oldX1 = parseFloat(line.$.x1);
    const oldY1 = parseFloat(line.$.y1);
    const oldX2 = parseFloat(line.$.x2);
    const oldY2 = parseFloat(line.$.y2);

    let moved1 = null;
    let moved2 = null;
    let originalNewY1 = oldY1;
    let originalNewY2 = oldY2;
    let newY1 = oldY1;
    let newY2 = oldY2;

    if (Number.isFinite(oldX1) && Number.isFinite(oldY1)) {
      const move1 = findMove(oldX1, oldY1);
      if (move1) {
        newY1 = oldY1 + move1.deltaY;
        originalNewY1 = newY1;
        line.$.y1 = formatNumber(newY1);
        updatedEndpoints += 1;
        moved1 = move1;
      }
    }

    if (Number.isFinite(oldX2) && Number.isFinite(oldY2)) {
      const move2 = findMove(oldX2, oldY2);
      if (move2) {
        newY2 = oldY2 + move2.deltaY;
        originalNewY2 = newY2;
        line.$.y2 = formatNumber(newY2);
        updatedEndpoints += 1;
        moved2 = move2;
      }
    }

    // If only one endpoint moved on a horizontal segment, keep the shared junction fixed
    // and add a short local vertical bridge near the moved port.
    // This avoids disconnecting other sinks/sources sharing the same net junction.
    if (moved1 && !moved2 && Number.isFinite(oldY1) && Number.isFinite(oldY2) && nearlyEqual(oldY1, oldY2)) {
      line.$.y1 = formatNumber(oldY1);
      bridges.push({
        x1: oldX1,
        y1: oldY1,
        x2: oldX1,
        y2: originalNewY1,
        className: line.$.class,
      });
      addedBridgeSegments += 1;
    } else if (!moved1 && moved2 && Number.isFinite(oldY1) && Number.isFinite(oldY2) && nearlyEqual(oldY1, oldY2)) {
      line.$.y2 = formatNumber(oldY2);
      bridges.push({
        x1: oldX2,
        y1: oldY2,
        x2: oldX2,
        y2: originalNewY2,
        className: line.$.class,
      });
      addedBridgeSegments += 1;
    }
  });

  bridges.forEach((b) => {
    const attrs = {
      x1: formatNumber(b.x1),
      y1: formatNumber(b.y1),
      x2: formatNumber(b.x2),
      y2: formatNumber(b.y2),
    };
    if (b.className) {
      attrs.class = b.className;
    }
    lines.push({ $: attrs });
  });

  return { updatedEndpoints, addedBridgeSegments };
}

fs.readFile(inputFile, (readError, data) => {
  if (readError) {
    console.error("[ERROR] Failed to read SVG:", readError.message);
    process.exit(1);
  }

  const parser = new xml2js.Parser();
  parser.parseString(data, (parseError, result) => {
    if (parseError) {
      console.error("[ERROR] Failed to parse SVG:", parseError.message);
      process.exit(1);
    }

    if (!result || !result.svg) {
      console.error("[ERROR] Invalid SVG format.");
      process.exit(1);
    }

    const { endpointMoves, shiftedModuleCount } = recenterPorts(result.svg);
    const { updatedEndpoints: updatedEndpointCount, addedBridgeSegments } = retargetWireEndpoints(result.svg, endpointMoves);

    const builder = new xml2js.Builder({ renderOpts: { pretty: true } });
    const xmlOutput = builder.buildObject(result);

    fs.writeFile(outputFile, xmlOutput, (writeError) => {
      if (writeError) {
        console.error("[ERROR] Failed to write SVG:", writeError.message);
        process.exit(1);
      }

      console.log(
        `[INFO] Recentered ports in ${shiftedModuleCount} module(s), retargeted ${updatedEndpointCount} wire endpoint(s), added ${addedBridgeSegments} bridge segment(s).`
      );
    });
  });
});
