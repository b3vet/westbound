# Checkpoint landmarks and warning signs (WP5.3)

Spec: "Legs and checkpoints" (a landmark at every checkpoint; warning signs at 1 km and 500 m), "World → Checkpoint landmarks" (express toll gantry, suspension bridge, big sign gantry with the leg name and distance, tunnel portal), "Night lighting" (retro-reflective signs), "Performance budget". Contracts: [CONTRACTS.md](CONTRACTS.md) §2, §3, §13.

| File | Class | Role |
| --- | --- | --- |
| `src/world/landmarks/landmarks.gd` | `Landmarks` | World-system node: `setup(ctx, road, origin)`, `update_view(focus_s)`; pools, placement, floating origin |
| `src/world/landmarks/landmark_builds.gd` | `LandmarkBuilds` | The four placeholder builds and the warning sign (procedural low-poly) |
| `src/world/landmarks/landmark_mesh_builder.gd` | `LandmarkMeshBuilder` | Flat-shaded faces, boxes, beams, sweeps and text strips in road space |
| `src/world/landmarks/landmark_template.gd` | `LandmarkTemplate` | One built mesh plus its reach along s and its text lines |
| `src/world/landmarks/landmark_section.gd` | `LandmarkSection` | The road cross-section a build is made for (cache key) |
| `src/world/landmarks/landmark_text.gd` | `LandmarkText` | The words: `CHECKPOINT 1 KM`, `LEG 3 — DESERT MESAS`, `NEXT CHECKPOINT 3.5 KM` |
| `src/world/landmarks/landmark_text_atlas.gd` | `LandmarkTextAtlas` | Sign text rasterised on the CPU into one R8 atlas |
| `src/world/landmarks/landmark_clearance.gd` | `LandmarkClearance` | WP5.5: the builds' and signs' ground zones, which the roadside keeps clear |
| `src/world/landmarks/landmark.gdshader` | | The world shader plus bending and atlas text |
| `src/core/tuning/landmark_tuning.gd`, `data/tuning/landmarks.tres` | `LandmarkTuning` | Every number (spans, heights, clearances, pools, atlas) |
| `src/world/landmarks/dev/landmark_preview.tscn` | | Review scene |

## Placement

- Every `CHECKPOINT` feature gets a build **at the checkpoint line**. Its style is the feature's `tag`, which the biome director fills from the biome whose leg ends there (WP5.5, see *Checkpoint styles*). Without a director it is `default_style`. `style_override` forces one (previews).
- Every `SIGN` feature tagged `ProceduralRoadPath.SIGN_CHECKPOINT` gets a panel right of the guardrail (`sign_setback_m`), facing traffic: `CHECKPOINT 1 KM` / the next leg. Legs are named by their biome ("each leg is one biome"): `LEG 2 — FARMLAND PLAINS`, or `LEG 2` without a biome name.
- The window is `[focus − keep_behind_m, focus + view distance + place_margin_m]`, re-queried every `update_step_m`. A build is placed when any of it enters and recycled when all of it has left. Between steps `update_view` does nothing.
- If a build reaches past the generated road, the road is generated that far (director rate, as RoadBuilder does).

## Pools and cost

- Every kind is built **once** at warm-up (the first `setup`) for the road's cross-section, and cached across retries. A checkpoint with another lane count gets its own build, made once and cached.
- Each kind has `landmarks_per_kind_count` (2) MeshInstance3Ds and there are `sign_pool_count` (4) sign instances. Each has its own ShaderMaterial. Nothing is created after warm-up. Retry re-runs `setup` and only releases the pool.
- **Draw calls:** one surface per instance. A landmark plus its two signs is **3 draw calls**.
- **Triangles:** toll gantry ~0.8k, bridge ~3.3k, sign gantry ~0.3k, tunnel ~0.6k, sign ~0.1k.
- **CPU:** warm-up ~20 ms once (desktop). A placement frame (stations, text, atlas upload) is under 2 ms (desktop, `test_update_view_cost`). Glyphs of a new font size are rasterised the first time that size is used.

## Bending along the road

Builds are authored in road space: `x = d`, `y = height`, `z = −(s − checkpoint s)`. Geometry along s is split every `bend_station_step_m`. At placement the road is sampled at stations every `bend_station_step_m` along the build, relative to its 64-bit anchor (the road at the checkpoint). `landmark.gdshader` moves each vertex to `station(s) + right(s)·d + up·height`, so a 360 m bridge follows a 1,200 m curve without rebuilding its mesh. Normals rotate with the heading. `custom_aabb` covers the bent build. Signs are rigid (`station_count = 0`, node transform).

**Floating origin:** each instance node sits at `anchor − origin`. On `Events.origin_shifted`, the live nodes move there (`reset_physics_interpolation`). Stations are relative to the anchor, so they never change.

## Clearances

Below `overhead_clearance_m` (5.5 m), no triangle lies over a lane or a shoulder. Everything down there stays within the median barrier (`|d| ≤ median_barrier_d`: the toll gantry's middle column, the sign gantry's inner upright, the tunnel's pier and central wall) or beyond a guardrail (`|d| ≥ guardrail_d`: bridge legs, tunnel walls, booths, uprights, signs). `test_structures_stay_outside_the_drivable_area` checks every build at 2, 3 and 4 lanes.

## Text and look

- **Text:** the engine's default font (Open Sans SemiBold, embedded in Godot) is rasterised through the TextServer's glyph cache into regions of one 1024² R8 atlas with mipmaps. Each pooled line owns a region sized to its strip's aspect. Text is set smaller when it is too wide. This works headless and on the web. The shader samples coverage and mixes the lettering colour with the panel colour before lighting and fog, so the text is graded, fogged and lit exactly like its sign on both renderers. It needs no Label3D and no extra pass.
- **Retro-reflective faces** (emissive class 1: sign faces, borders, lettering):
    - They glow `retro_emissive_factor` × the colour script's reflector ramp.
    - The player's fake light (`wb_player_light_*`) brightens them `retro_light_factor` × more.
    - By day they get `retro_day_fill_frac` of full sun whichever way they face. The player drives into the sun, so every sign face is on the shadow side, and without the fill they would read as black.
- **Night:** lane lights, canopy panels, tunnel lamp strips and the bridge's cable lamps use the street-lamp ramp. The bridge's tower beacons use the headlight ramp.
- **Parity:** Compatibility and Mobile snaps differ by about 1/255 on average (day and sunset) and about 3/255 at night. The night difference is mostly the car's additive glows.

## Preview

```
tools/snap.sh src/world/landmarks/dev/landmark_preview.tscn --renderer=both \
    --kind=toll_gantry|suspension_bridge|sign_gantry|tunnel_portal --dist=70 --cam=chase|hood|high|side \
    --sweep=sky_t:0.2,0.5,0.66
```

`--dist` is metres before the checkpoint; the warning signs stand at 1000 and 500. Other options: `--lights=<fake-light gain>`, `--roadside=false`, `--seed=N`, `--lane=0..2`, `--dump_atlas=<png>`.

## Open items

- ~~**Roadside overlap**~~ and ~~**Checkpoint tag**~~: done in WP5.5 (below).
- **Road under the builds:** the bridge has no water or gap below it, and the tunnel does not lower the road or drop lanes. Both are out of scope (Phase 6).
- **Units:** sign distances are metric (`KM`/`M`) whatever the `units` setting.

## Roadside clearance (WP5.5)

No roadside prop stands inside a landmark or a warning sign. That includes the median light poles, reflector and guardrail posts, fences, the field grid, scatter props, billboards and roadside sign gantries.

- **Zones:** `LandmarkBuilds.clearance_zones(kind, section, tuning, out)` lists where each build stands on the ground. `sign_clearance_zones(sign_d, tuning, out)` does the same for a warning sign. Each zone is five floats: s from and to (relative to the anchor), d from and to (signed, from the reference line), and a floor height. Only things reaching above the floor collide. The lateral bounds use the builds' own dimensions, which are named constants in `LandmarkBuilds` shared by the build code.
    - **Toll gantry:** the beam and columns across the whole road (the middle column is on the median), plus both booth islands with their canopies.
    - **Bridge:** the tower footings, the walkway's outer part with the suspenders, the backstays and their anchor blocks. The median is clear, so the median poles stay under the bridge. Guardrail and reflector posts stay on the walkway.
    - **Sign gantry:** from the median upright to the outer footing, on the player's side only.
    - **Tunnel:** the pier and central wall on the median, from the portal plate to the exit face. The walls, shell and hill (with its hipped ends) cover `[wall, hill foot]` from 25 m before the portal to 145 m after it. The hill zone's floor is `clearance_ground_cover_m` (1 m), so the flat crop tiles run on under the hill, which hides them, while trees, yards, fences and posts do not.
    - **Warning sign:** its two posts from the ground, and the panel above `sign_panel_bottom_m`, so the fence runs on under it.
- **`LandmarkClearance`:** a pure function of the road's CHECKPOINT and checkpoint SIGN features, each checkpoint's style (`resolve_style`: the tag, which the director fills, else `default_style`) and `LandmarkTuning`. It is deterministic and known before the Landmarks node places anything. Each zone grows by `clearance_margin_m` (1 m) along s.
    - **Queries:** `blocks_upright(aabb, s, d, yaw, sx, sy, sz)` checks a mesh instance. At yaw 0 or PI it uses the mesh's box. Otherwise it uses the footprint circle. `blocks_segment(aabb, s0, s1, d)` checks fence segments. `zones_in(s0, s1, out)` lists the zones.
    - **Cache:** zones are cached for the prepared range ± `clearance_cache_pad_m`. A refill is the only allocation: one `features_in` query, generating the road that far first (director rate, as Landmarks does). The cache also refills when `BiomeDirector.plan_version` changes (forks).
- **`Landmarks.exclusion_zones(s0, s1, out)`** lists them from its own `clearance`.
- **Roadside:** it builds its own `LandmarkClearance` at setup from the same inputs: the road, `biome_director` and `Tuning.landmarks`. It prepares it for the window (± the longest cell) whenever the window moves. Every placement helper in `RoadsideLayer` (`_place`, `_place_on_grade`, `_place_segment`) asks it and skips blocked instances (`layer.cleared`, `Roadside.cleared_count()`). The skip comes after all of the cell's Rng draws, so everything else is bit-identical to before. `clear_landmarks = false` turns it off. `landmark_style_override` mirrors `Landmarks.style_override` in previews (`landmark_preview --clear=false` shows the old overlap).
- **StreetLampPools:** they ask the same question for each median pole (the pole mesh's bounds, s = k × spacing, d = 0), so the removed poles get no pools. They build their clearance at setup, finding the director in `BiomeDirector.GROUP` (or in `biome_director`).
- **Effect:** the median pole at the toll and sign gantries and the three poles through the tunnel are gone, with their pools. Reflector posts are gone at the booths and along the tunnel walls (guardrail posts stay under their rail), and fences at the booths and the tunnel hill. Trees, yards and billboards are gone in the hill, and roadside gantries at any landmark.
- **Tests:** `tests/world/test_landmark_clearance.gd`:
    - the zones cover every build's vertices on the median and in the scenery band, at 2, 3 and 4 lanes
    - zones exist before placement
    - the cache holds and queries allocate nothing
    - across 10 checkpoints (every style), no instance footprint lies in a zone, and every instance away from the zones matches the roadside without clearance
    - the median poles go exactly where expected
    - same seed, same result whatever the drive
    - the lamp pools match the kept poles

## Checkpoint styles (WP5.5)

- **Data:** `BiomeDef.landmark_styles: Array[StringName]` (new) lists several styles. When it is empty, the biome uses `landmark_style` as before. Farmland lists all four: toll gantry, sign gantry, suspension bridge, tunnel portal. `landmark_style` stays `toll_gantry`.
- **Pick:** `BiomeDef.checkpoint_style(leg, seed)` cycles through the list by leg index from a start picked by the run's props stream (`rng_props.derive(&"landmark_styles")`) mixed with the biome id. Any four consecutive farmland legs show all four styles, and two legs in a row never repeat one. The same seed always gives the same styles.
- **Tag:** `BiomeDirector.checkpoint_style(leg, s)` gives the style of the biome whose leg ends at s. `tag_checkpoints(features)` fills the tag of every untagged CHECKPOINT feature (CONTRACTS §3). The road creates its features per query, so each consumer tags its own copies: Landmarks after its window query, and LandmarkClearance at a refill. `ProceduralRoadPath` is unchanged.
- **Tests:** `tests/world/test_landmark_styles.gd` covers farmland's four styles, the cycle and its seeded start, single-style biomes, the director tagging the real road's features deterministically (all four in the first four legs), and the landmarks building the tagged style while the clearance resolves the same one.
- **Snaps:** `tools/snap.sh src/run/run.tscn --renderer=both --s=<cp − 200> --speed_kmh=60 --seconds=3 --sky_t=0.25`. With the snap seed, the first four checkpoints are 3500 sign gantry, 7000 suspension bridge, 10500 tunnel portal and 14000 toll gantry.

