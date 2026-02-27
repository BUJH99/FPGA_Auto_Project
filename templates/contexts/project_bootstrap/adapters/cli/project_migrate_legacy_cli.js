const fs = require("fs");
const path = require("path");
const YAML = require("yaml");
const {
  resolveManifestContext,
  deriveExitCode,
} = require("../../../manifest/application/manifest_context_service");

const EXIT_OK = 0;
const EXIT_FAIL = 1;
const EXIT_INPUT = 2;

function normalizeSlashes(p) {
  return String(p || "").replace(/\\/g, "/");
}

function ensureDir(dirPath) {
  if (!fs.existsSync(dirPath)) fs.mkdirSync(dirPath, { recursive: true });
}

function parseArgs(argv) {
  const opts = {
    repoRoot: path.resolve(__dirname, "..", ".."),
    projectRoot: null,
    dryRun: false,
    inferGlobs: false,
  };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--repo") {
      i += 1;
      if (i >= argv.length) throw new Error("--repo requires a value");
      opts.repoRoot = path.resolve(argv[i]);
      continue;
    }
    if (arg.startsWith("--repo=")) {
      opts.repoRoot = path.resolve(arg.slice("--repo=".length));
      continue;
    }
    if (arg === "--project-root") {
      i += 1;
      if (i >= argv.length) throw new Error("--project-root requires a value");
      opts.projectRoot = path.resolve(argv[i]);
      continue;
    }
    if (arg.startsWith("--project-root=")) {
      opts.projectRoot = path.resolve(arg.slice("--project-root=".length));
      continue;
    }
    if (arg === "--dry-run") {
      opts.dryRun = true;
      continue;
    }
    if (arg === "--infer-globs") {
      opts.inferGlobs = true;
      continue;
    }
    throw new Error(`Unknown argument: ${arg}`);
  }

  if (!opts.projectRoot) {
    opts.projectRoot = path.join(opts.repoRoot, "Project");
  }

  return opts;
}

function discoverLegacyProjects(repoRoot) {
  const skip = new Set([
    "templates",
    ".git",
    ".agent",
    "tools",
    "Project",
    "docs",
    "tests",
    "node_modules",
  ]);

  const dirs = fs
    .readdirSync(repoRoot, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .sort((a, b) => a.localeCompare(b));

  const out = [];
  for (const name of dirs) {
    if (skip.has(name)) continue;
    const abs = path.join(repoRoot, name);
    if (!fs.existsSync(path.join(abs, "src"))) continue;
    out.push({ name, abs });
  }
  return out;
}

function walkFiles(rootDir) {
  const out = [];
  if (!fs.existsSync(rootDir)) return out;

  const stack = [rootDir];
  while (stack.length > 0) {
    const cur = stack.pop();
    const entries = fs.readdirSync(cur, { withFileTypes: true });
    entries.sort((a, b) => a.name.localeCompare(b.name));
    for (const entry of entries) {
      const abs = path.join(cur, entry.name);
      if (entry.isDirectory()) {
        stack.push(abs);
        continue;
      }
      if (!entry.isFile()) continue;
      out.push(normalizeSlashes(path.relative(rootDir, abs)));
    }
  }
  out.sort((a, b) => a.localeCompare(b));
  return out;
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
      if (anchor === ".") {
        globs.push(`**/*${ext}`);
      } else {
        globs.push(`${anchor}/**/*${ext}`);
      }
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
  if (srcFiles.length === 0) return "Top";
  return path.basename(srcFiles[0], path.extname(srcFiles[0]));
}

function inferManifestConfig(targetProject, projectName) {
  const allFiles = walkFiles(targetProject);
  const hdlFiles = allFiles.filter((rel) => /\.(v|sv)$/i.test(rel));
  const tbFiles = [];
  const srcFiles = [];
  for (const rel of hdlFiles) {
    const norm = normalizeSlashes(rel);
    const base = path.basename(norm);
    const isTbPath = /(^|\/)(tb|testbench|tests|verification|verif)(\/|$)/i.test(norm);
    const isTbName = /^tb_/i.test(base);
    if (isTbPath || isTbName) {
      tbFiles.push(norm);
    } else {
      srcFiles.push(norm);
    }
  }

  const incFiles = allFiles.filter((rel) => /\.(vh|svh)$/i.test(rel));
  const xdcFiles = allFiles.filter((rel) => /\.xdc$/i.test(rel));

  const srcGlobs = buildGlobsForExt(srcFiles, [".v", ".sv"]);
  const tbGlobs = buildGlobsForExt(tbFiles, [".v", ".sv"]);
  const incGlobs = buildGlobsForExt(incFiles, [".vh", ".svh"]);
  const xdcGlobs = buildGlobsForExt(xdcFiles, [".xdc"]);

  return {
    version: "0",
    project: {
      name: projectName,
    },
    hdl: {
      top: inferTopName(srcFiles),
      src_globs: srcGlobs.length > 0 ? srcGlobs : ["src/**/*.v", "src/**/*.sv"],
      tb_globs: tbGlobs.length > 0 ? tbGlobs : ["tb/**/*.v", "tb/**/*.sv"],
      inc_globs: incGlobs,
      xdc_globs: xdcGlobs,
      exclude_globs: [],
    },
  };
}

function writeManifestFromTemplate(targetProject, projectName, repoRoot, opts) {
  const useInferGlobs = Boolean(opts && opts.inferGlobs);
  const manifestPath = path.join(targetProject, "fpga_auto.yml");

  if (useInferGlobs) {
    const manifest = inferManifestConfig(targetProject, projectName);
    fs.writeFileSync(manifestPath, YAML.stringify(manifest), "utf8");
    return "manifest_created_inferred";
  }

  const tplPath = path.join(repoRoot, "templates", "manifest", "fpga_auto.template.yml");
  if (!fs.existsSync(tplPath)) {
    throw new Error(`Manifest template missing: ${tplPath}`);
  }

  const tpl = fs.readFileSync(tplPath, "utf8");
  const out = tpl.replace(/__PROJECT_NAME__/g, projectName);
  fs.writeFileSync(manifestPath, out, "utf8");
  return "manifest_created_from_template";
}

function tsNow() {
  const d = new Date();
  const yyyy = d.getFullYear();
  const mm = String(d.getMonth() + 1).padStart(2, "0");
  const dd = String(d.getDate()).padStart(2, "0");
  const hh = String(d.getHours()).padStart(2, "0");
  const mi = String(d.getMinutes()).padStart(2, "0");
  const ss = String(d.getSeconds()).padStart(2, "0");
  return `${yyyy}${mm}${dd}_${hh}${mi}${ss}`;
}

function main() {
  let opts = null;
  try {
    opts = parseArgs(process.argv.slice(2));
  } catch (err) {
    console.error(`[ERROR] ${err.message}`);
    process.exit(EXIT_INPUT);
    return;
  }

  if (!fs.existsSync(opts.repoRoot) || !fs.statSync(opts.repoRoot).isDirectory()) {
    console.error(`[ERROR] Repo root not found: ${opts.repoRoot}`);
    process.exit(EXIT_INPUT);
    return;
  }

  ensureDir(opts.projectRoot);

  const legacyProjects = discoverLegacyProjects(opts.repoRoot);
  const results = [];

  for (const project of legacyProjects) {
    const target = path.join(opts.projectRoot, project.name);
    const row = {
      name: project.name,
      source: normalizeSlashes(project.abs),
      target: normalizeSlashes(target),
      status: "pending",
      notes: [],
    };

    try {
      if (fs.existsSync(target)) {
        row.status = "failed";
        row.notes.push("target_already_exists");
        results.push(row);
        continue;
      }

      if (!opts.dryRun) {
        fs.cpSync(project.abs, target, { recursive: true, errorOnExist: true, force: false });
        if (!fs.existsSync(path.join(target, "fpga_auto.yml"))) {
          row.notes.push(writeManifestFromTemplate(target, project.name, opts.repoRoot, opts));
        }

        const resolved = resolveManifestContext(target);
        const rc = deriveExitCode(resolved);
        if (rc !== 0) {
          row.status = "failed";
          row.notes.push(`manifest_validation_failed:${(resolved.errors || []).map((e) => e.code).join(",")}`);
        } else {
          row.status = "migrated";
          row.notes.push("copied_and_validated");
        }
      } else {
        row.status = "dry_run";
        row.notes.push("copy_skipped");
      }
    } catch (err) {
      row.status = "failed";
      row.notes.push(err.message);
    }

    results.push(row);
  }

  const report = {
    policy: "copy_and_verify",
    repo_root: normalizeSlashes(opts.repoRoot),
    project_root: normalizeSlashes(opts.projectRoot),
    dry_run: opts.dryRun,
    infer_globs: opts.inferGlobs,
    scanned: legacyProjects.length,
    migrated: results.filter((r) => r.status === "migrated").length,
    failed: results.filter((r) => r.status === "failed").length,
    results,
  };

  const reportDir = path.join(opts.repoRoot, "output", "migration");
  ensureDir(reportDir);
  const reportPath = path.join(reportDir, `migration_report_${tsNow()}.json`);
  fs.writeFileSync(reportPath, JSON.stringify(report, null, 2), "utf8");

  console.log(`[INFO] scanned=${report.scanned} migrated=${report.migrated} failed=${report.failed}`);
  console.log(`[INFO] report=${normalizeSlashes(reportPath)}`);

  process.exit(report.failed > 0 ? EXIT_FAIL : EXIT_OK);
}

if (require.main === module) {
  main();
}
