# Web build

WP9.2 (plan Phase 9: "web build polish (gyro decision, load time)"). Spec: *Platform* (web export second; Compatibility renderer, single-threaded), *Audio*, *Controls → Gyro steering* ("Web build"). The web build on GitHub Pages is the owner's everyday playtest path (plan D4), so this page covers what a phone downloads, how fast it gets to the title, how audio starts, how a new deploy reaches the phone, and how to measure all of it.

## Files

| File | What it does |
| --- | --- |
| `platform/web/shell.html` | The custom HTML shell: the loading screen, versioned downloads, the stale-page check, the AudioContext hook, and (WP9.7) the landscape-only layout: a portrait page rotated to landscape, input remapped, the canvas sized, the safe-area insets for the game ([Landscape only](#landscape-only)). Set as `html/custom_html_shell` in the Web preset. |
| `platform/web/wordmark.woff`, `make_font.py` | Chakra Petch Bold cut down to A–Z, digits and a few signs (3.6 KB) for the loading screen; `make_font.py` rebuilds it (fontTools). |
| `platform/web/pack_music.gd` | Writes `music.pck` (the music tracks as their own pack). |
| `platform/web/.gdignore` | Keeps the directory out of Godot's import and out of `index.pck`. |
| `src/platform/web_audio_unlock.gd` (`WebAudioUnlock`) | Pure state machine: is the page's audio still locked? |
| `src/platform/web_audio_bridge.gd` (`WebAudioBridge`) | The page side: finds the engine's AudioContext, resumes it inside gestures, reports its state. |
| `src/platform/web_audio.gd` (`WebAudio`) | The node: polls the bridge, holds the music until the unlock and the music pack, boot marks. `GameAudio` adds it on the web. |
| `src/platform/web_music_pack.gd` (`WebMusicPack`) | Fetches and mounts `music.pck` when the main pack leaves the music out. |
| `src/platform/web_boot.gd` (`WebBoot`) | Boot milestones (`window.wbBoot`, the `wb-boot` event, a console line): `title`, `run`, and `start` (the first run after the title, WP9.7). |
| `src/platform/web_layout.gd` (`WebLayout`) | WP9.7: reads the shell's `window.wbLayout` (rotated, phone, the landscape box, the page's safe-area insets). |
| `src/input/screen_insets.gd` (`ScreenInsets`) | WP9.7: the safe area in canvas px for the HUD, menus and touch controls (web insets rotated and scaled, the engine's safe area natively, the phone's minimum left inset). |
| `src/platform/web_ui_probe.gd` (`WebUiProbe`) | WP9.7: with `?probe=ui`, prints the visible menu buttons (canvas px) for the smoke test's tap on PLAY. |
| `tools/export_web.sh` | Exports, then writes `music.pck` (when needed), `version.json` and the shell's build id and font; prints the engine template used, sizes and the transfer to the title. `--template=auto\|slim\|official` (WP9.9, [Slim engine](#slim-engine)). |
| `tools/web_template/` | WP9.9: the slim engine template: `build.sh` (pinned build), `westbound.gdbuild` + `detect_classes.gd` (class profile and the check), `verify.sh` + `probe.mjs` + `web_probe.gd`, `web_names.gd`, `web_net.gd` (official vs slim in Chromium), `removed_classes.txt`, `ci_gate.sh` ([Slim engine](#slim-engine)). |
| `tools/web_smoke/smoke.mjs` | The headless-Chromium smoke test, plus timings, transfer, memory, the audio-unlock test, the caching checks and (WP9.7) phone emulation: `--portrait` / `--landscape` / `--device`, `--tap-play`. |
| `tools/web_smoke/layout_test.mjs` | WP9.7: the shell's rotation math in node (the smoke runs it first; `tests/platform/test_web_layout.gd` runs it when node is installed). |
| `tools/web_smoke/pck_list.py` | Lists a `.pck` by group and file, raw and gzip. |
| `tests/platform/test_web_audio.gd` | Unit tests: the unlock state machine, the music hold, the node, the `GameAudio` hook, the music pack. |

## Measuring

```
tools/export_web.sh                                           # sizes + "transfer" (gzip, to the title)
python3 tools/web_smoke/pck_list.py build/web/index.pck       # what is in the pack, by group
node tools/web_smoke/smoke.mjs --settle 8000 --gzip           # timings as Pages serves the files
node tools/web_smoke/smoke.mjs --gzip --network 4g --json build/web_metrics.json
node tools/web_smoke/smoke.mjs --settle 8000 --audio-unlock tap   # also: click, key
node tools/web_smoke/smoke.mjs --stale                        # custom shell: a stale page reloads once
node tools/web_smoke/smoke.mjs --portrait --dpr 1             # iPhone 14 portrait: rotated, a tap on PLAY starts a run
node tools/web_smoke/smoke.mjs --landscape --dpr 1            # iPhone 14 landscape: not rotated, the same tap
```

`--gzip` serves every file gzip-encoded, as GitHub Pages does (checked: Pages sends `content-encoding: gzip` for `.wasm`, `.pck`, `.js` and `.html`, never brotli, with `cache-control: max-age=600`). `--network` uses Chrome DevTools' throttling (`wifi` 30 Mbps / 20 ms, `4g` 9 Mbps / 60 ms, `slow4g` 1.6 Mbps / 150 ms, or `<Mbps>,<rtt ms>`). The timings are page times from navigation start:

| Timing | Source |
| --- | --- |
| first paint | the browser's first contentful paint |
| wasm + pck loaded | resource timing of `index.wasm` and `index.pck` |
| wasm compiled | the engine's `WebAssembly.instantiate` resolving |
| engine main() | Godot's banner line |
| first frame | the first WebGL draw call |
| title shown | the game's `web boot: title` mark (the first frame after the title was drawn); `run` for a direct boot |
| overlay gone | the loading screen removed |

Memory: the wasm heap (`WebAssembly.Memory`) and Chrome's JS heap after the settle. The smoke never calls `page.evaluate()` before its gesture in `--audio-unlock` mode (Playwright's evaluate counts as a user gesture); its probes report through console lines instead.

**Caveat.** Headless Chromium renders WebGL with SwiftShader on the CPU, on a shared 4-core machine. The network-bound numbers (bytes, download times under `--network`) are solid; everything after "wasm compiled" (engine start, world build, shaders) is CPU-bound and runs several times slower and noisier than on a phone. Repeat runs of the same build vary by ±3 s there. For a phone, `window.wbBoot` holds the marks (e.g. `javascript:alert(JSON.stringify(wbBoot))` from the address bar).

## Budgets and measurements

The spec gives no number for load time or pack size ("web build polish ... load time"), so these are proposed budgets for the everyday playtest on a phone: **first paint under 0.5 s**, **under 12 MiB (gzip) before the title**, **title within 10 s on 4G** (9 Mbps). The official engine alone is 9.7 MiB on the wire; the slim engine (WP9.9, [Slim engine](#slim-engine)) is 6.1 MiB and brings the transfer to the title to 9.4 MiB, inside the budget.

Measured on this branch (release export, gzip like Pages). "Before" is the committed preset (Godot's shell, music inside `index.pck`); "after" adds the two requested preset lines (custom shell, music as `music.pck`):

| | Before | After | Change |
| --- | --- | --- | --- |
| `index.wasm` (raw / gzip) | 37.7 / 9.7 MiB | 37.7 / 9.7 MiB | engine template, unchanged |
| `index.pck` (raw / gzip) | 8.6 / 6.6 MiB | 4.9 / 3.1 MiB | −3.5 MiB gzip |
| `music.pck` (gzip, after the title) | – | 3.5 MiB | loads in the background |
| Transfer to the title | **16.4 MiB** | **12.9 MiB** | **−21 %** |
| First paint | 10.0 s (unthrottled), 23.6 s (4G) | **0.16 s**, **0.12 s** | the loading screen paints at once (Godot's shell has nothing contentful until the canvas: an ink page and a thin native progress bar) |
| Boot downloads done, 4G | 16.8 s | **13.4 s** | −3.4 s |
| Boot downloads done, unthrottled local | 1.6 s | 1.9 s | noise |
| Title shown, 4G (SwiftShader) | 23.3 s | 21.9 s | one run each (with the earlier smooth sweep); the CPU part is noisy (see caveat) |
| Title shown, unthrottled (SwiftShader) | 8.4–13.3 s (6 runs) | 9.0–12.4 s (3 runs, final shell) | same within noise: nothing here touches the CPU-bound boot |
| Music playing | at the first gesture | at the first gesture, or when `music.pck` lands after it (4G: 25.4 s from navigation) | |
| Wasm heap after the title | 186 MiB | 186 MiB | |
| JS heap after the title (Chrome) | 215 MiB | 215 MiB | |

The "engine main() → first frame" stretch (the engine's setup, the run scene's `_ready`, the world build and shader compiles) is the other big block: about 5–8 s under SwiftShader. It is CPU work on the main thread, outside this WP's paths. A phone does it much faster; measure it there with `wbBoot`.

## Where the bytes go

`index.pck` before (1,099 files, 6.6 MiB gzip; `pck_list.py`):

| Group | gzip |
| --- | --- |
| music, 3 OGG tracks (58–73 kbps, 32 kHz stereo) | 3.72 MiB |
| scripts (`src/**`, compiled tokens; ui 486 KiB, traffic 357, net 310, road 267, ...) | ~2.2 MiB |
| car models (3 imported `.glb` scenes) | 452 KiB |
| one-shot WAVs | 93 KiB |
| fonts (2 × Chakra Petch) | 79 KiB |
| props, traffic meshes, shaders, tuning data, the rest | ~0.3 MiB |

Checked and left alone:

- **Test fixtures, tools, docs** are already excluded (`exclude_filter`), and `westbound-server/` has a `.gdignore`.
- **Dev scenes** (`*/dev/*`: previews, the sandbox, the drive scene) are ~0.2 MiB gzip. The sandbox and drive scene must stay in the web build (working rule 10); the preview-only scenes (~0.15 MiB, about 1 % of the transfer) are not worth the risk of a missed reference.
- **Textures and VRAM compression.** The pack holds no VRAM-compressed textures at all (the art is vertex-colored; one PNG and one SVG, under 2 KiB). Both `vram_texture_compression/for_desktop` and `for_mobile` are on, which would ship every VRAM texture twice (S3TC/BPTC for desktop WebGL, ETC2/ASTC for phones), but with no such textures it costs nothing. If textured art arrives (ART track), keep both: desktop Chrome lacks ETC2 and iOS Safari lacks S3TC.
- **Music bitrate.** The tracks are already Vorbis at about quality 0 and 32 kHz (58–73 kbps). Going lower (q −1, ~45 kbps) would save ~1 MiB with audible artifacts on synth music. Not done; moving the music out of the boot path (below) saves all 3.5 MiB of it instead.
- **Fonts.** Two full Chakra Petch weights, 79 KiB. Subsetting to Latin would save ~40 KiB but risks player names (nametags, friends) in other scripts. Not done.
- **Compression.** Pages sends gzip only (no brotli, and no precompressed files), so nothing to gain there.

## Music pack

The music is the biggest part of `index.pck`, and the page downloads the whole main pack before the engine starts. With the requested exclude filter (`assets/audio/music_*`), `tools/export_web.sh` finds no music in `index.pck` and runs `platform/web/pack_music.gd`, which writes `build/web/music.pck`: each track's imported stream and a remap-only `.import`, exactly as an export packs them (PCKPacker, same engine version).

At run time `WebAudio` hands the track list to `WebMusicPack.begin()` as the run boots:

1. Every track already loadable (native, or the music still in `index.pck`): done, nothing fetched.
2. Otherwise it fetches `music.pck?v=<build>` with an `HTTPRequest` (`accept_gzip = false`: the browser has already decoded Pages' gzip; `download_chunk_size` 1 MiB, one read per frame), writes it to `/tmp/wb_music.pck` in the page's memory file system (never `user://`, the save's IndexedDB), mounts it with `ProjectSettings.load_resource_pack` and checks the tracks.
3. The music is held until the pack is in; if the fetch fails the game runs without music and says why in the console (no engine error). `HTTPRequest.download_file` reported success but wrote no file in the 4.7 web build, so the body is written out by hand.

Nothing loads a track before its pack: `AudioBank` would `push_error` on a missing file. The smoke checks `web music: loaded 3 tracks` whenever the game says it is downloading.

## Loading screen

`platform/web/shell.html` replaces Godot's default shell (ink page, native progress bar at the bottom):

- The title's look from the first paint: ink background, the **WESTBOUND** wordmark (Chakra Petch Bold, speed-tilted, the logo's drop shadow) and **CHASE THE SUN** in the run-start accent, left-anchored where the title draws them, so the title replaces the loading screen in place.
- The status bottom-left: `LOADING 42%` and an accent bar from the engine's download progress.
- `STARTING` after the download, with a sweep across the bar. Compiling the engine and building the world block the page's main thread for seconds, which freezes Godot's shell with a full, motionless bar. The sweep is a transform-only CSS animation, which browsers run on the compositor, so it keeps moving. It moves in 6 steps per 1.2 s rather than smoothly: a smooth (60 fps) sweep made Chromium composite the whole page every frame, which under SwiftShader slowed the first-frame → title stretch from ~1.6 s to ~4 s (3 runs each); stepped, it measured the same as no animation.
- It fades out on the game's first title frame (`wb-boot` event from `WebBoot`) or when `startGame()` resolves, whichever comes first. Errors show in the same place (`#status-notice`).
- The font is inlined as base64 by `tools/export_web.sh` (4.8 KB, no extra request; `font-display: block` never flashes a fallback font).

Measured effect: first contentful paint 0.12–0.16 s instead of the canvas's first frame (10 s unthrottled, 24 s on 4G under SwiftShader), and no frozen stretch (Godot's shell showed a full static bar for 8.4 s unthrottled, 6.9 s on 4G, between the download and the title).

## Audio unlock

**Finding (headless Chromium, the browser's default autoplay policy).** The page's AudioContext starts `suspended`. Godot 4.7's web engine calls `resume()` from its own mouse, touch and key callbacks, which run inside the browser's event dispatch in the single-threaded build, so the first click, tap (on `touchend`: `touchstart` does not count as user activation and logs a warning) or non-modifier key already resumes it. Modifier keys and Esc do not count as user activation (HTML spec), so no page can unlock on them. What was missing:

1. **Music "started" silently.** `GameAudio` starts the music on the title, before any gesture. The player then "plays" into a suspended context while `MusicPlayer`'s fade-in runs on frame time, so by the unlock the fade is long over and the track comes in abruptly (and a future engine that keeps mixing while suspended would skip its start). Now `MusicPlayer.hold` defers the start: `WebAudio` holds it while the context is locked (and until the music pack is in) and releases it on the unlock, so the music starts on the first gesture from the top with its fade-in.
2. **Gestures the engine never sees.** `WebAudioBridge` adds capture-phase listeners on `window` for the activating events (`pointerup`, `touchend`, `mousedown`, `keydown`, `click`): they call `resume()` and start a one-sample silent buffer (older iOS unlocks only on a sound started in a gesture). They act only while `navigator.userActivation.isActive`, so the browser never logs "not allowed to start". They cover a tap on an HTML overlay or a key while the canvas lacks focus.
3. **Finding the context.** The custom shell records it (`window.wbAudioCtx`) when the engine creates it; without the shell the bridge reaches the engine's own `GodotAudio.ctx` by evaluating in the engine's scope (`JavaScriptBridge.eval(code, false)`). With neither, it falls back to `navigator.userActivation.hasBeenActive`, and with no information at all it never holds the music.

`WebAudioUnlock` (pure): `UNKNOWN → LOCKED` (suspended or iOS `interrupted` at boot) `→ UNLOCKED` (running, or closed: never hold forever); a context that is already running needs nothing; a later suspension (iOS interrupts a hidden tab) is `RELOCKED → RESUMED` and never holds the playing music. The node polls every 0.1 s while locked and every 1 s after.

**Tests.** `tests/platform/test_web_audio.gd` (15 tests: the state machine, the hold, the node with a scripted bridge, the `GameAudio` hook, native unchanged, the music pack mounting a real `.pck`). `smoke.mjs --audio-unlock click|tap|key` launches Chromium with its default autoplay policy, checks the context is `suspended` and the game says `web audio: locked`, taps an empty part of the title, and requires the context `running`, `web audio: unlocked` and the music playing. All three gestures pass with both shells.

iOS note: Web Audio on iOS follows the ring/silent switch (like native Godot's default *ambient* session). Safari 17's `navigator.audioSession.type = 'playback'` would play through the silent switch; left alone to match native.

## Landscape only

WP9.7 (owner request). Westbound only plays in landscape. On a phone's browser in portrait, Safari's toolbars take much of the screen when the phone is turned, so instead of asking the player to turn the phone, the page itself turns the game: a phone locked in portrait (or just held upright) shows the game rotated a quarter turn and the player holds it sideways as usual. Same approach as the owner's cool_drive (`src/main.js` `applyLayout()`, `src/input.js`).

### Rotation (the shell)

`platform/web/shell.html` wraps the canvas and the loading screen in `#wb-rotor`. Its layout script runs before the engine and again on `resize`, `orientationchange` (and 250 ms after it: iOS reports the new viewport late), `visualViewport` resize and `screen.orientation` change:

- **When:** a touch device (`(pointer: coarse)`, or a mobile user agent) whose viewport (`visualViewport`, else `innerWidth`/`innerHeight`) is portrait. Desktop browsers and landscape viewports are never rotated. `?rotate=0` turns it off; `?rotate=1` also rotates a portrait desktop window (testing).
- **How:** the box gets the landscape size (the viewport's height × its width) and `transform: translate(<viewport width>px, 0) rotate(90deg)` about its top-left: it covers the viewport exactly, turned 90° clockwise. The game's top is the page's right edge, so the player turns the phone counter-clockwise and **the phone's top (the Dynamic Island or camera) is on the player's left**, as in cool_drive. A box point (x, y) is the page point (viewport width − y, x).
- **Canvas size:** the shell starts the engine with `canvasResizePolicy = 0` (the export's Adaptive policy would size the canvas to the portrait window) and sizes the canvas itself, rotated or not: CSS size = the box, backing size = the box × `devicePixelRatio` (what Adaptive did before). The engine follows `canvas.width/height` every frame, so Godot renders at the landscape size and the stretch (1280×720, `canvas_items` / `expand`) sees a landscape window: an iPhone 14 in portrait Safari (390×664 CSS px) gives a 664×390 box and a 1280×752 canvas.
- **Loading screen:** inside the box, sized in container units (`cqh`/`cqw`, with `vh`/`vw` fallbacks) and inset by the mapped safe area, so it is landscape from the first paint.

### Input

Godot 4.7's web input (`GodotInput.computePosition` in the engine JS) turns a DOM event into canvas pixels as `(clientX − rect.x) × canvas.width / rect.width` (and the same for y), with `rect = canvas.getBoundingClientRect()`. Under a CSS rotation the rect is the rotated box's bounding box and the axes swap, so every touch would land in the wrong place. The fix is in the shell, before the engine sees anything:

- The canvas' `getBoundingClientRect` is replaced: while rotated it returns the box's own rect `(0, 0, width, height)`.
- A capture-phase listener on `window` (it runs before the engine's listeners on the canvas and window) rewrites what the engine reads: `clientX`/`clientY` (and `movementX`/`movementY`) of `mousedown`, `mouseup`, `pointermove` (and the other pointer and mouse events) become the box's coordinates, `(clientY − box.top, box.right − clientX)`, and `changedTouches` of every touch event becomes a list of `{identifier, clientX, clientY}` in the box's frame. Own properties shadow the event's prototype getters (standard JS; no browser-specific API).
- So the game receives plain landscape `InputEventScreenTouch/Drag` and mouse events in canvas pixels: multi-touch (steering thumb + pedal thumb) works, touch ids are still the browser's (`TouchSlots` maps them), GUI buttons take their emulated mouse events, and nothing in GDScript knows about the rotation except the gyro and the insets.
- Why not in GDScript: a remap at the root viewport would have to run before every node's `_input` (autoloads get `_input` last) and would leave the engine's own mouse state unrotated. The shell's version is also what the smoke test exercises end to end.

The math is a pure block in the shell (`<wb-layout-math>`), tested in node by `tools/web_smoke/layout_test.mjs` (rotation decision, box, client → box and back, movements, insets, and the canvas pixel Godot's `computePosition` then computes).

### Gyro

The phone is physically in portrait (the page reports `screen.orientation.angle` 0 when orientation-locked) while the game is landscape. `WebMotionSource.screen_rotation_deg()` returns `WebMotionSource.game_rotation_deg(angle, WebLayout.rotated())`: the page's angle plus 90° when rotated (cool_drive adds the same 90). A portrait-locked phone then reads exactly like real landscape with its top on the left (angle 90); a page at 180 (Android upside-down portrait, where allowed) reads like the other landscape (270). Calibration and the sign check are unchanged (`tests/input/test_rotated_gyro.gd`: the same hold steers identically rotated and in landscape).

### Safe area

The 3D view stays full-bleed; the HUD, the menus and the touch controls stay inside the safe area (`ScreenInsets.canvas_safe_rect`, used by `HudLayout.canvas_safe_rect` and `PlayerInput`):

| Where | Source |
| --- | --- |
| Web (custom shell) | `env(safe-area-inset-*)` (the page has `viewport-fit=cover`), read by the shell from a probe element and passed as `wbLayout.il/it/ir/ib` (CSS px, the page's frame). Rotated: mapped into the box (**the portrait top, where the camera is, becomes the left**; the portrait bottom, the home indicator, the right; `ScreenInsets.rotate_cw`). Scaled from CSS px to canvas px by canvas ÷ box. |
| Native, and the web without the shell | `DisplayServer.get_display_safe_area()`, converted to canvas px as before. |
| Phone minimum | On a phone-class device (web: coarse pointer and a short screen side ≤ 600 CSS px; native: `mobile`), the left inset is at least `controls.min_left_inset_cm` (0.7 cm; with the HUD's 16 px edge margin its panels start about 0.85 cm in, past the Dynamic Island's far edge in landscape, 48 pt ≈ 0.8 cm), in canvas px via the controls' px per cm (web: the 6.8 cm-tall fallback, about 74 px on a 720-tall canvas). Safari often reports 0 in landscape; most players hold the phone with the camera on the left. The right side keeps only what the device reports. |

The touch controls follow it: the drag zone starts at the safe area's side (a thumb under the cutout does not steer), the drag visual (ring and dot, or wheel) is drawn shifted just enough to stay inside the safe width (`ControlsLayout.drag_visual_offset`; the anchor and the steering stay under the thumb), pedals already sat inside the safe area, and the HUD's thumb zones (3.4 cm from the canvas edge) still cover a thumb that lands just right of the minimum inset and drags the full 2.5 cm. Every screen's text fit is swept on a 1560×720 canvas with this left-only inset (`tests/a11y/test_text_size_sweep.gd`, `test_left_inset_*`).

### Native

Already landscape only: `display/window/handheld/orientation = 4` (sensor landscape: both landscape directions, never portrait) is what the iOS export writes into Info.plist (`UISupportedInterfaceOrientations` landscape left and right) and the Android export into the manifest (`sensorLandscape`); neither preset overrides it. The Web preset's PWA orientation is landscape. No portrait layout or "rotate your device" overlay exists in the game (searched).

### What to check on the iPhone

1. **Portrait-locked Safari** (orientation lock on, phone upright): the loading screen and the title appear turned; hold the phone sideways with its top on the left: the game is upright, fills the screen, Safari's toolbars stay small. Tap PLAY, drag-steer with the left thumb while holding gas with the right (multi-touch), pause, settings sliders.
2. **Gyro in that hold:** tilting like a wheel (right edge down) steers right; recalibrate works.
3. **Landscape Safari** (lock off, phone turned): not rotated, input normal; turn the phone the other way (camera on the right): still correct, gyro sign still right.
4. **Rotation both ways while playing** (lock off): portrait → landscape → portrait re-lays out without a stuck touch.
5. **Island side:** in both modes, the score, the menus, the drag wheel and the left brake pedal (gyro + manual) stay clear of the Dynamic Island on the left.
6. `javascript:alert(JSON.stringify(wbLayout))` from the address bar shows what the page decided (rotated, box, insets).

### Smoke

`smoke.mjs --portrait` emulates an iPhone 14 in portrait (390×664, touch, iPhone user agent), `--landscape` the same phone in landscape, `--device NAME` any Playwright device; `--dpr N` overrides the pixel ratio (SwiftShader renders every backing pixel on the CPU, so `--dpr 1` keeps it fast). It checks the layout (rotated or not, the box, the canvas's backing size, the box covering the viewport), then `--tap-play`: the page is opened with `?probe=ui`, the game prints its visible buttons in canvas px, the smoke taps PLAY's centre through the shell's rotation (`toClient`), taps DRIVE if the first-run chooser opens (a fresh profile), and requires the game's `web boot: start` mark. The default (desktop 1280×720) run is unchanged.

## Web gyro

The plan never recorded the M2 decision (§10 item 4 still lists web gyro as open). What the code does today (WP2.2, docs/CONTROLS.md → Web gyro): gyro works on the web through the game's own `devicemotion` bridge, the iOS permission is requested inside a tap, and when the permission is refused or the API is missing `is_gyro_supported()` is false, so the settings and the first-run chooser hide gyro and the countdown falls back to drag. The spec's fallback ("gyro is native-only in v1 and the web setting is hidden") applies only "if that is not reliably reachable", and WP2.2 found it reachable.

**Not changed here.** Turning gyro off on the web would remove a working, gated feature from the owner's everyday build and needs code outside this WP's paths. It is an owner question (see the handoff). If the answer is "native only", the change is one line in `PlayerInput._default_gravity_source()` (`src/input/player_input.gd`): return `GravitySource.new()` on the web too, so `is_gyro_supported()` is false and the settings hide gyro.

## Caching

GitHub Pages sends `cache-control: max-age=600` and a weak ETag made of the file's modification time and size, which changes on every deploy. Without help, a phone that opened the game in the last 10 minutes keeps running the old `index.html`, `index.pck` and `index.wasm` for up to 10 minutes after a deploy, and can mix a new page with an old pack.

- **Versioned downloads.** `tools/export_web.sh` hashes `index.wasm`, `index.pck` and `music.pck` into a 12-hex build id and writes it into the shell: `index.js?v=<build>` in the page, and the shell wraps `fetch` so the engine's own `index.wasm` and `index.pck` requests (and `music.pck`, through `window.wbBuild`) carry `?v=<build>`. A new build has new URLs: never a cached mix. A deploy that changes nothing keeps the same URLs.
- **Stale page.** `version.json` (`{"build": ..., "commit": ...}`) is fetched with `cache: 'no-store'` at boot, in parallel with the engine. If it names another build, the cached `index.html` is stale and the page reloads once (a `sessionStorage` guard stops a loop if Pages' edge still serves the old page).
- Checked by the smoke: every run with the custom shell requires the three files with `?v=<build>`; `--stale` serves a newer build id first and requires exactly one reload.

The two audio worklet files are loaded by `audioWorklet.addModule()`, not `fetch`, so they stay unversioned; they come from the engine template and only change with the Godot version.

## Slim engine

WP9.9. `index.wasm` was Godot's full web template (37.7 MiB, 9.7 MiB on the wire, 59 % of the transfer to the title). Westbound now ships its own build of the same engine: Godot 4.7-stable from the release tarball, the official compiler (Emscripten 4.0.20, the version `godotengine/build-containers` pins for 4.7), the official template's settings (`production=yes`, `optimize=size`, wasm SIMD, single-threaded), with what the game never uses compiled out. Nothing in the game changed.

### Before and after

Release export, gzip like Pages; timings from `smoke.mjs --gzip --network 4g --settle 8000`, three alternating runs each on the same machine (SwiftShader, see the caveat in [Measuring](#measuring)):

| | Official template | Slim template | Change |
| --- | --- | --- | --- |
| `index.wasm` raw / gzip | 37.7 / 9.6 MiB (9.71 MiB on the wire) | **23.0 / 6.0 MiB** (6.07 on the wire) | −39 % / −37 % |
| `index.js` raw / gzip | 273 / 67 KiB | 249 / 62 KiB | |
| `index.pck`, `music.pck` | 5.1 / 3.3 MiB, 3.7 / 3.5 MiB | unchanged | |
| Transfer to the title (`export_web.sh`) | 13.1 MiB | **9.4 MiB** | −28 % (inside the 12 MiB budget) |
| Boot downloads done, 4G | 13.35–13.47 s | **9.57–9.62 s** | −3.8 s |
| `WebAssembly.instantiate` (after the download) | 0.07 s | 0.04–0.05 s | streaming compile, already small |
| First frame, 4G | 20.0–21.0 s | 15.8–16.3 s | −4.6 s |
| Title shown, 4G | 21.96–23.04 s | **17.82–18.10 s** | −4.6 s |
| Engine classes (`ClassDB`) | 913 | 327 | −586 (`tools/web_template/removed_classes.txt`) |
| Wasm memory after loading every game resource (probe) | 155.2 MiB | 136.8 MiB | −18 MiB |
| Wasm memory, one text scene (probe) | 74.8 MiB | 65.9 MiB | −9 MiB |
| Wasm memory 8 s after the title (smoke) | 186.3 MiB | 197.1 MiB | see below |
| JS heap after the title (Chrome) | 215–257 MiB | 228–242 MiB | noise |

The wasm memory is a high-water mark that only grows, each time to at least 1.2× its size (Emscripten's geometric growth), so one reading can land a step apart; with the same work (the probes) the slim engine holds 9–18 MiB less. The CPU-bound stretch after `engine main()` (setup, world build, shaders) is the same within noise; the gain is the download. On a phone over 4G the 3.7 MiB less is about 3–4 s.

### What is compiled out

All of it was audited against `src/`, `data/`, `assets/`, `platform/` and `project.godot` (grep, then the [class profile](#class-profile)), and the [checks](#checks) prove it on the real pack.

| Off | Why it is safe |
| --- | --- |
| `disable_physics_2d` | No 2D bodies, areas or shapes anywhere (UI is Control-only). |
| `disable_navigation_2d`, `disable_navigation_3d` | Traffic is IDM/MOBIL in road space; no navigation nodes or servers. |
| `disable_xr` (also drops `webxr`, `mobile_vr`) | No XR. |
| `brotli=no` | Brotli only decodes WOFF2 fonts; the fonts are TTF. Replays use gzip (core). |
| `graphite=no` | SIL Graphite smart-font shaping; Chakra Petch has no Graphite tables (HarfBuzz/OpenType shaping stays). |
| `godot_physics_3d`, `vhacd` | The project uses **Jolt** (`physics/3d/physics_engine`); the crash cinematic's RigidBody3Ds and box shapes run on Jolt, which stays. VHACD is import-time convex decomposition. |
| `csg`, `gridmap`, `gltf`, `fbx`, `meshoptimizer` | No CSG or GridMap; `.glb` cars are imported at edit time (the pack holds `.scn`), no runtime GLTFDocument; LODs are made at import. |
| `multiplayer`, `enet`, `webrtc`, `upnp`, `jsonrpc` | The net layer is the game's own protocol over `WebSocketPeer` and `HTTPRequest` (both stay); no `@rpc`/SceneMultiplayer; ENet and UPnP cannot run in a browser; JSON-RPC serves the GDScript language server only. |
| `theora`, `mp3`, `interactive_music` | No video; audio is OGG Vorbis (music, loops) and WAV/QOA (one-shots), both stay; no AudioStreamInteractive/Playlist/Synchronized. |
| `noise`, `visual_shader` | No FastNoiseLite/NoiseTexture; every shader is a `.gdshader`. |
| `zip` | No ZIPReader/ZIPPacker (core `.zip` pack support, `minizip`, stays). |
| `astcenc`, `bcdec`, `etcpak`, `basis_universal`, `ktx`, `dds` | Runtime texture (de)compression and loaders: the pack has no VRAM-compressed textures (the art is vertex-colored). If textured art arrives, keep `bcdec`/`astcenc` in mind for a device that lacks both exported formats. |
| `bmp`, `tga`, `hdr`, `jpg`, `tinyexr` | Runtime `Image.load` of those formats: textures are imported `.ctex` (WebP lossless, which stays, like PNG in core). |

Kept on purpose: `text_server_adv` (HarfBuzz kerning and shaping, BiDi, ICU line breaking: player names may be any script; the fallback server would change text layout), `freetype`, `msdfgen` (the fonts are MSDF), `svg` (the default theme's icons are SVG at run time), `webp`, `ogg`/`vorbis`, `jolt_physics`, `mbedtls` (`Crypto.generate_random_bytes`, `TLSOptions`), `regex` (`fake_boards.gd`), `websocket`, `gdscript`, `javascript_eval` (`JavaScriptBridge.eval`: the audio bridge, `js_bridge.gd`, the URL parameters). Not changed from official: `deprecated`, `disable_advanced_gui` (the loop editor uses OptionButton/SpinBox), `threads=no`, the JS glue (no closure compiler: the audio bridge reads `GodotAudio` by name).

### Class profile

On top of the modules, `tools/web_template/westbound.gdbuild` (Godot's build profile format, passed as `build_profile=`) unregisters 243 class trees the game never uses (each disables its descendants at compile time, and full LTO drops their code): 2D nodes (`Node2D` and below), animation (`AnimationMixer`, `AnimationNode`), most 3D nodes outside what the game uses (lights other than `DirectionalLight3D`, particles, GI, decals, fog, occluders, joints, soft and vehicle bodies, skeletons and IK, sprites and `Label3D`, paths), `Environment`/`WorldEnvironment`/sky materials (the sky and the grade are custom shaders), unused containers and controls (`RichTextLabel`, `TabContainer`, `ItemList`, `Tree`, color picker, graph and code editors…), unused shapes, meshes, textures, audio effects and streams, `Translation`, `GDExtension`.

Godot 4.7 detects a profile only from the editor GUI (Project → Tools → Engine Compilation Configuration Editor → Detect from Project), so `tools/web_template/detect_classes.gd` does the same headless, more conservatively:

```
tools/godot.sh --headless --path . --script res://tools/web_template/detect_classes.gd -- --write   # regenerate the profile
tools/godot.sh --headless --path . --script res://tools/web_template/detect_classes.gd -- --check   # does the template have every class the game uses?
```

*Used* = every word in the game's text files (scripts, scenes, resources, shaders, `.import` files, `project.godot`, comments included) that names a class, the class of every object reached by loading every game resource (scene node types, sub-resources, imported files), the editor's always-kept classes (`Font`, `InputEvent`, `ShaderInclude`, `StyleBox`, `Window` and their inheriters), the dependencies the engine declares (`ADD_CLASS_DEPENDENCY`), a few objects the engine hands the game (`World3D`, `ImageTexture`, `ViewportTexture`, `Theme`, `Image`, `X509Certificate`, `CryptoKey`), and all their ancestors. Like the editor it disables only core Node and Resource classes. `--check` fails when the game uses a class that the profile disables or that `removed_classes.txt` lists (whole-line comments do not count there); `tools/export_web.sh` runs it before using the slim template and falls back to the official one when it fails, so a new feature using, say, `GPUParticles3D` or `FastNoiseLite` can never ship a broken web build: it ships the official engine until the profile is regenerated (`--write`) or the module re-enabled in `build.sh`, and the template rebuilt.

### Build

```
tools/web_template/build.sh            # release template -> build/web_template/web_nothreads_release.zip
tools/web_template/build.sh --debug    # debug template (tools/export_web.sh --debug)
tools/web_template/build.sh --hash     # the config hash (CI cache key)
```

Pinned: the Godot 4.7-stable source tarball (SHA-512 from the release's `SHA512-SUMS.txt`), emsdk tag 4.0.20 at its commit, SCons 4.10.1 in a venv; everything downloaded or built lives in `~/.cache/westbound/web_template` (emsdk ~1.6 GB; the source tree and objects ~3 GB while building, deleted afterwards unless `--keep`). The SCons flags, each with its reason, are in `build.sh`; the config hash covers `build.sh` and the profile, and `build/web_template/template.json` records it with the sizes. Two choices beyond the official build: **full LTO** (official uses thin; full drops more dead code) and **SCU** (`scu_build=yes`, about twice as fast cold). Neither changes float results: wasm arithmetic is strict IEEE-754 (no fast-math, no FMA contraction in the MVP/SIMD128 instruction set), the libm is the same musl, and the determinism compare is bit-identical (below). A cold release build took **15 min** here (4 cores; plus ~3 min for emsdk the first time). No Docker: a pinned emsdk checkout is just as reproducible and runs the same in CI.

### How the export picks the engine

The Web preset's `custom_template/release` and `/debug` point at `build/web_template/selected/` (gitignored). `tools/export_web.sh` fills it before each export:

- `--template=auto` (default; also `WB_WEB_TEMPLATE`): the slim template when `build/web_template/` holds one built for the current config hash and `detect_classes.gd --check` passes; else the official one, saying why on the `engine:` line.
- `--template=slim`: fail instead of falling back. `--template=official`: Godot's own. `--template=path.zip`: that template as is (experiments).

An editor-GUI export needs `selected/` to exist: run `tools/export_web.sh` once.

### Checks

`tools/web_template/verify.sh [--net=http://127.0.0.1:8080]` runs the official and the slim engine in headless Chromium with the same `index.pck`/`music.pck`, through a page that mounts the pack and replaces the main scene with a probe (export templates ignore `--script`, so the page drops the probe, a scene holding it and an `override.cfg` into the engine's file system):

- **Everything loads**: `web_probe.gd` compiles every script and loads every scene, resource and imported file of both packs. Same result on both engines: 675 loaded, the same 4 failures (below), no other error.
- **Names render identically**: `web_names.gd` draws player names in the game's theme (`Şahin#1234`, Turkish dotted/dotless i and Turkish upper-casing, `Zoë Ñandú Łukasz Øyvind Ærø`, a combining accent, Greek and Cyrillic, Thai, an emoji): the same shaped widths, and byte-identical screenshots.
- **Networking** (`--net`, with a local `westbound-server`): `web_net.gd` does an `HTTPRequest` to `/api/v1/health` and a `WebSocketPeer` echo (binary and text) on `/ws/echo`: ok on both. The game's own online boot (device account via `POST /api/v1/auth/device`) also ran against the local server with the slim engine.
- It rewrites `removed_classes.txt` (what the official engine has and the slim one lacks).

Also passed with the slim engine (this WP): every web smoke (default `--gzip`, `--portrait --dpr 1`, `--landscape --dpr 1` with the tap on PLAY, `--audio-unlock tap` with the music playing after the tap, `--stale`), and `tools/determinism/compare.sh --seconds=180`: **IDENTICAL** (180/180 s bit for bit vs native, 34 hits; the libm probe differs exactly as with the official engine).

### CI

`.github/workflows/web.yml` has a `template` job before `build`: it computes the config hash, looks it up in the Actions cache (`web-template-<hash>`, lookup only), and only on a miss builds the template (`continue-on-error`, step timeout 100 min) and saves it. The `build` job (`needs: template`, runs even when it failed) restores that cache, exports (`auto`), and runs `tools/web_template/ci_gate.sh` before the usual smokes: when the export used the slim engine it runs `verify.sh`, a default smoke and a 60 s determinism compare, and on any failure re-exports with the official engine (warning annotation); the step summary says which engine shipped. The existing smoke, determinism and deploy steps then test and deploy whatever was exported. So a slim-engine problem costs a warning, never a deploy. A config change costs one cold build (~15–30 min on a 4-core runner) on the first push; caches saved on the default branch are visible to every branch, other branches' caches only to themselves; GitHub evicts caches unused for 7 days (one push a week keeps it).

### Found on the way (not changed: outside this WP)

- The web pack contains four scripts that cannot compile there, on either engine: `assets/cars/car_import.gd` (an `EditorScenePostImport`) and the dev previews `src/road/dev/road_preview.gd`, `roadside_preview.gd`, `lane_change_road_path.gd` (they use `StraightRoadPath`/`ArcRoadPath`, which live outside the export). Those preview scenes are broken in the web build.
- Greek and Cyrillic names render as missing-glyph boxes on the web on both engines: Chakra Petch has no such glyphs and a browser build has no system fallback fonts. Latin with diacritics (Turkish included) and Thai render.

## Next steps (not done here)

1. ~~A smaller engine~~: done in WP9.9 ([Slim engine](#slim-engine)).
2. **Measure on the iPhone.** The CPU-bound boot (engine setup, world build, shader compiles) can only be judged on the phone; `wbBoot` has the marks.

## Shared-file requests

`export_presets.cfg` (Web preset only; iOS and Android unchanged):

```diff
 [preset.0]
 ...
-exclude_filter="tests/*, tools/*, docs/*, *.md, .github/*, build/*"
+exclude_filter="tests/*, tools/*, docs/*, *.md, .github/*, build/*, assets/audio/music_*"
 ...
 [preset.0.options]
 ...
-html/custom_html_shell=""
+html/custom_html_shell="res://platform/web/shell.html"
```

Both are independent: the shell alone gives the loading screen and the versioned downloads; the filter alone makes `music.pck` (the game fetches it either way). Everything works, and the smoke passes, with neither.

`.github/workflows/web.yml` (build job): see the handoff for the exact diff (gzip metrics, the audio-unlock and stale-page smoke runs).
