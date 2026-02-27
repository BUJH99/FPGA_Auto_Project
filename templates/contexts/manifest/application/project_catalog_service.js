const { createResult, addError } = require("../domain/manifest_result");
const { resolveProjectRoot, assertProjectRoot } = require("../domain/project_root");
const { loadManifestDocument } = require("../domain/manifest_document");
const { resolveFileSet } = require("../domain/resolved_file_set");
const { ManifestSnapshot } = require("../domain/manifest_snapshot");
const { FileCatalog } = require("../domain/file_catalog");

class ProjectCatalogService {
  resolveFromProjectRoot(projectRootInput) {
    const projectRootAbs = resolveProjectRoot(projectRootInput);
    const result = createResult(projectRootAbs);

    const rootCheck = assertProjectRoot(projectRootAbs);
    if (!rootCheck.ok) {
      addError(result, rootCheck.code, rootCheck.message, rootCheck.refPath);
      return {
        ok: false,
        result,
        snapshot: null,
        catalog: FileCatalog.fromResolved(result.resolved),
      };
    }

    const config = loadManifestDocument(projectRootAbs, result);
    if (!config) {
      return {
        ok: false,
        result,
        snapshot: null,
        catalog: FileCatalog.fromResolved(result.resolved),
      };
    }

    result.resolved = resolveFileSet(result, projectRootAbs, config);

    let snapshot = null;
    try {
      snapshot = ManifestSnapshot.fromResult(result);
    } catch (err) {
      addError(result, "manifest_snapshot_error", err.message, "manifest_resolved.json");
    }

    const catalog = snapshot ? snapshot.catalog : FileCatalog.fromResolved(result.resolved);
    return {
      ok: result.errors.length === 0,
      result,
      snapshot,
      catalog,
    };
  }

  resolveFromManifestJson(resultJsonPath) {
    try {
      const snapshot = ManifestSnapshot.fromFile(resultJsonPath);
      return {
        ok: !snapshot.hasErrors(),
        result: snapshot.toResult(),
        snapshot,
        catalog: snapshot.catalog,
      };
    } catch (err) {
      const result = createResult(process.cwd());
      addError(result, "manifest_snapshot_error", err.message, resultJsonPath);
      return {
        ok: false,
        result,
        snapshot: null,
        catalog: FileCatalog.fromResolved(result.resolved),
      };
    }
  }
}

module.exports = {
  ProjectCatalogService,
};
