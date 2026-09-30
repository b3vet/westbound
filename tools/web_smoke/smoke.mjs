#!/usr/bin/env node
// Smoke test for the web export: serve build/web/, open it in headless
// Chromium (WebGL 2 via SwiftShader), wait for the Godot engine to boot and
// render, then fail on any console error, page error or failed request.
// Saves a screenshot to build/web_smoke.png. Prints the load timings, the
// bytes transferred and the memory (docs/WEB.md → Measuring).
//
//   node tools/web_smoke/smoke.mjs [--dir build/web] [--timeout 60000]
//        [--settle 3000] [--screenshot build/web_smoke.png] [--headed]
//        [--query "server=off"] [--expect REGEX]... [--reload --expect-reload REGEX...]
//        [--wait-for REGEX] [--wait-timeout MS] [--console-out FILE]
//        [--gzip] [--network wifi|4g|slow4g|<Mbps>,<rtt ms>] [--json out.json]
//        [--audio-unlock [click|tap|key]] [--stale]
//        [--device NAME | --portrait | --landscape] [--tap-play] [--dpr N]
//
// --query: the page's query string (default server=off; e.g. the loop test mode:
// "mode=loop&server=off&at=city&bot=keep"). --expect: a console line must match
// REGEX (repeatable; e.g. the loop map hash the build prints). --reload: after the
// first boot, reload the page in the same browser profile (same IndexedDB) and boot
// again; --expect-reload: a console line of the second boot must match REGEX (the
// save's persistence check: --query "server=off&save_probe=1" --reload
// --expect-reload "Save probe: loaded 1 boot"). --wait-for: after the boot, wait (up to
// --wait-timeout, default 600000 ms) until a console line matches REGEX, then settle as
// usual (the determinism check: --query "determinism=daily&date=2026-09-30&seconds=60"
// --wait-for "^DT done"). --console-out: write every console line to FILE (one per line).
//
// WP9.2 (load time, docs/WEB.md):
// --gzip: serve every file gzip-encoded, as GitHub Pages does, so the transfer
// sizes are the real ones. --network: throttle the page (Chrome DevTools
// conditions: wifi 30 Mbps / 20 ms, 4g 9 Mbps / 60 ms, slow4g 1.6 Mbps / 150 ms,
// or "<Mbps>,<rtt ms>"). --json: write the metrics to a file. The timings are page
// times from navigation start: first paint, downloads done, wasm compiled, the
// engine's main(), first WebGL frame, title shown (the game's "web boot: title"
// mark), loading overlay gone; plus the wasm heap and JS heap after the settle.
// When the game fetches its music pack ("web music: downloading"), it must load.
// --audio-unlock: launch with the browser's default autoplay policy (the rest of
// the smoke allows autoplay) and check the unlock: the page's AudioContext is
// suspended at boot and the game holds its music ("web audio: locked"); one
// gesture (a click by default, or a touch tap, or a key) on an empty part of the
// title must resume the context and start the music ("web audio: unlocked ...
// music playing"). Nothing runs page.evaluate() before that gesture: Playwright's
// evaluate counts as a user gesture and would unlock the page itself.
// Caching (custom shell only): index.js, index.wasm and index.pck must be requested
// with ?v=<build id>. --stale serves a version.json naming a newer build first (a
// cached index.html after a deploy): the page must reload itself exactly once.
//
// WP9.7 (landscape only, docs/WEB.md → Landscape only):
// --device NAME: emulate a Playwright device (e.g. "iPhone 14", "iPhone 14 landscape":
// its viewport, pixel ratio, touch and user agent). --portrait is --device "iPhone 14"
// and --landscape is --device "iPhone 14 landscape"; both also --tap-play and check the
// shell's layout: portrait must be rotated (the canvas is the landscape box, the rotated
// box covers the viewport), landscape must not. --dpr N overrides the device's pixel
// ratio (SwiftShader renders every backing pixel on the CPU). --tap-play: after the
// title, tap PLAY where the game draws it (the game prints its buttons with ?probe=ui,
// in canvas px; the tap goes through the shell's rotation when the page is rotated),
// then DRIVE if the first-run chooser opens; the game must start a run ("web boot:
// start"). Before any browser work the smoke runs tools/web_smoke/layout_test.mjs (the
// shell's rotation math in node).
//
// Needs `npm ci` in tools/web_smoke once. Browser: Playwright's Chromium
// (`npx playwright install chromium`), or CHROMIUM_PATH=/path/to/chrome.
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';
import { chromium, devices } from 'playwright';
import { loadLayoutMath, runLayoutTests } from './layout_test.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

// Chrome DevTools' throttling presets (download Mbps, round trip ms).
const NETWORKS = {
  wifi: [30, 20],
  '4g': [9, 60],
  slow4g: [1.6, 150],
};
const GESTURES = ['click', 'tap', 'key'];

function parseArgs(argv) {
  const opts = {
    dir: path.join(repoRoot, 'build', 'web'),
    timeout: 60000,
    settle: 3000,
    screenshot: path.join(repoRoot, 'build', 'web_smoke.png'),
    headed: false,
    query: 'server=off',
    expect: [],
    reload: false,
    expectReload: [],
    waitFor: null,
    waitTimeout: 600000,
    consoleOut: null,
    gzip: false,
    network: null,
    json: null,
    audioUnlock: null,
    stale: false,
    device: null,
    expectRotated: null,
    tapPlay: false,
    dpr: null,
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
      case '--reload': opts.reload = true; break;
      case '--expect-reload': opts.expectReload.push(new RegExp(value())); opts.reload = true; break;
      case '--wait-for': opts.waitFor = new RegExp(value()); break;
      case '--wait-timeout': opts.waitTimeout = Number(value()); break;
      case '--console-out': opts.consoleOut = path.resolve(value()); break;
      case '--gzip': opts.gzip = true; break;
      case '--network': {
        const v = value();
        const pair = NETWORKS[v] || v.split(',').map(Number);
        if (pair.length !== 2 || !pair.every((n) => Number.isFinite(n) && n > 0)) {
          console.error(`smoke: --network takes ${Object.keys(NETWORKS).join('|')} or "<Mbps>,<rtt ms>"`);
          process.exit(2);
        }
        opts.network = { name: v, mbps: pair[0], rtt: pair[1] };
        break;
      }
      case '--json': opts.json = path.resolve(value()); break;
      case '--stale': opts.stale = true; break;
      case '--device': opts.device = value(); break;
      case '--portrait': opts.device = 'iPhone 14'; opts.expectRotated = true; opts.tapPlay = true; break;
      case '--landscape': opts.device = 'iPhone 14 landscape'; opts.expectRotated = false; opts.tapPlay = true; break;
      case '--tap-play': opts.tapPlay = true; break;
      case '--dpr': opts.dpr = Number(value()); break;
      case '--audio-unlock': {
        // Optional value: the next argument when it names a gesture.
        let g = inline;
        if (g === undefined && GESTURES.includes(argv[i + 1])) g = argv[++i];
        opts.audioUnlock = g || 'click';
        if (!GESTURES.includes(opts.audioUnlock)) {
          console.error(`smoke: --audio-unlock takes ${GESTURES.join('|')}`);
          process.exit(2);
        }
        break;
      }
      case '-h': case '--help':
        console.log('usage: node tools/web_smoke/smoke.mjs [--dir build/web] [--timeout 60000] [--settle 3000] [--screenshot build/web_smoke.png] [--headed] [--query "server=off"] [--expect REGEX]... [--reload --expect-reload REGEX...] [--gzip] [--network wifi|4g|slow4g|<Mbps>,<rtt>] [--json out.json] [--audio-unlock [click|tap|key]] [--stale] [--wait-for REGEX] [--wait-timeout MS] [--console-out FILE] [--device NAME | --portrait | --landscape] [--tap-play] [--dpr N]');
        process.exit(0);
      default:
        console.error(`smoke: unknown argument ${argv[i]}`);
        process.exit(2);
    }
  }
  if (!Number.isFinite(opts.timeout) || !Number.isFinite(opts.settle) || !Number.isFinite(opts.waitTimeout)) {
    console.error('smoke: --timeout, --settle and --wait-timeout take milliseconds');
    process.exit(2);
  }
  if (opts.device && !devices[opts.device]) {
    console.error(`smoke: unknown --device "${opts.device}" (Playwright device names, e.g. "iPhone 14", "iPhone 14 landscape")`);
    process.exit(2);
  }
  if (opts.dpr != null && !(opts.dpr > 0)) {
    console.error('smoke: --dpr takes a positive pixel ratio');
    process.exit(2);
  }
  if (opts.tapPlay && opts.audioUnlock) {
    console.error('smoke: --tap-play and --audio-unlock are separate runs');
    process.exit(2);
  }
  return opts;
}

// Static server with the MIME types the Godot web export needs. No
// COOP/COEP headers, on purpose: GitHub Pages cannot send them, and the
// single-threaded build must run without them. --gzip encodes like Pages.
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
  '.woff2': 'font/woff2',
};

// --stale: the first version.json names a newer build (as if index.html came from
// the browser cache after a deploy); the custom shell must reload once.
const STALE_BUILD = 'ffffffffffff';

function serve(root, gzip, stale) {
  const gzCache = new Map();
  const sent = new Map();   // path -> bytes on the wire
  const urls = [];          // every GET, with its query
  let staleLeft = stale ? 1 : 0;
  const server = http.createServer((req, res) => {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.writeHead(405).end();
      return;
    }
    urls.push(req.url);
    let rel = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
    if (rel.endsWith('/')) rel += 'index.html';
    if (rel === '/version.json' && staleLeft > 0) {
      staleLeft--;
      res.writeHead(200, { 'Content-Type': MIME['.json'], 'Cache-Control': 'no-store' });
      res.end(JSON.stringify({ build: STALE_BUILD }));
      return;
    }
    const file = path.resolve(root, '.' + rel);
    if (!file.startsWith(root + path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
      res.writeHead(404, { 'Content-Type': 'text/plain' }).end('not found');
      return;
    }
    const type = MIME[path.extname(file).toLowerCase()] || 'application/octet-stream';
    const headers = { 'Content-Type': type, 'Cache-Control': 'no-store' };
    let body = null;
    if (gzip && /\bgzip\b/.test(req.headers['accept-encoding'] || '')) {
      if (!gzCache.has(file)) gzCache.set(file, zlib.gzipSync(fs.readFileSync(file), { level: 6 }));
      body = gzCache.get(file);
      headers['Content-Encoding'] = 'gzip';
      headers['Vary'] = 'Accept-Encoding';
      headers['Content-Length'] = body.length;
    } else {
      headers['Content-Length'] = fs.statSync(file).size;
    }
    res.writeHead(200, headers);
    if (req.method === 'HEAD') {
      res.end();
      return;
    }
    sent.set(rel, (sent.get(rel) || 0) + headers['Content-Length']);
    if (body) res.end(body);
    else fs.createReadStream(file).pipe(res);
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ server, sent, urls })));
}

// SwiftShader gives headless Chromium a software WebGL 2 on machines with no GPU.
const GL_ARGS = [
  '--use-angle=swiftshader',
  '--enable-unsafe-swiftshader',
  '--ignore-gpu-blocklist',
];
const AUTOPLAY_ARG = '--autoplay-policy=no-user-gesture-required';

// Runs in the page before any of its scripts. Reports through console lines
// ("wbsmoke: <what> <page ms> ...") so the harness never needs page.evaluate()
// before a gesture test. Records: the WebGL 2 renderer, the loading overlay's
// removal and any notice, the first WebGL draw (first frame), AudioContext
// states and the first activating gesture, and the wasm memory (for the report).
function pageProbe() {
  const now = () => Math.round(performance.now());
  const log = console.log;
  const say = (s) => log.call(console, `wbsmoke: ${s}`);
  window.__wbsmoke = { memory: null };
  // Engine main() starts: the time of Godot's banner line.
  let banner = false;
  console.log = function (...a) {
    if (!banner && typeof a[0] === 'string' && a[0].startsWith('Godot Engine v')) {
      banner = true;
      say(`main-start ${now()}`);
    }
    return log.apply(console, a);
  };
  // First frame: the first draw call on any WebGL 2 context.
  const P = window.WebGL2RenderingContext && WebGL2RenderingContext.prototype;
  if (P) {
    const names = ['drawArrays', 'drawElements', 'drawArraysInstanced', 'drawElementsInstanced', 'drawRangeElements'];
    const orig = {};
    let seen = false;
    for (const n of names) {
      orig[n] = P[n];
      P[n] = function (...args) {
        if (!seen) {
          seen = true;
          for (const m of names) P[m] = orig[m];
          say(`first-frame ${now()}`);
        }
        return orig[n].apply(this, args);
      };
    }
  }
  // Wasm memory (for the memory report).
  let compiled = false;
  const keepMemory = (result) => {
    if (!compiled) {
      compiled = true;
      say(`wasm-ready ${now()}`);
    }
    const inst = result && (result.instance || result);
    const exp = inst && inst.exports;
    if (exp) for (const k of Object.keys(exp)) if (exp[k] instanceof WebAssembly.Memory) window.__wbsmoke.memory = exp[k];
    return result;
  };
  for (const n of ['instantiate', 'instantiateStreaming']) {
    const o = WebAssembly[n];
    if (o) WebAssembly[n] = function (...a) { return o.apply(this, a).then(keepMemory); };
  }
  // Audio contexts and their states.
  const AC = window.AudioContext;
  if (AC) {
    const Wrapped = function (...a) {
      const c = new AC(...a);
      say(`audio-ctx ${c.state} ${now()}`);
      c.addEventListener('statechange', () => say(`audio-ctx ${c.state} ${now()}`));
      return c;
    };
    Wrapped.prototype = AC.prototype;
    window.AudioContext = Wrapped;
  }
  // The first gesture the browser counts as user activation.
  const ua = navigator.userActivation;
  let gestured = false;
  const onGesture = (e) => {
    if (gestured || (ua && !ua.isActive)) return;
    gestured = true;
    say(`gesture ${e.type} ${now()}`);
  };
  for (const t of ['pointerup', 'touchend', 'mousedown', 'keydown', 'click']) window.addEventListener(t, onGesture, true);
  // WebGL 2, the loading overlay and the shell's error notice.
  document.addEventListener('DOMContentLoaded', () => {
    const gl = document.createElement('canvas').getContext('webgl2');
    let r = 'none';
    if (gl) {
      const info = gl.getExtension('WEBGL_debug_renderer_info');
      r = info ? gl.getParameter(info.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
      const lose = gl.getExtension('WEBGL_lose_context');
      if (lose) lose.loseContext();
    }
    say(`webgl ${r}`);
    let overlay = !!document.getElementById('status');
    let noticed = false;
    const timer = setInterval(() => {
      const notice = document.getElementById('status-notice');
      if (!noticed && notice && notice.style.display === 'block' && notice.innerText.trim()) {
        noticed = true;
        say(`notice ${notice.innerText.trim().replace(/\s+/g, ' ')}`);
      }
      if (overlay && !document.getElementById('status')) {
        overlay = false;
        say(`overlay-gone ${now()}`);
        clearInterval(timer);
      }
    }, 50);
  });
}

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

async function launch(headed, autoplay) {
  const base = { headless: !headed, args: autoplay ? [...GL_ARGS, AUTOPLAY_ARG] : GL_ARGS };
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

const MIB = 1048576;
const mib = (n) => (n == null ? '-' : `${(n / MIB).toFixed(2)} MiB`);
const sec = (ms) => (ms == null ? '-' : `${(ms / 1000).toFixed(2)} s`);

// The last "<prefix> <ms>" console line value (page ms), or null.
function consoleMs(lines, re) {
  for (let i = lines.length - 1; i >= 0; i--) {
    const m = re.exec(lines[i]);
    if (m) return Number(m[1]);
  }
  return null;
}

async function collectMetrics(page, consoleLines, sent) {
  const perf = await page.evaluate(() => {
    const nav = performance.getEntriesByType('navigation')[0];
    const res = performance.getEntriesByType('resource').map((r) => ({
      name: new URL(r.name).pathname.split('/').pop(),
      end: r.responseEnd,
      transfer: r.transferSize,
      encoded: r.encodedBodySize,
      decoded: r.decodedBodySize,
    }));
    const mem = window.__wbsmoke && window.__wbsmoke.memory;
    const heap = performance.memory || null;
    const fcp = performance.getEntriesByType('paint').find((e) => e.name === 'first-contentful-paint');
    return {
      fcp: fcp ? fcp.startTime : null,
      html: nav ? nav.responseEnd : null,
      dcl: nav ? nav.domContentLoadedEventEnd : null,
      res,
      wasmHeap: mem ? mem.buffer.byteLength : null,
      jsHeapUsed: heap ? heap.usedJSHeapSize : null,
      jsHeapTotal: heap ? heap.totalJSHeapSize : null,
    };
  });
  const byName = (re) => perf.res.filter((r) => re.test(r.name));
  const big = byName(/\.(wasm|pck)$/).filter((r) => r.name !== 'music.pck');   // the boot's downloads
  const downloaded = big.length ? Math.max(...big.map((r) => r.end)) : null;
  const files = {};
  for (const r of perf.res) files[r.name] = { end_ms: Math.round(r.end), decoded: r.decoded, encoded: r.encoded };
  let wire = 0;
  for (const [rel, n] of sent) {
    wire += n;
    const name = rel.split('/').pop();
    if (files[name]) files[name].wire = n;
    else files[name] = { wire: n };
  }
  return {
    html_ms: perf.html,
    first_paint_ms: perf.fcp,
    dom_ms: perf.dcl,
    downloaded_ms: downloaded,
    wasm_ready_ms: consoleMs(consoleLines, /^wbsmoke: wasm-ready (\d+)/),
    main_start_ms: consoleMs(consoleLines, /^wbsmoke: main-start (\d+)/),
    engine_started_ms: consoleMs(consoleLines, /^wbsmoke: overlay-gone (\d+)/),
    first_frame_ms: consoleMs(consoleLines, /^wbsmoke: first-frame (\d+)/),
    title_ms: consoleMs(consoleLines, /^web boot: title (\d+) ms/),
    run_ms: consoleMs(consoleLines, /^web boot: run (\d+) ms/),
    wire_bytes: wire,
    wasm_heap_bytes: perf.wasmHeap,
    js_heap_used_bytes: perf.jsHeapUsed,
    js_heap_total_bytes: perf.jsHeapTotal,
    files,
  };
}

function printMetrics(m, opts) {
  const net = opts.network ? `${opts.network.mbps} Mbps / ${opts.network.rtt} ms RTT (${opts.network.name})` : 'unthrottled';
  console.log(`smoke: timing (page time from navigation start; ${opts.gzip ? 'gzip like Pages' : 'no compression'}, ${net}):`);
  console.log(`smoke:   html loaded        ${sec(m.html_ms)}`);
  console.log(`smoke:   first paint        ${sec(m.first_paint_ms)}   (first contentful paint: the loading screen)`);
  console.log(`smoke:   wasm + pck loaded  ${sec(m.downloaded_ms)}`);
  console.log(`smoke:   wasm compiled      ${sec(m.wasm_ready_ms)}`);
  console.log(`smoke:   engine main()      ${sec(m.main_start_ms)}   (Godot banner)`);
  console.log(`smoke:   first frame        ${sec(m.first_frame_ms)}   (first WebGL draw)`);
  if (m.title_ms != null) console.log(`smoke:   title shown        ${sec(m.title_ms)}   (web boot: title)`);
  if (m.run_ms != null) console.log(`smoke:   run shown          ${sec(m.run_ms)}   (web boot: run)`);
  console.log(`smoke:   overlay gone       ${sec(m.engine_started_ms)}   (loading screen removed)`);
  console.log(`smoke:   transferred        ${mib(m.wire_bytes)}`);
  for (const [name, f] of Object.entries(m.files).sort((a, b) => (b[1].wire || 0) - (a[1].wire || 0)).slice(0, 5)) {
    console.log(`smoke:     ${name.padEnd(28)} ${mib(f.wire).padStart(10)} on the wire, ${mib(f.decoded).padStart(10)} decoded, done ${sec(f.end_ms)}`);
  }
  console.log(`smoke:   memory             wasm heap ${mib(m.wasm_heap_bytes)}, JS heap ${mib(m.js_heap_used_bytes)} used / ${mib(m.js_heap_total_bytes)}`);
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const root = path.resolve(opts.dir);
  if (!fs.existsSync(path.join(root, 'index.html'))) {
    console.error(`smoke: ${root}/index.html not found. Build it first: tools/export_web.sh`);
    process.exit(2);
  }

  // The shell's rotation math first (node, no browser).
  const layoutFailures = runLayoutTests();
  if (layoutFailures.length) {
    console.error('smoke: the shell\'s layout math is wrong (tools/web_smoke/layout_test.mjs):');
    for (const f of layoutFailures) console.error(`  - ${f}`);
    process.exit(1);
  }
  console.log('smoke: layout math (tools/web_smoke/layout_test.mjs) passes');
  if (opts.tapPlay && !/(^|&)probe=ui(&|$)/.test(opts.query)) opts.query = `${opts.query}&probe=ui`.replace(/^&/, '');

  const { server, sent, urls } = await serve(root, opts.gzip, opts.stale);
  // The custom shell's build id (tools/export_web.sh fills it; '' with Godot's shell).
  const shellBuild = (/const build = '([0-9a-f]{8,})'/.exec(fs.readFileSync(path.join(root, 'index.html'), 'utf8')) || [])[1] || '';
  // ?server=off: the smoke test never creates accounts on the production server (N1.2).
  if (!/(^|&)server=off(&|$)/.test(opts.query)) opts.query = `${opts.query}&server=off`.replace(/^&/, '');
  const url = `http://127.0.0.1:${server.address().port}/index.html?${opts.query}`;
  const failures = [];
  const consoleLines = [];
  let browser;
  let metrics = null;
  const t0 = Date.now();
  const elapsed = () => `${((Date.now() - t0) / 1000).toFixed(1)}s`;

  try {
    browser = await launch(opts.headed, !opts.audioUnlock);
    const device = opts.device ? { ...devices[opts.device] } : null;
    if (device) {
      delete device.defaultBrowserType;   // the descriptor, in Chromium
      if (opts.dpr != null) device.deviceScaleFactor = opts.dpr;
      console.log(`smoke: device ${opts.device}: ${device.viewport.width}x${device.viewport.height} CSS px, ` +
        `pixel ratio ${device.deviceScaleFactor}, touch ${device.hasTouch}`);
    }
    const context = await browser.newContext(device || {
      viewport: { width: 1280, height: 720 },
      hasTouch: opts.audioUnlock === 'tap',
      ...(opts.dpr != null ? { deviceScaleFactor: opts.dpr } : {}),
    });
    const page = await context.newPage();
    await page.addInitScript(pageProbe);
    if (opts.network) {
      const cdp = await context.newCDPSession(page);
      await cdp.send('Network.enable');
      await cdp.send('Network.emulateNetworkConditions', {
        offline: false,
        latency: opts.network.rtt,
        downloadThroughput: (opts.network.mbps * 1e6) / 8,
        uploadThroughput: (opts.network.mbps * 1e6) / 8,
      });
    }

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

    console.log(`smoke: serving ${root} at ${url}${opts.gzip ? ' (gzip)' : ''}`);
    await page.goto(url, { waitUntil: 'load', timeout: opts.timeout });

    // Booted = Godot printed its banner (since console line `from`) and the loading
    // overlay is gone (the shell removes #status once the game is up). Read from the
    // page probe's console lines only (no page.evaluate: see --audio-unlock).
    const waitBoot = async (from) => {
      const deadline = Date.now() + opts.timeout;
      for (;;) {
        if (failures.length) break;
        const lines = consoleLines.slice(from);
        const notice = lines.find((l) => l.startsWith('wbsmoke: notice '));
        if (notice) {
          failures.push(`Godot shell error notice: ${notice.slice('wbsmoke: notice '.length)}`);
          break;
        }
        const webgl = lines.find((l) => l.startsWith('wbsmoke: webgl '));
        if (webgl && webgl === 'wbsmoke: webgl none') {
          failures.push('smoke: WebGL 2 is not available in this Chromium (tried SwiftShader flags)');
          break;
        }
        const banner = lines.some((l) => /^Godot Engine v\d/.test(l));
        const overlayGone = lines.some((l) => l.startsWith('wbsmoke: overlay-gone '));
        if (banner && overlayGone) break;
        if (Date.now() > deadline) {
          failures.push(`engine did not start within ${opts.timeout} ms (banner seen: ${banner}, loading overlay present: ${!overlayGone})`);
          break;
        }
        await page.waitForTimeout(250);
      }
    };
    await waitBoot(0);
    const webgl = consoleLines.find((l) => l.startsWith('wbsmoke: webgl '));
    if (webgl) console.log(`smoke: WebGL 2 renderer: ${webgl.slice('wbsmoke: webgl '.length)}`);

    if (!failures.length && opts.audioUnlock) await audioUnlock(page, opts, consoleLines, failures);
    if (!failures.length && (opts.tapPlay || opts.expectRotated != null)) await checkLayout(page, opts, consoleLines, failures);
    if (!failures.length && opts.tapPlay) await tapPlay(page, opts, consoleLines, failures);
    if (!failures.length) checkCaching(opts, urls, consoleLines, shellBuild, failures);

    if (!failures.length && opts.waitFor) {
      const deadline = Date.now() + opts.waitTimeout;
      console.log(`smoke: waiting up to ${opts.waitTimeout} ms for a console line matching ${opts.waitFor}`);
      while (!failures.length && !consoleLines.some((l) => opts.waitFor.test(l))) {
        if (Date.now() > deadline) {
          failures.push(`no console line matched ${opts.waitFor} within ${opts.waitTimeout} ms`);
          break;
        }
        await page.waitForTimeout(250);
      }
      if (!failures.length) console.log(`smoke: ${opts.waitFor} seen after ${elapsed()}`);
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

      const renderer = consoleLines.find((l) => /OpenGL API|WebGL/.test(l) && !l.startsWith('wbsmoke:'));
      if (renderer) console.log(`smoke: Godot renderer: ${renderer}`);

      // The music pack (music.pck, when the main pack leaves the music out) must load.
      if (consoleLines.some((l) => l.startsWith('web music: downloading'))) {
        const deadline = Date.now() + opts.timeout;
        while (!consoleLines.some((l) => /^web music: (loaded|no music)/.test(l)) && Date.now() < deadline) await page.waitForTimeout(250);
        const line = consoleLines.find((l) => /^web music: (loaded|no music)/.test(l));
        if (!line || !line.startsWith('web music: loaded')) failures.push(`music pack: ${line || 'never loaded'}`);
        else console.log(`smoke: music pack: ${line.slice('web music: '.length)}`);
      }

      metrics = await collectMetrics(page, consoleLines, sent);
      printMetrics(metrics, opts);

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
      if (opts.reload && !failures.length) {
        // Same page, same profile: user:// (IndexedDB) must still hold what the first
        // boot wrote.
        const from = consoleLines.length;
        console.log(`smoke: reloading after ${elapsed()}`);
        await page.reload({ waitUntil: 'load', timeout: opts.timeout });
        await waitBoot(from);
        if (!failures.length) {
          await page.waitForTimeout(opts.settle);
          console.log(`smoke: second boot after ${elapsed()}`);
          for (const re of opts.expectReload) {
            if (!consoleLines.slice(from).some((l) => re.test(l))) failures.push(`after the reload, no console line matches ${re}`);
            else console.log(`smoke: after the reload, console matches ${re}`);
          }
        }
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
    if (opts.consoleOut) {
      fs.mkdirSync(path.dirname(opts.consoleOut), { recursive: true });
      fs.writeFileSync(opts.consoleOut, consoleLines.join('\n') + '\n');
      console.log(`smoke: ${consoleLines.length} console lines written to ${opts.consoleOut}`);
    }
  }

  if (opts.json) {
    fs.mkdirSync(path.dirname(opts.json), { recursive: true });
    fs.writeFileSync(opts.json, JSON.stringify({ gzip: opts.gzip, network: opts.network, audio_unlock: opts.audioUnlock, failures, metrics }, null, 1));
    console.log(`smoke: metrics written to ${opts.json}`);
  }
  if (failures.length) {
    console.error(`\nsmoke: FAIL after ${elapsed()} (${failures.length} problem(s)):`);
    for (const f of failures) console.error(`  - ${f}`);
    process.exit(1);
  }
  console.log(`smoke: PASS in ${elapsed()}`);
}

// The custom shell asks for index.js, index.wasm and index.pck with ?v=<build> (a new
// deploy never mixes with cached files), and --stale makes it reload exactly once.
function checkCaching(opts, urls, consoleLines, build, failures) {
  if (!build) {
    console.log('smoke: caching: Godot\'s default shell (no build id): files are not versioned');
    if (opts.stale) failures.push('--stale needs the custom shell (platform/web/shell.html)');
    return;
  }
  for (const f of ['index.js', 'index.wasm', 'index.pck']) {
    const got = urls.filter((u) => u.split('?')[0].endsWith('/' + f));
    if (!got.length) failures.push(`caching: ${f} was never requested`);
    else if (!got.every((u) => u.endsWith(`?v=${build}`))) failures.push(`caching: ${f} requested as ${got.join(', ')}, not ?v=${build}`);
  }
  const music = urls.filter((u) => u.split('?')[0].endsWith('/music.pck'));   // only when the game fetched it
  if (!music.every((u) => u.endsWith(`?v=${build}`))) failures.push(`caching: music.pck requested as ${music.join(', ')}, not ?v=${build}`);
  const pages = urls.filter((u) => u.split('?')[0].endsWith('/index.html')).length;
  const reloads = consoleLines.filter((l) => /^Westbound: build \w+ is out/.test(l)).length;
  if (opts.stale) {
    if (reloads !== 1 || pages !== 2) failures.push(`caching: a stale page must reload exactly once (reload notes ${reloads}, index.html loads ${pages})`);
    else console.log('smoke: caching: the stale page reloaded once and booted the current build');
  } else if (reloads) {
    failures.push(`caching: the page reloaded itself ${reloads} time(s) (version.json disagrees with index.html)`);
  }
  if (!failures.length) console.log(`smoke: caching: index.js, index.wasm and index.pck fetched with ?v=${build}`);
}

// --audio-unlock: the page must boot with its audio locked and the game holding the
// music; one gesture on an empty part of the title must unlock both.
async function audioUnlock(page, opts, consoleLines, failures) {
  const has = (re, from = 0) => consoleLines.slice(from).some((l) => re.test(l));
  const waitFor = async (re, ms, from = 0) => {
    const deadline = Date.now() + ms;
    while (!has(re, from) && Date.now() < deadline && !failures.length) await page.waitForTimeout(100);
    return has(re, from);
  };
  // The title first (the world builds after the engine starts), so the gesture lands
  // on it; a direct boot (?title=0, ?mode=) marks "run" instead.
  if (!(await waitFor(/^web boot: (title|run) /, opts.timeout))) {
    failures.push('audio unlock: the game never marked the title or a run (web boot: title|run)');
    return;
  }
  const ctxStates = () => consoleLines.filter((l) => l.startsWith('wbsmoke: audio-ctx ')).map((l) => l.split(' ')[2]);
  const before = ctxStates();
  console.log(`smoke: audio before the gesture: context ${before.join(' -> ') || '(none)'}`);
  if (!before.length) {
    failures.push('audio unlock: the page made no AudioContext');
    return;
  }
  if (before[before.length - 1] !== 'suspended') {
    failures.push(`audio unlock: the context is "${before[before.length - 1]}" before any gesture; this Chromium does not enforce the autoplay policy, so the test proves nothing`);
    return;
  }
  if (!has(/^web audio: locked /)) {
    failures.push('audio unlock: the game did not report the lock ("web audio: locked ..."); its music would start silently');
    return;
  }
  if (has(/^web audio: unlocked /)) {
    failures.push('audio unlock: the game reported an unlock before any gesture');
    return;
  }
  const from = consoleLines.length;
  // An empty part of the title: right of the menu, below the profile chip, above the
  // road (the attract drive ignores taps).
  const vp = page.viewportSize();
  const x = Math.round(vp.width * 0.78);
  const y = Math.round(vp.height * 0.3);
  if (opts.audioUnlock === 'tap') await page.touchscreen.tap(x, y);
  else if (opts.audioUnlock === 'key') await page.keyboard.press('ArrowRight');
  else await page.mouse.click(x, y);
  console.log(`smoke: audio gesture: ${opts.audioUnlock} at (${x}, ${y})`);
  // Generous: SwiftShader frames take hundreds of ms on a loaded machine, and the
  // game polls the context every 0.1 s of its own frames.
  const unlockWait = Math.min(opts.timeout, 15000);
  const running = await waitFor(/^wbsmoke: audio-ctx running /, unlockWait, from);
  const unlocked = await waitFor(/^web audio: unlocked /, unlockWait, from);
  const gesture = consoleMs(consoleLines, /^wbsmoke: gesture \w+ (\d+)/);
  const resumed = consoleMs(consoleLines, /^wbsmoke: audio-ctx running (\d+)/);
  // The music starts on the unlock, or when its pack (music.pck) arrives after it.
  const playing = unlocked && await waitFor(/^web audio: .*music playing/, unlockWait, from);
  if (!running) failures.push(`audio unlock: the context did not resume after a ${opts.audioUnlock}`);
  if (!unlocked) failures.push('audio unlock: the game did not report the unlock ("web audio: unlocked ...")');
  else if (!playing) failures.push('audio unlock: unlocked, but the music did not start');
  if (running && unlocked) {
    console.log(`smoke: audio unlocked by the ${opts.audioUnlock}: context running ${resumed != null && gesture != null ? `${resumed - gesture} ms after the gesture` : ''}, music playing`);
  }
}

main();

// WP9.7: the shell's layout as the page reports it (window.wbLayout and the real
// geometry). --portrait: rotated, the canvas the landscape box, the rotated box covering
// the viewport; --landscape (and desktop): not rotated, the canvas the viewport.
async function readLayout(page) {
  return page.evaluate(() => {
    const L = window.wbLayout;
    const rotor = document.getElementById('wb-rotor');
    const canvas = document.getElementById('canvas');
    if (!L || !rotor || !canvas) return null;
    const r = Element.prototype.getBoundingClientRect.call(rotor);
    return {
      rotated: L.rotated, phone: L.phone, width: L.width, height: L.height,
      insets: [L.il, L.it, L.ir, L.ib],
      rect: { left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height },
      canvas: [canvas.width, canvas.height],
      canvasCss: [canvas.clientWidth, canvas.clientHeight],
      viewport: [window.innerWidth, window.innerHeight],
      dpr: window.devicePixelRatio,
    };
  });
}

async function checkLayout(page, opts, consoleLines, failures) {
  const L = await readLayout(page);
  if (!L) {
    failures.push('layout: no window.wbLayout (Godot\'s default shell? --portrait and --tap-play need platform/web/shell.html)');
    return;
  }
  console.log(`smoke: layout: ${L.rotated ? 'rotated' : 'not rotated'}, box ${L.width}x${L.height} CSS px, canvas ${L.canvas.join('x')} px ` +
    `(dpr ${L.dpr}), viewport ${L.viewport.join('x')}, box on the page ${Math.round(L.rect.width)}x${Math.round(L.rect.height)} at ` +
    `${Math.round(L.rect.left)},${Math.round(L.rect.top)}, phone ${L.phone}, insets ${L.insets.join(',')}`);
  const [vw, vh] = L.viewport;
  const near = (a, b) => Math.abs(a - b) <= 1;
  if (opts.expectRotated != null && L.rotated !== opts.expectRotated) {
    failures.push(`layout: expected ${opts.expectRotated ? 'a rotated' : 'an unrotated'} page, got ${L.rotated ? 'rotated' : 'unrotated'}`);
  }
  const wantBox = L.rotated ? [vh, vw] : [vw, vh];
  if (!near(L.width, wantBox[0]) || !near(L.height, wantBox[1])) failures.push(`layout: box ${L.width}x${L.height}, want ${wantBox.join('x')}`);
  if (!near(L.rect.left, 0) || !near(L.rect.top, 0) || !near(L.rect.width, vw) || !near(L.rect.height, vh)) {
    failures.push(`layout: the game box does not cover the viewport (${JSON.stringify(L.rect)})`);
  }
  if (L.width <= L.height) failures.push(`layout: the game box ${L.width}x${L.height} is not landscape`);
  const wantCanvas = [Math.round(L.width * L.dpr), Math.round(L.height * L.dpr)];
  if (!near(L.canvas[0], wantCanvas[0]) || !near(L.canvas[1], wantCanvas[1])) {
    failures.push(`layout: canvas ${L.canvas.join('x')} px, want ${wantCanvas.join('x')} (the box x the pixel ratio)`);
  }
  if (!consoleLines.some((l) => /^Westbound layout: (rotated|landscape) /.test(l))) failures.push('layout: the shell never logged its layout');
}

// The newest block of "wbui: button" lines (the game prints the whole list on a change).
function probeButtons(consoleLines, from) {
  let end = -1;
  for (let i = consoleLines.length - 1; i >= from; i--) {
    if (consoleLines[i].startsWith('wbui: button ')) { end = i; break; }
  }
  if (end < 0) return [];
  let start = end;
  while (start - 1 >= from && consoleLines[start - 1].startsWith('wbui: button ')) start--;
  const out = [];
  for (const line of consoleLines.slice(start, end + 1)) {
    const m = /^wbui: button (-?\d+) (-?\d+) (\d+) (\d+) canvas (\d+) (\d+) (.*)$/.exec(line);
    if (m) out.push({ x: +m[1], y: +m[2], w: +m[3], h: +m[4], cw: +m[5], ch: +m[6], text: m[7] });
  }
  return out;
}

// Taps the button labelled `text` (the newest probe list since console line `from`),
// through the shell's rotation. Returns false when the game never showed it.
async function tapButton(page, text, from, consoleLines, failures, ms) {
  const M = loadLayoutMath();
  const deadline = Date.now() + ms;
  let b = null;
  let seenAt = -1;
  // Wait for the button, then for its list to hold still (the title's intro animates).
  while (Date.now() < deadline && !failures.length) {
    const list = probeButtons(consoleLines, from);
    const hit = list.find((x) => x.text === text) || null;
    if (hit && (!b || hit.x !== b.x || hit.y !== b.y)) { b = hit; seenAt = Date.now(); }
    if (b && Date.now() - seenAt > 1500) break;
    await page.waitForTimeout(250);
  }
  if (!b) return false;
  const L = await readLayout(page);
  const bx = ((b.x + b.w / 2) / b.cw) * L.width;
  const by = ((b.y + b.h / 2) / b.ch) * L.height;
  const [cx, cy] = M.toClient(bx, by, L.rect, L.rotated);
  await page.touchscreen.tap(cx, cy);
  console.log(`smoke: tapped ${text} at canvas (${Math.round(b.x + b.w / 2)}, ${Math.round(b.y + b.h / 2)}) of ${b.cw}x${b.ch} = ` +
    `page (${Math.round(cx)}, ${Math.round(cy)})${L.rotated ? ' (rotated)' : ''}`);
  return true;
}

// --tap-play: PLAY (then DRIVE on the first-run chooser) must start a run.
async function tapPlay(page, opts, consoleLines, failures) {
  const has = (re, from = 0) => consoleLines.slice(from).some((l) => re.test(l));
  const waitFor = async (re, ms, from = 0) => {
    const deadline = Date.now() + ms;
    while (!has(re, from) && Date.now() < deadline && !failures.length) await page.waitForTimeout(250);
    return has(re, from);
  };
  if (!(await waitFor(/^web boot: title /, opts.timeout))) {
    failures.push('tap play: the game never marked the title (web boot: title)');
    return;
  }
  const from = consoleLines.findIndex((l) => /^web boot: title /.test(l));
  if (!(await tapButton(page, 'PLAY', from, consoleLines, failures, 20000))) {
    failures.push('tap play: the game never listed a PLAY button (wbui: button ... PLAY; is ?probe=ui on?)');
    return;
  }
  const after = consoleLines.length;
  const stepMs = Math.min(opts.timeout, 30000);
  const deadline = Date.now() + stepMs;
  let chooser = false;
  while (Date.now() < deadline && !failures.length && !has(/^web boot: start /, after)) {
    if (probeButtons(consoleLines, after).some((x) => x.text === 'DRIVE')) { chooser = true; break; }
    await page.waitForTimeout(250);
  }
  if (chooser) {
    console.log('smoke: the first-run chooser opened (a fresh save): tapping DRIVE');
    await tapButton(page, 'DRIVE', after, consoleLines, failures, 10000);
  }
  if (!(await waitFor(/^web boot: start /, stepMs, after))) {
    failures.push(`tap play: no run started after the tap${chooser ? ' on DRIVE' : ' on PLAY'} ("web boot: start")`);
    return;
  }
  console.log('smoke: the tap on PLAY started a run');
}
