# Accessibility (WP9.3)

Spec: *UI, HUD and design system → Accessibility* (reduced motion, color independence, text size), *Cameras* (reduced motion), *Audio, haptics and game feel*, *Lives* (the first hit's sting and pulse). Plan: WP9.3. Settings: `reduced_motion`, `text_scale` and `haptics` (docs/SAVE.md → Settings).

| Part | Where | Tests |
| --- | --- | --- |
| Reduced motion | camera, HUD widgets, screens, the car's damage look, the web shell | `tests/a11y/test_reduced_motion.gd` |
| Color independence | HUD words, lamps, loop-strip shapes, the drag-brake ring; the dev filter | `tests/a11y/test_color_independence.gd` |
| Text size | every screen and HUD widget at 100 % and 125 % on three canvases | `tests/a11y/test_text_size_sweep.gd` |
| Audio and haptic redundancy | the critical warnings | `tests/a11y/test_alert_redundancy.gd` |

## Reduced motion

The spec's setting turns off camera shake, camera roll, the FOV punch and slow motion. WP9.3 applies it everywhere something moves for effect: the HUD and the screens fade only, the title's camera holds still, and flickers stay under three flashes a second (WCAG 2.3.1). It applies live: the settings page's toggle takes effect in the same frame, and it settles any animation that is running.

**How.** `HudStyle.reduced_motion` (set by `Hud` from the setting) is read by every HUD widget's `animate()`, and `HudWidget.settle_motion()` puts a widget back at rest when the setting turns on. `RunScreen.motion_reduced()` is the screen's own flag *or* the setting, so every screen honours it, including the ones nobody set a flag on (title, online hub, first run). `HudWidget.motion_amount()` reports how far a widget is drawn from rest (px, radians or pulse depth), and the test uses it.

The table below is `ROWS` in `tests/a11y/test_reduced_motion.gd`. The test drives each row with the setting off, where it must move (so the driver really exercises it), and on, where it must stay within its bound. A `kept` row is the same both ways; a `still` row never moves; a `covered` row is proved by the named test.

| Row | Source | Reduced motion | Where | Kind |
| --- | --- | --- | --- | --- |
| `camera_shake` | hit and close-pass shake | off | `CameraRig.shake_amplitude()` | moves |
| `camera_roll` | roll into lateral acceleration | off | `CameraRig._update` | moves |
| `fov_punch` | boost FOV punch | off | `CameraRig.punch_deg()` | moves |
| `cockpit_head_sway` | cockpit head sway | off | `CameraRig._pose_cockpit` | moves |
| `slow_motion` | thread 0.6×, first hit 0.5×, crash 0.25× | off: requests ignored | `TimeScale.request` | moves |
| `finale_swing` | journey finale camera swing | refused; the JOURNEY COMPLETE toast still shows | `CameraRig.start_finale` | moves |
| `attract_camera` | title attract: orbit, drive-past and cuts | holds the chase follow pose behind the car (`camera.attract_reduced_motion_mode`); no shots or cuts | `CameraRig.attract_still()` | moves |
| `hud_chain_pulse` | chain scale pop on every scored event | no pop; the stack line is the response | `HudChain.animate` | moves |
| `hud_multiplier_wobble` | multiplier wobble above 20× | no wobble; the hue cycle (≤ 1.2 Hz, a color change) stays | `HudMultiplier.animate` | moves |
| `hud_event_stack` | lines pop in from the left and slide down a row | lines fade in and out where they stand | `HudEventStack` | moves |
| `hud_bank_flyer` | banked chain flies into the score | fades out where the chain was; the count-up stays | `HudFlyer._place` | moves |
| `hud_glitter` | glitter bursts | none | `HudGlitter.burst` | moves |
| `hud_life_break` | lost life gem breaks, halves fall and spin | the gem fades in place | `HudLives._draw_break` | moves |
| `hud_life_restore` | restored gem pops with an overshoot | fades in | `HudLives._paint_plate` | moves |
| `hud_ghost_blink` | lives panel blinks during the ghost | steady; GHOST is written under it | `HudLives.blink_edge` | moves |
| `hud_too_slow_pulse` | minimum-speed strip pulses | steady; TOO SLOW is written | `HudMinSpeed._pulse` | moves |
| `hud_boost_pulse` | boost segments pulse while boosting | steady; BOOSTING is written | `HudBoost._pulse` | moves |
| `hud_objective_pop` | objective chip pops in | no pop; its fade stays | `HudObjective` | moves |
| `hud_journey_grow` | JOURNEY COMPLETE grows in | no grow; its fade stays | `HudJourneyToast.animate` | moves |
| `hud_leg_toast` | leg summary toast | fades only (both ways) | `HudLegToast.animate` | still |
| `hud_achievement_toast` | achievement unlock toast | fades only (both ways) | `HudAchievementToast.animate` | still |
| `hud_cooling_icon` | cooling icon (WP9.1) | static (both ways) | `HudCooling` | still |
| `screen_title` | title menu slides in | fades only | `RunScreen.slide_in` / `motion_reduced()` | moves |
| `screen_online_hub` | online hub slides in | fades only | same | moves |
| `screen_pause` | pause menu slides in | fades only | same | moves |
| `screen_countdown` | 3-2-1-GO punch | no punch | `RunScreen.punch` | moves |
| `screen_results` | results rows slide, NEW BEST pops | fades only | `RunScreen.slide_in`, `punch` | moves |
| `screen_crash_hint` | TAP TO SKIP pulses | steady | `CrashScreen._process` | moves |
| `ghost_flicker` | player car flickers 12 Hz during the ghost | 2 Hz (`feel.ghost_flicker_reduced_motion_hz`) | `PlayerFx.ghost_hz()` | moves (bound: 3 flashes/s) |
| `damage_lamp_flicker` | dead headlight flickers 14 steps/s | 2 steps/s (`feel.lamp_flicker_reduced_motion_hz`) | `PlayerFx.advance` | moves (bound: 3 flashes/s) |
| `speed_lines` | speed lines and wind streaks above 180 km/h | kept: not camera motion (spec list; docs/FEEL.md). Open question below | `SpeedLines` | kept |
| `garage_turntable` | garage car spins | holds its idle spin (a drag still turns it) | `GarageScreen` / `GarageTurntable.still` | covered: `tests/ui/test_garage.gd` |
| `crash_orbit` | crash cinematic orbit camera | slower orbit (`crash.orbit_reduced_motion_frac`, 35 %) and no slow motion | `CrashSequence` | covered: `tests/run/test_crash_sequence.gd` |
| `loading_shell` | web loading bar sweep | follows the **system** setting (`prefers-reduced-motion`; the game's setting is not readable before the engine runs): no sweep, the bar breathes in opacity (stepped, one change per 1.2 s) | `platform/web/shell.html` | covered: `test_web_shell_follows_the_system_setting` |

**Not decorative motion (unchanged).** Nametags follow their cars; the touch overlay follows the thumb; the leaderboards list scrolls under the finger; traffic blinkers and hazards (1.5 Hz) and the road-works arrow board (1 Hz) are information, all under 3 Hz. The room HUD (loop strip, room line, feed, toast, banner) has no animation. There are no full-screen flashes anywhere (a hit is a shake, a sting and a pulse).

## Color independence

The rule: no meaning is carried by color alone. The audit below covers every place where color changes with meaning; the sandbox's racer tag colors are dev-only and skipped.

| Where | Color | Second channel | Status |
| --- | --- | --- | --- |
| Event messages (pass, close pass, cut, thread, hesitated, banked, chain lost, shoulder, night, life restored, …) | text / accent / gold / hot | one word per event, and one sound per scoring event | already (tested: one word each) |
| Traffic blinkers vs brake lights | amber vs red | a blinker flashes (1.5 Hz) on one side; brake lights are steady, on both sides and the high third brake light | already (tested) |
| Boost meter | accent READY, gold BOOSTING | READY / BOOSTING / the percentage written; lit segment count | already |
| Lives | hot gems | a lost life is an empty outline (shape); GHOST written during the ghost | already |
| Minimum speed | hot bar and edge | TOO SLOW written; the bar's length | already |
| Chain danger (shoulder, chain lost) | hot | SHOULDER / CHAIN LOST lines | already |
| Leg objective | gold done, hot failed | a tick or a cross in the icon; FAILED written | already |
| Sun bar / room clock | gold day, accent night | SUN / DAY / NIGHT / DAWN written | already |
| High-beam button | gold fill when on | a filled button with a dark glyph vs a dark one (luminance) | already |
| Settings options | accent fill | the selected option also gets the accent tab and brighter text | already |
| Garage items | dimmed when locked | the unlock rule written ("LEVEL 4") | already |
| Achievements | gold when unlocked | UNLOCKED / LOCKED / progress written | already |
| Results | gold for records | NEW BEST, "+… OVER YOUR BEST", FIRST RECORD written | already |
| Leaderboards | own row accent-filled, podium ranks gold | the rank number; the own row is a filled panel (luminance) | already |
| Friends presence | dot color | ONLINE / IN A ROOM / OFFLINE written | already |
| Room nametags and chat feed | crew color | `name#tag [CREW]` written | already |
| Room loop strip | crew color per dot | **fixed:** a dot shape per crew color (`net.room_crew_dot_facets`: triangles, squares, hexagons), chosen so no two colors a protanope, deuteranope or tritanope confuses (simulated ΔE < 25) share a shape; your own dot is the larger hexagon | fixed (tested) |
| Drag braking (touch overlay) | the thumb dot turns hot | **fixed:** a hot ring round the thumb (the gyro hold-brake's shape), in both drag visuals | fixed (tested) |
| Set-piece signs | amber / white faces | every sign has its legend (MERGING TRAFFIC, ROAD WORKS, …); the arrow board flashes | already |

### Color-blindness check (DEV ONLY)

`tools/snap.sh <scene> --cvd=protan,deutan,tritan,mono` (or `--cvd=all`) writes a simulated copy of each screenshot, `<png>_cvd-<kind>.png`, next to it. It is a post-process of the saved file (`src/ui/screens/dev/cvd_snap.gd` with `CvdFilter`), never a render pass: gameplay keeps the single color grade. Dichromacy uses the Machado, Oliveira and Fernandes (2009) matrices at full severity in linear RGB; `mono` is achromatopsia (Rec. 709 luminance). `CvdFilter.simulate()` and `delta_e()` also run in tests (the loop-strip shape rule).

Review snaps (both renderers, each with `--cvd=all` or `--cvd=deutan,protan`): `hud_preview.tscn --state=busy` (ghost, boosting, the event words), `--state=too_slow`, `--state=objective --failed=true`, and `screens_preview.tscn --screen=results_best`. What they show: every state keeps its word or shape under all four filters. One observation: the hot color (#ff5a4d) loses most of its lightness for a protanope, so hot text (TOO SLOW, FAILED, CHAIN LOST) reads dimmer on the dark panels, still legible; a lighter hot would help if the design system is revisited.

## Text size

Settings → TEXT SIZE is 100 % or 125 % (`hud.text_scales`) for the HUD and every screen. The game's canvas is 1280×720 stretched with `canvas_items` / `expand`, so a landscape display gives one of three canvas shapes: 1280×720 (16:9 phones), about 1560×720 (19.5:9 notched phones, 44 px side insets and a 21 px home indicator) and 1280×960 (4:3 tablets: 1024×768 and 2048×1536 windows both give it).

| Screen or widget | 1280×720 and 1560×720 | 1280×960 tablet |
| --- | --- | --- |
| HUD (every widget, busy values, both units, both hands), speed cluster, objective chip, leg toast | `tests/ui/test_text_fit.gd` | sweep (re-run) |
| Countdown, pause, settings, crash, results | `tests/ui/test_text_fit.gd` | sweep |
| Title, settings and account, online hub | `tests/ui/test_title_text_fit.gd` | sweep |
| Garage, results XP panel | `tests/ui/test_garage_text_fit.gd` | sweep |
| Achievements screen and title row | `tests/ui/test_achievements_text_fit.gd` | sweep |
| Achievement toast (placement, every title) | `tests/ui/test_achievements_toast.gd` | sweep |
| Friends and crews | `tests/ui/test_social_text_fit.gd` | sweep |
| First-run chooser | `tests/ui/test_first_run.gd` | sweep |
| Settings pages (pause and title) | `tests/ui/test_settings_panel.gd` | sweep |
| Leaderboards | `tests/ui/test_leaderboards_screen.gd` | sweep |
| Cooling icon (WP9.1) | `tests/platform/test_cooling_icon.gd` (1280, 1361, 1560) | a HUD rect in the sweep's HUD re-run |
| First-run warm-up hint | **new**: the sweep, all three canvases | the sweep |
| Room HUD (strip, line, N6.2 crew line and TRAIN badge, feed, toast, banner) and room menu | **new**: the sweep, all three canvases; the crew line and badge beside the HUD: `tests/ui/test_room_score_hud.gd` | the sweep (both) |

**The sweep.** `tests/a11y/test_text_size_sweep.gd` re-runs each per-screen test's own methods on the tablet canvas: it loads the test's source, swaps its `CANVASES` constant for `[1280×960]`, and runs the methods through `run_all.gd`'s lifecycle, forwarding every failure. Each screen keeps its own fixture and rules, and nothing is copied. The warm-up hint and the room HUD, which had no text-fit test, get the same rules (inside its box, its panel or button and the safe area; no overlaps; touch-sized buttons; off the HUD's panels) at all three canvases.

**Findings and fixes.** Every screen with a text-fit test also fits the tablet canvas at both sizes. The two new checks found three problems, all fixed:

- **Warm-up hint, 125 % on 1280×720 and 1280×960:** its panel (the two lines with SKIP beside them, 413 px) reached 14 px into the event stack's column. When it would, SKIP now goes under the lines (a narrower, taller panel; the warm-up's road is empty, so nothing is read there). The notched 1560 canvas keeps the one-row panel. `FirstRunWarmupHint._layout`.
- **Room chat feed, 125 % on 1280×720:** a long `name#tag  TEXT` line ran under the crash-out toast in the centre column. N6.2 landed the same rule in parallel (the name shortened with "…" so the line ends before the event stack's column); the merge keeps that one rule and makes it live: the sender and message are kept whole and every layout (a text-size change included) re-fits the shown line (`RoomHud._fit_feed`, `_place_feed`); `feed_text()` returns the full line.
- **Room crash-out toast, 125 % on 1280×720 and 1560×720 (after N6.2's crew line moved the feed down):** the official-score line made the toast wider than the event stack's column, and it ran over the chat feed. A toast that would reach over the feed's column now drops below the feed's reserved area (`RoomHud._place_toast`).
- **Room HUD text size was not live:** it read the setting once, at setup, so a change made during a room run left it at the old size. It now restyles on `settings_changed(text_scale)` (`RoomHud.restyle()`).

## Audio and haptic redundancy

Every critical warning should reach a player who cannot see it: a sound, a pulse or both. `tests/a11y/test_alert_redundancy.gd` emits each warning with a real `GameAudio` and a recording `Haptics` listening.

| Warning | Visual | Sound | Haptic | Status |
| --- | --- | --- | --- | --- |
| Life lost (first hit) | a gem breaks | `hit_impact` + `sting_hit` | strong burst, 150 ms | covered |
| Crash (run over) | crash cinematic, lives | `crash_metal`, `crash_glass`, `hit_impact`, `sting_hit` | long rumble, 400 ms | covered |
| HESITATED (chain lost to the minimum speed) | HESITATED line | `sting_hesitated` | **none** | gap (haptic) |
| Minimum speed (TOO SLOW) | strip + TOO SLOW | **none** | **none** | gap |
| Set-piece warning (signs at 600 / 500 / 400 / 300 m) | the signs in the world | **none** | **none** | gap |
| Shoulder penalty | SHOULDER line | **none** | **none** | gap |

The gaps are in `src/audio/` and `src/platform/haptics.gd`, outside WP9.3's paths; they are handoff requests. The test holds each one to still being a gap, so the fix fails it until the row moves out of `KNOWN_GAPS` and this table.

## Open questions

- **Speed lines under reduced motion.** The spec's list (shake, roll, FOV punch, slow motion) keeps them, and docs/FEEL.md recorded that decision; radial streaks are a strong sense-of-speed (vection) cue, which is what reduced-motion players often want gone. A tuning scale for them is a one-line change if the owner wants it.
- **The warning cues** above need an audio asset (a short warning tone) and a haptic pattern each.
