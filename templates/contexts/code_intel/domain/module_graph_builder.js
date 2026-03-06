function collectDuplicateDeclarations(allDecls) {
  const warnings = [];
  const declMap = new Map();

  for (const decl of allDecls || []) {
    const key = `${decl.type}:${decl.name}`.toLowerCase();
    if (declMap.has(key)) {
      warnings.push({
        type: "duplicate_declaration",
        declarationType: decl.type,
        name: decl.name,
        files: [declMap.get(key).file, decl.file],
      });
      continue;
    }
    declMap.set(key, decl);
  }

  return warnings;
}

function buildModuleGraph(fileRecords, moduleNames) {
  const graph = {};
  for (const moduleName of moduleNames || []) {
    graph[moduleName] = [];
  }

  for (const record of fileRecords || []) {
    for (const inst of record.instances || []) {
      const parents = inst.parentName
        ? [inst.parentName]
        : (record.declarations || []).filter((decl) => decl.type === "module").map((decl) => decl.name);
      for (const parent of parents) {
        if (!graph[parent]) graph[parent] = [];
        if (inst.moduleName !== parent) {
          graph[parent].push(inst.moduleName);
        }
      }
    }
  }

  Object.keys(graph).forEach((key) => {
    graph[key] = Array.from(new Set(graph[key])).sort((a, b) => a.localeCompare(b));
  });

  return graph;
}

module.exports = {
  collectDuplicateDeclarations,
  buildModuleGraph,
};
