# Quality tiers, adaptive governor and thermal

Spec: Performance budget (frame rate, render resolution, quality tiers, **adaptive governor**), Tech stack → Platform services (the native thermal plugin), Implementation milestones → M9 ("the governor steps down and up correctly under a forced thermal state"). Plan: WP0.3 (tiers), WP4.6 (dev quality row), **WP9.1** (governor and thermal). Draw-call and frame numbers are in [PERF.md](PERF.md).

| File | What |
| --- | --- |
| `src/platform/quality.gd` (autoload `Quality`) | `compute()` (pure: tier + rung + platform + battery saver + game state → settings), the applier, and the governor's host: it feeds the governor every frame and applies its rung |
| `src/platform/governor.gd` (`Governor`) | the governor's state machine. Pure, headless, allocation-free per tick |
| `src/platform/thermal.gd` (`Thermal`) | the thermal state: dev override, native plugin, or none |
| `src/ui/hud/widgets/hud_cooling.gd` | the HUD's cooling icon |
| `src/ui/dev_hud.gd` | the dev HUD's `thermal` and `governor` rows and the `THERMAL` button |
| `platform/ios/thermal/`, `platform/android/thermal/` | native plugin sources. **Untested on device** |
| `data/tuning/quality.tres` (`QualityTuning`) | every number below |

## Tiers

| Tier | Render scale | MSAA | View distance | Particles |
| --- | --- | --- | --- | --- |
| Low | 0.6 | off | 500 m | 50% |
| Medium (default) | 0.75 | off | 700 m | 100% |
| High | 0.9 | 2x (off on web) | 800 m | 100% |

Frame cap: 60 in gameplay (countdown, running, crash) and 30 in menus and pause. Battery saver caps at 30. The cap never goes above 60, even on 120 Hz screens. The far plane is the view distance plus `far_plane_margin_m`, just past the fog end.

## Governor

The governor is an offset below the user's tier: rung 0 is the tier itself. It is never saved over the user's setting and never raises any value above what the tier gives.

### Rungs

The rungs are cumulative, in the spec's order.

| Rung | Changes | Low | Medium | High | Who reads it |
| --- | --- | --- | --- | --- | --- |
| 0 | the user's tier | 0.6 · 50% · 500 m · 60 | 0.75 · 100% · 700 m · 60 | 0.9 · 100% · 800 m · 60 | |
| 1 `scale` | render scale −0.1 (floor 0.5) | **0.5** | **0.65** | **0.8** | root viewport `scaling_3d_scale` |
| 2 `particles` | particle count −50% | **25%** | **50%** | **50%** | `JuiceFx` (speed-line and spark caps; re-read on `Events.governor_changed`), `PlayerFx` (hood smoke count, read when its emitter is made) |
| 3 `view` | view distance −150 m | **350 m** | **550 m** | **650 m** | fog (`SkyRig`), far plane (`CameraRig`), road chunk window, roadside, landmarks, biome features, fork view, water ribbon, traffic-view cull. **Held until the run ends** (Simulation safety below) |
| 4 `30fps` | frame cap 30 | 30 | 30 | 30 | `Engine.max_fps` |

A rung that changes nothing for the current settings is skipped both ways. For example, with battery saver on (already 30 fps) the governor stops at rung 3, and with a dev render-scale override rung 1 is skipped. Shadows are already none (blob decals) and MSAA is off on Low and Medium, so there are no rungs for them.

### Rules

| | Rule | Tuning |
| --- | --- | --- |
| Pressure | Thermal is serious or critical, **or** the last 10 s of gameplay frames hold more than 10% that missed vsync. A frame misses when it takes longer than 1.5 frame intervals at the current cap | `governor_window_s`, `governor_miss_frac`, `governor_miss_factor` |
| Down | Under pressure, one rung down, at most one per 10 s since the last change. The first comes at once for thermal, or as soon as the 10 s window is full for frames | `governor_step_down_interval_s` |
| Up | After 60 s of unbroken calm (thermal **nominal** and at most 2% missed frames over a full window), one rung up | `governor_step_up_after_s`, `governor_up_miss_frac` |
| Hold | Thermal fair, or missed frames between 2% and 10%: no step either way, and the calm time starts again | |
| Backoff | A step down within 60 s of a step up doubles the next wait to step up, up to 300 s. A step up that holds for 60 s resets the wait | `governor_relapse_window_s`, `governor_up_backoff_factor`, `governor_step_up_max_s` |
| Outside gameplay | In menus, pause and results, frames are not judged and the calm time holds. Thermal still steps down, so a hot phone also cools in the menus. When gameplay resumes the window starts empty | |
| Hitches | Frames over 0.5 s (loading, the app in the background) are not sampled, and the timers advance at most 0.5 s per frame | `governor_ignore_frame_s` |

These rules give hysteresis in three ways: the 2%/10% band, the 10 s down vs 60 s up asymmetry, and the backoff. With a steady load the governor settles on a rung and stays there.

The autoload measures the real time between frames (`Time.get_ticks_usec`, outside the simulation). It runs the governor every frame, except headless, where tests call `Quality.step_governor(frame_s)` with synthetic frames. A thermal override turns it on headless too.

### Cooling icon

The cooling icon is a small snowflake on a control-bevel panel, centred under the pause button (HudLayout `cooling`, the size of a life icon, scaled with the text size). Its slot is always reserved, so nothing moves when it appears. Hidden, it draws nothing. Shown, it is one draw call that never redraws. It takes no touches. It is clear of the thumb zones, the pedals, the middle third and the other readouts in every layout: both hands, both text sizes, drag or gyro steering, auto or manual pedals, and controls scale 0.8 to 1.2. `tests/platform/test_cooling_icon.gd` checks this, and `tests/ui/test_hud_layout.gd` checks it as part of `HudLayout.rects()`.

**Deviation (flagged, WP9.1):** the spec says the icon shows "while it [the governor] is active". Here it shows only while a thermal step is part of the offset (`Quality.is_cooling()`). A weaker device that sits one rung down for frame time alone would otherwise show a hot-phone icon all the time. `QualityTuning.cooling_icon_any_reason = true` restores the spec's literal rule.

Snapshots: `tools/snap.sh src/ui/hud/dev/hud_preview.tscn --renderer=both --state=idle --cooling=true [--text_scale=1.25] [--hand=left --throttle=manual]`.

### Dev HUD

- **thermal:** `serious  forced`, `fair  native`, or `nominal` (no source). It turns red at serious and critical.
- **governor:** `r2 particles  thermal  last thermal  p95 17.0 ms  miss 0%  cooling`. The fields are the rung and its name, what the governor sees now (`calm`, `hold`, `frames`, `thermal`, or `idle` outside gameplay), the last step's reason, the window's frame-time p95 and missed-frame share, and whether the cooling icon shows. The row is red while a rung is held. The row sits last, so the earlier rows keep their indices.
- **quality:** `medium  gov 2`, as before.
- **THERMAL auto / nominal / fair / serious / critical:** forces the thermal state for the session (M9 gate on a device).

## Simulation safety

The governor may change rendering only. An audit of what the tier values feed (WP9.1, at `284b32f`):

| Value | Reaches the simulation? | Where |
| --- | --- | --- |
| render scale, MSAA | no | root viewport only |
| particle scale | no | `JuiceFx`, `FxParticles`, `SpeedLines`, `PlayerFx`. Their randomness is a fixed `VISUAL_SEED` RandomNumberGenerator, not a run `Rng` stream |
| frame cap (30 fps rung) | no | The simulation runs per 120 Hz tick. Calling `Run.frame()` every 1, 2 or 4 ticks gives the same trace (checked on the Daily run, 30 s) |
| **view distance** | **yes** | see the list below |

The view distance reaches the simulation through `RoadBuilder.view_distance_m()`, which follows `Quality.view_distance_m` and is re-read on `Events.quality_changed` / `governor_changed`:

1. **Spawn distance.** `Run._start_run` (src/run/run.gd:1171) calls `director.set_fog_end(builder.view_distance_m())`, and the director spawns traffic at the fog end. This is read once per run start and retry. It is the tier coupling from [DAILY.md → Findings 3](DAILY.md): Low and Medium runs of the same date differ from second 10.
2. **Leg planner horizon, every tick.** `Run._road_ahead()` (run.gd:942) generates the road to `_view_ahead(s) = s + view distance + 2 chunks`. `legs.plan_ahead(road, _view_ahead(s) + leg length)` queues checkpoint and sign features up to there. The queue length is part of `LegTracker.hash_into`, and so of the run's trace hash (replays, ghosts, the Daily check). A 700 → 550 m change 5 s into the 2026-09-30 Daily run changes the trace (the `legs` component) from second 27. The same `_view_ahead` is used by the respawn, teleport and start paths (run.gd:455, 944, 1144, 1215, 1545).
3. **Fork candidate generation.** `RunForks._advance_candidate` (src/run/run_forks.gd:240) generates the candidate branch all at once instead of a few blocks per tick when the player is within `builder.view_distance_m()` (+ prefetch) of the split.
4. **Defaults, not couplings:** `TrafficDirector` starts from the default tier's fog end (traffic_director.gd:223) until item 1 overwrites it. `DailyTrace` pins the view distance for the determinism check (daily_trace.gd:87). The dev scenes (`car_drive`, `traffic_sandbox`) call `set_fog_end(builder.view_distance_m())` as the run does.

**What WP9.1 does:** the view-distance rung is **held from a run's start to its end** and applied between runs (`governor_view_distance_between_runs = true`). A run is the Game states COUNTDOWN, RUNNING, PAUSED and CRASH, so a retry from the pause menu stays in the held state. While held, `Quality.view_distance_m` and `far_plane_m` stay at the run's start value (they match the fog). `Quality.effective.view_pending` says a rung is waiting. When the run ends (RESULTS or MENU), the value applies and `Events.governor_changed` fires again so every view reader re-reads it. The other rungs apply at once. `tests/platform/test_governor_run.gd` drives the real Run (the Daily run, device view distance, not pinned) through all four rungs and back under a forced thermal script, with 30 fps frame cadence at rung 4. The per-second trace hashes and the leg planner's horizon match an ungoverned run exactly. With the hold switched off, the same run's builder view distance and leg planner horizon move.

**What remains (for N8.2):** a view-distance rung taken in one run still changes the **next** run's spawn distance and planner horizon, just as a different tier does. A user who changes the tier from the pause menu also changes the view distance mid-run, because that is a user action and not held. Both go away when the simulation stops reading the view distance. The spawn distance would become a tier-independent tuning value (DAILY.md's proposal), and `_view_ahead` / the planner horizon / the fork `near` check would read a fixed distance. `Quality.run_view_distance_m` (the user tier's view distance, never the governor's) is there for that switch. After N8.2, set `governor_view_distance_between_runs = false` and the rung applies live.

## Thermal

`Thermal.get_state()` returns `nominal`, `fair`, `serious` or `critical`. The first source that applies wins:

1. **Dev override.** `?thermal=<script>` on the web, or `--thermal=<script>` on the command line; the dev HUD's THERMAL button; or `force()` / `force_script()` in tests. A script is `state[:seconds],...`: each state lasts its seconds of frame time, and the last one holds. `serious` forces serious; `serious:45,nominal` is the M9 check (rungs 1 to 4 at 0, 10, 20 and 30 s; back up at 105, 165, 225 and 285 s); `off` clears it. A boot override also turns the governor on headless.
2. **Native plugin.** The `WestboundThermal` engine singleton, if the build has it. It is read on its signal and polled every `thermal_poll_s` (2 s).
3. **None** (web, desktop, or a build without the plugin): nominal, `available()` false. The governor works from frame times alone.

Plugin interface (both platforms):

| Member | |
| --- | --- |
| `get_raw_state() -> int` | the platform's value: iOS `ProcessInfo.ThermalState` 0..3, Android `PowerManager.THERMAL_STATUS_*` 0..6; −1 unknown |
| `get_platform() -> String` | `"ios"` or `"android"` |
| `is_supported() -> bool` | false where the OS has no API (Android below 10). The plugin is then not attached |
| `signal thermal_state_changed(raw_state: int)` | emitted on the engine thread |

Raw values map to levels through `thermal_ios_levels` = `[0, 1, 2, 3]` (one to one) and `thermal_android_levels` = `[0, 1, 2, 3, 3, 3, 3]` (none, light, **moderate → serious**, severe and above → critical). Android's MODERATE already throttles, so the governor steps down there: act before the OS does (cool_drive THERMAL.md). Unknown values read nominal.

### Native plugins (untested on device)

**iOS** (`platform/ios/thermal/`): an Objective-C++ Godot iOS plugin (`.gdip` + static xcframework). `WestboundThermal` reads `NSProcessInfo.thermalState` and observes `NSProcessInfoThermalStateDidChangeNotification` on the main queue, emitting deferred.

1. On a Mac with Xcode, with a Godot 4.7-stable source checkout whose headers are generated: `GODOT_SRC=… platform/ios/thermal/build.sh release`.
2. Copy `westbound_thermal.gdip` and `bin/westbound_thermal.xcframework` to `res://ios/plugins/westbound_thermal/`.
3. Tick the plugin in the iOS export preset (`plugins/WestboundThermal=true` in `export_presets.cfg`), then export.

**Android** (`platform/android/thermal/`): a Godot Android plugin v2 in Kotlin (AAR). `get_raw_state` reads `PowerManager.getCurrentThermalStatus()`. An `OnThermalStatusChangedListener` is registered on resume and removed on pause, and it emits on the render thread.

1. `cd platform/android/thermal && gradle :plugin:assemble` (JDK 17, Android SDK 35; the Godot library version in `plugin/build.gradle.kts` must match the export templates).
2. Copy `addon/westbound_thermal/` to `res://addons/westbound_thermal/`, and the AARs to its `bin/` as `westbound_thermal-debug.aar` and `westbound_thermal-release.aar`.
3. Enable the editor plugin (`project.godot` `[editor_plugins]`) and use a Gradle build in the Android preset (`gradle_build/use_gradle_build=true` with the Android build template installed), then export.

Both source folders carry a `.gdignore`, so Godot, `tools/lint` and `tools/check_warnings.sh` skip them until they are installed.

### On device (owner)

1. Build and install the plugins as above. The dev HUD's thermal row should say `nominal  native`, not just `nominal`.
2. **M9 gate:** in a run, tap THERMAL until it reads `serious`. The governor row should step `r1 scale` → `r2 particles` → `r3 view` → `r4 30fps` about 10 s apart, with the cooling icon under [II]. Tap to `nominal`: it should step back one rung a minute to `r0` and the icon should go away. On the web, `?thermal=serious:45,nominal` does the same without taps.
3. **Acceptance soak (D4):** a 20-minute drive at Medium on the iPhone 13-class device. Record the governor row (COPY) at 5, 10, 15 and 20 minutes. A real `serious` there is a thermal failure of the budget, not a governor bug.

## Tests

| File | What |
| --- | --- |
| `tests/platform/test_governor.gd` | the rules above with synthetic frames: timings, hysteresis band, fair holds, outside gameplay, hitches, backoff and cap, skipped rungs, p95, determinism (trace hash), no allocations per tick, a tuning double |
| `tests/platform/test_quality_governor.gd` | through `Quality`: forced thermal down and back up, frame time without the icon, never above the user's tier (every tier, battery saver), battery saver skips the fps rung, the view-distance hold and its release, the switch off, dev stats and dev HUD rows |
| `tests/platform/test_governor_run.gd` | the real Run: all rungs mid-run, trace unchanged (M9 gate + simulation safety) |
| `tests/platform/test_thermal.gd` | plugin double (iOS and Android maps, signal, poll, unsupported), override scripts, dev cycle |
| `tests/platform/test_cooling_icon.gd` | placement in every layout, follows the governor, draw calls, no touches |
