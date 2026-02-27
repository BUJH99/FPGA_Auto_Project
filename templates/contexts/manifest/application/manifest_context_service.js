const fs = require("fs");
const path = require("path");
const {
  EXIT_OK,
  EXIT_INPUT,
} = require("../domain/manifest_constants");
const { ensureDir } = require("../domain/manifest_utils");
const { ProjectCatalogService } = require("./project_catalog_service");

const catalogService = new ProjectCatalogService();

function resolveManifestContext(projectRootInput) {
  return catalogService.resolveFromProjectRoot(projectRootInput).result;
}

function resolveProjectContext(projectRootInput) {
  return catalogService.resolveFromProjectRoot(projectRootInput);
}

function resolveProjectContextFromManifestJson(resultJsonPath) {
  return catalogService.resolveFromManifestJson(resultJsonPath);
}

function deriveExitCode(result) {
  return (result.errors && result.errors.length > 0) ? EXIT_INPUT : EXIT_OK;
}

function writeJson(outPath, data) {
  const abs = path.resolve(outPath);
  ensureDir(path.dirname(abs));
  fs.writeFileSync(abs, JSON.stringify(data, null, 2), "utf8");
}

function writeManifestLists(outDir, result) {
  const outAbs = path.resolve(outDir);
  ensureDir(outAbs);

  const listDefs = [
    ["manifest_src_files.lst", result.resolved.src_files || []],
    ["manifest_tb_files.lst", result.resolved.tb_files || []],
    ["manifest_inc_dirs.lst", result.resolved.inc_dirs || []],
    ["manifest_xdc_files.lst", result.resolved.xdc_files || []],
  ];

  for (const [fileName, rows] of listDefs) {
    const filePath = path.join(outAbs, fileName);
    const body = rows.length > 0 ? `${rows.join("\n")}\n` : "";
    fs.writeFileSync(filePath, body, "utf8");
  }

  return {
    src_list: path.join(outAbs, "manifest_src_files.lst"),
    tb_list: path.join(outAbs, "manifest_tb_files.lst"),
    inc_list: path.join(outAbs, "manifest_inc_dirs.lst"),
    xdc_list: path.join(outAbs, "manifest_xdc_files.lst"),
  };
}

module.exports = {
  resolveManifestContext,
  resolveProjectContext,
  resolveProjectContextFromManifestJson,
  deriveExitCode,
  writeJson,
  writeManifestLists,
};
