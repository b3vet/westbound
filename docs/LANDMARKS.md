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
| `src/world/landmarks/landmark.gdshader` | | The world shader plus bending and atlas text |
| `src/core/tuning/landmark_tuning.gd`, `data/tuning/landmarks.tres` | `LandmarkTuning` | Every number (spans, heights, clearances, pools, atlas) |
| `src/world/landmarks/dev/landmark_preview.tscn` | | Review scene |

## Placement

- Every `CHECKPOINT` feature gets a build **at the checkpoint line**. Its style is the feature's `tag`, else the `landmark_style` of the biome whose leg ends there (`biome_director`), else `default_style`. `style_override` forces one (previews).
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

- **Roadside overlap:** the roadside does not skip landmark ranges. Median light poles every 50 m stand at every checkpoint line, inside the gantries' middle columns, and inside the tunnel's central wall. The tunnel's cover is 11.6 m high so the lamp heads stay inside the hill. Billboards, fences and the farmland fields can intersect the booths and the tunnel hill. Roadside gantries can occasionally land inside a landmark.
- **Checkpoint tag:** `ProceduralRoadPath` leaves the CHECKPOINT `tag` empty, so the style comes from the biome. Farmland is `toll_gantry`, so until biomes 2–6 exist every run shows toll gantries. The preview shows the others.
- **Road under the builds:** the bridge has no water or gap below it, and the tunnel does not lower the road or drop lanes. Both are out of scope (Phase 6).
- **Units:** sign distances are metric (`KM`/`M`) whatever the `units` setting.
