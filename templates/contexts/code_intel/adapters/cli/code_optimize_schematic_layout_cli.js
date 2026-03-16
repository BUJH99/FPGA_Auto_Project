#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

function parseArgs(argv) {
  const args = {
    baseline: '',
    override: '',
    output: '',
  };

  for (let idx = 0; idx < argv.length; idx += 1) {
    const token = argv[idx];
    if ((token === '--baseline' || token === '-b') && idx + 1 < argv.length) {
      args.baseline = argv[idx + 1];
      idx += 1;
      continue;
    }
    if ((token === '--override' || token === '--layout') && idx + 1 < argv.length) {
      args.override = argv[idx + 1];
      idx += 1;
      continue;
    }
    if ((token === '--output' || token === '-o') && idx + 1 < argv.length) {
      args.output = argv[idx + 1];
      idx += 1;
    }
  }

  if (!args.baseline || !args.override || !args.output) {
    throw new Error(
      'usage: code_optimize_schematic_layout_cli.js --baseline base.json --override custom.elk.json --output merged.json'
    );
  }

  return args;
}

function readJson(jsonPath) {
  return JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
}

function writeJson(jsonPath, value) {
  fs.writeFileSync(jsonPath, JSON.stringify(value, null, 2), 'utf8');
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function normalizeLegacyEdgeEndpoints(layout) {
  for (const edge of layout.edges || []) {
    if ((!Array.isArray(edge.sources) || edge.sources.length === 0) && edge.sourcePort) {
      edge.sources = [edge.sourcePort];
    }
    if ((!Array.isArray(edge.targets) || edge.targets.length === 0) && edge.targetPort) {
      edge.targets = [edge.targetPort];
    }
  }
}

function nearlyEqual(lhs, rhs, epsilon = 1e-6) {
  return Math.abs(Number(lhs || 0) - Number(rhs || 0)) <= epsilon;
}

function splitPortId(portId) {
  const dotIdx = String(portId).indexOf('.');
  if (dotIdx < 0) {
    return { nodeId: String(portId), portId: String(portId) };
  }
  return {
    nodeId: portId.slice(0, dotIdx),
    portId,
  };
}

function buildLayoutIndex(layout) {
  const childById = new Map();
  const portById = new Map();
  const edgeById = new Map();

  for (const child of layout.children || []) {
    childById.set(child.id, child);
    for (const port of child.ports || []) {
      portById.set(port.id, { child, port });
    }
  }

  for (const edge of layout.edges || []) {
    edgeById.set(edge.id, edge);
  }

  return { childById, portById, edgeById };
}

function getPortRef(layoutIndex, portId) {
  return layoutIndex.portById.get(portId) || null;
}

function getAbsPortPoint(layoutIndex, portId) {
  const ref = getPortRef(layoutIndex, portId);
  if (!ref) {
    return null;
  }
  return {
    x: Number(ref.child.x || 0) + Number(ref.port.x || 0),
    y: Number(ref.child.y || 0) + Number(ref.port.y || 0),
    child: ref.child,
    port: ref.port,
  };
}

function getPortSide(child, port) {
  const x = Number(port.x || 0);
  const y = Number(port.y || 0);
  const width = Number(child.width || 0);
  const height = Number(child.height || 0);

  if (nearlyEqual(x, 0)) {
    return 'left';
  }
  if (nearlyEqual(x, width)) {
    return 'right';
  }
  if (nearlyEqual(y, 0)) {
    return 'top';
  }
  if (nearlyEqual(y, height)) {
    return 'bottom';
  }
  return 'unknown';
}

function uniqueSorted(values, compareFn) {
  return Array.from(new Set(values)).sort(compareFn);
}

function median(values) {
  if (!values.length) {
    return 0;
  }
  const sorted = [...values].sort((lhs, rhs) => lhs - rhs);
  const mid = Math.floor(sorted.length / 2);
  if ((sorted.length % 2) === 1) {
    return sorted[mid];
  }
  return (sorted[mid - 1] + sorted[mid]) / 2;
}

function calcLaneStep(offsets) {
  if (offsets.length < 2) {
    return 10;
  }
  const diffs = [];
  for (let idx = 1; idx < offsets.length; idx += 1) {
    const diff = Math.abs(offsets[idx] - offsets[idx - 1]);
    if (diff > 0) {
      diffs.push(diff);
    }
  }
  const step = Math.round(median(diffs));
  return step > 0 ? step : 10;
}

function clonePoint(point) {
  return {
    x: Number(point.x || 0),
    y: Number(point.y || 0),
  };
}

function buildEdgeSection(existingSection, startPoint, endPoint, bendPoints) {
  const nextSection = existingSection ? clone(existingSection) : {};
  nextSection.startPoint = clonePoint(startPoint);
  nextSection.endPoint = clonePoint(endPoint);
  if (bendPoints && bendPoints.length > 0) {
    nextSection.bendPoints = bendPoints.map(clonePoint);
  }
  else {
    delete nextSection.bendPoints;
  }
  return nextSection;
}

function buildDirectSection(existingSection, startPoint, endPoint) {
  return buildEdgeSection(existingSection, startPoint, endPoint, []);
}

function samePoint(lhs, rhs) {
  return !!lhs && !!rhs && nearlyEqual(lhs.x, rhs.x) && nearlyEqual(lhs.y, rhs.y);
}

function extractJunctionPointRefs(section, junctionPoints) {
  if (!section || !Array.isArray(junctionPoints) || junctionPoints.length === 0) {
    return [];
  }

  const bendPoints = section.bendPoints || [];
  return junctionPoints.map((junction) => {
    if (samePoint(junction, section.startPoint)) {
      return { kind: 'start' };
    }
    if (samePoint(junction, section.endPoint)) {
      return { kind: 'end' };
    }

    const bendIdx = bendPoints.findIndex((bendPoint) => samePoint(junction, bendPoint));
    if (bendIdx >= 0) {
      return { kind: 'bend', index: bendIdx };
    }
    return null;
  }).filter(Boolean);
}

function resolveJunctionPointRef(section, junctionRef) {
  if (!section || !junctionRef) {
    return null;
  }
  if (junctionRef.kind === 'start') {
    return section.startPoint;
  }
  if (junctionRef.kind === 'end') {
    return section.endPoint;
  }
  if (junctionRef.kind === 'bend') {
    const bendPoints = section.bendPoints || [];
    return bendPoints[junctionRef.index] || null;
  }
  return null;
}

function applyEdgeSection(edge, nextSection) {
  const currentSection = (edge.sections || [])[0] || null;
  const junctionRefs = extractJunctionPointRefs(currentSection, edge.junctionPoints || []);

  edge.sections = [nextSection];

  if (junctionRefs.length === 0) {
    delete edge.junctionPoints;
    return;
  }

  const nextJunctionPoints = junctionRefs
    .map((junctionRef) => resolveJunctionPointRef(nextSection, junctionRef))
    .filter(Boolean)
    .map(clonePoint);

  if (nextJunctionPoints.length > 0) {
    edge.junctionPoints = nextJunctionPoints;
  }
  else {
    delete edge.junctionPoints;
  }
}

function applyEdgeSectionExplicit(edge, nextSection, junctionPoints) {
  edge.sections = [nextSection];
  if (Array.isArray(junctionPoints) && junctionPoints.length > 0) {
    edge.junctionPoints = junctionPoints.map(clonePoint);
  }
  else {
    delete edge.junctionPoints;
  }
}

function clampLane(laneX, startPoint, endPoint) {
  const minX = Math.min(startPoint.x, endPoint.x);
  const maxX = Math.max(startPoint.x, endPoint.x);
  if (maxX - minX < 40) {
    return (startPoint.x + endPoint.x) / 2;
  }

  const lower = minX + 20;
  const upper = maxX - 20;
  if (laneX < lower) {
    return lower;
  }
  if (laneX > upper) {
    return upper;
  }
  return laneX;
}

function buildVerticalLaneSection(existingSection, startPoint, endPoint, laneX) {
  const clampedLane = clampLane(laneX, startPoint, endPoint);
  if (nearlyEqual(startPoint.y, endPoint.y)) {
    return buildDirectSection(existingSection, startPoint, endPoint);
  }

  return buildEdgeSection(existingSection, startPoint, endPoint, [
    { x: clampedLane, y: startPoint.y },
    { x: clampedLane, y: endPoint.y },
  ]);
}

function buildStructuredFanoutRoute(existingSection, startPoint, endPoint, laneX) {
  const clampedLane = clampLane(laneX, startPoint, endPoint);
  if (nearlyEqual(startPoint.y, endPoint.y)) {
    return {
      section: buildDirectSection(existingSection, startPoint, endPoint),
      junctionPoints: [],
    };
  }

  const section = buildEdgeSection(existingSection, startPoint, endPoint, [
    { x: clampedLane, y: startPoint.y },
    { x: clampedLane, y: endPoint.y },
  ]);

  const junctionPoints = nearlyEqual(clampedLane, endPoint.x)
    ? []
    : [{ x: clampedLane, y: endPoint.y }];

  return { section, junctionPoints };
}

function buildFallbackSection(existingSection, baselineInfo, startPoint, endPoint) {
  if (nearlyEqual(startPoint.x, endPoint.x) || nearlyEqual(startPoint.y, endPoint.y)) {
    return buildDirectSection(existingSection, startPoint, endPoint);
  }

  if (baselineInfo.baseLaneX != null) {
    const sourceDelta = Math.abs(baselineInfo.baseLaneX - baselineInfo.baseStartPoint.x);
    const targetDelta = Math.abs(baselineInfo.baseLaneX - baselineInfo.baseEndPoint.x);
    const laneX = sourceDelta <= targetDelta
      ? startPoint.x + (baselineInfo.baseLaneX - baselineInfo.baseStartPoint.x)
      : endPoint.x + (baselineInfo.baseLaneX - baselineInfo.baseEndPoint.x);
    return buildVerticalLaneSection(existingSection, startPoint, endPoint, laneX);
  }

  const laneX = (startPoint.x + endPoint.x) / 2;
  return buildVerticalLaneSection(existingSection, startPoint, endPoint, laneX);
}

function intervalOf(startPoint, endPoint) {
  return {
    start: Math.min(startPoint.y, endPoint.y),
    end: Math.max(startPoint.y, endPoint.y),
  };
}

function intervalsOverlap(lhs, rhs, padding = 4) {
  return !(lhs.end + padding < rhs.start || rhs.end + padding < lhs.start);
}

function orderOffsetsNearAnchor(side, offsets) {
  if (side === 'left' || side === 'top') {
    return [...offsets].sort((lhs, rhs) => rhs - lhs);
  }
  return [...offsets].sort((lhs, rhs) => lhs - rhs);
}

function describeEdge(edge, layoutIndex) {
  const sourcePortId = edge.sources[0];
  const targetPortId = edge.targets[0];
  const sourceRef = getPortRef(layoutIndex, sourcePortId);
  const targetRef = getPortRef(layoutIndex, targetPortId);
  const sourcePoint = getAbsPortPoint(layoutIndex, sourcePortId);
  const targetPoint = getAbsPortPoint(layoutIndex, targetPortId);
  const section = (edge.sections || [])[0] || {};
  const bendPoints = section.bendPoints || [];
  let baseLaneX = null;
  if (bendPoints.length === 2 && nearlyEqual(bendPoints[0].x, bendPoints[1].x)) {
    baseLaneX = Number(bendPoints[0].x);
  }

  return {
    edgeId: edge.id,
    sourcePortId,
    targetPortId,
    sourceNodeId: splitPortId(sourcePortId).nodeId,
    targetNodeId: splitPortId(targetPortId).nodeId,
    sourceRef,
    targetRef,
    sourceSide: sourceRef ? getPortSide(sourceRef.child, sourceRef.port) : 'unknown',
    targetSide: targetRef ? getPortSide(targetRef.child, targetRef.port) : 'unknown',
    baseStartPoint: sourcePoint,
    baseEndPoint: targetPoint,
    baseLaneX,
    baseSection: section,
    baseHasDirectSection: bendPoints.length === 0,
  };
}

function copyChildOverrides(baseLayout, overrideLayout) {
  const baseIndex = buildLayoutIndex(baseLayout);
  const overrideIndex = buildLayoutIndex(overrideLayout);
  const movedNodeIds = new Set();

  for (const [childId, overrideChild] of overrideIndex.childById.entries()) {
    const baseChild = baseIndex.childById.get(childId);
    if (!baseChild) {
      continue;
    }

    const beforeX = Number(baseChild.x || 0);
    const beforeY = Number(baseChild.y || 0);
    if (overrideChild.x != null) {
      baseChild.x = Number(overrideChild.x);
    }
    if (overrideChild.y != null) {
      baseChild.y = Number(overrideChild.y);
    }
    if (!nearlyEqual(beforeX, baseChild.x) || !nearlyEqual(beforeY, baseChild.y)) {
      movedNodeIds.add(childId);
    }

    const basePorts = new Map((baseChild.ports || []).map((port) => [port.id, port]));
    for (const overridePort of overrideChild.ports || []) {
      const basePort = basePorts.get(overridePort.id);
      if (!basePort) {
        continue;
      }
      const beforePortX = Number(basePort.x || 0);
      const beforePortY = Number(basePort.y || 0);
      if (overridePort.x != null) {
        basePort.x = Number(overridePort.x);
      }
      if (overridePort.y != null) {
        basePort.y = Number(overridePort.y);
      }
      if (!nearlyEqual(beforePortX, basePort.x) || !nearlyEqual(beforePortY, basePort.y)) {
        movedNodeIds.add(childId);
      }
    }
  }

  return movedNodeIds;
}

function isBoundaryNode(nodeId) {
  return typeof nodeId === 'string' && !nodeId.startsWith('u');
}

function alignBoundaryNodesToPorts(mergedLayout, movedNodeIds) {
  const mergedIndex = buildLayoutIndex(mergedLayout);
  const childById = new Map((mergedLayout.children || []).map((child) => [child.id, child]));

  for (const edge of mergedLayout.edges || []) {
    const sourcePortId = edge.sources[0];
    const targetPortId = edge.targets[0];
    const sourceRef = getPortRef(mergedIndex, sourcePortId);
    const targetRef = getPortRef(mergedIndex, targetPortId);
    if (!sourceRef || !targetRef) {
      continue;
    }

    const sourceNodeId = sourceRef.child.id;
    const targetNodeId = targetRef.child.id;

    if (isBoundaryNode(sourceNodeId) && !isBoundaryNode(targetNodeId)) {
      const targetPoint = getAbsPortPoint(mergedIndex, targetPortId);
      const nextY = Number(targetPoint.y) - Number(sourceRef.port.y || 0);
      const sourceChild = childById.get(sourceNodeId);
      if (sourceChild && !nearlyEqual(sourceChild.y, nextY)) {
        sourceChild.y = nextY;
        movedNodeIds.add(sourceNodeId);
      }
      continue;
    }

    if (!isBoundaryNode(sourceNodeId) && isBoundaryNode(targetNodeId)) {
      const sourcePoint = getAbsPortPoint(mergedIndex, sourcePortId);
      const nextY = Number(sourcePoint.y) - Number(targetRef.port.y || 0);
      const targetChild = childById.get(targetNodeId);
      if (targetChild && !nearlyEqual(targetChild.y, nextY)) {
        targetChild.y = nextY;
        movedNodeIds.add(targetNodeId);
      }
    }
  }
}

function routeFanoutSourceGroup(groupInfos, baselineIndex, mergedIndex, mergedEdges) {
  const laneInfo = groupInfos.find((info) => info.baseLaneX != null);
  if (!laneInfo) {
    return;
  }

  if (laneInfo.sourceNodeId === 'uInstrFields') {
    const sourcePoint = getAbsPortPoint(mergedIndex, laneInfo.sourcePortId);
    const laneXs = groupInfos
      .map((info) => info.baseLaneX)
      .filter((laneX) => laneX != null);
    const useRightLane = groupInfos.some((info) => {
      const targetPoint = getAbsPortPoint(mergedIndex, info.targetPortId);
      return targetPoint && sourcePoint && (targetPoint.x >= sourcePoint.x);
    });
    const trunkLaneX = laneXs.length > 0
      ? (useRightLane ? Math.min(...laneXs) : Math.max(...laneXs))
      : laneInfo.baseLaneX;

    for (const info of groupInfos) {
      const edge = mergedEdges.get(info.edgeId);
      const startPoint = getAbsPortPoint(mergedIndex, info.sourcePortId);
      const endPoint = getAbsPortPoint(mergedIndex, info.targetPortId);
      if (!edge || !startPoint || !endPoint) {
        continue;
      }

      const routed = buildStructuredFanoutRoute(edge.sections && edge.sections[0], startPoint, endPoint, trunkLaneX);
      applyEdgeSectionExplicit(edge, routed.section, routed.junctionPoints);
    }
    return;
  }

  const baseSourcePoint = laneInfo.baseStartPoint;
  const laneOffset = laneInfo.baseLaneX - baseSourcePoint.x;
  const sourcePoint = getAbsPortPoint(mergedIndex, laneInfo.sourcePortId);
  const targetPoints = groupInfos
    .map((info) => getAbsPortPoint(mergedIndex, info.targetPortId))
    .filter(Boolean);
  const directionSign = targetPoints.some((point) => point.x < sourcePoint.x) ? -1 : 1;
  const laneStep = 10;
  const hasUpperTargets = groupInfos.some((info) => {
    const targetPoint = getAbsPortPoint(mergedIndex, info.targetPortId);
    return targetPoint && sourcePoint && (targetPoint.y < sourcePoint.y);
  });
  const loweredInfos = groupInfos
    .filter((info) => {
      const targetPoint = getAbsPortPoint(mergedIndex, info.targetPortId);
      return targetPoint && sourcePoint && (targetPoint.y > sourcePoint.y);
    })
    .sort((lhs, rhs) => {
      const lhsPoint = getAbsPortPoint(mergedIndex, lhs.targetPortId);
      const rhsPoint = getAbsPortPoint(mergedIndex, rhs.targetPortId);
      return Number(lhsPoint ? lhsPoint.y : 0) - Number(rhsPoint ? rhsPoint.y : 0);
    });
  const spreadOffsetByEdgeId = new Map();
  if (loweredInfos.length >= 2) {
    loweredInfos.forEach((info, idx) => {
      const lowerIdx = hasUpperTargets ? (idx + 1) : idx;
      spreadOffsetByEdgeId.set(info.edgeId, laneOffset + (lowerIdx * laneStep * directionSign));
    });
  }
  else if (loweredInfos.length === 1 && hasUpperTargets) {
    spreadOffsetByEdgeId.set(loweredInfos[0].edgeId, laneOffset + (laneStep * directionSign));
  }

  for (const info of groupInfos) {
    const edge = mergedEdges.get(info.edgeId);
    const startPoint = getAbsPortPoint(mergedIndex, info.sourcePortId);
    const endPoint = getAbsPortPoint(mergedIndex, info.targetPortId);
    if (!edge || !startPoint || !endPoint) {
      continue;
    }

    const keepDirect = info.baseHasDirectSection && nearlyEqual(startPoint.y, endPoint.y);
    const nextSection = keepDirect
      ? buildDirectSection(edge.sections && edge.sections[0], startPoint, endPoint)
      : buildVerticalLaneSection(
          edge.sections && edge.sections[0],
          startPoint,
          endPoint,
          startPoint.x + (spreadOffsetByEdgeId.get(info.edgeId) ?? laneOffset)
        );
    applyEdgeSection(edge, nextSection);
  }
}

function firstVerticalLaneX(edge) {
  const section = (edge.sections || [])[0];
  if (!section) {
    return null;
  }
  const bendPoints = section.bendPoints || [];
  if (bendPoints.length < 2) {
    return null;
  }
  if (!nearlyEqual(bendPoints[0].x, bendPoints[1].x)) {
    return null;
  }
  return Number(bendPoints[0].x);
}

function enforceBranchStoreMirrorLanes(mergedLayout) {
  const mergedIndex = buildLayoutIndex(mergedLayout);
  const mergedEdges = mergedIndex.edgeById;
  const branchInfos = [];
  const storeInfos = [];

  for (const edge of mergedLayout.edges || []) {
    const sourcePortId = edge.sources[0];
    const targetPortId = edge.targets[0];
    const sourceNodeId = splitPortId(sourcePortId).nodeId;

    if (sourceNodeId === 'uBranchDecoder' && targetPortId.startsWith('uControlComposer.iBranch')) {
      branchInfos.push({
        edge,
        sourcePortId,
        targetPortId,
        laneX: firstVerticalLaneX(edge),
        orderY: getAbsPortPoint(mergedIndex, sourcePortId)?.y ?? 0,
      });
      continue;
    }

    if (sourceNodeId === 'uStoreDecoder' && targetPortId.startsWith('uControlComposer.iStore')) {
      storeInfos.push({
        edge,
        sourcePortId,
        targetPortId,
        laneX: firstVerticalLaneX(edge),
        orderY: getAbsPortPoint(mergedIndex, sourcePortId)?.y ?? 0,
      });
    }
  }

  const mirroredLaneXs = storeInfos
    .filter((info) => info.laneX != null)
    .sort((lhs, rhs) => lhs.orderY - rhs.orderY)
    .map((info) => info.laneX);

  if (!mirroredLaneXs.length || !branchInfos.length) {
    return;
  }

  const sortedBranchInfos = [...branchInfos].sort((lhs, rhs) => lhs.orderY - rhs.orderY);
  sortedBranchInfos.forEach((info, idx) => {
    const edge = mergedEdges.get(info.edge.id);
    const startPoint = getAbsPortPoint(mergedIndex, info.sourcePortId);
    const endPoint = getAbsPortPoint(mergedIndex, info.targetPortId);
    if (!edge || !startPoint || !endPoint) {
      return;
    }

    const laneX = mirroredLaneXs[Math.min(idx, mirroredLaneXs.length - 1)];
    applyEdgeSection(
      edge,
      buildVerticalLaneSection(edge.sections && edge.sections[0], startPoint, endPoint, laneX)
    );
  });
}

function mirrorUpperControlComposerFanInLanes(mergedLayout) {
  const mergedIndex = buildLayoutIndex(mergedLayout);
  const mergedEdges = mergedIndex.edgeById;
  const upperInfos = [];
  const lowerInfos = [];

  for (const edge of mergedLayout.edges || []) {
    const sourcePortId = edge.sources[0];
    const targetPortId = edge.targets[0];
    if (!targetPortId.startsWith('uControlComposer.i')) {
      continue;
    }

    const sourcePoint = getAbsPortPoint(mergedIndex, sourcePortId);
    const targetPoint = getAbsPortPoint(mergedIndex, targetPortId);
    const laneX = firstVerticalLaneX(edge);
    if (!sourcePoint || !targetPoint || laneX == null) {
      continue;
    }

    const info = {
      edge,
      sourcePortId,
      targetPortId,
      sourcePoint,
      targetPoint,
      laneX,
    };

    if (sourcePoint.y < targetPoint.y) {
      upperInfos.push(info);
    }
    else if (sourcePoint.y > targetPoint.y) {
      lowerInfos.push(info);
    }
  }

  if (!upperInfos.length || !lowerInfos.length) {
    return;
  }

  const lowerLanePalette = lowerInfos
    .sort((lhs, rhs) => lhs.sourcePoint.y - rhs.sourcePoint.y)
    .map((info) => info.laneX);

  if (!lowerLanePalette.length) {
    return;
  }

  const laneStep = calcLaneStep(uniqueSorted(lowerLanePalette, (lhs, rhs) => lhs - rhs));
  const sortedUpperInfos = [...upperInfos].sort((lhs, rhs) => rhs.sourcePoint.y - lhs.sourcePoint.y);

  sortedUpperInfos.forEach((info, idx) => {
    const edge = mergedEdges.get(info.edge.id);
    if (!edge) {
      return;
    }

    const paletteLane = idx < lowerLanePalette.length
      ? lowerLanePalette[idx]
      : lowerLanePalette[lowerLanePalette.length - 1] + ((idx - lowerLanePalette.length + 1) * laneStep);

    applyEdgeSection(
      edge,
      buildVerticalLaneSection(edge.sections && edge.sections[0], info.sourcePoint, info.targetPoint, paletteLane)
    );
  });
}

function spreadLowerSourceFanoutLanes(mergedLayout) {
  const edgesBySourcePort = new Map();

  for (const edge of mergedLayout.edges || []) {
    const sourcePortId = edge.sources[0];
    if (!edgesBySourcePort.has(sourcePortId)) {
      edgesBySourcePort.set(sourcePortId, []);
    }
    edgesBySourcePort.get(sourcePortId).push(edge);
  }

  for (const groupedEdges of edgesBySourcePort.values()) {
    if (groupedEdges.length < 2) {
      continue;
    }

    const shapedEdges = groupedEdges
      .map((edge) => {
        const section = (edge.sections || [])[0];
        if (!section) {
          return null;
        }
        const bends = section.bendPoints || [];
        if (bends.length !== 2 || !nearlyEqual(bends[0].x, bends[1].x)) {
          return null;
        }
        return {
          edge,
          section,
          laneX: Number(bends[0].x),
        };
      })
      .filter(Boolean);

    if (shapedEdges.length < 2) {
      continue;
    }

    const sourcePoint = shapedEdges[0].section.startPoint;
    const goingRight = shapedEdges[0].section.endPoint.x >= sourcePoint.x;
    const sign = goingRight ? 1 : -1;
    const lowerEdges = shapedEdges
      .filter(({ edge }) => splitPortId(edge.sources[0]).nodeId !== 'uInstrFields')
      .filter(({ section }) => Number(section.endPoint.y) > Number(sourcePoint.y))
      .sort((lhs, rhs) => Number(lhs.section.endPoint.y) - Number(rhs.section.endPoint.y));

    if (lowerEdges.length < 2) {
      continue;
    }

    const uniqueLaneCount = new Set(lowerEdges.map(({ laneX }) => laneX)).size;
    if (uniqueLaneCount >= lowerEdges.length) {
      continue;
    }

    const baseLaneX = goingRight
      ? Math.max(...lowerEdges.map(({ laneX }) => laneX))
      : Math.min(...lowerEdges.map(({ laneX }) => laneX));
    const laneStep = 10;

    lowerEdges.forEach(({ edge, section }, idx) => {
      const laneX = baseLaneX + (idx * laneStep * sign);
      applyEdgeSection(edge, buildVerticalLaneSection(section, section.startPoint, section.endPoint, laneX));
    });
  }
}

function routeAnchorGroup(groupInfos, anchorKind, side, baselineIndex, mergedIndex, mergedEdges) {
  if (!groupInfos.length || (side !== 'left' && side !== 'right')) {
    return;
  }

  const baselineSortedInfos = [...groupInfos].sort((lhs, rhs) => {
    const lhsRemote = anchorKind === 'target' ? lhs.baseStartPoint : lhs.baseEndPoint;
    const rhsRemote = anchorKind === 'target' ? rhs.baseStartPoint : rhs.baseEndPoint;
    return Number(lhsRemote ? lhsRemote.y : 0) - Number(rhsRemote ? rhsRemote.y : 0);
  });

  const sortedInfos = [...groupInfos].sort((lhs, rhs) => {
    const lhsRemote = anchorKind === 'target'
      ? getAbsPortPoint(mergedIndex, lhs.sourcePortId)
      : getAbsPortPoint(mergedIndex, lhs.targetPortId);
    const rhsRemote = anchorKind === 'target'
      ? getAbsPortPoint(mergedIndex, rhs.sourcePortId)
      : getAbsPortPoint(mergedIndex, rhs.targetPortId);
    return Number(lhsRemote ? lhsRemote.y : 0) - Number(rhsRemote ? rhsRemote.y : 0);
  });

  const orderedOffsets = [];
  for (const info of baselineSortedInfos) {
    if (info.baseLaneX == null) {
      continue;
    }
    const baseAnchor = anchorKind === 'target'
      ? info.baseEndPoint
      : info.baseStartPoint;
    orderedOffsets.push(info.baseLaneX - baseAnchor.x);
  }

  let laneStep = calcLaneStep(uniqueSorted(orderedOffsets, (lhs, rhs) => lhs - rhs));
  if (laneStep <= 0) {
    laneStep = 10;
  }

  const isDescendingIntoTarget = anchorKind === 'target' && side === 'left' && sortedInfos.some((info) => {
    const startPoint = getAbsPortPoint(mergedIndex, info.sourcePortId);
    const endPoint = getAbsPortPoint(mergedIndex, info.targetPortId);
    return startPoint && endPoint && (startPoint.y > endPoint.y);
  });
  if (isDescendingIntoTarget) {
    laneStep = Math.max(laneStep, 18);
  }

  if (!orderedOffsets.length) {
    orderedOffsets.push(side === 'left' ? -laneStep : laneStep);
  }
  const outermostOffset = side === 'left'
    ? Math.min(...orderedOffsets)
    : Math.max(...orderedOffsets);
  const laneUsage = new Map();

  if (isDescendingIntoTarget) {
    const descendingInfos = sortedInfos.filter((info) => {
      const startPoint = getAbsPortPoint(mergedIndex, info.sourcePortId);
      const endPoint = getAbsPortPoint(mergedIndex, info.targetPortId);
      return startPoint && endPoint && (startPoint.y > endPoint.y);
    });
    const nonDescendingInfos = sortedInfos.filter((info) => !descendingInfos.includes(info));

    if (descendingInfos.length) {
      // For lower fan-in groups, push the first bend farther away as the source
      // module moves downward so the module-to-bend horizontal gap widens.
      const farthestLaneX = Math.max(...baselineSortedInfos
        .filter((info) => info.baseLaneX != null)
        .map((info) => info.baseLaneX));
      const closestLegalLaneX = Math.max(...descendingInfos.map((info) => {
        const startPoint = getAbsPortPoint(mergedIndex, info.sourcePortId);
        const endPoint = getAbsPortPoint(mergedIndex, info.targetPortId);
        return Math.min(startPoint.x, endPoint.x) + 20;
      }));
      const descendingLaneStep = descendingInfos.length > 1
        ? Math.max(10, Math.floor((farthestLaneX - closestLegalLaneX) / (descendingInfos.length - 1)))
        : 0;

      for (let idx = 0; idx < descendingInfos.length; idx += 1) {
        const info = descendingInfos[idx];
        const edge = mergedEdges.get(info.edgeId);
        const startPoint = getAbsPortPoint(mergedIndex, info.sourcePortId);
        const endPoint = getAbsPortPoint(mergedIndex, info.targetPortId);
        if (!edge || !startPoint || !endPoint) {
          continue;
        }

        const keepDirect = info.baseHasDirectSection && nearlyEqual(startPoint.y, endPoint.y);
        if (keepDirect) {
          applyEdgeSection(edge, buildDirectSection(edge.sections && edge.sections[0], startPoint, endPoint));
          continue;
        }

        const laneX = Math.min(
          farthestLaneX,
          closestLegalLaneX + (idx * descendingLaneStep)
        );
        applyEdgeSection(edge, buildVerticalLaneSection(edge.sections && edge.sections[0], startPoint, endPoint, laneX));
      }
    }

    const routedNonDescendingInfos = nonDescendingInfos.filter((info) => {
      const startPoint = getAbsPortPoint(mergedIndex, info.sourcePortId);
      const endPoint = getAbsPortPoint(mergedIndex, info.targetPortId);
      return startPoint && endPoint && !(
        info.baseHasDirectSection && nearlyEqual(startPoint.y, endPoint.y)
      );
    });

    const farthestNonDescendingLaneX = routedNonDescendingInfos.length > 0
      ? Math.max(...baselineSortedInfos
        .filter((info) => routedNonDescendingInfos.includes(info) && info.baseLaneX != null)
        .map((info) => info.baseLaneX))
      : null;
    const closestLegalNonDescendingLaneX = routedNonDescendingInfos.length > 0
      ? Math.max(...routedNonDescendingInfos.map((info) => {
        const startPoint = getAbsPortPoint(mergedIndex, info.sourcePortId);
        const endPoint = getAbsPortPoint(mergedIndex, info.targetPortId);
        return Math.min(startPoint.x, endPoint.x) + 20;
      }))
      : null;
    const nonDescendingLaneStep = routedNonDescendingInfos.length > 1
      ? Math.max(
        10,
        Math.floor(
          (farthestNonDescendingLaneX - closestLegalNonDescendingLaneX) /
          (routedNonDescendingInfos.length - 1)
        )
      )
      : 0;

    let nonDescendingLaneIdx = 0;
    for (let idx = 0; idx < nonDescendingInfos.length; idx += 1) {
      const info = nonDescendingInfos[idx];
      const edge = mergedEdges.get(info.edgeId);
      const startPoint = getAbsPortPoint(mergedIndex, info.sourcePortId);
      const endPoint = getAbsPortPoint(mergedIndex, info.targetPortId);
      if (!edge || !startPoint || !endPoint) {
        continue;
      }

      const keepDirect = info.baseHasDirectSection && nearlyEqual(startPoint.y, endPoint.y);
      if (keepDirect) {
        applyEdgeSection(edge, buildDirectSection(edge.sections && edge.sections[0], startPoint, endPoint));
        continue;
      }

      const laneX = farthestNonDescendingLaneX != null && closestLegalNonDescendingLaneX != null
        ? Math.max(
          closestLegalNonDescendingLaneX,
          farthestNonDescendingLaneX - (nonDescendingLaneIdx * nonDescendingLaneStep)
        )
        : endPoint.x + outermostOffset;
      nonDescendingLaneIdx += 1;
      applyEdgeSection(edge, buildVerticalLaneSection(edge.sections && edge.sections[0], startPoint, endPoint, laneX));
    }
    return;
  }

  for (let idx = 0; idx < sortedInfos.length; idx += 1) {
    const info = sortedInfos[idx];
    const edge = mergedEdges.get(info.edgeId);
    const startPoint = getAbsPortPoint(mergedIndex, info.sourcePortId);
    const endPoint = getAbsPortPoint(mergedIndex, info.targetPortId);
    if (!edge || !startPoint || !endPoint) {
      continue;
    }

    const keepDirect = info.baseHasDirectSection && nearlyEqual(startPoint.y, endPoint.y);
    if (keepDirect) {
      applyEdgeSection(edge, buildDirectSection(edge.sections && edge.sections[0], startPoint, endPoint));
      continue;
    }

    const anchorPoint = anchorKind === 'target' ? endPoint : startPoint;
    const preferredOffset = idx < orderedOffsets.length
      ? orderedOffsets[idx]
      : (side === 'left'
        ? outermostOffset - (laneStep * (idx - orderedOffsets.length + 1))
        : outermostOffset + (laneStep * (idx - orderedOffsets.length + 1)));

    const interval = intervalOf(startPoint, endPoint);
    let laneOffset = preferredOffset;
    while (true) {
      const laneKey = String(laneOffset);
      const usedIntervals = laneUsage.get(laneKey) || [];
      const overlaps = usedIntervals.some((other) => intervalsOverlap(other, interval));
      if (!overlaps) {
        if (!laneUsage.has(laneKey)) {
          laneUsage.set(laneKey, []);
        }
        laneUsage.get(laneKey).push(interval);
        break;
      }
      laneOffset = side === 'left' ? laneOffset - laneStep : laneOffset + laneStep;
    }

    const laneX = anchorPoint.x + laneOffset;
    applyEdgeSection(edge, buildVerticalLaneSection(edge.sections && edge.sections[0], startPoint, endPoint, laneX));
  }
}

function rerouteMovedEdges(baselineLayout, mergedLayout, movedNodeIds) {
  const baselineIndex = buildLayoutIndex(baselineLayout);
  const mergedIndex = buildLayoutIndex(mergedLayout);
  const mergedEdges = mergedIndex.edgeById;

  const edgeInfos = [];
  const edgesBySourcePort = new Map();
  const edgesBySourceNode = new Map();
  const edgesByTargetNode = new Map();

  for (const edge of baselineLayout.edges || []) {
    const info = describeEdge(edge, baselineIndex);
    edgeInfos.push(info);

    if (!edgesBySourcePort.has(info.sourcePortId)) {
      edgesBySourcePort.set(info.sourcePortId, []);
    }
    edgesBySourcePort.get(info.sourcePortId).push(info);

    if (!edgesBySourceNode.has(info.sourceNodeId)) {
      edgesBySourceNode.set(info.sourceNodeId, []);
    }
    edgesBySourceNode.get(info.sourceNodeId).push(info);

    if (!edgesByTargetNode.has(info.targetNodeId)) {
      edgesByTargetNode.set(info.targetNodeId, []);
    }
    edgesByTargetNode.get(info.targetNodeId).push(info);
  }

  const handledEdges = new Set();
  const impactedEdgeIds = new Set();
  for (const info of edgeInfos) {
    if (movedNodeIds.has(info.sourceNodeId) || movedNodeIds.has(info.targetNodeId)) {
      impactedEdgeIds.add(info.edgeId);
    }
  }

  for (const [sourcePortId, groupInfos] of edgesBySourcePort.entries()) {
    if (groupInfos.length <= 1) {
      continue;
    }
    if (!groupInfos.some((info) => info.baseLaneX != null)) {
      continue;
    }
    const impacted = groupInfos.some((info) => impactedEdgeIds.has(info.edgeId));
    if (!impacted) {
      continue;
    }
    routeFanoutSourceGroup(groupInfos, baselineIndex, mergedIndex, mergedEdges);
    for (const info of groupInfos) {
      handledEdges.add(info.edgeId);
    }
  }

  const anchorGroups = new Map();
  for (const info of edgeInfos) {
    if (handledEdges.has(info.edgeId)) {
      continue;
    }

    const sourceCount = (edgesBySourceNode.get(info.sourceNodeId) || []).length;
    const targetCount = (edgesByTargetNode.get(info.targetNodeId) || []).length;
    let anchorKind = '';
    let anchorNodeId = '';
    let anchorSide = '';

    if (targetCount > sourceCount && targetCount > 1) {
      anchorKind = 'target';
      anchorNodeId = info.targetNodeId;
      anchorSide = info.targetSide;
    }
    else if (sourceCount > 1) {
      anchorKind = 'source';
      anchorNodeId = info.sourceNodeId;
      anchorSide = info.sourceSide;
    }
    else {
      continue;
    }

    if (anchorSide !== 'left' && anchorSide !== 'right') {
      continue;
    }

    const groupKey = `${anchorKind}:${anchorNodeId}:${anchorSide}`;
    if (!anchorGroups.has(groupKey)) {
      anchorGroups.set(groupKey, {
        anchorKind,
        anchorSide,
        infos: [],
      });
    }
    anchorGroups.get(groupKey).infos.push(info);
  }

  for (const group of anchorGroups.values()) {
    const impacted = group.infos.some((info) => impactedEdgeIds.has(info.edgeId));
    if (!impacted) {
      continue;
    }
    routeAnchorGroup(group.infos, group.anchorKind, group.anchorSide, baselineIndex, mergedIndex, mergedEdges);
    for (const info of group.infos) {
      handledEdges.add(info.edgeId);
    }
  }

  for (const info of edgeInfos) {
    if (handledEdges.has(info.edgeId) || !impactedEdgeIds.has(info.edgeId)) {
      continue;
    }

    const edge = mergedEdges.get(info.edgeId);
    const startPoint = getAbsPortPoint(mergedIndex, info.sourcePortId);
    const endPoint = getAbsPortPoint(mergedIndex, info.targetPortId);
    if (!edge || !startPoint || !endPoint) {
      continue;
    }

    applyEdgeSection(
      edge,
      buildFallbackSection(edge.sections && edge.sections[0], info, startPoint, endPoint)
    );
  }
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const baselinePath = path.resolve(args.baseline);
  const overridePath = path.resolve(args.override);
  const outputPath = path.resolve(args.output);

  const baselineLayout = readJson(baselinePath);
  const overrideLayout = readJson(overridePath);
  const mergedLayout = clone(baselineLayout);

  normalizeLegacyEdgeEndpoints(baselineLayout);
  normalizeLegacyEdgeEndpoints(overrideLayout);
  normalizeLegacyEdgeEndpoints(mergedLayout);

  const movedNodeIds = copyChildOverrides(mergedLayout, overrideLayout);
  alignBoundaryNodesToPorts(mergedLayout, movedNodeIds);
  rerouteMovedEdges(baselineLayout, mergedLayout, movedNodeIds);
  spreadLowerSourceFanoutLanes(mergedLayout);
  enforceBranchStoreMirrorLanes(mergedLayout);
  mirrorUpperControlComposerFanInLanes(mergedLayout);

  writeJson(outputPath, mergedLayout);
  process.stdout.write(
    `[INFO] Optimized merged layout written: ${outputPath} (moved nodes: ${movedNodeIds.size})\n`
  );
}

main();
