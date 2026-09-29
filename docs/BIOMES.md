# Biomes and the journey plan (WP6.4a)

Spec: "World → Biomes" (each leg is one biome; default order; forks swap the next biome; every biome must look good across the whole color script; biome data), "Road" (3 lanes by default, some biomes 4, tunnels and road works 2), "Color script" (biome tint offsets), "Sky" (3–4 horizon silhouette cards), "Legs and checkpoints", "The journey goal". Contracts: [CONTRACTS.md](CONTRACTS.md) §3, §10, §13.

## The plan: leg → biome

| Leg | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9+ |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Biome | Farmland | Desert | Desert | Canyon | Canyon | City | City | Valley fog | **Coast** (endless) |

- Data: `LegsTuning.leg_biome_ids` (one id per leg, `legs_to_coast` of them) and `endless_biome_id` (`data/tuning/legs.tres`). Ids name `data/biomes/<id>.tres`.
- **Flagged interpretation.** The spec lists the default order farmland → desert → canyon → coast → city → valley fog, but also makes the coast the destination "reached after 8 legs", after which "the road continues as an endless coastal highway". Both can't hold with the coast fourth. The plan keeps the order for the other five biomes, spreads them over the 8 legs (desert, canyon and city get two legs each), and makes the coast the arrival and the endless road. City lands late (legs 6–7, usually at night by then), and valley fog is last (its dawn-friendly palette meets the dawn at a night checkpoint). It is one data line to change.
- A biome whose file does not exist yet falls back to the leg before it (`BiomePlan.missing_ids`). Until WP6.4b lands city, valley fog and coast, legs 6+ stay canyon.
- Leg k covers `[(k−1)·L, k·L)`, so the next leg's biome takes over **at the checkpoint line**.

## Framework API

| Where | What |
| --- | --- |
| `BiomePlan` (`src/road/biome_plan.gd`, pure) | `from_tuning(legs)`, `uniform(biome, L)`, `biome_for_leg(k)`, `biome_at(s)`, `leg_at(s)`, `plan_next(leg, biome)` (forks: one leg), `set_biome_from_leg(leg, biome)`, `add_candidate(biome)` (a fork's possible biome, so world parts exist for it), `catalog()`, `blend_into(s, before, after, out)`, `version` |
| `BiomeDirector` (Node) | Owns the plan (`plan`, `journey = false` for one biome everywhere). `setup` hands it to a `ProceduralRoadPath` (`set_biome_plan`). `biome_at`, `current`, `plan_next`, `set_biome_from_leg`, `biomes()`, blended look queries (`verge_color_at`, `ground_color_at`, `rock_color_at`, `rock_shade_color_at`, `world_tint_at`, `fog_tint_at`, `horizon_blend_at`), `plan_version`. Emits `Events.biome_changed(id)` at setup and at each change. Pushes the look to the `SkyRig` (group `wb_sky`) |
| `BiomeRoadRules` (`src/road/road_gen/`, pure) | Per-leg road rules latched once from the plan: lane count, curve / crest / tunnel frequency scales, bend sight clearance |
| `ProceduralRoadPath` | `set_biome_plan(plan)` restarts generation with the rules. It schedules each leg's lane change and tunnels as it generates, one leg ahead. `TUNNEL` features (`value` = length), `SIGN` with tag `lane_ends`. `schedule_lane_count` now accepts any order and keeps the schedule sorted. `lanes_right_edge_d` (and therefore `guardrail_d`) follows the taper |
| `SkyRig` | `set_biome_tint_offset(v)` (existing), `set_fog_tint_offset(c)`, `set_horizon_blend(style_a, height_a, style_b, height_b, t)`, `set_heat_shimmer(x)` |

### At a checkpoint

- **Props** swap at the line. Each roadside cell is filled by the layer of the biome at the cell's middle, and `Roadside` builds layers for the whole catalog at setup.
- **Ground, verge and rock colours** blend over `[line − biome_blend_before_m, line + biome_blend_after_m]` (250 / 350 m, smoothstep). `RoadBuilder` gives the mesher the colours at each chunk's start and end, and the mesher interpolates per row.
- **World and fog tint offsets** blend over the same range, at the player's s.
- **Horizon** cards crossfade over `horizon_blend_before_m / _after_m` (600 / 900 m). Per layer, the silhouette height morphs from one style to the other.
- **Lane count** changes `biome_lane_change_after_m` (320 m, past the bridge's backstays) after the line, tapering over `biome_lane_taper_m` (250 m).
- **Toast:** the leg summary names the new leg's biome (`leg_started` carries the id; the HUD loads `data/biomes/<id>.tres` for `display_name`).

### Determinism and forks

Everything is data plus the run seed: tunnels come from `rng_road.derive(&"tunnels")` mixed with the leg, and cliffs from `rng_props.derive(&"cliffs")`. `tests/unit/test_road_biomes.gd` and `test_biome_journey.gd` hash the traces.

A leg's **road rules are latched** the first time the generator asks about the leg, which happens while it generates the previous leg. A later `plan_next` for that leg changes its look (props, colours, horizon, toast), but not its geometry. For a fork to change the next leg's lanes, curves or tunnels, WP6.5 must plan it before the road generates past the fork's leg start minus one leg. To keep Daily Drive identical across quality tiers (different view distances generate different distances ahead), fork plans must not depend on how far the road happened to be generated. Otherwise the road would differ between tiers.

## Adding a biome (for WP6.4b)

1. Create `data/biomes/<id>.tres` (`BiomeDef`). `id` must equal the file name, because the HUD and `BiomePlan.load_biome` find it by id.
2. **Road:** `lane_count` (2–4; 4 widens after the checkpoint), `curve_frequency_scale` (straights ÷ scale; above 1 also tightens the radius range), `crest_frequency_scale`, `tunnel_frequency_scale` (× `RoadTuning.tunnels_per_leg`), `bend_sight_clearance_m` (0 = the road default; walls close to the road lower it and flag more `BLIND_BEND`s).
3. **Props:** `scatter_props` (`RoadsideProp`: SCATTER or ROW; one MultiMesh and one draw call per mesh variant), `field_grid`, `fence_mesh_path` / `fence_setback_m`, and `cliffs` (`CliffDef`, built into the road chunks: no draw call). Keep setbacks clear of a cliff band. Meshes go in `assets/props/<biome>/`, built by a script in `tools/props/` with `PropMeshBuilder` (`extra_colors` for colours not in the palette).
4. **Look:** `ground_color`, `verge_color`, `rock_color` / `rock_shade_color` (the hill over a road tunnel), `world_tint_offset` (linear, added to world albedo; keep it within ±0.02, because darks show it most) and `fog_tint_offset` (sRGB, added to the fog and horizon tints), and `traffic_palette`.
5. **Horizon:** `horizon_layer_style` (`SkyRig.HorizonStyle` per layer, nearest first), `horizon_layer_height_m`, `heat_shimmer` (0..1), and `horizon_set` (a name).
6. **Checkpoints:** `landmark_style` / `landmark_styles`. **Traffic:** `set_piece_ids` / `set_piece_weights`.
7. Put the id in `LegsTuning.leg_biome_ids` or `endless_biome_id`, or pass it to `plan.add_candidate` for a fork.
8. Check the look with `tools/snap.sh src/run/run.tscn --leg=N [--leg_s=M] --sweep=sky_t:0.05,0.38,0.5,0.72 --renderer=both`. `--leg=N` starts M metres (600 by default) into leg N.

## Desert mesas

- **Road:** 3 lanes, `curve_frequency_scale` 0.45 (about 40% fewer bends: long straights) and crests 0.6.
- **Props:** mesas and buttes (big, far, flat-shaded, banded red rock with a pale stratum; 700 m cells, set back 60–300 m); saguaros and small cacti with flowers; sage scrub; red rock clusters (dry-wash rocks); a barbed-wire fence.
- **Look:** warm tint (world +0.012 / +0.004 / −0.006, fog +0.03 / +0.01 / −0.03), tan ground and verge.
- **Horizon:** mesas on three layers, mountains farthest.
- **Heat shimmer:** `heat_shimmer = 1`. `horizon.gdshader` ripples the top edge of the far cards (two beating sine waves along the azimuth, travelling with `TIME`, up to about 0.1°) and lifts the base haze toward the sky's horizon colour (a mirage band). It fades with the sun's height, so there is none at night. It is a vertex effect on existing cards: no extra pass and no screen reads, and it matches on both renderers (parity at sky_t 0.2: p99.9 11, mean 0.69).
- **Checkpoints:** sign gantry or toll gantry.

## Canyon pass

- **Road:** 3 lanes, curves 1.8, crests 1.8, tunnels 1.6, and bend sight clearance 6 m (walls hide bends: more `BLIND_BEND`s).
- **Cliffs:** a `CliffDef` profile of 9 faces (ledges between steep faces in strata colours), set 3 m past the scenery line. They wobble per row by seeded noise, come in 300 m runs per side (65% right, 55% left) that rise and fall over 70 m, always frame tunnels (160 m), and fall away 330 m around checkpoints (landmarks) and 30 m around the right-hand warning signs. They are built into the chunk surface, so they follow every curve and cost no draw calls. Boulders and scrub stand in front of them; pines and hoodoo spires stand behind.
- **Tunnels:** `RoadTuning.tunnel_*`. A leg holds 0–2 tunnels (each 300–800 m) in its window: 650 m after its checkpoint, and 150 m before the next checkpoint's first warning sign. With two, they share one narrowed section.
    - **Lanes:** they drop to 2, with a 200 m taper ending 150 m before the portal, and come back 80 m after the exit. A `lane_ends` sign stands 400 m before the drop.
    - **Shell:** built into the chunk mesh. Walls beyond the guardrails, a central wall on the median (twin bores) and a roof at `LandmarkTuning.tunnel_clearance_m`. Lamp strips every `tunnel_lamp_spacing_m` on the walls, as emissive class 2 (street-lamp ramp). The interior (road, barrier, rails, walls) is darkened by `tunnel_interior_shade_frac` (0.42).
    - **Hill:** the landmark tunnel's hill profile in the biome's rock colours, plus a 20 m ridge over the bore and hipped ends with wing walls past both portals.
    - **Portals:** concrete faces with chamfered openings.
    - **Clearance:** `LandmarkClearance` adds `ZONE_TUNNEL` zones (`LandmarkBuilds.road_tunnel_clearance_zones`): the median through the bore (no median poles, and so no lamp pools; no gantries) and `[wall, hill foot]` past the hips. Queries take a zone mask.
    - **Light change:** the spec's "light change at entry and exit" belongs to WP6.3's tunnel squeeze.
- **Look:** a slight warm tint, red-brown ground.
- **Horizon:** mountains near and far, with mesas between.
- **Checkpoints:** tunnel portal, suspension bridge, sign gantry.

## Budget (container, `tools/drawcalls.sh src/run/run.tscn --set=leg_override:8 --cam=chase --speed_kmh=150`, 1361×720)

| Where | 3D draw calls | Triangles |
| --- | --- | --- |
| Farmland, leg 1 | 47 | 75k |
| Desert, leg 2 | 43 | 82k |
| Canyon, leg 4 (walls both sides, tunnel ahead) | 39 | 65k |
| Farmland → desert checkpoint | 48 | 85k |
| Desert → canyon checkpoint | 45 | 71k |

- **Roadside worst case** (`tests/unit/test_roadside_biomes.gd`): desert 14, canyon 11, farmland 19.
- **Chunk build:** a canyon chunk with a portal and walls is about 4.2k triangles and about 2.2× the build time of a farmland chunk. It is still time-sliced by rows.

## Tests

| File | Covers |
| --- | --- |
| `tests/unit/test_biome_plan.gd` | The plan, the fallbacks, forks, blending and road-rule latching |
| `tests/unit/test_biome.gd` | The director and the three biomes' data |
| `tests/unit/test_biome_look.gd` | Tint, fog and horizon blend, shimmer |
| `tests/unit/test_biome_journey.gd` | The real run: handovers, toast names, tunnels on the run's road, determinism |
| `tests/unit/test_road_biomes.gd` | Scales, lane tapers, tunnels, determinism, a neutral plan being bit-identical, sorted scheduling |
| `tests/unit/test_road_tunnels.gd` | The shell, portals, lamps, darkening, hill, cliffs, ground blend, build cost |
| `tests/unit/test_roadside_biomes.gd` | Budget, clear zone, mesh contract, props swapping at the line |
| `tests/world/test_road_tunnel_clearance.gd` | Tunnel zones, the shell inside them, no poles in real tunnels |
