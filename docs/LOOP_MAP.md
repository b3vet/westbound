# The loop map (N3.1)

Spec: [WESTBOUND_MULTIPLAYER_HANDOFF.md](../WESTBOUND_MULTIPLAYER_HANDOFF.md) → The loop map, Time of day in multiplayer, Rules for the server code 5. Plan: [MULTIPLAYER_PLAN.md](MULTIPLAYER_PLAN.md) MP-D3, N3.1. Protocol: [PROTOCOL.md](PROTOCOL.md) (`map_hash`). Contracts: [CONTRACTS.md](CONTRACTS.md) §2–§3.

`loop_v1` is a fixed, closed, one-way highway loop of exactly 25 km, generated from a seed plus a short list of hand edits, and frozen as data:

| File | What | Who reads it |
| --- | --- | --- |
| `data/maps/loop_v1.tres` | `LoopMapDef`: seed, section templates, feature rules, edits. The client scene data: everything regenerates from it. | client (`LoopRoadPath.load_default()`), the editor |
| `data/maps/loop_v1.json` | The road-space file (canonical JSON) | client (hash in `Hello`) |
| `westbound-server/data/maps/loop_v1.json` | The same bytes, for the server (its Docker build context is `westbound-server/`) | server (N3.2) |
| `*/loop_v1.sha256` | Sidecar: `<sha256>  loop_v1.json` (`sha256sum -c` format) | CI, the owner (Coolify) |

**Map hash (`loop_v1`):** `26a4e08b8e456ec56471c7d0626ab4ed760ba7579add6e4c279e9b3faa0dd296`. It is the SHA-256 of every byte of `loop_v1.json`. Since N3.2 the server compiles its copy in and accepts that hash on its own (see [Server map loading](#server-map-loading)); `WB_GATEWAY__MAP_HASHES` ([SERVER.md](SERVER.md) → Map hashes) is only an explicit override. The hash changes with any edit, seed or generator change: re-export, commit both copies and rebuild the server (and, with an override set, update it; list the old hash too while old clients are out).

## Code

| Path | Class | Role |
| --- | --- | --- |
| `src/road/loop/loop_map_def.gd`, `loop_section_def.gd` | `LoopMapDef`, `LoopSectionDef` | Design data (resources) |
| `src/road/loop/loop_gen.gd` | `LoopGen` | Pure generator: def + `Tuning` → `LoopLayout` |
| `src/road/loop/loop_layout.gd` | `LoopLayout` | Generated data: closed table, elements, every feature, the editor's parameter list |
| `src/road/loop/loop_road_path.gd` | `LoopRoadPath` | The `RoadPath` (pure, `# lint: sim`) |
| `src/road/loop/loop_validator.gd` | `LoopValidator` | The rules below, as error strings |
| `src/road/loop/loop_export.gd` | `LoopExport` | Canonical JSON, SHA-256, writing and checking both copies |
| `src/road/loop/dev/loop_editor.tscn` | (`loop_editor.gd`, `LoopPlot`) | The editor tool, also headless (`--export`, `--check`) |
| `src/road/loop/dev/loop_preview.tscn` | | The world stack on the loop at a named place (snaps) |
| `src/road/loop/dev/loop_traffic_preview.tscn` | | The traffic sandbox on the loop (snaps; the editor's PREVIEW TRAFFIC) |
| `src/road/road_gen/road_plan_gen.gd`, `road_profile_gen.gd` | | Additive hooks: `begin_alignment`, `add_straight`, `add_bend`, `bend_length`; `begin_profile`, `add_element`. The procedural output is unchanged. |
| `src/traffic/dev/traffic_sandbox.gd` | | Road injection hook: `road_override`, `biome_plan_override`, `start_s` (set before `_ready`) |
| `src/run/run_loop.gd` | `RunLoop` | N3.2: the loop test mode (road, periodic plan, elevated zone, sections' traffic, room clock, HUD feed) |
| `src/run/room_clock.gd` | `RoomClock` | N3.2: the room clock (pure, `# lint: sim`) |
| `src/core/tuning/loop_tuning.gd`, `data/tuning/loop.tres` | `LoopTuning` | N3.2: clock, density, director leg, excluded set pieces |
| `src/net/map_info.gd` | `MapInfo` | N3.2: the client's map hash for `Hello` |
| `src/ui/hud/hud_loop_feed.gd` | `HudLoopFeed` | N3.2: the HUD's clock and sector values |
| `westbound-server/crates/sim/src/map.rs`, `crates/server/src/map.rs` | `LoopMap`, `ServerMap` | N3.2: the server's map (parse, validate, wrap math; compile-in and hash) |

## The design

A rounded pentagon driven counterclockwise (left turns; seen from above with north up). Each section is one pentagon side of 5,000 m ending in a 72° corner, so the lengths and headings nearly close by symmetry. The closure step removes what is left. Headings are world headings, right-positive, with 0 = due west (the sun's azimuth).

| # | Section | s (m) | Lanes | Heading | Character |
| --- | --- | --- | --- | --- | --- |
| 0 | desert | 0–5,000 | 4 (3→4 at 320; 4→3 at 4,450) | 122° (NNE), then the corner to 50° | Start/finish toll gantry at s = 0. A 2.5 km straight, one R ≈ 1,470 m corner. Flat (±1.5 %). |
| 1 | canyon | 5,000–10,000 | 3, 2 in tunnel 0 | 50°, S-bends ±20° at R ≈ 1,300 m, corner to −22° | Cliffs. Tunnel 0 (6,417–6,829, 2 lanes, taper 6,067–6,267, lanes back 6,909–7,109). Tunnel 1 (9,266–9,746, 3 lanes). Two blind crests. Sector 2 gantry is a tunnel portal. Crosses due west inside the corner bend. |
| 2 | coast | 10,000–15,000 | 3 | −22° (sun 15–30° off the axis, on the sea's side), ±6° sweepers, corner to −94° | The sea on the right. The suspension bridge (sector 3) at 12,500 with its backstays at 12,230–12,770. One crest. The best sunset view. |
| 3 | city | 15,000–20,000 | 4 (3→4 at 15,320) | −94° (S), ±8° sweepers, corner to −166° | Elevated zone 15,700–19,300. Ramp pair 0: off-ramp 15,970 (250 m), on-ramp 16,920 (300 m). Densest, slowest flow speeds. |
| 4 | farmland | 20,000–25,000 | 3 (4→3 at 20,320) | −166°, ±14° long sweepers at R ≈ 2,800 m, the closing corner to −238° (= 122°) | Ramp pair 1: off-ramp 21,090, on-ramp 22,040. One crest. |

- **Sector gantries** (6, every L/6 = 4,166.7 m): 0 at 0 (toll gantry, start/finish), 1 at 4,167 (sign gantry), 2 at 8,333 (tunnel portal), 3 at 12,500 (suspension bridge), 4 at 16,667 and 5 at 20,833 (sign gantries). Warning signs stand 1 km and 500 m before each gantry.
- **Road works:** one toggleable zone per section (80 m taper, 300 m closed, 80 m taper, one lane from the right, off by default): 640, 5,200, 11,400, 17,560 and 24,030.
- **Spawn points:** every lane, 150 m past each sector gantry.
- **Flow speeds** (km/h, lane from the right): desert 100/135/170/185, canyon 90/120/150/165, coast 95/125/155/170, city 85/110/135/150, farmland 95/130/165/180.
- **Profile:** periodic PVIs every 550–1,600 m (by section), elevation between about −26 m and +54 m, grades ≤ 4.6 %, four blind crests (two in the canyon).
- **Lane counts** follow the handoff (4 in the desert and city, 2 in one canyon tunnel, 3 elsewhere) rather than the biome files (desert 3, coast 4 in single-player).

## Generation (`LoopGen`)

The generator uses the procedural road's own primitives, not a second road math:

- **Plan:** `RoadPlanGen` lays the elements (straights, then clothoid, arc and clothoid bends) through `begin_alignment`/`add_straight`/`add_bend`, and emits `BEND`, `BLIND_BEND` and sharp-bend `SIGN` features with the per-biome sight clearance (a `BiomeRoadRules` over the sections). Each section is straight, bend, …, bend, straight. A bend's deflection comes from the data and its radius and transition are drawn from the data's ranges. The straights share the rest of the section by weights (jittered ±20 %). The last straight of a section is the remainder, so every section is exactly 5,000 m.
- **Profile:** `RoadProfileGen` lays the grade tangents and parabolic vertical curves through `begin_profile`/`add_element`, and `is_blind_crest`/`crest_sight_distance` flag the crests from the geometry. PVIs are seeded per section. Crests (+g then −g over a 3,000–6,000 m vertical curve) go on PVIs away from tunnels. The mean grade is removed so the lap closes. Each vertical curve takes at most 90 % of its neighbouring tangents.
- **Table:** the same dense table as `ProceduralRoadPath` (2 m cells; Hermite heading with curvature slopes, Hermite elevation with grade slopes, positions integrated along the mid-cell heading). `sample_into` uses the same rule, so its cost is the same: about 1.6 µs against 1.5 µs (`test_sample_into_cost_like_the_procedural_road`). A whole generation takes about 100 ms.
- **Features:** tunnels come from per-tunnel windows. Lane changes are the section counts (at `lane_change_offset_m` from the section start, tapered over `biome_lane_taper_m`) plus the narrowed tunnel's drop and restore (`ProceduralRoadPath`'s rule: the taper ends `tunnel_lane_lead_m` before the portal, and the lanes come back `tunnel_lane_trail_m` after the exit). A lane-ends sign stands 400 m before every drop. Ramps and road works are searched along their windows from a seeded start: ramps need straight-ish road (radius ≥ 2,000 m), and both stay clear of gantries, tunnels, the bridge, lane tapers and blind crests (approach and far side). Every feature position is a whole number of millimetres.
- **Determinism:** streams derived from `map_seed` (`loop/plan`, `loop/profile`, `loop/features/…`). Every value is drawn in a fixed order and an edit replaces the drawn value afterwards, so an edit never shifts another value (`test_an_edit_changes_only_its_value`).

### Closure

- **Heading:** the last bend's deflection is −2π minus every other bend's, so the elements turn exactly one lap (`total_turn = -TAU`).
- **Position:** two sections (`closure_sections` = canyon and farmland) move a length *d* from their last straight to their first, and their lengths stay exact. The end point then moves by *d*·(u(h_first) − u(h_last)), with u(h) = (sin h, −cos h), a linear map with a known Jacobian. Newton on the integrated table converges in 2 steps to 5·10⁻¹² m That last rounding is spread over the lap, so table entry N equals entry 0 exactly.
- **Profile:** the PVIs are periodic (the last tangent runs into PVI 0 at s = 0), so elevation and grade close by construction (1.3·10⁻¹³ m).
- **Seam:** s = 0 lies on the desert's first straight: curvature 0 on both sides (C2 plan), grade continuous (C1 profile), the start/finish line.

## LoopRoadPath

- It answers every `RoadPath` query for any s, taken modulo L. Positions, elevation, lanes, the cross-section and features repeat every lap. The heading is continuous: heading(s + L) = heading(s) − 2π, so heading differences along the road never jump. `heading_at`, `elevation_at` and `grade_at` are tick-safe, as on `ProceduralRoadPath`.
- **Unwrapped s:** a client may keep counting s past L. World systems then build at s + kL, which lands on the same ground (the snaps build across the seam). `features_in(s0, s1)` reports every lap's features at their unwrapped s. A `CHECKPOINT`'s value is lap × 6 + sector + 1. `length_generated()` is `INF`.
- **Wrap math:** `wrap_s(s)` ∈ [0, L), `lap_of(s)`, and `signed_delta(a, b)` ∈ [−L/2, L/2) (how far b is ahead of a) for every distance comparison, as the handoff asks.
- **Sections:** `section_at`, `section_id`, `section_start`, `lane_flow_speed_mps(lane, lanes, s)`. `biome_plan(laps)` returns a `BiomePlan` with one leg per section over `laps` laps. Give it to a `BiomeDirector` (`director.plan`, `apply_to_road = false`) before its setup.
- **Not in the `RoadFeature` contract** (its kinds are frozen): ramps, road works zones, spawn points and elevated zones live in `road.layout` and the road-space file.
- **Pure:** a `RefCounted` with no Node, autoload or allocation in the tick paths (`test_queries_allocate_nothing`, lint `WB104`).

## Sky and glare

The loop turns through every heading, so the single-player sun rule (heading 15–30° off the sun, everywhere) cannot hold. This is MP-D3's "sun constraint relaxed for the loop". The room clock drives the sky, and the sun stays at world heading 0 (`SkyRig`). The loop keeps the part of the rule that matters. `LoopValidator.check_glare` enforces it:

- No straight heads within 15° of due west. The loop crosses west once per lap, inside the canyon's corner bend, like a procedural sun-side switch.
- A section with a sea (the coast, `WaterDef.road_sun_side`) keeps every straight up to its last bend in the 15–30° band on the sea's side. The coast runs at −22° with the sun on the right over the water. The bridge (−24.6°) is the sunset view.

Elsewhere the sun is on the side (desert 122°, city −94°) or behind (farmland), which suits the room clock's 22 minutes of day and 10 of night. See the snaps below.

## Road-space file (`loop_v1.json`)

Canonical JSON: the keys come in a fixed order (the order `LoopExport.road_space` writes, never sorted by a library), with two-space indentation and one small object per line. Positions and lengths are integers in **millimetres** (the protocol's `s` is u32 mm). Speeds are km/h floats with up to 6 decimals and no trailing zeros. The file uses UTF-8 and LF line endings and ends with one newline. **The hash is the SHA-256 of every byte of the file.**

| Key | Content |
| --- | --- |
| `format_version` | 1 (bump on any change of meaning) |
| `map_id` | `"loop_v1"` |
| `units` | `{"length": "mm", "speed": "km/h"}` |
| `generator` | `name`, `version` (`LoopMapDef.generator_version`), `seed`, `section_length_mm`, `edits` (sorted by key) |
| `length_mm` | L = 25,000,000 |
| `cross_section` | median half-width, inner shoulder, lane width, shoulder, guardrail offset (mm) |
| `sections` | `index`, `id`, `s_start_mm`, `s_end_mm`, `lanes`, `lane_flow_speeds_from_right_kmh` |
| `lanes` | Ranges tiling [0, L): `s_start_mm`, `s_end_mm`, `count`, `lane_width_mm`, `taper_mm` (from `s_start` the right edge moves from the previous count to `count` along a smoothstep over `taper_mm`, and the count steps at `s_start`, as in `ProceduralRoadPath`) |
| `tunnels` | `index`, `s_start_mm`, `s_end_mm`, `lanes` |
| `bridge` | `sector`, `s_start_mm`, `s_end_mm` (span and backstays) |
| `ramps` | `pair`, `kind` (`off`/`on`), `side` (`right`), `section`, `s_mm`, `length_mm` (off: the diverge starts at s; on: the merge) |
| `closure_zones` | `index`, `section`, `s_start_mm`, `s_end_mm` (with both tapers), `taper_mm`, `lanes_closed_from_right`, `default_on` |
| `sectors` | `index`, `s_mm`, `style`, `start_finish` |
| `spawn_points` | `s_mm`, `lane` |

The server needs no geometry: traffic, scoring and collisions run in road space. The client regenerates the geometry from `loop_v1.tres`.

## Editor

```
tools/godot.sh --path . res://src/road/loop/dev/loop_editor.tscn                    # or F6 in the Godot editor
tools/godot.sh --headless --path . res://src/road/loop/dev/loop_editor.tscn -- --export   # regenerate the files
tools/godot.sh --headless --path . res://src/road/loop/dev/loop_editor.tscn -- --check    # exit 1 if not current
tools/snap.sh src/road/loop/dev/loop_editor.tscn --size=1600x1000 [--select=<key>] [--group=<group>]
```

- **Plot** (left): the plan, north up. Section colours, width by lane count, tunnels dark (with their lanes), the bridge white, the elevated zone outlined, road works orange, ramps as yellow spurs, sector bars (S0 START chequered), blind crests red, lane changes as dots with the new count. The elevation strip below shows one lap. The square handles are the s-like parameters (tunnel portals, sector offsets, ramps, road works, lane changes): drag one along the loop to move it. The wheel zooms and a right drag pans.
- **Fields** (right): the seed with GENERATE, and every tunable as a numeric field, filtered by group (`bend`, `straight`, `pvi`, `tunnel`, `lanes`, `sector`, `ramp`, `closure`). Edited fields are highlighted, and **x** drops an edit. Edit keys are listed in `loop_map_def.gd`: radius, deflection and transition per bend; straight weights; `pvi/<i>/raise_m` (crest heights) and `radius_m`; tunnel portal and length; lane-change points; sector offsets (sector 3 moves the bridge); the ramp pair's off-ramp; road works starts.
- **Status:** L, the closure residual, the export hash, and the validation list (VALID or the errors).
- **Buttons:** SAVE writes the seed and edits into `loop_v1.tres`. EXPORT writes both JSON copies and the sidecars, and refuses while there are errors. CHECK compares the files with a fresh export. RESET EDITS clears the edits. PREVIEW TRAFFIC opens the traffic sandbox on the edited loop.

After changing the loop: SAVE, then EXPORT (or `--export`), then commit `data/maps/*` and `westbound-server/data/maps/*` and update `WB_GATEWAY__MAP_HASHES`. `test_committed_files_are_current` fails until the files are regenerated.

## Validation

`LoopValidator.validate(road, tuning)` must be empty for a committed loop (`test_loop_v1_is_valid`). It checks:

- **Closure:** position below 1 mm, heading below 10⁻⁶ rad, curvature 0 at the seam, elevation and grade. Exactly one full turn.
- **Limits:**
    - radius ≥ 1,200 m everywhere (canyon included; the biome rules never go tighter);
    - grade ≤ 5 %;
    - vertical radius ≥ 3,000 m;
    - straights ≥ 100 m.
- **Lengths:** L within 24–26 km. Each section within ±10 % of the handoff's 5 km.
- **Lanes:** every change is tapered, and none lies in a tunnel or on the bridge. The narrowed tunnel is 2 lanes from portal to exit, with its taper finished `tunnel_lane_lead_m` before the portal.
- **Tunnels and bridge:**
    - the tunnels lie in the canyon, clear of the gantries;
    - the bridge lies in the coast;
    - sector 3 is the suspension bridge.
- **Ramps:** on straight-ish road (R ≥ 2,000 m), and clear of tunnels, the bridge, lane tapers and gantries.
- **Sectors:** 6, evenly spread (±15 %), start/finish in the desert.
- **Road works:** one per section, clear of tunnels, the bridge, ramps and lane changes.
- **Glare:** the rules above.

Other seeds may fail: the design is tuned for `map_seed = 1`, and the editor shows what to fix.

Tests: `tests/road/test_loop_road_path.gd`, `test_loop_export.gd` and `test_loop_editor.gd` (the editor and the traffic sandbox on the loop, driving across the seam).

## Snaps

```
tools/snap.sh src/road/loop/dev/loop_editor.tscn --size=1600x1000
tools/snap.sh src/road/loop/dev/loop_preview.tscn --sweep=at:start,desert,tunnel,crest,coast,bridge,city,ramp,farmland,seam --sky_t=0.3
tools/snap.sh src/road/loop/dev/loop_preview.tscn --at=bridge --cam=sea --sweep=sky_t:0.2,0.5,0.66,0.85 --tag=sea
tools/snap.sh src/road/loop/dev/loop_traffic_preview.tscn --at=city --warm_s=15 --sky_t=0.4
```

`loop_preview` options: `--at=<place>` or `--s=<m>`, `--lap=<n>`, `--cam=chase|high|top|side|sea`, `--sky_t`, `--tier`, `--label=false`.

## Wrap-around and the loop test mode (N3.2)

### The wrap design

**s stays unwrapped and monotonic on the client.** The car, traffic (`TrafficSim`, the director, the view, opposite traffic), scoring, hit detection, the leg tracker, the camera and every world node keep counting s past L lap after lap; only road queries wrap. `LoopRoadPath` answers any s modulo L (positions, elevation, lanes, the cross-section, features at their unwrapped s, a continuous heading), so:

- every distance between two things the client simulates (car to traffic, car to gantry, chunk to focus) is a plain difference, which equals the wrapped signed difference while they are less than L/2 apart (always: traffic lives within about 1 km of the car);
- nothing in the traffic sim, the director, scoring or hits needed a change: there is no seam in their numbers;
- float64 s keeps full precision for hours (70 m/s for 10 h is 2.5·10⁶ m, a step of 5·10⁻¹⁰ m);
- the floating origin works as before: positions repeat every lap, and wrapping s never moves the world.

The run starts at **s = L + the first spawn point** (lap 1, 150 m past the start / finish gantry), so nothing ever builds at s < 0. Wrapped s comes in only from the server (N4): `LoopRoadPath.unwrap_near(ref_s, wrapped_s)` places it next to the car, `signed_delta` / `wrap_s` / `lap_of` are the other forms, and `RoadPath.period_m()` (L on the loop, 0 on the open road) lets world code tell the two apart.

What changed for the world stack:

- **Look plan:** `road.biome_plan(0)` is periodic (`BiomePlan.repeating`, `period_legs` = 5: leg k is section (k − 1) mod 5), valid at any lap.
- **Elevated city:** `ElevatedPlan.set_zones(layout.elevated_s0, layout.elevated_s1, L)` replaces the seeded cells with the loop's zone (15,700–19,300 m) every lap. Sector 4's sign gantry stands on the viaduct.
- **Landmarks:** on a loop road the gantries name sectors (`LandmarkText.loop_landmark`): START / FINISH on the toll gantry, SECTOR n — BIOME and NEXT GANTRY x KM, and the warning signs read GANTRY 1 KM (FINISH 1 KM before the line).
- **Roadside props** are seeded by unwrapped cell index, so the scatter differs from lap to lap (continuous across the seam, never popping). The road, lanes, landmarks, tunnels, the bridge, the sea and the elevated zone repeat exactly. Making props repeat would need every cell length to divide L (open question).
- Ramps and road works stay road-space data only (no ramp geometry or rail gaps yet; the zones are off).

### Loop test mode

A single-player practice run on `loop_v1` (`Run.MODE_LOOP`, `RunLoop`, docs/RUN.md → Loop mode):

- **Open it:** web `?mode=loop` (add `&server=off` offline); native `--mode=loop` (user or engine argument) or the dev **LOOP** button (row 4; it toggles back to JOURNEY). Dev URL extras: `&at=desert|canyon|tunnel|crest|coast|bridge|city|ramp|farmland|seam|<metres>`, `&clock_min=<minutes into the room cycle>`, `&bot=keep`, `&lane=`, `&speed_kmh=`, `&cam=`, `&hud=false`.
- **Off:** forks, the finale and the journey bonus, Chase the Sun (the sun clock, lifts, hesitation's sink), leg objectives, and the lane-reshaping or lane-closing set pieces (`LoopTuning.excluded_set_pieces`: merge zone, road works).
- **Sectors:** the loop's CHECKPOINT features are the sector gantries, so `LegTracker` runs them as legs (a copy of `LegsTuning` whose `legs_to_coast` is never reached): a crossing banks the chain, pays Clean / Pace / Threads / Heat (×2 at night) and a clean sector restores a life. The HUD toast reads SECTOR n COMPLETE, LAP n COMPLETE at the start / finish line, and SECTOR n — BIOME for the next one. The full N6 sector rules come later.
- **Room clock:** `RoomClock` (`LoopTuning`: 32 min, 22 day / 10 night, epoch 0 = UTC-derived, so every public room shares it). The run reads the wall clock once at its start and then advances the clock by the sim's dt (replayable; tests pass a fixed start). The day runs sky_t morning → sunset; the night runs sunset → the night keyframe (45 s), holds, and dawns over the last 60 s. Night ×2 covers all 10 minutes. The HUD's top plate becomes the clock: DAY / NIGHT ×2, the cycle with the night's share, NIGHT IN mm:ss (DAWN IN at night) and SECTOR x.x KM to the next gantry.
- **Traffic:** the director at `LoopTuning.director_leg` (5: mix, headway, set-piece unlocks), at **10 vehicles per km per lane** (the spec's normal room density) × the section's share (desert 90 %, canyon and coast 100 %, city 130 %, farmland 90 %), with the section's lane flow speeds (written into the run's own `TrafficTuning` copy when the car enters a section; batches planned ahead near a section line use the section the car is in).

### Performance

Draw calls, `tools/drawcalls.sh src/run/run.tscn --mode=loop --at=<place> --clock_min=<m> --bot=keep --hud=false` (1361x720, Medium, frozen frame; 100 is the budget):

| Where | Clock | 3D draws | Triangles | Vehicles (+ opposite) |
| --- | --- | --- | --- | --- |
| Desert | 8 min (afternoon) | 39 | 78k | 31 + 14 |
| Canyon tunnel | 8 min | 37 | 52k | 10 + 8 |
| Coast | 21 min (sunset) | 40 | 56k | 16 + 12 |
| City, elevated | 9 min | 44 | 88k | 38 + 20 |
| City, elevated | 26 min (night) | 48 | 89k | 38 + 20 |
| Farmland | 12 min | 42 | 59k | 17 + 11 |
| Seam (start / finish) | 15 min | 48 | 70k | 18 + 11 |

With the HUD, the dev HUD and the dev buttons the city is 70 draws in all (44 3D). CPU (`test_city_frame_cost`, headless, this loaded machine): see the bench lines in the test log.

### Server map loading

`westbound-server` compiles `westbound-server/data/maps/loop_v1.json` in (`include_str!`, like the profanity list: the Docker context is `westbound-server/`, and the binary can never run with another map than the one it was built with). At startup `map::builtin()` parses and validates it (`sim::map::LoopMap::from_json`: format version, units, sections and lane ranges tiling [0, L), tunnels, the bridge, ramps, road works, sectors in order with sector 0 the start / finish, spawn points on a lane) and hashes the bytes (SHA-256). `AppState.map` holds it for the room code. The gateway accepts that hash when `gateway.map_hashes` is empty (dev keeps accepting any hash too); a configured list is an explicit override and replaces it (a warning is logged when it leaves the built-in hash out). The log says `loop map loaded … sha256=…` and the accepted hashes.

`sim::map::LoopMap` (pure) has the wrap math in millimetres (`wrap_mm`, `signed_delta_mm` in [−L/2, L/2), `unwrap_near`, `lap_of`, `in_span`) and metres (`signed_delta_m`, `wrap_m`), `lane_count_at`, `section_at`, `lane_flow_speed_kmh`, `sector_at`, `next_sector`, `sector_crossed`, `tunnel_at` and `closure_zone_at`. Rust tests: `sim` (`map::tests`: wrapped signed difference, lane counts by s, sectors, refusals) and `server` (`map::tests`: the hash equals the committed `.sha256`).

**Client hash:** `MapInfo.loop_hash()` (`src/net/map_info.gd`) is `FileAccess.get_sha256("res://data/maps/loop_v1.json")` as raw bytes for `NetClient.start(url, build, map_hash, …)`. The export presets export all resources, and Godot packs the JSON byte for byte (checked in a real web export: the 4,581 bytes sit unchanged in `index.pck`). In loop mode the run prints `loop: loop_v1 map_hash=<hex>` once, and the web smoke checks it: `node tools/web_smoke/smoke.mjs --query "mode=loop&server=off" --expect "loop: loop_v1 map_hash=$(cut -d' ' -f1 data/maps/loop_v1.sha256)"`.

Tests: `tests/run/test_run_loop.gd` (the mode, the seam with traffic, lap after lap, the floating origin, determinism, sectors, the clock, per-section traffic, allocation, the city's frame cost; the soak drives three whole laps twice), `tests/run/test_room_clock.gd`, `tests/road/test_loop_wrap.gd`, `tests/ui/test_hud_loop.gd`, `tests/net/test_map_info.gd`.

**Snaps:** `tools/snap.sh src/run/run.tscn --mode=loop --sweep=at:desert,tunnel,coast,city,farmland,seam --clock_min=8 --bot=keep --seconds=2`; the web export: `node tools/web_smoke/smoke.mjs --query "mode=loop&at=coast&clock_min=21.3&bot=keep" --settle 12000 --screenshot tests/out/snaps/web_loop_coast.png`.
