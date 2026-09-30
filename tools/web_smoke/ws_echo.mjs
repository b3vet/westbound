#!/usr/bin/env node
// WebSocket echo check from a browser page (multiplayer N0 gate, docs/SERVER.md):
// serves a blank page from its own http://127.0.0.1 origin (standing in for the
// web build's origin), opens it in headless Chromium, then from the page
//   1. fetches <server>/api/v1/health cross-origin (CORS),
//   2. opens <server>/ws, sends a binary and a text message and expects both echoed.
// Prints "WS_ECHO ok ..." and exits 0, or "WS_ECHO FAIL <reason>" and exits 1.
//
//   node tools/web_smoke/ws_echo.mjs [--server https://localhost:8443] [--insecure]
//        [--timeout 15000] [--headed]
//
// --insecure launches Chromium with --ignore-certificate-errors, for the local
// Caddy `tls internal` certificate. Needs `npm ci` in tools/web_smoke once; the
// browser is found like smoke.mjs does (CHROMIUM_PATH, Playwright's cache).
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { chromium } from 'playwright';

function parseArgs(argv) {
  const opts = { server: 'https://localhost:8443', insecure: false, timeout: 15000, headed: false };
  for (let i = 0; i < argv.length; i++) {
    const [flag, inline] = argv[i].split(/=(.*)/s, 2);
    const value = () => (inline !== undefined ? inline : argv[++i]);
    switch (flag) {
      case '--server': opts.server = value().replace(/\/+$/, ''); break;
      case '--insecure': opts.insecure = true; break;
      case '--timeout': opts.timeout = Number(value()); break;
      case '--headed': opts.headed = true; break;
      case '-h': case '--help':
        console.log('usage: node tools/web_smoke/ws_echo.mjs [--server https://localhost:8443] [--insecure] [--timeout 15000] [--headed]');
        process.exit(0);
      default:
        console.error(`ws_echo: unknown argument ${argv[i]}`);
        process.exit(2);
    }
  }
  if (!/^https?:\/\//.test(opts.server) || !Number.isFinite(opts.timeout)) {
    console.error('ws_echo: --server takes an http(s) origin, --timeout milliseconds');
    process.exit(2);
  }
  return opts;
}

function findInstalledChromium(headed) {
  const roots = [process.env.PLAYWRIGHT_BROWSERS_PATH, path.join(process.env.HOME || '', '.cache', 'ms-playwright')]
    .filter((p) => p && fs.existsSync(p));
  for (const root of roots) {
    for (const entry of fs.readdirSync(root).sort().reverse()) {
      const candidate = !headed && entry.startsWith('chromium_headless_shell-')
        ? path.join(root, entry, 'chrome-linux', 'headless_shell')
        : entry.startsWith('chromium-') ? path.join(root, entry, 'chrome-linux', 'chrome') : null;
      if (candidate && fs.existsSync(candidate)) return candidate;
    }
  }
  return undefined;
}

async function launch(opts) {
  const base = { headless: !opts.headed, args: opts.insecure ? ['--ignore-certificate-errors'] : [] };
  if (process.env.CHROMIUM_PATH) return chromium.launch({ ...base, executablePath: process.env.CHROMIUM_PATH });
  try {
    return await chromium.launch(base);
  } catch (err) {
    const fallback = findInstalledChromium(opts.headed);
    if (!/Executable doesn't exist/.test(String(err)) || !fallback) throw err;
    return chromium.launch({ ...base, executablePath: fallback });
  }
}

// Runs in the page.
async function echoInPage({ server, timeout }) {
  const health = await fetch(`${server}/api/v1/health`, { cache: 'no-store' }).then((r) => r.json());
  if (health.status !== 'ok') throw new Error(`health: ${JSON.stringify(health)}`);
  const wsUrl = server.replace(/^http/, 'ws') + '/ws/echo';
  const payload = new Uint8Array(1024).map((_, i) => (i * 31 + 7) % 256);
  const text = 'westbound web echo';
  return await new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    ws.binaryType = 'arraybuffer';
    const timer = setTimeout(() => reject(new Error(`timeout (readyState ${ws.readyState})`)), timeout);
    let t0 = 0;
    let gotBinary = false;
    ws.onopen = () => {
      t0 = performance.now();
      ws.send(payload);
      ws.send(text);
    };
    ws.onerror = () => reject(new Error('websocket error'));
    ws.onclose = (e) => reject(new Error(`closed early (code ${e.code})`));
    ws.onmessage = (e) => {
      if (e.data instanceof ArrayBuffer) {
        const back = new Uint8Array(e.data);
        if (back.length !== payload.length || back.some((b, i) => b !== payload[i])) {
          reject(new Error(`binary echo differs (${back.length} bytes)`));
          return;
        }
        gotBinary = true;
      } else if (e.data === text && gotBinary) {
        clearTimeout(timer);
        ws.onclose = null;
        ws.close(1000);
        resolve({ url: wsUrl, rttMs: Math.round(performance.now() - t0), health });
      } else {
        reject(new Error(`unexpected message ${String(e.data).slice(0, 80)}`));
      }
    };
  });
}

const opts = parseArgs(process.argv.slice(2));
const page_server = http.createServer((_req, res) => {
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
  res.end('<!doctype html><title>ws_echo</title><p>ws_echo');
});
await new Promise((r) => page_server.listen(0, '127.0.0.1', r));
const pageUrl = `http://127.0.0.1:${page_server.address().port}/`;

let browser;
let code = 1;
try {
  browser = await launch(opts);
  const page = await browser.newPage();
  await page.goto(pageUrl);
  const r = await page.evaluate(echoInPage, { server: opts.server, timeout: opts.timeout });
  console.log(`WS_ECHO ok ${r.url} from ${pageUrl} rtt_ms=${r.rttMs} server=${r.health.version} (${r.health.build}) db=${r.health.db}`);
  code = 0;
} catch (err) {
  console.log(`WS_ECHO FAIL ${opts.server}: ${err.message || err}`);
} finally {
  if (browser) await browser.close();
  page_server.close();
}
process.exit(code);
