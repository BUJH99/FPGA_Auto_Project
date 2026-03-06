const path = require("path");
const { normalizeSlashes } = require("./legacy_project_candidate");

function classifyHdlFiles(allFiles) {
  const hdlFiles = allFiles.filter((rel) => /\.(v|sv)$/i.test(rel));
  const tbFiles = [];
  const srcFiles = [];

  for (const relPath of hdlFiles) {
    const normalized = normalizeSlashes(relPath);
    const base = path.basename(normalized);
    const isTbPath = /(^|\/)(tb|testbench|tests|verification|verif)(\/|$)/i.test(normalized);
    const isTbName = /^tb_/i.test(base);
    if (isTbPath || isTbName) {
      tbFiles.push(normalized);
    } else {
      srcFiles.push(normalized);
    }
  }

  return {
    srcFiles,
    tbFiles,
  };
}

function buildGlobsForExt(files, extList) {
  const extSet = new Set(extList.map((ext) => ext.toLowerCase()));
  const buckets = new Map();

  for (const relPath of files) {
    const ext = path.extname(relPath).toLowerCase();
    if (!extSet.has(ext)) continue;
    const parts = normalizeSlashes(relPath).split("/");
    const anchor = parts.length > 1 ? parts[0] : ".";
    if (!buckets.has(ext)) buckets.set(ext, new Set());
    buckets.get(ext).add(anchor);
  }

  const globs = [];
  const exts = Array.from(buckets.keys()).sort((a, b) => a.localeCompare(b));
  for (const ext of exts) {
    const anchors = Array.from(buckets.get(ext)).sort((a, b) => a.localeCompare(b));
    for (const anchor of anchors) {
      globs.push(anchor === "." ? `**/*${ext}` : `${anchor}/**/*${ext}`);
    }
  }

  return globs;
}

function inferTopName(srcFiles) {
  const preferred = ["TOP", "Top", "top"];
  for (const name of preferred) {
    if (srcFiles.some((rel) => path.basename(rel, path.extname(rel)) === name)) {
      return name;
    }
  }
  if (!srcFiles.length) {
    return "Top";
  }
  return path.basename(srcFiles[0], path.extname(srcFiles[0]));
}

function inferManifestConfig(projectName, allFiles) {
  const normalizedFiles = Array.isArray(allFiles)
    ? allFiles.map((filePath) => normalizeSlashes(filePath)).sort((a, b) => a.localeCompare(b))
    : [];
  const { srcFiles, tbFiles } = classifyHdlFiles(normalizedFiles);
  const incFiles = normalizedFiles.filter((rel) => /\.(vh|svh)$/i.test(rel));
  const xdcFiles = normalizedFiles.filter((rel) => /\.xdc$/i.test(rel));

  return {
    version: "0",
    project: {
      name: projectName,
    },
    hdl: {
      top: inferTopName(srcFiles),
      src_globs: buildGlobsForExt(srcFiles, [".v", ".sv"]).length > 0
        ? buildGlobsForExt(srcFiles, [".v", ".sv"])
        : ["src/**/*.v", "src/**/*.sv"],
      tb_globs: buildGlobsForExt(tbFiles, [".v", ".sv"]).length > 0
        ? buildGlobsForExt(tbFiles, [".v", ".sv"])
        : ["tb/**/*.v", "tb/**/*.sv"],
      inc_globs: buildGlobsForExt(incFiles, [".vh", ".svh"]),
      xdc_globs: buildGlobsForExt(xdcFiles, [".xdc"]),
      exclude_globs: [],
    },
  };
}

module.exports = {
  classifyHdlFiles,
  buildGlobsForExt,
  inferTopName,
  inferManifestConfig,
};
