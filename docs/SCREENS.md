# In-run screens (WP4.4)

The countdown (with gyro calibration), the pause menu with its compact settings, the crash's TAP TO SKIP hint and the results. Spec: *UI, HUD and design system → Screens, Design system, Accessibility*; *Run end*; *Controls → Gyro steering*. Contract: [CONTRACTS.md §14](CONTRACTS.md#14-run-hud-and-screens-phase-4) (screens are Control scenes under `src/ui/screens/` that emit intents; the run acts on them).

| File | Class | Role |
| --- | --- | --- |
| `run_screens.gd` / `.tscn` | `RunScreens` | CanvasLayer (layer 60): shows the screen for the Game state, re-emits the intents |
| `run_screen.gd` | `RunScreen` | base: always processes, `visible = false` when inactive, tweens, layout in the safe area |
| `countdown_screen.gd` / `.tscn` | `CountdownScreen` | 3-2-1-GO, the gyro card, the web motion-permission tap |
| `pause_screen.gd` / `.tscn` | `PauseScreen` | RESUME, RECALIBRATE (gyro), SETTINGS, QUIT |
| `settings_panel.gd` | `SettingsPanel` | the in-run settings rows (inside the pause screen) |
| `crash_screen.gd` / `.tscn` | `CrashScreen` | TAP TO SKIP; the whole screen takes the tap |
| `results_screen.gd` / `.tscn` | `ResultsScreen` | score count-up, NEW BEST, the stats, RETRY and GARAGE |
| `screen_text.gd`, `screen_button.gd`, `screen_panel.gd` | `ScreenText`, `ScreenButton`, `ScreenPanel` | the design-system pieces, drawn with the HUD's helpers |
| `dev/screens_preview.tscn` | | snap scene over the real run |

## Wiring

```gdscript
screens = preload("res://src/ui/screens/run_screens.tscn").instantiate()
add_child(screens)
screens.bind(hub, feed)                       # PlayerInput (gyro) and HudFeed (leg, summary)
screens.resume.connect(resume)
screens.recalibrate.connect(hub.recalibrate_gyro)
screens.retry.connect(retry)
screens.quit.connect(retry)                   # no title screen until Phase 8
screens.skip.connect(skip)
screens.countdown_hold.connect(hold_countdown)
```

`RunScreens` listens to `Events.game_state_changed`, `run_started`, `countdown_tick`, `run_over` and `settings_changed`. It never touches gameplay.

| Game state | Screen |
| --- | --- |
| COUNTDOWN | Countdown (from `run_started` and `countdown_tick`) |
| RUNNING | none; GO holds, fades and hides itself |
| PAUSED | Pause (the countdown hides and comes back on resume with its step) |
| CRASH | Crash (TAP TO SKIP) |
| RESULTS | Results, opened by `run_over` (which follows the state change) |
| BOOT, MENU | none |

- **Run changes** (`src/run/run.gd`):
    - `RunUi` is gone. The HUD always exists, so the fallback readouts went with it.
    - The HUD also steps aside while paused (`_sync_hud`), because the pause menu is full screen.
    - `hold_countdown(on)` holds the auto countdown.
    - The countdown step comes from tuning: `hud.countdown_step_s` on the first run and `hud.retry_countdown_step_s` on a retry.
    - `run_over` also carries `previous_best`, the best before this run, for the comparison.
- **Countdown ownership:** the run keeps counting in sim ticks (`auto_countdown` stays on), so the countdown is deterministic, pauses with the tree and needs no frame timing. The screen shows `countdown_tick` and asks for the hold when it needs one.
- **Layer 60:** above the dev rows (50), so the modal screens cover them, and below the dev HUD (100), a diagnostic overlay. The countdown never blocks touches, so the dev rows keep working during it (rule 10).

## Countdown

- **Numbers.** 3, 2 and 1 in Chakra Petch 700 at `font_countdown_px`, speed-tilted, with the HUD's outline and drop shadow and tabular digits. Each step punches in (from `countdown_punch_scale_pct`, back-eased, over `countdown_punch_s`). GO is in the accent. It holds for `countdown_go_hold_s`, fades over `countdown_go_fade_s`, then the screen hides.
- **Info column.** Left-anchored at mid height, clear of the car and the HUD corners:
    - LEG n OF 8 with the biome name, and the leg objective's HUD label (e.g. "5 CLOSE PASSES") when there is one (WP5.6);
    - in gyro mode, a card: TILT STEERING / HOLD YOUR PHONE / IN DRIVING POSITION, with one slanted segment lit per step. At GO it turns gold: CALIBRATED / NEUTRAL LOCKED.
- **Gyro calibration.** docs/CONTROLS.md: "Neutral is captured during the 3-2-1 countdown". The screen emits `recalibrate` on every step, so the neutral follows the hold while the player settles in, and once more at GO, which locks it. The run forwards each to `PlayerInput.recalibrate_gyro()`. Gyro mode means `hub.effective_steering == GYRO`.
- **Web motion permission (iOS).** With gyro chosen on the web and the permission not yet granted (`WebMotionSource.permission_state()` is `idle` or `armed`):
    - `RunScreens` holds the countdown (`countdown_hold(true)`) and shows TAP TO ENABLE TILT STEERING.
    - The first tap anywhere grants the permission inside the browser's own gesture dispatch (the capture listener that `activate()` armed; see docs/CONTROLS.md → Web gyro). The same tap releases the hold, and the full countdown runs.
    - If the permission was refused, GO switches the hub back to the settings layout (drag).
- **Quick retry countdown.** A retry counts 3-2-1 at `retry_countdown_step_s` (0.5 s): 1.5 s from RETRY to driving, inside `retry_max_s` (2 s). See [Deviations](#deviations).

## Pause

- **Layout.** PAUSED (speed-tilted) top-left with a summary under it: LEG n OF 8, the distance driven, the banked total.
- **Buttons.** One column on the thumb side (right; left when left-handed), stacked bottom-up from the thumb:
    1. RESUME: primary, `primary_button_size_px` tall, nearest the thumb;
    2. RECALIBRATE: gyro only. It shows CALIBRATED for `recalibrated_note_s`;
    3. SETTINGS;
    4. QUIT: its edge turns hot when pressed. It is furthest from the thumb.

  Each is at least `touch_target_px` (88) tall and `menu_button_width_px` wide.
- **Input.** The tree is paused, so every screen has `PROCESS_MODE_ALWAYS`; tweens bound to them keep running. Esc, P or Start toggles the pause through the hub. Enter or Space resumes.
- **QUIT** starts a fresh run (`run.retry()`) until the title screen exists (Phase 8).

### Settings

A two-column grid of rows. Each row has a label and a segmented choice of OPTION buttons, each `touch_target_px` tall. A press calls `Settings.set_value` at once. The rows follow `Events.settings_changed`, so changes from the dev rows show too. Settings changed here are saved (`Save.save_to_disk()`) when the menu resumes or quits.

| Row | Key | Choices |
| --- | --- | --- |
| STEERING | `steering_mode` | DRAG / TILT (TILT disabled, marked N/A, where `is_gyro_supported()` is false) |
| THROTTLE | `throttle_mode` | AUTO / MANUAL |
| HAND | `left_handed` | RIGHT / LEFT |
| DRAG LOOK | `drag_visual` | RING / WHEEL |
| CONTROLS SIZE | `controls_scale` | `settings_controls_scales` (80 / 100 / 120%) |
| SENSITIVITY | `steer_sensitivity` | `settings_sensitivities` (75 / 100 / 135%) |
| UNITS | `units` | KM/H / MPH |
| TEXT SIZE | `text_scale` | `text_scales` (100 / 125%) |
| REDUCED MOTION | `reduced_motion` | OFF / ON |
| HAPTICS | `haptics` | ON / OFF |

Every key already exists in `Settings.DEFAULTS`. The spec's full settings screen (dead zone, curve, graphics tier, battery saver, audio buses, camera) is WP8.1 / WP8.5.

## Crash

The whole screen takes the tap during CRASH and emits `skip`, and keys still reach the run's own handler. The TAP TO SKIP chip appears after `crash_hint_delay_s` so the impact reads first, then pulses at `crash_hint_pulse_hz`. The timing is in real time, not the 0.25× slow motion.

## Results

`show_results(payload)` takes the `Events.run_over` payload: `RunStats.results` plus `personal_best`, `new_best` and `previous_best`.

- **Score.** RUN OVER, then the total in `font_results_score_px`, speed-tilted with tabular digits. It counts up from 0 over `results_count_s` (cubic ease-out).
- **Record.** NEW BEST is a gold chamfered badge. It pops when the count passes the old best, or at the end of the count on a first record. The score turns gold with it. The comparison line reads:
    - no record: BEST 2,010,000 · 725,500 TO BEAT;
    - a record: +336,900 OVER YOUR BEST;
    - a first record: FIRST RECORD.
- **Tiles.** DISTANCE (km or mi), LEGS (n, then OF 8 TO THE COAST, or COAST REACHED in gold), TOP SPEED (km/h or mph).
- **List.** BEST CHAIN, BEST MULTIPLIER (the HUD's × format), THREADS, CLOSE PASSES, TIME AT NIGHT (m:ss), HITS, COAST REACHED.
- **Buttons.** RETRY is primary, `primary_button_size_px`, bottom-right in thumb reach and mirrored when left-handed. GARAGE is disabled with SOON until Phase 8.
- **Guard.** RETRY ignores taps (and Enter) for `results_input_delay_s`, so the tap that skipped the crash never lands on it.
- **Motion.** The screen fades in, the tiles and rows slide in staggered by `results_row_stagger_s`, and the badge pops.

## Look and cost

- **Design system:**
    - `HudStyle`: the theme's colors and fonts at the text size, and the sky's accent (`SkyRig.accent_changed`);
    - `HudMesh`: chamfered panels with 1.5 px antialiased neon edges and accent tabs, one triangle array per piece;
    - `HudDraw`: text with the HUD's outline and shadow, and tabular digits.
    - Buttons: NORMAL, PRIMARY (accent fill, ink label, a `>>` speed chevron), DANGER (hot edge when pressed) and OPTION (the selected one is accent-tinted with a tab). A pressed face sinks 2 px. No gradients, no pills.
- **Layout.** Left-anchored on the 46 px grid (one cell of margin inside the safe area, `HudLayout.canvas_safe_rect`). Sizes follow the text size (100 / 125%); touch targets do not.
- **Transitions.** Tweens on modulate, scale and position that ignore `Engine.time_scale`. No blur and no full-screen shader. The pause and results dim the game with one ink `ColorRect` (`screen_dim_pct`).
- **Reduced motion:** fades only, with no punches, slides or pulse.
- **Hidden = `visible = false`,** never alpha 0. In gameplay (RUNNING after GO) nothing under the layer is visible: `RunScreens.visible_item_count() == 0`, tested. `tools/drawcalls.sh src/run/run.tscn --state=running` shows the layer's share as 0.
- **Touch.** Buttons are `BaseButton`s: they take the mouse events Godot emulates from touches, so raw touch ids (large on iOS Safari) never index anything. The tests tap with `Input.parse_input_event` and id `1_893_457_201`.

## Tuning (`data/tuning/hud.tres`, group Run screens)

- **Countdown:** `countdown_step_s`, `retry_countdown_step_s`, `countdown_punch_scale_pct`, `countdown_punch_s`, `countdown_go_hold_s`, `countdown_go_fade_s`.
- **Transitions:** `screen_fade_in_s`, `screen_fade_out_s`, `screen_slide_px`, `screen_dim_pct`.
- **Results:** `results_fade_in_s`, `results_count_s`, `results_row_stagger_s`, `results_badge_pop_s`, `results_input_delay_s`.
- **Crash and pause:** `crash_hint_delay_s`, `crash_hint_pulse_hz`, `recalibrated_note_s`.
- **Sizes:** `touch_target_px` (88), `primary_button_size_px`, `menu_button_width_px`, `settings_label_width_px`, `results_stats_width_px`, `results_stat_row_px`.
- **Type:** `font_countdown_px`, `font_title_px`, `font_results_score_px`, `font_screen_button_px`, `font_screen_body_px`.
- **Settings choices:** `settings_controls_scales`, `settings_sensitivities`.

## Preview

```
tools/snap.sh src/ui/screens/dev/screens_preview.tscn --renderer=both --sweep=screen:countdown,pause,settings,results,results_best,crash,hold
tools/snap.sh src/ui/screens/dev/screens_preview.tscn --screen=countdown --gyro --step=0
tools/snap.sh src/ui/screens/dev/screens_preview.tscn --screen=settings --hand=left --text_scale=1.25
tools/snap.sh src/ui/screens/dev/screens_preview.tscn --size=2496x1320 --screen=results_best     # the owner's iPhone
```

The preview is the real run (`run.tscn`) in the matching state, with the screen settled. The dev rows and dev HUD step aside unless you pass `--dev`. Options:

- `--screen=countdown|pause|settings|results|results_best|crash|hold`
- `--step=3|2|1|0`
- `--gyro`
- `--hand`, `--text_scale`, `--units`
- `--sky_t`
- `--reduced_motion`

## Tests

`tests/ui/test_run_screens.gd` covers:

- one screen per Game state, and nothing drawn when hidden;
- the countdown steps and GO;
- gyro recalibration on every step and the lock at GO (a fake tilt source; the neutral equals the hold at GO), and none in drag mode;
- the web permission hold released by an iOS-id tap;
- a pause from the countdown;
- every pause button through real touches while the tree is paused, and the menu on the thumb side (mirrored);
- every settings row writing `Settings`, and TILT disabled without tilt;
- every results key, the personal-best comparison, the NEW BEST pop, and the skip-tap guard;
- RETRY to RUNNING within `hud.retry_max_s` of sim time (1.5 s measured);
- TAP TO SKIP.

## Deviations

- **Quick retry countdown.** The spec wants a 3-2-1 countdown (with gyro calibration) and also "Retry puts the player back on the road within 2 seconds". Retry reaches COUNTDOWN on the road in the same frame. The retry countdown runs at 0.5 s a step, so the player is driving 1.5 s after RETRY. The first run keeps 1 s steps.
- **QUIT** starts a fresh run until the title screen exists (Phase 8).
- **GARAGE** is disabled until Phase 8.


## Account (N1.2)

Pause → SETTINGS → ACCOUNT (shown only when an online session exists: web builds and release exports; native dev runs are offline unless `--server=`). The `ProfilePanel` shows `name#tag` and online status, rename with inline server errors, TRY AGAIN / NEW ACCOUNT when signed out or failed, "Sign in with Apple / Google — coming soon" (MP-D2) and DELETE ACCOUNT with a confirm step. See docs/NET_CLIENT.md.
