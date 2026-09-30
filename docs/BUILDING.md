# Building Westbound

How to produce the Web, iOS and Android builds, and what the owner has to set up
once. Nothing secret lives in the repo: signing keys, passwords, provisioning
profiles and the Apple team ID stay on the owner's machine.

Export presets live in [`export_presets.cfg`](../export_presets.cfg) (orchestrator-owned):

| Preset | Renderer | Output | Notes |
| --- | --- | --- | --- |
| **Web** | Compatibility (WebGL 2) | `build/web/index.html` | Single-threaded, ETC2/ASTC + S3TC/BPTC textures, adaptive canvas, dark `#0b1020` page |
| **iOS** | Mobile (Metal) | `build/ios/Westbound.ipa` (+ `Westbound.xcodeproj`) | Bundle `com.b3vet.westbound`, iPhone + iPad, iOS 14+, team ID left empty |
| **Android** | Mobile (Vulkan) | `build/android/westbound.apk` | Package `com.b3vet.westbound`, arm64-v8a, min SDK 29 (Godot's Vulkan default), VIBRATE permission |

All presets leave `tests/`, `tools/`, `docs/`, `build/`, `.github/` and `*.md` out of the pack.
Landscape orientation (both sides, sensor-driven) comes from the project setting
`display/window/handheld/orientation`, which Godot writes into the iOS Info.plist
and the Android manifest.

Everything in `build/` is gitignored.

## Export templates

```
tools/export_templates.sh          # web templates only (enough for the web build)
tools/export_templates.sh --all    # every platform (needed for iOS and Android)
```

The script downloads the official `Godot_v4.7-stable_export_templates.tpz` (~1.3 GB),
checks its SHA-512 against the pinned value, extracts what is needed into
`${WESTBOUND_CACHE:-~/.cache/westbound}/export_templates/4.7.stable/`, deletes the tpz
(set `WESTBOUND_KEEP_TPZ=1` to keep it), and symlinks the files into the folder the
editor reads:

- Linux: `~/.local/share/godot/export_templates/4.7.stable/`
- macOS: `~/Library/Application Support/Godot/export_templates/4.7.stable/`

Set `GODOT_TEMPLATES_DIR=...` to install somewhere else. Re-running is a no-op once the
templates are installed. Installing templates from the editor's Export Template Manager
works too.

## Web

```
tools/export_web.sh              # release build -> build/web/
tools/export_web.sh --debug      # debug template
node tools/web_smoke/smoke.mjs   # headless-Chromium smoke test (see below)
```

`export_web.sh` installs the templates if needed, runs `--import`, then
`--export-release "Web" build/web/index.html`. If the export fails it prints Godot's
log and exits non-zero. On success it prints the sizes. The M0 build is about
38 MiB of wasm (9.6 MiB gzipped), a 14 KiB pck and 270 KiB of JS. Load-time work is WP9.2.

### Running it in a browser

A Godot web build needs WebGL 2, `fetch`, and a **secure context** (HTTPS, or
`localhost`). Opening `index.html` from disk does not work. Serve the folder over
HTTP on your own machine:

```
npx serve build/web       # or: python3 -m http.server -d build/web 8000
```

Then open `http://localhost:<port>/` on the same machine. An iPhone on the LAN
**cannot** use `http://192.168.x.x:<port>`, because that is not a secure context and
the page stops with "Secure Context" missing. Use the GitHub Pages build instead (below),
or an HTTPS tunnel.

### Why GitHub Pages works (no COOP/COEP)

Pages can't send custom headers. That's fine because the Web preset is
single-threaded (`variant/thread_support=false`, the Godot 4.3+ default). Verified
against Godot 4.7-stable:

- With threads off, the exporter uses the `web_nothreads_*` templates and writes
  `GODOT_THREADS_ENABLED = false` into `index.html`.
- `Engine.getMissingFeatures({threads: false})` in
  `platform/web/js/engine/features.js` checks only WebGL 2, `fetch` and a secure
  context. It skips the cross-origin-isolation and `SharedArrayBuffer` checks that
  need COOP/COEP headers.
- The engine banner reports `Build configuration: ... single-threaded`.
- The smoke test's server sends no COOP/COEP headers, and the build boots.

The PWA option (`progressive_web_app/*`) is off. It would add a service worker that can
inject those headers, which a threaded build would need. We don't use one.

### Smoke test (`tools/web_smoke/`)

```
(cd tools/web_smoke && npm ci)                               # once
(cd tools/web_smoke && npx playwright install chromium)      # once, if no Chromium is installed
node tools/web_smoke/smoke.mjs [--dir build/web] [--timeout 60000] [--settle 3000] \
                               [--screenshot build/web_smoke.png] [--headed]
```

The test:

1. Serves `build/web/` from a small Node static server with correct MIME types
   (`application/wasm`) and no COOP/COEP headers, just like Pages.
2. Opens the page in headless Chromium with software WebGL 2 (SwiftShader:
   `--use-angle=swiftshader --enable-unsafe-swiftshader --ignore-gpu-blocklist`).
3. Waits for the Godot banner (`Godot Engine v4.7...`) and for the loading overlay to go
   away, then lets the game run for `--settle` ms.
4. Saves a screenshot to `build/web_smoke.png`. It checks that the screenshot is not one
   flat color, which would mean nothing rendered.
5. **Fails** on any `console.error`, uncaught page error, failed request or HTTP
   status of 400 or above, on a shell error notice, or on a timeout.

To use a Chromium other than Playwright's, set `CHROMIUM_PATH=/path/to/chrome`. If the
pinned Playwright's browser build is missing, the script falls back to any Chromium
found under `PLAYWRIGHT_BROWSERS_PATH` or `~/.cache/ms-playwright`.

### CI and GitHub Pages (`.github/workflows/web.yml`)

On every push (and on manual dispatch), the `build` job:

1. Restores `~/.cache/westbound` (Godot binary + web templates).
2. Runs `tools/export_web.sh`.
3. Uploads `build/web` as the **`web-build`** artifact.
4. Installs Playwright's headless Chromium.
5. Runs the smoke test.
6. Uploads the screenshot as **`web-smoke-screenshot`**.

The `deploy` job publishes `web-build` to GitHub Pages. It runs only when the
repository variable `PAGES_ENABLED` is `true`, so the workflow stays green until Pages is set up.

**Owner: enabling Pages (one time)**

1. **Settings → Pages → Build and deployment → Source: GitHub Actions.**
   Pages on a private repo needs a paid plan (Pro/Team). On a free plan the repo must be public.
2. **Settings → Environments → `github-pages` → Deployment branches and tags.** Add
   the working branch (`claude/game-implementation-phases-asl5jz`). By default only the
   default branch may deploy. The environment appears after step 1. If it doesn't,
   create it with that name.
3. **Settings → Secrets and variables → Actions → Variables → New repository variable:**
   `PAGES_ENABLED` = `true`. Optionally add `PAGES_BRANCH` = the branch name, so pushes from
   other branches build and test without deploying.
4. Push, or re-run the **Web** workflow (Actions → Web → Run workflow). The deploy
   job prints the URL, normally `https://b3vet.github.io/westbound/`.

On the iPhone, open that URL in Safari and turn the phone to landscape. Each push
redeploys. If the old build sticks, reload the page.

## iOS (owner's Mac)

Needs macOS, Xcode, an Apple developer account and the Godot 4.7-stable editor.

1. Install the templates: `GODOT=/Applications/Godot.app/Contents/MacOS/Godot tools/export_templates.sh --all`
   (or use the editor's Export Template Manager).
2. Open the project in the editor. Go to **Project → Export… → iOS** and fill in
   **App Store Team ID** (the 10-character ID from developer.apple.com → Membership).
   The debug export method (Development) and bundle ID `com.b3vet.westbound` are already set.
3. Export from the editor, or from the command line:
   ```
   GODOT=/Applications/Godot.app/Contents/MacOS/Godot tools/godot.sh --headless --path . \
     --export-debug iOS build/ios/Westbound.ipa
   ```
   This writes `build/ios/Westbound.xcodeproj` and, if signing works, the `.ipa`.
   To sign, run on device, and profile with Instruments, open the Xcode project and run it
   on the iPhone. You can tick **Export Project Only** to skip the `.ipa` step.

**Keeping the team ID out of git.** Godot moves only fields marked *secret* into the
gitignored `.godot/export_credentials.cfg`. For iOS those are the provisioning-profile
UUIDs, not the team ID. The team ID is saved into `export_presets.cfg` like any other
option. Do one of these:

- Before committing, run `git restore -p export_presets.cfg` to drop the team-ID line
  (it's the easiest after a one-off export), or
- run `git update-index --skip-worktree export_presets.cfg` so git ignores your local
  edits. Undo it with `--no-skip-worktree` before pulling preset changes.

The team ID isn't a password (it appears in every signed app), but the plan keeps it
local (plan §10). Certificates and profiles stay in the macOS keychain and Xcode.

## Android (not device-tested yet, plan D5)

Needs the Android SDK (platform-tools, build-tools, a platform for API 36) and JDK 17.

1. `tools/export_templates.sh --all`
2. In **Editor Settings → Export → Android**, set **Android SDK Path** and **Java SDK Path**.
   Once the Java SDK is set, Godot creates a debug keystore on its own.
3. `tools/godot.sh --headless --path . --export-debug Android build/android/westbound.apk`

Min/target SDK are left at Godot's defaults: min 29 (Vulkan), target 36. Overriding
them needs **Use Gradle Build** (`android_source.zip` template + `res://android/`),
which we don't use yet. Only arm64-v8a is on. All Vulkan-capable devices are 64-bit.
Tick `architectures/armeabi-v7a` if a 32-bit build is ever needed.

**Release signing:** don't put keystore paths or passwords in the preset. Godot reads them
from the environment, which suits CI secrets:

```
GODOT_ANDROID_KEYSTORE_RELEASE_PATH=/path/to/release.keystore
GODOT_ANDROID_KEYSTORE_RELEASE_USER=<alias>
GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD=<password>
```

If you enter them in the editor instead, they land in the gitignored
`.godot/export_credentials.cfg` (they are *secret* fields). Keystore files never go
into the repo.
