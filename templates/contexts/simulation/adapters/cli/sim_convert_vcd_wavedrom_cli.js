const fs = require("fs");
const path = require("path");

function usage() {
  console.log("Usage:");
  console.log("  node tools/vcd_to_wavedrom.js --vcd <tb_xxx.vcd> --signals <tb_xxx.wave.json> --out <wavedrom_cases.json> [--markers <sim.log>] [--jsonl <cases.jsonl>] [--max-points <N>]");
  console.log("");
  console.log("Signal config example:");
  console.log("{");
  console.log('  "strictSignalMatch": true,');
  console.log('  "defaultSignals": ["tb_Top.iClk", "tb_Top.iRstn", "tb_Top.oDone"],');
  console.log('  "cases": [');
  console.log('    { "name": "TC_RESET_001", "signals": ["tb_Top.iClk", "tb_Top.iRstn"] },');
  console.log('    { "name": "TC_MAIN_001", "signals": ["tb_Top.iClk", "tb_Top.iRstn", "tb_Top.oDone"] }');
  console.log("  ]");
  console.log("}");
}

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (token === "--help" || token === "-h") {
      args.help = true;
      continue;
    }
    if (!token.startsWith("--")) {
      continue;
    }
    const key = token.slice(2);
    const value = argv[i + 1];
    if (!value || value.startsWith("--")) {
      throw new Error(`Missing value for argument '${token}'.`);
    }
    args[key] = value;
    i += 1;
  }
  return args;
}

function normalizeSignalName(name) {
  return String(name || "").trim().replace(/\s*\[[^\]]+\]\s*$/, "");
}

function parseVarDefinition(line) {
  const m = line.match(/^\$var\s+(\S+)\s+(\d+)\s+(\S+)\s+(.+?)\s+\$end$/);
  if (!m) return null;
  return {
    varType: m[1],
    width: Number(m[2]),
    id: m[3],
    reference: normalizeSignalName(m[4]),
  };
}

function parseVcdDefinitions(lines) {
  const scopeStack = [];
  const definitions = [];
  const fullNameIndex = new Map();
  let timescale = "";
  let timescaleBuffer = [];
  let inTimescale = false;
  let endDefinitionsLine = -1;

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i].trim();
    if (!line) continue;

    if (line.startsWith("$enddefinitions")) {
      endDefinitionsLine = i;
      break;
    }

    if (inTimescale) {
      if (line.includes("$end")) {
        timescaleBuffer.push(line.replace("$end", "").trim());
        timescale = timescaleBuffer.join(" ").trim();
        inTimescale = false;
      } else {
        timescaleBuffer.push(line);
      }
      continue;
    }

    if (line.startsWith("$timescale")) {
      if (line.includes("$end")) {
        timescale = line.replace("$timescale", "").replace("$end", "").trim();
      } else {
        inTimescale = true;
        timescaleBuffer = [];
      }
      continue;
    }

    if (line.startsWith("$scope")) {
      const m = line.match(/^\$scope\s+\S+\s+(.+?)\s+\$end$/);
      if (m) scopeStack.push(m[1]);
      continue;
    }

    if (line.startsWith("$upscope")) {
      if (scopeStack.length > 0) scopeStack.pop();
      continue;
    }

    if (!line.startsWith("$var")) continue;

    const parsed = parseVarDefinition(line);
    if (!parsed) continue;

    const fullName = [...scopeStack, parsed.reference].join(".");
    const def = {
      id: parsed.id,
      width: parsed.width,
      varType: parsed.varType,
      reference: parsed.reference,
      fullName,
    };
    definitions.push(def);
    if (!fullNameIndex.has(fullName)) {
      fullNameIndex.set(fullName, []);
    }
    fullNameIndex.get(fullName).push(def);
  }

  if (endDefinitionsLine < 0) {
    throw new Error("Invalid VCD: '$enddefinitions' not found.");
  }

  return {
    definitions,
    fullNameIndex,
    timescale,
    endDefinitionsLine,
  };
}

function resolveSignal(requestedName, definitions, fullNameIndex) {
  const normalized = normalizeSignalName(requestedName);
  if (!normalized) return { error: "Empty signal name." };

  const exact = fullNameIndex.get(normalized) || [];
  if (exact.length === 1) return { def: exact[0] };
  if (exact.length > 1) return { error: `Signal '${requestedName}' is ambiguous (exact match).` };

  const candidates = definitions.filter((d) => d.fullName.endsWith(`.${normalized}`) || d.reference === normalized);
  if (candidates.length === 1) return { def: candidates[0] };
  if (candidates.length === 0) return { error: `Signal '${requestedName}' was not found in VCD.` };

  return {
    error: `Signal '${requestedName}' is ambiguous. Candidates: ${candidates.slice(0, 6).map((c) => c.fullName).join(", ")}${candidates.length > 6 ? " ..." : ""}`,
  };
}

function normalizeScalar(value) {
  const ch = String(value || "").trim().toLowerCase().slice(0, 1);
  if (ch === "0" || ch === "1" || ch === "x" || ch === "z") return ch;
  return "x";
}

function normalizeVector(value) {
  return String(value || "").replace(/_/g, "").trim().toLowerCase();
}

function parseVcdEvents(lines, startLineIndex, trackedIds) {
  const eventsById = new Map();
  const lastById = new Map();
  let maxTime = 0;

  trackedIds.forEach((id) => eventsById.set(id, []));

  let currentTime = 0;
  for (let i = startLineIndex; i < lines.length; i += 1) {
    const line = lines[i].trim();
    if (!line) continue;

    if (line.startsWith("#")) {
      const t = Number(line.slice(1).trim());
      if (Number.isFinite(t)) {
        currentTime = t;
        if (t > maxTime) maxTime = t;
      }
      continue;
    }

    if (line.startsWith("$")) continue;

    let id = null;
    let value = null;
    const c = line[0];

    if ("01xXzZ".includes(c)) {
      id = line.slice(1).trim();
      value = normalizeScalar(c);
    } else if (c === "b" || c === "B") {
      const p = line.slice(1).trim().split(/\s+/, 2);
      if (p.length === 2) {
        id = p[1];
        value = normalizeVector(p[0]);
      }
    } else if (c === "r" || c === "R") {
      const p = line.slice(1).trim().split(/\s+/, 2);
      if (p.length === 2) {
        id = p[1];
        value = p[0];
      }
    }

    if (!id || value === null) continue;
    if (!trackedIds.has(id)) continue;

    const prev = lastById.get(id);
    if (prev === value) continue;
    lastById.set(id, value);
    eventsById.get(id).push({ time: currentTime, value });
  }

  return { eventsById, maxTime };
}

function parseSignalConfig(rawConfig) {
  if (Array.isArray(rawConfig)) {
    return {
      strictSignalMatch: true,
      defaultSignals: rawConfig.map((x) => String(x)),
      cases: [],
    };
  }

  if (!rawConfig || typeof rawConfig !== "object") {
    throw new Error("Signal config must be an object or array.");
  }

  const strictSignalMatch = rawConfig.strictSignalMatch !== false;
  const defaultSignals = Array.isArray(rawConfig.defaultSignals) ? rawConfig.defaultSignals.map((x) => String(x)) : [];
  const cases = Array.isArray(rawConfig.cases) ? rawConfig.cases : [];

  return {
    strictSignalMatch,
    defaultSignals,
    cases,
  };
}

function parseCaseEventsFromLog(logPath) {
  if (!logPath || !fs.existsSync(logPath)) return [];
  const lines = fs.readFileSync(logPath, "utf8").split(/\r?\n/);
  const events = [];

  const beginRe = /@CASE_BEGIN\|(\d+)\|(.+)/;
  const endRe = /@CASE_END\|(\d+)\|([^|]+)\|([^|\s]+)/;

  lines.forEach((line) => {
    const beginMatch = line.match(beginRe);
    if (beginMatch) {
      events.push({
        type: "BEGIN",
        time: Number(beginMatch[1]),
        name: beginMatch[2].trim(),
        status: "RUNNING",
      });
      return;
    }

    const endMatch = line.match(endRe);
    if (endMatch) {
      events.push({
        type: "END",
        time: Number(endMatch[1]),
        name: endMatch[2].trim(),
        status: String(endMatch[3] || "N/A").toUpperCase(),
      });
    }
  });

  return events;
}

function parseCaseEventsFromJsonl(jsonlPath) {
  if (!jsonlPath || !fs.existsSync(jsonlPath)) return [];
  const lines = fs.readFileSync(jsonlPath, "utf8").split(/\r?\n/);
  const events = [];

  lines.forEach((line) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    let obj;
    try {
      obj = JSON.parse(trimmed);
    } catch (_err) {
      return;
    }
    if (!obj || !obj.event || !obj.name) return;

    const eventName = String(obj.event).toUpperCase();
    if (eventName !== "CASE_BEGIN" && eventName !== "CASE_END") return;

    events.push({
      type: eventName === "CASE_BEGIN" ? "BEGIN" : "END",
      time: Number(obj.time || 0),
      name: String(obj.name).trim(),
      status: obj.status ? String(obj.status).toUpperCase() : "N/A",
    });
  });

  return events;
}

function buildCaseWindows(events, warnings) {
  const stackByName = new Map();
  const windows = [];

  events.forEach((evt) => {
    if (!evt.name || !Number.isFinite(evt.time)) return;

    if (evt.type === "BEGIN") {
      if (!stackByName.has(evt.name)) stackByName.set(evt.name, []);
      stackByName.get(evt.name).push(evt);
      return;
    }

    if (evt.type === "END") {
      const stack = stackByName.get(evt.name) || [];
      if (stack.length === 0) {
        warnings.push(`Found CASE_END without matching CASE_BEGIN: ${evt.name} @ ${evt.time}`);
        return;
      }

      const begin = stack.pop();
      if (evt.time < begin.time) {
        warnings.push(`Case '${evt.name}' has endTime < startTime (${evt.time} < ${begin.time}). Skipped.`);
        return;
      }

      windows.push({
        name: evt.name,
        startTime: begin.time,
        endTime: evt.time,
        status: evt.status || "N/A",
      });
    }
  });

  Array.from(stackByName.keys()).forEach((name) => {
    const stack = stackByName.get(name) || [];
    stack.forEach((beginEvt) => {
      warnings.push(`Found CASE_BEGIN without CASE_END: ${name} @ ${beginEvt.time}`);
    });
  });

  windows.sort((a, b) => a.startTime - b.startTime);
  return windows;
}

function mergeCasesWithConfig(configCases, markerCases, defaultSignals) {
  if (!Array.isArray(configCases) || configCases.length === 0) {
    return markerCases.map((c) => ({
      name: c.name,
      startTime: c.startTime,
      endTime: c.endTime,
      status: c.status || "N/A",
      requestedSignals: defaultSignals.slice(),
    }));
  }

  const markerQueueByName = new Map();
  markerCases.forEach((item) => {
    if (!markerQueueByName.has(item.name)) markerQueueByName.set(item.name, []);
    markerQueueByName.get(item.name).push(item);
  });

  const merged = [];
  configCases.forEach((caseCfg) => {
    const name = String(caseCfg.name || "").trim();
    if (!name) return;
    const signals = Array.isArray(caseCfg.signals) && caseCfg.signals.length > 0 ? caseCfg.signals.map((s) => String(s)) : defaultSignals.slice();

    let startTime = Number(caseCfg.startTime);
    let endTime = Number(caseCfg.endTime);
    let status = caseCfg.status ? String(caseCfg.status).toUpperCase() : "N/A";

    if (!Number.isFinite(startTime) || !Number.isFinite(endTime)) {
      const queue = markerQueueByName.get(name) || [];
      if (queue.length > 0) {
        const markerCase = queue.shift();
        startTime = markerCase.startTime;
        endTime = markerCase.endTime;
        status = markerCase.status || status;
      }
    }

    merged.push({
      name,
      startTime,
      endTime,
      status,
      requestedSignals: signals,
    });
  });

  return merged;
}

function ensureCaseRanges(cases) {
  const errors = [];
  cases.forEach((c) => {
    if (!Number.isFinite(c.startTime) || !Number.isFinite(c.endTime)) {
      errors.push(`Case '${c.name}' has invalid start/end time.`);
      return;
    }
    if (c.endTime < c.startTime) {
      errors.push(`Case '${c.name}' has endTime < startTime.`);
    }
    if (!Array.isArray(c.requestedSignals) || c.requestedSignals.length === 0) {
      errors.push(`Case '${c.name}' has no signal list. Set defaultSignals or case.signals in config.`);
    }
  });
  if (errors.length > 0) throw new Error(errors.join("\n"));
}

function uniquify(arr) {
  return Array.from(new Set(arr));
}

function formatVectorValue(raw) {
  const value = String(raw || "").toLowerCase();
  if (!value || /[xz]/.test(value)) return value || "x";
  if (!/^[01]+$/.test(value)) return value;

  if (value.length <= 4) return value;
  try {
    const asHex = BigInt(`0b${value}`).toString(16);
    return `0x${asHex}`;
  } catch (_err) {
    return value;
  }
}

function reduceTicks(sortedTicks, maxPoints) {
  if (sortedTicks.length <= maxPoints) return sortedTicks;
  if (maxPoints < 2) return [sortedTicks[0], sortedTicks[sortedTicks.length - 1]];

  const result = [];
  const step = (sortedTicks.length - 1) / (maxPoints - 1);
  for (let i = 0; i < maxPoints; i += 1) {
    const idx = Math.round(i * step);
    const tick = sortedTicks[Math.max(0, Math.min(sortedTicks.length - 1, idx))];
    if (result.length === 0 || result[result.length - 1] !== tick) {
      result.push(tick);
    }
  }
  if (result[result.length - 1] !== sortedTicks[sortedTicks.length - 1]) {
    result.push(sortedTicks[sortedTicks.length - 1]);
  }
  return result;
}

function valueTimeline(events, ticks) {
  const vals = [];
  let idx = 0;
  let current = "x";
  for (let i = 0; i < ticks.length; i += 1) {
    const t = ticks[i];
    while (idx < events.length && events[idx].time <= t) {
      current = events[idx].value;
      idx += 1;
    }
    vals.push(current);
  }
  return vals;
}

function encodeWaveFromValues(values, width) {
  let wave = "";
  const data = [];
  let prev = null;
  const scalar = width <= 1;

  values.forEach((raw) => {
    const normalized = scalar ? normalizeScalar(raw) : normalizeVector(raw);
    let ch = ".";

    if (prev === null || normalized !== prev) {
      if (scalar) {
        ch = normalized;
      } else if (!normalized || /[xz]/.test(normalized)) {
        ch = "x";
      } else {
        ch = "=";
        data.push(formatVectorValue(normalized));
      }
    }

    wave += ch;
    prev = normalized;
  });

  return data.length > 0 ? { wave, data } : { wave };
}

function buildCaseWave(caseSpec, resolvedSignals, eventsById, maxPoints, timescale) {
  const perSignalEvents = [];
  const tickSet = new Set([caseSpec.startTime, caseSpec.endTime]);

  resolvedSignals.forEach((sig) => {
    const allEvents = eventsById.get(sig.id) || [];
    let baseline = null;
    const inRange = [];

    allEvents.forEach((evt) => {
      if (evt.time <= caseSpec.startTime) {
        baseline = evt;
        return;
      }
      if (evt.time > caseSpec.endTime) {
        return;
      }
      inRange.push(evt);
      tickSet.add(evt.time);
    });

    if (baseline) {
      inRange.unshift({ time: caseSpec.startTime, value: baseline.value });
    }

    perSignalEvents.push({
      signal: sig,
      events: inRange,
    });
  });

  const ticks = reduceTicks(Array.from(tickSet).sort((a, b) => a - b), maxPoints);
  const signalItems = perSignalEvents.map((entry) => {
    const values = valueTimeline(entry.events, ticks);
    const encoded = encodeWaveFromValues(values, entry.signal.width);
    const item = {
      name: entry.signal.displayName,
      wave: encoded.wave || "x",
    };
    if (encoded.data) item.data = encoded.data;
    return item;
  });

  return {
    signal: signalItems,
    head: {
      text: `${caseSpec.name} [${caseSpec.status}]`,
      tick: 0,
    },
    foot: {
      text: `${caseSpec.startTime} -> ${caseSpec.endTime}${timescale ? ` (${timescale})` : ""}`,
    },
  };
}

function main() {
  try {
    const args = parseArgs(process.argv.slice(2));
    if (args.help) {
      usage();
      return;
    }

    if (!args.vcd || !args.signals || !args.out) {
      usage();
      throw new Error("Arguments '--vcd', '--signals', and '--out' are required.");
    }

    const vcdPath = path.resolve(args.vcd);
    const signalPath = path.resolve(args.signals);
    const outPath = path.resolve(args.out);
    const markerPath = args.markers ? path.resolve(args.markers) : "";
    const jsonlPath = args.jsonl ? path.resolve(args.jsonl) : "";
    const maxPoints = Math.max(8, Number(args["max-points"] || 80));

    if (!fs.existsSync(vcdPath)) throw new Error(`VCD file not found: ${vcdPath}`);
    if (!fs.existsSync(signalPath)) throw new Error(`Signal config file not found: ${signalPath}`);

    const warnings = [];
    const signalConfigRaw = JSON.parse(fs.readFileSync(signalPath, "utf8"));
    const signalConfig = parseSignalConfig(signalConfigRaw);

    const markerEvents = [
      ...parseCaseEventsFromLog(markerPath),
      ...parseCaseEventsFromJsonl(jsonlPath),
    ];
    const markerCases = buildCaseWindows(markerEvents, warnings);

    const mergedCases = mergeCasesWithConfig(
      signalConfig.cases,
      markerCases,
      signalConfig.defaultSignals
    );

    if (mergedCases.length === 0) {
      throw new Error("No testcase window found. Add CASE_BEGIN/CASE_END markers or specify case ranges in signal config.");
    }
    ensureCaseRanges(mergedCases);

    const vcdRaw = fs.readFileSync(vcdPath, "utf8");
    const lines = vcdRaw.split(/\r?\n/);
    const defs = parseVcdDefinitions(lines);

    const allRequestedSignalNames = uniquify(
      mergedCases.flatMap((c) => c.requestedSignals.map((x) => String(x)))
    );

    const resolvedByRequested = new Map();
    const resolveErrors = [];

    allRequestedSignalNames.forEach((requested) => {
      const result = resolveSignal(requested, defs.definitions, defs.fullNameIndex);
      if (result.error) {
        const msg = `Signal resolve error: ${result.error}`;
        if (signalConfig.strictSignalMatch) resolveErrors.push(msg);
        else warnings.push(msg);
        return;
      }
      const def = result.def;
      resolvedByRequested.set(requested, {
        id: def.id,
        width: def.width,
        fullName: def.fullName,
        displayName: def.reference,
      });
    });

    if (resolveErrors.length > 0) {
      throw new Error(resolveErrors.join("\n"));
    }

    const trackedIds = new Set(Array.from(resolvedByRequested.values()).map((x) => x.id));
    const parsedEvents = parseVcdEvents(lines, defs.endDefinitionsLine + 1, trackedIds);

    const outputCases = mergedCases.map((caseSpec) => {
      const resolvedSignals = caseSpec.requestedSignals
        .map((requested) => {
          const resolved = resolvedByRequested.get(requested);
          if (!resolved) return null;
          return {
            requested,
            id: resolved.id,
            width: resolved.width,
            name: resolved.fullName,
            displayName: resolved.displayName,
          };
        })
        .filter(Boolean);

      if (resolvedSignals.length === 0) {
        throw new Error(`Case '${caseSpec.name}' has no valid signal after resolution.`);
      }

      return {
        name: caseSpec.name,
        status: caseSpec.status || "N/A",
        startTime: caseSpec.startTime,
        endTime: caseSpec.endTime,
        signals: resolvedSignals.map((s) => s.name),
        wavedrom: buildCaseWave(
          caseSpec,
          resolvedSignals,
          parsedEvents.eventsById,
          maxPoints,
          defs.timescale
        ),
      };
    });

    const payload = {
      generatedAt: new Date().toISOString(),
      sourceVcd: path.relative(process.cwd(), vcdPath),
      signalConfig: path.relative(process.cwd(), signalPath),
      markerSource: markerPath ? path.relative(process.cwd(), markerPath) : "",
      caseMetaSource: jsonlPath ? path.relative(process.cwd(), jsonlPath) : "",
      timescale: defs.timescale || null,
      maxPoints,
      warnings,
      cases: outputCases,
    };

    fs.mkdirSync(path.dirname(outPath), { recursive: true });
    fs.writeFileSync(outPath, `${JSON.stringify(payload, null, 2)}\n`, "utf8");

    console.log(`[INFO] Case count: ${outputCases.length}`);
    console.log(`[SUCCESS] Wrote ${outPath}`);
    if (warnings.length > 0) {
      console.log(`[WARN] ${warnings.length} warning(s) detected. Check output JSON 'warnings' field.`);
    }
  } catch (err) {
    console.error(`[ERROR] ${err.message}`);
    process.exit(1);
  }
}

main();
