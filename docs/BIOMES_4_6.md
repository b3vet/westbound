# Biomes 4–6: coastal highway, city at night, valley fog (WP6.4b)

Spec: "World, road and visual direction" (Road: roadside rhythm; Color script: biome tint offsets; Sky: horizon silhouette cards with parallax; Biomes 4–6; "every biome must look good across the whole color script"), "Night lighting", "The journey goal" (the coast is the destination), "Performance budget". Contracts: [CONTRACTS.md](CONTRACTS.md) §2, §10 (BiomeDef), §13 (look contract). WP6.4a builds the biome sequencing framework (and `docs/BIOMES.md`); this file is the biomes 4–6 part (fold it into `BIOMES.md` as a "Biomes 4–6" section when both are merged).

| Biome | File | Signature |
| --- | --- | --- |
| 4 Coastal highway | `data/biomes/coast.tres` | The ocean below the road on the player's side, with surf, sea stacks and a lighthouse islet; road-cut rock cliffs, coastal houses, palms and scrub on the land side; the sun sinks into the sea; headlands and islands on the horizon; cooler tint; 4 lanes |
| 5 City at night | `data/biomes/city.tres` | Blocks of glass towers, brick apartment slabs, warehouses and mid-rises whose windows light up at night; distant skyscrapers; sound walls; neon billboards ("Volt Noodle Bar", "Starline Motel", invented); elevated highway stretches over the lowered street level; a lit skyline horizon; grey-blue concrete and glass by day; 4 lanes |
| 6 Valley fog | `data/biomes/valley_fog.tres` | Conifer and mixed forests (copses), meadows, farmhouses and barns, a rail fence, river glimpses, low fog layers and mist curtains (thickest at dawn, dusk and night), misty ridges on the horizon, a dawn-friendly tint; 3 lanes |

## Files

| Path | Class | Role |
| --- | --- | --- |
| `src/road/biome_def.gd` (block `WP6.4b`) | `BiomeDef` | `water`, `elevated`, `fog_cards`, `horizon_def` (all optional) |
| `src/world/biome_features/biome_feature.gd` | `BiomeFeature` | Base of the three feature nodes: windows in steps, background build of the next window, floating origin |
| `src/world/biome_features/feature_mesh.gd` | `FeatureMesh` | Vertex arrays of one build |
| `src/world/biome_features/ground_drop_mesher.gd` | `GroundDropMesher` | `RoadChunkMesher` with the ground ribbon lowered (the RoadBuilder hook) |
| `src/world/ocean/water_def.gd`, `water_plan.gd`, `water_ribbon.gd` | `WaterDef`, `WaterPlan`, `WaterRibbon` | Ocean / river data, shoreline plan, the node |
| `src/world/elevated/elevated_def.gd`, `elevated_plan.gd`, `elevated_sections.gd` | `ElevatedDef`, `ElevatedPlan`, `ElevatedSections` | Elevated stretches data, plan (`drop_at`), the node |
| `src/world/fog_cards/fog_cards_def.gd`, `fog_cards.gd` | `FogCardsDef`, `FogCards` | Low fog data, the node |
| `src/world/horizon_sets/horizon_set_def.gd` | `HorizonSetDef` | A biome's horizon set; `apply(material)` |
| `assets/shaders/water.gdshader` (+ `materials/water.tres`) | | Faceted animated water, sky/sun reflection, sea-side land |
| `assets/shaders/fog_card.gdshader` (+ `materials/fog_card.tres`) | | Alpha-blended mist cards |
| `assets/shaders/world_windows.gdshader` (+ `materials/world_windows.tres`) | | `world.gdshader` plus lit windows (emissive class 4) |
| `assets/shaders/horizon_biomes.gdshader` | | `horizon.gdshader` superset: islands, headlands, sea masks, mist, lit windows |
| `tools/props/build_props_4_6.gd`, `biome_prop_builder.gd`, `palette_biomes_4_6.tres` | `BiomePropBuilder` | Prop generator, builder extras, the biome colors |
| `assets/props/{coast,city,valley}/*.res` | | Generated props |
| `src/road/dev/biome_preview.tscn` | | Review scene (real road, roadside, features, sky, parked traffic) |

## Props

Generated like farmland's (`tools/props/build_props.gd`): flat-shaded, palette vertex colors, `world.tres`, deterministic.

```
tools/godot.sh --headless --path . --script res://tools/props/build_props_4_6.gd
```

- **Palette:** the style guide (`assets/palette/palette.tres`) plus 31 biome colors in `tools/props/palette_biomes_4_6.tres` (sand, rock, palm, glass, concrete, neon, conifer, meadow, ...). `BiomePropBuilder.merged_palette()` joins them; names never shadow the style guide (tested). Folding them into `palette.tres` is the palette owner's call.
- **Emissive:** lamps, the lighthouse lantern and neon tubes use class 2 (street lamp: bright at night, the colored tube by day). City windows use **class 4** of `world_windows.gdshader`: the glass color by day, plus `window_glow` × `wb_emissive_streetlamp` × UV2.y (the room's brightness, 0 = dark) at night. Buildings are `world_windows.tres`; the tests accept it next to `world.tres`.
- **Footings:** every city prop reaches 12 m below its origin (`FOOTING_M` ≥ `ElevatedDef.height_m`), so beside an elevated stretch it stands on the lowered ground.
- **Budgets:** ≤ 400 triangles per mesh (tested). Forests are copses of 8–9 trees in one mesh (144 triangles), so woods cost few instances.

## World features

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

### WaterRibbon (coast ocean, valley river)

`WaterDef` per biome; `WaterPlan` gives the shoreline offset at s (the def's offset, a meander, the sweep in and out over `arrive_m` at the biome's ends, or none; river cells show with `span_chance_frac`).

- **Flat water** (`drop_m` = 0, the river): shore strip, water, far bank, `lift_m` above the road plane.
- **Sea slope** (`drop_m` > 0, the coast): a road-level strip (`shore_offset_m`), then the land falls over `slope_run_m` in a craggy slope to the sea level (the road's elevation smoothed over ±`level_smoothing_m`, minus `drop_m`, at least `min_drop_m` below the road), then the beach, surf and sea, flat. A low chase camera sees water at road level only as a thin band at the horizon; below the road the ocean fills its side of the view.
- **Islets:** sea stacks and a lighthouse islet (`islet_*` fields) are copied into the water mesh at the sea level: no extra draw call. Their lantern glows (the water shader takes the emissive class from UV2.x on land vertices).
- **Shader:** every vertex bobs on its own phase; fragments take their triangle's flat normal from screen-space derivatives, light it with the shared sun, and reflect the shared sky (`wb_sky_color`) and two sun lobes (sparkles and the path) by Fresnel. `set_time()` fixes the wave clock (snaps, parity). A depth pull (`depth_pull_frac`) keeps the water above the ground ribbon at range.
- **Horizon:** `water.horizon_material = <the sky's Horizon material>` feeds `sea_dir` (toward the sea, from the road heading 300 m ahead) to `horizon_biomes.gdshader`, so headlands stay on the land side and islands on the sea side.
- **Side:** the coast's ocean is on the **right** (the player's carriageway: from the left the opposite carriageway hides it) and must be on the **sun's** side, so the sun sinks into the sea. The road plan picks the sun side at random per seed and keeps it 15–40 km, so the road generator must keep the sun right of the axis through coast legs (needs below). The preview picks such a seed.
- `ground_drop_at(s, side)`: how far the ground ribbon must go down on that side (below the sea), for the mesher hook.

### ElevatedSections (city)

`ElevatedPlan.drop_at(s)`: per `cell_length_m` cell, at most one stretch (chance, length, position from the seed), whole inside one biome span, never over a checkpoint landmark or warning sign (`LandmarkClearance`, when given). The ground falls away with a smoothstep over `ramp_m` to `height_m`; the road never moves (road space, traffic, scoring are untouched). The node draws the deck edge beyond each guardrail, parapets, girder fascia, the deck's underside, a hammerhead pier under each carriageway every `pier_spacing_m`, and the ground under the road.

### FogCards (valley)

Per (cell, side), a bank of `layer_count` horizontal translucent cards stacked above the ground and `curtain_count` vertical mist curtains, from `setback_min_m` beyond the scenery line outward (never over the carriageway or its clear zone), more likely and denser where the road runs through a dip (`valley_factor`). The shader fades the edges, breaks the cards up with world-anchored noise, clears them within `near_clear_m` + `near_fade_m` of the camera, and thins them with a high sun (`midday_factor`). Color: the fog color with the sun's in-scatter (`wb_fog_color_dir`), a touch brighter. Transparent pass, `render_priority` 1 (after the sky, §13).

### Horizon sets

`BiomeDef.horizon_def` (a `HorizonSetDef`) resolves `horizon_set`: the base shader's per-layer parameters plus the extensions of `horizon_biomes.gdshader` (a superset of `horizon.gdshader`: same mesh, uniforms, styles 0–4 and output):

| Set | Layers (near → far) |
| --- | --- |
| `coast_headlands` | headlands (land side), islands (sea side), mountains (land), mountains (land) |
| `city_skyline` | skyline with lit windows, skyline with lit windows, hills, mountains |
| `valley_ridges` | hills, hills, mountains, mountains, each with its lower part in mist |

`set_def.apply(material)` switches the material to `horizon_biomes.gdshader` when the set needs it and writes every uniform. `SkyRig.set_horizon_layer()` still works on the new shader.

## Wiring (for the sequencing WP / orchestrator)

1. **World nodes:** add `WaterRibbon`, `ElevatedSections` and `FogCards` to the run's world stack with the run's `BiomeDirector`, `setup(ctx, road, origin)` and `update_view(s)` per frame (as Roadside). `ElevatedSections.clearance` = the run's `LandmarkClearance` (set before setup). Keep the road generated from `s − road.roadside_behind_m` to the window end (as for Roadside).
2. **Ground hook:** RoadBuilder's mesher must be a `GroundDropMesher` with `drop_at = elevated.plan.drop_at` and `field_drop_at = water.ground_drop_at` (the features must be set up before the builder builds). Without it the city's elevated stretches stand on the ground and the coast's ground ribbon covers the sea. `src/road/dev/biome_preview.gd` shows it (it swaps the builder's private `_mesher`; the builder should expose a setter).
3. **Sky:** on a biome change, `biome.horizon_def.apply(<Horizon material>)` (crossfade is WP6.4a's), `set_biome_tint_offset(world_tint_offset)`, and `water.horizon_material = <Horizon material>`.
4. **Sun side at the coast:** the road plan must keep the sun right of the axis (plan sun side −1, the water's side +1) through coast legs, switching before the leg if needed.
5. **Roadside:** no common billboards on the water side where `WaterDef.drop_m` > 0 (they would stand on the sea slope). Biome props already stay on the land side.
6. **Lane counts:** coast 4, city 4, valley 3 (`BiomeDef.lane_count`); the preview schedules them.

## Review and budget

```
tools/snap.sh src/road/dev/biome_preview.tscn --biome=coast --renderer=both --sweep=sky_t:0,0.38,0.5,0.58,0.66
tools/snap.sh src/road/dev/biome_preview.tscn --biome=city --cam=side --sky_t=0.66
tools/drawcalls.sh src/road/dev/biome_preview.tscn --biome=valley_fog --traffic=false
```

Options: `--biome`, `--seed`, `--s`, `--cam=chase|far|driver|high|side|sea|back` (chase and far are the game's rigs), `--sky_t`, `--tier`, `--traffic`, `--features`, `--ground_drop`, `--horizon`, `--lanes`, `--time`, `--night_lights`, `--label`.

**Draw calls** (`tools/drawcalls.sh`, chase, Medium, no traffic, 3D only): farmland 26 (road 5, roadside 18, sky 3); coast 20 (water 1, road 5, roadside 11, sky 3); city 25 (elevated 1, road 6, roadside 15, sky 3); valley 27 (water 1, fog 1, road 5, roadside 17, sky 3). Roadside worst over 12 km at Medium (tests): coast 17 / 26k triangles, city 16 / 44k, valley 19 / 53k (share 25 / 60k). With traffic (~33k at leg 8) every biome stays under 150k.

**Parity** (`tools/parity.sh`, chase at sky_t 0 / 0.38 / 0.5 / 0.66 / 0.85 and high views): the coast (water, horizon) and the city (windows, horizon, elevated) pass everywhere in the gameplay view; the coast's water-dominated high view passes. Known residues, none from a new opaque shader:
- the valley's chase view at sky_t 0 (p99.9 16): dense forest silhouettes against the bright morning fog on the unchanged `world.gdshader` (it stays 16 with the features and the horizon set turned off, `--features=false --horizon=false`);
- the city's night side view (p99.9 15): hundreds of sub-pixel lit windows and stars (the window shader alone matches exactly in an isolated test);
- the valley's fog cards seen from high above by day (p99.9 15): an alpha layer, which §13 judges by eye (`FOG_COMPAT_LIFT` 0.2 in `fog_card.gdshader` is the best compromise across views).
