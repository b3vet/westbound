# Acceptance sweep (WP9.5)

Sep 30, 2026 · branch `wp/9.5` off `claude/game-implementation-phases-asl5jz` @ `5949a38` · plan [§7 Phase 9](IMPLEMENTATION_PLAN.md#phase-9--hardening-and-release-m9) ("every acceptance test in the spec, as a checklist, run and recorded")

Every acceptance item of [`WESTBOUND HANDOFF.md`](../WESTBOUND%20HANDOFF.md) (the spec) and [`WESTBOUND_MULTIPLAYER_HANDOFF.md`](../WESTBOUND_MULTIPLAYER_HANDOFF.md) (the MP spec): the performance acceptance test, every per-system **Tests** list, the feel targets, the fairness rules, the hard budget rules, the resource budget, the MP **Testing** section, and every milestone's *done when*. Each row says how it is verified, what the latest run gave, and a status.

**Status key:** ✅ pass · ⚠️ pass with a deviation (Dn / MP-Dn) or a caveat named in the notes · ❌ fail · 📱 needs the owner's device · 👤 open owner decision.

**Test references:** `dir/test_x.gd::method` under `tests/` (GDScript, `tools/test.sh`); `crate::file::fn` under `westbound-server/crates/` (Rust). "fast ✓" = passed in this sweep's fast tier; "soak ✓" = passed in this sweep's soak tier; see [What ran](#what-ran).

## Summary

**205 checklist rows.** Each row is counted once, under the first of ❌ → 📱 → 👤 → ⚠️ → ✅ that it carries:

| ✅ pass | ⚠️ pass with a deviation | ❌ fail | 📱 needs the device | 👤 owner decision |
| --- | --- | --- | --- | --- |
| 136 | 44 | 2 | 18 | 5 |

Counting every icon a row carries: ⚠️ 57, 📱 19, 👤 7.

**WP9.6 update (Sep 30, 2026, branch `wp/9.6`):** six of the eight ❌ rows are fixed (SP-T1, M3, PL-1..PL-4; proposed deviations D33, D34 and D27's text). M6 improved but stays ❌ (O9), and M9 follows it. The counts above are after WP9.6; WP9.5's were ✅ 134, ⚠️ 40, ❌ 8, 📱 18, 👤 5.

What passed:

- the fast tier (1,969 tests) and the Rust gate (408 tests);
- determinism, native vs wasm (300 / 300 s);
- the netcode acceptance and the load test (every target met);
- the web smokes, the draw calls and renderer parity.

What failed:

- the traffic soak's collision gate, on a checker-heading case;
- one milestone criterion that no test covered before this sweep;
- four of the plan's own soak thresholds.

### ❌ Failures

| Row | One-line cause |
| --- | --- |
| **M6** all set pieces appear in a full journey | WP9.6: 5 whole journeys met 1, 1, 1, 4 and 3 set pieces (2.0 per journey, 4 of 8 kinds; WP9.5: 0.67, 2 kinds). Rolling pieces at 105–125 km/h need 2–4 km of clear road at the bot's ~150 km/h pace, which the journey road rarely has ([F2](#f2-set-pieces-rarely-appear-in-a-real-journey)). O9 open |
| **M9** every acceptance test passes | Follows from M6 plus the 📱 items. The governor part passes headless |

Fixed in WP9.6 (was ❌): **SP-T1 / M3** (collision criterion D34 + the long-vehicle merge guard; spot checks pass), **PL-1** (the soak bot overtakes a slow vehicle), **PL-2** (cap 120 on 4-lane roads, D33), **PL-3** (one-sided bound), **PL-4** (4 runs, D27 text).

### 📱 Owner's iPhone session (concise)

1. **Native iOS build with the thermal plugin.** The dev HUD's thermal row reads `nominal  native`.
2. **M9 governor.** In a run, tap THERMAL to `serious`. The governor should step `r1 scale` → `r2 particles` → `r3 view` → `r4 30fps` about 10 s apart, with the cooling icon under [II]. Tap to `nominal`: it should climb back one rung a minute to `r0`, and the icon should go.
3. **D4 / M1 soak.** 20 minutes at Medium at 200–280 km/h. COPY the dev HUD at 0, 5, 10, 15 and 20 min. It should hold 60 fps and never reach `serious`.
4. **Gyro (native).** Steer in both landscape orientations, including a flip mid-drive. Check the calibration during the countdown and RECAL in pause.
5. **Web gyro (Safari).** The motion prompt should appear from a tap and steering should work. Then decide O5 (keep on the web, or native only).
6. **Haptics and audio (native).** Pass light, close medium, thread heavy, bank double, hit 150 ms burst, crash 400 ms. Every scoring event should feel instant.
7. **Daily Drive on two devices** (the phone plus a desktop browser) on the same date: the same route, forks and traffic.
8. **Later, when multiplayer can be tested on phones:**
    - a 30-minute crew session of at least 4 phones over cellular. It covers N4 (same traffic), N5 (a full lap) and N9 (a party of 3 from an invite link);
    - one phone through Network Link Conditioner at 150 ms / 2 %;
    - after the Keychain plugin and Apple / Google (MP-D2): N1, the account survives a reinstall and signs in on a second device;
    - N7 boards on iOS, Android and web; Game Center achievement mirroring; Android (D5).

### 👤 Owner decisions

**Deferred to the owner's playtest (owner, 2026-09-30; not blocking):**

- **O1** How racers get past the player: the current weaving stays (D17, SP-T20).
- **O2** Traffic spawn distance: 800 m stays, against the spec's ~750 m and the old 700 m (MP-D14, SP-T9).
- **O3** Speed lines under reduced motion: they stay on (D32, SP-K3 / SP-U4).
- **O4** A warning sound or haptic for TOO SLOW, set-piece warnings, the shoulder penalty and HESITATED: none for now (SP-U7).

**Still open:**

- **O5** Web gyro on the iPhone: keep it on the web or make it native-only. It works through the `devicemotion` bridge; the M2 decision was never recorded (WEB.md).
- **O6** Cockpit camera improvements (feel and look; plan §10).
- **O7** Should roadside props repeat on every loop lap? Today the scatter differs per lap (LOOP_MAP.md).
- **O8** The D12 two-lane slow wall. Options: a lower density cap on 2 lanes, a right-lane flow at or above the minimum speed, or a lower minimum speed on 2-lane sections (PASSABILITY.md).
- **O9 (F2)** Set pieces in a real journey. WP9.6 tuned the director (0.67 → 2.0 per journey, 2 → 4 kinds), short of 4–8: the options are in SPAWNING.md, *Set pieces in a real journey*.
- ~~O10 (F1)~~ Decided (orchestrator) and done in WP9.6: gate on bodies and the drawn heading (proposed D34) plus the long-vehicle merge guard.
- ~~O11~~ Decided (orchestrator) and done in WP9.6: PL-2 by data (cap 120 on 4 lanes, D33), PL-3 one-sided.

Orchestrator-level open items (not owner questions):

- D21's braking-limited bound and greedy path extraction;
- slipstream has no sound or visual (FEEL.md);
- `shadow_contacts` retention;
- the web render-scale proposal (PERF.md);
- deploying the current branch: production runs `0793a8a` (PR-1).

The spec's own open questions stay open (final roster, music, two-way stretches, cloud save; MP: VPS transfer allowance, push, soft-solid, loop v2, web sign-in).

## What ran

All runs were on this container (4 vCPU, shared with other agents, load average 1–9), at `5949a38` + this WP. Everything ran under `nice`; cargo used its own target dir with debuginfo off.

| Check | Command | Wall | Result |
| --- | --- | --- | --- |
| Fast tier | `tools/test.sh` | 710 s | **ALL PASSED, 1,969 tests** (697 s in the runner). 16 tests took over the 5 s budget on the loaded box. The known load-flaky benches (`test_ocean.gd::test_frame_cost_while_driving`, `test_landmarks.gd::test_update_view_cost`) passed first time |
| Lint | `tools/lint`, `tools/lint --strict` | < 10 s | clean |
| Warnings | `tools/check_warnings.sh` | ~1 min | 650 scripts, **0 with warnings/errors** |
| Soak tier | `--tier=soak`, one process per file (20 files, 34 soaks incl. the new one), 3 in parallel, cap 3,600 s each | **2,626 s** (44 min) | 16 files pass, **4 fail** (PL-1..4). None skipped or shortened. Longest: verifier 1,838 s, traffic metrics 1,032 s, racer weave 710 s, loop 621 s, traffic sim 542 s |
| Traffic soak gate (spot) | `tools/soak.sh --km=500 --shards=4 --all-pieces` | 942 s | 504 km, 18 runs, 3.7 sim h: **GATE FAILED**, `collision_pairs` 27 (F1); every other gate 0; impossible windows 0 / 13,367 checks; director passability 1,746 checks, 0 failed; set pieces 90 (tolls 56, tunnels 24, merge 5, slalom 2, wall 2, roadblock 1) |
| Determinism | `tools/determinism/compare.sh --seconds=300 --driver=bot --replay --no-export` | 404 s | **IDENTICAL 300 / 300 s** (score 20,948, 49 cars); DetMath probe identical on all 10 functions; both replays (50,551 B) accepted by the native verifier (`playback=resim`) |
| Web export | `tools/export_web.sh` | 24 s | 46.8 MiB, 13.0 MiB gzip to the title |
| Web smoke | `node tools/web_smoke/smoke.mjs --settle 5000` | 39 s | PASS (first paint 0.12 s, title 9.8 s) |
| | `… --audio-unlock tap` | 55 s | PASS: suspended at boot, running 1.8 s after the tap, music playing |
| | `… --stale` | 47 s, then 21 s | Under load: the reload worked, but it FAILED the animation check (5 frames in 3 s). Rerun on a quiet box: **PASS** |
| | `… --gzip --network 4g` | 48 s | PASS (title 23.0 s, 16.6 MiB) |
| Draw calls | `tools/drawcalls.sh src/run/run.tscn …` (city leg 7 at leg-8 density, chase and hood; valley leg 8 at `sky_t` 0.7; loop city at night) | 4 × ~50 s | 69 / 69 / 72 / 73 frozen with HUD + dev HUD + dev buttons; moving max 80; ≤ 93k triangles |
| Parity | `tools/parity.sh src/sun/dev/look_preview.tscn --sweep=sky_t:0,0.2,0.38,0.5,0.58,0.66,0.85` | 53 s | 7 / 7 ok |
| Rust gate | `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test --workspace` | 108 s + 326 s | fmt ✓, clippy ✓, **408 passed, 0 failed, 10 ignored** |
| Rust long | `cargo test --release -p sim --test soak soak_hour_rush -- --ignored` | 45 s (+ 656 s release build) | ✓: 3,600 s simulated, 0 collisions, 0 violations, min blinker 1.050 s |
| | `NETCODE_SECS=300 cargo test --release -p server --test netcode acceptance_long -- --ignored` | 303 s | ✓: claims 99.72 %, 0 false hits, corrections 5 mm / 0.310 m, late 0.50 per 10 bot-min, 0 offences |
| Load test | `taskset -c 0 westbound-server serve` + `taskset -c 1-3 loadtest --rooms 20 --bots 8 --rtt 150 --jitter 30 --loss 0.02 --secs 300 --warmup 15` | 320 s | **RESULT PASS**: CPU 36.2 %, tick p99 ≤ 3 ms, RSS 107.9 MB, worst down 4.92 KB/s, claims 99.93 %, 0 false hits, corrections 5 mm / 0.280 m, late 0.11. `dockerd` had stopped (`docker info` worked at the start, `/var/run/docker.sock` was gone later), so this used the documented host path |
| Production | read-only `curl` of `/api/v1/health`, `/r/K7QX2M`, `/.well-known/*` | < 5 s | PR-1..3 |
| Classification | the four failing soaks on `b76c162` (before N8.2); the bot soak on `3766450` (WP6.10) | ~10 min | See PL-1..4 |
| Diagnosis | two scratch scripts replaying soak run 1 and bot run 3 (under `tests/out/diag/`, not committed) | ~15 min | F1, PL-1 |

**WP9.6 re-runs** (branch `wp/9.6`, same container, shared, under `nice`):

| Check | Command | Result |
| --- | --- | --- |
| Fast tier | `tools/test.sh` | 1,977 passed and 1 failed (`test_tuning.gd::test_ref_max_active_vehicles`, pinned 90). Updated for D33 and re-run: passes. 1,978 tests with WP9.6's 9 new ones |
| Lint, warnings | `tools/lint --strict`, `tools/check_warnings.sh` | clean; 652 scripts, 0 with warnings/errors |
| Soaks PL-1..PL-4 | `--tier=soak --filter=…` one each | all pass (numbers in the rows) |
| Journey acceptance | `--filter=test_acceptance_journey` (5 journeys) | passes: 10 pieces, 4 kinds (floor 6 and 3), every route biome |
| Traffic soak spot checks | `tools/soak.sh --km=500 --shards=4 --all-pieces` and `--canyon` | both GATE PASSED, 0 impossible windows (SOAK.md, *WP9.6*) |
| Metrics baseline | `tools/soak.sh --update-baseline` | rewritten deliberately (set pieces per leg 0.023 → 0.133) |
| Rust gate | `cargo fmt --check`, `clippy --all-targets -D warnings`, `cargo test --workspace --locked` (own target dir, debuginfo off) | fmt ✓, clippy ✓, **409 passed, 0 failed, 10 ignored** (+1: `parity::trace_sp_long_merge_120hz`) |
| Exporter | `export_sim_data.gd -- --check` | current (18 files) |
| Determinism | `tools/determinism/compare.sh --seconds=60` | **IDENTICAL 60 / 60 s** |

## Single-player spec

### Performance budget

| ID | Item (spec § Performance budget) | Verified by | Latest result | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| SP-P1 | **Acceptance test (every milestone from M1):** a 20-minute straight-line drive on a real iPhone 13-class device at Medium shows no thermal throttling and holds 60 fps, dev-HUD numbers recorded | Owner on device (docs/QUALITY.md → On device, step 3; docs/playtests/M1.md §2) | Not run: no native iOS build yet | 📱 | D4: only native iOS numbers count. Web on the owner's iPhone: 60 fps, 17 ms frame at leg 8 (PERF.md), not a thermal proxy |
| SP-P2 | Frame rate: 60 fps cap in gameplay, 30 in menus, optional 30 fps battery saver, never above 60 on 120 Hz | `unit/test_quality.gd::test_frame_caps`, `::test_never_above_60_fps`, `::test_governor_fps_rung_in_menu_and_battery_saver` | fast ✓ | ✅ | |
| SP-P3 | Quality tier table (render scale 0.6/0.75/0.9, MSAA off/off/2x, view 500/700/800 m, particles 50/100/100 %); MSAA off on web | `unit/test_quality.gd::test_tier_table_matches_spec`, `::test_msaa_modes`, `::test_web_forces_msaa_off`, `::test_applier_sets_viewport_and_fps` | fast ✓ | ✅ | |
| SP-P4 | Materials, lights, shadows, post: custom unlit / single-light vertex-lit only, one `DirectionalLight3D` with shadows off, no Omni/Spot, no shadow maps, at most one full-screen pass | `tools/lint` (rules WB0xx, docs/TOOLS.md) | clean (`--strict` too) | ✅ | Also `unit/test_road_builder.gd::test_road_and_world_shaders_are_the_same_code`, `ui/test_garage.gd::test_turntable_uses_the_project_shaders_only` |
| SP-P5 | Every shader looks the same on Mobile and Compatibility | `tools/parity.sh src/sun/dev/look_preview.tscn --sweep=sky_t:…` | 7 of 7 keyframes ok (p99.9 ≤ 7, mean ≤ 1.32 of 255) | ✅ | |
| SP-P6 | Draw calls ≤ 100 in gameplay | `tools/drawcalls.sh src/run/run.tscn …` (below) | City at leg-8 density (89 cars): **69** with HUD + dev HUD + dev buttons (moving mean 66, max 70; 3D 41), chase and hood alike; valley at leg 8 near night: 72 (moving max 80); loop city at night: 73 (moving max 76) | ✅ | Container Compatibility renderer; draw counts carry over to devices (PERF.md) |
| SP-P7 | Triangles ≤ 150k visible | `tools/drawcalls.sh` (same runs) | 65k (city) to 93k (valley, moving) | ✅ | |
| SP-P8 | Far plane just past the fog end; nothing drawn fully inside fog | `unit/test_quality.gd::test_far_plane_is_view_distance_plus_margin`, `unit/test_sky.gd::test_fog_tracks_view_distance`, `unit/test_camera_rig.gd::test_far_plane_from_quality` | fast ✓ | ✅ | |
| SP-P9 | Blob shadow under every vehicle, no shadow maps | `unit/test_road_builder.gd::test_blob_shadow_on_road_under_vehicle`, `::test_blob_shadow_node_and_multimesh`; lint | fast ✓ | ✅ | |
| SP-P10 | Particles clamped in size and count per tier | `fx/test_juice_fx.gd::test_tier_clamps_particle_counts`, `::test_speed_lines_are_one_mesh_clamped_by_tier` | fast ✓ | ✅ | |
| SP-P11 | HUD labels update only when their value changes; nothing animates when idle | `ui/test_hud.gd::test_labels_change_only_when_the_shown_value_changes`, `::test_idle_hud_hides_what_it_does_not_show`, `platform/test_cooling_icon.gd::test_hidden_draws_nothing_and_shown_never_redraws` | fast ✓ | ✅ | |
| SP-P12 | CPU: sim ticks allocate nothing | `run/test_run.gd::test_ticks_create_no_objects`, `unit/test_traffic_sim.gd::test_ticks_do_not_grow_memory`, `unit/test_scoring.gd::test_no_allocations_over_a_long_scripted_run`, `unit/test_passability.gd::test_checks_allocate_nothing`, `unit/test_road_path.gd::test_sample_into_allocates_nothing` (+ ~20 more `*allocat*` tests) | fast ✓ | ✅ | |
| SP-P13 | Far traffic (beyond 200 m) at 30 Hz, near at 120 Hz | `unit/test_traffic_sim.gd::test_far_vehicles_tick_at_30_hz_close_to_reference` | fast ✓ | ✅ | |
| SP-P14 | **Adaptive governor:** serious thermal or > 10 % missed vsync over 10 s steps down one rung every 10 s (scale −0.1 floor 0.5, particles −50 %, view −150 m, 30 fps); up one rung after 60 s nominal; never above the user's tier; a separate offset never saved; cooling icon | `platform/test_governor.gd` (18 tests), `platform/test_quality_governor.gd` (9), `platform/test_governor_run.gd` (2), `platform/test_cooling_icon.gd` (6), `unit/test_quality.gd::test_governor_*` | fast ✓ | ⚠️ | D30 (icon only for a thermal step), D31 (view rung between runs: now live by default after N8.2, `test_view_distance_live_by_default`) |

### Core loop: Chase the Sun

| ID | Item (spec § Core loop) | Verified by | Latest result | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| SP-L1 | Sinking: afternoon → sunset in 5 min at the base rate | `unit/test_sun_clock.gd::test_five_minutes_to_sunset_at_base_rate`, `::test_reset_starts_in_the_afternoon` | fast ✓ | ✅ | |
| SP-L2 | Too slow: sinks 3× faster | `unit/test_sun_clock.gd::test_too_slow_sinks_three_times_faster` | fast ✓ | ✅ | |
| SP-L3 | Checkpoint lift 40 % of the day span + up to 20 % for pace; never earlier than the run's start | `unit/test_sun_clock.gd::test_checkpoint_lift_and_pace_bonus_bounds`, `::test_lift_never_earlier_than_run_start` | fast ✓ | ✅ | |
| SP-L4 | Nudges: a thread lifts 1 %; five close passes within 10 s lift 1 % | `unit/test_sun_clock.gd::test_thread_and_close_pass_nudges_lift_one_percent`, `unit/test_scoring.gd::test_five_close_passes_in_10s_nudge_the_sun` | fast ✓ | ✅ | |
| SP-L5 | Sun 15–30° off the camera axis (glare rule) | `unit/test_road_path.gd::test_sun_band`, `::test_sun_band_other_seeds`; soak `::soak_sun_band_and_crests_many_seeds`; loop: `road/test_loop_road_path.gd::test_glare_rule` | fast ✓, soak ✓ | ✅ | The loop relaxes the band (MP-D3 note, LOOP_MAP.md) |
| SP-L6 | Night: ×2 on everything scored, including leg bonuses and objectives | `unit/test_scoring.gd::test_speed_factor_and_night`, `::test_bonus_goes_straight_to_banked_with_night_factor`, `run/test_run_legs.gd::test_objective_completion_pays_at_night_x2` | fast ✓ | ✅ | |
| SP-L7 | Night: same traffic density as the leg's day | `unit/test_traffic_director_waves.gd::test_night_keeps_the_leg_density` | fast ✓ | ✅ | |
| SP-L8 | Night has no timer; the next checkpoint plays a 6 s dawn (night → dawn → morning) while play continues; `sky_t` lands at morning | `unit/test_sun_clock.gd::test_night_has_no_timer`, `::test_dawn_transition_exactly_six_seconds_and_lands_at_morning`, `::test_checkpoint_during_nightfall_brings_dawn` | fast ✓ | ✅ | |
| SP-L9 | Legs ~3.5 km; warning signs at 1 km and 500 m | `unit/test_leg_tracker.gd::test_warnings_at_1km_and_500m_once_each`, `world/test_landmarks.gd::test_warning_signs_at_exactly_the_warning_features`, `unit/test_tuning.gd::test_ref_legs` | fast ✓ | ✅ | |
| SP-L10 | Crossing a checkpoint: banks, lifts / dawns, pays bonuses, restores a life on a clean leg, 2.5 s non-blocking toast | `run/test_run.gd::test_checkpoint_crossing_runs_the_leg_sequence`, `::test_clean_leg_restores_a_life`, `ui/test_hud_leg.gd::test_toast_lasts_leg_toast_s_and_does_not_block` | fast ✓ | ✅ | |
| SP-L11 | Leg bonuses Clean / Pace / Threads (3+) / Heat (10× for 15 s); night doubles them | `unit/test_leg_tracker.gd::test_clean_leg_fact`, `::test_pace_fact`, `::test_threads_fact`, `::test_heat_fact`, `::test_bonus_list_and_points` | fast ✓ | ✅ | |
| SP-L12 | One optional objective per leg ("5 close passes", "thread twice", "no braking"), paid on completion | `core/test_leg_objectives.gd` (18 tests), `run/test_run_legs.gd::test_objective_progress_reaches_the_feed` | fast ✓ | ✅ | |
| SP-L13 | Forks: signs name both branches 1 km ahead; the side of the road at the split picks | `run/test_forks.gd::test_fork_is_announced_at_one_km_with_both_biomes`, `::test_left_side_takes_the_left_branch`, `::test_right_side_takes_the_right_branch_seamlessly` | fast ✓ | ⚠️ | D18 (no traffic on a branch before the pick; left = stay, right = advance) |
| SP-L14 | The coast after 8 legs: finale (ocean, 3 s wide swing in a traffic-free breather, car holds its lane), journey bonus, "Journey complete" recorded; the road continues endless | `run/test_journey.gd::test_full_journey_through_forks_to_the_coast_finale`, `::test_finale_waits_for_a_clear_breather`, `::test_journey_complete_is_recorded_once_in_the_save`; soak `::soak_full_journey_without_teleports`; `unit/test_leg_tracker.gd::test_coast_after_eight_legs_then_endless` | fast ✓, soak ✓ | ✅ | |
| SP-L15 | Daily Drive: seed from the UTC date; same route, forks, traffic and set pieces for everyone; best run's ghost at 20 Hz (`s`, `d`, heading) | `unit/test_contracts.gd::test_run_context_daily`, `run/test_title_flow.gd::test_daily_drive_uses_todays_utc_seed_and_retry_keeps_it`, `unit/test_daily_source.gd::test_same_date_same_road_traffic_and_set_pieces`, `run/test_journey.gd::test_daily_drive_same_date_same_forks_and_route`, `meta/test_daily_ghost.gd::test_recorder_samples_at_20_hz`, `meta/test_daily_run.gd` | fast ✓ | ✅ | |
| SP-L16 | Results screen: score, distance, legs, coast, best chain, best multiplier, threads, close passes, top speed, time at night, hits; PB comparison; Retry and Garage | `ui/test_run_screens.gd::test_results_show_every_payload_key`, `::test_results_new_best_badge_and_comparison`, `meta/test_garage_run.gd::test_results_garage_opens_the_garage` | fast ✓ | ✅ | |
| SP-L17 | Retry puts the player back on the road within 2 s | `ui/test_run_screens.gd::test_retry_is_back_on_the_road_within_budget` | fast ✓ | ⚠️ | D13 (the countdown runs at 0.5 s per step on a retry: driving 1.5 s after RETRY) |

### Scoring (M4: "every event, anti-exploit rules, banking, loss cases")

| ID | Item (spec § Scoring) | Verified by | Latest result | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| SP-S1 | Points = base × multiplier × speed factor (1.0 at 100 → 2.0 at 250 km/h, clamped) × night factor | `unit/test_scoring.gd::test_pass_scores_base_times_factors_and_adds_one`, `::test_speed_factor_and_night`, `::test_points_round_half_away_from_zero` | fast ✓ | ✅ | |
| SP-S2 | Pass: ahead → behind, centers within 5.4 m laterally; 10, +1 | `unit/test_scoring.gd::test_pass_is_paid_when_the_car_is_fully_behind`, `::test_pass_lateral_window_boundary`, `::test_no_pass_when_player_drops_back_or_is_overtaken`; `integration/test_scoring_loop.gd::test_pass_then_cash_out` | fast ✓ | ✅ | |
| SP-S3 | Close pass: hull clearance < 1.0 m during the overlap; 30, +3, boost +10 % | `unit/test_scoring.gd::test_close_pass_boundary_and_rewards`, `::test_close_pass_clearance_is_minimum_during_overlap`; `integration/test_scoring_loop.gd::test_close_pass_fills_the_boost_meter` | fast ✓ | ✅ | |
| SP-S4 | Cut: lane line at ≥ 140 km/h with traffic within 15 m in the lane left or entered; 15, +1 | `unit/test_scoring.gd::test_cut_scores_with_traffic_nearby`, `::test_cut_boundaries` | fast ✓ | ✅ | |
| SP-S5 | Thread: one car on each side within 0.5 s, both < 1.5 m; 50, +5, boost +25 %, on top of the passes | `unit/test_scoring.gd::test_thread_pays_on_top_of_both_passes`, `::test_thread_window_boundary`, `::test_thread_clearance_boundary_and_sides`, `::test_each_pass_threads_once`; `integration/test_scoring_loop.gd::test_thread_between_two_cars` | fast ✓ | ✅ | |
| SP-S6 | Slipstream: within 15 m behind at ≥ 120 km/h, boost +20 %/s | `unit/test_scoring.gd::test_slipstream_fills_boost`; `integration/test_scoring_loop.gd::test_slipstream_on_and_off` | fast ✓ | ✅ | |
| SP-S7 | Anti-exploit: a cut needs traffic (weaving on an empty road scores nothing); one cut per car per 3 s; nothing during the 2 s ghost; nothing on the shoulder | `unit/test_scoring.gd::test_weaving_on_an_empty_road_scores_nothing`, `::test_cut_per_car_cooldown`, `::test_cut_cooldown_keyed_by_vehicle_id_not_slot`, `::test_nothing_scores_during_the_ghost_period`, `::test_pass_overlapping_the_ghost_end_scores_nothing`, `::test_passing_on_the_shoulder_scores_nothing`; `integration/test_scoring_loop.gd` (same four in the real run), `integration/test_hits_loop.gd::test_nothing_scores_during_the_ghost` | fast ✓ | ✅ | |
| SP-S8 | Multiplier: starts 1.0, no cap (HUD to 999×); decays 0.5/s × (1.0 at 100 → 0.1 at 250 km/h) | `unit/test_scoring.gd::test_multiplier_decay_by_speed`, `::test_multiplier_has_no_cap_and_floor_is_one`, `ui/test_hud.gd::test_multiplier_text_caps_at_999` | fast ✓ | ✅ | |
| SP-S9 | Shoulder: no gains, decay ×3; > 2 s on it blocks gains 3 s more | `unit/test_scoring.gd::test_shoulder_decay_x3_and_no_gains`, `::test_shoulder_penalty_after_2s`, `::test_short_shoulder_visit_has_no_penalty`; `integration/test_scoring_loop.gd::test_passing_on_the_shoulder_scores_nothing_and_penalizes` | fast ✓ | ✅ | |
| SP-S10 | Minimum speed 100 km/h: TOO SLOW + bar, drain 3/s; > 3 s continuous = HESITATED (chain lost, ×1.0); grace until first 100 km/h and 3 s after a hit | `unit/test_scoring.gd::test_too_slow_drains_3_per_s`, `::test_hesitation_after_3s`, `::test_hesitation_needs_continuous_slowness`, `::test_grace_until_min_speed_first_reached`, `::test_grace_after_hit`; `integration/test_scoring_loop.gd::test_too_slow_and_hesitation_lose_the_chain`; `ui/test_hud.gd::test_min_speed_bar_visibility_thresholds` | fast ✓ | ✅ | |
| SP-S11 | Banking at checkpoints and by cashing out (multiplier back to 1.0 while above minimum speed; slower at high speed); bonuses straight to banked; hits / hesitation lose the chain, banked never lost; final score = banked | `unit/test_scoring.gd::test_cash_out_banks_when_multiplier_returns_to_one`, `::test_cash_out_takes_longer_at_high_speed`, `::test_no_cash_out_after_dipping_below_min_speed`, `::test_checkpoint_banks_and_keeps_multiplier`, `::test_hit_loses_chain_but_never_banked`, `::test_run_end_loses_held_chain`, `::test_bonus_goes_straight_to_banked_with_night_factor`; `integration/test_scoring_loop.gd::test_checkpoint_banks_the_chain_and_pays_the_bonus` | fast ✓ | ✅ | |
| SP-S12 | Boost: full meter = 3 s extra thrust and +8 % top speed; raises the speed factor and slows decay | `integration/test_boost_loop.gd` (3 tests), `unit/test_vehicle_physics.gd::test_boost_top_speed_and_feel`, `::test_boost_meter_drain` | fast ✓ | ✅ | |
| SP-S13 | Score feedback: 4-line event stack (PASS, CLOSE!, CUT, THREAD!, HESITATED); multiplier hue-cycles faster as it grows, wobbles above 20×; glitter on high-multiplier close passes and threads; banking count-up with a chime | `ui/test_hud.gd::test_event_stack_keeps_four_lines_and_ages_out`, `::test_every_event_has_its_own_word`, `::test_multiplier_hue_cycles_faster_as_it_grows_and_wobbles_above_20`, `::test_glitter_on_high_multiplier_close_passes_and_threads`, `::test_banking_count_up_converges_to_the_banked_total`, `audio/test_audio.gd::test_banking_counts_up_then_chimes` | fast ✓ | ✅ | |
| SP-S14 | Fairness: camera, control scheme and throttle mode never affect scoring | `integration/test_fairness.gd` (3 tests), `night/test_high_beam.gd::test_high_beams_change_nothing_in_the_run` | fast ✓ | ✅ | |
| SP-S15 | Scoring is deterministic and allocation-free (plan WP3.4 / rule 5–6) | `unit/test_scoring.gd::test_determinism_trace`, `::test_no_allocations_over_a_long_scripted_run`; soak `::soak_dense_traffic_invariants` | fast ✓, soak ✓ | ✅ | |

### Lives, hits and crashes (spec **Tests** list + rules)

| ID | Item (spec § Lives) | Verified by | Latest result | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| SP-H1 | **Collision boxes:** hull overlap agrees with the 8 cm inset boxes up to 350 km/h, no tunnelling between 120 Hz ticks | `unit/test_hit_detection.gd::test_agrees_with_reference_up_to_350_kmh`, `::test_rear_end_at_350_kmh`, `::test_corner_clip_between_ticks_is_not_tunnelled`, `::test_near_misses_that_look_clean_are_clean` | fast ✓ | ✅ | |
| SP-H2 | **First hit:** a scripted first hit leaves the player drivable and above minimum speed within 1 s | `unit/test_lives.gd::test_first_hit_leaves_player_drivable_above_min_speed_within_1s`; `integration/test_hits_loop.gd::test_first_hit_drivable_falcon`, `_viper`, `_brute` | fast ✓ | ✅ | |
| SP-H3 | **Ghost period:** a second contact during the 2.0 s ghost does not count | `unit/test_lives.gd::test_second_contact_during_ghost_does_not_count`, `::test_ghost_lasts_exactly_the_ghost_period` | fast ✓ | ✅ | |
| SP-H4 | **Life recovery:** a clean-leg restore never exceeds 2 lives (tuning switch, on by default) | `unit/test_lives.gd::test_clean_leg_restore_never_exceeds_two`, `::test_restore_switch_off`, `run/test_run.gd::test_clean_leg_restores_a_life` | fast ✓ | ✅ | |
| SP-H5 | First hit: −1 life, chain lost, ×1.0; deflect, −20 % speed, 0.6 s wobble; shake; 0.5× for 0.3 s; hit car swerves, brakes, hazards, recovers ~4 s | `unit/test_lives.gd::test_hit_response_speed_deflection_and_wobble`, `unit/test_traffic_sim.gd::test_hit_swerve_brake_hazards_recover`, `fx/test_slowmo_table.gd::test_the_spec_table`, `run/test_time_scale.gd::test_first_hit_keeps_the_tick_dt` | fast ✓ | ✅ | |
| SP-H6 | Damage for the rest of the run: hood smoke, one flickering headlight | `unit/test_car_visual.gd::test_damage_hook`, `run/test_run.gd::test_hood_smoke_hidden_in_hood_and_cockpit_cameras` | fast ✓ | ⚠️ | D16 (no smoke in hood / cockpit cameras) |
| SP-H7 | Second hit: Jolt hand-off at current velocities with a contact impulse; 0.25× for 2.5 s; orbit camera; traffic brakes; tap skips; bodies back to kinematic next run | `run/test_crash_sequence.gd` (18 tests), `run/test_time_scale.gd::test_crash_quarter_speed`, `integration/test_hits_loop.gd::test_second_hit_crash_results_retry` | fast ✓ | ✅ | |
| SP-H8 | Rear-end prevention: traffic from behind never rear-ends a player driving normally | `unit/test_traffic_sim.gd::test_never_rear_ends_a_player_driving_normally`, `unit/test_racer_arrivals.gd::test_rear_end_prevention_*` (2); soak `unit/test_traffic_sim.gd::soak_never_rear_ends_normal_player`; `tools/soak.sh` counter `rear_end_normal` | fast ✓, soak ✓, soak.sh `rear_end_normal` 0 | ✅ | |
| SP-H9 | No unfair spawns: never overlapping the player or inside the ghost zone | `unit/test_traffic_director.gd::test_never_spawns_overlapping_the_player_or_ghost_zone`, `::test_ghost_zone_default_is_player_box_plus_margins` | fast ✓ | ✅ | |

### Traffic (spec **Tests (headless)** + fairness rules)

| ID | Item (spec § Traffic) | Verified by | Latest result | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| SP-T1 | **Soak:** 10,000 simulated km with a bot driver: zero impossible windows and zero traffic-to-traffic collisions | `tools/soak.sh` (full: `--km=10000`, ~1 h on 4 free cores); spot checks `tools/soak.sh --km=500 --shards=4 --all-pieces` and `--canyon` | **WP9.6 (final tree):** all-pieces 504 km, 18 runs: **every gate 0, GATE PASSED**, impossible windows 0 of 13,328 checks, heading-only pair-ticks 0 (reported); canyon 504 km: every gate 0, 0 of 13,501. (WP9.5: collision_pairs 27 in run 1, [F1](#f1-soak-collision-slow-semi-merging-beside-a-fast-lane)) | ⚠️ | **Proposed D34:** a collision is a body overlap or an overlap as clients draw the cars (`TrafficViewTuning`'s heading), as in the Rust soak (N4.1); WP6.8's ±0.28 rad box is reported as `yaw_only_pairs`, not gated. And the traffic no longer does it: a long vehicle crawling out of its lane waits for a fast car in the lane beyond its target (`long_merge_guard`, neutral on `standstill_beside_fast`: 17 / 8 with and without). SOAK.md, *WP9.6*. Full 10,000 km not re-run (records: M3 10,024 km, WP6.1, M6 gate 2,016 km). D12: the 2-lane slow wall stays open |
| SP-T2 | **Rule checks:** zero lane changes shorter than the minimum signal time; zero no-ambush violations | Soak counters `signal_violations`, `unsignaled_moves`, `ambush_violations` (`tools/soak.sh`); `unit/test_traffic_sim.gd::test_rule_checks_dense_weaving_short`; soaks `::soak_rule_checks_dense_weaving_10_min`, `::soak_rule_checks_four_lanes_fast_player` | fast ✓, soak ✓, soak.sh signal 0, unsignaled 0, ambush 0 | ✅ | |
| SP-T3 | **Determinism:** the same seed gives an identical traffic trace (hash of all states every second) | `unit/test_traffic_sim.gd::test_determinism_trace`, `soak/test_traffic_soak.gd::test_trace_is_deterministic_across_runs_and_shards`, `unit/test_traffic_director.gd::test_deterministic_given_seed_and_trace` | fast ✓ | ✅ | |
| SP-T4 | **Logged metrics per build** (gaps/km, lane changes per vehicle-minute, mean speed per lane, set pieces per leg): a regression beyond ±15 % fails | `unit/test_traffic_metrics.gd::soak_metrics_reference_matches_baseline` vs `tests/baselines/traffic_metrics.json`; `::test_compare_flags_regressions_beyond_tolerance` | fast ✓, soak ✓ (±15 % vs baseline) | ✅ | |
| SP-T5 | Rule 1: blinker 1.0 s before lateral motion (aggressive 0.6, floor 0.5); move 2.0–3.0 s (aggressive 1.5) | `unit/test_traffic_sim.gd::test_registry_profiles_match_spec`, `::test_signal_then_smoothstep_move`, `::test_scripted_signal_on_a_far_vehicle_lasts_the_full_signal_time`; `unit/test_tuning.gd::test_ref_signal_time`, `::test_ref_lane_change_move_time` | fast ✓ | ⚠️ | D15: the racer profile (190–250 km/h) added; its signal is within the rule |
| SP-T6 | Rule 2: no ambush (1.5 s prediction + 1.0 m margin); cancel if the player enters the gap while signalling | `unit/test_mobil.gd::test_no_ambush_predicate`, `::test_no_ambush_refuses_in_the_sim`, `unit/test_traffic_sim.gd::test_cancels_when_player_enters_the_gap`, `unit/test_traffic_director_lane_drops.gd::test_merges_obey_no_ambush` | fast ✓ | ✅ | |
| SP-T7 | Rule 3: brake lights above 1 m/s², brighter above 4 m/s² | `unit/test_traffic_sim.gd::test_brake_light_thresholds`, `unit/test_traffic_view.gd::test_brake_lights_follow_flags`; soak counter `brake_flag_violations` | fast ✓ | ✅ | |
| SP-T8 | Rule 4: deceleration never above 6 m/s² except set pieces announced ≥ 300 m ahead | `unit/test_set_piece_source.gd::test_hard_decel_only_after_a_300m_warning`, `::test_scripted_vehicles_keep_the_clamp_without_permission`, `::test_rule_checker_allows_hard_decel_only_to_warned_set_pieces`, `traffic/test_set_pieces_rolling.gd::test_no_hard_braking_*`; soak counter `decel_violations` | fast ✓ | ✅ | |
| SP-T9 | Rule 5: no visible pop-in (spawn beyond the fog end ahead, or behind the frustum) | `unit/test_traffic_director.gd::test_ahead_spawns_land_beyond_the_fog_end`, `::test_behind_spawns_only_when_player_slower_and_out_of_frustum`, `run/test_first_run_warmup.gd::test_every_vehicle_arrives_beyond_the_fog`, `run/test_sim_horizon.gd::test_the_horizon_covers_every_tier` | fast ✓ | ⚠️ 👤 | MP-D14: spawns past 800 m on every tier (spec "about 750 m"). O2 800 vs 700 m: **deferred to owner playtest** (800 m stays), not blocking |
| SP-T10 | Rule 6: within 150 m after a blind crest or bend, density ≤ 60 % and no set pieces; warning signs before sharp sections | `unit/test_traffic_director_waves.gd::test_blind_windows_cap_density_on_real_roads`, `::test_no_set_pieces_in_blind_windows_or_at_checkpoints`, `unit/test_road_path.gd::test_blind_crests_flagged_and_real`, `::test_no_unflagged_blind_crests` | fast ✓ | ✅ | |
| SP-T11 | Rule 7: right-hand traffic; lane flow speeds rise to the left; slow profiles keep right | `unit/test_spawn_sources.gd::test_lane_flow_speed_ordering`, `::test_slow_profiles_keep_right`, `unit/test_spawn_mix.gd::test_lane_flows_rise_to_the_left`, `unit/test_mobil.gd::test_keep_right_drift_and_truck_lanes` | fast ✓ | ⚠️ | D15 lane flows 95/120/145/160 |
| SP-T12 | Driver types (8) with their speed bands and behaviours; hesitant from leg 3 (cancels ~20 %); motorbikes split lanes (never during the player's lane change) | `unit/test_traffic_sim.gd::test_registry_profiles_match_spec`, `::test_hesitant_cancel_ratio`, `::test_motorbike_splits_lanes_in_slow_traffic`, `::test_motorbike_never_starts_splitting_during_player_lane_change`, `unit/test_spawn_sources.gd::test_hesitant_only_from_leg_3`; soak `::soak_hesitant_cancel_ratio` | fast ✓ | ⚠️ | D15 (racer added, wider bands) |
| SP-T13 | Traffic reacts: horn after ~30 % of close passes; brake tap on cut-ins < 10 m; hazards after a hit; blind-spot horn after 3 s | `unit/test_traffic_sim.gd::test_honk_and_close_pass_horn_share`, `::test_tight_cut_in_brake_tap`, `::test_blind_spot_horn`, `::test_hit_swerve_brake_hazards_recover` | fast ✓ | ⚠️ | D8: no night-tailgating high beams (`::test_no_automatic_high_beams_at_night`) |
| SP-T14 | Spawning: ~750 m ahead at lane flow speed with IDM gaps; behind ~150 m only when the player is slower and out of frustum; despawn 200 m behind; cap on the carriageway | `unit/test_traffic_director.gd::test_prefill_populates_the_road_ahead`, `::test_despawn_200m_behind_and_beyond_the_window`, `::test_cap_on_the_player_carriageway`, `unit/test_spawn_sources.gd::test_idm_consistent_gaps_within_plan` | fast ✓ | ⚠️ | D11 (cap 90, not 60), MP-D14 (800 m) |
| SP-T15 | Opposite carriageway: visual only, constant speed, lower density, headlights at night | `unit/test_opposite_traffic.gd` (12 tests) | fast ✓ | ✅ | |
| SP-T16 | Director: intensity waves 45–90 s with a 10–15 s breather; every leg ends in a breather; density 8 → 16 per km per lane, aggressive 5 → 20 %, hesitant from leg 3, set-piece variety grows | `unit/test_traffic_director_waves.gd::test_cycles_last_45_to_90_s_with_10_to_15_s_breathers`, `::test_every_leg_ends_with_a_breather_at_its_checkpoint`, `::test_difficulty_ramps_by_leg`, `unit/test_set_piece_source.gd::test_kinds_unlock_by_leg_and_follow_the_biome_mix`, `unit/test_tuning.gd::test_ref_density_by_leg` | fast ✓ | ⚠️ | D11 (leg 8: 18/km/lane), D15/D17 (fast share 15 → 35 %) |
| SP-T17 | All 8 set pieces with their warnings (silhouettes, brake-light ripple, signs 500/250 m, 400 m + arrow board, tunnel portal, toll signs 1 km / 500 m) | `unit/test_set_piece_source.gd` (truck wall, rolling roadblock), `traffic/test_set_pieces_anchored.gd` (merge, works, tunnel, toll), `traffic/test_set_pieces_rolling.gd` (slalom, convoy), `world/test_set_piece_view.gd` | fast ✓ | ✅ | How often they appear in a real journey: see M6 |
| SP-T18 | **Passability guarantee:** forward-sim 10 Hz × 8 s, lateral grid in 0.25 s steps within the car's lane-change capability, a path at ≥ minimum speed never within 0.3 m; re-roll ≤ 5 then remove the worst blocker; runs with a bot driver in tests | `unit/test_passability.gd` (21), `unit/test_passability_director.gd` (8), `unit/test_passability_bot.gd::test_bot_drives_dense_traffic_on_its_path`, soak `::soak_bot_drives_every_lane_count`; the gate soak's passability bot | fast ✓, soak **✗** `soak_bot_drives_every_lane_count` (PL-1) | ⚠️ | The director side holds: `soak.sh` spot check 1,746 batch checks, 0 failed, 0 unresolved; the oracle found 0 impossible windows. The bot soak's own bar fails (PL-1). D21 (the batch is checked beyond the fog, time-sliced; unlimited braking in the search). Open (orchestrator): braking-limited bound, greedy path extraction (PASSABILITY.md) |
| SP-T19 | Traffic sandbox: free cam, time scale, pause / step, spawn controls, overlays (IDM gap, MOBIL incentives, blinkers, predicted occupancy, passability paths) | `unit/test_traffic_sandbox.gd` (11), `unit/test_passability_sandbox.gd`, `net/test_net_traffic_sandbox.gd` | fast ✓ | ✅ | Working rule 10 (review tools alive) |
| SP-T20 | Aggressive / fast traffic "passes the player from behind" (driver table); D17 racers arrive from behind and weave past | `unit/test_racer_arrivals.gd::test_racers_arrive_and_pass_a_*` (4), `unit/test_racer_weave.gd` (15); soaks `::soak_arrivals_in_traffic`, `::soak_racers_pass_through_traffic` | fast ✓, soak ✓ (`soak_density_with_weaving_racers` ✗: PL-3) | ⚠️ 👤 | D15, D17. O1 how racers get past the player: **deferred to owner playtest** (current weaving stays), not blocking |

### Car physics and feel (spec **Tests (headless)** + feel targets)

| ID | Item (spec § Car physics) | Verified by | Latest result | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| SP-V1 | **Lane-change time** 0.80 / 1.00 / 1.15 s at 100 / 200 / 280 km/h ±5 %, for each car | `unit/test_vehicle_physics.gd::test_lane_change_time_each_car`, `::test_capability_agrees_with_simulation` | fast ✓ | ✅ | |
| SP-V2 | **Settling:** overshoot < 5 % of lane width; drift < 0.3 m within 1 s of release; critically damped | `unit/test_vehicle_physics.gd::test_settling_each_car`, `::test_release_straightens_without_oscillation` | fast ✓ | ✅ | |
| SP-V3 | **Straight-line stability:** zero input 60 s on a curve, drift < 0.3 m | `unit/test_vehicle_physics.gd::test_straight_line_stability_on_curve` | fast ✓ | ✅ | |
| SP-V4 | **Performance specs:** top speed and 0–200 km/h within 2 % of each car's spec | `unit/test_vehicle_physics.gd::test_top_speed_each_car`, `::test_zero_to_200_each_car` | fast ✓ | ✅ | |
| SP-V5 | **Determinism:** the same input trace gives an identical state trace | `unit/test_vehicle_physics.gd::test_determinism_same_inputs_same_trace` | fast ✓ | ✅ | |
| SP-V6 | **Robustness:** no NaN or explosion under random input fuzzing for 10 simulated minutes | soak `unit/test_vehicle_physics.gd::soak_fuzz_ten_minutes`, `::soak_fuzz_ten_minutes_on_bends`; fast `::test_fuzz_fast` | fast ✓, soak ✓ | ✅ | |
| SP-V7 | Feel: input to visible yaw < 50 ms | `unit/test_vehicle_physics.gd::test_input_to_visible_yaw` | fast ✓ | ✅ | |
| SP-V8 | Feel: holding full input never spins the car (slip clamp 8°) | `unit/test_vehicle_physics.gd::test_full_input_never_spins` | fast ✓ | ✅ | |
| SP-V9 | Feel: braking 250 → 100 km/h in about 1.3 s (with 9 m/s²) | `unit/test_vehicle_physics.gd::test_braking_each_car` (≈ 3.5–3.8 s) | fast ✓ | ⚠️ | D6 (owner): 9 m/s² stands; the spec's two numbers contradict |
| SP-V10 | Feel: boost felt within 0.1 s (FOV punch, sound, thrust) | `unit/test_vehicle_physics.gd::test_boost_top_speed_and_feel` (thrust), `unit/test_camera_rig.gd::test_shake_and_punch_fade_and_listen_to_events`, `feel/test_one_frame.gd::test_boost` | fast ✓ | ✅ | The camera applies the punch on its next physics tick (FEEL.md → Open) |
| SP-V11 | Steering pipeline: 30° at 0 → 3.5° at 250 km/h, full lock in 0.12 s; road-curvature feed-forward (not lane-centering) | `unit/test_vehicle_physics.gd::test_steering_pipeline`, `::test_sign_conventions` | fast ✓ | ✅ | |
| SP-V12 | Visual body motion: roll ≤ 4°, pitch ≤ 2°, 2.5 Hz / ζ 0.6 spring; wheels spin and steer; never feeds back | `unit/test_car_visual.gd::test_step_response_is_a_2_5_hz_spring_with_damping_0_6`, `::test_roll_and_pitch_never_exceed_their_maxima`, `::test_visual_never_mutates_state_or_input` | fast ✓ | ✅ | |
| SP-V13 | Car stats: top speed 240–300 km/h, every stat within ~±10 % across the roster; handling scales lane change 0.9–1.1 | `unit/test_vehicle_physics.gd::test_car_roster_stats_within_spec`, `::test_vehicle_type_scales_lane_change` | fast ✓ | ✅ | |

### Controls (spec **Tests**)

| ID | Item (spec § Controls) | Verified by | Latest result | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| SP-C1 | **Mapping:** the steering curve maps correctly at the dead-zone edge, midpoint and full input | `unit/test_drag_control.gd::test_mapping_edge_mid_full`, `unit/test_gyro_control.gd::test_mapping_edge_mid_full`, `unit/test_steering_input.gd::test_drag_mapping`, `::test_gyro_mapping_in_degrees` | fast ✓ | ✅ | |
| SP-C2 | **Gyro:** sign correct in both landscape orientations (and flipping mid-run) | `unit/test_gyro_control.gd::test_sign_in_both_landscape_orientations`, `::test_flip_mid_run_keeps_neutral_and_sign` | fast ✓ | ✅ | Real sensor: 📱 (DEV-2) |
| SP-C3 | **Drag anchor:** follows past `max_drag` (2.5 cm physical) | `unit/test_drag_control.gd::test_anchor_follows_past_max_drag`, `::test_max_drag_is_physical` | fast ✓ | ✅ | |
| SP-C4 | **Keyboard:** the steering ramp reaches full input in 0.15 s | `unit/test_keys_gamepad.gd::test_ramp_reaches_full_in_015s` | fast ✓ | ✅ | |
| SP-C5 | **Equivalence:** all four layouts produce identical physics for the same inputs | `unit/test_player_controller.gd::test_equivalence_identical_physics_all_layouts`, `::test_equivalence_steady_values_with_real_tuning` | fast ✓ | ⚠️ | D9 (joined gas + boost cap), D10 (wheel visual) |
| SP-C6 | Drag details: 4 % dead zone, exponent 1.6, release to 0 in 80 ms, down-drag brake > 30 %, flick-up boost > 0.6 m/s | `unit/test_drag_control.gd::test_release_ramps_to_zero_in_80ms`, `::test_down_drag_brake_threshold`, `::test_flick_up_fires_boost_once` | fast ✓ | ✅ | |
| SP-C7 | Gyro details: 25° max, 2° dead zone, 60 ms low-pass, calibration in the countdown, Recalibrate in pause | `unit/test_gyro_control.gd::test_smoothing_time_constant_60ms`, `::test_calibrated_neutral`, `ui/test_run_screens.gd::test_gyro_recalibrates_through_the_countdown_and_locks_at_go` | fast ✓ | ✅ | |
| SP-C8 | Web gyro: iOS Safari permission from a gesture; if unreliable, native-only and hidden on web | `ui/test_run_screens.gd::test_web_motion_permission_holds_the_countdown_until_a_tap`, `::test_gyro_option_disabled_where_there_is_no_tilt` | fast ✓ | 👤 📱 | Works through the game's `devicemotion` bridge; the M2 decision was never recorded (WEB.md → Web gyro). O5 / DEV-3 |
| SP-C9 | Touch ids: never index by `InputEventScreenTouch.index` (iOS Safari raw ids) | `unit/test_player_controller.gd::test_ios_touch_ids_drag_steer`, `::test_touch_slots_map_arbitrary_ids`, `unit/test_dev_hud.gd::test_three_finger_tap_with_ios_touch_ids` | fast ✓ | ✅ | |
| SP-C10 | Settings + first run: chooser (default drag + auto), 20 s empty-road warm-up | `ui/test_first_run.gd`, `run/test_first_run_warmup.gd::test_twenty_seconds_of_empty_road_then_traffic`, `ui/test_settings_panel.gd::test_every_spec_setting_has_a_row_on_its_page` | fast ✓ | ⚠️ | D22–D25 |
| SP-C11 | M2 on device: drag and gyro both feel precise | Owner (docs/playtests/M2.md) | Owner M2 playtest passed on web (plan §9) | 📱 | Gyro on native (DEV-2) |

### Cameras

| ID | Item (spec § Cameras) | Verified by | Latest result | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| SP-K1 | Four modes (chase default, far, hood, overhead); spring follow; cycling saved | `unit/test_camera_rig.gd::test_modes_frame_the_car_ahead`, `::test_cycle_mode_wraps_saves_and_emits`, `::test_saved_mode_restored_at_startup`, `::test_spring_step_converges_with_bounded_overshoot` | fast ✓ | ⚠️ | D11: cockpit camera added now (`camera/test_cockpit_camera.gd`, 17 tests) |
| SP-K2 | FOV 62° at 100 km/h → 78° at top speed; distances pull back ≤ 15 %; look-ahead ≤ 1.2 m; roll ≤ 1.5° | `unit/test_camera_rig.gd::test_fov_mapping`, `::test_pullback_scales_with_speed_up_to_15_pct`, `::test_look_ahead_bounded_and_toward_lateral_velocity`, `::test_roll_bounded_and_into_the_turn` | fast ✓ | ✅ | |
| SP-K3 | Reduced motion turns off shake, roll, FOV punch (and slow motion) | `unit/test_camera_rig.gd::test_reduced_motion_zeroes_roll_shake_and_punch`, `fx/test_slowmo_table.gd::test_reduced_motion_turns_slow_motion_off`, `a11y/test_reduced_motion.gd` (5) | fast ✓ | ⚠️ 👤 | D32 (wider). O3 speed lines under reduced motion: **deferred to owner playtest** (they stay on), not blocking |
| SP-K4 | Scripted: crash orbit at 0.25×; 3 s finale swing in a traffic-free breather; menu drive-by; no scripted camera while traffic can hit | `run/test_crash_sequence.gd::test_orbit_camera_is_current_and_frames_the_bodies`, `run/test_journey.gd::test_finale_waits_for_a_clear_breather`, `run/test_title_flow.gd::test_the_attract_car_drives_and_cannot_be_hit` | fast ✓ | ✅ | |
| SP-K5 | Glare: rim term strongest when backlit; taillights and brake lights always emissive | `unit/test_traffic_view.gd::test_brake_lights_follow_flags`, `::test_headlights_only_with_the_flag_and_tail_glow_at_night`; rim light is shader-only (snaps) | fast ✓ | ✅ | The rim term has no numeric test (visual; snaps at WP3.1) |

### World, road, look, night

| ID | Item (spec § World) | Verified by | Latest result | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| SP-W1 | Road: 3 lanes default (biomes 2–4), 3.6 m lanes, 3.0 m shoulders, median barrier | `unit/test_tuning.gd::test_ref_lane_width_and_shoulder`, `::test_ref_lanes_per_direction`, `unit/test_road_chunk_mesher.gd::test_barrier_and_rails_in_place`, `unit/test_road_biomes.gd::test_biome_lane_count_changes_after_the_checkpoint_with_a_taper` | fast ✓ | ✅ | |
| SP-W2 | Geometry: radius ≥ 1,200 m, grade ≤ 5 %, C1 continuity; 200 m pooled chunks | `unit/test_road_path.gd::test_bounds_and_continuity_200km`; soak `::soak_10000km_with_forgetting`; `unit/test_road_builder.gd::test_pool_stable_while_driving_20km` | fast ✓, soak ✓ | ✅ | |
| SP-W3 | Floating origin every 2 km in one frame, no hitch or seam | `unit/test_floating_origin.gd` (4), `unit/test_road_builder.gd::test_origin_shifts_over_long_drive_keep_seams`, `unit/test_road_drive.gd::test_drive_through_origin_shift`, `unit/test_player_car.gd::test_origin_shift_keeps_the_car_continuous` | fast ✓ | ✅ | |
| SP-W4 | Roadside rhythm as MultiMesh: poles every 50 m, reflector posts every 25 m, etc. | `unit/test_roadside.gd::test_rhythm_exact_multiples_across_slides_and_origin_shift`, `::test_budget_share_at_medium` | fast ✓ | ✅ | |
| SP-W5 | Color script: 7 keyframes, every channel, interpolated, pushed as globals once per frame; biome tint offsets; live `sky_t` slider | `unit/test_color_script.gd` (12), `unit/test_sky.gd::test_pushes_every_declared_global`, `::test_skips_unchanged_values`, `::test_sky_t_slider_scrubs_and_plays`, `unit/test_biome_look.gd` | fast ✓ | ✅ | |
| SP-W6 | Six biomes with their data (props, tints, lanes, set-piece mix, horizon set, landmark style) | `unit/test_biome.gd`, `unit/test_biome_coast_city_valley.gd`, `unit/test_biome_wiring.gd` | fast ✓ | ✅ | "Looks good across the whole color script": snaps (BIOMES.md), owner web review |
| SP-W7 | Night lighting without lights: headlight cones, glow sprites, lamp pools, player fake light, retro-reflectors | `night/test_headlight_cones.gd`, `night/test_street_lamp_pools.gd`, `night/test_player_headlights.gd`, `world/test_set_piece_view.gd::test_road_works_props_are_drawn_retro_reflective_in_three_draw_calls` | fast ✓ | ⚠️ | D8: manual high beams added (`night/test_high_beam.gd`) |
| SP-W8 | Checkpoint landmarks (toll gantry, suspension bridge, sign gantry, tunnel portal) announced at 1 km and 500 m | `world/test_landmarks.gd` (17), `world/test_landmark_styles.gd` | fast ✓ | ✅ | |

### Audio, haptics and feel

| ID | Item (spec § Audio, haptics and game feel) | Verified by | Latest result | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| SP-F1 | **Every scoring event gets sound, haptics and a visual response within one frame** (M7 done) | `feel/test_one_frame.gd` (21), `audio/test_audio.gd::test_every_scoring_event_sounds_in_the_same_frame`, `platform/test_haptics.gd::test_every_pattern_fires_for_its_event` | fast ✓ | ⚠️ | D19 (a cut uses the pass tick). Slipstream has no sound or discrete visual (FEEL.md → Open; the spec gives it no feedback line) |
| SP-F2 | Pass whoosh louder and shorter with smaller clearance; close zip, thread thump | `audio/test_audio.gd::test_whoosh_scales_with_clearance`, `::test_close_pass_zip_and_thread_thump`, `::test_whoosh_sits_on_the_passed_cars_side_with_doppler` | fast ✓ | ✅ | Placeholder CC0 audio (D2) |
| SP-F3 | Engine, wind, horns, air brakes, tire hum, tunnel reverb, stingers pitched by multiplier, night low-pass, buses Master / Music / SFX / Engine / UI | `audio/test_audio.gd` (20), `audio/test_audio_settings.gd` | fast ✓ | ✅ | Feel on device: DEV-4 |
| SP-F4 | Haptics table (light / medium / heavy / double / 150 ms / 400 ms), toggle | `platform/test_haptics.gd::test_spec_durations`, `::test_banking_is_a_double_light_tick`, `::test_setting_disables_every_pattern` | fast ✓ | 📱 | Real haptics only on a phone (DEV-4) |
| SP-F5 | Slow motion: thread 0.6× 0.25 s, first hit 0.5× 0.3 s, crash 0.25× 2.5 s | `fx/test_slowmo_table.gd::test_the_spec_table`, `::test_thread_slows_to_0_6_for_0_25_s`, `run/test_run.gd::test_slow_motion_does_not_change_the_run` | fast ✓ | ✅ | |
| SP-F6 | Speed lines above 180 km/h; tire smoke on hard braking; sparks on scrapes; FOV punch on boost | `fx/test_juice_fx.gd::test_speed_line_threshold`, `::test_tire_smoke_at_the_rear_wheels_while_braking_hard`, `::test_sparks_at_the_scrape_position` | fast ✓ | ✅ | |

### UI, HUD, accessibility

| ID | Item (spec § UI, Accessibility) | Verified by | Latest result | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| SP-U1 | Design system: colours table, chamfered panels (13 / 7 px), 1.5 px neon edge, speed tilt, Chakra Petch (OFL, logged) | `ui/test_ui_theme.gd` (9) | fast ✓ | ✅ | |
| SP-U2 | HUD layout on the screen edges, middle third clear; safe areas; mirrored for left-handed play | `ui/test_hud_layout.gd` (7), `ui/test_hud_leg.gd::test_toast_and_chip_stay_out_of_the_middle_third`, `unit/test_player_controller.gd::test_layout_rects_right_and_left_handed` | fast ✓ | ⚠️ | D14 (speed and boost cluster bottom-centre) |
| SP-U3 | Screens: title (attract drive), garage, settings (all spec settings), countdown, pause, results, leaderboards | `ui/test_title_screen.gd`, `ui/test_garage.gd`, `ui/test_settings_panel.gd`, `ui/test_run_screens.gd`, `ui/test_leaderboards_screen.gd` | fast ✓ | ⚠️ | D25 (settings on 3 pages) |
| SP-U4 | Reduced motion: shake, roll, FOV punch, slow motion off | `a11y/test_reduced_motion.gd`, `fx/test_slowmo_table.gd::test_reduced_motion_*` | fast ✓ | ⚠️ 👤 | D32; O3 speed lines **deferred to owner playtest** (stay on) |
| SP-U5 | Colour independence: every event has its own word and sound | `a11y/test_color_independence.gd` (8), `ui/test_hud.gd::test_every_event_has_its_own_word` | fast ✓ | ✅ | |
| SP-U6 | Text size 100 % / 125 % for HUD and menus | `ui/test_text_fit.gd`, `a11y/test_text_size_sweep.gd` (14), `ui/test_hud.gd::test_text_scale_setting_scales_the_layout` | fast ✓ | ✅ | |
| SP-U7 | Warning cues (TOO SLOW, set-piece warning, shoulder penalty, HESITATED) beyond colour | `a11y/test_alert_redundancy.gd::test_critical_warnings_have_a_sound_and_a_pulse` | fast ✓ | 👤 | Words and pulses exist. O4 a warning tone / haptic per cue: **deferred to owner playtest** (none for now), not blocking |

### Cars, garage, progression, meta

| ID | Item (spec § Cars, Save, Leaderboards) | Verified by | Latest result | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| SP-A1 | **Validation test** `check_car_assets`: fails on missing nodes, over-budget meshes, wrong orientation or scale | `unit/test_check_car_assets.gd` (4) | fast ✓ | ✅ | Path `tests/unit/`, not `tests/check_car_assets.gd` |
| SP-A2 | Modular convention; placeholder cars stubbed; triangle budgets | `unit/test_check_car_assets.gd::test_bare_mesh_is_stubbed_to_the_convention`, `unit/test_car_visual.gd::test_every_car_draws_within_the_merged_target` | fast ✓ | ⚠️ | D2 (CC0 / cool_drive placeholders) |
| SP-A3 | 8 cars at launch, 1 unlocked; driver level from lifetime banked score; milestone unlocks (leg 4, coast, 7-day streak, 100 threads) | `meta/test_progression.gd::test_roster_has_the_spec_slots_and_rules`, `meta/test_meta_profile.gd::test_leg_and_coast_milestones`, `::test_daily_streak_milestone`, `::test_lifetime_threads_milestone` | fast ✓ | ⚠️ | D26 (3 drivable, 5 "coming soon"), D27, D28 |
| SP-A4 | ~25 achievements mirrored to Game Center / Play Games | `meta/test_achievement_catalog.gd::test_about_twenty_five`, `::test_the_spec_examples_are_there`, `meta/test_achievement_platform.gd` | fast ✓ | ⚠️ 📱 | D29; platform calls only against doubles here (DEV-6) |
| SP-A5 | Local versioned save (settings, unlocks, stats, bests, ghosts) | `core/test_save.gd` (12), `core/test_save_migrations.gd` (9), `core/test_save_store.gd` (10) | fast ✓ | ✅ | |
| SP-A6 | Leaderboards: Journey (all-time, weekly), Daily, distance | MP N7 (below); `ui/test_leaderboards_screen.gd` | fast ✓ | ⚠️ | D29: our server's boards replace the platform boards (MP spec) |
| SP-A7 | Future-mode hooks: vehicles are data, controller swap at runtime, SpawnSource, swappable scoring rule set, mode state machine, music clock | `unit/test_contracts.gd::test_controller_swap_keeps_state`, `::test_music_clock_stub`, `unit/test_player_car.gd::test_controller_swap_between_ticks_leaves_state_untouched`, `run/test_game_flow.gd::test_hud_sections_per_mode` | fast ✓ | ✅ | |

### Plan-level soak gates (soak tier)

The soak tier holds a few gates of the plan's own (deviation targets and tuning surveys), beyond the spec's lists. Four fail. Each is deterministic (a fixed seed), so each was also run on `b76c162` (the tree just before the N8.2 merge, which changed every traffic trace: DetMath in place of libm, the 800 m tier-independent horizon).

| ID | Gate | Test | Latest result | On `b76c162` | Status | Cause / notes |
| --- | --- | --- | --- | --- | --- | --- |
| PL-1 | The passability bot drives every lane count (3, 3, 2, 4 lanes; legs 1–8 of 2.5 km) with no contact, **never below the minimum speed**, always with a path, the oracle agreeing (WP6.1) | `unit/test_passability_bot.gd::soak_bot_drives_every_lane_count` | **WP9.6: ✓** runs 0–3: no path 0, contacts 0, windows 0, never below the minimum (135 / 148 / 125 / 138 km/h average). WP9.5: ✗ run 3, 36.5 s below 100 km/h behind a 90 km/h motorbike, 1 check without a path | ✓ | ✅ | Fixed in the soak bot, not the assertion: a vehicle ahead in its own lane within 120 m and 3 m/s slower than its target speed makes it prefer the faster neighbouring lane (`PassabilityBot._overtake_lane`). The greedy path extraction held it at the minimum speed behind the bike (its headway pins the slowest allowed speed) until a car beside closed the way out |
| PL-2 | Effective density tracks the target: within 10 % at each leg, leg 8 ≥ 78 % of target, the cap binds < 5 % of the time (D11 / D17) | `soak/test_density.gd::soak_effective_density_tracks_target` | **WP9.6: ✓** 3 lanes 100 / 93 / 83 %, 4 lanes 99 / 91 / 85 % (legs 1 / 4 / 8), the cap binding **0 %** in every cell (4 lanes leg 8: peak 111). WP9.5: ✗ 4 lanes leg 8, cap binds 5.72 % | ✗ (3 lanes leg 4 −12.0 %; leg 8 at 77.8 %) | ⚠️ | **Proposed D33.** The binding was not benign: with the cap at 120 the 4-lane leg-8 survey met 87 % of the target instead of 81 % (15.2 vs 13.1 per km at the player in the peaks). So the cap is 120 on roads of 4+ lanes and stays 90 elsewhere (`max_active_vehicles` / `max_active_vehicles_narrow`); draw calls unchanged (per model: 41 3D calls with 91 cars in the city); phone tick about 0.26 ms at 111 cars by D11's extrapolation (📱 to confirm). Leg 4 on 4 lanes sits 1 point inside its band. SOAK.md / SPAWNING.md, *WP9.6* |
| PL-3 | Weaving racers do not cost leg-8 density: at least −3 % (and at most +8 %, sanity) against the same survey with weaving off (D17 / WP6.9) | `unit/test_racer_weave.gd::soak_density_with_weaving_racers` | **WP9.6: ✓** 3 lanes **+1.29 %**, 4 lanes **−2.53 %** (both surveys without set pieces) | ✗ (3 lanes −5.97 %) | ✅ | Orchestrator: the guard's intent is "weaving must not cost density", so the bound is one-sided (≥ −3 %) with a +8 % sanity bound (was ±3 %; WP9.5 read +3.63 % on 4 lanes, +2.4 % on 3). With WP9.6's more frequent set pieces the pair swung by several percent (3 lanes −3.68 % with pieces, +1.29 % without, same seeds), so both surveys now run without them: the guard measures the weaving. 4 lanes sits 0.5 point inside the bound (the chaos is about ±1.5 %). SOAK.md, *WP9.6* |
| PL-4 | A fresh install reaches its first unlock within 4 beginner runs (proposed D27 text: "after 1–4 runs") | `meta/test_first_unlock.gd::soak_fresh_install_reaches_its_first_unlock` | **WP9.6: ✓** installs 0 and 2 on run 1, install 1 on run 4 (runs 1–3 bank 24, 143, 76 XP) | ✓ (runs 1, 2, 3) | ⚠️ | Orchestrator: XP unchanged; the gate is 4 runs and D27's text becomes "1–4 runs" (GARAGE.md). The spec's M8 bar (it reaches the unlock) holds |

### Milestones (spec § Implementation milestones, *done when*)

| ID | Done when | Verified by | Latest result | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| M0 | An empty scene runs on an iPhone, an Android phone and a desktop browser; `run_all.gd` green from the command line | fast tier; web smoke (Chromium); owner iPhone | fast ALL PASSED (1,969); web smoke PASS | ⚠️ 📱 | D5: Android pending a device (DEV-7) |
| M1 | Empty-road 20-min drive holds 60 fps with no throttling on an iPhone 13-class device at Medium; looks right across the color script on both renderers | SP-P1; `tools/parity.sh` look sweep; owner web look review (passed) | parity 7 of 7 keyframes ok (p99.9 ≤ 7, mean ≤ 1.32 of 255) | 📱 | D4: the native soak is still open (DEV-1) |
| M2 | Lane-change, settling and stability tests pass; drag and gyro feel precise on device | SP-V1..V3 fast ✓; owner playtest | fast ✓; owner M2 passed (web) | ✅ | Gyro on native pending (DEV-2) |
| M3 | 10,000 km soak, determinism and fairness tests pass; 10-min sandbox review shows readable, lively traffic | SP-T1..T3, SP-T5..T11; owner review ("traffic really good") | WP9.6 spot checks (all-pieces and canyon, 504 km each): every gate 0, impossible windows 0 | ⚠️ | SP-T1 (proposed D34). D12. Owner's M3 review passed |
| M4 | Scoring unit tests (every event, anti-exploit, banking, loss cases) pass; a first full playable loop works | SP-S1..S15; `integration/test_scoring_loop.gd`, `integration/test_hits_loop.gd` | fast ✓ | ✅ | |
| M5 | A run cycles day → night → dawn across legs; sun bar and leg toasts read clearly | `run/test_run_legs.gd::test_m5_day_night_dawn_across_legs`, `ui/test_hud_leg.gd`, `ui/test_text_fit.gd::test_leg_toast_fits_every_setting` | fast ✓ | ✅ | |
| M6 | Passability tests pass (zero impossible windows) and **all biomes and set pieces appear in a full journey** | SP-T18; `acceptance/test_acceptance_journey.gd::soak_full_journey_shows_every_biome_and_the_set_pieces_it_meets` (WP9.6: 5 journeys, asserts ≥ 6 pieces and ≥ 3 kinds) | **WP9.6:** 5 whole journeys, no teleports: every biome of the route appears ✓; set pieces met **1, 1, 1, 4, 3** = **2.0 per journey, 4 of 8 kinds** (toll gantry 5, truck wall 2, tunnel squeeze 2, slalom 1); `--all-pieces` soak 0.78 per leg, 7 kinds. WP9.5: 1, 1, 0 (2 kinds), 0.63 per leg | ❌ 👤 | Improved but short of the orchestrator's 4–8 ([F2](#f2-set-pieces-rarely-appear-in-a-real-journey), SPAWNING.md *Set pieces in a real journey*): at the bot's ~150 km/h a rolling piece (105–125 km/h) is met 60–150 s after it appears beyond the fog and needs 2–4 km of road with no lane drop, tunnel, fork, checkpoint range or blind crest; the journey road rarely has that. **O9 stays open** with options (accept ~2 for a 150 km/h driver, rolling pieces slower while hidden, more feature-tied pieces, or restate the bar). Passability part: 0 impossible windows (SP-T1) |
| M7 | Every scoring event has sound, haptics and a visual response within one frame | SP-F1 | fast ✓ | ⚠️ | D19; owner native feel check (DEV-4) |
| M8 | A fresh install progresses to its first unlock; Daily Drive gives identical runs on two devices for the same date | soak `meta/test_first_unlock.gd::soak_fresh_install_reaches_its_first_unlock`; `tools/determinism/compare.sh --seconds=300 --driver=bot --replay` (Linux native vs wasm in Chromium) | soak **✗** (install 1 took 4 runs; PL-4); determinism **IDENTICAL 300 / 300 s**, both replays accepted | ⚠️ 📱 | The spec's bar holds (all 3 installs reach the first unlock: runs 1, 4, 1); the plan's D27 "1–3 runs" fails for install 1 (PL-4). Native vs wasm is the stand-in for two devices; two real phones: DEV-5 |
| M9 | The governor steps down and up correctly under a forced thermal state; every acceptance test in this document passes | `platform/test_quality_governor.gd::test_forced_thermal_steps_down_and_back_up`, `platform/test_governor_run.gd`; this document | fast ✓ | ❌ 📱 | Headless ✓; native plugins untested on device (DEV-1); "every acceptance test passes": M6 (see the ❌ list) and the 📱 items |

## Multiplayer spec

### Resource budget and load test

| ID | Item (MP § Resource budget, Testing → Load test) | Verified by | Latest result | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| MP-R1 | 20 full rooms (160 players) at ≤ 50 % of one core | `bots` `loadtest` (LOADTEST.md). This sweep: the release `westbound-server` pinned with `taskset -c 0` (the spec's "taskset or a cgroup"), `loadtest` on cores 1–3, 20 rooms × 8 bots, normal density, 150 ms ± 30 ms / 2 % loss, 15 s warm-up + 300 s. `dockerd` was no longer running in the container, so not the Docker image | **36.2 %** (300 s window, 160 bots, host `taskset -c 0`) | ✅ | N10.1 on record: 38.1 % normal, 42.8 % rush (LOADTEST.md) |
| MP-R2 | Room tick p99 < 5 ms per 20 Hz tick | same | **≤ 3.0 ms** (mean 0.62 ms, max 195 ms) | ✅ | N10.1: ≤ 3 ms / ≤ 2 ms |
| MP-R3 | Server memory < 300 MB (excluding the verifier) | same | **107.9 MB** peak | ✅ | N10.1: 99.6 MB |
| MP-R4 | Downstream ≤ 10 KB/s per player incl. framing; upstream ~1 KB/s | same; `server/tests/rooms.rs::rush_hour_downstream_stays_in_budget_with_8_bots`; `net/test_codec_perf.gd::test_frames_are_what_the_budget_assumes` | **4.92 KB/s** worst bot on the wire (mean 4.64); up 0.50 KB/s | ✅ | N10.1: worst 5.09 KB/s |
| MP-R5 | Verifier one job at a time, `nice 10`, 1 GB cap | `server/tests/replays.rs::the_server_runs_one_job_at_a_time_in_order`; sidecar compose `mem_limit: 1g` | Rust gate ✓ | ⚠️ 📱 | Sidecar built, **not deployed** (DETERMINISM.md → enabling); peak ~225 MB measured (SERVER.md) |
| MP-R6 | Hard caps 40 rooms / 400 connections | `server/tests/ws.rs::connection_cap_refuses_extra_clients`, `server/tests/rooms.rs::quick_join_browse_leave_and_the_room_cap`, `server/tests/config.rs::defaults_are_valid_and_match_the_spec` | Rust gate ✓ | ✅ | |
| MP-R7 | Bounded everything: 64-frame outbound queue (slow client disconnected), 16 KB inbound max, per-connection rate limits; one frame per tick per client | `server/tests/ws.rs::slow_client_is_disconnected_when_queue_fills`, `::max_size_message_passes_oversize_is_closed_1009`, `server/tests/gateway.rs::rate_limits_drop_then_disconnect`, `server/src/rooms/tests.rs::relay_one_frame_per_tick_and_placement_ack` | Rust gate ✓ | ✅ | |
| MP-R8 | Data shared with the client comes from the client (map, profiles exported from Godot) | `road/test_loop_export.gd::test_committed_files_are_current`, `::test_client_and_server_copies_and_sidecars`, `sim/tests/parity.rs` | fast ✓, Rust ✓ | ✅ | |

### Server testing (MP § Testing → Server)

| ID | Item | Verified by | Latest result | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| MP-S1 | **Traffic parity:** Rust IDM and MOBIL match GDScript on shared vectors within 1e-9 | `sim/tests/parity.rs` (10: IDM, MOBIL, no-ambush, RNG, closures, 4 tick-identical traces) | Rust gate ✓ | ⚠️ | MP-D5 (three safety extensions, ported to GDScript in WP6.11) |
| MP-S2 | **Scoring:** every event, anti-exploit rule, banking and loss case, plus crew proximity and trains | `sim/tests/scoring_parity.rs` (5: bit-exact with `src/scoring/`), `server/tests/scoring.rs`, `server/src/rooms/tests.rs::claims_score_sync_and_verified_runs_reach_the_sink`, `sim` unit tests | Rust gate ✓ | ✅ | |
| MP-S3 | **Codec and map:** every golden vector round-trips; wrap-around distance math | `protocol/tests/golden_vectors.rs` (6), `road/test_loop_road_path.gd::test_wrap_math`, `sim/tests/mp_rules.rs::leaders_are_found_across_the_loop_seam` | Rust ✓, fast ✓ | ✅ | |
| MP-S4 | **Traffic soak:** one simulated hour of the full loop at each density: 0 collisions, stable density, every lane change signalled ≥ 1.0 s | `sim/tests/soak.rs::soak_hour_light`, `::soak_hour_normal`, `::soak_hour_rush` (ignored, `--release`); normal suite `::soak_short_normal`, `::soak_short_rush` | `soak_hour_rush` ✓: 3,600 s in 44 s, 1,200 cars stable, 0 collisions, 0 violations, min blinker-to-motion 1.050 s, 0 body overlaps. Light / normal hours not rerun | ✅ | N4.1 on record: 0 collisions at every density, signals ≥ 1.05 s |
| MP-S5 | **Fuzzing:** malformed and oversized inbound messages never crash a room | `protocol/src/proptests.rs` (`random_bytes_never_panic`, `mutated_client_frames_never_panic`, …), `server/tests/gateway.rs::undecodable_first_frames_are_malformed`, `::oversize_frame_closes_1009` | Rust gate ✓ | ✅ | Rooms only receive decoded, validated messages; the fuzzing sits at the codec / gateway |

### Netcode harness (MP § Testing → Netcode harness)

| ID | Item: at 150 ms RTT, ±30 ms jitter, 2 % loss | Verified by | Latest result | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| MP-N1 | Claim acceptance > 99 % | `server/tests/netcode.rs::acceptance_30s` (normal suite); `::acceptance_long` (ignored, `NETCODE_SECS`); the load test | `acceptance_30s` ✓; `acceptance_long` 300 s: **99.72 %** (358 / 359); load test 99.93 % (6,822 / 6,827) | ✅ | N10.1: 99.92 % of 13,171 |
| MP-N2 | False server-detected hits < 1 per hour | same | 0 (0.00 / h) in both | ✅ | N10.1: 0 in 27.5 bot-hours |
| MP-N3 | Median traffic correction < 0.15 m, p99 < 0.6 m | same | `acceptance_long` **5 mm / 0.310 m**; load test 5 mm / 0.280 m | ✅ | N10.1: 5 mm / 0.285 m |
| MP-N4 | Late intents < 1 per 10 minutes | same | `acceptance_long` **0.50** per 10 bot-min (2 of 3,547); load test 0.11 | ✅ | N10.1: 0.06 per 10 bot-minutes |

### Client and verifier testing (MP § Testing)

| ID | Item | Verified by | Latest result | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| MP-C1 | **Codec:** encodes and decodes every golden vector | `net/test_codec_vectors.gd` (13) | fast ✓ | ✅ | |
| MP-C2 | **Clock sync** converges within ±5 ms on a simulated link | `net/test_clock.gd::test_converges_within_5ms_on_the_acceptance_link` | fast ✓ | ⚠️ | MP-D4 (smoothing on top of lowest-RTT-of-8) |
| MP-C3 | **Traffic corrector:** a recorded server stream replayed through it keeps error within the thresholds | `net/test_network_traffic.gd::test_small_and_medium_errors_blend_out_over_their_times`, `::test_prediction_error_without_loss_stays_under_the_bounds`, `::test_loss_on_the_stream`; soak `::soak_network_traffic_ten_minutes` | fast ✓, soak ✓ | ⚠️ | MP-D8 (late-intent blinker minimum, in-view slides) |
| MP-C4 | **Replay recorder:** output matches the verifier's expected format | `net/test_replay_recorder.gd::test_header_layout_is_the_documented_one`, `::test_round_trip_keeps_every_field`, `verifier/test_verifier.gd::test_honest_bot_replay_is_accepted` | fast ✓ | ⚠️ | MP-D14 (inputs in the replay) |
| MP-V1 | **Verifier:** 100 % of honest replays accepted | `verifier/test_verifier.gd::test_honest_bot_replay_is_accepted`, `::test_honest_replay_with_hits_is_accepted`, `::test_daily_replay_is_verified_on_its_date`; soaks `::soak_long_honest_runs_are_all_accepted`, `::soak_five_honest_bot_runs`, `::soak_exact_states_reproduce_long_runs`; `compare.sh --replay` (wasm replay verified natively) | fast ✓, soak ✓ (3 soaks, 1,838 s), determinism **IDENTICAL 300 / 300 s**, both replays accepted | ✅ | MP-D14 |
| MP-V2 | **Verifier:** tampered replays rejected: inflated score, edited path (teleport, impossible lateral speed), removed hit, wrong seed | `verifier/test_verifier.gd::test_inflated_score_is_rejected`, `::test_teleport_is_rejected`, `::test_impossible_lateral_speed_is_rejected`, `::test_removed_hit_is_rejected`, `::test_wrong_seed_is_rejected`, `::test_edited_inputs_are_rejected` (+ kinematic variants) | fast ✓ | ✅ | |
| MP-V3 | Accept if the recomputed score is within 3 % and no unreported hits | `verifier/test_verifier.gd` (above); `server/tests/replays.rs::accepted_verdict_verifies_the_run_and_keeps_a_top_replay`, `::rejected_verdict_rejects_the_run_and_deletes_the_replay` | fast ✓, Rust ✓ | ⚠️ | MP-D14: every 30 Hz sample must equal the re-simulation (stricter) |
| MP-V4 | Determinism rules: seeded RNG only; no `pow` / `sin` / `cos` / `exp` in sim paths; fixed tick; no iteration-order dependence | `tools/lint` WB105 (DetMath), `unit/test_det_math.gd`, `sim/tests/detmath.rs`, `integration/test_determinism.gd`, `compare.sh` | lint clean, fast ✓ | ✅ | `LoopGen` closure solve keeps `allow-libm` (not a run path; DETERMINISM.md) |
| MP-DEV1 | **On device before every release:** a 30-minute crew session of ≥ 4 real phones over cellular | Owner | Not run | 📱 | DEV-8 |
| MP-DEV2 | **On device before every release:** one phone through Network Link Conditioner at 150 ms / 2 % loss | Owner | Not run | 📱 | DEV-9 |

### Multiplayer rules with tests

| ID | Item (MP §) | Verified by | Latest result | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| MP-X1 | Map hash check on join: a mismatch is refused with "please update" | `server/tests/gateway.rs::map_mismatch_before_auth`, `net/test_net_client.gd::test_map_mismatch`, `net/test_map_info.gd` | Rust ✓, fast ✓ | ✅ | |
| MP-X2 | Room clock: 32 min cycle (22 day, 10 night), UTC-derived for public rooms; host options for private | `run/test_room_clock.gd` (5), `server/tests/rooms_data.rs::the_room_clock_is_the_games`, `server/src/rooms/tests.rs::night_follows_the_room_clock` | fast ✓, Rust ✓ | ⚠️ | MP-D7 |
| MP-X3 | Server traffic: 20 Hz, players in the sim, no-ambush on predicted players, MP signal ≥ 1.0 s for every profile, hit reaction broadcast | `sim/tests/mp_rules.rs` (10) | Rust ✓ | ✅ | |
| MP-X4 | Area of interest −300 / +900 m; corrections 5 Hz within 100 m, ≥ 1 Hz otherwise; intents at decision time | `server/tests/traffic_stream.rs::rush_hour_mirrors_match_the_area_of_interest_every_tick`, `::intents_reach_every_client_that_has_the_car` | Rust ✓ | ✅ | |
| MP-X5 | Client corrections: < 0.5 m over 0.3 s, 0.5–5 m over 0.15 s, larger snaps; late intents | `net/test_network_traffic.gd::test_small_and_medium_errors_blend_out_over_their_times`, `::test_large_errors_snap_out_of_view_and_slide_in_view`, `::test_late_intents_show_the_blinker_then_catch_up` | fast ✓ | ⚠️ | MP-D8 |
| MP-X6 | Players: 20 Hz states; plausibility (speed ≤ top × 1.1, accel / lateral ≤ 1.2×, no teleports) marks the run unverified | `server/src/rooms/plausibility.rs` tests, `server/src/rooms/tests.rs::implausible_states_mark_the_run_unverified`, `net/test_room_session.gd::test_states_are_stamped_with_room_ticks_once_per_tick` | Rust ✓, fast ✓ | ⚠️ | MP-D7 (lateral cap 12 m/s), MP-D11 (stamps) |
| MP-X7 | Remote players 100 ms behind, extrapolate ≤ 250 ms then fade; ghosted, translucent within 15 m; nametags; loop strip | `net/test_room_track.gd` (12), `net/test_room_run.gd::test_remote_players_are_drawn_ghosted_with_nametags`, `ui/test_room_hud.gd::test_loop_strip_dots_and_idle` | fast ✓ | ✅ | |
| MP-X8 | Spawning behind the crew leader in a gap at flow speed with 3 s protection; crash-out respawn; rejoin crew; 15 s seat hold | `server/src/rooms/tests.rs::crash_out_respawns_behind_the_crew_leader_after_3_s`, `::rejoin_crew_across_the_seam`, `::seat_hold_reconnect_keeps_the_run`, `::seat_hold_expires_after_15_s`, `net/test_room_run.gd` | Rust ✓, fast ✓ | ⚠️ | MP-D7, MP-D9 |
| MP-X9 | Shadow collision logging and admin stats | `server/tests/admin_stats.rs::shadow_contacts_are_written_and_summarised` | Rust ✓ | ✅ | Retention open (SERVER.md) |
| MP-X10 | Scoring in MP: sectors bank and pay, clean sector restores a life; crew proximity +0.25× per crewmate within 30 m (cap ×2); trains (25, +2, within 1.0 s); claims ±300 ms / +0.35 m; ScoreSync ≥ 1 Hz and at banks; hit cross-check (> 0.3 m for 2+ ticks) | `server/src/rooms/tests.rs::claims_score_sync_and_verified_runs_reach_the_sink`, `server/tests/scoring.rs`, `net/test_score_client.gd` (15), `net/test_score_client_run.gd` (8), `run/test_run_loop.gd::test_sector_gantry_banks_and_pays` | Rust ✓, fast ✓ | ⚠️ | MP-D10, MP-D11 |
| MP-X11 | Rooms: 6-char codes without confusable characters; host kicks and settings; host passes to the longest present; closes 60 s after empty; Quick Join fills the fullest room that fits the party; browser | `server/src/rooms/tests.rs::private_room_snapshot_join_leave_and_host_passing`, `::host_rules_kick_density_and_time_mode`, `::an_empty_room_closes_after_60_s`, `server/tests/parties.rs::quick_join_fits_the_whole_party_as_one_crew`, `ui/test_room_hub.gd` | Rust ✓, fast ✓ | ⚠️ | MP-D12 |
| MP-X12 | Protocol: handshake with version / build / map hash; ping every 2 s, dead after 8 s | `server/tests/gateway.rs` (21), `net/test_net_client.gd::test_keepalive_pings_every_2s_and_stays_alive`, `::test_dead_after_8s_of_silence` | Rust ✓, fast ✓ | ✅ | |
| MP-X13 | Accounts: device account, 1 h JWT, rotating 30-day refresh, secret hash only, deletion; names name#1234 3–16 chars, profanity filter, rename every 30 days | `server/tests/auth.rs` (11), `server/tests/profile.rs` (4), `server/tests/names.rs` (6), `net/test_session.gd` (23) | Rust ✓, fast ✓ | ⚠️ 📱 | MP-D2: Apple / Google linking and Keychain plugin deferred (DEV-10) |
| MP-X14 | Rate limits per IP and per account on every HTTP route, per connection on every WS message type | `server/tests/ratelimit.rs` (5), `server/tests/ops.rs::every_route_is_limited_per_ip_and_upgrades_too` | Rust ✓ | ✅ | |
| MP-X15 | Leaderboards: 5 boards, global / around me / friends, seasons; single-player plausibility checks; replay when top 100 or PB; legacy PB upload | `server/tests/leaderboards.rs` (8), `server/tests/runs.rs` (14), `net/test_boards_client.gd`, `net/test_runs_client.gd` (18) | Rust ✓, fast ✓ | ✅ | |
| MP-X16 | Social: friends, presence, blocks, parties, crews (tag, roles, 16 members), reports, quick chat, moderation CLI | `server/tests/social.rs` (14), `server/tests/presence.rs`, `server/tests/parties.rs`, `server/tests/cli.rs`, `net/test_social_client.gd` (22) | Rust ✓, fast ✓ | ⚠️ | MP-D12 |
| MP-X17 | Graceful restart: 60 s notice, clients reconnect and rejoin by code | `server/tests/ops.rs::planned_restart_notice_handover_and_rejoin_by_code`, `server/tests/cli.rs::serve_sigterm_sends_the_restart_notice_then_closes_1012`, `net/test_room_run.gd::test_a_server_restart_rejoins_by_code_into_a_fresh_run` | Rust ✓, fast ✓ | ⚠️ | MP-D13 |
| MP-X18 | Backups nightly with 7-day retention | `server/tests/db.rs::nightly_run_writes_dated_file_and_prunes`, `server/tests/ops.rs::a_backup_restores_into_a_fresh_server` | Rust ✓ | ⚠️ | MP-D1 (in-container task + Coolify volumes) |

### Production (live, read-only probes)

Owner / coordinator, 2026-09-30: production is live on Coolify. Probed from this container with read-only requests only (no accounts, rooms or runs created).

| ID | Check | Probe | Result | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| PR-1 | Health | `GET https://westbound.sipsakrandevu.com/api/v1/health` | 200 `{"status":"ok","version":"0.1.0","build":"0793a8a","db":"ok"}` (0.7 s) | ✅ | Reports build `0793a8a` (the N8.2 shared-files commit, 2 commits after `b76c162`); this branch is at `5949a38` (+ N4.4 / N10.1), so production does not have the N10.1 load-test and admin-stats work yet |
| PR-2 | Invite page `/r/<code>` | `GET /r/K7QX2M` | 200 `text/html`, "Westbound invite" page | ✅ | |
| PR-3 | Deep-link files | `GET /.well-known/apple-app-site-association`, `/.well-known/assetlinks.json` | 200 `application/json`: `{"applinks":{"details":[]}}` and `[]` | ⚠️ 📱 | Served, but empty until the app ids are set at store setup (DEV-12) |

### MP milestones (*done when*)

| ID | Done when | Verified by | Latest result | Status | Notes |
| --- | --- | --- | --- | --- | --- |
| N0 | A phone connects over `wss://` through the proxy on the real VPS | Owner (2026-09-29, Coolify, `westbound.sipsakrandevu.com`); PR-1 | Met (plan); health answers `ok` today (PR-1) | ⚠️ | MP-D1 (Coolify proxy, not Caddy) |
| N1 | An account survives an iOS reinstall; a linked account signs in on a second device | Needs the Keychain plugin and Apple / Google (MP-D2) | Not testable yet | 📱 | DEV-10 |
| N2 | Golden vectors pass on both sides; clock sync meets its test | MP-S3, MP-C1, MP-C2 | Rust ✓, fast ✓ | ✅ | |
| N3 | The loop drives cleanly end-to-end in single-player test mode within the performance budget | `run/test_run_loop.gd::test_lap_after_lap`, `::test_crossing_the_seam_is_clean`, `::test_city_frame_cost`; soak `::soak_three_laps_with_traffic`; loop draw calls (LOOP_MAP.md) | fast ✓, soak ✓ (3 laps × 2) | ✅ | 👤 O7 props per lap |
| N4 | Two phones see the same traffic; the bot harness meets its correction targets | MP-N3; two phones: owner | `acceptance_long` **5 mm / 0.310 m**; load test 5 mm / 0.280 m | ⚠️ 📱 | DEV-8 |
| N5 | 4 friends can drive a full lap together | Owner | Not run | 📱 | DEV-8 |
| N6 | Scoring tests pass; bots' claim acceptance > 99 % | MP-S2, MP-N1 | `acceptance_30s` ✓; `acceptance_long` 300 s: **99.72 %** (358 / 359); load test 99.93 % (6,822 / 6,827) | ✅ | |
| N7 | Every board shows correct global, around-me and friends views on iOS, Android and web | `server/tests/leaderboards.rs::every_board_period_and_view`, `ui/test_leaderboards_screen.gd`; devices: owner | Rust ✓, fast ✓ | ⚠️ 📱 | Native builds not exported yet (DEV-11) |
| N8 | Verifier tests pass; a verification job stays within its memory cap | MP-V1..V3; `server/tests/replays.rs::end_to_end_with_the_godot_verifier` (ignored) | fast ✓, soak ✓ (3 soaks, 1,838 s) | ⚠️ | ~225 MB peak measured; sidecar not deployed |
| N9 | A party of 3 can Quick Join a public room together from an invite link | `server/tests/parties.rs::quick_join_fits_the_whole_party_as_one_crew`, `ui/test_party_ui.gd::test_an_invite_link_joins_the_room_or_else_the_party`; live local check (plan) | Rust ✓, fast ✓; production `/r/` and `/.well-known/*` answer (PR-2, PR-3) | ⚠️ 📱 | MP-D12. The routes are live (coordinator, 2026-09-30); the deep-link files are empty until the app ids exist, so the link opens the web build only (DEV-12). A party of 3 on real devices: DEV-8 |
| N10 | Load-test targets met on a 1-vCPU limit; a planned restart reconnects everyone automatically | MP-R1..R4; MP-X17 | load test PASS (every target `ok`); restart tests ✓ | ⚠️ | MP-D13 (runs and seats do not survive; the client rejoins by code into a fresh run) |

## Gaps and notes

### F1: soak collision: slow semi merging beside a fast lane

`tools/soak.sh --km=500 --shards=4 --all-pieces`, run 1 (seed 20260928; 3 lanes, the canyon's road as every 4th all-pieces run; Falcon GT bot). Replayed with a scratch script:

- **t = 93.8 s:** semi id 37 (truck profile, 16.0 × 2.55 m) stands almost still in lane 2 (d 10.70, 6 → 3 km/h), braking.
- **t = 94.25 s:** it signals left (1.0 s), then moves over 3.0 s from 3 → 9 km/h. `v_lat` peaks at −1.8 m/s, so `atan2(v_lat, v)` is about −0.4 rad, clamped to −0.28.
- **t = 97.74–97.97 s:** a pickup (commuter) passes in lane 0 (d 3.50) at 95 km/h beside the semi's front half. The semi's box center is at d 7.30 (lane 1). The unrotated bodies are 1.5 m apart (edges 4.50 vs 6.03). The 16 m box yawed 0.28 rad reaches 8 × sin 0.28 + 1.27 × cos 0.28 ≈ 3.4 m left of its center, to d ≈ 3.96 against the pickup's inset edge at 4.42: about 0.5 m of overlap for 27 ticks (0.22 s).
- **What it is.** The sim translates boxes (no rotation), so the traffic never touched. The traffic view yaws cars by their lateral velocity (floored and clamped), though, so the semi's cab would visibly point into lane 0 as the pickup passes.
- **Where this was seen before.** WP6.8 introduced the clamp for this class; the Rust soak prints "body overlaps 0 pair-ticks; single-player checker heading adds N pair-ticks" and gates on bodies.
- **Nothing was changed here.** Changing the gate definition or the traffic is an orchestrator / owner call (O10).
- **WP9.6 (both done):** the gate counts bodies and the heading clients draw (the semi's drawn heading at 9 km/h is about 0.16 rad: no overlap), the ±0.28 rad box is reported (`yaw_only_pairs`: 27 in this run); and long vehicles (> 12 m) crawling (< 20 km/h) wait for a fast car (> 60 km/h) in the lane beyond their target (`long_merge_guard`: 174 held evaluations here, yaw-only 0, `standstill_beside_fast` unchanged). SOAK.md, *WP9.6*.

### F2: set pieces rarely appear in a real journey

`tests/acceptance/test_acceptance_journey.gd::soak_full_journey_shows_every_biome_and_the_set_pieces_it_meets` drives the real `Run` for the whole journey. It uses no teleports, a weaving `SandboxBot` and infinite lives, then prints what it met:

| Drive | Sim time | Biomes (legs 1–9) | Set pieces met | Director peaks: seen / no chance / missed / unfit / busy |
| --- | --- | --- | --- | --- |
| seed 20260929, 250 km/h | 726 s | farmland ×2, desert ×2, canyon ×2, city, valley fog, coast | tunnel squeeze 1 | 9 / 3 / 3 / 2 / 0 |
| seed 7, 250 km/h | 778 s | farmland, desert ×2, canyon, city ×2, valley fog ×2, coast | toll gantry 1 | 10 / 3 / 6 / 2 / 0 |
| seed 20260929, 170 km/h | 719 s | farmland, desert ×2, canyon ×2, city ×2, valley fog, coast | none (a truck wall warned, never met) | 10 / 3 / 4 / 2 / 0 |

- **Peaks per journey.** Only 9–10 wave peaks happen per journey (45–90 s cycles over ~12 min).
- **The chance roll.** It is 50 → 80 % by leg, and a third of the peaks fail it.
- **The meet rule.** It drops a peak when the player would not meet the piece within the peak, or not within 75 % of the piece's `approach_max_s` at the smoothed pace (SET_PIECES.md → How a piece happens). That removes most of the rest at cut-up speeds.
- **Result.** The six Flow-scheduled kinds essentially never reach the player; only the feature-anchored tunnel squeeze and toll gantry show. `soak.sh --all-pieces` (every kind unlocked from leg 1, toll gantries forced) gets 0.63 per leg, which is not what a player sees.
- **The test.** It asserts the biome half (whole journey driven, every route biome appears). It reports the set-piece half, because asserting it would only pin today's failure.
- **WP9.6:** the per-peak logs showed the road, not the rules' intent, as the limit: at the bot's pace a rolling piece is met 60–150 s after it appears, 2–4 km on, and a fork's set-piece zone covered 3.75 km. The director now judges the meet at the cruising pace, retries unfit / busy / unplaced peaks at the next batch, lets rolling pieces through widenings, ends a fork's zone 1.2 km past the split, retries busy tunnel / toll pieces, and the data raise the chance (70 → 90 %), the approach (240 s, 90 %), the tunnel squeeze (100 %) and the static kinds' weights. Result: 5 journeys (the test now drives two more: seed 11 at 250, seed 7 at 170) met 1, 1, 1, 4, 3 pieces, 4 kinds; the test asserts ≥ 6 pieces and ≥ 3 kinds. SPAWNING.md, *Set pieces in a real journey (WP9.6)*.

### Tests added

- `tests/acceptance/test_acceptance_journey.gd` (soak tier, 1 method, ~6 min): the M6 check above. There was no test for "all biomes and set pieces appear in a full journey"; `run/test_journey.gd` teleports between checkpoints and counts no set pieces.

### Coverage gaps (no automated test, by nature or by choice)

- **Device-only:**
    - SP-P1 (thermal / fps);
    - the feel of drag, gyro, haptics and audio;
    - Game Center / Play Games calls (only doubles here);
    - Android (D5);
    - every MP on-device item (MP-DEV1/2, N1, N4, N5, N7, N9 on phones).
- **Visual only:** the sun rim term in the vehicle shader (SP-K5), and "looks right across the color script" (snaps and owner review; parity is automated).
- **Spec path:** the validation test lives at `tests/unit/test_check_car_assets.gd`, not `tests/check_car_assets.gd` (SP-A1).
- **Not rerun in this sweep:**
    - the full 10,000 km soak (about an hour of four free cores; the 500 km spot check stands in, and it failed its gate);
    - the Rust ignored `soak_hour_light` / `soak_hour_normal`, `rooms.rs::bench_20_rooms_of_8_bots`, `scoring.rs::acceptance_run_long`, `traffic_stream.rs::bench_streaming_cost_per_room_tick`, `ops.rs::container_sigterm_sends_the_notice_then_closes_1012` (needs a container) and `replays.rs::end_to_end_with_the_godot_verifier`;
    - the load test in the Docker image (`dockerd` stopped; host `taskset` instead);
    - rush density in the load test (N10.1 record: 42.8 %).
- **Slipstream:** it has no sound or discrete visual (FEEL.md → Open); the spec's feedback list does not name it.

### Fixes made in this WP

- `docs/PASSABILITY.md`: two stale lines said `run.gd` does not call `director.set_player_params()`, "so the game runs without the check". `run.gd` calls it at every run start and on a dev teleport; corrected.
