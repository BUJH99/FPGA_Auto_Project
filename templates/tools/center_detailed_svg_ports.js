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
  const lines = svgRoot.line || [];

  const moveJunctionForNet = (netClass, jx, oldJy, deltaY) => {
    if (!netClass) {
      return;
    }

    lines.forEach((line) => {
      if (!line.$ || line.$.class !== netClass) {
        return;
      }

      const x1 = parseFloat(line.$.x1);
      const y1 = parseFloat(line.$.y1);
      const x2 = parseFloat(line.$.x2);
      const y2 = parseFloat(line.$.y2);

      if (Number.isFinite(x1) && Number.isFinite(y1) && nearlyEqual(x1, jx) && nearlyEqual(y1, oldJy)) {
        line.$.y1 = formatNumber(y1 + deltaY);
        updatedEndpoints += 1;
      }

      if (Number.isFinite(x2) && Number.isFinite(y2) && nearlyEqual(x2, jx) && nearlyEqual(y2, oldJy)) {
        line.$.y2 = formatNumber(y2 + deltaY);
        updatedEndpoints += 1;
      }
    });
  };

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
    let newY1 = oldY1;
    let newY2 = oldY2;

    if (Number.isFinite(oldX1) && Number.isFinite(oldY1)) {
      const move1 = findMove(oldX1, oldY1);
      if (move1) {
        newY1 = oldY1 + move1.deltaY;
        line.$.y1 = formatNumber(newY1);
        updatedEndpoints += 1;
        moved1 = move1;
      }
    }

    if (Number.isFinite(oldX2) && Number.isFinite(oldY2)) {
      const move2 = findMove(oldX2, oldY2);
      if (move2) {
        newY2 = oldY2 + move2.deltaY;
        line.$.y2 = formatNumber(newY2);
        updatedEndpoints += 1;
        moved2 = move2;
      }
    }

    // Keep orthogonal routing by shifting the connected junction on the same net.
    if (moved1 && !moved2 && Number.isFinite(oldY1) && Number.isFinite(oldY2) && nearlyEqual(oldY1, oldY2)) {
      const junctionX = oldX2;
      const junctionOldY = oldY2;
      const deltaY = moved1.deltaY;
      newY2 = oldY2 + deltaY;
      line.$.y2 = formatNumber(newY2);
      moveJunctionForNet(line.$.class, junctionX, junctionOldY, deltaY);
    } else if (!moved1 && moved2 && Number.isFinite(oldY1) && Number.isFinite(oldY2) && nearlyEqual(oldY1, oldY2)) {
      const junctionX = oldX1;
      const junctionOldY = oldY1;
      const deltaY = moved2.deltaY;
      newY1 = oldY1 + deltaY;
      line.$.y1 = formatNumber(newY1);
      moveJunctionForNet(line.$.class, junctionX, junctionOldY, deltaY);
    }
  });

  return updatedEndpoints;
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
    const updatedEndpointCount = retargetWireEndpoints(result.svg, endpointMoves);

    const builder = new xml2js.Builder({ renderOpts: { pretty: true } });
    const xmlOutput = builder.buildObject(result);

    fs.writeFile(outputFile, xmlOutput, (writeError) => {
      if (writeError) {
        console.error("[ERROR] Failed to write SVG:", writeError.message);
        process.exit(1);
      }

      console.log(
        `[INFO] Recentered ports in ${shiftedModuleCount} module(s), retargeted ${updatedEndpointCount} wire endpoint(s).`
      );
    });
  });
});
