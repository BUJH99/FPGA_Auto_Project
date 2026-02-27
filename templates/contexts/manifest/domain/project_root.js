const fs = require("fs");
const path = require("path");

function resolveProjectRoot(projectRootInput) {
  return path.resolve(projectRootInput || process.cwd());
}

function assertProjectRoot(projectRootAbs) {
  if (!fs.existsSync(projectRootAbs)) {
    return {
      ok: false,
      message: `Project directory not found: ${projectRootAbs}`,
      code: "project_not_found",
      refPath: projectRootAbs,
    };
  }
  let stat = null;
  try {
    stat = fs.statSync(projectRootAbs);
  } catch (err) {
    return {
      ok: false,
      message: `Cannot stat project directory: ${err.message}`,
      code: "project_not_found",
      refPath: projectRootAbs,
    };
  }

  if (!stat.isDirectory()) {
    return {
      ok: false,
      message: `Project path is not a directory: ${projectRootAbs}`,
      code: "project_not_found",
      refPath: projectRootAbs,
    };
  }

  return { ok: true };
}

module.exports = {
  resolveProjectRoot,
  assertProjectRoot,
};
