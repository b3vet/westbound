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

## Biomes 4–6: coastal highway, city at night, valley fog (WP6.4b)

Spec: "World, road and visual direction" (Road: roadside rhythm; Color script: biome tint offsets; Sky: horizon silhouette cards with parallax; Biomes 4–6; "every biome must look good across the whole color script"), "Night lighting", "The journey goal" (the coast is the destination), "Performance budget". With these files in place the plan above runs city on legs 6–7, valley fog on leg 8 and the coast from leg 9 on (endless).

| Biome | File | Signature |
| --- | --- | --- |
| 4 Coastal highway | `data/biomes/coast.tres` | The ocean below the road on the player's side, with surf, sea stacks and a lighthouse islet; road-cut rock cliffs, coastal houses, palms and scrub on the land side; the sun sinks into the sea; headlands and islands on the horizon; cooler tint; 4 lanes |
| 5 City at night | `data/biomes/city.tres` | Blocks of glass towers, brick apartment slabs, warehouses and mid-rises whose windows light up at night; distant skyscrapers; sound walls; neon billboards ("Volt Noodle Bar", "Starline Motel", invented); elevated highway stretches over the lowered street level; a lit skyline horizon; grey-blue concrete and glass by day; 4 lanes |
| 6 Valley fog | `data/biomes/valley_fog.tres` | Conifer and mixed forests (copses), meadows, farmhouses and barns, a rail fence, river glimpses, low fog layers and mist curtains (thickest at dawn, dusk and night), misty ridges on the horizon, a dawn-friendly tint; 3 lanes |

### Files

| Path | Class | Role |
| --- | --- | --- |
| `src/road/biome_def.gd` (block `WP6.4b`) | `BiomeDef` | `water`, `elevated`, `fog_cards`, `horizon_def` (all optional) |
| `src/world/biome_features/biome_feature.gd` | `BiomeFeature` | Base of the three feature nodes: windows in steps, background build of the next window, floating origin |
| `src/world/biome_features/feature_mesh.gd` | `FeatureMesh` | Vertex arrays of one build |
| `src/world/biome_features/ground_drop_mesher.gd` | `GroundDropMesher` | `RoadChunkMesher` with the ground ribbon lowered (the RoadBuilder hook) |
| `src/world/ocean/water_def.gd`, `water_plan.gd`, `water_ribbon.gd` | `WaterDef`, `WaterPlan`, `WaterRibbon` | Ocean / river data, shoreline plan, the node |
| `src/world/elevated/elevated_def.gd`, `elevated_plan.gd`, `elevated_sections.gd` | `ElevatedDef`, `ElevatedPlan`, `ElevatedSections` | Elevated stretches data, plan (`drop_at`), the node |
| `src/world/fog_cards/fog_cards_def.gd`, `fog_cards.gd` | `FogCardsDef`, `FogCards` | Low fog data, the node |
| `src/world/horizon_sets/horizon_set_def.gd` | `HorizonSetDef` | A biome's horizon extensions; `apply_blend(material, a, b, t)` |
| `assets/shaders/water.gdshader` (+ `materials/water.tres`) | | Faceted animated water, sky/sun reflection, sea-side land |
| `assets/shaders/fog_card.gdshader` (+ `materials/fog_card.tres`) | | Alpha-blended mist cards |
| `assets/shaders/world_windows.gdshader` (+ `materials/world_windows.tres`) | | `world.gdshader` plus lit windows (emissive class 4) |
| `assets/shaders/horizon_biomes.gdshader` | | `horizon.gdshader` superset: islands, headlands, sea masks, mist, lit windows |
| `tests/unit/test_biome_coast_city_valley.gd`, `tests/world/test_{ocean,elevated,fog_cards}.gd` | | Data, budgets, clear zone, plans, meshes, determinism, frame cost |
| `tools/props/build_props_4_6.gd`, `biome_prop_builder.gd`, `palette_biomes_4_6.tres` | `BiomePropBuilder` | Prop generator, builder extras, the biome colors |
| `assets/props/{coast,city,valley}/*.res` | | Generated props |
| `src/road/dev/biome_preview.tscn` | | Review scene (real road, roadside, features, sky, parked traffic) |

### Props

Generated like farmland's (`tools/props/build_props.gd`): flat-shaded, palette vertex colors, `world.tres`, deterministic.

```
tools/godot.sh --headless --path . --script res://tools/props/build_props_4_6.gd
```

- **Palette:** the style guide (`assets/palette/palette.tres`) plus 31 biome colors in `tools/props/palette_biomes_4_6.tres` (sand, rock, palm, glass, concrete, neon, conifer, meadow, ...). `BiomePropBuilder.merged_palette()` joins them; names never shadow the style guide (tested). It predates `PropMeshBuilder.extra_colors` (WP6.4a); both work.
- **Emissive:** lamps, the lighthouse lantern and neon tubes use class 2 (street lamp: bright at night, the colored tube by day). City windows use **class 4** of `world_windows.gdshader`: the glass color by day, plus `window_glow` × `wb_emissive_streetlamp` × UV2.y (the room's brightness, 0 = dark) at night. Buildings are `world_windows.tres`; the tests accept it next to `world.tres`.
- **Footings:** every city prop reaches 12 m below its origin (`FOOTING_M` ≥ `ElevatedDef.height_m`), so beside an elevated stretch it stands on the lowered ground.
- **Budgets:** ≤ 400 triangles per mesh (tested). Forests are copses of 8–9 trees in one mesh (144 triangles), so woods cost few instances.

### World features

All three are world-system nodes (§13) built on `BiomeFeature`:

```
feature.biome_director = director     # biome spans; null = fallback_biome everywhere
feature.setup(ctx, road, origin)      # seed: ctx.rng_props.derive(<feature id>)
feature.update_view(player_s)         # once per frame
```

- **Windows:** step k shows `[k·step − roadside_behind_m, (k+1)·step + view distance]`. While it is shown, the next window is built in the background (`build_units_per_frame` rows / banks / piers per frame, from the data) and swapped in at the step. The p99.5 frame is 0.3–0.6 ms on a desktop (tests).
- **Floating origin:** a build's vertices are relative to its anchor (the origin when it began); the node sits at `anchor − origin` and moves on `Events.origin_shifted`. Nothing is rebuilt for a shift.
- **Determinism:** everything is a function of (props seed, absolute s, the biome plan). Same seed, same water, stretches and fog (tested).
- **Draw calls:** one per feature while it has geometry.

#### WaterRibbon (coast ocean, valley river)

`WaterDef` per biome; `WaterPlan` gives the shoreline offset at s (the def's offset, a meander, the sweep in and out over `arrive_m` at the biome's ends, or none; river cells show with `span_chance_frac`).

- **Flat water** (`drop_m` = 0, the river): shore strip, water, far bank, `lift_m` above the road plane.
- **Sea slope** (`drop_m` > 0, the coast): a road-level strip (`shore_offset_m`), then the land falls over `slope_run_m` in a craggy slope to the sea level (the road's elevation smoothed over ±`level_smoothing_m`, minus `drop_m`, at least `min_drop_m` below the road), then the beach, surf and sea, flat. A low chase camera sees water at road level only as a thin band at the horizon; below the road the ocean fills its side of the view.
- **Islets:** sea stacks and a lighthouse islet (`islet_*` fields) are copied into the water mesh at the sea level: no extra draw call. Their lantern glows (the water shader takes the emissive class from UV2.x on land vertices).
- **Shader:** every vertex bobs on its own phase; fragments take their triangle's flat normal from screen-space derivatives, light it with the shared sun, and reflect the shared sky (`wb_sky_color`) and two sun lobes (sparkles and the path) by Fresnel. `set_time()` fixes the wave clock (snaps, parity). A depth pull (`depth_pull_frac`) keeps the water above the ground ribbon at range.
- **Horizon:** `water.horizon_material = <the sky's Horizon material>` feeds `sea_dir` (toward the sea, from the road heading 300 m ahead) to `horizon_biomes.gdshader`, so headlands stay on the land side and islands on the sea side.
- **Side:** the coast's ocean is on the **right** (the player's carriageway: from the left the opposite carriageway hides it) and must be on the **sun's** side, so the sun sinks into the sea. The road plan picks the sun side at random per seed and keeps it 15–40 km, so the road generator must keep the sun right of the axis through coast legs (needs below). The preview picks such a seed.
- `ground_drop_at(s, side)`: how far the ground ribbon must go down on that side (below the sea), for the mesher hook.

#### ElevatedSections (city)

`ElevatedPlan.drop_at(s)`: per `cell_length_m` cell, at most one stretch (chance, length, position from the seed), whole inside one biome span, never over a checkpoint landmark or warning sign (`LandmarkClearance`, when given). The ground falls away with a smoothstep over `ramp_m` to `height_m`; the road never moves (road space, traffic, scoring are untouched). The node draws the deck edge beyond each guardrail, parapets, girder fascia, the deck's underside, a hammerhead pier under each carriageway every `pier_spacing_m`, and the ground under the road.

#### FogCards (valley)

Per (cell, side), a bank of `layer_count` horizontal translucent cards stacked above the ground and `curtain_count` vertical mist curtains, from `setback_min_m` beyond the scenery line outward (never over the carriageway or its clear zone), more likely and denser where the road runs through a dip (`valley_factor`). The shader fades the edges, breaks the cards up with world-anchored noise, clears them within `near_clear_m` + `near_fade_m` of the camera, and thins them with a high sun (`midday_factor`). Color: the fog color with the sun's in-scatter (`wb_fog_color_dir`), a touch brighter. Transparent pass, `render_priority` 1 (after the sky, §13).

#### Horizon sets

Each biome sets `horizon_layer_style` / `horizon_layer_height_m` (the director's crossfade, above) and a `horizon_def` (`HorizonSetDef`) with the extensions of `horizon_biomes.gdshader`, a superset of `horizon.gdshader` (same mesh, uniforms, styles 0–4, crossfade, heat shimmer and output):

| Biome | Styles (near → far) | Extensions |
| --- | --- | --- |
| Coast (`coast_headlands`) | headlands (6), islands (5), mountains, mountains | headlands and mountains on the land side, islands on the sea side (`layer_land`) |
| City (`city_skyline`) | skyline, skyline, hills, mountains | lit windows on both skylines at night (`layer_windows`) |
| Valley (`valley_ridges`) | hills, hills, mountains, mountains | the lower part of every card in mist (`layer_mist`) |

`HorizonSetDef.apply_blend(material, from_def, to_def, t)` switches the Horizon material to `horizon_biomes.gdshader` the first time a set is given and writes the extensions blended like the silhouettes (null = none). ISLANDS and HEADLANDS are drawn flat by the base shader, so without the switch the coast shows a clear sea horizon.

### Wiring (needs, for the orchestrator)

1. **World nodes:** add `WaterRibbon`, `ElevatedSections` and `FogCards` to the run's world stack with the run's `BiomeDirector`: `setup(ctx, road, origin)` and `update_view(s)` per frame, like Roadside. `ElevatedSections.clearance` = the run's `LandmarkClearance` (landmark and road-tunnel zones), set before setup. Keep the road generated from `s − road.roadside_behind_m` to the window end (as for Roadside).
2. **Ground hook:** RoadBuilder's mesher must be a `GroundDropMesher` (same constructor, plus `cliff_seed`) with `drop_at = elevated.plan.drop_at` and `field_drop_at = water.ground_drop_at`; set the features up before the builder's first build. Without it the city's viaducts stand on the ground and the coast's ground ribbon covers the sea. `src/road/dev/biome_preview.gd` shows it by swapping the builder's private `_mesher`; the builder should take a mesher (or the two callables).
3. **Sky:** in `BiomeDirector._push_look`, after `set_horizon_blend`, call `HorizonSetDef.apply_blend(<the sky's Horizon material>, h.from.horizon_def, h.to.horizon_def, h.t)` (SkyRig should expose its Horizon material); and `water.horizon_material = <that material>` for the sea mask.
4. **Sun side at the coast:** the road plan must keep the sun right of the axis (plan sun side −1; `WaterDef.side` +1) through the coast legs, switching before the first one if needed, so the sun sinks into the sea.
5. **Roadside:** no common billboards on the water side where `WaterDef.drop_m` > 0 (they would stand over the sea slope). Biome props already stay on the land side.
6. **Tunnels:** the coast has none (`tunnel_frequency_scale` 0: its hill would stand on the sea slope); the city (0.2) and the valley (0.3) use `rock_color` / `rock_shade_color` for the hill. Elevated stretches avoid tunnel zones through the clearance.

### Review and budget

```
tools/snap.sh src/road/dev/biome_preview.tscn --biome=coast --renderer=both --sweep=sky_t:0,0.38,0.5,0.58,0.66
tools/snap.sh src/road/dev/biome_preview.tscn --biome=city --cam=side --sky_t=0.66
tools/drawcalls.sh src/road/dev/biome_preview.tscn --biome=valley_fog --traffic=false
```

Options: `--biome`, `--seed`, `--s`, `--cam=chase|far|driver|high|side|sea|back` (chase and far are the game's rigs), `--sky_t`, `--tier`, `--traffic`, `--features`, `--ground_drop`, `--horizon`, `--lanes`, `--time`, `--night_lights`, `--label`.

**Draw calls** (`tools/drawcalls.sh`, chase, Medium, no traffic, 3D only): farmland 26 (road 5, roadside 18, sky 3); coast 20 (water 1, road 5, roadside 11, sky 3); city 25 (elevated 1, road 6, roadside 15, sky 3); valley 27 (water 1, fog 1, road 5, roadside 17, sky 3). Roadside worst over 12 km at Medium (tests): coast 17 / 26k triangles, city 16 / 44k, valley 19 / 53k (share 25 / 60k). In the run (`tools/drawcalls.sh src/run/run.tscn --set=leg_override:N --cam=chase --speed_kmh=150`, traffic, features not yet wired): city leg 6 50 3D draw calls / 66k triangles, valley leg 8 48 / 69k (farmland leg 1: 47 / 75k above); the coast (leg 9, dev HUD) 37 3D. Wired, the features add one draw call each (two in the valley) and a few thousand triangles: every biome stays within farmland + 6 draw calls and under 150k triangles.

**Parity** (`tools/parity.sh`, chase at sky_t 0 / 0.38 / 0.5 / 0.66 / 0.85 and high views): the coast (water, horizon) and the city (windows, horizon, elevated) pass everywhere in the gameplay view; the coast's water-dominated high view passes. Known residues, none from a new opaque shader:
- the valley's chase view at sky_t 0 (p99.9 16): dense forest silhouettes against the bright morning fog on the unchanged `world.gdshader` (it stays 16 with the features and the horizon set turned off, `--features=false --horizon=false`);
- the city's night side view (p99.9 15): hundreds of sub-pixel lit windows and stars (the window shader alone matches exactly in an isolated test);
- the valley's fog cards seen from high above by day (p99.9 15): an alpha layer, which §13 judges by eye (`FOG_COMPAT_LIFT` 0.2 in `fog_card.gdshader` is the best compromise across views).
