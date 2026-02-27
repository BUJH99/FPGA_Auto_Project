/**
 * svg_to_png_node.js
 * Convert an SVG file to PNG using one of several available methods:
 *   1. @resvg/resvg-js  (fastest, pure Rust, no browser needed)
 *   2. puppeteer / puppeteer-core  (headless Chrome)
 *   3. canvas + svg-parser (fallback)
 *
 * Usage:
 *   node svg_to_png_node.js --input <file.svg> --output <file.png> [--width 1200] [--dpi 150]
 *   node svg_to_png_node.js --batch-md <report_md> --output-md <out_md> --project-root <dir>
 *
 * Auto-installs @resvg/resvg-js into <projectRoot>/node_modules if not present.
 */
'use strict';

const fs   = require('fs');
const path = require('path');
const { execSync, spawnSync } = require('child_process');

// ─── CLI args ────────────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const get = (flag, def = null) => {
    const i = args.indexOf(flag);
    return i >= 0 && args[i + 1] ? args[i + 1] : def;
};

const mode        = get('--batch-md') ? 'batch' : 'single';
const inputSvg    = get('--input');
const outputPng   = get('--output');
const batchMdIn   = get('--batch-md');
const batchMdOut  = get('--output-md');
const projectRoot = get('--project-root', process.cwd());
const dpi         = parseInt(get('--dpi', '96'), 10);    // 96 = Word screen DPI
const widthHint   = parseInt(get('--width', '1200'), 10);
const imgWidth    = get('--img-width', '95%');           // pandoc width attribute

// ─── npm root for auto-install ───────────────────────────────────────────────
const nmRoot = path.join(projectRoot, 'node_modules');
const resvgPkg = path.join(nmRoot, '@resvg', 'resvg-js');

function tryRequireResvg() {
    try { return require(resvgPkg); } catch (_) { return null; }
}

function autoInstallResvg() {
    console.log('[INFO] @resvg/resvg-js not found. Auto-installing (this takes ~30s first time)...');
    try {
        const pkgJson = path.join(projectRoot, 'package.json');
        if (!fs.existsSync(pkgJson)) {
            fs.writeFileSync(pkgJson, JSON.stringify({ name: 'fpga-report', private: true }, null, 2), 'utf8');
        }
        execSync('npm install --no-save @resvg/resvg-js@2', {
            cwd: projectRoot,
            stdio: 'inherit',
            timeout: 120000
        });
        return tryRequireResvg();
    } catch (e) {
        console.warn('[WARN] Auto-install failed:', e.message);
        return null;
    }
}

// ─── Convert single SVG → PNG via resvg ──────────────────────────────────────
function convertWithResvg(resvg, svgPath, pngPath) {
    const svgData = fs.readFileSync(svgPath);
    const instance = new resvg.Resvg(svgData, {
        dpi,
        fitTo: { mode: 'width', value: widthHint },
        font: {
            // IMPORTANT: must be true so that text nodes (port names, module
            // names, labels) are actually rendered. When false, all text is
            // silently dropped and the PNG contains only shapes/lines.
            loadSystemFonts: true,
            // Fallback font families for text that doesn't specify one
            defaultFontFamily: 'Arial',
            serifFamily:       'Times New Roman',
            sansSerifFamily:   'Arial',
            monospaceFamily:   'Courier New'
        }
    });
    const rendered = instance.render();
    const buf = rendered.asPng();
    const dir = path.dirname(pngPath);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(pngPath, buf);
    return true;
}

// ─── Convert via puppeteer (if installed globally) ────────────────────────────
function convertWithPuppeteer(svgPath, pngPath) {
    // Try to find puppeteer / puppeteer-core
    let puppeteerPath = null;
    for (const name of ['puppeteer', 'puppeteer-core']) {
        try {
            puppeteerPath = require.resolve(name);
            break;
        } catch (_) {}
        const local = path.join(nmRoot, name);
        if (fs.existsSync(local)) { puppeteerPath = local; break; }
    }
    if (!puppeteerPath) return false;

    // Run headless browser in a child node script  
    const helperCode = `
const puppeteer = require(${JSON.stringify(puppeteerPath)});
const fs = require('fs');
const path = require('path');

(async () => {
  const svgPath = ${JSON.stringify(svgPath)};
  const pngPath = ${JSON.stringify(pngPath)};
  const svgContent = fs.readFileSync(svgPath, 'utf8');

  const browser = await puppeteer.launch({ headless: true, args: ['--no-sandbox'] });
  const page = await browser.newPage();
  await page.setContent(\`<html><body style="margin:0;padding:0;background:white">\${svgContent}</body></html>\`);
  const el = await page.$('svg');
  if (el) {
    const box = await el.boundingBox();
    await page.setViewport({ width: Math.ceil(box.width) || 1200, height: Math.ceil(box.height) || 900, deviceScaleFactor: 2 });
    await el.screenshot({ path: pngPath, omitBackground: false });
  } else {
    await page.screenshot({ path: pngPath, fullPage: true });
  }
  await browser.close();
  console.log('[OK]', pngPath);
})().catch(e => { console.error('[ERR]', e.message); process.exit(1); });
`;
    const tmpJs = path.join(require('os').tmpdir(), `_svg2png_helper_${Date.now()}.js`);
    fs.writeFileSync(tmpJs, helperCode, 'utf8');
    try {
        const r = spawnSync(process.execPath, [tmpJs], { timeout: 30000, encoding: 'utf8' });
        if (r.status === 0 && fs.existsSync(pngPath)) return true;
    } finally {
        if (fs.existsSync(tmpJs)) fs.unlinkSync(tmpJs);
    }
    return false;
}

// ─── Master convert function ──────────────────────────────────────────────────
let _resvg = tryRequireResvg();

const svgPngCache = new Map();

function convertSvg(svgPath, pngPath) {
    if (svgPngCache.has(svgPath)) return svgPngCache.get(svgPath);
    if (!fs.existsSync(svgPath)) {
        console.warn('[WARN] SVG not found:', svgPath);
        svgPngCache.set(svgPath, false);
        return false;
    }

    // 1) resvg-js
    if (!_resvg) _resvg = autoInstallResvg();
    if (_resvg) {
        try {
            if (convertWithResvg(_resvg, svgPath, pngPath)) {
                console.log(`[INFO] Converted (resvg): ${path.basename(svgPath)}`);
                svgPngCache.set(svgPath, pngPath);
                return pngPath;
            }
        } catch (e) { console.warn('[WARN] resvg failed:', e.message); }
    }

    // 2) puppeteer
    try {
        if (convertWithPuppeteer(svgPath, pngPath)) {
            console.log(`[INFO] Converted (puppeteer): ${path.basename(svgPath)}`);
            svgPngCache.set(svgPath, pngPath);
            return pngPath;
        }
    } catch (e) { console.warn('[WARN] puppeteer failed:', e.message); }

    console.warn('[WARN] All converters failed:', svgPath);
    svgPngCache.set(svgPath, false);
    return false;
}

// ─── Single mode ──────────────────────────────────────────────────────────────
if (mode === 'single') {
    if (!inputSvg || !outputPng) {
        console.error('Usage: node svg_to_png_node.js --input <file.svg> --output <file.png>');
        process.exit(1);
    }
    // Resolve relative to process.cwd() for single mode (not projectRoot)
    const svgAbs = path.resolve(process.cwd(), inputSvg);
    const pngAbs = path.resolve(process.cwd(), outputPng);
    const result = convertSvg(svgAbs, pngAbs);
    if (result) {
        console.log('[SUCCESS]', pngAbs);
    } else {
        console.error('[FAIL] Conversion failed');
        process.exit(1);
    }
    process.exit(0);
}

// ─── Batch mode: scan markdown, replace SVG → PNG ───────────────────────────
if (!batchMdIn || !batchMdOut) {
    console.error('Usage (batch): node svg_to_png_node.js --batch-md <input.md> --output-md <output.md> --project-root <dir>');
    process.exit(1);
}

const mdAbsIn  = path.resolve(batchMdIn);
const mdAbsOut = path.resolve(batchMdOut);
const mdDir    = path.dirname(mdAbsIn);
const projAbs  = path.resolve(projectRoot);

if (!fs.existsSync(mdAbsIn)) {
    console.error('[ERROR] Input markdown not found:', mdAbsIn);
    process.exit(1);
}

let raw = fs.readFileSync(mdAbsIn, 'utf8');

// Match: ![alt](some/path.svg) or ![alt](some/path.svg?query)
const SVG_RE = /!\[([^\]]*)\]\(([^)]+?\.svg(?:\?[^)]*)?)\)/g;

let convertedCount = 0;
let skippedCount   = 0;

raw = raw.replace(SVG_RE, (full, alt, svgRel) => {
    const svgPath = svgRel.replace(/\?.*$/, '');  // strip query

    // Resolve absolute path (try: project-root relative, mdDir relative, absolute)
    let svgAbs = null;
    for (const candidate of [
        path.resolve(projAbs, svgPath),
        path.resolve(mdDir,   svgPath),
        path.resolve(svgPath)
    ]) {
        if (fs.existsSync(candidate)) { svgAbs = candidate; break; }
    }

    if (!svgAbs) {
        console.warn('[WARN] SVG not found:', svgPath);
        skippedCount++;
        return `[${alt}]`;  // fallback: plain text link
    }

    // Target PNG path: same dir as SVG, same stem + suffix
    const pngAbs = svgAbs.replace(/\.svg$/i, '.docx_converted.png');
    const result = convertSvg(svgAbs, pngAbs);

    if (result) {
        // Relative to project root, forward slashes for pandoc
        let pngRel = path.relative(projAbs, pngAbs).replace(/\\/g, '/');
        convertedCount++;
        // Add pandoc image-size attribute so Word scales to page width
        return `![${alt}](${pngRel}){ width=${imgWidth} }`;
    } else {
        skippedCount++;
        // Fallback: convert to plain link so pandoc doesn't error on missing image
        return `[${alt}]`;
    }
});

// Write output
const dir = path.dirname(mdAbsOut);
if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(mdAbsOut, raw, 'utf8');

console.log(`[SUCCESS] SVG→PNG batch done: ${convertedCount} converted, ${skippedCount} skipped`);
console.log('[INFO] Output:', mdAbsOut);
