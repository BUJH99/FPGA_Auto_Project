function normalizeSlashes(value) {
  return String(value || "").replace(/\\/g, "/");
}

function normalizeString(value) {
  return String(value || "").trim();
}

function normalizeStatus(value, fallback = "generated") {
  const status = normalizeString(value).toLowerCase();
  return status || fallback;
}

function normalizeNumber(value, fallback = 0) {
  const num = Number(value);
  return Number.isFinite(num) ? num : fallback;
}

function uniqueStrings(values) {
  if (!Array.isArray(values)) return [];
  return Array.from(
    new Set(
      values
        .map((value) => normalizeString(value))
        .filter(Boolean)
    )
  ).sort((a, b) => a.localeCompare(b));
}

function sanitizeSignalTag(value, fallback = "signal") {
  const out = normalizeString(value)
    .replace(/[^A-Za-z0-9_.-]+/g, "_")
    .replace(/^_+|_+$/g, "");
  return out || fallback;
}

function buildDefaultSignalFlowMarkdownRelativePath({
  topModule,
  signalQuery,
} = {}) {
  const topTag = sanitizeSignalTag(topModule, "top");
  const signalTag = sanitizeSignalTag(signalQuery, "signal");
  return `output/signal/${topTag}/signal_flow_${signalTag}.md`;
}

function createSignalFlowArtifactRecord({
  kind,
  path,
  role = "supporting",
} = {}) {
  return {
    kind: normalizeString(kind) || "artifact",
    path: normalizeSlashes(path),
    role: normalizeString(role) || "supporting",
  };
}

function normalizeEdgeRows(rows) {
  if (!Array.isArray(rows)) return [];
  return rows.map((row) => ({
    direction: normalizeString(row && row.direction),
    from: normalizeString(row && row.from),
    to: normalizeString(row && row.to),
    kind: normalizeString(row && row.kind),
    location: normalizeString(row && row.location),
    detail: normalizeString(row && row.detail),
  }));
}

function normalizeTraversalRows(rows) {
  if (!Array.isArray(rows)) return [];
  return rows.map((row) => ({
    modulePath: normalizeString(row && row.modulePath),
    moduleName: normalizeString(row && row.moduleName),
    depth: normalizeNumber(row && row.depth),
  }));
}

function createSignalFlowPublicContract({
  projectRoot,
  manifestJsonPath = "",
  topModule,
  signalQuery,
  status = "generated",
  requestedTraceDepth = "",
  effectiveTraceDepth = 0,
  hierarchyDepth = 0,
  moduleCount = 0,
  hierarchyInstanceCount = 0,
  totalGraphEdges = 0,
  matchedNodes = [],
  upstreamRows = [],
  downstreamRows = [],
  upstreamModules = [],
  downstreamModules = [],
  upstreamTruncated = false,
  downstreamTruncated = false,
  warnings = [],
  artifacts = [],
  primaryOutputPath = "",
  markdownPath = "",
} = {}) {
  const matched = uniqueStrings(matchedNodes);
  const normalizedUpstreamRows = normalizeEdgeRows(upstreamRows);
  const normalizedDownstreamRows = normalizeEdgeRows(downstreamRows);

  return {
    schemaVersion: 1,
    type: "signal_flow_report",
    status: normalizeStatus(status),
    generatedAt: new Date().toISOString(),
    projectRoot: normalizeSlashes(projectRoot),
    manifestJsonPath: normalizeSlashes(manifestJsonPath),
    topModule: normalizeString(topModule),
    signalQuery: normalizeString(signalQuery),
    primaryOutputPath: normalizeSlashes(primaryOutputPath),
    markdownPath: normalizeSlashes(markdownPath),
    traceDepth: {
      requested: normalizeString(requestedTraceDepth),
      effective: normalizeNumber(effectiveTraceDepth),
      hierarchyLimit: normalizeNumber(hierarchyDepth),
    },
    matches: {
      count: matched.length,
      nodes: matched,
    },
    graph: {
      moduleCount: normalizeNumber(moduleCount),
      hierarchyInstanceCount: normalizeNumber(hierarchyInstanceCount),
      totalEdgeCount: normalizeNumber(totalGraphEdges),
      upstreamEdgeCount: normalizedUpstreamRows.length,
      downstreamEdgeCount: normalizedDownstreamRows.length,
      truncated: {
        upstream: Boolean(upstreamTruncated),
        downstream: Boolean(downstreamTruncated),
      },
    },
    traversal: {
      upstreamModules: normalizeTraversalRows(upstreamModules),
      downstreamModules: normalizeTraversalRows(downstreamModules),
    },
    trace: {
      upstream: {
        truncated: Boolean(upstreamTruncated),
        edges: normalizedUpstreamRows,
      },
      downstream: {
        truncated: Boolean(downstreamTruncated),
        edges: normalizedDownstreamRows,
      },
    },
    warnings: uniqueStrings(warnings),
    artifacts: Array.isArray(artifacts)
      ? artifacts.map((artifact) => createSignalFlowArtifactRecord(artifact))
      : [],
  };
}

module.exports = {
  normalizeSlashes,
  sanitizeSignalTag,
  buildDefaultSignalFlowMarkdownRelativePath,
  createSignalFlowArtifactRecord,
  createSignalFlowPublicContract,
};
