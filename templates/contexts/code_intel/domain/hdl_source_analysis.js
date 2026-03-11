function stripCommentsPreserveLines(text) {
  const noBlock = text.replace(/\/\*[\s\S]*?\*\//g, (match) => match.replace(/[^\n]/g, " "));
  return noBlock.replace(/\/\/.*$/gm, "");
}

function stripPreprocessorDirectivesPreserveLines(text) {
  return text.replace(/^\s*`[^\r\n]*/gm, (match) => match.replace(/[^\r\n]/g, " "));
}

function parseDeclarations(cleanText) {
  const declarations = [];
  const patterns = [
    { type: "module", re: /\bmodule\s+(?:automatic\s+|static\s+)?([A-Za-z_][A-Za-z0-9_$]*)\b/g },
    { type: "interface", re: /\binterface\s+([A-Za-z_][A-Za-z0-9_$]*)\b/g },
    { type: "package", re: /\bpackage\s+([A-Za-z_][A-Za-z0-9_$]*)\b/g },
    { type: "program", re: /\bprogram\s+(?:automatic\s+|static\s+)?([A-Za-z_][A-Za-z0-9_$]*)\b/g },
    { type: "class", re: /\bclass\s+(?:automatic\s+|static\s+)?([A-Za-z_][A-Za-z0-9_$]*)\b/g },
    { type: "checker", re: /\bchecker\s+([A-Za-z_][A-Za-z0-9_$]*)\b/g },
  ];

  for (const { type, re } of patterns) {
    let match;
    while ((match = re.exec(cleanText)) !== null) {
      declarations.push({
        type,
        name: match[1],
        offset: match.index,
      });
    }
  }

  declarations.sort(
    (a, b) => (a.offset - b.offset) || a.type.localeCompare(b.type) || a.name.localeCompare(b.name)
  );
  return declarations;
}

function parseIncludes(rawText) {
  const includes = [];
  const re = /`include\s+"([^"]+)"/g;
  let match;
  while ((match = re.exec(rawText)) !== null) {
    includes.push(match[1]);
  }
  return includes;
}

function detectSvFeatures(cleanText) {
  return {
    always_ff: /\balways_ff\b/.test(cleanText),
    always_comb: /\balways_comb\b/.test(cleanText),
    always_latch: /\balways_latch\b/.test(cleanText),
    typedef_enum: /\btypedef\s+enum\b/.test(cleanText),
    logic: /\blogic\b/.test(cleanText),
    modport: /\bmodport\b/.test(cleanText),
    import_pkg: /\bimport\s+[A-Za-z_][A-Za-z0-9_$]*\s*::/.test(cleanText),
  };
}

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function parseInstances(cleanText, moduleNames) {
  const instances = [];
  for (const modName of moduleNames) {
    const escapedModName = escapeRegExp(modName);
    const re = new RegExp(
      `\\b${escapedModName}\\b\\s*(?:#\\s*\\([\\s\\S]*?\\)\\s*)?([A-Za-z_][A-Za-z0-9_$]*)\\s*\\(`,
      "g"
    );
    let match;
    while ((match = re.exec(cleanText)) !== null) {
      instances.push({ moduleName: modName, instName: match[1] || "" });
    }
  }
  return instances;
}

function parseModuleBlocks(cleanText) {
  const blocks = [];
  const re = /\bmodule\s+(?:automatic\s+|static\s+)?([A-Za-z_][A-Za-z0-9_$]*)\b[\s\S]*?\bendmodule\b/g;
  let match;
  while ((match = re.exec(cleanText)) !== null) {
    blocks.push({
      moduleName: match[1],
      text: match[0],
      offset: match.index,
    });
  }
  return blocks;
}

function inferProjectLanguage(fileInfos) {
  const hasV = fileInfos.some((row) => row.ext === ".v");
  const hasSv = fileInfos.some((row) => row.ext === ".sv" || row.ext === ".svh");
  if (hasV && hasSv) return "mixed";
  if (hasSv) return "systemverilog";
  return "verilog";
}

function containsInterfaceInstantiation(text, interfaceNames) {
  for (const name of interfaceNames) {
    const escaped = escapeRegExp(name);
    const re = new RegExp(`\\b${escaped}\\b\\s+[A-Za-z_][A-Za-z0-9_$]*\\s*\\(`);
    if (re.test(text)) return true;
  }
  return false;
}

module.exports = {
  containsInterfaceInstantiation,
  detectSvFeatures,
  inferProjectLanguage,
  parseDeclarations,
  parseIncludes,
  parseInstances,
  parseModuleBlocks,
  stripCommentsPreserveLines,
  stripPreprocessorDirectivesPreserveLines,
};
