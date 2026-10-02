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
2. **Settings → Environments → `github-pages` → Deployment branches and tags.** The
   workflow deploys from the default branch (`main`), which the environment allows by
   default. The environment appears after step 1. If it doesn't, create it with that name.
3. **Settings → Secrets and variables → Actions → Variables → New repository variable:**
   `PAGES_ENABLED` = `true`. Optionally add `PAGES_BRANCH` = a branch name to deploy
   from that branch instead of `main` (add it to the environment in step 2). Pushes from
   other branches build and test without deploying.
4. Push, or re-run the **Web** workflow (Actions → Web → Run workflow). The deploy
   job prints the URL, normally `https://b3vet.github.io/westbound/`.

On the iPhone, open that URL in Safari and turn the phone to landscape. Each push
redeploys. If the old build sticks, reload the page.

## iOS (owner's Mac)

Needs macOS, Xcode with the iOS SDK, an Apple developer account and the official Godot
4.7-stable macOS editor (any copy; point `GODOT` at its binary). Last verified with Xcode
26.3 (iOS SDK 26.2), shipping 0.1.0 (2) to TestFlight. The commands below assume:

```
export GODOT=/Applications/Godot.app/Contents/MacOS/Godot   # or wherever your Godot.app is
```

Values in `<ANGLE_BRACKETS>` are the owner's and never go into the repo.

### One-time setup

1. **Templates:** `tools/export_templates.sh --all` (or the editor's Export Template Manager).
2. **Team ID:** in **Project → Export… → iOS**, fill in **App Store Team ID** (developer.apple.com
   → Membership), or set `application/app_store_team_id` in `export_presets.cfg`. Then keep it
   out of git (see [Keeping the team ID out of git](#keeping-the-team-id-out-of-git)).
   Already set in the preset: bundle ID `com.b3vet.westbound`, Development (debug) and App Store
   (release) export methods, version `0.1.0` (`application/short_version`), the build number
   (`application/version`), the App Store icon and launch screen (`assets/branding/`, the icon
   is opaque), and two Info.plist keys (`application/additional_plist_content`):
   `ITSAppUsesNonExemptEncryption = NO` (HTTPS/WSS only, so no export-compliance question per
   build) and `UIRequiresFullScreen = YES` (the game is landscape-only; without it App Store
   validation rejects the iPad build).
3. **App ID and app record:** register the bundle ID `com.b3vet.westbound` (developer.apple.com
   → Identifiers, or the App Store Connect API `POST /v1/bundleIds`) and create the app in App
   Store Connect (My Apps → +) with that bundle ID. The API can't create app records; that step
   is web-only.
4. **App Store Connect API key:** a team key (App Manager role) saved as
   `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`, plus its key ID and issuer ID. The
   upload uses it, and it lets Xcode sign the App Store build with a cloud-managed distribution
   certificate, so no Apple Distribution certificate has to be in the keychain.
5. **TestFlight group:** an internal group with access to all builds, so every upload reaches
   testers without an extra step. Beta testers are per app: add yourself to this app's group
   by email (assigning an existing tester record from another app fails with
   `409 STATE_ERROR "Tester(s) cannot be assigned"`).

### Each TestFlight upload

1. Raise the build number, `application/version`, in the iOS preset (every upload needs a new
   one; change `application/short_version` for a new marketing version).
2. Export. The `.ipa` step fails on signing (exit code 1, see step 3), but
   `build/ios/Westbound.xcodeproj` is written, and that's all we need:
   ```
   tools/godot.sh --headless --path . --export-release iOS build/ios/Westbound.ipa
   ```
3. Fix the signing identity (after **every** export). Godot writes
   `CODE_SIGN_IDENTITY = "Apple Distribution"` into the Release config together with
   `CODE_SIGN_STYLE = Automatic`, which Xcode rejects: *"Westbound has conflicting provisioning
   settings. Westbound is automatically signed for development, but a conflicting code signing
   identity Apple Distribution has been manually specified."* The App Store export re-signs
   with distribution anyway:
   ```
   sed -i '' 's/CODE_SIGN_IDENTITY = "Apple Distribution";/CODE_SIGN_IDENTITY = "Apple Development";/' \
     build/ios/Westbound.xcodeproj/project.pbxproj
   ```
4. Archive:
   ```
   xcodebuild -project build/ios/Westbound.xcodeproj -scheme Westbound -configuration Release \
     -destination 'generic/platform=iOS' -archivePath build/ios/Westbound.xcarchive \
     -derivedDataPath build/ios/DerivedData -allowProvisioningUpdates archive
   ```
5. Check the archived app on a device before uploading (iPhone unlocked and on a cable; get
   its identifier from `xcrun devicectl list devices`). The console shows Godot's log (see
   [Debugging on a device](#debugging-on-a-device)):
   ```
   xcrun devicectl device install app --device <DEVICE> \
     build/ios/Westbound.xcarchive/Products/Applications/Westbound.app
   xcrun devicectl device process launch --console --terminate-existing \
     --environment-variables '{"OS_ACTIVITY_DT_MODE":"1"}' --device <DEVICE> com.b3vet.westbound
   ```
6. Upload. Write `build/ios/ExportOptions.plist`:
   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
   	<key>method</key><string>app-store-connect</string>
   	<key>destination</key><string>upload</string>
   	<key>teamID</key><string><TEAM_ID></string>
   	<key>signingStyle</key><string>automatic</string>
   	<key>uploadSymbols</key><true/>
   	<key>manageAppVersionAndBuildNumber</key><false/>
   </dict>
   </plist>
   ```
   then:
   ```
   xcodebuild -exportArchive -archivePath build/ios/Westbound.xcarchive \
     -exportOptionsPlist build/ios/ExportOptions.plist -exportPath build/ios/export \
     -allowProvisioningUpdates \
     -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 \
     -authenticationKeyID <KEY_ID> -authenticationKeyIssuerID <ISSUER_ID>
   ```
   It ends with `Upload succeeded` / `** EXPORT SUCCEEDED **` (about 2 minutes).
7. Apple processes the build in about 5 minutes; then it shows up in TestFlight. To script
   the wait, poll `GET /v1/builds?filter[app]=<APP_ID>` on the App Store Connect API until
   `processingState` is `VALID`.

### Debugging on a device

- **Crash reports:** crashes that testers send from TestFlight appear in App Store Connect →
  TestFlight → Crashes (API: `betaFeedbackCrashSubmissions` and their `crashLog`).
- **Release builds crash where debug builds only log.** The release templates compile out
  GDScript's null checks, so a method call or property assignment on `null` that prints a
  `SCRIPT ERROR` in the editor or a debug build segfaults on a release build (for example,
  0.1.0 (1) crashed in `Node::reset_physics_interpolation()` because
  `CrashSequence.reset()` ran before `setup()`). To find the script and line, run a debug
  export on the device. The Development method signs it automatically:
  ```
  tools/godot.sh --headless --path . --export-debug iOS build/ios-debug/Westbound.ipa
  xcrun devicectl device install app --device <DEVICE> build/ios-debug/Westbound.ipa
  ```
  then launch it with the `--console` command from step 5 above.
- **Getting the log:** Godot logs through os_log, so `--console` alone shows nothing.
  `OS_ACTIVITY_DT_MODE=1` (what Xcode sets) mirrors it to the console with GDScript backtraces.
  `log collect --device-udid …` needs root.
- **Device errors:** `kAMDMobileImageMounterDeviceLocked` means unlock the iPhone;
  `CoreDeviceError 4000` (disconnected right after connecting) is usually Wi-Fi, so use a cable.

### Known issues

- **No iOS Simulator with the stock 4.7 templates.** The simulator slice of `libgodot.a` is
  x86_64 only, so an arm64 simulator build fails to link (`_main` undefined). An x86_64 build
  also fails against the iOS 26.2 simulator SDK: undefined Swift concurrency symbols
  (`Swift.MainActor.shared`) from Godot's SwiftUI app shell. Use a device, or build the
  templates from source with an arm64 simulator slice.
- **`mouse_get_position(): Mouse is not supported by this display server`** is logged on every
  start. It's an engine bug (the root window asks for the mouse position on entering the
  tree), [godotengine/godot#124041](https://github.com/godotengine/godot/issues/124041), fixed
  upstream. Harmless; it goes away with a Godot update.
- **Minimum iOS version:** App Store Connect warns that from April 2027 apps must target
  iOS 15.0 or later. Raise `application/min_ios_version` (now 14.0) before then.
- `Info.plist` ships an empty `NSCameraUsageDescription` (Godot's camera module). It
  didn't block the upload.
- `test_sin_cos_tan_accuracy` fails on macOS: it compares against the host's libm, which
  differs from Linux glibc. CI (Linux) is the reference.

### Keeping the team ID out of git

Godot moves only fields marked *secret* into the
gitignored `.godot/export_credentials.cfg`. For iOS those are the provisioning-profile
UUIDs, not the team ID. The team ID is saved into `export_presets.cfg` like any other
option. Do one of these:

- Before committing, run `git restore -p export_presets.cfg` to drop the team-ID line
  (it's the easiest after a one-off export), or
- run `git update-index --skip-worktree export_presets.cfg` so git ignores your local
  edits (including the build number). Undo it with `--no-skip-worktree` before pulling
  preset changes.

The team ID isn't a password (it appears in every signed app), but the plan keeps it
local (plan §10). Certificates, profiles and the API key stay in the macOS keychain,
Xcode and `~/.appstoreconnect/`.

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
