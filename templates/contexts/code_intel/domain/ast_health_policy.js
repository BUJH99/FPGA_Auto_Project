function detectParserProvider() {
  try {
    const Parser = require("tree-sitter");
    const Verilog = require("tree-sitter-verilog");
    return {
      name: "tree-sitter-verilog",
      parse(text) {
        const parser = new Parser();
        parser.setLanguage(Verilog);
        return parser.parse(text);
      },
    };
  } catch {
    return null;
  }
}

function applyAstHealthPolicy(fileRecords, interfaceNames, astInputByPath, containsInterfaceInstantiation) {
  for (const record of fileRecords || []) {
    if (!record.warnings || record.warnings.length === 0) continue;
    const hasAstSyntaxError = record.warnings.some((warning) => warning.type === "ast_syntax_error");
    if (!hasAstSyntaxError) continue;
    const astInput = astInputByPath.get(record.path) || "";
    if (!astInput) continue;
    if (!containsInterfaceInstantiation(astInput, interfaceNames)) continue;
    record.warnings = record.warnings.filter((warning) => warning.type !== "ast_syntax_error");
    record.warnings.push({
      type: "ast_syntax_degraded",
      message: "AST parser limitation around interface instantiation; downgraded from syntax error",
    });
  }
}

module.exports = {
  detectParserProvider,
  applyAstHealthPolicy,
};
