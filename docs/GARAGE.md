# Garage and progression (WP8.2)

The garage (car select, paint and rims on a turntable), the driver level and the level and milestone unlocks. Spec: [Cars, garage, progression and art pipeline → Garage and progression](../WESTBOUND%20HANDOFF.md#garage-and-progression) ("Roster. 8 player cars at launch; 1 unlocked at start"; "Driver level. Lifetime banked score feeds a driver level. Levels unlock cars, paint colors and rims"; "Milestone unlocks. Some cars unlock from milestones instead: reach leg 4, reach the coast, a 7-day Daily Drive streak, 100 lifetime threads"; "Cosmetics. Paint colors and rims now; liveries later. The garage shows the car on a turntable with the current sky palette"), [Modular car convention](../WESTBOUND%20HANDOFF.md#modular-car-convention) (Rim: swappable mesh, scaled to the wheel radius; 800 triangles, shared), Car shader (paint is a shader parameter), UI → Screens (Title, Garage, Results), [Implementation milestones → M8](../WESTBOUND%20HANDOFF.md#implementation-milestones) ("a fresh install can progress to its first unlock"). The screen: [SCREENS.md → Garage](SCREENS.md#garage-wp82).

| File | Class | Role |
| --- | --- | --- |
| `src/meta/progression.gd` | `Progression` | Pure level math: XP for a run, XP to reach a level, the level for an XP total, progress |
| `src/meta/meta_profile.gd` | `MetaProfile` | The player's stats, unlocks and garage choices over three save sections (plain dictionaries: no nodes, no autoloads); `record_run`, unlock rules, selection rules |
| `src/meta/garage.gd` | `Garage` | The facade over the `Save` autoload: `profile()`, `award_run(results)`, `selected_car_path()`, `selected_look(car)`, `changed()` |
| `src/meta/garage_catalog.gd`, `garage_slot.gd`, `paint_option.gd` | `GarageCatalog`, `GarageSlot`, `PaintOption` | The catalog data types |
| `src/vehicle/rim_style.gd`, `car_look.gd` | `RimStyle`, `CarLook` | A rim option; a car's paint + rims |
| `src/vehicle/car_model.gd` (additive) | `CarModel.apply_rim`, `build_styled_rim_mesh` | Swaps the four Rim meshes before the draws are merged |
| `src/vehicle/player_car.gd` (additive) | `PlayerCar.setup(..., car_look)` | Applies the look before `CarVisual.bind` merges the draws |
| `src/ui/screens/garage_screen.gd` | `GarageScreen` | The garage screen (a RunScreen under TitleScreens) |
| `src/ui/screens/garage_turntable.gd` | `GarageTurntable` | The turntable: a transparent SubViewport with its own world over the live title |
| `src/ui/screens/garage_item_button.gd`, `garage_xp_bar.gd` | `GarageItemButton`, `GarageXpBar` | A list item (locked state, paint chip); the level bar (garage header, results) |
| `data/cars/garage/catalog.tres` | `GarageCatalog` | The 8 slots, 12 paints, 6 rims and their unlock rules |
| `data/tuning/progression.tres` | `ProgressionTuning` | XP, level curve, milestone thresholds, turntable and screen numbers |

## Driver level

- **XP** = the run's banked score × `xp_per_point` (1.0): the spec's "lifetime banked score". Runs in `xp_modes` (Journey, Daily Drive, Loop practice) earn it; the leaderboards' own rules (the first-run warm-up, D24) do not matter here: every run the player drove counts.
- **Level curve:** total XP to reach level L = `level_xp_base` × (L − 1)^`level_xp_exponent` = 5,000 × (L − 1)^1.8, levels 1 to `max_level` (50). Every level costs at least as much as the one before (tested).

| Level | 2 | 3 | 4 | 5 | 6 | 8 | 10 | 12 | 15 | 18 | 20 | 30 | 50 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Total XP | 5,000 | 17,411 | 36,123 | 60,629 | 90,597 | 166,015 | 260,980 | 374,522 | 578,097 | 819,932 | 1,001,674 | 2,144,304 | 5,512,174 |

- **At run end** (`Run._show_results`, when `record_best`): `Garage.award_run(results)` records the run (XP, runs, lifetime threads, the furthest leg, the coast, the Daily streak), unlocks whatever now holds, writes the save at once, and merges `xp_gained`, `xp_total`, `level_before`, `level` and `unlocked` (new unlock ids) into the `Events.run_over` payload. The results screen reads them; `NetRunPayload` leaves them out (the server refuses unknown fields).

## Unlocks

`data/cars/garage/catalog.tres` (every level and rule is data; the milestone thresholds are `ProgressionTuning.unlock_leg_milestone` / `unlock_daily_streak_days` / `unlock_lifetime_threads`):

| Slot | Car | Unlock |
| --- | --- | --- |
| 1 | Falcon GT | start (`cars_unlocked_at_start` = 1) |
| 2 | Night Viper | level 4 |
| 3 | Brute V8 | milestone: reach leg 4 |
| 4 | COMING SOON (placeholder) | level 8 |
| 5 | COMING SOON (placeholder) | milestone: reach the coast |
| 6 | COMING SOON (placeholder) | level 12 |
| 7 | COMING SOON (placeholder) | milestone: 7-day Daily Drive streak |
| 8 | COMING SOON (placeholder) | milestone: 100 lifetime threads |

- **Paints** (every car, named, never colour alone): FACTORY (the car's own `default_paint`, start), SUNSET 2, PEARL 3, TEAL 5, MIDNIGHT 6, FLAMINGO 7, CANARY 9, GRAPHITE 10, VIOLET 11, MINT 13, GOLD RUSH 15, OBSIDIAN 18.
- **Rims:** STOCK (the model's own rims, start), MESH 3, DEEP DISH 4, BLACKOUT 6, GOLD 8, TURBINE 11. Each is a flat-shaded variant of the stub rim (face disc, 5–12 spokes, an optional lip ring) in the vehicle shader's trim slot, scaled to the wheel radius, ≤ 100 triangles (budget 800). **Authored rims** (WP-ART-G, G5): a style whose `mesh_path` names an imported `assets/cars/rims/<id>.glb` (or a Mesh) uses that mesh instead, modelled at radius 1.0 facing +X and scaled to `wheel_radius × radius_frac` (`CarModel.load_rim_mesh`, `place_authored_rim`); a missing file falls back to the procedural rim. None is set yet (docs/ART_PRODUCTION.md §4.1.4, P4).
- **Rules:** the leg and coast milestones count on the journey road only (`milestone_modes`: Journey and Daily Drive; loop practice's sectors are not legs). "Reach leg 4" = `legs_completed + 1 ≥ 4`. The Daily streak grows on consecutive UTC days with a Daily Drive run, holds on the same day, restarts after a missed day; the milestone takes the best streak. Lifetime threads add up across runs in `xp_modes`.
- **Unlocks only grow:** once recorded they stay, whatever a retune does (tested).
- **Placeholders:** the final roster is a spec open question (the art pipeline makes the cars). Slots 4–8 show as COMING SOON with their rule; their unlock is recorded when the rule holds, but they can never be selected or driven ("IN THE WORKS · LEVEL 8" on the turntable, an empty disc). A new car = a `data/cars/<id>.tres`, its path in `Run.CAR_PATHS` (the replay verifier builds runs from it) and in its slot's `car_path`, with the slot id = the CarDef id (tested).
- **When a COMING SOON slot gets its car** (WP-ART-G, G7): its id changes from `slot_N` to the CarDef id, and the old id goes in the slot's `former_ids` (`GarageSlot`, e.g. `former_ids = PackedStringArray("slot_4")`). `Garage.profile()` then moves what the save recorded under the old id on every load (`SaveMigrations.rename_car_ids`, from `GarageCatalog.car_id_renames()`): the unlock `car/slot_4` → `car/<id>` (keeping the earlier run count if both exist), the selected car and the look. No save version bump: the renames are data and the move is a no-op once done. Tests: `tests/art/test_art_pipeline.gd` (`test_car_id_renames_*`, `test_roster_catalog_renames_are_consistent`).

### Numbers: the first unlock (M8 gate)

The first level-up (level 2, 5,000 XP) unlocks SUNSET paint. `tests/meta/test_first_unlock.gd` plays fresh installs through the real path (the Run with a weaving, boosting bot at 187 km/h in real traffic, the real scoring and banking, a two-hit crash, the results, `Garage.award_run` into the save). Banking is lumpy: the chain banks at the first checkpoint, about 70 s in, so a 90 s beginner run that reaches it earns about 5,000–7,700 XP and one that does not about 100–170. Soak result (2026-09-30), three fresh installs, 90 s runs: first unlock after **1, 2 and 3 runs** (gate: ≤ 3). **WP9.6 (PL-4):** after N8.2's traces install 1 unlocks on **run 4** (runs 1–3 bank 24, 143 and 76 XP: none reaches the first checkpoint's bank) and installs 0 and 2 on run 1. XP stays as it is (orchestrator); the gate is now **≤ 4 runs** and D27's text proposal reads "first unlock after 1–4 runs". The bot's 5-minute runs earn 10,000–21,000 XP (level 2–3); a skilled run of about 2,000,000 points jumps to level 20+.

## Save

Three sections (`Save.section`), all JSON objects; no new save version (the sections are additive and `normalize` keeps unknown top-level sections):

```json
"stats":   { "xp": 36123, "runs": 9, "threads": 14, "best_leg": 4, "coast": false,
             "daily_streak": 2, "daily_best_streak": 3, "daily_last_day": 20361, "backfilled": true },
"unlocks": { "car/falcon_gt": 0, "paint/factory": 0, "rim/stock": 0, "paint/sunset": 2, "car/night_viper": 9 },
"garage":  { "car": "night_viper", "looks": { "night_viper": { "paint": "teal", "rim": "mesh" } } }
```

- `unlocks` maps an unlock id (`car/<slot>`, `paint/<id>`, `rim/<id>`) to the run count it unlocked on.
- `garage.looks` keeps each car's own paint and rims. A saved choice that is not unlocked (a hand-edited or damaged save, a retune) falls back to the start car / FACTORY / STOCK; a damaged number reads as 0.
- **Backfill** (once per save, `stats.backfilled`): a save from before WP8.2 has personal bests but no lifetime XP; its XP starts at the sum of its bests (a lower bound of what it banked) and a recorded journey counts as the coast (and leg 4).
- Written at once with the run's award; a selection is saved at the end of the frame (`Garage.changed` → `Save.request_save`).

## Selection and the run

- **The title's flow drives the garage's car:** `Run.enter_menu` (the attract drive) and `Run.start_mode` (PLAY, DAILY DRIVE, LOOP PRACTICE; RETRY keeps it) set `car_index` to the selected slot's `Run.CAR_PATHS` entry and `car_look` to its paint and rims. The leaderboards' `car` field is the driven CarDef's id, as before; the replay verifier finds it in `Run.CAR_PATHS`.
- **The garage closing** on the title (`TitleScreens.garage_closed` → `Run.refresh_menu_car`) swaps the attract car in place (same spot, the bot takes the new car); nothing rebuilds when nothing changed.
- **Overrides:** `?car=` / `--car=` (a `CAR_PATHS` index or a car id; the factory look) wins over the garage, on the title and on a direct boot. Direct boots (`?title=0`, `?mode=`), tests and tools keep `car_index` (and `car_look`, null = factory).
- **Visual only:** paint and rims never reach physics or the trace (`tests/meta/test_garage_run.gd`: identical trace hashes with any look). The model is rebuilt only when the car or its look changes.

## Turntable

- A `SubViewport` with its own `World3D`, `transparent_bg`, no environment and no light nodes: a `Camera3D`, the disc and the car. The title's live attract drive shows through it under the garage's dim.
- **The live sky palette:** the car's vehicle shader (and the disc, drawn in its trim slot) reads the `wb_*` shader globals the title's SkyRig writes at its held `camera.attract_sky_t` (docs/CONTRACTS.md §13), so the car wears the same light, sheen and sky fresnel it has on the road at that hour; no separate lighting setup. The blob shadow is the run's (shared mesh and shader).
- **Same shaders as the run:** CarModel with the look applied and its draws merged (`merge_draw_surfaces`), identical on both renderers (snaps below).
- **Cost:** it renders only while the garage is open (`UPDATE_ALWAYS`, else `UPDATE_DISABLED`), at the canvas's physical resolution capped at `turntable_max_pixel_scale` (2×). A paint change recolours in place; a rim or car change rebuilds the model once.
- **Motion:** spins at `turntable_spin_deg_s` (14°/s) from `turntable_start_yaw_deg` (front three-quarter); a drag turns it (`turntable_drag_deg_per_px`); reduced motion holds the idle spin.

## Tests

| File | Covers |
| --- | --- |
| `tests/meta/test_progression.gd` | XP = banked score (modes, never negative, the scale), the level curve (thresholds, monotonic steps, cap), progress; the catalog: 8 slots, 1 at start, each spec milestone once, levels unlock cars too, every real car in `Run.CAR_PATHS` with its id, paints and rims (one FACTORY, one STOCK, names, rim triangle budget), item names, placeholders marked |
| `tests/meta/test_meta_profile.gd` | a fresh profile; a run's XP and the level-up with its unlocks; every level item at its level; leg and coast milestones (loop legs don't count); lifetime threads; the Daily streak (same day, missed day); locked items can't be selected; placeholders never drive; per-car looks; fallbacks for bad saved choices; unlocks never revoked; backfill; JSON round trip |
| `tests/meta/test_garage_save.gd` | award + selection through a JSON reload and `SaveMigrations.migrate` (no new version); a v1 save backfilled once; unknown keys kept; other modes leave the save alone |
| `tests/meta/test_car_look.gd` | every rim style on every car (swapped, shared, scaled, within budget, the merged draw budget kept), rims before the merge only, `CarLook` equality, PlayerCar wears the look |
| `tests/meta/test_garage_run.gd` | the selection drives the title's attract car, PLAY, RETRY and the payload's car id; the garage on the title swaps the attract car (no rebuild without a change); the results' GARAGE; direct boots keep `car_index`; `?car=` index / id; the look never changes the trace |
| `tests/meta/test_first_unlock.gd` | fast: a real run's XP is its banked score, in the payload and the save; the first level-up unlocks something. Soak (the M8 gate): three fresh installs reach their first unlock within 4 beginner runs (WP9.6; was 3) |
| `tests/ui/test_garage.gd` | GARAGE / DONE (iOS-id taps), tabs, placeholders marked, an unlocked tap selects and saves, a locked tap previews and never selects (nothing written), keys, the turntable (on only while open, spin, drag, reduced motion, rebuilds), project shaders only (no lights, environment or StandardMaterial3D) |
| `tests/ui/test_garage_text_fit.gd` | the garage (every tab, previews, level 1 and max) and the results' XP panel (level-up with every unlock, one unlock, none, max level; both hands) at 100 / 125 % on 1280×720 and a notched 1560×720; the paint chip never covers its name |

## Preview

```
tools/snap.sh src/run/run.tscn --renderer=both --state=menu --title=garage --sweep=sky_t:0.2,0.42   # day, golden (the title's sky)
tools/snap.sh src/run/run.tscn --state=menu --title=garage --tab=paint --xp=80000 --pick=teal        # --tab=car|paint|rims, --pick=<id>: select or preview
tools/snap.sh src/run/run.tscn --state=menu --title=garage --pick=slot_7                             # a placeholder
tools/snap.sh src/ui/screens/dev/screens_preview.tscn --renderer=both --screen=results --xp=30000    # the results' XP panel (a level-up)
```

## Open

- **The roster** (spec open question): 3 real cars, 5 marked placeholders; slot rules are data, so the art pipeline's cars drop in.
- **Daily streak:** counted here from the Daily Drive runs' UTC day (meta only). WP8.4 owns the Daily Drive (`daily` section); if it keeps its own streak, the milestone can read that instead.
- **Achievements** (WP8.3) can read `stats` (`threads`, `best_leg`, `coast`, `runs`) rather than keep their own counters.
