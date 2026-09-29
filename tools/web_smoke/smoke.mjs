#!/usr/bin/env node
// Smoke test for the web export: serve build/web/, open it in headless
// Chromium (WebGL 2 via SwiftShader), wait for the Godot engine to boot and
// render, then fail on any console error, page error or failed request.
// Saves a screenshot to build/web_smoke.png.
//
//   node tools/web_smoke/smoke.mjs [--dir build/web] [--timeout 60000]
//        [--settle 3000] [--screenshot build/web_smoke.png] [--headed]
//        [--query "server=off"] [--expect REGEX]...
//
// --query: the page's query string (default server=off; e.g. the loop test mode:
// "mode=loop&server=off&at=city&bot=keep"). --expect: a console line must match
// REGEX (repeatable; e.g. the loop map hash the build prints).
//
// Needs `npm ci` in tools/web_smoke once. Browser: Playwright's Chromium
// (`npx playwright install chromium`), or CHROMIUM_PATH=/path/to/chrome.
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

function parseArgs(argv) {
  const opts = {
    dir: path.join(repoRoot, 'build', 'web'),
    timeout: 60000,
    settle: 3000,
    screenshot: path.join(repoRoot, 'build', 'web_smoke.png'),
    headed: false,
    query: 'server=off',
    expect: [],
  };
  for (let i = 0; i < argv.length; i++) {
    const [flag, inline] = argv[i].split(/=(.*)/s, 2);
    const value = () => (inline !== undefined ? inline : argv[++i]);
    switch (flag) {
      case '--dir': opts.dir = path.resolve(value()); break;
      case '--timeout': opts.timeout = Number(value()); break;
      case '--settle': opts.settle = Number(value()); break;
      case '--screenshot': opts.screenshot = path.resolve(value()); break;
      case '--headed': opts.headed = true; break;
      case '--query': opts.query = value(); break;
      case '--expect': opts.expect.push(new RegExp(value())); break;
      case '-h': case '--help':
        console.log('usage: node tools/web_smoke/smoke.mjs [--dir build/web] [--timeout 60000] [--settle 3000] [--screenshot build/web_smoke.png] [--headed] [--query "server=off"] [--expect REGEX]...');
        process.exit(0);
      default:
        console.error(`smoke: unknown argument ${argv[i]}`);
        process.exit(2);
    }
  }
  if (!Number.isFinite(opts.timeout) || !Number.isFinite(opts.settle)) {
    console.error('smoke: --timeout and --settle take milliseconds');
    process.exit(2);
  }
  return opts;
}

// Static server with the MIME types the Godot web export needs. No
// COOP/COEP headers, on purpose: GitHub Pages cannot send them, and the
// single-threaded build must run without them.
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.wasm': 'application/wasm',
  '.pck': 'application/octet-stream',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.json': 'application/json',
  '.css': 'text/css; charset=utf-8',
};

function serve(root) {
  const server = http.createServer((req, res) => {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.writeHead(405).end();
      return;
    }
    let rel = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
    if (rel.endsWith('/')) rel += 'index.html';
    const file = path.resolve(root, '.' + rel);
    if (!file.startsWith(root + path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
      res.writeHead(404, { 'Content-Type': 'text/plain' }).end('not found');
      return;
    }
    const type = MIME[path.extname(file).toLowerCase()] || 'application/octet-stream';
    res.writeHead(200, {
      'Content-Type': type,
      'Content-Length': fs.statSync(file).size,
      'Cache-Control': 'no-store',
    });
    if (req.method === 'HEAD') res.end();
    else fs.createReadStream(file).pipe(res);
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server)));
}

// SwiftShader gives headless Chromium a software WebGL 2 on machines with no GPU.
const CHROME_ARGS = [
  '--use-angle=swiftshader',
  '--enable-unsafe-swiftshader',
  '--ignore-gpu-blocklist',
  '--autoplay-policy=no-user-gesture-required',
];

// Find an already-installed Playwright Chromium when the pinned package
// version's own build is missing (e.g. a preinstalled browser cache).
function findInstalledChromium(headed) {
  const roots = [process.env.PLAYWRIGHT_BROWSERS_PATH, path.join(process.env.HOME || '', '.cache', 'ms-playwright')]
    .filter((p) => p && fs.existsSync(p));
  const candidates = [];
  for (const root of roots) {
    for (const entry of fs.readdirSync(root).sort().reverse()) {
      if (!headed && entry.startsWith('chromium_headless_shell-')) {
        candidates.push(path.join(root, entry, 'chrome-linux', 'headless_shell'));
      } else if (entry.startsWith('chromium-')) {
        candidates.push(path.join(root, entry, 'chrome-linux', 'chrome'));
      }
    }
  }
  return candidates.find((p) => fs.existsSync(p));
}

async function launch(headed) {
  const base = { headless: !headed, args: CHROME_ARGS };
  if (process.env.CHROMIUM_PATH) return chromium.launch({ ...base, executablePath: process.env.CHROMIUM_PATH });
  try {
    return await chromium.launch(base);
  } catch (err) {
    const fallback = findInstalledChromium(headed);
    if (!/Executable doesn't exist/.test(String(err)) || !fallback) throw err;
    console.log(`smoke: pinned Chromium not installed, using ${fallback}`);
    return chromium.launch({ ...base, executablePath: fallback });
  }
}

// Decode the screenshot in the browser (no image deps) and summarize it:
// the most common color and how many pixels differ from it.
async function analyzePng(browser, png) {
  const page = await browser.newPage();
  try {
    return await page.evaluate(async (b64) => {
      const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
      const bmp = await createImageBitmap(new Blob([bytes], { type: 'image/png' }));
      const canvas = new OffscreenCanvas(bmp.width, bmp.height);
      const ctx = canvas.getContext('2d');
      ctx.drawImage(bmp, 0, 0);
      const { data } = ctx.getImageData(0, 0, bmp.width, bmp.height);
      const counts = new Map();
      for (let i = 0; i < data.length; i += 4) {
        const key = (data[i] << 16) | (data[i + 1] << 8) | data[i + 2];
        counts.set(key, (counts.get(key) || 0) + 1);
      }
      let mode = 0;
      let modeCount = 0;
      for (const [k, n] of counts) if (n > modeCount) { mode = k; modeCount = n; }
      const [mr, mg, mb] = [(mode >> 16) & 255, (mode >> 8) & 255, mode & 255];
      let differing = 0;
      let bright = 0;
      for (let i = 0; i < data.length; i += 4) {
        const d = Math.abs(data[i] - mr) + Math.abs(data[i + 1] - mg) + Math.abs(data[i + 2] - mb);
        if (d > 48) differing++;
        if (0.2126 * data[i] + 0.7152 * data[i + 1] + 0.0722 * data[i + 2] > 160) bright++;
      }
      const total = data.length / 4;
      return {
        width: bmp.width,
        height: bmp.height,
        dominant: '#' + mode.toString(16).padStart(6, '0'),
        dominantPct: (100 * modeCount) / total,
        differingPct: (100 * differing) / total,
        brightPixels: bright,
      };
    }, png.toString('base64'));
  } finally {
    await page.close();
  }
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const root = path.resolve(opts.dir);
  if (!fs.existsSync(path.join(root, 'index.html'))) {
    console.error(`smoke: ${root}/index.html not found. Build it first: tools/export_web.sh`);
    process.exit(2);
  }

  const server = await serve(root);
  // ?server=off: the smoke test never creates accounts on the production server (N1.2).
  if (!/(^|&)server=off(&|$)/.test(opts.query)) opts.query = `${opts.query}&server=off`.replace(/^&/, '');
  const url = `http://127.0.0.1:${server.address().port}/index.html?${opts.query}`;
  const failures = [];
  const consoleLines = [];
  let browser;
  const t0 = Date.now();
  const elapsed = () => `${((Date.now() - t0) / 1000).toFixed(1)}s`;

  try {
    browser = await launch(opts.headed);
    const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });

    page.on('console', (msg) => {
      const text = msg.text();
      consoleLines.push(text);
      console.log(`  [console.${msg.type()}] ${text}`);
      if (msg.type() === 'error') failures.push(`console error: ${text}`);
    });
    page.on('pageerror', (err) => failures.push(`page error: ${err.message}`));
    page.on('requestfailed', (req) => {
      // net::ERR_ABORTED is the browser cancelling a request it no longer needs
      // (e.g. a duplicate prefetch of index.wasm); a missing file shows up as an
      // HTTP error below and a failed boot as missing engine output.
      const err = req.failure()?.errorText ?? '';
      if (err.includes('ERR_ABORTED')) {
        console.log(`smoke: note: aborted request ignored: ${req.url()}`);
        return;
      }
      failures.push(`request failed: ${req.url()} (${err})`);
    });
    page.on('response', (res) => {
      // Browsers may probe /favicon.ico on their own; Pages would 404 it too.
      if (res.status() >= 400 && !res.url().endsWith('/favicon.ico')) {
        failures.push(`HTTP ${res.status()}: ${res.url()}`);
      }
    });

    console.log(`smoke: serving ${root} at ${url}`);
    await page.goto(url, { waitUntil: 'load', timeout: opts.timeout });

    const gl = await page.evaluate(() => {
      const ctx = document.createElement('canvas').getContext('webgl2');
      if (!ctx) return null;
      const info = ctx.getExtension('WEBGL_debug_renderer_info');
      return info ? ctx.getParameter(info.UNMASKED_RENDERER_WEBGL) : ctx.getParameter(ctx.RENDERER);
    });
    if (!gl) throw new Error('WebGL 2 is not available in this Chromium (tried SwiftShader flags)');
    console.log(`smoke: WebGL 2 renderer: ${gl}`);

    // Booted = Godot printed its banner and the loading overlay is gone
    // (the shell removes #status once engine.startGame() resolves).
    const deadline = Date.now() + opts.timeout;
    for (;;) {
      if (failures.length) break;
      const state = await page.evaluate(() => {
        const notice = document.getElementById('status-notice');
        return {
          overlay: !!document.getElementById('status'),
          notice: notice && notice.style.display === 'block' ? notice.innerText : '',
        };
      });
      if (state.notice) {
        failures.push(`Godot shell error notice: ${state.notice.trim()}`);
        break;
      }
      const banner = consoleLines.some((l) => /^Godot Engine v\d/.test(l));
      if (banner && !state.overlay) break;
      if (Date.now() > deadline) {
        failures.push(`engine did not start within ${opts.timeout} ms (banner seen: ${banner}, loading overlay present: ${state.overlay})`);
        break;
      }
      await page.waitForTimeout(250);
    }

    if (!failures.length) {
      console.log(`smoke: engine started after ${elapsed()}; letting it run ${opts.settle} ms`);
      const frames = await page.evaluate((ms) => new Promise((resolve) => {
        let n = 0;
        const end = performance.now() + ms;
        const tick = (now) => { n++; if (now < end) requestAnimationFrame(tick); else resolve(n); };
        requestAnimationFrame(tick);
      }), opts.settle);
      console.log(`smoke: ${frames} animation frames in ${opts.settle} ms`);
      if (frames < 10) failures.push(`page barely animates (${frames} frames in ${opts.settle} ms)`);

      const renderer = consoleLines.find((l) => /OpenGL API|WebGL/.test(l));
      if (renderer) console.log(`smoke: Godot renderer: ${renderer}`);

      fs.mkdirSync(path.dirname(opts.screenshot), { recursive: true });
      const png = await page.screenshot({ path: opts.screenshot });
      const img = await analyzePng(browser, png);
      console.log(`smoke: screenshot ${opts.screenshot} ${img.width}x${img.height}, dominant ${img.dominant} (${img.dominantPct.toFixed(1)}%), ` +
        `${img.differingPct.toFixed(2)}% other pixels, ${img.brightPixels} bright pixels`);
      // A booted scene draws something besides the clear color (the title label
      // in M0). A flat image means the canvas never rendered.
      if (img.differingPct < 0.05) failures.push(`screenshot is a flat ${img.dominant}: nothing rendered`);
      for (const re of opts.expect) {
        if (!consoleLines.some((l) => re.test(l))) failures.push(`no console line matches ${re}`);
        else console.log(`smoke: console matches ${re}`);
      }
    } else {
      try {
        fs.mkdirSync(path.dirname(opts.screenshot), { recursive: true });
        await page.screenshot({ path: opts.screenshot });
      } catch { /* best effort */ }
    }
  } catch (err) {
    failures.push(`smoke: ${err.message || err}`);
  } finally {
    if (browser) await browser.close();
    server.close();
  }

  if (failures.length) {
    console.error(`\nsmoke: FAIL after ${elapsed()} (${failures.length} problem(s)):`);
    for (const f of failures) console.error(`  - ${f}`);
    process.exit(1);
  }
  console.log(`smoke: PASS in ${elapsed()}`);
}

main();
