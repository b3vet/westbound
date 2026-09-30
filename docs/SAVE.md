# Save, settings and the first run (WP8.1)

The local save, every player setting, the first-run chooser and the empty-road warm-up. Spec: [Save data](../WESTBOUND%20HANDOFF.md#save-data) ("A local, versioned save in `user://` holds settings, unlocks, stats, personal bests and Daily Drive ghosts"), [Controls → Settings and first run](../WESTBOUND%20HANDOFF.md#controls), [UI → Screens → Settings](../WESTBOUND%20HANDOFF.md#screens), [Accessibility](../WESTBOUND%20HANDOFF.md#accessibility). The screens are in [SCREENS.md → Settings, First run](SCREENS.md#settings).

| File | Class | Role |
| --- | --- | --- |
| `src/core/save.gd` | autoload `Save` | The document in memory (`data`), load / save / autosave, sections, first-run flags, personal bests and journeys |
| `src/core/save/save_store.gd` | `SaveStore` | One JSON file: atomic write, backup, corrupt-file recovery |
| `src/core/save/save_migrations.gd` | `SaveMigrations` | Versions, the migration chain, `normalize()` |
| `src/core/settings.gd` | autoload `Settings` | Every setting: defaults, `set_value` → `Events.settings_changed`, sanitized loading |
| `src/core/tuning/meta_tuning.gd`, `data/tuning/meta.tres` | `MetaTuning` | Warm-up length and fade, the dead-zone and curve choices |
| `src/run/run_warmup.gd` | `RunWarmup` | The warm-up on the run (director density, the hint, the save flag) |
| `src/ui/screens/first_run_*.gd`, `settings_panel.gd` | | The chooser, its screen and sketch, the warm-up hint, the settings grid |

## Format

`user://save.json`, a JSON object, tab-indented. Version **2**:

```json
{
	"version": 2,
	"settings": { "steering_mode": "drag", "throttle_mode": "auto", "left_handed": false, "...": "..." },
	"first_run": { "chooser_done": true, "warmup_done": true },
	"bests": { "journey": 2010000, "daily": 48200 },
	"journeys": { "journey": { "count": 2, "best_time_s": 1843.25, "best_distance_m": 61234.5 } },
	"stats": {},
	"unlocks": {},
	"daily": {}
}
```

- JSON numbers read back as floats: readers use `int()` (`Save.best_score`). Settings are stored as their plain values (StringName choices as strings) and typed again on load.
- Keys this build does not know are kept: unknown top-level sections, and unknown keys inside `settings` (written back unchanged), so a newer build's data survives a round trip through an older one.

### Sections

`Save.section(name)` returns the live dictionary (created empty when missing); change it in place, then `Save.request_save()` (soon) or `Save.save_to_disk()` (now).

| Section | Owner | Contents |
| --- | --- | --- |
| `settings` | WP8.1 (`Settings.to_dict`) | every setting below |
| `first_run` | WP8.1 | `chooser_done`, `warmup_done` (bools) |
| `bests` | WP4.1 (`Save.submit_best_score`) | best banked score per mode id |
| `journeys` | WP6.5 (`Save.record_journey`) | per mode: `count`, `best_time_s`, `best_distance_m` |
| `stats`, `unlocks`, `garage` | WP8.2 (driver XP and level, lifetime stats incl. the Daily streak, unlocks, the car/paint/rims selection); additive, no version bump | [GARAGE.md](GARAGE.md) |
| `achievements` | WP8.3: `{unlocked: {id: UTC day}, progress: {metric: value}, mirrored: {id: true}}`; additive | [ACHIEVEMENTS.md](ACHIEVEMENTS.md) |
| `daily` | WP8.4 (`DailyGhostStore`) | `ghosts`: the index of the Daily Drive ghosts on the device, `{date: {score, ticks, car, bytes}}` (the best run per UTC date; today and yesterday kept). The Daily streak stays in `stats` (WP8.2). [DAILY.md](DAILY.md) |
| any new one | its WP, via `section()` | achievements (WP8.3) can take their own |

**Ghosts** (WP8.4, 20 Hz samples) are not inside `save.json` (that file is rewritten on every settings change): each is its own file, `user://daily/<date>.ghost` (`DailyGhost`, written temp + read back + rename like `SaveStore`), and only the index is in `daily`. See [DAILY.md → Ghost file and storage](DAILY.md#ghost-file-and-storage).

## Migrations

`SaveMigrations.migrate(doc)` runs one step per version up to `VERSION`, then `normalize()` (every section present with the right type; the first-run flags default to not done). A migrated or recovered document is written back at once, and the previous file becomes the backup.

| Step | What | Why |
| --- | --- | --- |
| v0 → v1 | adds `version` | the M0 skeleton wrote documents without one |
| v1 → v2 | adds `first_run` = both **done**, `stats`, `unlocks`, `daily`; `bests` become whole numbers, non-numbers dropped | WP0.1–WP7 builds (the web playtest build included) wrote v1: `{version, settings, bests, journeys}`. A v1 file means the game was already played or set up, so an existing player never sees the chooser or the warm-up; their settings and personal bests carry over |

- **A newer version** (a downgrade: an old cached web build opening a newer save) loads as far as this build understands it, **read-only**: `save_to_disk()` never overwrites it.
- **An unreadable version** (not a whole number) starts fresh, with the first run marked done.
- **Adding a version:** bump `VERSION`, add `_vN_to_vN1` and its `match` case, a fixture of the old shape and a test in `tests/core/test_save_migrations.gd`, and a row here.

## Files, atomic writes and recovery

`SaveStore` writes `save.json.tmp` (flushed, closed and read back), copies the current good `save.json` to `save.json.bak`, then renames the temp file over `save.json`. A crash at any point leaves the old file or the new one, never half of one. Some platforms refuse to rename over a file: the store then removes it (the backup holds it) and renames again.

| On load | Status | The game does |
| --- | --- | --- |
| no file | `FRESH` | defaults, first run pending |
| `save.json` parses (a JSON object, valid UTF-8) | `OK` | migrate, apply |
| `save.json` damaged (truncated, zero-filled, binary, not an object) | `BACKUP` | moved aside to `save.json.corrupt`; `save.json.bak` loaded and written back |
| both damaged or missing | `CORRUPT` | defaults, first run **done** (this player had a save) |

Nothing here pushes an error: damage is a warning (`push_warning`) and the game goes on. Bytes are checked for UTF-8 before decoding, so garbage never logs engine errors.

## When it writes

- **At once:** a personal best, a journey, the first-run chooser answered, explicit `save_to_disk()` calls (the pause menu's RESUME / QUIT and the title's DONE after a settings change).
- **Soon:** any `Settings.set_value` (the settings rows, the C camera key, M mute, the HUD camera button, the chooser) marks the save dirty; it is written at the end of that frame, or, while the run is `RUNNING`, when the run leaves `RUNNING` (pause, crash, results, title). The warm-up's end is recorded the same way. So a camera cycle mid-run never touches the disk during gameplay, and the spec's "the choice is saved" holds.
- **On the way out:** `NOTIFICATION_WM_CLOSE_REQUEST`, `APPLICATION_PAUSED` (iOS / Android backgrounding), `APPLICATION_FOCUS_OUT` (a web tab hidden) and `WM_GO_BACK_REQUEST` flush pending changes.

## Web

On the web, `user://` is Godot's `/userfs`, mirrored to IndexedDB. Closing a file opened for writing flags the file system, and the engine syncs it to IndexedDB on its next main-loop iteration; every write here closes its file explicitly, and the rename happens in the same frame, so one sync carries both. Verified in a real browser:

```
tools/export_web.sh
node tools/web_smoke/smoke.mjs --settle 8000 --query "server=off&save_probe=1" \
     --expect "Save probe: loaded 0 boot" --reload --expect-reload "Save probe: loaded 1 boot"
```

`?save_probe=1` makes `Save` print how many boots the save has seen, then count this one and write at once (`dev.probe_boots`); `--reload` reloads the page in the same browser profile. Result (2026-09-30, headless Chromium): boot 1 `loaded 0, status FRESH`, wrote; after the reload `loaded 1, status OK`. A private window or blocked site data leaves IndexedDB empty on the next visit: the game then starts fresh, as a new install.

## Settings

Every setting the spec names, where it lives, and how it applies (live, from `Events.settings_changed`; nothing polls). Choices come from tuning.

| Spec | Key | Page · row | Choices | Applied by |
| --- | --- | --- | --- | --- |
| steering mode | `steering_mode` | CONTROLS · STEERING (+ the chooser) | DRAG / TILT (N/A without tilt) | `PlayerInput` |
| throttle mode | `throttle_mode` | CONTROLS · THROTTLE (+ the chooser) | AUTO / MANUAL | `PlayerInput` |
| left-handed mirror | `left_handed` | CONTROLS · HAND (+ the chooser) | RIGHT / LEFT | `PlayerInput`, HUD, screens |
| sensitivity | `steer_sensitivity` | CONTROLS · SENSITIVITY | `hud.settings_sensitivities` 75 / 100 / 135 % | `PlayerInput` (clamped 0.5–2) |
| dead zone | `steer_dead_zone` | CONTROLS · DEAD ZONE | `meta.settings_dead_zones` SMALL / NORMAL / LARGE (×0.5 / 1 / 2) | `PlayerInput` |
| response curve | `steer_curve` | CONTROLS · CURVE | `meta.settings_curves` GENTLE / NORMAL / SHARP (exponent 1.0 / 1.6 / 2.2) | `PlayerInput` |
| (D10) drag visual | `drag_visual` | CONTROLS · DRAG LOOK | RING / WHEEL | `ControlsOverlay` |
| (D9) controls size | `controls_scale` | CONTROLS · CONTROLS SIZE | `hud.settings_controls_scales` 80 / 100 / 120 % | `PlayerInput` |
| camera | `camera_mode` | GAME · CAMERA (full width) | every `camera.modes`: CHASE / FAR CHASE / HOOD / OVERHEAD / COCKPIT | `CameraRig` (also the C key and the HUD button) |
| graphics tier | `quality_tier` | GAME · GRAPHICS | every `quality.tier_names`: LOW / MEDIUM / HIGH | `Quality` |
| battery saver | `battery_saver` | GAME · BATTERY SAVER | OFF / ON (30 fps) | `Quality` |
| text size | `text_scale` | GAME · TEXT SIZE | `hud.text_scales` 100 / 125 % | HUD, screens |
| units | `units` | GAME · UNITS | KM/H / MPH | HUD, screens |
| reduced motion | `reduced_motion` | GAME · REDUCED MOTION | OFF / ON | camera, juice, screens, time scale |
| haptics | `haptics` | GAME · HAPTICS | ON / OFF | `Haptics` |
| audio buses | `volume_master`, `volume_music`, `volume_sfx`, `volume_engine`, `volume_ui` | AUDIO · MASTER … INTERFACE | `audio.volume_steps` | `AudioBuses` |
| (M key) mute | `audio_muted` | AUDIO · SOUND | ON / MUTED | `AudioBuses` |
| the chooser, revisited | — | CONTROLS · CHOOSE LAYOUT | the first-run chooser in place of the rows | — |

**Loading is defensive** (`Settings.sanitize`): a value of the wrong type, an unknown choice (`CHOICES`) or a non-finite number loads as the default. Ranges are clamped by the systems that read them, from their own tuning. Loading announces every key whose value changed, so a system already running applies it.

## First run

- **Chooser.** On a fresh save (`Save.chooser_pending()`), the title's PLAY, DAILY DRIVE or LOOP PRACTICE opens the chooser first (`TitleScreens.open_first_run`). DRIVE keeps the choice, SKIP puts the spec's default back (drag + auto, right hand); either records `first_run.chooser_done` and starts the run. Esc goes back to the title and it stays pending. It can be revisited any time from SETTINGS → CONTROLS → CHOOSE LAYOUT.
- **Warm-up.** The next Journey run started from the title while `first_run.warmup_done` is false (`Save.warmup_pending()`) begins with `meta.warmup_s` (20 s, the spec's) of empty road. `Run.start_mode` arms `RunWarmup`; `Run._start_run` begins it before the director's prefill:
    - the director's density scale is 0 (both carriageways, behind spawns) and racer arrivals are off, so the road is empty from the first frame;
    - only RUNNING ticks count (not the countdown or the pause); whole ticks of the fixed dt, no clock: deterministic;
    - then the density steps back up over `meta.warmup_fade_s` in `meta.warmup_fade_steps` steps (the first at once) and arrivals come back. The director plans new traffic beyond the fog, so it arrives out of the distance and never pops in (tested);
    - the hint (top-right under the HUD buttons) shows WARM-UP · EMPTY ROAD, TRAFFIC IN n S and SKIP; SKIP starts the fade-in now; then TRAFFIC AHEAD for `meta.warmup_end_note_s`;
    - it is recorded done at its end or on SKIP. A run that ends earlier, or QUIT, leaves it pending for the next Journey. Daily Drive never warms up (the day's traffic is the same for everyone), a retry never does, and neither does a direct boot (`?title=0`, tools);
    - the run's results carry `warmup: true`, and `NetRunPayload.eligible` keeps that run off the leaderboards: the verifier replays a run from its seed without a warm-up, so it could not verify it.

## Tests and tools

- **The test runner never touches the player's save.** Under a `--script` main loop (`tools/test.sh`, soaks, `tools/snap.sh`, the verifier and other tools) `Save` is in memory only (`persistent` false: nothing read, nothing written) and the first run is off (`first_run_enabled` false). Integration tests therefore never see the chooser or the warm-up on a fresh `user://`.
- **A test that wants the first run** sets `Save.first_run_enabled = true` and `Save.reset_fresh()` (and restores both in `after_each`), as `tests/ui/test_first_run.gd` and `tests/run/test_first_run_warmup.gd` do. Tests of the file layer use their own `SaveStore` / `Save` instance on `user://test_save_<pid>/`.
- **Boot parameter `first_run`** (`?first_run=` on the web, `--first_run=` on the command line or a snap): `0` = off, `1` = a fresh first run in memory (nothing is written). Snaps: `tools/snap.sh src/run/run.tscn --state=menu --title=play --first_run=1` (the chooser), `tools/snap.sh src/ui/screens/dev/screens_preview.tscn --screen=warmup --warmup_s=3` (the hint).

| Test file | Covers |
| --- | --- |
| `tests/core/test_save_store.gd` | round trip, the backup is the previous document, every kind of damage (truncated, empty, not an object, zero-filled, bad UTF-8, a surrogate) loads quietly, backup recovery, a stale temp file, folders, UTF-8 check, non-ASCII |
| `tests/core/test_save_migrations.gd` | fresh document, `version_of`, v1 → v2 (the real v1 shape: settings, bests, journeys, first run done), v0 → v2, bad bests, unknown keys, `normalize`, newer / invalid versions untouched, every old version reaches the current |
| `tests/core/test_save.gd` | the autoload in memory under the runner; a legacy v1 save survives (settings applied, PBs kept, written back as v2 with the v1 file as backup); fresh install round trip; corrupt → backup; unreadable → fresh without first run; newer → read-only; settings sanitized, unknown keys kept; load announces changes; autosave at the end of the frame, never while RUNNING; sections; `reset_fresh` |
| `tests/ui/test_settings_panel.gd` | every spec setting has a row on its page; every option writes its setting live and shows selected; changes elsewhere show; CHOOSE LAYOUT / BACK; TILT N/A; text fit on every page and the chooser in the pause menu and on the title (both text sizes, 1280×720 and a notched 1560×720) |
| `tests/ui/test_first_run.gd` | the chooser on a fresh save's PLAY, DRIVE, SKIP (defaults), Esc, DAILY DRIVE, never twice, never when off, DRIVE on the thumb side (mirrored), the sketch, text fit for all four layouts |
| `tests/run/test_first_run_warmup.gd` | 20 s of no vehicles on either carriageway (three seeds), the fade-in beyond the fog, SKIP, countdown and pause not counted, only the first Journey from the title, results kept off the leaderboards, QUIT keeps it pending, off in tests, not on a direct boot, deterministic, title → chooser → warm-up |

## Other storage (not in this save)

| What | Where | Owner |
| --- | --- | --- |
| Device account (tokens, profile) | native: `user://net/session.dat` (AES-encrypted, key from `user://net/install.salt`); web: `localStorage["westbound.net.v1"]` | `NetSession` (N1.2), `NetFileStore` / `NetWebStore` |
| Offline run queue, legacy-upload flags | native: `user://net/runs.dat`; web: `localStorage["westbound.net.v1.runs"]` (per server: a name suffix) | `NetRunsClient` (N7) |
| Daily Drive ghosts (the index is in `daily`) | `user://daily/<date>.ghost` (web: IndexedDB via `/userfs`) | `DailyGhostStore` (WP8.4) |
| Stored replays awaiting upload | native: `user://net/replay_<key>.dat`; web: `localStorage["westbound.net.v1.replay_<key>"]` | `NetRunsClient` (N8.1) |

These keep their own files and formats (atomic temp + rename natively); nothing in WP8.1 reads or writes them.
