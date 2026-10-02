// WP9.9 (docs/WEB.md → Slim engine): run tools/web_template/web_probe.gd inside a web
// engine in headless Chromium and save its console.
//
//   node tools/web_template/probe.mjs --dir DIR --out LOG [--timeout 180000]
//        [--names --screenshot PNG] [--net http://127.0.0.1:8080]
//
// --names runs tools/web_template/web_names.gd instead (player names in the game's theme)
// and saves a screenshot of it; --net runs web_net.gd (HTTP + WebSocket echo against a
// local westbound-server).
//
// DIR holds an unzipped web template (godot.js, godot.wasm, the audio worklets) and the
// game's index.pck (and music/*.pck, if the export made them). Export templates ignore
// `--script`, so the page preloads the probe, a scene holding it and an override.cfg
// next to index.pck that makes that scene the main scene: the game's pack and autoloads
// load, its own main scene never runs. Uses the Playwright install of tools/web_smoke
// (npm ci there once).
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(path.join(here, '../web_smoke/package.json'));
const { chromium } = require('playwright');

const opts = { dir: '', out: '', timeout: 180000, names: false, screenshot: '', net: '' };
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const v = () => argv[++i];
  switch (argv[i]) {
    case '--dir': opts.dir = path.resolve(v()); break;
    case '--out': opts.out = path.resolve(v()); break;
    case '--timeout': opts.timeout = Number(v()); break;
    case '--names': opts.names = true; break;
    case '--net': opts.net = v(); break;
    case '--screenshot': opts.screenshot = path.resolve(v()); break;
    default: console.error(`probe: unknown argument ${argv[i]}`); process.exit(2);
  }
}
if (!opts.dir || !opts.out) {
  console.error('usage: node tools/web_template/probe.mjs --dir DIR --out LOG [--timeout MS]');
  process.exit(2);
}

const mode = opts.names ? 'names' : opts.net ? 'net' : 'load';
const musicDir = path.join(opts.dir, 'music');
const musicPacks = mode === 'load' && fs.existsSync(musicDir) ? fs.readdirSync(musicDir).filter((f) => f.endsWith('.pck')).sort() : [];
const script = { load: 'web_probe.gd', names: 'web_names.gd', net: 'web_net.gd' }[mode];
const doneRe = { load: /^PROBE done files/, names: /^PROBE done text/, net: /^PROBE done net/ }[mode];
const PAGE = `<!doctype html><html><head><meta charset="utf-8"></head>
<body style="margin:0;background:#000"><canvas id="canvas" width="1280" height="720"></canvas>
<script>
// The wasm memory, for the heap size at the end (PROBE heap).
const wbInst = WebAssembly.instantiate;
WebAssembly.instantiate = async (...a) => { const r = await wbInst(...a); window.wbMem = (r.instance || r).exports; return r; };
const wbStream = WebAssembly.instantiateStreaming;
WebAssembly.instantiateStreaming = async (...a) => { const r = await wbStream(...a); window.wbMem = r.instance.exports; return r; };
</script>
<script src="godot.js"></script>
<script>
const engine = new Engine({ executable: 'godot', mainPack: 'index.pck', canvasResizePolicy: 0,
  canvas: document.getElementById('canvas') });
const files = [engine.preloadFile('${script}', '/tmp/${script}'),
  engine.preloadFile('probe.tscn', '/tmp/probe.tscn'), engine.preloadFile('override.cfg', 'override.cfg')];
${musicPacks.map((f) => `files.push(engine.preloadFile('music/${f}', '/tmp/music/${f}'));`).join('\n')}
Promise.all(files).then(() => engine.startGame()).catch((e) => console.error('PROBE start failed: ' + e));
</script></body></html>`;

const INLINE = {
  '/override.cfg': '[application]\n\nrun/main_scene="/tmp/probe.tscn"\n',
  '/probe.tscn': `[gd_scene load_steps=2 format=3]\n\n[ext_resource type="Script" path="/tmp/${script}" id="1"]\n\n`
    + `[node name="WebProbe" type="${opts.names ? 'Control' : 'Node'}"]\nscript = ExtResource("1")\n`,
};
const MIME = { '.js': 'text/javascript', '.wasm': 'application/wasm', '.html': 'text/html', '.pck': 'application/octet-stream' };
const server = http.createServer((req, res) => {
  const rel = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
  if (rel === '/' || rel === '/probe.html') {
    res.writeHead(200, { 'Content-Type': 'text/html' }).end(PAGE);
    return;
  }
  if (INLINE[rel]) {
    res.writeHead(200, { 'Content-Type': 'text/plain' }).end(INLINE[rel]);
    return;
  }
  const file = rel === `/${script}` ? path.join(here, script) : path.resolve(opts.dir, '.' + rel);
  if (!fs.existsSync(file) || !fs.statSync(file).isFile()) {
    res.writeHead(404).end('not found');
    return;
  }
  res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream' });
  fs.createReadStream(file).pipe(res);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const url = `http://127.0.0.1:${server.address().port}/probe.html?server=off${opts.net ? '&probe_server=' + encodeURIComponent(opts.net) : ''}`;

const browser = await chromium.launch({
  headless: true,
  args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'],
  ...(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {}),
});
const lines = [];
let done = false;
let resolveDone;
const finished = new Promise((r) => { resolveDone = r; });
const page = await browser.newPage();
page.on('console', (m) => {
  const t = m.type() === 'error' ? `console.error: ${m.text()}` : m.text();
  lines.push(t);
  if (doneRe.test(m.text())) { done = true; resolveDone(); }
});
page.on('pageerror', (e) => lines.push(`pageerror: ${e.message}`));
const t0 = Date.now();
await page.goto(url);
await Promise.race([finished, new Promise((r) => setTimeout(r, opts.timeout))]);
if (done) {
  const heap = await page.evaluate(() => {
    const ex = window.wbMem || {};
    const mem = Object.values(ex).find((v) => v instanceof WebAssembly.Memory);
    return mem ? mem.buffer.byteLength : 0;
  });
  lines.push(`PROBE heap ${heap}`);
}
if (done && opts.screenshot) {
  await page.waitForTimeout(3000);   // a few frames after the labels went up
  fs.mkdirSync(path.dirname(opts.screenshot), { recursive: true });
  await page.locator('#canvas').screenshot({ path: opts.screenshot });
}
await browser.close();
server.close();
fs.mkdirSync(path.dirname(opts.out), { recursive: true });
fs.writeFileSync(opts.out, lines.join('\n') + '\n');
const summary = lines.find((l) => doneRe.test(l)) || 'no PROBE done line';
const heapLine = lines.find((l) => l.startsWith('PROBE heap ')) || 'PROBE heap 0';
console.log(`probe: ${path.basename(opts.dir)}: ${summary}, wasm heap ${(Number(heapLine.split(' ')[2]) / 1048576).toFixed(2)} MiB (${((Date.now() - t0) / 1000).toFixed(1)} s) -> ${opts.out}`);
process.exit(done ? 0 : 1);
