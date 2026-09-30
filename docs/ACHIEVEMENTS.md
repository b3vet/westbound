# Achievements and the platform services (WP8.3)

25 achievements, tracked from the `Events` bus and the run's results, saved locally, shown in an unlock toast and on their own screen, and mirrored to Game Center / Google Play Games when their plugin is in the build. Spec: [Garage and progression](../WESTBOUND%20HANDOFF.md#garage-and-progression) ("Achievements. About 25 achievements, mirrored to Game Center and Google Play Games (for example: first thread, 50× multiplier, a clean journey, a full night survived, 300 km/h)"), [Architecture → Platform services](../WESTBOUND%20HANDOFF.md) ("a thin `platform/leaderboards.gd` wrapper that no-ops on web"), [Leaderboards](../WESTBOUND%20HANDOFF.md#leaderboards), multiplayer handoff → Migration from Game Center / Play Games ("Their leaderboards are retired; achievements stay on the platform services"), Save data. The screen: [SCREENS.md → Achievements](SCREENS.md#achievements-wp83).

| File | Class | Role |
| --- | --- | --- |
| `src/meta/achievements/achievement_def.gd` | `AchievementDef` | One achievement: id, title, line, tab, metric, threshold, unit, hidden, platform ids |
| `src/meta/achievements/achievement_catalog.gd` | `AchievementCatalog` | The list, the tabs, the hairline clearance, the platform mirror switches and board ids |
| `src/meta/achievements/achievement_tuning.gd` | `AchievementTuning` | Toast and screen numbers; the catalog's path |
| `src/meta/achievements/achievement_tracker.gd` | `AchievementTracker` | Pure: the metrics, the thresholds, unlock-once (`pending`); allocation-free event handlers |
| `src/meta/achievements/achievement_text.gd` | `AchievementText` | The line with its numbers in the player's units; the state / progress line |
| `src/platform/achievements.gd` | `AchievementService` | The service (requested autoload `Achievements`): listens, records, toasts, ticks, mirrors |
| `src/platform/leaderboards.gd` | `PlatformLeaderboards` | Game Center / Play Games through their plugins, found at run time; a no-op elsewhere |
| `src/ui/hud/hud_achievement_layer.gd`, `widgets/hud_achievement_toast.gd` | `HudAchievementLayer`, `HudAchievementToast` | The unlock toast and where it goes |
| `src/ui/screens/achievements_screen.gd`, `achievements_card.gd` | `AchievementsScreen`, `AchievementsCard` | The screen (from the title's ACHIEVEMENTS) and its cards |
| `data/achievements/catalog.tres`, `tuning.tres` | | The data |

## The achievements

Thresholds are data (`data/achievements/catalog.tres`); `{n}` in a line is the threshold in the player's units. Hidden ones read HIDDEN / KEEP DRIVING TO REVEAL IT. until unlocked.

| Tab | Id | Title | Line | Metric ≥ threshold |
| --- | --- | --- | --- | --- |
| DRIVING | `first_thread` | NEEDLE | THREAD YOUR FIRST GAP. | `threads_total` ≥ 1 (spec: "first thread") |
| | `threads_run` | TEN IN ONE | 10 THREADS IN ONE RUN. | `threads_run` ≥ 10 |
| | `threads_total` | THREAD COUNT | 100 THREADS IN TOTAL. | `threads_total` ≥ 100 |
| | `close_passes_run` | CLOSE CALLS | 25 CLOSE PASSES IN ONE RUN. | `close_passes_run` ≥ 25 |
| | `hairline` (hidden) | HAIRLINE | A CLOSE PASS UNDER 25 CM. | `hairline_run` ≥ 1 (a close pass at ≤ `hairline_clearance_m` 0.25 m) |
| | `multiplier_50` | FIFTY TIMES | REACH A 50× MULTIPLIER. | `multiplier_run` ≥ 50 (spec: "50× multiplier") |
| | `multiplier_100` (hidden) | TRIPLE DIGITS | REACH A 100× MULTIPLIER. | `multiplier_run` ≥ 100 |
| | `top_speed_300` | 300 CLUB | REACH 300 KM/H. (186 MPH) | `top_speed_run` ≥ 300 km/h (spec: "300 km/h"; Night Viper 285 km/h + 8 % boost) |
| THE ROAD | `first_leg` | FIRST LEG | CROSS YOUR FIRST CHECKPOINT. | `leg_run` ≥ 2 (no "1 / 2" shown: `show_progress` off) |
| | `halfway` | HALFWAY WEST | REACH LEG 4 IN ONE RUN. | `leg_run` ≥ 4 |
| | `coast` | THE COAST | REACH THE COAST. | `coast_run` ≥ 1 |
| | `clean_journey` | CLEAN JOURNEY | THE COAST WITHOUT A HIT. | `clean_coast_run` ≥ 1 (spec: "a clean journey") |
| | `clean_legs` | SPOTLESS | 3 CLEAN LEGS IN ONE RUN. | `clean_legs_run` ≥ 3 |
| | `heat` | FEEL THE HEAT | EARN A HEAT LEG BONUS. | `heat_legs_run` ≥ 1 |
| | `night_survived` | NIGHT OWL | DRIVE A FULL NIGHT TO DAWN. | `nights_run` ≥ 1 (spec: "a full night survived") |
| | `night_thread` (hidden) | NIGHT THREAD | THREAD A GAP AT NIGHT. | `night_threads_run` ≥ 1 |
| | `hazards` | OBSTACLE COURSE | 10 HAZARDS WITHOUT A HIT. | `set_pieces_total` ≥ 10 |
| CAREER | `big_bank` | BIG BANK | BANK A 50,000 CHAIN. | `chain_run` ≥ 50,000 |
| | `half_million` | HALF A MILLION | SCORE 500,000 IN ONE RUN. | `score_run` ≥ 500,000 |
| | `objectives` | ON TASK | COMPLETE 10 LEG OBJECTIVES. | `objectives_total` ≥ 10 |
| | `level_10` | VETERAN | REACH DRIVER LEVEL 10. | `level` ≥ 10 |
| | `new_wheels` | NEW WHEELS | UNLOCK A SECOND CAR. | `cars` ≥ 2 (real cars only, not COMING SOON slots) |
| | `daily_driver` | DAILY DRIVER | FINISH A DAILY DRIVE. | `daily_runs_total` ≥ 1 |
| | `daily_streak` | EVERY DAY | 7-DAY DAILY DRIVE STREAK. | `daily_streak` ≥ 7 |
| | `in_the_loop` | IN THE LOOP | FINISH A LOOP PRACTICE RUN. | `loop_runs_total` ≥ 1 (the online side) |

The count is `ProgressionTuning.achievement_count` (25, the spec's "about 25"; tested). A tab holds at most `screen_columns × screen_rows` (9).

## Metrics

`AchievementTracker.METRIC_IDS`, in three scopes:

- **RUN** — one run's value; the saved value is the best run. `threads_run`, `close_passes_run`, `hairline_run`, `night_threads_run` (Events.scored), `multiplier_run` (scored's multiplier and multiplier_changed), `chain_run` (the largest chain_banked amount), `score_run` (the banked total from chain_banked / bonus_awarded, and the results' score), `top_speed_run` (the results' `top_speed_kmh`, in m/s: the bus has no speed event, so it counts at the run's end), `leg_run` (1 at the start, +1 per checkpoint_crossed, and the results' legs + 1), `coast_run` / `clean_coast_run` (coast_reached; clean = no hit since the run started), `clean_legs_run` / `heat_legs_run` (the crossing summary's `clean` / `heat`), `nights_run` (night_started, then dawn_started in the same run).
- **TOTAL** — adds up over finished runs, live during one. `threads_total` (thread events in the garage's XP modes; also never below the garage's lifetime `stats.threads`), `set_pieces_total` (set_piece_ended with no hit since its start; overlapping pieces share one hit flag), `objectives_total` (objective_completed), `daily_runs_total` / `loop_runs_total` (a run_over in that mode).
- **PROFILE** — the garage's numbers (`Garage.profile()`): `level`, `cars` (real cars unlocked), `daily_streak` (the best streak). Read at start, at each run's start and after the run's award (`Garage.award_run` runs before `Events.run_over`).

**Modes.** Every run counts for the run records. The leg and coast metrics count on the journey road only (`ProgressionTuning.milestone_modes`: Journey, Daily Drive; loop practice's sectors are not legs); lifetime threads only in `xp_modes`, like the garage's.

**A run's life.** `run_started` begins it (and re-reads the save); `run_over` ends it (the results, then the saved values); a move to MENU without results (QUIT) drops its values, but what it unlocked stays. Events outside a run count for nothing (the title's attract drive never scores anyway).

**Once.** An achievement is marked the moment its metric reaches its threshold and queued once; the service records it with the UTC day and never again. Unlocks are never revoked, whatever a retune does.

**Quiet unlocks.** At start (and at every run start or save load) whatever the save already earned — lifetime threads, driver level, cars, Daily streak from a save older than WP8.3 — is recorded without a toast or tick, and mirrored.

**Cost.** The handlers run in the run's drain every frame (multiplier_changed fires most frames): packed arrays sized at init, a list of achievement indices per metric, no allocation per event (tested: object count and static memory flat over 2,000 bursts). Unlocks allocate (the save, the toast): at most 25 times.

## Save

Section `achievements` (additive: no new save version; `normalize` keeps unknown sections, tested through `SaveMigrations.migrate`):

```json
"achievements": {
	"unlocked": { "first_thread": 20361, "halfway": 20361 },
	"progress": { "threads_run": 14.0, "close_passes_run": 17.0, "top_speed_run": 80.2, "threads_total": 64.0, "...": 0.0 },
	"mirrored": { "first_thread": true }
}
```

- `unlocked`: id → the UTC day it unlocked. `progress`: metric → the best run (RUN), the total (TOTAL) or the last profile value (PROFILE), in tracker units (m/s for speed). `mirrored`: ids the platform has taken.
- Written with the run's end (`Save.request_save`, which waits while RUNNING, so an unlock mid-run never touches the disk during gameplay) and with each unlock.
- A damaged section (not a dictionary, bad numbers) reads as empty or 0.

## Service

`AchievementService` (`src/platform/achievements.gd`, class name; requested autoload name `Achievements`).

- **Until the autoload exists** `TitleScreens._ready` calls `AchievementService.ensure(self)`: the run always builds its title, so the game has exactly one service (a child of TitleScreens). With the autoload, `ensure` finds it (`AchievementService.current`).
- **Tests and tools:** under a `--script` main loop none is made and an autoload stays dormant (like the first run: `Save` is in memory there), so other suites never see unlocks, toasts or pulses. A test sets `run_under_tools` on its own instance, or `AchievementService.attach_under_tools` for the run's path.
- **Listener only:** it never emits a gameplay signal (tested). Its own signal: `unlocked(id)`, after the unlock is recorded.

## Toast

`HudAchievementLayer` (a canvas layer, `toast_layer` 70: over the HUD and the run's screens (60), under the dev HUD (100)) with one `HudAchievementToast`, the leg toast's style: faceted panel, gold edge, accent tab, ACHIEVEMENT UNLOCKED (label face, accent) over the title (display face, gold).

- **When:** in the frame of the unlock (inside the emit; tested), for `toast_s` (3.2 s) of real time: fade in `toast_in_s`, out `toast_out_s`; slow motion does not stretch it. Several unlocks in one frame queue (up to `toast_queue_max`, 4; the save has them all). One light haptic tick (`Haptics` PASS pattern) per batch; the haptics setting off sends none. A tick during a stronger pulse (a thread's thump) is dropped by Haptics' priority rule.
- **Where:** top-right, under the lives and the HUD buttons (and the objective chip when it sits right), between the top-centre readouts (the middle third, the chain row and the event stack, which is wider than the middle third at 125 %) and the safe edge, `toast_size_px` (340 × 74) × the text size. It never enters the thumb zones or the pedals (plan D14); if it would (very short canvases), it goes under the score on the left. From the live Hud's layout, or one built from the settings. Tested for both canvases, text sizes, hands, throttle modes and controls sizes.
- **The finale:** while the HUD's JOURNEY COMPLETE banner is up, the toast waits hidden and resumes after.
- It shows over the results and the title too (unlocks at the run's end), and takes no touches.
- **Cost:** idle it is hidden (no canvas item draws) and does not process; one plate and two fonts (three draw calls) while it shows, drawn once per unlock.

## Screen

See [SCREENS.md → Achievements](SCREENS.md#achievements-wp83).

## Platforms

`PlatformLeaderboards.detect()`: Game Center on iOS when the `GameCenter` singleton is in the build (godot-ios-plugins: `authenticate()`, `is_authenticated()`, `award_achievement({name, progress: 100, show_completion_banner})`, `post_score({score, category})`), Play Games on Android when `GodotPlayGameServices` (godot-play-game-services: `unlockAchievement(id)`, `submitScore(id, score)`) or the older `GodotPlayGamesServices` (`submitLeaderBoardScore`) is; else none (web, desktop, headless, a build without the plugin). A missing plugin or method returns false and never errors. The calls are fire and forget.

- **Achievements** are mirrored on unlock and retried (`mirror_pending`) at start and each run's start and end until the platform reports a signed-in player; each is sent once (`mirrored`).
- **Ids** are placeholders in the catalog (`game_center_id` = `westbound.achievement.<id>`, `play_games_id` = `PLACEHOLDER_<ID>`) until the App Store Connect and Play Console entries exist (owner).
- **Boards (optional mirror, off):** the spec's boards (Journey all-time and weekly, Daily Drive, distance) live on our server (N7: `src/net/boards_client.gd`, the leaderboards screen), and the multiplayer handoff retires the platform boards. `platform/leaderboards.gd` can still mirror them: `catalog.mirror_boards` on submits the Journey score and distance or the Daily score after a run the leaderboards would take (not a warm-up run, D24; loop practice has none). Weekly is the platform's own time scope. Proposed deviation row below.
- **Plugins:** not in the export yet (no device here); adding them is WP9.4's store-build work.

### Proposed deviation (for the plan's §2)

| # | Spec | Now | Why |
| --- | --- | --- | --- |
| D29 | Leaderboards via Game Center and Google Play Games (`platform/leaderboards.gd`; boards Journey all-time and weekly, Daily, distance) | The boards are our server's (N7), shown in-game; `platform/leaderboards.gd` is a thin optional mirror to the platform boards, **off by default** (`data/achievements/catalog.tres` `mirror_boards`). Achievements stay on the platforms (mirrored on unlock). The 25 achievements are designed from the spec's examples and systems (the spec lists five) | Multiplayer handoff → Migration: "Their leaderboards are retired; achievements stay on the platform services" |

## Tests

| File | Covers |
| --- | --- |
| `tests/meta/test_achievement_catalog.gd` | 25 (the tuning's count); the spec's five examples; ids, metrics, tabs, upper-case text with every placeholder filled (km/h and mph), unique platform ids; tabs fit the grid; a few hidden; units in lines and state lines; board ids, the boards mirror off |
| `tests/meta/test_achievement_tracker.gd` | metric tables; best run vs totals; totals only in XP modes; leg 1 at the start; profile numbers; unlock once through `pending`; progress round trip through JSON; no allocations in the handlers |
| `tests/meta/test_achievement_triggers.gd` | table-driven: every achievement through the real `Events` bus and run results, locked one step before and unlocked by its step, announced once; a hit spoils the clean journey; loop sectors are not legs; nothing outside a run; QUIT drops the counts; hazards need no hit; totals across runs; unlock once over three runs; the save's round trip (JSON, a migration, a reload: nothing unlocks again); a damaged section; an older save's quiet unlocks; listener only |
| `tests/meta/test_achievement_platform.gd` | no platform: a quiet no-op, achievements local; Game Center's and Play Games' (both plugins') calls and ids; a plugin without the methods; mirrored once; mirrored after a later sign-in; boards mirror off by default, on: Journey, distance, Daily, never a warm-up run or loop practice |
| `tests/meta/test_achievement_run.gd` | the real run: one service from its title, none under the runner unless asked; a thread in the drain unlocks and toasts in that frame, clear of the live HUD; a real run end (two hits, the crash, the results) records the run's progress; QUIT drops it; the screen over the attract drive reads the service |
| `tests/ui/test_achievements_toast.gd` | in the frame of the unlock; one haptic tick (none with haptics off); fades, queues, hides, then draws nothing and stops processing; real time under slow motion; a burst capped; placement clear of the thumbs, the middle third and every HUD readout in 48 layouts; every title fits (probe) |
| `tests/ui/test_achievements_screen.gd` | ACHIEVEMENTS in the title's row; opens (iOS-style touch id), DONE / Esc / Enter back; tabs by tap and keys; card states (unlocked, progress, one-off, hidden, hidden unlocked); mph; the garage's numbers; read only; nothing drawn after |
| `tests/ui/test_achievements_text_fit.gd` | every tab, locked / widest progress / unlocked, km/h and mph, 100 / 125 % on 1280×720 and a notched 1560×720: texts in their boxes, cards whole and apart, buttons touch targets; the title's four-button row fits |

## Preview

```
tools/snap.sh src/ui/screens/dev/achievements_preview.tscn --renderer=both --view=screen             # DRIVING, a mixed save
tools/snap.sh src/ui/screens/dev/achievements_preview.tscn --view=screen --tab=1 --text_scale=1.25 --size=1560x720
tools/snap.sh src/ui/screens/dev/achievements_preview.tscn --renderer=both --view=toast --id=top_speed_300
```

## Open

- **Autoload:** `Achievements="*res://src/platform/achievements.gd"` (orchestrator); until then the title hosts it.
- **Platform ids and plugins:** placeholders; the owner creates the entries; the plugins go into the store builds (WP9.4).
- **Daily Drive (WP8.4):** `daily_driver` and `daily_streak` read the run's mode and the garage's streak; if WP8.4 keeps its own streak, the profile value can read that.
- **Live top speed:** 300 CLUB unlocks at the run's end (the bus carries no speed); a `top_speed` event would let it pop mid-run.
