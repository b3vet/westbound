# The loop map (N3.1)

Spec: [WESTBOUND_MULTIPLAYER_HANDOFF.md](../WESTBOUND_MULTIPLAYER_HANDOFF.md) → The loop map, Time of day in multiplayer, Rules for the server code 5. Plan: [MULTIPLAYER_PLAN.md](MULTIPLAYER_PLAN.md) MP-D3, N3.1. Protocol: [PROTOCOL.md](PROTOCOL.md) (`map_hash`). Contracts: [CONTRACTS.md](CONTRACTS.md) §2–§3.

`loop_v1` is a fixed, closed, one-way highway loop of exactly 25 km, generated from a seed plus a short list of hand edits, and frozen as data:

| File | What | Who reads it |
| --- | --- | --- |
| `data/maps/loop_v1.tres` | `LoopMapDef`: seed, section templates, feature rules, edits. The client scene data: everything regenerates from it. | client (`LoopRoadPath.load_default()`), the editor |
| `data/maps/loop_v1.json` | The road-space file (canonical JSON) | client (hash in `Hello`) |
| `westbound-server/data/maps/loop_v1.json` | The same bytes, for the server (its Docker build context is `westbound-server/`) | server (N3.2) |
| `*/loop_v1.sha256` | Sidecar: `<sha256>  loop_v1.json` (`sha256sum -c` format) | CI, the owner (Coolify) |

**Map hash (`loop_v1`):** `26a4e08b8e456ec56471c7d0626ab4ed760ba7579add6e4c279e9b3faa0dd296`. Set it as `WB_GATEWAY__MAP_HASHES` ([SERVER.md](SERVER.md) → Map hashes). It is the SHA-256 of every byte of `loop_v1.json`. It changes with any edit, seed or generator change: re-export, commit both copies and update the setting (list the old hash too while old clients are out).

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

## For N3.2 (streaming, loop test mode, server)

- **Client streaming:** the world stack already builds on unwrapped s ≥ 0 (the snaps cross the seam). What remains:
    - The `RoadBuilder` builds no chunk at s < 0. Start a session at s = L (lap 1) or wrap the focus before it goes negative.
    - `BiomePlan` is finite: `road.biome_plan(laps)` covers `laps` laps, then falls back to the first section's biome. A periodic plan (leg k → section (k − 1) mod 5) avoids the limit.
    - Consumers that downcast to `ProceduralRoadPath` (fog cards, water ribbon, landmarks' `first_retained_s`, the mesher's rail gaps) fall back to their defaults.
    - `forget_before` is a no-op: the whole table is 12,501 samples.
- **Floating origin:** positions repeat every lap and the loop spans about 8 × 8 km, so the origin shifts as usual. Wrapping s does not move the world.
- **Elevated city:** `ElevatedSections` still places its stretches with `ElevatedPlan`'s own seeded cells in the city biome. `road.layout.elevated_s0/s1` holds the loop's intended zone for N3.2 to feed in.
- **Ramps and road works are road-space data only:** no ramp geometry or rail gap is drawn yet, and the zones are off by default. The server toggles them; the traffic and the view follow from lane closures (N4/N6).
- **Landmarks** name each gantry's next "leg" from the plan. With the loop plan that is the next section's biome.
- **Client hash for `Hello`:** `FileAccess.get_sha256("res://data/maps/loop_v1.json")` (the tests check that it equals the sidecar and a fresh export). Confirm that exported builds ship the `.json` byte for byte: Godot's JSON loader recognises it, and `export_presets.cfg` excludes only tests, tools and docs. Alternatively, bake the hex into a constant at export time.
- **Server:** load `westbound-server/data/maps/loop_v1.json` (e.g. `include_str!`, like `profanity.txt`), compare the SHA-256 of those bytes with the configured hash, and use `length_mm` as the wrap. Every position is already in mm.
- **Loop test mode:** `LoopRoadPath.load_default()` plus the loop's `biome_plan`, with the run's `ProceduralRoadPath`-only paths (forks, finale, `schedule_lane_count` set pieces) switched off. The traffic sandbox hook shows the minimal wiring.
