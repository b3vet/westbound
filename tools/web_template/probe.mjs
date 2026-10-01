// WP9.9 (docs/WEB.md → Slim engine): run tools/web_template/web_probe.gd inside a web
// engine in headless Chromium and save its console.
//
//   node tools/web_template/probe.mjs --dir DIR --out LOG [--timeout 180000]
//        [--names --screenshot PNG]
//
// --names runs tools/web_template/web_names.gd instead (player names in the game's theme)
// and saves a screenshot of it.
//
// DIR holds an unzipped web template (godot.js, godot.wasm, the audio worklets) and the
// game's index.pck (and music.pck, if the export made one). Export templates ignore
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

const opts = { dir: '', out: '', timeout: 180000, names: false, screenshot: '' };
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const v = () => argv[++i];
  switch (argv[i]) {
    case '--dir': opts.dir = path.resolve(v()); break;
    case '--out': opts.out = path.resolve(v()); break;
    case '--timeout': opts.timeout = Number(v()); break;
    case '--names': opts.names = true; break;
    case '--screenshot': opts.screenshot = path.resolve(v()); break;
    default: console.error(`probe: unknown argument ${argv[i]}`); process.exit(2);
  }
}
if (!opts.dir || !opts.out) {
  console.error('usage: node tools/web_template/probe.mjs --dir DIR --out LOG [--timeout MS]');
  process.exit(2);
}

const hasMusic = !opts.names && fs.existsSync(path.join(opts.dir, 'music.pck'));
const script = opts.names ? 'web_names.gd' : 'web_probe.gd';
const doneRe = opts.names ? /^PROBE done text/ : /^PROBE done /;
const PAGE = `<!doctype html><html><head><meta charset="utf-8"></head>
<body style="margin:0;background:#000"><canvas id="canvas" width="1280" height="720"></canvas>
<script src="godot.js"></script>
<script>
const engine = new Engine({ executable: 'godot', mainPack: 'index.pck', canvasResizePolicy: 0,
  canvas: document.getElementById('canvas') });
const files = [engine.preloadFile('${script}', '/tmp/${script}'),
  engine.preloadFile('probe.tscn', '/tmp/probe.tscn'), engine.preloadFile('override.cfg', 'override.cfg')];
${hasMusic ? "files.push(engine.preloadFile('music.pck', '/tmp/music.pck'));" : ''}
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
const url = `http://127.0.0.1:${server.address().port}/probe.html?server=off`;

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
console.log(`probe: ${path.basename(opts.dir)}: ${summary} (${((Date.now() - t0) / 1000).toFixed(1)} s) -> ${opts.out}`);
process.exit(done ? 0 : 1);
