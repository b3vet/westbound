# Web build

WP9.2 (plan Phase 9: "web build polish (gyro decision, load time)"). Spec: *Platform* (web export second; Compatibility renderer, single-threaded), *Audio*, *Controls → Gyro steering* ("Web build"). The web build on GitHub Pages is the owner's everyday playtest path (plan D4), so this page covers what a phone downloads, how fast it gets to the title, how audio starts, how a new deploy reaches the phone, and how to measure all of it.

## Files

| File | What it does |
| --- | --- |
| `platform/web/shell.html` | The custom HTML shell: the loading screen, versioned downloads, the stale-page check, the AudioContext hook. Needs `html/custom_html_shell` in the Web preset (requested, see [Shared-file requests](#shared-file-requests)). |
| `platform/web/wordmark.woff`, `make_font.py` | Chakra Petch Bold cut down to A–Z, digits and a few signs (3.6 KB) for the loading screen; `make_font.py` rebuilds it (fontTools). |
| `platform/web/pack_music.gd` | Writes `music.pck` (the music tracks as their own pack). |
| `platform/web/.gdignore` | Keeps the directory out of Godot's import and out of `index.pck`. |
| `src/platform/web_audio_unlock.gd` (`WebAudioUnlock`) | Pure state machine: is the page's audio still locked? |
| `src/platform/web_audio_bridge.gd` (`WebAudioBridge`) | The page side: finds the engine's AudioContext, resumes it inside gestures, reports its state. |
| `src/platform/web_audio.gd` (`WebAudio`) | The node: polls the bridge, holds the music until the unlock and the music pack, boot marks. `GameAudio` adds it on the web. |
| `src/platform/web_music_pack.gd` (`WebMusicPack`) | Fetches and mounts `music.pck` when the main pack leaves the music out. |
| `src/platform/web_boot.gd` (`WebBoot`) | Boot milestones (`window.wbBoot`, the `wb-boot` event, a console line). |
| `tools/export_web.sh` | Exports, then writes `music.pck` (when needed), `version.json` and the shell's build id and font; prints sizes and the transfer to the title. |
| `tools/web_smoke/smoke.mjs` | The headless-Chromium smoke test, plus timings, transfer, memory, the audio-unlock test and the caching checks. |
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

The spec gives no number for load time or pack size ("web build polish ... load time"), so these are proposed budgets for the everyday playtest on a phone: **first paint under 0.5 s**, **under 12 MiB (gzip) before the title**, **title within 10 s on 4G** (9 Mbps). The download alone of the current engine is 9.7 MiB, so the transfer budget is only reachable with a smaller engine template ([next steps](#next-steps-not-done-here)).

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

## Web gyro

The plan never recorded the M2 decision (§10 item 4 still lists web gyro as open). What the code does today (WP2.2, docs/CONTROLS.md → Web gyro): gyro works on the web through the game's own `devicemotion` bridge, the iOS permission is requested inside a tap, and when the permission is refused or the API is missing `is_gyro_supported()` is false, so the settings and the first-run chooser hide gyro and the countdown falls back to drag. The spec's fallback ("gyro is native-only in v1 and the web setting is hidden") applies only "if that is not reliably reachable", and WP2.2 found it reachable.

**Not changed here.** Turning gyro off on the web would remove a working, gated feature from the owner's everyday build and needs code outside this WP's paths. It is an owner question (see the handoff). If the answer is "native only", the change is one line in `PlayerInput._default_gravity_source()` (`src/input/player_input.gd`): return `GravitySource.new()` on the web too, so `is_gyro_supported()` is false and the settings hide gyro.

## Caching

GitHub Pages sends `cache-control: max-age=600` and a weak ETag made of the file's modification time and size, which changes on every deploy. Without help, a phone that opened the game in the last 10 minutes keeps running the old `index.html`, `index.pck` and `index.wasm` for up to 10 minutes after a deploy, and can mix a new page with an old pack.

- **Versioned downloads.** `tools/export_web.sh` hashes `index.wasm`, `index.pck` and `music.pck` into a 12-hex build id and writes it into the shell: `index.js?v=<build>` in the page, and the shell wraps `fetch` so the engine's own `index.wasm` and `index.pck` requests (and `music.pck`, through `window.wbBuild`) carry `?v=<build>`. A new build has new URLs: never a cached mix. A deploy that changes nothing keeps the same URLs.
- **Stale page.** `version.json` (`{"build": ..., "commit": ...}`) is fetched with `cache: 'no-store'` at boot, in parallel with the engine. If it names another build, the cached `index.html` is stale and the page reloads once (a `sessionStorage` guard stops a loop if Pages' edge still serves the old page).
- Checked by the smoke: every run with the custom shell requires the three files with `?v=<build>`; `--stale` serves a newer build id first and requires exactly one reload.

The two audio worklet files are loaded by `audioWorklet.addModule()`, not `fetch`, so they stay unversioned; they come from the engine template and only change with the Godot version.

## Next steps (not done here)

1. **A smaller engine (the biggest lever).** `index.wasm` is Godot's full web template: 37.7 MiB, 9.7 MiB gzip, 59 % of the transfer before the title, and its compile time. A custom web template built with a build profile of the classes the project uses (dropping unused modules such as navigation, XR, CSG, GridMap and Theora) and `optimize=size` typically lands around 20–25 MiB (5–6.5 MiB gzip); an estimate, to be measured. Cost: an emsdk matching the template's Emscripten (4.0.20), a cached CI build (~30–60 min cold), and a re-check of every feature on the web. Needs an orchestrator decision (CI time, a new pinned artifact).
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
