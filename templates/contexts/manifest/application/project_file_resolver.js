const fs = require("fs");
const path = require("path");
const fg = require("fast-glob");
const { sortUnique, normalizeSlashes } = require("../domain/manifest_utils");
const { addError, addWarning } = require("../domain/manifest_result");
const { createResolvedFileSet } = require("../domain/resolved_file_set");

function toProjectRelative(projectRoot, absPath) {
  return normalizeSlashes(path.relative(projectRoot, absPath));
}

function expandFileGlobs(result, projectRoot, fieldName, patterns, excludeGlobs) {
  const files = new Set();
  for (const pattern of patterns) {
    let matches = [];
    try {
      matches = fg.sync(pattern, {
        cwd: projectRoot,
        dot: true,
        onlyFiles: true,
        followSymbolicLinks: true,
        ignore: excludeGlobs,
      });
    } catch (err) {
      addError(result, "glob_expand_failed", `Failed to expand glob ${fieldName}: ${err.message}`, pattern);
      continue;
    }

    if (matches.length === 0) {
      addWarning(result, "glob_no_match", `No files matched ${fieldName} pattern: ${pattern}`, pattern);
      continue;
    }

    for (const match of matches) {
      const abs = path.resolve(projectRoot, match);
      if (!fs.existsSync(abs)) {
        addWarning(result, "glob_no_match", `Matched path does not exist: ${match}`, pattern);
        continue;
      }

      let stat = null;
      try {
        stat = fs.statSync(abs);
      } catch (err) {
        addWarning(result, "glob_no_match", `Cannot stat matched path: ${match} (${err.message})`, pattern);
        continue;
      }

      if (!stat.isFile()) continue;
      files.add(toProjectRelative(projectRoot, abs));
    }
  }

  return sortUnique([...files]);
}

function expandIncGlobs(result, projectRoot, patterns, excludeGlobs) {
  const dirs = new Set();
  for (const pattern of patterns) {
    let matches = [];
    try {
      matches = fg.sync(pattern, {
        cwd: projectRoot,
        dot: true,
        onlyFiles: false,
        onlyDirectories: false,
        followSymbolicLinks: true,
        ignore: excludeGlobs,
      });
    } catch (err) {
      addError(result, "glob_expand_failed", `Failed to expand glob hdl.inc_globs: ${err.message}`, pattern);
      continue;
    }

    if (matches.length === 0) {
      addWarning(result, "glob_no_match", `No paths matched hdl.inc_globs pattern: ${pattern}`, pattern);
      continue;
    }

    for (const match of matches) {
      const abs = path.resolve(projectRoot, match);
      if (!fs.existsSync(abs)) continue;
      let stat = null;
      try {
        stat = fs.statSync(abs);
      } catch {
        continue;
      }

      const absDir = stat.isDirectory() ? abs : path.dirname(abs);
      dirs.add(toProjectRelative(projectRoot, absDir));
    }
  }

  return sortUnique([...dirs]);
}

function resolveProjectFileSet(result, projectRootAbs, manifestConfig) {
  const excludeGlobs = manifestConfig.hdl.exclude_globs || [];
  const srcGlobs = manifestConfig.hdl.src_globs || [];
  const tbGlobs = manifestConfig.hdl.tb_globs || [];
  const incGlobs = manifestConfig.hdl.inc_globs || [];
  const xdcGlobs = manifestConfig.hdl.xdc_globs || [];

  return createResolvedFileSet({
    src_files: expandFileGlobs(result, projectRootAbs, "hdl.src_globs", srcGlobs, excludeGlobs),
    tb_files: expandFileGlobs(result, projectRootAbs, "hdl.tb_globs", tbGlobs, excludeGlobs),
    inc_dirs: expandIncGlobs(result, projectRootAbs, incGlobs, excludeGlobs),
    xdc_files: expandFileGlobs(result, projectRootAbs, "hdl.xdc_globs", xdcGlobs, excludeGlobs),
  });
}

module.exports = {
  resolveProjectFileSet,
};
