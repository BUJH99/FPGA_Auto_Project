const fs = require("fs");
const path = require("path");
const fg = require("fast-glob");
const { loadStrictManifestContext } = require("../../../shared/application/manifest_contract_loader");
const { ensureDir, writeJsonFile } = require("../../../shared/application/json_file_service");
const { createVitisPlan, normalizeSlashes } = require("../domain/vitis_contracts");
const {
  defaultBitGlobs,
  defaultApplicationIncludes,
  defaultApplicationSources,
  defaultPlatformName,
  defaultPlatformXpfm,
  defaultSummaryFile,
  defaultWorkspace,
  defaultXsaPath,
  interpolateTemplate,
  sanitizeName,
} = require("../domain/vitis_defaults");

const APP_STEPS = new Set(["create_application", "build_application", "run_application"]);
const MULTI_APP_STEPS = new Set(["create_application", "build_application", "full_flow"]);
const PLATFORM_SELECT_STEPS = new Set(["build_platform", "create_application", "run_application", "full_flow"]);
const VALID_STEPS = new Set([
  "export_xsa",
  "create_platform",
  "create_application",
  "build_platform",
  "build_application",
  "run_application",
  "full_flow",
]);

function isPlainObject(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function toBoolean(value, fallback) {
  if (typeof value === "boolean") return value;
  if (value === undefined || value === null || value === "") return Boolean(fallback);
  const normalized = String(value).trim().toLowerCase();
  if (["1", "true", "yes", "y", "on"].includes(normalized)) return true;
  if (["0", "false", "no", "n", "off"].includes(normalized)) return false;
  return Boolean(fallback);
}

function nonEmptyString(value, fallback) {
  const raw = String(value || "").trim();
  return raw || fallback;
}

function stringArray(value, fallback = []) {
  const rows = Array.isArray(value) ? value : fallback;
  return rows.map((row) => String(row || "").trim()).filter(Boolean);
}

function formatTimestamp(date = new Date()) {
  const pad = (value) => String(value).padStart(2, "0");
  return [
    date.getFullYear(),
    pad(date.getMonth() + 1),
    pad(date.getDate()),
    "_",
    pad(date.getHours()),
    pad(date.getMinutes()),
    pad(date.getSeconds()),
  ].join("");
}

function currentTimestamp(forcedValue = "") {
  const requested = String(forcedValue || process.env.FPGA_AUTO_TIMESTAMP || process.env.FPGA_AUTO_RUN_TIMESTAMP || "").trim();
  if (requested) {
    return sanitizeName(requested, formatTimestamp());
  }
  return formatTimestamp();
}

function resolveProjectPath(projectRoot, rawValue, variables) {
  const interpolated = interpolateTemplate(rawValue, variables);
  return path.isAbsolute(interpolated)
    ? path.resolve(interpolated)
    : path.resolve(projectRoot, interpolated);
}

function projectRelative(projectRoot, targetPath) {
  const root = path.resolve(projectRoot);
  const abs = path.resolve(targetPath);
  return normalizeSlashes(path.relative(root, abs));
}

function cmdSetLine(name, value) {
  return `set "${name}=${String(value || "")}"`;
}

function splitSelections(values) {
  const rows = Array.isArray(values) ? values : [values];
  return rows
    .flatMap((value) => String(value || "").split(/[;,]/g))
    .map((value) => value.trim())
    .filter(Boolean);
}

function templateHasToken(rawValue, tokenNames) {
  const raw = String(rawValue || "");
  return tokenNames.some((token) => raw.includes(token));
}

function timestampedFilePath(filePath, timestamp, rawTemplate = "") {
  if (templateHasToken(rawTemplate, ["${timestamp}"])) {
    return filePath;
  }
  const parsed = path.parse(filePath);
  return path.join(parsed.dir, `${parsed.name}_${timestamp}${parsed.ext || ".xsa"}`);
}

function timestampedName(name, timestamp, rawTemplate = "") {
  if (templateHasToken(rawTemplate, ["${timestamp}"])) {
    return name;
  }
  return `${sanitizeName(name, "platform")}_${compactTimestampForName(timestamp)}`;
}

function compactTimestampForName(timestamp) {
  const raw = String(timestamp || "").trim();
  const match = raw.match(/^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})$/);
  if (!match) return sanitizeName(raw, formatTimestamp()).slice(0, 24);
  return `${match[2]}${match[3]}_${match[4]}${match[5]}${match[6]}`;
}

function buildPlanCommand(plan, planPaths) {
  const app = plan.application || {};
  const selectedAppNames = Array.isArray(plan.selectedApplications)
    ? plan.selectedApplications.map((item) => item.name).filter(Boolean).join(",")
    : "";
  return [
    "@echo off",
    cmdSetLine("VITIS_STEP", plan.step),
    cmdSetLine("VITIS_PROJECT_ROOT", plan.projectRoot),
    cmdSetLine("VITIS_MANIFEST_JSON", plan.manifestJsonPath),
    cmdSetLine("VITIS_PLAN_JSON", planPaths.planPath),
    cmdSetLine("VITIS_RESULT_JSON", planPaths.resultPath),
    cmdSetLine("VITIS_SUMMARY_JSON", planPaths.summaryPath),
    cmdSetLine("VITIS_WORKSPACE", plan.workspace),
    cmdSetLine("VITIS_XSA_PATH", plan.xsa.path),
    cmdSetLine("VITIS_XSA_EXPORT_TCL", plan.xsa.exportTcl || ""),
    cmdSetLine("VITIS_XSA_GENERATED_PATH", plan.xsa.generatedPath || ""),
    cmdSetLine("VITIS_XSA_BIT_PATH", plan.xsa.bitPath || ""),
    cmdSetLine("VITIS_XSA_VIVADO_PROJECT", plan.xsa.vivadoProject || ""),
    cmdSetLine("VITIS_XSA_IMPL_RUN", plan.xsa.implRun || "impl_1"),
    cmdSetLine("VITIS_XSA_INCLUDE_BITSTREAM", plan.xsa.includeBitstream ? "1" : "0"),
    cmdSetLine("VITIS_XSA_FIXED", plan.xsa.fixed ? "1" : "0"),
    cmdSetLine("VITIS_XSA_VALIDATE", plan.xsa.validate ? "1" : "0"),
    cmdSetLine("VITIS_PLATFORM_NAME", plan.platform.name),
    cmdSetLine("VITIS_PLATFORM_XPFM", plan.platform.xpfm),
    cmdSetLine("VITIS_PLATFORM_OS", plan.platform.os),
    cmdSetLine("VITIS_PLATFORM_CPU", plan.platform.cpu),
    cmdSetLine("VITIS_PLATFORM_DOMAIN", plan.platform.domainName),
    cmdSetLine("VITIS_APP_NAME", app.name || ""),
    cmdSetLine("VITIS_APP_NAMES", selectedAppNames),
    cmdSetLine("VITIS_APP_TARGET", app.target || ""),
    cmdSetLine("VITIS_RUN_AUTO", plan.run && plan.run.auto ? "1" : "0"),
    cmdSetLine("VITIS_RUN_MODE", plan.run && plan.run.mode || "hardware"),
    cmdSetLine("VITIS_LOG_PATH", plan.paths.logPath),
    cmdSetLine("VITIS_JOURNAL_PATH", plan.paths.journalPath),
    cmdSetLine("VITIS_VIVADO_TOP_MODULE", plan.vivado.topModule || ""),
    cmdSetLine("VITIS_VIVADO_PART_NUMBER", plan.vivado.partNumber || ""),
    cmdSetLine("VITIS_VIVADO_PROJECT_NAME", plan.vivado.projectName || ""),
    "",
  ].join("\r\n");
}

function resolveApplication(projectRoot, rawApp, index, variables, platformDomain) {
  const app = isPlainObject(rawApp) ? rawApp : {};
  const name = sanitizeName(interpolateTemplate(app.name || `app_${index + 1}`, variables), `app_${index + 1}`);
  const appVariables = { ...variables, appName: name };
  const sourceGlobs = stringArray(app.sources, defaultApplicationSources(name))
    .map((row) => interpolateTemplate(row, appVariables));
  const includeDirs = stringArray(app.includes, defaultApplicationIncludes(name))
    .map((row) => normalizeSlashes(resolveProjectPath(projectRoot, row, appVariables)));
  const sourceMatches = sourceGlobs.length > 0
    ? fg.sync(sourceGlobs, { cwd: projectRoot, onlyFiles: true, dot: false, unique: true })
      .sort((left, right) => left.localeCompare(right))
    : [];
  const linkerScript = app.linker_script
    ? normalizeSlashes(resolveProjectPath(projectRoot, app.linker_script, appVariables))
    : "";
  return {
    name,
    template: nonEmptyString(app.template, "empty_application"),
    domain: nonEmptyString(app.domain, platformDomain),
    target: nonEmptyString(app.target, "hw"),
    sourceGlobs: sourceGlobs.map((row) => normalizeSlashes(row)),
    sourceMatches: sourceMatches.map((row) => normalizeSlashes(row)),
    sourceFiles: sourceMatches.map((row) => normalizeSlashes(resolveProjectPath(projectRoot, row, appVariables))),
    includes: includeDirs,
    linkerScript,
  };
}

function resolveApplications(projectRoot, vitisConfig, variables, platformDomain) {
  const configuredApps = Array.isArray(vitisConfig.applications) ? vitisConfig.applications : [];
  return configuredApps.map((rawApp, index) => resolveApplication(
    projectRoot,
    rawApp,
    index,
    variables,
    platformDomain
  ));
}

function readWorkspaceComponentJson(componentDir) {
  const componentJson = path.join(componentDir, "vitis-comp.json");
  try {
    return JSON.parse(fs.readFileSync(componentJson, "utf-8"));
  } catch {
    return {};
  }
}

function componentTypeOf(payload) {
  return String(payload.type || payload.configuration && payload.configuration.componentType || "").trim().toUpperCase();
}

function resolveWorkspaceApplication(projectRoot, workspace, componentDir, payload, index, platformDomain) {
  const name = sanitizeName(payload.name || path.basename(componentDir), `app_${index + 1}`);
  return {
    name,
    template: nonEmptyString(payload.template, "empty_application"),
    domain: nonEmptyString(payload.domain || payload.domainRealName, platformDomain),
    target: "hw",
    sourceGlobs: [],
    sourceMatches: [],
    sourceFiles: [],
    includes: [],
    linkerScript: "",
    discoveredFrom: "workspace",
    componentDir: normalizeSlashes(componentDir),
    relativeComponentDir: projectRelative(projectRoot, componentDir),
    workspaceRelativeComponentDir: normalizeSlashes(path.relative(path.resolve(workspace), path.resolve(componentDir))),
  };
}

function discoverWorkspaceApplications(projectRoot, workspace, platformDomain) {
  if (!workspace || !fs.existsSync(workspace)) return [];
  let entries = [];
  try {
    entries = fs.readdirSync(workspace, { withFileTypes: true });
  } catch {
    return [];
  }
  const applications = [];
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    if (isInternalWorkspaceDir(entry.name)) continue;
    const componentDir = path.join(workspace, entry.name);
    const payload = readWorkspaceComponentJson(componentDir);
    if (componentTypeOf(payload) !== "HOST") continue;
    applications.push(resolveWorkspaceApplication(
      projectRoot,
      workspace,
      componentDir,
      payload,
      applications.length,
      platformDomain
    ));
  }
  return applications.sort((left, right) => left.name.localeCompare(right.name));
}

function mergeApplications(configuredApplications, discoveredApplications) {
  const merged = [];
  const seen = new Set();
  for (const application of [...configuredApplications, ...discoveredApplications]) {
    const name = String(application && application.name || "").trim();
    const key = name.toLowerCase();
    if (!name || seen.has(key)) continue;
    seen.add(key);
    merged.push(application);
  }
  return merged;
}

function loadVitisContext(projectRoot, manifestJsonPath, { timestamp = "" } = {}) {
  const root = path.resolve(projectRoot || process.cwd());
  const manifestJsonAbs = path.resolve(manifestJsonPath || "");
  const manifestContext = loadStrictManifestContext(root, manifestJsonAbs);
  const config = manifestContext.snapshot && isPlainObject(manifestContext.snapshot.config)
    ? manifestContext.snapshot.config
    : {};
  const projectName = sanitizeName(
    manifestContext.snapshot.projectName || (config.project && config.project.name) || path.basename(root)
  );
  const selectedTimestamp = currentTimestamp(timestamp);
  const variables = { projectName, timestamp: selectedTimestamp };
  const vitisConfig = isPlainObject(config.vitis) ? config.vitis : {};
  const xsaConfig = isPlainObject(vitisConfig.xsa) ? vitisConfig.xsa : {};
  const platformConfig = isPlainObject(vitisConfig.platform) ? vitisConfig.platform : {};
  const runConfig = isPlainObject(vitisConfig.run) ? vitisConfig.run : {};
  const vivadoConfig = isPlainObject(config.vivado) ? config.vivado : {};
  const platformDomain = nonEmptyString(platformConfig.domain_name, "standalone_domain");
  const workspace = resolveProjectPath(root, vitisConfig.workspace || defaultWorkspace(), variables);
  const xsaRawPath = xsaConfig.path || defaultXsaPath(projectName);
  const configuredXsaPath = resolveProjectPath(root, xsaRawPath, variables);
  const xsaExportTcl = xsaConfig.export_tcl
    ? resolveProjectPath(root, xsaConfig.export_tcl, variables)
    : "";
  const xsaGeneratedPath = xsaConfig.generated_path
    ? resolveProjectPath(root, xsaConfig.generated_path, variables)
    : "";
  const xsaRawBitPath = xsaConfig.bit_path || "";
  const xsaBitPath = xsaRawBitPath
    ? resolveProjectPath(root, xsaRawBitPath, variables)
    : "";
  const xsaBitGlobs = stringArray(xsaConfig.bit_globs, defaultBitGlobs(projectName))
    .map((row) => interpolateTemplate(row, variables));
  const xsaVivadoProject = xsaConfig.vivado_project
    ? resolveProjectPath(root, xsaConfig.vivado_project, variables)
    : "";
  const xsaImplRun = nonEmptyString(xsaConfig.impl_run, "impl_1");
  const platformRawName = platformConfig.name || defaultPlatformName(projectName);
  const platformBaseName = sanitizeName(interpolateTemplate(platformRawName, variables), "platform");
  const platformRawXpfm = platformConfig.xpfm || defaultPlatformXpfm(platformBaseName);
  const configuredPlatformXpfm = resolveProjectPath(root, platformRawXpfm, {
    ...variables,
    platformName: platformBaseName,
  });
  const configuredApplications = resolveApplications(root, vitisConfig, variables, platformDomain);
  const discoveredApplications = discoverWorkspaceApplications(root, workspace, platformDomain);
  const applications = mergeApplications(configuredApplications, discoveredApplications);

  return {
    root,
    manifestJsonAbs,
    manifestContext,
    config,
    projectName,
    timestamp: selectedTimestamp,
    variables,
    vitisConfig,
    xsaConfig,
    xsaRawPath,
    configuredXsaPath,
    xsaExportTcl,
    xsaGeneratedPath,
    xsaRawBitPath,
    xsaBitPath,
    xsaBitGlobs,
    xsaVivadoProject,
    xsaImplRun,
    platformConfig,
    platformRawName,
    platformBaseName,
    platformRawXpfm,
    configuredPlatformXpfm,
    platformDomain,
    runConfig,
    vivadoConfig,
    workspace,
    configuredApplications,
    discoveredApplications,
    applications,
  };
}

function statInfo(filePath) {
  try {
    const stat = fs.statSync(filePath);
    return { exists: true, mtimeMs: stat.mtimeMs, isDirectory: stat.isDirectory() };
  } catch {
    return { exists: false, mtimeMs: 0, isDirectory: false };
  }
}

function walkFiles(root, extension) {
  const out = [];
  const start = path.resolve(root || "");
  if (!fs.existsSync(start)) return out;
  const wanted = String(extension || "").toLowerCase();
  const stack = [start];
  while (stack.length > 0) {
    const current = stack.pop();
    let rows = [];
    try {
      rows = fs.readdirSync(current, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const row of rows) {
      const next = path.join(current, row.name);
      if (row.isDirectory()) {
        stack.push(next);
      } else if (!wanted || path.extname(row.name).toLowerCase() === wanted) {
        out.push(next);
      }
    }
  }
  return out;
}

function sortCandidates(candidates) {
  const sorted = candidates
    .sort((left, right) => {
      if (left.exists !== right.exists) return left.exists ? -1 : 1;
      if ((right.mtimeMs || 0) !== (left.mtimeMs || 0)) return (right.mtimeMs || 0) - (left.mtimeMs || 0);
      return String(left.path || left.xpfm || "").localeCompare(String(right.path || right.xpfm || ""));
    })
    .map((candidate, index) => ({ ...candidate, index: index + 1 }));
  return sorted;
}

function sortBitCandidates(candidates) {
  const sorted = candidates
    .sort((left, right) => {
      if (left.exists !== right.exists) return left.exists ? -1 : 1;
      const leftRunnable = Boolean(left.hasRunPath && left.vivadoProject);
      const rightRunnable = Boolean(right.hasRunPath && right.vivadoProject);
      if (leftRunnable !== rightRunnable) return leftRunnable ? -1 : 1;
      if ((right.mtimeMs || 0) !== (left.mtimeMs || 0)) return (right.mtimeMs || 0) - (left.mtimeMs || 0);
      return String(left.path || "").localeCompare(String(right.path || ""));
    })
    .map((candidate, index) => ({ ...candidate, index: index + 1 }));
  return sorted;
}

function addXsaCandidate(rows, projectRoot, xsaPath) {
  const abs = path.resolve(xsaPath || "");
  const key = abs.toLowerCase();
  if (rows.has(key)) return;
  const stat = statInfo(abs);
  rows.set(key, {
    kind: "xsa",
    name: path.basename(abs, path.extname(abs)),
    fileName: path.basename(abs),
    path: normalizeSlashes(abs),
    relativePath: projectRelative(projectRoot, abs),
    exists: stat.exists && !stat.isDirectory,
    mtimeMs: stat.mtimeMs,
  });
}

function discoverXsaCandidates(projectRoot, configuredXsaPath) {
  const rows = new Map();
  for (const filePath of walkFiles(path.join(projectRoot, "output", "vitis", "xsa"), ".xsa")) {
    addXsaCandidate(rows, projectRoot, filePath);
  }
  if (configuredXsaPath) {
    addXsaCandidate(rows, projectRoot, configuredXsaPath);
  }
  return sortCandidates(Array.from(rows.values()));
}

function inferImplRunFromBit(bitPath) {
  const parts = path.normalize(bitPath || "").split(path.sep);
  for (let index = 0; index < parts.length - 1; index += 1) {
    if (String(parts[index]).toLowerCase().endsWith(".runs")) {
      return parts[index + 1] || "";
    }
  }
  return "";
}

function inferVivadoProjectFromBit(bitPath) {
  let current = path.dirname(path.resolve(bitPath || ""));
  const root = path.parse(current).root;
  for (let depth = 0; depth < 10 && current && current !== root; depth += 1) {
    try {
      const xprs = fs.readdirSync(current)
        .filter((name) => path.extname(name).toLowerCase() === ".xpr")
        .sort((left, right) => left.localeCompare(right));
      if (xprs.length > 0) {
        return path.join(current, xprs[0]);
      }
    } catch {
      // Keep walking upward; generated Vivado trees may contain transient folders.
    }
    current = path.dirname(current);
  }
  return "";
}

function addBitCandidate(rows, projectRoot, payload) {
  const abs = path.resolve(payload.path || "");
  const key = abs.toLowerCase();
  if (rows.has(key)) return;
  const stat = statInfo(abs);
  const inferredRun = inferImplRunFromBit(abs);
  const inferredProject = inferVivadoProjectFromBit(abs);
  const hasRunPath = Boolean(inferredRun && path.normalize(abs).split(path.sep).some((part) => String(part).toLowerCase().endsWith(".runs")));
  rows.set(key, {
    kind: "bit",
    name: path.basename(abs, path.extname(abs)),
    fileName: path.basename(abs),
    path: normalizeSlashes(abs),
    relativePath: projectRelative(projectRoot, abs),
    exists: stat.exists && !stat.isDirectory,
    mtimeMs: stat.mtimeMs,
    vivadoProject: normalizeSlashes(inferredProject || payload.vivadoProject),
    implRun: nonEmptyString(payload.implRun, inferredRun || "impl_1"),
    hasRunPath,
  });
}

function discoverBitCandidates(projectRoot, configuredBitPath, bitGlobs, configuredVivadoProject, configuredImplRun) {
  const rows = new Map();
  const globs = stringArray(bitGlobs, defaultBitGlobs(path.basename(projectRoot)));
  if (globs.length > 0) {
    const matches = fg.sync(globs, {
      cwd: projectRoot,
      onlyFiles: true,
      dot: false,
      unique: true,
      ignore: [
        "output/vitis/**",
        "output/vws/**",
        "output/Platform/**",
        "output/**/_ide/bitstream/**",
      ],
    });
    for (const relPath of matches) {
      addBitCandidate(rows, projectRoot, {
        path: path.resolve(projectRoot, relPath),
        vivadoProject: configuredVivadoProject,
      });
    }
  }
  if (configuredBitPath) {
    addBitCandidate(rows, projectRoot, {
      path: configuredBitPath,
      vivadoProject: configuredVivadoProject,
      implRun: configuredImplRun,
    });
  }
  return sortBitCandidates(Array.from(rows.values()));
}

function inferComponentDirFromXpfm(xpfmPath) {
  const normalized = path.normalize(xpfmPath);
  const parts = normalized.split(path.sep);
  const exportIndex = parts.lastIndexOf("export");
  if (exportIndex > 0) {
    return parts.slice(0, exportIndex).join(path.sep);
  }
  return path.dirname(xpfmPath);
}

function isInternalWorkspaceDir(name) {
  const raw = String(name || "");
  return raw.startsWith(".") || raw.startsWith("_");
}

function readWorkspaceComponentType(componentDir) {
  return componentTypeOf(readWorkspaceComponentJson(componentDir));
}

function addPlatformCandidate(rows, projectRoot, payload) {
  const name = sanitizeName(payload.name || path.basename(payload.xpfm || payload.componentDir || "", ".xpfm"), "platform");
  const componentDir = path.resolve(payload.componentDir || inferComponentDirFromXpfm(payload.xpfm || ""));
  const xpfm = path.resolve(payload.xpfm || path.join(componentDir, "export", name, `${name}.xpfm`));
  const key = xpfm.toLowerCase();
  const existing = rows.get(key);
  const xpfmStat = statInfo(xpfm);
  const componentStat = statInfo(componentDir);
  const candidate = {
    kind: "platform",
    name,
    fileName: path.basename(xpfm),
    xpfm: normalizeSlashes(xpfm),
    path: normalizeSlashes(xpfm),
    componentDir: normalizeSlashes(componentDir),
    relativePath: projectRelative(projectRoot, xpfm),
    exists: xpfmStat.exists || componentStat.exists,
    hasXpfm: xpfmStat.exists && !xpfmStat.isDirectory,
    hasComponentDir: componentStat.exists && componentStat.isDirectory,
    mtimeMs: xpfmStat.exists ? xpfmStat.mtimeMs : componentStat.mtimeMs,
  };
  if (!existing || (candidate.hasXpfm && !existing.hasXpfm) || candidate.mtimeMs > existing.mtimeMs) {
    rows.set(key, candidate);
  }
}

function isSelectablePlatformCandidate(candidate) {
  return Boolean(candidate && (candidate.hasXpfm || candidate.hasComponentDir));
}

function discoverPlatformCandidates(projectRoot, workspace, configuredPlatform) {
  const rows = new Map();
  const searchRoots = [
    workspace,
    path.join(projectRoot, "output", "vitis", "platform"),
  ];
  for (const root of searchRoots) {
    for (const filePath of walkFiles(root, ".xpfm")) {
      addPlatformCandidate(rows, projectRoot, {
        name: path.basename(filePath, path.extname(filePath)),
        xpfm: filePath,
        componentDir: inferComponentDirFromXpfm(filePath),
      });
    }
  }
  if (workspace && fs.existsSync(workspace)) {
    let entries = [];
    try {
      entries = fs.readdirSync(workspace, { withFileTypes: true });
    } catch {
      entries = [];
    }
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      if (isInternalWorkspaceDir(entry.name)) continue;
      const name = sanitizeName(entry.name, "platform");
      const componentDir = path.join(workspace, entry.name);
      const expectedXpfm = path.join(componentDir, "export", name, `${name}.xpfm`);
      const componentType = readWorkspaceComponentType(componentDir);
      if (componentType && componentType !== "PLATFORM") continue;
      if (!componentType && !fs.existsSync(expectedXpfm)) continue;
      addPlatformCandidate(rows, projectRoot, {
        name,
        componentDir,
        xpfm: expectedXpfm,
      });
    }
  }
  if (configuredPlatform && (configuredPlatform.xpfm || configuredPlatform.name)) {
    addPlatformCandidate(rows, projectRoot, configuredPlatform);
  }
  return sortCandidates(Array.from(rows.values()).filter(isSelectablePlatformCandidate));
}

function resolveSelectorPath(projectRoot, selector) {
  const raw = String(selector || "").trim();
  if (!raw) return "";
  return path.isAbsolute(raw) ? path.resolve(raw) : path.resolve(projectRoot, raw);
}

function findCandidate(candidates, selector, projectRoot, fields) {
  const requested = String(selector || "").trim();
  if (!requested || requested.toLowerCase() === "latest") return null;
  if (/^[0-9]+$/.test(requested)) {
    return candidates.find((candidate) => candidate.index === Number(requested)) || null;
  }
  const requestedLower = requested.toLowerCase();
  const requestedPath = normalizeSlashes(resolveSelectorPath(projectRoot, requested)).toLowerCase();
  return candidates.find((candidate) => {
    const names = [
      candidate.name,
      candidate.fileName,
      path.basename(candidate.path || candidate.xpfm || ""),
      path.basename(candidate.path || candidate.xpfm || "", path.extname(candidate.path || candidate.xpfm || "")),
    ].map((value) => String(value || "").toLowerCase());
    if (names.includes(requestedLower)) return true;
    return fields.some((field) => normalizeSlashes(candidate[field] || "").toLowerCase() === requestedPath);
  }) || null;
}

function selectXsaCandidate(candidates, selector, projectRoot) {
  const requested = String(selector || "").trim();
  if (!requested || requested.toLowerCase() === "latest") {
    return candidates.find((candidate) => candidate.exists) || candidates[0] || null;
  }
  const match = findCandidate(candidates, requested, projectRoot, ["path"]);
  if (match) return match;
  if (requested.includes("/") || requested.includes("\\") || requested.toLowerCase().endsWith(".xsa")) {
    const abs = resolveSelectorPath(projectRoot, requested);
    const rows = new Map();
    addXsaCandidate(rows, projectRoot, abs);
    return Array.from(rows.values())[0] || null;
  }
  throw new Error(`No XSA matching '${requested}' was found.`);
}

function selectBitCandidate(candidates, selector, projectRoot) {
  const requested = String(selector || "").trim();
  if (!requested || requested.toLowerCase() === "latest") {
    return candidates.find((candidate) => candidate.exists) || candidates[0] || null;
  }
  const match = findCandidate(candidates, requested, projectRoot, ["path"]);
  if (match) return match;
  if (requested.includes("/") || requested.includes("\\") || requested.toLowerCase().endsWith(".bit")) {
    const abs = resolveSelectorPath(projectRoot, requested);
    const rows = new Map();
    addBitCandidate(rows, projectRoot, { path: abs });
    return Array.from(rows.values())[0] || null;
  }
  throw new Error(`No bitstream matching '${requested}' was found.`);
}

function selectPlatformCandidate(candidates, selector, projectRoot, { requireXpfm = false } = {}) {
  const requested = String(selector || "").trim();
  let candidate = null;
  if (!requested || requested.toLowerCase() === "latest") {
    candidate = requireXpfm
      ? candidates.find((row) => row.hasXpfm)
      : candidates.find((row) => row.exists);
    candidate = candidate || candidates[0] || null;
  } else {
    candidate = findCandidate(candidates, requested, projectRoot, ["xpfm", "componentDir"]);
    if (!candidate && (requested.includes("/") || requested.includes("\\") || requested.toLowerCase().endsWith(".xpfm"))) {
      const abs = resolveSelectorPath(projectRoot, requested);
      const rows = new Map();
      addPlatformCandidate(rows, projectRoot, {
        name: path.basename(abs, path.extname(abs)),
        xpfm: abs,
        componentDir: inferComponentDirFromXpfm(abs),
      });
      candidate = Array.from(rows.values())[0] || null;
    }
  }
  if (!candidate) {
    const suffix = requested
      ? ` matching '${requested}'`
      : "";
    throw new Error(`No Vitis platform candidate${suffix} was found. Create a Vitis platform first or choose an exported .xpfm.`);
  }
  if (!isSelectablePlatformCandidate(candidate)) {
    throw new Error(`Selected platform is not available yet: ${candidate.xpfm}. Create a Vitis platform first or choose an exported .xpfm.`);
  }
  if (requireXpfm && !candidate.hasXpfm) {
    throw new Error(`Selected platform does not have an exported XPFM yet: ${candidate.xpfm}`);
  }
  return candidate;
}

function selectApplications(applications, requestedApps, step, {
  allApps = false,
  runRequested = false,
  createMissingApplication = null,
} = {}) {
  if (!APP_STEPS.has(step) && step !== "full_flow") return [];
  const requested = splitSelections(requestedApps);
  if (applications.length === 0 && !(step === "create_application" && requested.length > 0 && createMissingApplication)) {
    throw new Error("vitis.applications must contain at least one application for this Vitis step.");
  }
  if (allApps) {
    if (step === "run_application" || (step === "full_flow" && runRequested)) {
      throw new Error("Hardware run supports one Vitis application at a time.");
    }
    return [...applications];
  }

  if (requested.length === 0) {
    if (applications.length > 1) {
      throw new Error("Multiple Vitis applications are configured. Pass --app <name>, --apps <name1,name2>, or --all-apps.");
    }
    return [applications[0]];
  }

  const selected = [];
  for (const name of requested) {
    let match = applications.find((app) => app.name.toLowerCase() === name.toLowerCase());
    if (!match && step === "create_application" && createMissingApplication) {
      match = createMissingApplication(name, selected.length);
    }
    if (!match) {
      throw new Error(`No Vitis application named '${name}' exists in vitis.applications.`);
    }
    if (!selected.some((app) => app.name.toLowerCase() === match.name.toLowerCase())) {
      selected.push(match);
    }
  }
  if (selected.length > 1 && !MULTI_APP_STEPS.has(step)) {
    throw new Error(`Vitis step '${step}' supports one application at a time.`);
  }
  if (selected.length > 1 && step === "full_flow" && runRequested) {
    throw new Error("Full flow with --run supports one Vitis application at a time.");
  }
  return selected;
}

function resolveCreatePlatformXpfm(context, platformName) {
  const shouldHonorConfiguredXpfm = templateHasToken(context.platformRawXpfm, [
    "${timestamp}",
    "${platform.name}",
    "${platformName}",
  ]);
  const rawXpfm = shouldHonorConfiguredXpfm
    ? context.platformRawXpfm
    : path.join(context.workspace, platformName, "export", platformName, `${platformName}.xpfm`);
  return path.isAbsolute(rawXpfm) ? path.resolve(rawXpfm) : resolveProjectPath(context.root, rawXpfm, {
    ...context.variables,
    platformName,
  });
}

function listVitisChoices({
  projectRoot,
  manifestJsonPath,
  kind,
} = {}) {
  const context = loadVitisContext(projectRoot, manifestJsonPath);
  const xsaCandidates = discoverXsaCandidates(context.root, context.configuredXsaPath);
  const bitCandidates = discoverBitCandidates(
    context.root,
    context.xsaBitPath,
    context.xsaBitGlobs,
    context.xsaVivadoProject,
    context.xsaImplRun
  );
  const platformCandidates = discoverPlatformCandidates(context.root, context.workspace, {
    name: context.platformBaseName,
    xpfm: context.configuredPlatformXpfm,
    componentDir: path.join(context.workspace, context.platformBaseName),
  });
  const normalizedKind = String(kind || "").trim().toLowerCase();
  if (normalizedKind === "xsas" || normalizedKind === "xsa") {
    return { kind: "xsas", choices: xsaCandidates };
  }
  if (normalizedKind === "bits" || normalizedKind === "bitstreams" || normalizedKind === "bit") {
    return { kind: "bits", choices: bitCandidates };
  }
  if (normalizedKind === "platforms" || normalizedKind === "platform") {
    return { kind: "platforms", choices: platformCandidates };
  }
  if (normalizedKind === "applications" || normalizedKind === "apps" || normalizedKind === "app") {
    return {
      kind: "applications",
      choices: context.applications.map((application, index) => ({
        index: index + 1,
        kind: "application",
        name: application.name,
        target: application.target,
        template: application.template,
      })),
    };
  }
  throw new Error("--list must be one of: bits, xsas, platforms, applications");
}

function prepareVitisPlan({
  projectRoot,
  manifestJsonPath,
  step,
  appName = "",
  appNames = [],
  allApps = false,
  target = "",
  runRequested = false,
  xsaSelector = "",
  bitSelector = "",
  platformSelector = "",
  timestamp = "",
} = {}) {
  const selectedStep = String(step || "").trim();
  if (!VALID_STEPS.has(selectedStep)) {
    throw new Error(`Unknown Vitis step: ${selectedStep || "(blank)"}`);
  }

  const context = loadVitisContext(projectRoot, manifestJsonPath, { timestamp });
  const xsaCandidates = discoverXsaCandidates(context.root, context.configuredXsaPath);
  const bitCandidates = discoverBitCandidates(
    context.root,
    context.xsaBitPath,
    context.xsaBitGlobs,
    context.xsaVivadoProject,
    context.xsaImplRun
  );
  let selectedXsa = null;
  let selectedBit = null;
  let xsaPath = context.configuredXsaPath;
  if (selectedStep === "export_xsa") {
    xsaPath = timestampedFilePath(context.configuredXsaPath, context.timestamp, context.xsaRawPath);
    selectedBit = selectBitCandidate(bitCandidates, bitSelector, context.root);
  } else if (selectedStep === "create_platform") {
    selectedXsa = selectXsaCandidate(xsaCandidates, xsaSelector, context.root);
    if (selectedXsa) xsaPath = selectedXsa.path;
  }

  let platformName = context.platformBaseName;
  let xpfmPath = context.configuredPlatformXpfm;
  if (selectedStep === "create_platform") {
    platformName = timestampedName(context.platformBaseName, context.timestamp, context.platformRawName);
    xpfmPath = resolveCreatePlatformXpfm(context, platformName);
  }

  const platformCandidates = discoverPlatformCandidates(context.root, context.workspace, {
    name: context.platformBaseName,
    xpfm: context.configuredPlatformXpfm,
    componentDir: path.join(context.workspace, context.platformBaseName),
  });
  let selectedPlatform = null;
  if (PLATFORM_SELECT_STEPS.has(selectedStep)) {
    selectedPlatform = selectPlatformCandidate(platformCandidates, platformSelector, context.root, {
      requireXpfm: false,
    });
    platformName = selectedPlatform.name;
    xpfmPath = selectedPlatform.xpfm;
  }

  const requestedAppNames = [...splitSelections(appName), ...splitSelections(appNames)];
  const selectedApplications = selectApplications(context.applications, requestedAppNames, selectedStep, {
    allApps,
    runRequested,
    createMissingApplication: (name, index) => resolveApplication(
      context.root,
      { name },
      index,
      context.variables,
      context.platformDomain
    ),
  });
  if (target) {
    selectedApplications.forEach((application) => {
      application.target = target;
    });
  }
  const selectedApplication = selectedApplications.length > 0 ? selectedApplications[0] : null;

  const outputRoot = path.join(context.root, "output", "vitis");
  const planDir = path.join(outputRoot, "plan");
  const resultDir = path.join(outputRoot, "results");
  const summaryDir = path.join(outputRoot, "summaries");
  const logDir = path.join(context.root, "log", "vitis");
  const stepFileBase = selectedStep;
  const planPaths = {
    planPath: path.join(planDir, `${stepFileBase}_plan.json`),
    commandPath: path.join(planDir, `${stepFileBase}_plan.cmd`),
    resultPath: path.join(resultDir, `${stepFileBase}_result.json`),
    summaryPath: path.join(summaryDir, defaultSummaryFile(selectedStep)),
  };
  const paths = {
    outputRoot: normalizeSlashes(outputRoot),
    planPath: normalizeSlashes(planPaths.planPath),
    commandPath: normalizeSlashes(planPaths.commandPath),
    resultPath: normalizeSlashes(planPaths.resultPath),
    summaryPath: normalizeSlashes(planPaths.summaryPath),
    logPath: normalizeSlashes(path.join(logDir, `${stepFileBase}.log`)),
    journalPath: normalizeSlashes(path.join(logDir, `${stepFileBase}.jou`)),
  };

  const warnings = [];
  for (const application of selectedApplications) {
    if (application.sourceGlobs.length > 0 && application.sourceMatches.length === 0) {
      warnings.push(`application_source_globs_empty:${application.name}`);
    }
  }
  if (selectedStep === "create_platform" && selectedXsa && !selectedXsa.exists) {
    warnings.push(`selected_xsa_missing:${selectedXsa.path}`);
  }
  if (selectedStep === "export_xsa") {
    if (!selectedBit) {
      warnings.push("bitstream_missing:no_bit_candidates");
    } else {
      if (!selectedBit.exists) warnings.push(`selected_bit_missing:${selectedBit.path}`);
      if (!selectedBit.vivadoProject) warnings.push(`selected_bit_no_vivado_project:${selectedBit.path}`);
    }
  }
  if ((selectedStep === "create_application" || selectedStep === "run_application") && selectedPlatform && !selectedPlatform.hasXpfm) {
    warnings.push(`selected_platform_xpfm_missing:${selectedPlatform.xpfm}`);
  }

  const plan = createVitisPlan({
    step: selectedStep,
    projectRoot: context.root,
    manifestJsonPath: context.manifestJsonAbs,
    projectName: context.projectName,
    timestamp: context.timestamp,
    workspace: context.workspace,
    xsa: {
      path: xsaPath,
      exportTcl: context.xsaExportTcl,
      generatedPath: context.xsaGeneratedPath,
      bitPath: selectedBit ? selectedBit.path : context.xsaBitPath,
      vivadoProject: selectedBit && selectedBit.vivadoProject ? selectedBit.vivadoProject : context.xsaVivadoProject,
      implRun: selectedBit && selectedBit.implRun ? selectedBit.implRun : context.xsaImplRun,
      bitSelected: selectedBit,
      bitCandidates,
      includeBitstream: toBoolean(context.xsaConfig.include_bitstream, true),
      fixed: toBoolean(context.xsaConfig.fixed, true),
      validate: toBoolean(context.xsaConfig.validate, true),
      selected: selectedXsa,
      candidates: xsaCandidates,
    },
    platform: {
      name: platformName,
      xpfm: xpfmPath,
      os: nonEmptyString(context.platformConfig.os, "standalone"),
      cpu: nonEmptyString(context.platformConfig.cpu, "auto"),
      domainName: context.platformDomain,
      selected: selectedPlatform,
      candidates: platformCandidates,
    },
    applications: context.applications,
    application: selectedApplication,
    selectedApplications,
    run: {
      mode: nonEmptyString(context.runConfig.mode, "hardware"),
      hwServer: nonEmptyString(context.runConfig.hw_server, ""),
      deviceIndex: Object.prototype.hasOwnProperty.call(context.runConfig, "device_index") ? context.runConfig.device_index : null,
      auto: toBoolean(context.runConfig.auto, false) || Boolean(runRequested),
    },
    vivado: {
      topModule: nonEmptyString(context.vivadoConfig.top_module, context.manifestContext.snapshot.top || "TOP"),
      partNumber: nonEmptyString(context.vivadoConfig.part, "xczu3eg-sbva484-1-i"),
      projectName: nonEmptyString(context.vivadoConfig.project_name, `${context.projectName}_vivado`),
      srcListPath: normalizeSlashes(path.join(context.root, "output", "manifest", "manifest_src_files.lst")),
      xdcListPath: normalizeSlashes(path.join(context.root, "output", "manifest", "manifest_xdc_files.lst")),
      incListPath: normalizeSlashes(path.join(context.root, "output", "manifest", "manifest_inc_dirs.lst")),
    },
    paths,
    warnings,
  });

  ensureDir(planDir);
  ensureDir(resultDir);
  ensureDir(summaryDir);
  ensureDir(logDir);
  const planPath = writeJsonFile(planPaths.planPath, plan);
  fs.writeFileSync(planPaths.commandPath, buildPlanCommand(plan, {
    planPath,
    resultPath: normalizeSlashes(planPaths.resultPath),
    summaryPath: normalizeSlashes(planPaths.summaryPath),
  }), "utf8");

  return {
    plan,
    planPath,
    commandPath: normalizeSlashes(planPaths.commandPath),
    resultPath: normalizeSlashes(planPaths.resultPath),
    summaryPath: normalizeSlashes(planPaths.summaryPath),
    relative: {
      xsaPath: projectRelative(context.root, xsaPath),
      xpfmPath: projectRelative(context.root, xpfmPath),
    },
  };
}

module.exports = {
  prepareVitisPlan,
  listVitisChoices,
  VALID_STEPS,
};
