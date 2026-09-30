#!/usr/bin/env node
// Compares two Daily Drive determinism traces (WP8.4; docs/DAILY.md → Determinism check):
// the "DT ..." lines DailyTrace prints natively (tools/determinism/daily_trace.gd) and in
// the web build (`?determinism=daily`, captured by tools/web_smoke/smoke.mjs --console-out).
//
//   node tools/determinism/compare.mjs native.log web.log [--names native,web]
//
// Prints: both runs' info lines, the libm probe (which math functions give different bits),
// how many seconds match from the start, the first diverging second and which state
// components differ there, and with per-tick detail lines (DTT, --detail=<second>) the first
// diverging tick with the car's float bits on both sides.
// Exit: 0 all seconds match, 1 diverged, 2 missing or unreadable traces.
import fs from 'node:fs';

const args = process.argv.slice(2);
const files = args.filter((a) => !a.startsWith('--'));
let names = ['native', 'web'];
for (const a of args) if (a.startsWith('--names=')) names = a.slice('--names='.length).split(',');
if (files.length !== 2) {
  console.error('usage: node tools/determinism/compare.mjs <a.log> <b.log> [--names=a,b]');
  process.exit(2);
}

// "key=value key2=value2" -> {key: value}; values may not contain spaces.
function fields(line) {
  const out = {};
  for (const part of line.split(/\s+/)) {
    const eq = part.indexOf('=');
    if (eq > 0) out[part.slice(0, eq)] = part.slice(eq + 1);
  }
  return out;
}

function parse(file) {
  const text = fs.readFileSync(file, 'utf8');
  const t = { info: null, libm: null, params: null, secs: new Map(), ticks: new Map(), done: false };
  for (const raw of text.split(/\r?\n/)) {
    // Console captures may prefix lines; find the marker.
    const i = raw.search(/\bDTT? /);
    if (i < 0) continue;
    const line = raw.slice(i).trim();
    if (line.startsWith('DT info ')) t.info = fields(line);
    else if (line.startsWith('DT libm ')) t.libm = fields(line);
    else if (line.startsWith('DT params ')) t.params = fields(line);
    else if (line.startsWith('DT sec=')) { const f = fields(line); t.secs.set(Number(f.sec), f); }
    else if (line.startsWith('DTT ')) { const f = fields(line); t.ticks.set(Number(f.k), f); }
    else if (line.startsWith('DT done')) t.done = true;
  }
  return t;
}

const [a, b] = files.map((f) => {
  try { return parse(f); } catch (e) { console.error(`compare: cannot read ${f}: ${e.message}`); process.exit(2); }
});
for (const [t, n, f] of [[a, names[0], files[0]], [b, names[1], files[1]]]) {
  if (!t.info || t.secs.size === 0) {
    console.error(`compare: ${n} (${f}) has no trace (no "DT info" / "DT sec=" lines)`);
    process.exit(2);
  }
}

const COMPONENTS = ['car', 'input', 'traffic', 'opp', 'scoring', 'lives', 'legs', 'obj', 'sun', 'forks', 'stats'];
const pad = (s, n) => String(s).padEnd(n);

console.log('## Runs');
for (const key of ['date', 'seed', 'driver', 'view_m', 'view_m_device', 'tier', 'platform', 'hz', 'build', 'params']) {
  const same = a.info[key] === b.info[key] ? '' : '  <- differs';
  console.log(`  ${pad(key, 14)} ${pad(names[0] + '=' + a.info[key], 34)} ${names[1]}=${b.info[key]}${same}`);
}
if (a.info.seed !== b.info.seed) console.log('  WARNING: different seeds: the traces cannot match (different dates?)');

if (a.params && b.params) {
  const diff = Object.keys(a.params).filter((k) => a.params[k] !== b.params[k]);
  console.log(`\n## Car physics constants (VehicleParams, built at load time)`);
  console.log(diff.length ? `  ${diff.length} of ${Object.keys(a.params).length} differ: ${diff.join(', ')}`
    : `  all ${Object.keys(a.params).length} identical`);
}

console.log('\n## libm probe (fixed inputs per function; hash of the exact result bits)');
const libmDiff = [];
if (a.libm && b.libm) {
  console.log(`  ${pad('fn', 6)} ${pad('exact', 10)} ${pad('low 8 bits masked', 18)} blocks of ${a.libm.chunk} inputs that differ`);
  for (const k of Object.keys(a.libm)) {
    if (['n', 'chunk'].includes(k) || k.includes('_')) continue;
    const same = a.libm[k] === b.libm[k];
    if (!same) libmDiff.push(k);
    const m = a.libm[`${k}_masked`] === b.libm[`${k}_masked`] ? 'same' : 'DIFFERENT';
    const ca = a.libm[`${k}_chunks`] || '';
    const cb = b.libm[`${k}_chunks`] || '';
    let blocks = 0;
    for (let i = 0; i < Math.min(ca.length, cb.length); i += 2) if (ca.slice(i, i + 2) !== cb.slice(i, i + 2)) blocks++;
    console.log(`  ${pad(k, 6)} ${pad(same ? 'same' : 'DIFFERENT', 10)} ${pad(m, 18)} ${blocks} / ${ca.length / 2}`);
  }
} else {
  console.log('  (missing on one side)');
}

const n = Math.min(a.secs.size, b.secs.size);
let matched = 0;
let first = -1;
let totalSame = 0;
for (let s = 1; s <= n; s++) {
  const x = a.secs.get(s);
  const y = b.secs.get(s);
  if (!x || !y) break;
  if (x.all === y.all) {
    totalSame++;
    if (first < 0) matched = s;
  } else if (first < 0) {
    first = s;
  }
}

console.log('\n## Trace');
console.log(`  seconds compared:            ${n} (${names[0]} ${a.secs.size}, ${names[1]} ${b.secs.size}${a.done && b.done ? '' : ', a run did not finish'})`);
console.log(`  matching from the start:     ${matched} s`);
console.log(`  matching seconds in total:   ${totalSame} / ${n}`);
{
  const x = a.secs.get(n);
  const y = b.secs.get(n);
  if (x && y && x.score !== undefined) {
    const same = x.score === y.score && x.hits === y.hits && x.cars === y.cars ? 'same' : 'DIFFERENT';
    console.log(`  at second ${n}:  ${names[0]} score=${x.score} hits=${x.hits} cars=${x.cars} s=${x.s}; ${names[1]} score=${y.score} hits=${y.hits} cars=${y.cars} s=${y.s} (${same})`);
  }
}
if (first < 0) {
  console.log('  first divergence:            none');
} else {
  const x = a.secs.get(first);
  const y = b.secs.get(first);
  const diff = COMPONENTS.filter((c) => x[c] !== y[c]);
  console.log(`  first divergence:            second ${first}: ${diff.join(', ') || 'all (components equal?)'}`);
  console.log(`    ${names[0]}: s=${x.s} d=${x.d} v=${x.v} cars=${x.cars}`);
  console.log(`    ${names[1]}: s=${y.s} d=${y.d} v=${y.v} cars=${y.cars}`);
  // Where each component first differs (the order hints at the cause).
  const firstBy = {};
  for (let s = 1; s <= n; s++) {
    const p = a.secs.get(s);
    const q = b.secs.get(s);
    if (!p || !q) break;
    for (const c of COMPONENTS) if (firstBy[c] === undefined && p[c] !== q[c]) firstBy[c] = s;
  }
  console.log('    each component first differs at second: ' +
    COMPONENTS.map((c) => `${c}=${firstBy[c] ?? '-'}`).join(' '));
}

if (a.ticks.size && b.ticks.size) {
  console.log('\n## Per-tick detail');
  const ks = [...a.ticks.keys()].filter((k) => b.ticks.has(k)).sort((p, q) => p - q);
  let tick = -1;
  for (const k of ks) if (a.ticks.get(k).all !== b.ticks.get(k).all) { tick = k; break; }
  if (tick < 0) {
    console.log(`  ticks ${ks[0]}..${ks[ks.length - 1]}: all equal`);
  } else {
    const x = a.ticks.get(tick);
    const y = b.ticks.get(tick);
    const diff = COMPONENTS.filter((c) => x[c] !== y[c]);
    console.log(`  first diverging tick: k=${tick} (components: ${diff.join(', ')})`);
    for (const key of ['s', 'd', 'yaw', 'v', 'vlat', 'steer']) {
      const mark = x[key] === y[key] ? '' : '  <- differs';
      console.log(`    ${pad(key, 6)} ${pad(x[key], 40)} ${y[key]}${mark}`);
    }
    // The tick before: identical state on both sides; the libm results the next physics
    // step takes from it (lcos, lsin, lexp, ltan). One that differs is the cause.
    const px = a.ticks.get(tick - 1);
    const py = b.ticks.get(tick - 1);
    if (px && py) {
      console.log(`  the tick before (k=${tick - 1}, state ${px.all === py.all ? 'identical' : 'different'}): libm results the next step uses`);
      for (const key of ['lcos', 'lsin', 'lexp', 'ltan', 'lwob']) {
        if (px[key] === undefined) continue;
        const mark = px[key] === py[key] ? '' : '  <- differs: the cause';
        console.log(`    ${pad(key, 6)} ${pad(px[key], 40)} ${py[key]}${mark}`);
      }
    }
  }
}

console.log('\n## Verdict');
const complete = a.secs.size === b.secs.size && a.done && b.done;
const libmNote = libmDiff.length ? ` (libm differs: ${libmDiff.join(', ')})` : ' (libm probe identical)';
if (first < 0 && complete) {
  console.log(`  IDENTICAL: ${n} s of the ${a.info.date} Daily Drive match bit for bit (${names[0]} vs ${names[1]})${libmNote}.`);
  process.exit(0);
}
if (first < 0) {
  console.log(`  INCOMPLETE: the ${n} s both runs have match, but the runs differ in length${libmNote}.`);
  process.exit(1);
}
console.log(`  DIVERGED at second ${first} (${matched} s matched)${libmNote}.`);
process.exit(1);
