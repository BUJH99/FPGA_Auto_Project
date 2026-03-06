const path = require("path");
const {
  buildIndex,
  parseArgs,
  writeIndex,
  printList,
} = require("../../application/hdl_index_builder");

function normalizeSlashes(value) {
  return String(value || "").replace(/\\/g, "/");
}

function main() {
  try {
    const opts = parseArgs(process.argv.slice(2));
    const index = buildIndex(opts.projectRoot, opts);
    const outPath = path.resolve(opts.projectRoot, opts.out || "output/cache/hdl_index.json");

    if (opts.write || opts.out) {
      writeIndex(index, outPath);
      console.error(`[INFO] HDL index written: ${normalizeSlashes(outPath)}`);
      console.error(
        `[INFO] Files=${index.summary.totalFiles}, modules=${index.summary.modules}, warnings=${index.summary.warnings}`
      );
    }

    if (opts.list) {
      printList(index, opts.list);
      return;
    }

    process.stdout.write(JSON.stringify(index, null, opts.pretty ? 2 : 0));
  } catch (err) {
    console.error(`[ERROR] ${err.message}`);
    process.exit(1);
  }
}

if (require.main === module) {
  main();
}

module.exports = {
  buildIndex,
};
