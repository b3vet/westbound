#!/usr/bin/env node
// Unit test of the web shell's landscape-only math (WP9.7, docs/WEB.md → Landscape only):
// runs the <wb-layout-math> block of platform/web/shell.html in node (no browser) and
// checks the rotation decision, the box, the client → box coordinate mapping (and its
// inverse), movements and the inset mapping, plus what the engine then computes from a
// rewritten event (Godot 4.7's GodotInput.computePosition with the box's own rect).
//
//   node tools/web_smoke/layout_test.mjs        (smoke.mjs runs it first, too)
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

export function loadLayoutMath(shellPath = path.join(repoRoot, 'platform', 'web', 'shell.html')) {
  const src = fs.readFileSync(shellPath, 'utf8');
  const m = /\/\/ <wb-layout-math>[^\n]*\n([\s\S]*?)\/\/ <\/wb-layout-math>/.exec(src);
  if (!m) throw new Error(`${shellPath}: no <wb-layout-math> block`);
  return new Function(`${m[1]}\nreturn WBLayoutMath;`)();
}

// Godot 4.7 web: GodotInput.computePosition (platform/web/js/libs/library_godot_input.js).
function computePosition(evt, rect, canvas) {
  const rw = canvas.width / rect.width;
  const rh = canvas.height / rect.height;
  return [(evt.clientX - rect.x) * rw, (evt.clientY - rect.y) * rh];
}

export function runLayoutTests(M = loadLayoutMath()) {
  const failures = [];
  const eq = (got, want, what) => {
    const ok = Array.isArray(want)
      ? Array.isArray(got) && got.length === want.length && got.every((v, i) => Math.abs(v - want[i]) < 1e-9)
      : got === want;
    if (!ok) failures.push(`${what}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
  };

  // Rotation: touch + portrait only; ?rotate=0 never, ?rotate=1 also without touch.
  eq(M.shouldRotate(true, 390, 664, null), true, 'portrait phone rotates');
  eq(M.shouldRotate(true, 844, 340, null), false, 'landscape phone does not');
  eq(M.shouldRotate(false, 390, 664, null), false, 'portrait desktop window does not');
  eq(M.shouldRotate(true, 390, 664, false), false, '?rotate=0');
  eq(M.shouldRotate(false, 390, 664, true), true, '?rotate=1 on a desktop portrait window');
  eq(M.shouldRotate(false, 1280, 720, true), false, '?rotate=1 on a landscape window');
  eq(M.force('?server=off&rotate=0'), false, 'force 0');
  eq(M.force('?rotate=1'), true, 'force 1');
  eq(M.force('?server=off'), null, 'no force');

  // The box and the transform.
  eq(M.box(390, 664, true), [664, 390], 'rotated box is the viewport turned');
  eq(M.box(844, 340, false), [844, 340], 'landscape box is the viewport');
  eq(M.transform(390, true), 'translate(390px, 0px) rotate(90deg)', 'transform');
  eq(M.transform(390, false), '', 'no transform');

  // Client → box on a 390 × 664 portrait viewport (the box covers it: rect 0,0 → 390,664).
  const r = { left: 0, top: 0, right: 390, bottom: 664 };
  eq(M.toBox(390, 0, r, true), [0, 0], "box top-left = the page's top-right corner");
  eq(M.toBox(0, 0, r, true), [0, 390], "box bottom-left = the page's top-left corner (the phone's top is the player's left)");
  eq(M.toBox(0, 664, r, true), [664, 390], "box bottom-right = the page's bottom-left corner");
  eq(M.toBox(100, 200, r, true), [200, 290], 'a point');
  eq(M.toBox(100, 200, { left: 10, top: 20, right: 400, bottom: 684 }, false), [90, 180], 'unrotated: offset only');
  // Offset box (a visual viewport offset) and the round trip.
  const r2 = { left: 5, top: 7, right: 395, bottom: 671 };
  for (const p of [[0, 0], [663, 389], [123.5, 45.25]]) {
    eq(M.toBox(...M.toClient(p[0], p[1], r2, true), r2, true), p, `round trip ${p}`);
    eq(M.toBox(...M.toClient(p[0], p[1], r2, false), r2, false), p, `round trip unrotated ${p}`);
  }
  // Movements: a finger moving down the portrait page moves right in the box; moving
  // right on the page moves up in the box.
  eq(M.deltaToBox(0, 10, true), [10, -0], 'down the page = right in the box');
  eq(M.deltaToBox(10, 0, true), [0, -10], 'right on the page = up in the box');
  eq(M.deltaToBox(3, 4, false), [3, 4], 'unrotated movement');

  // Insets: the portrait top (the camera) becomes the box's left, the portrait bottom
  // (home indicator) its right.
  eq(M.insetsToBox([0, 59, 0, 34], true), [59, 0, 34, 0], 'rotated insets');
  eq(M.insetsToBox([59, 0, 59, 21], false), [59, 0, 59, 21], 'landscape insets unchanged');

  // What the engine computes from a rewritten event: the canvas' rect is the box's own
  // (0, 0, 664, 390), the backing store the box × dpr 3; a tap on the page at (100, 200)
  // must land on canvas pixel (200, 290) × 3.
  const canvas = { width: 664 * 3, height: 390 * 3 };
  const box = { x: 0, y: 0, width: 664, height: 390 };
  const [bx, by] = M.toBox(100, 200, r, true);
  eq(computePosition({ clientX: bx, clientY: by }, box, canvas), [600, 870], 'engine canvas pixel');
  return failures;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const failures = runLayoutTests();
  if (failures.length) {
    console.error(`layout_test: FAIL (${failures.length})`);
    for (const f of failures) console.error(`  - ${f}`);
    process.exit(1);
  }
  console.log('layout_test: PASS');
}
