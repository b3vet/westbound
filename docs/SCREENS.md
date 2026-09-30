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
screens.quit.connect(enter_menu)              # WP8.5: back to the title
screens.results_screen.menu.connect(enter_menu)   # WP8.5: the results' MENU
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
- **QUIT** goes back to the title (`run.enter_menu()`, WP8.5).

### Settings

WP8.1 (docs/SAVE.md → Settings has every setting, its key and what applies it). The same `SettingsPanel` is in the pause menu and on the title (SETTINGS). Under the header (SETTINGS, ACCOUNT, DONE) a row of page tabs, left-anchored: **GAME**, **CONTROLS**, **AUDIO** (each `settings_label_width_px` wide, text size applied). Under it the shown page: a label and a segmented choice of OPTION buttons per row, each `touch_target_px` tall; full-width rows first (the camera), then two columns. The label column is as wide as the page's longest label (at most `settings_label_width_px`), so three-option rows keep their captions at 125 %. A press calls `Settings.set_value` at once and every system applies it live from `Events.settings_changed`; the rows follow that signal too, so a change from the keyboard, the HUD or the dev rows shows at once. `Save` writes the change at the end of the frame (the pause menu's RESUME / QUIT and the title's DONE also save).

| Page | Row | Key | Choices |
| --- | --- | --- | --- |
| GAME | CAMERA (full width) | `camera_mode` | `camera.player_modes()`: CHASE / FAR CHASE / HOOD / OVERHEAD (the cockpit is hidden from players, plan D11 / docs/COCKPIT.md; `camera.cockpit_player_enabled` brings it back) |
| GAME | GRAPHICS | `quality_tier` | every `quality.tier_names`: LOW / MEDIUM / HIGH |
| GAME | BATTERY SAVER | `battery_saver` | OFF / ON |
| GAME | TEXT SIZE | `text_scale` | `text_scales` (100 / 125%) |
| GAME | UNITS | `units` | KM/H / MPH |
| GAME | REDUCED MOTION | `reduced_motion` | OFF / ON |
| GAME | HAPTICS | `haptics` | ON / OFF |
| CONTROLS | STEERING | `steering_mode` | DRAG / TILT (TILT disabled, marked N/A, where `is_gyro_supported()` is false) |
| CONTROLS | THROTTLE | `throttle_mode` | AUTO / MANUAL (default MANUAL, D22) |
| CONTROLS | HAND | `left_handed` | RIGHT / LEFT |
| CONTROLS | DRAG LOOK | `drag_visual` | RING / WHEEL (default WHEEL, D10) |
| CONTROLS | CONTROLS SIZE | `controls_scale` | `settings_controls_scales` (80 / 100 / 120%) |
| CONTROLS | SENSITIVITY | `steer_sensitivity` | `settings_sensitivities` (75 / 100 / 135%) |
| CONTROLS | DEAD ZONE | `steer_dead_zone` | `meta.settings_dead_zones`: SMALL / NORMAL / LARGE |
| CONTROLS | CURVE | `steer_curve` | `meta.settings_curves`: GENTLE / NORMAL / SHARP |
| AUDIO | MASTER, MUSIC, EFFECTS, ENGINE, INTERFACE | `volume_*` | `audio.volume_steps` (OFF, then %) |
| AUDIO | SOUND | `audio_muted` | ON / MUTED |

**CHOOSE LAYOUT** (the right end of the tab row, CONTROLS only) swaps the rows for the first-run chooser (below; the spec: "The chooser can be revisited from settings"); the button reads BACK while it shows. A tab, BACK, or closing the settings brings the rows back. **DEFAULTS** (left of it, CONTROLS only) puts every CONTROLS row back to `Settings.DEFAULTS` (drag + manual, right hand, wheel look, 100 % size, sensitivity, normal dead zone and curve); the other pages are untouched. It is how a player with an older save gets the new default layout (docs/SAVE.md → Settings).

## First run

WP8.1 (docs/SAVE.md → First run). Spec: Controls → Settings and first run.

| File | Class | Role |
| --- | --- | --- |
| `first_run_screen.gd` | `FirstRunScreen` | The chooser screen over the title (a RunScreen, built on first use by `TitleScreens.open_first_run`) |
| `first_run_chooser.gd` | `FirstRunChooser` | The chooser itself: STEERING, THROTTLE, HAND and the sketch (also in the settings) |
| `first_run_sketch.gd` | `FirstRunSketch` | A landscape phone with the chosen layout: the drag ring (steer left / right, brake down, boost up), the manual drag zone, the gas column with its boost cap and the brake, the tilted phone; mirrored for left-handed play |
| `first_run_warmup.gd` | `FirstRunWarmupHint` | The warm-up's hint (a CanvasLayer at layer 6) |

- **When.** On a fresh save (`Save.chooser_pending()`), the title's PLAY, DAILY DRIVE or the hub's LOOP PRACTICE opens the chooser instead of starting; the menu steps aside. Never again once answered, and never under the test runner or tools (docs/SAVE.md → Tests and tools).
- **Layout.** HOW DO YOU DRIVE? (display face, speed-tilted) top-left and PICK YOUR CONTROLS · CHANGE THEM ANY TIME IN SETTINGS under it in the accent. The rows left-anchored: a label, then two big OPTION cards with a note each (DRAG "SLIDE A THUMB" / TILT "TILT THE PHONE", N/A without tilt; AUTO "GAS ALWAYS ON" / MANUAL "GAS + BRAKE PEDALS"; RIGHT / LEFT "MIRRORED"); on a fresh save the default (drag + manual, right hand; plan D22, owner 2026-10-01) preselected. Right of them the sketch and two lines naming the layout (ONE THUMB DOES IT ALL / DOWN BRAKES · FLICK UP BOOSTS, ...; the words LEFT and RIGHT swap when mirrored). DRIVE (primary, `primary_button_size_px`) in the thumb corner with SKIP (note DRAG + MANUAL) beside it; both mirror at once when LEFT is chosen.
- **Intents.** A card writes Settings at once (the settings rows follow). DRIVE keeps the choice; SKIP puts the defaults back (drag + manual, the wheel look, right hand: `FirstRunChooser.apply_defaults`); either records it (`Save.mark_chooser_done`) and `TitleScreens` starts the mode that asked. Enter drives; Esc goes back to the title (still pending).
- **Warm-up hint.** During the first Journey's empty-road warm-up: a panel right-aligned under the HUD's lives, pause, camera and high-beam slots (clear of the top-centre readouts, the leg toast and the dev rows): WARM-UP · EMPTY ROAD in the accent, TRAFFIC IN n S (tabular, changes once a second), SKIP (a touch target). At the end (or SKIP) the line reads TRAFFIC AHEAD, SKIP goes, and the panel hides after `meta.warmup_end_note_s`. Under the pause menu's dim while paused. Nothing exists outside the first run.

Previews:

```
tools/snap.sh src/run/run.tscn --renderer=both --state=menu --title=play --first_run=1          # the chooser from PLAY
tools/snap.sh src/ui/screens/dev/screens_preview.tscn --renderer=both --screen=settings --sweep=page:game,controls,chooser,audio
tools/snap.sh src/ui/screens/dev/screens_preview.tscn --renderer=both --screen=warmup --warmup_s=3
```

Tests: `tests/ui/test_settings_panel.gd`, `tests/ui/test_first_run.gd`, `tests/run/test_first_run_warmup.gd` (docs/SAVE.md → Tests and tools).

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
- **Buttons.** RETRY is primary, `primary_button_size_px`, bottom-right in thumb reach and mirrored when left-handed. GARAGE (WP8.2) beside it goes to the title with the garage open (`garage` → `Run.open_garage`). MENU (WP8.5) sits next to LEADERBOARDS, away from RETRY, and goes back to the title; it obeys the same tap guard.
- **XP (WP8.2).** Under the stats list, a panel: DRIVER LEVEL n and +XP (accent, tabular), the level bar (`GarageXpBar`; gold on a level-up), then LEVEL UP · NEW: SUNSET PAINT, MESH RIMS in gold (shortened to LEVEL UP · n NEW IN THE GARAGE when the names do not fit), or 12,400 XP TO LEVEL 4 (muted), or MAX LEVEL. It reads the payload keys `Garage.award_run` adds (docs/GARAGE.md) and hides without them (tests, tools). It slides in after the rows.
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

- `--screen=countdown|pause|settings|results|results_best|crash|hold|warmup` (warmup: WP8.1, `--warmup_s=`)
- `--page=game|controls|audio|chooser` (settings)
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


## Account (N1.2)

Pause → SETTINGS → ACCOUNT (shown only when an online session exists: web builds and release exports; native dev runs are offline unless `--server=`). The `ProfilePanel` shows `name#tag` and online status, rename with inline server errors, TRY AGAIN / NEW ACCOUNT when signed out or failed, "Sign in with Apple / Google — coming soon" (MP-D2) and DELETE ACCOUNT with a confirm step. See docs/NET_CLIENT.md.

## Leaderboards (N7.2)

The online leaderboards, replacing the Game Center / Play Games boards (multiplayer handoff → Leaderboards, Client changes → Leaderboards screen). Data and requests: docs/NET_CLIENT.md → Runs and leaderboards client.

| File | Class | Role |
| --- | --- | --- |
| `leaderboards_screen.gd` | `LeaderboardsScreen` | the screen (a `RunScreen`), opened over the pause menu or the results |
| `leaderboards_list.gd` | `LeaderboardsList` | the list: pooled rows, drag / fling / wheel, pull to refresh, taps, the pinned own row |
| `leaderboards_row.gd` | `LeaderboardsRow` | one custom-drawn row (one mesh + its texts) |
| `results_online.gd` | `ResultsOnline` | the results' online panel (placements, NEW PB, VERIFYING, the waiting and refused states) |
| `dev/leaderboards_preview.tscn` | | snap scene over the real run, on the in-memory boards server (or `--server=` a local one) |

### Where it opens

- **Pause:** LEADERBOARDS sits above QUIT in the menu column (the same size as the others). It shows only when an online session exists, like ACCOUNT.
- **Results:** LEADERBOARDS at the bottom, on the side away from RETRY (bottom-left; bottom-right when left-handed). It opens on the run's board (Journey or Daily Drive) and obeys the results' tap guard.
- `LeaderboardsScreen.attach(host, …)` builds it the first time only (a child of the host), and `open_over(host)` hides the host's widgets (its dim stays) until BACK or Esc brings them back. A new pause or new results close it. Hidden = `visible = false`: nothing draws in gameplay (`RunScreens.visible_item_count() == 0`), and nothing exists before the first open.

### Layout

- **Top row:** LEADERBOARDS (display face, speed-tilted), the period control, BACK at the right end.
- **Periods:** Loop: SEASON / ALL TIME. Journey: THIS WEEK / ALL TIME. Loop crew: SEASON. Distance: ALL TIME. Daily Drive: a day stepper `<` TODAY `>` (YESTERDAY, then SEP 27 …, back `boards_daily_days_back` days; the middle button goes back to today).
- **Tabs:** LOOP SEASON, LOOP CREW, JOURNEY, DAILY DRIVE, DISTANCE in a column on the left, each `touch_target_px` tall.
- **List:** a panel on the right. Row: rank (the podium in gold), name + `#tag` (muted), the crew tag chip, the LEGACY (muted) or VERIFYING (accent) chip, the score (tabular; Distance in km or mi with the units setting). Crew rows on Loop crew show the crew's name and tag. The player's row is accent-filled with a gold score; when it is out of view (a rank past the top 100, or scrolled away) it is pinned at the bottom of the list. Long names end in an ellipsis.
- **Bottom row:** the views TOP 100 / AROUND ME / FRIENDS on the thumb side (right; left when left-handed), the status line on the other side: "241 ON THIS BOARD", UPDATING..., PULL TO REFRESH / RELEASE TO REFRESH, REPORTED. THANKS., BLOCKED, OFFLINE (a cached page shown while the server can't be reached). The status line gives way when the buttons need its room (125% text with the row actions).
- **Around me** centres the player's row.

### Touch

- The list reads the mouse events Godot emulates from touches (never a touch index). A press that moves less than `boards_tap_slop_px` is a tap; more scrolls, and the release flings (`boards_fling_decay`). The wheel scrolls a row.
- **Pull to refresh:** at the top, the list follows half the finger; past `boards_pull_refresh_px` the status reads RELEASE TO REFRESH and letting go reads the page again.
- **Report / block:** tapping another player's row selects it (accent edge) and puts REPORT CHEATING, REPORT NAME, BLOCK and CANCEL where the views were. BLOCK asks for a second tap (CONFIRM BLOCK). Your own row and crew rows take no actions. The answer shows in the status line (TOO MANY REPORTS TODAY for the server's daily limit). The full friends UI is N9.2.

### States

In the list's panel, centred: LOADING..., NO RUNS HERE YET, NO FRIENDS HERE YET, YOU'RE NOT ON THIS BOARD YET (around me without an entry), CREWS RANK HERE (the crew board has no friends view), NOT SIGNED IN (around me and friends need the account), OFFLINE with RETRY, COULDN'T LOAD with the server's reason, ONLINE IS OFF (no session).

### Cost

- **Rows are pooled:** about `list height / row height + 2` `LeaderboardsRow` controls (10 at 1280×720), rebound as the list scrolls; 100 entries never make 100 controls. A row is one canvas item (one `HudMesh` triangle array plus its texts) and redraws only when rebound to different content. The rows sit in a clipping child above the pinned row.
- The screen is built on first use and hidden with `visible = false`.

### Results → Online

Under the tiles, with a Journey or Daily Drive run and an online session. The results never wait for it: they open at once and the panel follows the submission.

| Submission | Shows |
| --- | --- |
| sending | SUBMITTING... |
| queued: offline / 429 / signed out / suspended | OFFLINE — WILL SUBMIT / WILL SUBMIT SHORTLY / NOT SIGNED IN — WILL SUBMIT / ACCOUNT SUSPENDED (hot) |
| done | "#12 THIS WEEK  ·  #340 ALL TIME" (Journey) or "#3 TODAY" (Daily; YESTERDAY or the date for a run across midnight), "#812 DISTANCE" under it, and the NEW PB (gold) and VERIFYING (accent) chips. It slides in (`boards_reveal_s`) and NEW PB punches when the answer arrives |
| rejected `build_unsupported` | UPDATE REQUIRED (hot), "Update Westbound to post scores online." |
| rejected (another check) | NOT RANKED, "This run didn't pass the server's checks." |
| refused / too old | COULDN'T SUBMIT / TOO OLD TO SUBMIT |

NEW PB is the server's word: the run improved the mode's all-time entry (Journey) or the day's (Daily Drive). The local NEW BEST badge and comparison line stay as they were.

### Preview

```
tools/snap.sh src/ui/screens/dev/leaderboards_preview.tscn --renderer=both --sweep=view:global,around_me
tools/snap.sh src/ui/screens/dev/leaderboards_preview.tscn --state=empty            # also offline, signin, loading
tools/snap.sh src/ui/screens/dev/leaderboards_preview.tscn --select=2 --hand=left --text_scale=1.25
tools/snap.sh src/ui/screens/dev/leaderboards_preview.tscn --board=daily --days_back=3 --size=1560x720
tools/snap.sh src/ui/screens/dev/leaderboards_preview.tscn --screen=results --result=pending   # also done, offline, update, sending
tools/snap.sh src/ui/screens/dev/leaderboards_preview.tscn --server=http://127.0.0.1:18480 --from=results   # a local server
```

### Tests

`tests/ui/test_leaderboards_screen.gd`: opened from the pause menu by an iOS-id tap (built on first use, the menu steps aside, BACK and Esc bring it back, nothing drawn in gameplay, a new pause starts at the menu); no session: no buttons, ONLINE IS OFF; every tab, period, view and Daily day asking for the right URL; the own row pinned in the top 100 and highlighted and centred in around me; signed out: around me asks to sign in, global still reads; a small row pool scrolled by a touch drag and the wheel, rows not redrawn when unchanged; pull to refresh forcing a read; loading, empty (three kinds), crew friends, offline + RETRY, offline over a cached page; report cheating / name and block (with its confirm) from a row, not on your own row, the daily report limit; the results' placements arriving after the results opened (SUBMITTING... first, then the ranks, the chips and the slide-in), OFFLINE — WILL SUBMIT then UPDATE REQUIRED, none for Loop practice, and LEADERBOARDS from the results; text fit at both text sizes, both hands and the notched 1560×720 canvas (the top 100 with the longest name and markers, the row actions, around me pulled, a Daily date, offline, the results with every chip and with UPDATE REQUIRED).

## Social (N9.2)

Pause → SETTINGS → ACCOUNT → **FRIENDS** / **CREW**. The social screens sit inside the ACCOUNT panel as a tab row (ACCOUNT / FRIENDS / CREW, shown whenever a session exists) instead of a new pause-menu button, so the pause column (where N7.2 adds LEADERBOARDS) is untouched and `pause_screen.gd` has no N9.2 edit. The title stays ACCOUNT; the selected tab names the view. The tab row's right end holds PREV / NEXT and the page ("1/2") for the list below. Implementation and data flow: docs/NET_CLIENT.md → Social client.

| File | Class | What it is |
| --- | --- | --- |
| `src/ui/screens/friends_panel.gd` | `FriendsPanel` | The friends list (requests, friends by presence, your requests; or the blocked list), ADD FRIEND, your code with COPY CODE, and a player's sheet |
| `src/ui/screens/crew_panel.gd` | `CrewPanel` | CREATE A CREW / JOIN A CREW, or the crew card, invite code, LEAVE / DISBAND, members and a member's sheet |
| `src/ui/screens/report_dialog.gd` | `ReportDialog` | The reusable report dialog (friends, crew, N7.2's boards, N5's room menu) |
| `src/ui/screens/social_row.gd` | `SocialRow` | A list row: presence dot, `name` `#tag` `[CREW]`, a status line, up to two buttons |
| `src/ui/screens/social_actions.gd` | `SocialActions` | An action sheet with confirm steps (the question in hot text, CONFIRM / CANCEL) |
| `src/ui/screens/social_field.gd` | `SocialField` | Text field: on-screen keyboards (the web prompt), key muting |
| `src/ui/screens/social_ui.gd` | `SocialUi` | Name fitting, button widths, field look, web clipboard / share / prompt |
| `src/ui/screens/dev/social_preview.tscn` | | Snap scene |

**Friends.** Left (58 %): `FRIENDS n/100 · k ONLINE`, then rows of touch-target height: requests waiting for you (WANTS TO BE FRIENDS, ACCEPT, MORE), friends in a room (gold dot, IN A ROOM, JOIN when the room has space), online (accent dot), offline (muted dot), then your requests (REQUEST SENT, CANCEL). JOIN is the N5 seam: disabled with SOON until `NetSocialClient.join_handler` is set. Right: ADD FRIEND (the code field + SEND; the answer in the note line, e.g. "No player with that code." whether unknown or blocked), YOUR FRIEND CODE with COPY CODE, and BLOCKED n (the blocked list with UNBLOCK; FRIENDS switches back). MORE opens the player's sheet in the right column: REMOVE FRIEND (or DECLINE for a request), BLOCK (both confirmed: "Remove X from your friends?", "Block X? They can't add or invite you."), REPORT, BACK. The FRIENDS tab's second line counts waiting requests ("1 NEW").

**Crew.** Without one: CREATE A CREW (name, tag, CREATE; the filter's and the rules' answers in the hint line) and JOIN A CREW (invite code, JOIN). In one: the card (`[TAG] Name`, `n/16 MEMBERS · YOU: ROLE`, `SEASON 2026-09: #3 · 183,200` or NOT ON THE BOARD YET), INVITE CODE with COPY, SHARE (only where the browser has a share sheet) and NEW CODE (owner, officers), then LEAVE CREW and DISBAND (owner), each confirmed. Right: MEMBERS n/16, owner first, `OWNER · YOU` on your row; MORE on another member opens their sheet over the left column with only what your role may do (`NetCrew.allowed_actions`: MAKE OFFICER / MAKE MEMBER / MAKE OWNER / KICK, each confirmed) plus REPORT and BACK.

**Report.** A faceted card over the tab's area: REPORT PLAYER, `name#tag`, the note line; the six reasons as option buttons (CHEATING, OFFENSIVE NAME, OFFENSIVE CREW, HARASSMENT, GRIEFING, OTHER); SEND REPORT → "Report for harassment?" with REPORT / BACK → "Report sent. Thank you." with DONE. A 429 shows "Report limit reached. Try again in 24 h." and keeps SEND off until the wait ends (also when reopened). Other screens: `add_child(dialog)`, `setup(style, tuning)`, `layout(area)`, `open_for(client, account_id, full_name, context)`, and hide their own content while it shows (`visibility_changed`).

**Rules.** Every button and field is at least `touch_target_px` (88) tall; names that don't fit are shortened with "..." (never a question or an error: confirm questions shorten the name inside them). Everything is under the pause screen, so nothing draws during gameplay (`RunScreens.visible_item_count() == 0`). While a field has focus the run's `PlayerInput` stops reading keys. Text fields on a touch-screen web page open the browser's prompt (see docs/NET_CLIENT.md → On-screen keyboards).

```
tools/snap.sh src/ui/screens/dev/social_preview.tscn --renderer=both --sweep=social:friends,sheet,confirm,error,blocked,crew,member,crew_confirm,crew_none,crew_error,report,report_confirm,report_sent,report_limited
tools/snap.sh src/ui/screens/dev/social_preview.tscn --size=2496x1320 --text_scale=1.25 --social=crew
```

**Tests:** `tests/ui/test_social_screens.gd` (tabs, rows and presence, the JOIN seam, add / accept / cancel with errors inline, remove / block confirms, the blocked list, paging, offline, report flow and rate limit, crew create / join errors, the role UI per role, crew confirms, copy, the web prompt, key muting, the pause-menu path and zero draw items when hidden) and `tests/ui/test_social_text_fit.gd` (every state with 16-W names and 24-W crew names, every note text shown whole, touch targets and safe area, both text sizes, both hands, 1280x720 and a notched 1560x720).


## Title (WP8.5)

The game boots into the title: the run's MENU state over the attract drive (docs/RUN.md → Title and attract). Spec: UI → Screens ("Title: the attract camera drives the selected car; Play, Daily Drive, Garage, Leaderboards, Settings"); Design system; Accessibility; multiplayer handoff → Client changes (Online hub).

| File | Class | Role |
| --- | --- | --- |
| `title_screens.gd` | `TitleScreens` | CanvasLayer (layer 60, like RunScreens; they never show together): built on first use, opened by the run in MENU, emits `start(mode)` |
| `title_screen.gd` | `TitleScreen` | the title: logo, menu, profile chip, settings / account view, leaderboards |
| `online_hub_screen.gd` | `OnlineHubScreen` | the online hub: rooms (N5.2), loop practice, friends, crew, leaderboards |
| `room_lobby_panel.gd` | `RoomLobbyPanel` | N5.2: the hub's room flows (PRIVATE ROOM, JOIN BY CODE, ROOM BROWSER, joining) |
| `title_profile_chip.gd` | `TitleProfileChip` | `name#tag` and the online status (a ScreenButton) |
| `title_band.gd` | `TitleBand` | the slanted ink band behind the left-anchored menus (one draw call) |

### Layout

- **Left-anchored, up from the bottom-left thumb:** a row of LEADERBOARDS, SETTINGS, GARAGE (WP8.2: the garage) and ACHIEVEMENTS (WP8.3); above it PLAY (primary, `primary_button_size_px` tall, `menu_button_width_px` wide: Journey), DAILY DRIVE (today's UTC date under the label: "WED SEP 30") and ONLINE ("LOOP PRACTICE · ROOMS SOON"). Every button is at least `touch_target_px` tall.
- **Logo:** WESTBOUND in Chakra Petch (the display face) at `font_logo_px`, outlined and speed-tilted (speed_tilt.gdshader), CHASE THE SUN under it in the accent.
- **Band:** ink at `title_band_pct` from the left edge to `title_band_width_px`, its right edge leaning with the speed tilt and lined with the accent. The attract drive shows through it; the car sits right of centre (the camera's frame yaw).
- **Profile chip (top-right):** the session's `name#tag` (PLAYER before a sign-in) and its status word (ONLINE, CONNECTING, OFFLINE, ...; ONLINE OFF without a session) after a status diamond (accent online, gold connecting, hot suspended / refused, muted otherwise). It follows `status_changed` / `profile_changed`. It never reaches the logo: the name is shortened with "..." to the room right of it (and `title_chip_max_width_px`). A tap opens ACCOUNT (or the settings without a session).
- **SETTINGS:** the pause menu's settings view: SETTINGS (at `font_title_px`) top-left, DONE and ACCOUNT top-right, the SettingsPanel (GAME / CONTROLS / AUDIO pages, WP8.1) or the ProfilePanel (ACCOUNT / FRIENDS / CREW) under them, over the dim. Settings are saved when DONE closes the view or a run starts.
- **LEADERBOARDS:** the existing LeaderboardsScreen over the title (BACK / Esc comes back).
- **Keys:** Enter plays; Esc closes the settings view.
- **Text size:** 100% / 125% (`text_scale`), restyled live; touch targets do not scale. Not mirrored for left-handed play (the title has no thumb-side control column; the band and logo anchor left).

### Online hub

ONLINE (speed-tilted) and the status line (`name#tag · ONLINE`, or "ONLINE IS OFF IN THIS BUILD · LOOP PRACTICE STILL WORKS") top-left, BACK top-right (Esc too). A ROOMS panel (UP TO 8 PLAYERS in gold): QUICK JOIN, ROOM BROWSER, PRIVATE ROOM, JOIN BY CODE (N5.2, below); without the server (`?server=off`) they are disabled with ONLINE OFF and the panel says "Rooms need the online server. Loop practice still works." (OFFLINE and the reason while signing in or offline). LOOP PRACTICE (primary, bottom-left, "SOLO ON THE LOOP · WORKS OFFLINE" over it) starts the run in loop mode, the same as `?mode=loop`. FRIENDS, CREW and LEADERBOARDS go up from the right thumb: FRIENDS / CREW open the title's account view on that tab and DONE comes back to the hub (disabled, ONLINE OFF, without a session); LEADERBOARDS opens on the Loop board.

### Rooms (N5.2)

Docs: [ROOMS_CLIENT.md](ROOMS_CLIENT.md). The room buttons open `RoomLobbyPanel` over the dimmed hub, one view at a time; every button is a ScreenButton at least `touch_target_px` tall; Esc / BACK closes it.

| Button | View | Then |
| --- | --- | --- |
| QUICK JOIN | joining status: "CONNECTING...", "FINDING A ROOM...", CANCEL | the room |
| PRIVATE ROOM | TRAFFIC: LIGHT / NORMAL / RUSH HOUR; TIME OF DAY: CYCLE / MORNING / GOLDEN (fixed) / NIGHT; CREATE ROOM, BACK | "CREATING YOUR ROOM...", the room |
| JOIN BY CODE | the code field (6 characters; lower case, spaces and dashes are forgiven; a wrong code says "A code is 6 letters and digits."), JOIN, BACK | "JOINING ABC234...", the room |
| ROOM BROWSER | up to 4 public rooms, fullest first: `7/8 · NORMAL · NIGHT ×2 · 42 MS` (a full room disabled), REFRESH (also every `room_browse_refresh_s`), BACK; none: "NO PUBLIC ROOMS YET · QUICK JOIN STARTS ONE" | "JOINING ROOM 12...", the room |

**In the room (N6.2, multiplayer scoring; ROOMS_CLIENT.md → Scoring in a room):** the room HUD's crew line under the room line (`CREW ×1.50 · 2 NEAR`, accent while crewmates are within 30 m, `CREW ×1.00` muted otherwise) with the gold TRAIN ×n badge beside it for 2.5 s after each train link (the train counter; `TRAIN ×n +pts` also on the event stack); an official sector bonus the run did not pay on the event stack; the gameplay HUD's banked total eased to the official score at banking moments; the crash-out toast with the official score; the room menu's PLAYERS with `CREW TOTAL 48,250` (gold) beside LEAVE ROOM. Text fit at 100 % / 125 % on 1280×720 and a notched 1560×720 beside the gameplay HUD (`tests/ui/test_room_score_hud.gd`): top half, clear of the thumb zones (a long name is shortened on the chat feed so its line stays clear of the event stack).

A refusal shows the server's reason in hot text ("No room with that code.", "That room is full.", ...) with TRY AGAIN and BACK. When the room's snapshot arrives the panel closes and the hub emits `room_ready(session)`; the run drives in the room (in-room HUD: ROOMS_CLIENT.md → Room HUD). Leaving the room (LEAVE ROOM, the pause menu's QUIT), a kick, the room closing or the seat lost come back to the hub with the reason on the ROOMS panel in hot text.

### Party (N9.3)

Docs: [ROOMS_CLIENT.md](ROOMS_CLIENT.md) → Parties. The ROOMS panel has a third column: PARTY over the party's line (`NO PARTY YET`, `3/8 · YOU LEAD`, `3/8 · Dusty#1234 LEADS`, gold `Dusty#1234 INVITES YOU`; shortened with "..."). PARTY opens RoomLobbyPanel's PARTY view (a waiting invite's card first): without a party CREATE PARTY / JOIN PARTY (a code field) / BACK; in one, `PARTY K7QX2M`, the members in two columns (LEADER, YOU; the leader removes with two taps: TAP AGAIN TO REMOVE), who picks the room, INVITE FRIENDS (the account view on FRIENDS), SHARE LINK (or COPY LINK), LEAVE PARTY, BACK. An invite arriving while the hub shows opens PARTY INVITE (gold `name#tag INVITES YOU`, DECLINE, ACCEPT). The friends list gets INVITE on online friends and a live JOIN ("FRIEND'S ROOM · JOINING ROOM 12..."). An invite link (`?room=` / `--room=`) opens the hub with INVITE LINK · JOINING K7QX2M... (a room, else the party). The room menu (ROOMS_CLIENT.md → Room HUD) gets a ROOM tab: the invite link with COPY LINK / SHARE, and for the host TRAFFIC, TIME OF DAY and REMOVE A PLAYER. Snaps: `tools/snap.sh src/ui/screens/dev/party_preview.tscn --renderer=both --sweep=party:none,lead,member,kick,invite,link,hub` (and `--seconds=2.5 --sweep=party:room_host,room_player`). Tests: `tests/ui/test_party_ui.gd`, `tests/ui/test_room_menu_host.gd` (flows through iOS-style touch ids and text fit at both text sizes on 1280x720 and a notched 1560x720).


### Flow

| From | Intent | Run |
| --- | --- | --- |
| Title PLAY / Enter | `start(&"journey")` (WP8.1: after the first-run chooser on a fresh save) | `start_mode`: the Journey run, full 1 s countdown, same frame (the first one on a fresh save warms up) |
| Title DAILY DRIVE | `start(&"daily")` | the day's seed (`Rng.daily_seed` of today's UTC date) |
| Hub LOOP PRACTICE | `start(&"loop")` | loop mode (N3.2) |
| Hub room joined (N5.2) | `room_ready(session)` | `start_room(session)`: loop mode in the room (RunRoom) |
| Pause RETRY in a room | `retry` | REJOIN CREW (`run_event.rejoin`) |
| Pause QUIT | `quit` | `enter_menu()` |
| Results MENU | `menu` | `enter_menu()` |
| Results RETRY | `retry` | `retry()`: the same mode (Daily keeps the day's seed) |
| Title GARAGE | `TitleScreens.open_garage` | none while open; DONE → `garage_closed` → `refresh_menu_car()` (the attract drive takes the selected car and look) |
| Results GARAGE | `garage` | `open_garage()`: `enter_menu()`, then the garage over the title |
| Title ACHIEVEMENTS | `TitleScreens.open_achievements` (WP8.3) | none; DONE comes back to the title |

### Cost

Nothing exists before the game first shows the title (tests and tools that never do pay nothing). Hidden = `visible = false`: `TitleScreens.visible_item_count() == 0` outside MENU, tested. Buttons are ScreenButtons: emulated mouse events, never a raw touch index.

### Preview

```
tools/snap.sh src/run/run.tscn --renderer=both --state=menu --sweep=sky_t:0.2,0.42,0.72   # day, golden (the title's own sky), night
tools/snap.sh src/run/run.tscn --state=menu --attract_s=24                               # later in the attract drive
tools/snap.sh src/run/run.tscn --renderer=both --state=menu --sweep=title:hub,settings,play   # the hub, the settings view, PLAY -> countdown
tools/snap.sh src/run/run.tscn --state=menu --shot=pass --attract_s=1.5
tools/snap.sh src/run/run.tscn --renderer=both --state=menu --sweep=title:rooms,rooms_off,rooms_create,rooms_code,rooms_browser,rooms_joining,rooms_failed   # N5.2
```

### Tests

`tests/ui/test_room_hub.gd` (N5.2: rooms off without a server, every room flow through iOS-id taps, refusals, touch targets), `tests/ui/test_title_screen.gd` (every button's intent through iOS-id taps, Enter / Esc, the left-anchored layout and touch targets, the settings and account views, the profile chip following a fake session, FRIENDS / CREW from the hub into the account tabs and back, the Loop board, the text size, nothing drawn when hidden), `tests/ui/test_title_text_fit.gd` (menu with the widest name#tag, settings GAME / AUDIO, account, hub with and without a session; both text sizes, 1280x720 and a notched 1560x720), `tests/run/test_title_flow.gd` (see docs/RUN.md).


## Garage (WP8.2)

Car select, paint and rims on a turntable, and the driver level. Spec: UI → Screens ("Garage: car select, paint and rims"); Garage and progression. Progression, unlocks, the save and the turntable's rendering: [GARAGE.md](GARAGE.md).

| File | Class | Role |
| --- | --- | --- |
| `garage_screen.gd` | `GarageScreen` | the screen (a RunScreen under TitleScreens, built on the first GARAGE) |
| `garage_turntable.gd` | `GarageTurntable` | the car on its disc under the live sky (a transparent SubViewport) |
| `garage_item_button.gd` | `GarageItemButton` | a list item: an OPTION button with the unlock rule in its note, dimmed when locked, a paint chip |
| `garage_xp_bar.gd` | `GarageXpBar` | the level bar (slanted, accent; gold for a level-up on the results) |

### Layout

- **Top row:** GARAGE (display face, `font_title_px`, speed-tilted) top-left; DONE (primary) top-right; between them, right-aligned, DRIVER LEVEL n, the level bar and "36,123 / 60,629 XP" (tabular; "… XP · MAX LEVEL" at the cap).
- **Left:** the tabs CAR / PAINT / RIMS (OPTION buttons) and the tab's items in a grid, each `touch_target_px` tall: the 8 roster slots in 2 columns (the car's name; placeholders read COMING SOON), the 12 paints in 3 (the name, a colour chip at the right end that shrinks to clear the name), the 6 rims in 2. The note line: SELECTED on the selected car, the unlock rule on a locked item (LEVEL 4, REACH LEG 4, REACH THE COAST, 7-DAY DAILY STREAK · 2/7, 100 THREADS · 37/100). A locked item is dimmed. The list's width (`progression.garage_list_width_px`) grows with the text size.
- **Right:** the turntable fills the column from the tabs to the screen's edges; over its lower part, left-anchored: the car's name (display face, `garage_name_font_px`), the state line (SELECTED in the accent; LOCKED · LEVEL 4 or PREVIEW · LOCKED · LEVEL 9 in gold; IN THE WORKS · LEVEL 8, muted, for a placeholder, over an empty disc) and the stats (TOP 270 KM/H · 0-200 IN 8.8 S; mph with the units setting).
- Not mirrored for left-handed play (like the title: no thumb-side column).

### Behaviour

- **A tap on an unlocked item selects it** (the car; or the selected car's paint or rims) and saves it (end of the frame); the next run and the attract car use it. **A tap on a locked item previews it** on the turntable and names what unlocks it; nothing is selected or written. A new tab (or DONE) drops the preview.
- **Keys:** Esc and Enter = DONE; Left / Right step through the tab's items (select or preview); Up / Down change the tab (wrapping).
- **Touch:** ScreenButtons and the turntable read the mouse events Godot emulates from touches, never a raw touch index. A drag on the turntable turns the car.
- **Cost:** nothing exists before the first GARAGE; closed = `visible = false` and the turntable's viewport stops rendering. Under the title's layer, so nothing draws in gameplay (`TitleScreens.visible_item_count() == 0`).
- **Reduced motion:** fades only, and the turntable holds its idle spin.

### Preview

```
tools/snap.sh src/run/run.tscn --renderer=both --state=menu --title=garage --sweep=sky_t:0.2,0.42
tools/snap.sh src/run/run.tscn --state=menu --title=garage --tab=paint --xp=80000 --pick=teal
tools/snap.sh src/ui/screens/dev/screens_preview.tscn --screen=results --xp=30000 --text_scale=1.25   # the results' XP panel
```

### Tests

`tests/ui/test_garage.gd`, `tests/ui/test_garage_text_fit.gd`, `tests/meta/test_garage_run.gd` (see GARAGE.md → Tests).

## Achievements (WP8.3)

The achievements, their progress and what is hidden. Spec: Garage and progression ("About 25 achievements"); UI → Screens; Accessibility. The achievements themselves, the tracking, the save, the unlock toast and the platform mirror: [ACHIEVEMENTS.md](ACHIEVEMENTS.md).

| File | Class | Role |
| --- | --- | --- |
| `achievements_screen.gd` | `AchievementsScreen` | the screen (a RunScreen under TitleScreens, built on the first ACHIEVEMENTS; modal) |
| `achievements_card.gd` | `AchievementsCard` | one achievement: a ScreenPanel with its title, state line, line and bar |

### Layout

- **Top row:** ACHIEVEMENTS (display face, `font_title_px`, speed-tilted) top-left; DONE (primary) top-right; left of it, right-aligned, "8 / 25 UNLOCKED" (tabular).
- **Tabs:** DRIVING / THE ROAD / CAREER (`AchievementCatalog.groups`; OPTION buttons, `touch_target_px` tall, as wide as the widest label).
- **Grid:** the tab's achievements in `achievements.screen_columns` × `screen_rows` (3 × 3) cards across the safe width, as tall as their text needs (never past the safe area). A card: the title (display face, `card_title_px`) and, right-aligned on its line, the state (label face, tabular): UNLOCKED (gold), "17 / 25" / "287 / 300 KM/H" / "32× / 50×" (the best run or the total), LOCKED (a one-off), ??? (hidden); under it the line (body face, muted) with its numbers in the player's units; at the bottom the bar (accent; full and gold once unlocked; none for a hidden or one-off lock). Unlocked cards have a gold edge and tab. A locked hidden one reads HIDDEN / KEEP DRIVING TO REVEAL IT.
- Colour is never the only cue: every state has its word. Not mirrored for left-handed play (like the garage).

### Behaviour

- Reads the save's unlocked ids and the service's progress (a snapshot of the save and the garage when no service runs); never writes.
- **Keys:** Esc and Enter = DONE; Left / Right change the tab (wrapping). **Touch:** ScreenButtons (emulated mouse events, never a raw touch index); the cards take no touches.
- **Cost:** nothing exists before the first ACHIEVEMENTS; closed = `visible = false` under the title's layer, so nothing draws in gameplay (`TitleScreens.visible_item_count() == 0`).
- **Text size:** 100% / 125%; every title and line shows whole at both sizes on 1280×720 and a notched 1560×720 (tested).

### Preview

```
tools/snap.sh src/ui/screens/dev/achievements_preview.tscn --renderer=both --view=screen
tools/snap.sh src/ui/screens/dev/achievements_preview.tscn --view=screen --tab=2 --text_scale=1.25 --size=1560x720
tools/snap.sh src/ui/screens/dev/achievements_preview.tscn --renderer=both --view=toast   # the unlock toast in a run
```

### Tests

`tests/ui/test_achievements_screen.gd`, `tests/ui/test_achievements_text_fit.gd`, `tests/ui/test_achievements_toast.gd` (see ACHIEVEMENTS.md → Tests).
