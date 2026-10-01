# Westbound — Art production brief

Sep 30, 2026 · for the art track (plan §7 "Parallel art track", ART1–ART5) · companion to [`WESTBOUND HANDOFF.md`](../WESTBOUND%20HANDOFF.md) (the **spec**), [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) (the **plan**) and [`CONTRACTS.md`](CONTRACTS.md) §13 (the **look contract**)

This brief is for a Claude Code agent with Blender (Blender's Python API or a Blender MCP) that builds Westbound's 3D assets in-house. It starts with the player cars (designs, models, interiors for the hidden cockpit camera) and then covers every other 3D asset the game uses. Every claim about the game below comes from the code and data in this repo; the file is cited next to it. If this brief and the repo disagree, **the repo wins**: flag the difference in your handoff note and don't work around it.

Contents: [1 Purpose](#1-purpose-and-how-to-use-this-doc) · [2 Art direction](#2-art-direction) · [3 Technical contract](#3-technical-contract-hard-rules) · [4 Asset inventory](#4-asset-inventory) · [5 Production order](#5-production-order) · [6 Handoff protocol](#6-handoff-protocol) · [7 Appendix](#7-appendix)

---

## 1. Purpose and how to use this doc

### 1.1 Who does what

| Role | Where | Does |
| --- | --- | --- |
| **Blender agent** (you) | The owner's PC with Blender and a clone of this repo | Designs and models the assets. Writes the Blender batch scripts in `tools/blender/`. Exports `.glb` files and sidecar JSON. Checks them in Blender against §3. Commits on an art branch (§6). |
| **Game-side agent** | The Linux container (Godot 4.7 headless, Xvfb, Mesa) | Owns the import and conversion code, the data files (`data/**`), the tests, snaps and draw-call checks. Registers every delivered asset and runs the gates (§6.3). |
| **Orchestrator** | Same container | Reviews and merges, owns shared files (`project.godot`, `CLAUDE.md`, the plan, root `data/tuning.tres`). |
| **Owner** | | Approves designs (§4.1 briefs), answers the open questions (§7.6), plays the builds. |

**Your owned paths** (create or modify only these): `tools/blender/**`, `art/**` (new, see §3.10), `assets/cars/<car id>/**` (a new folder per car, the three remodels included, plus `calib_box/`), `assets/cars/rims/**`, and new rows in `assets/LICENSES.md`. Everything else (`src/**`, `data/**`, `tests/**`, `assets/shaders/**`, `assets/palette/**`, existing `assets/props/**` and `assets/traffic/**`) belongs to the game side. If you need a change there, write it in your handoff note as `needs: …` (CLAUDE.md, "Multi-agent workflow").

### 1.2 How to read this doc

1. §2 once, for the look.
2. §3 before any modelling: the hard rules (axes, names, materials, budgets, export). Most of them are checked by tests that fail the build.
3. The §4 section for the asset you are making: purpose, where it appears, current state, budgets, required nodes, and an acceptance check.
4. §5 for the order and §6 for how to hand back.

### 1.3 What exists today, and what the game side must add first

The game is feature-complete on placeholders. The **game side of the pipeline is built** (WP-ART-G, Sep 30, 2026: G1–G9 done, see §3.11 for the entry points); `tools/blender/` is empty (only `.gitkeep`): the Blender side is yours. Status of each piece:

| Piece | State | Where |
| --- | --- | --- |
| Modular car convention (node names, stubbing, draw merging) | ✅ built | `src/vehicle/car_model.gd` (`CarModel`) |
| Car import script (`EditorScenePostImport`) | ✅ **two paths.** Placeholders (no `Body` node, no `"modular"` in the sidecar): the old bake, unchanged. **Modular** (sidecar `"modular": true` or a `Body` node in the file): keeps your node tree and converts every mesh by material name (G1, §3.11) | `assets/cars/car_import.gd` → `tools/art/car_modular_import.gd` |
| Car validation test | ✅ built | `tests/unit/test_check_car_assets.gd` (spec's `tests/check_car_assets.gd`) |
| Blender batch scripts (ART2) | ❌ missing: yours to write (§3.12, §5 P0) | `tools/blender/` |
| Calibration assets (game side) | ✅ a generated modular test car (every node, light, marker, the interior, one face per palette colour), its LOD1, a rim, a traffic model and a prop swatch, run through G1–G9 by the tests and snapped on both renderers. Tests only (never in the roster). Build yours to the same shape (§5 P0) | `tools/art/art_calib.gd`, `tools/art/make_calibration.gd`, `tests/art/fixtures/` |
| Prop and traffic pipeline from `.glb` | ✅ built (G2, G3): `tools/art/convert.gd` writes the same `.res` meshes the procedural builders write (loaders unchanged), and the builders keep a converted mesh. Landmarks and set-piece props are still procedural (G10, P7) | `tools/art/convert.gd`, `tools/art/art_convert.gd` |

The game-side tasks this brief depends on are numbered **G1–G11** (full list in §3.11). **G1–G9 are done** (WP-ART-G): the modular car import, the prop and traffic converters, model interiors in the cockpit view, authored rims, the hood marker, the car-id save migration, LOD1 use and the colour round trip, each proven with a game-side calibration asset. G10 (landmark and set-piece kits) waits for P7; G11 is per phase. Phase P0 (§5) still starts with a calibration asset from you, which the same tests then check.

### 1.4 Tools you can and cannot run on the PC

- **Blender side:** everything in `tools/blender/` (your scripts), Blender's own renders for self-review (§3.12.1).
- **Godot side:** `tools/godot.sh` downloads a **Linux x86_64** binary. On Windows or macOS, set `GODOT=/path/to/godot4.7` to use a local Godot 4.7 editor; then `tools/test.sh --filter=check_car_assets` works if you have bash (Git Bash or WSL). `tools/snap.sh`, `tools/parity.sh` and `tools/drawcalls.sh` need `xvfb-run` and Mesa (Linux only). If you can't run them, say so in the handoff; the game-side agent runs them in the container.

---

## 2. Art direction

### 2.1 The style

From the spec (Decisions log "Art"; World, road and visual direction; Art pipeline):

- **Stylized, flat-shaded low-poly. Not realism.** One normal per face, no smoothing. "Chunky proportions, silhouette first."
- **No textures.** "No photo textures." Colour is flat per face, picked **by name** from the style palette (§2.2). The only texture in the vehicle shader is a shared matcap for paint sheen, which you don't author (`assets/shaders/materials/vehicle_matcap.tres`).
- **Colour grading is the star.** One value, the sky timeline `sky_t`, drives every colour on screen: sky, fog, sun light, ambient, the shadow-side tint and the night emissive ramps (`data/color_script.tres`, pushed as `wb_*` shader globals, CONTRACTS §13). Your asset has one "true" colour per face; the game lights and grades it from morning through golden hour, sunset, dusk, night and dawn. **Mood comes from the color script, not the palette** (`assets/palette/README.md`).
- **Keep colours mid-value** so they read at noon and at dusk (palette README). Avoid near-white and near-black for large areas, except where the palette already has them (`ink`, `white`).
- **Night has no real lights.** Lamps, windows, reflectors and signs are emissive faces that follow the colour script's ramps (docs/NIGHT.md). Model them as separate faces with their own material (§3.3).
- **Reference game:** the world style of the owner's [cool_drive](https://github.com/b3vet/cool_drive).

### 2.2 The palette

The style guide sheet (ART1) is `assets/palette/palette.tres` (`WBPalette`: 34 named sRGB colours; the swatch image `assets/palette/palette.png` is generated from it). Biome work added two more named sets that props already use. **Every colour you use must have one of these names** (the converters in §3.11 look colours up by name). New colours go through the game side (`needs: palette colour <name> #rrggbb`).

**Style palette** (`assets/palette/palette.tres`):

| Group | Name → sRGB hex |
| --- | --- |
| Neutrals and road furniture | `ink` #1c1c21 · `asphalt` #3d3d42 · `concrete` #a8a399 · `concrete_shade` #807d78 · `steel` #99a1a8 · `steel_dark` #5c616b · `white` #f0ede3 · `cream` #f2e3bd · `sign_green` #176640 · `sign_blue` #1f4c94 · `hazard_yellow` #fac729 · `reflector_amber` #ff9e1f · `reflector_red` #d91f1a · `lamp_warm` #ffdb94 |
| Land and crops | `wheat_gold` #deab4a · `wheat_light` #f2cf78 · `wheat_shade` #b28036 · `straw` #e6c785 · `soil` #785436 · `soil_dark` #543b26 · `grass` #788f40 · `grass_dry` #a8a159 · `crop_green` #5c8033 · `leaf` #3b5e2b · `leaf_dark` #264221 · `bark` #5c402b |
| Buildings | `barn_red` #a32b21 · `roof_slate` #4c4f59 · `silo_metal` #c2c2bd · `sky_pale` #b2d1e0 |
| Invented-brand accents | `brand_orange` #f57521 · `brand_teal` #1a9499 · `brand_navy` #212b59 · `brand_pink` #ed6b85 |

**Biome colours, coast / city / valley** (`tools/props/palette_biomes_4_6.tres`, 31 names): `sand`, `sand_wet`, `rock_light`, `rock`, `rock_dark`, `palm_frond`, `palm_frond_dark`, `palm_trunk`, `scrub`, `scrub_dry`, `stucco`, `terracotta`, `glass`, `glass_dark`, `concrete_blue`, `concrete_dark`, `brick`, `board_dark`, `neon_pink`, `neon_cyan`, `neon_violet`, `neon_lime`, `conifer`, `conifer_dark`, `broadleaf`, `broadleaf_light`, `meadow`, `meadow_light`, `flower_yellow`, `timber`, `roof_dark`.

**Biome colours, desert / canyon** (`tools/props/biome_colors.gd`, `BiomeColors.COLORS`, 18 names): `red_rock`, `red_rock_light`, `red_rock_dark`, `rock_band_pale`, `mesa_top`, `sand`, `sand_dark`, `cactus`, `cactus_dark`, `cactus_flower`, `sage`, `scrub`, `dead_wood`, `canyon_rock`, `canyon_rock_dark`, `canyon_rock_pale`, `pine`, `pine_dark`. (`sand` and `scrub` exist in both biome sets with different values. Use the set of the biome you are building.)

**Vehicle colours** that are not palette entries but are fixed in code (use these names in §3.3):

| Use | sRGB (0–1) | Source |
| --- | --- | --- |
| Headlight lens | (1.0, 0.95, 0.82) | `CarModel.COLOR_HEADLIGHT` |
| Tail lamp | (0.85, 0.04, 0.04) | `CarModel.COLOR_TAILLIGHT` |
| Brake lamp | (1.0, 0.12, 0.08) | `CarModel.COLOR_BRAKE` |
| Blinker | (1.0, 0.55, 0.05) | `CarModel.COLOR_BLINKER` |
| Reverse | (0.95, 0.96, 1.0) | `CarModel.COLOR_REVERSE` |
| Car glass | (0.08, 0.10, 0.13) | `CarModel.COLOR_GLASS` |
| Paint shade multipliers | 1.0 / 0.8 / 0.55 | `tools/traffic_models/build_traffic_models.gd` (`paint`, `paint_shade`, `paint_dark`) |

**Player paints** (the garage's 12, `data/cars/garage/catalog.tres`): FACTORY (the car's own `default_paint`), SUNSET #fa731f, PEARL #e6e3db, TEAL #0d8c8c, MIDNIGHT #141f52, FLAMINGO #f2528c, CANARY #f7cc1f, GRAPHITE #333536, VIOLET #7338bf, MINT #73e0a8, GOLD RUSH #cc9933, OBSIDIAN #0d0d0f. **Every player car must look good in all 12**, from obsidian to pearl, so no car's design may depend on its paint colour (§4.1.2).

**UI colours** (spec, Design system) are for 2D only: ink #0b1020, panel #111a30, text #f4f7ff, gold #ffd24a, hot #ff5a4d. The accent follows the sky. Don't use purple/violet as a default accent (spec anti-pattern).

### 2.3 What reads on a phone at speed

The numbers that set the level of detail (from `data/tuning/quality.tres`, `camera.tres`, `progression.tres`, `tools/drawcalls.sh`'s default canvas):

- The owner's iPhone canvas is about 1361 × 720; the 3D view renders at **0.75** of that on Medium (about 540 px tall), with **no MSAA** on Medium and web. Vertical field of view is **62° → 78°** with speed.
- That gives about **450 / D pixels per metre** at distance D (at 62°). Chase camera: 7 m behind and 3.6 m above the player car, so the player car is ~100 px wide and 5 cm ≈ 3 px. A traffic car 50 m ahead is ~17 px wide; at 150 m, ~6 px.
- **Garage turntable** (`data/tuning/progression.tres`): camera 8.2 m away, 2.3 m high, FOV 30°, up to 2× pixel scale: about 300 px per metre, so **1 cm ≈ 3 px**. The garage is the only place players see fine detail.

Rules that follow:

1. **Silhouette first.** Each vehicle needs a profile you can name at 20 px wide. Exaggerate the defining features (wedge nose, fastback, box, hood scoop, fins, long tail) by 10–20 %.
2. **Big colour blocks.** 3–5 colour areas per vehicle: paint, a dark greenhouse (glass), dark trim (bumpers, sills, grille), lamps. No stripes or details under ~5 cm on traffic (they alias without MSAA).
3. **Lamps are big and bold.** Traffic is read from behind, often backlit by the low western sun, and at night only by its lamps (spec, Glare rule and Night). Rear lamp clusters should cover roughly a quarter of the rear width each side. Keep a gap between the brake and blinker areas so they read as separate lights.
4. **Design the rear first for traffic, and the rear three-quarter from above for the player car** (the chase view). Design the front three-quarter for the garage (turntable start yaw 215°, `turntable_start_yaw_deg`).
5. **Dark glass, light body** (or the reverse): the greenhouse is the strongest shape cue at range.
6. **No thin geometry** (antennas, wipers, wire spokes) except in the garage-visible player car, and there only if at least 1 cm thick.

### 2.4 Capture the current look for reference

The game-side agent (or you, on Linux) can capture the current in-game look. Snaps land in `tests/out/snaps/` (gitignored). The colour-script keyframes are `sky_t` 0 morning, 0.2 afternoon, 0.38 golden hour, 0.5 sunset, 0.58 dusk, 0.66 night, 0.85 dawn (`data/tuning/sun.tres`).

```
tools/snap.sh src/vehicle/dev/car_preview.tscn --renderer=both --car=falcon_gt --cam=chase3q --speed_kmh=0 --sweep=sky_t:0,0.2,0.38,0.5,0.58,0.66,0.85
tools/snap.sh src/run/run.tscn --renderer=both --state=menu --title=garage --sweep=sky_t:0.2,0.42      # the garage turntable
tools/snap.sh src/traffic/dev/traffic_view_preview.tscn --scenario=lineup --cam=quarter              # every traffic model side by side
tools/snap.sh src/traffic/dev/traffic_view_preview.tscn --renderer=both --sweep=sky_t:0.2,0.38,0.66 --cam=chase
tools/snap.sh src/road/dev/biome_preview.tscn --biome=desert --renderer=both --sweep=sky_t:0,0.38,0.5,0.58,0.66
tools/snap.sh src/world/landmarks/dev/landmark_preview.tscn --kind=suspension_bridge --dist=70 --cam=chase --sweep=sky_t:0.2,0.5,0.66
tools/snap.sh src/dev/car_drive.tscn --renderer=both --cam=cockpit --sweep=sky_t:0,0.2,0.38,0.5,0.58,0.7,0.85   # the procedural cockpit
tools/snap.sh src/run/run.tscn --renderer=both --leg=6 --hud=false --sweep=sky_t:0.38,0.5,0.58,0.72         # the city in the real run
```

Ask the game side for a reference set at the start of each phase; judge your work against it (§3.12).

---

## 3. Technical contract (hard rules)

"Test" in this section means a headless test that fails the build. "Rule" means a review check.

### 3.1 Units, axes, origins

- **Meters.** Blender scene: Metric, Unit Scale 1.0, Length in meters. Model at real size. No object scale other than 1.0 on export (apply scale).
- **Godot frame:** Y up, **−Z forward**, **+X right**, meters (CONTRACTS §2 "World frame"; spec "Modular car convention").
- **Blender frame:** the glTF exporter with **+Y Up** on (its default) maps Blender (x, y, z) to glTF/Godot (x, z, −y). So in Blender: **Z up, +Y forward (the nose points to +Y), +X right, left side at −X.** In Blender's top view (numpad 7) the nose points up the screen.

| Asset class | Origin (in Blender) | Forward | Other rules | Checked by |
| --- | --- | --- | --- | --- |
| Player car | On the ground (z = 0) at the **centre between the axles** (front and rear axle equally far from the origin, and the origin on the centreline) | Nose +Y | Wheels touch z = 0 (hub height = tire radius, ±2 cm); front wheels at +Y, left wheels at −X; headlights at the front left/right; `cam_hood` in front of the origin, `exhaust_L` behind it | test (`test_check_car_assets.gd`: ±5 cm axle centre, ±2 cm ground) |
| Traffic vehicle | On the ground at the **centre of the body box** (for cars also between the axles; the traffic sim's `s`, `d` is this point) | Nose +Y | Box centre within 10 cm across and 5 % of the length along; wheels touch the ground ±2 cm | test (`tests/unit/test_traffic_view.gd`) |
| Roadside prop | On the ground at the placement point | **+X points away from the road**, +Y is the direction of travel (Godot −Z), so the side facing approaching traffic faces −Y | The game rotates the same mesh 180° for the other carriageway (`tools/props/build_props.gd` header). Scatter setbacks are measured to the nearest edge of the mesh footprint (`RoadsideProp`) | test (`test_roadside_biomes.gd`: sits on the ground, bounds ≥ −1 m) |
| Landmark / set-piece kit part | Road space: x = lateral offset `d` (right +), y = distance along the road from the anchor (travel +Y), z = height | Travel +Y | See §3.9 | (G10) |

### 3.2 Names

Godot builds the node tree from Blender **object** names. Rules:

1. **Exact spelling and case** for every convention name in §3.6–§3.8 (`Body`, `Wheel_FL`, `headlight_L`, `cam_cockpit`, …). The code looks them up by string (`CarModel.WHEEL_NAMES`, `LIGHT_NAMES`, `MARKER_NAMES`).
2. **No Blender `.001` suffixes** in exported objects. Blender needs globally unique object names, but the convention repeats `Rim` and `Tire` under each wheel. Name them **`Tire_FL`, `Rim_FL`, `Tire_FR`, …** in Blender; the import (G1) renames a child of `Wheel_XX` that starts with `Tire`/`Rim` to `Tire`/`Rim`.
3. **No Godot import suffixes.** The car `.glb` import has `nodes/use_name_suffixes=true` (`assets/cars/placeholder/*.glb.import`), so a name ending in `-col`, `-convcol`, `-colonly`, `-convcolonly`, `-navmesh`, `-occ`, `-occonly`, `-rigid`, `-vehicle`, `-wheel`, `-noimp`, `-loop` or `-cycle` changes the node's type. `Wheel_FL` and `SteeringWheel` are fine; `rear-wheel` is not.
4. Only `A–Z a–z 0–9 _` in object and material names. No spaces, dots, `:`, `@`, `/`, `%`, `"`.
5. **Mesh data names** may be anything (they are not node names), but linked duplicates must share one mesh datablock (§3.6.3).
6. **Material names carry meaning** (§3.3). Use lower case.
7. File names: `snake_case`, and the car's file name is its CarDef id (`falcon_gt.glb`).

### 3.3 Materials and colour

**No PBR, no textures, no lights in files.** The game never uses the file's materials: it replaces them with the project shaders by **material name** (spec, Art pipeline step 3; CONTRACTS §13). Blender's Principled BSDF is only your viewport preview. Set its Base Color to the palette hex so the preview is honest, but the name is what counts.

**The colour comes from the material name.** Give every flat colour its own material, named after the slot and the palette colour. The converters and the modular car import (G1–G3) look the name up in the palette (§2.2) and write the exact sRGB value into the vertex `COLOR` the shaders read. This avoids glTF's colour-space conversions, and keeps you and the palette in sync. Vertex colour attributes are **not** used: the import overwrites COLOR from the name (`tests/art/test_art_pipeline.gd::test_material_names_win_over_vertex_colours`).

#### 3.3.1 Player cars (`vehicle.gdshader`, one shader with five slot materials)

The shader (`assets/shaders/vehicle.gdshader`) is vertex-lit with one light, a matcap sheen and a sky-fresnel rim. Each **slot** is a separate material in `assets/shaders/materials/vehicle_*.tres`, so each slot on a mesh is one surface, and on the `Body` **one draw call**.

| Material name in Blender | Slot | What the shader does | Used on |
| --- | --- | --- | --- |
| `paint` | paint (0) | albedo = the player's paint colour × COLOR.r, where COLOR.r = **1.0**; matcap sheen 0.25, sky reflect 0.22 | Every panel that takes the garage paint |
| `paint_shade` | paint | the same with COLOR.r = **0.8** (a darker tone of the same paint) | Lower panels, sills, recesses that should follow the paint but darker |
| `paint_dark` | paint | COLOR.r = **0.55** | Deep recesses in paint colour |
| `trim_<palette name>`, e.g. `trim_ink`, `trim_asphalt`, `trim_steel`, `trim_steel_dark`, `trim_white`, `trim_cream`, `trim_reflector_amber` | trim (1) | albedo = COLOR (the named sRGB colour); sheen 0.08 | Tires, rims, grilles, bumpers, diffusers, chrome (`steel`), badges, lamp bezels, two-tone roofs |
| `glass` (colour = `CarModel.COLOR_GLASS`) or `glass_<palette name>` | glass (2) | albedo = COLOR; sheen 0.3, strong sky fresnel 0.3 | Windows and clear headlamp covers |
| `lamp_head`, `lamp_tail` | lamp (3) | a lit lens by day (COLOR × 0.45, sun-lit), fully emissive as the colour script's headlight ramp comes up at dusk | **Only** on the `headlight_*` and `taillight_*` light meshes |
| `signal_brake`, `signal_blinker`, `signal_reverse` | signal (4) | fully emissive while the node is shown; the game shows the node only while the light is on | **Only** on the `brake_*`, `blinker_*` and `reverse` light meshes |

Notes:

- **Paint is one colour.** Anything that must not change with the player's paint (a contrasting roof, stripes, a black bonnet) is **trim**. A livery mask is supported by the shader (`use_livery`, `livery_mask` sampled on UV0, red channel) but liveries are "later" (spec, Garage). Give paint faces a clean non-overlapping UV0 unwrap in 0–1 so a livery can be added without remodelling; it costs nothing now.
- **Lamp housings** (chrome rings, black bezels) are **trim on the Body**, not on the light node: a light node's mesh is merged or switched as a whole (§3.6.4).
- The sheen and fresnel make large flat paint panels read as "car paint" in motion. Don't bevel every edge; a few big facets catch the matcap better than many small ones.

#### 3.3.2 Interiors (cockpit camera only)

Model interiors now; the cockpit view shows them (**G4**, done). The procedural cockpit (the fallback for a car without an `Interior`) uses `src/camera/cockpit/cockpit.gdshader` (the world lighting plus a sky fill, because a cabin is lit mostly by skylight) and `cockpit_gauges.gdshader` (procedural dials, no texture). G4 applies the same shaders to model interiors by name:

| Material name | Becomes | Used on |
| --- | --- | --- |
| `interior_<palette name>` (e.g. `interior_ink`, `interior_asphalt`, `interior_roof_slate`, `interior_cream`) | the interior material (one surface, one draw); COLOR = the named colour | Dash, door cards, pillar inner faces, roof liner, seats, console, mirror frame |
| `interior_screen` | the interior material with the vehicle-light emissive class (glows on the headlight ramp, as the procedural centre stack does) | A centre-stack screen or radio face |
| `gauges` | `cockpit_gauges.gdshader` on a separate `Gauges` object: speedometer in the left half, tachometer in the right half of UV 0–1, drawn from `speed_frac` / `rpm_frac` | One quad, UV0 0–1, about **2.6 : 1** (width : height, the shader's `aspect` default), facing the driver's eye |

Interior colours read as dark neutral greys by day, warm at golden hour and deep blue at night in the procedural cockpit (docs/COCKPIT.md "Lighting"). Keep them mid-dark (`asphalt`, `roof_slate`, `steel_dark`), with one accent (for example a `cream` or `brand_orange` stripe at 12 o'clock on the steering wheel rim, as the procedural wheel has).

#### 3.3.3 Traffic vehicles (`traffic.gdshader`, one mesh, one material)

Every traffic model is **one surface** drawn with the shared `assets/shaders/materials/traffic.tres`. Parts are told apart per vertex (`UV.x` = part id, `TrafficLights.PART_*` in `src/traffic/view/traffic_lights.gd`). The converter (G3) writes `UV.x` and `UV2` from your material names and wheel objects:

| Material name | Part (UV.x) | Behaviour (`assets/shaders/traffic.gdshader`) |
| --- | --- | --- |
| `<palette name>` or `fixed_<palette name>` | 0 fixed | albedo = the colour |
| `paint`, `paint_shade`, `paint_dark` | 1 paint | albedo = the instance's paint (the biome's traffic palette, or the model's fixed palette) × 1.0 / 0.8 / 0.55 |
| `glass_<palette name>` (the procedural models use `roof_slate`) | 2 glass | strong sky reflection |
| `wheel_<palette name>` (tire `ink`, hub `steel`, spokes `steel_dark`) | 3 wheel | spins about the X axis through its wheel's hub (UV2 = hub y, z) |
| `head_<palette name>` (`cream`) | 4 headlamp | lit with the headlights on |
| `rear_<palette name>` (`reflector_red`) | 5 rear lamp | always lit (glare rule), brighter at night, brake-bright when braking |
| `brake_<palette name>` (`reflector_red`) | 6 brake only | e.g. a high third brake light |
| `blinkL_<palette name>`, `blinkR_<palette name>` (`reflector_amber`) | 7 / 8 | left (−X) / right (+X) blinkers and hazards, front and rear |

Body roll and pitch are applied in the shader around a pivot **0.5 m** above the ground (`traffic.tres` `pivot_height`); nothing to model for it.

#### 3.3.4 Props, road furniture, landmarks, set-piece props (`world.gdshader` and relatives)

World meshes use one material, `assets/shaders/materials/world.tres` (city buildings: `world_windows.tres`). The vertex conventions (CONTRACTS §13) are: `COLOR.rgb` = palette sRGB, `UV2.x` = emissive class, `UV2.y` = tint class. The converter (G2) writes them from your material names:

| Material name | UV2.x emissive class | Effect |
| --- | --- | --- |
| `<palette name>` | 0 none | Lit by the sun, fogged |
| `<palette name>__reflector` | 1 reflector | Retro-reflective: glows on the reflector ramp at night and brightens in the player's headlights; gets a day fill so sign faces never go black against the sun (`wb_retro_light`, docs/NIGHT.md). Reflector posts, sign faces, borders, chevrons |
| `<palette name>__lamp` | 2 street lamp | Glows on the street-lamp ramp at night: lamp heads, tunnel lamp strips, neon tubes, the lighthouse lantern |
| `<palette name>__window` | 4 lit window (`world_windows.tres` only) | The glass colour by day, plus a warm glow × the street-lamp ramp × a per-face room brightness (UV2.y, 0 = dark) at night. The converter assigns room brightness per face, deterministically, as `tools/props/build_props_4_6.gd` does |
| `<palette name>__flash` | 4 flashing lamp (`set_piece.gdshader`) | Set pieces only: the arrow board's lamps, flashing at 1 Hz |

(Class 3, "vehicle light", is used by the cockpit screen and the procedural models, not by props.)

### 3.4 Geometry rules

1. **Flat shading everywhere** (Blender: Shade Flat). The exporter then writes one vertex per face corner, which is what the shaders expect ("Flat shading means duplicated vertices per face", CONTRACTS §13).
2. **Triangles are what count.** Budgets (§3.5) are triangles after triangulation. Quads and n-gons are fine to model with; count `Σ (len(polygon.vertices) − 2)`.
3. **Single-sided, outward-facing.** Every shader culls back faces (`cull_back`). Normals must point outward (Blender: Face Orientation overlay all blue). Anything seen from both sides (a thin fin, a sign panel) needs two faces or a thickness.
4. **Closed where it matters**: the body shell seen from the chase and garage cameras must have no holes. The underside can be open above 5 cm off the ground, since no camera sees it, except that the **garage turntable** shows the sills and the tires' inner sides.
5. **No degenerate or duplicate faces** (zero-area faces are dropped by the exporter and can crash the colour lookup). Merge by distance at 0.1 mm before export.
6. **No modifiers left unapplied** that you don't intend (the exporter applies them with `export_apply=True`). Mirror modifiers are fine.
7. **Apply rotation and scale** on every object (Ctrl+A), **except** the objects whose rotation is part of the convention: the left-side `Tire_*`/`Rim_*` (rotated 180° about Z, §3.6.3) and `SteeringWheel` (tilted along the column, §3.6.5). Scale is always 1.
8. **Object origins are pivots.** Keep the origin where the table in §3.6 says (wheel hubs, the steering wheel hub, marker positions). Never "apply location" on pivots.
9. **No hidden or disabled objects** in the exported collection; no cameras, lights, armatures, shape keys or animations.

### 3.5 Budgets

| Asset | Triangles | Draw calls | Source | Checked |
| --- | --- | --- | --- | --- |
| Player car **Body** (LOD0) | **≤ 15,000** (spec). Target 6–10k: multiplayer draws other players' cars from the same models (`src/net/rooms/remote_car_view.gd`) | Body 3 (paint, trim, glass) | `progression.tres` `player_body_tris_lod0` | test |
| Player car LOD1 | **≤ 5,000** | 1 per slot | `player_body_tris_lod1` | test (`test_check_car_assets.gd::test_lod1_models_fit_their_budget`); loadable with `CarModel.load_lod1_mesh`, not drawn yet (§7.6 Q14) |
| Player car interior (all `Interior` meshes) | **≤ 5,000** | 3 (interior, steering wheel, gauges) | `player_interior_tris` | test |
| Rim (each) | **≤ 800**, shared by the four wheels | (in the wheels' 1) | `rim_tris` | test |
| **Whole player car, merged, lights off** | — | **≤ 5**: body 3 + merged head/tail lamps 1 + all four wheels 1 (brake lights add 1 while braking) | `CarModel.MERGED_DRAW_SURFACES_MAX` | test (`tests/unit/test_car_visual.gd`) |
| Traffic vehicle | **≤ 3,000** (spec hard limit). **Target 600–1,000** for cars and bikes, ≤ 1,500 for the coach and semis (the procedural models are 360–704) | 1 per model (every instance of a model is one MultiMesh) | `traffic_tris_lod0` | test |
| Traffic LOD1 | ≤ 1,000 | +1 per model while it has both near and far vehicles | `traffic_tris_lod1` | converter (G3, `convert.gd`); `TrafficView` draws it beyond `lod1_distance_m` (60 m, G8). Optional: a model without one draws LOD0 everywhere |
| Roadside and biome prop (per mesh) | **≤ 400** | 1 per mesh variant (a MultiMesh per variant) | `MESH_TRIANGLE_BUDGET` in `tests/unit/test_roadside.gd`, `test_roadside_biomes.gd`, `test_biome_coast_city_valley.gd` | test |
| Roadside share of the frame | ≤ 60k triangles, ≤ 25 draw calls | | `TRIANGLE_SHARE`, `DRAW_CALL_SHARE` in `test_roadside.gd` | test |
| Landmarks | today: toll gantry ~0.8k, bridge ~3.3k, sign gantry ~0.3k, tunnel ~0.6k, sign ~0.1k | 1 per landmark instance, 1 per sign | docs/LANDMARKS.md | review |
| **Whole frame** | **≤ 150,000** visible | **≤ 100** in gameplay | spec Performance budget; `quality.tres` | `tools/drawcalls.sh` |

Why the traffic target is well below its limit: the busiest frame today (the city at leg-8 density) is about **105k** triangles with ~400-triangle traffic (docs/PERF.md, "Biomes in the run"), and up to 90 vehicles on the player's side (120 on 4-lane roads, plan D33) plus the opposite carriageway draw with no LOD. Each extra 100 triangles per traffic model costs roughly 5–9k triangles in a busy frame (an estimate: 50–90 cars in view). At 3,000 per car the frame would exceed 150k.

**Draw calls grow with variety, not detail.** Each traffic model adds one draw call whenever any instance is on screen (15 today with 17 models, docs/PERF.md). Each roadside mesh variant adds one per biome in view. Keep the number of **models and variants** about where it is (§4) unless the game side measures room.

**File size.** No embedded images. Aim for ≤ 1.5 MB per `.glb`. The whole web pack to the title is ~12.9 MiB and the three placeholder cars already cost 452 KiB (docs/WEB.md).

### 3.6 Player car convention (spec "Modular car convention"; `CarModel`)

#### 3.6.1 The tree

The Blender collection you export for car `falcon_gt` (the Godot names are shown; Blender names differ only where noted):

```
Car_FalconGT                 Empty at the world origin, no rotation (root; "Car_" + PascalCase of the id)
  Body                       mesh: paint / paint_shade / paint_dark, trim_*, glass surfaces
  Lights                     Empty at the origin
    headlight_L, headlight_R   mesh: lamp_head          (left = −X)
    taillight_L, taillight_R   mesh: lamp_tail
    brake_L, brake_R           mesh: signal_brake
    blinker_FL, blinker_FR     mesh: signal_blinker      (front)
    blinker_RL, blinker_RR     mesh: signal_blinker      (rear)
    reverse                    mesh: signal_reverse      (one node; may hold both reverse lamps)
  Wheel_FL, Wheel_FR         Empty at the front hub centres, no rotation (steer pivots)
    Tire_FL / Rim_FL           mesh (Blender names; become Tire / Rim)
  Wheel_RL, Wheel_RR         Empty at the rear hub centres, no rotation
    Tire_RL / Rim_RL
  Interior                   Empty at the origin (optional for the tests, required for this brief)
    Cabin                      mesh: interior_* (+ interior_screen): dash, door cards, pillars, liner, seats, console, mirror
    SteeringWheel              mesh: interior_*; origin at the wheel hub, local axes along the column (§3.6.5)
    Gauges                     mesh: one quad, material gauges
  Markers                    Empty at the origin
    cam_cockpit, cam_hood, exhaust_L, exhaust_R, smoke_hood, shadow    Empties (become Marker3D, G1)
  Damage                     optional, later (spec: alternate bumper_F / bumper_R / hood meshes)
```

The import adds `CollisionBox` (a disabled `CollisionShape3D`: the Body's bounds inset by **8 cm** on the sides, front, back and top, `lives.collision_inset_m` = 0.08). Don't model a collision mesh.

`CarModel.required_paths()` (every one must exist after import, or the test fails): `Body`, `Lights`, the 11 light names, `Wheel_FL/FR/RL/RR` each with `Rim` and `Tire`, `Markers` with the 6 marker names, `CollisionBox`. Missing nodes are "stubbed" with placeholders, and the test also requires that the import stubbed **nothing** (`test_every_car_model_passes`: `m.stubbed.size() == 0`).

#### 3.6.2 Size and fit

- **Body bounds must match the car's `CarDef`** (`data/cars/<id>.tres`) within **5 %** in length (Z) and width (X), and the length must lie in **3.8–5.2 m** (test). The Body bounds include everything in the `Body` mesh: **mirrors count toward the width.** Either keep mirrors within the tolerance (≤ ~4.5 cm per side beyond the body on a 1.9 m car) or raise it as a question (§7.6, Q5).
- **The CarDef dimensions are gameplay.** `CarDef.length_m` and `width_m` set the player's hit box, the close-pass clearance and the traffic sim's view of the player (`src/run/run.gd` → `HitDetection.set_player_body`, `Scoring.set_player_body`, `TrafficSim.set_player_body`). Your model must look exactly as big as it hits. Changing an existing car's CarDef dimensions is a gameplay change for the orchestrator, not an art change.
- **Wheelbase:** the axle spacing should equal `CarDef.wheelbase_m` (physics uses it; not tested, but visible when the car turns).
- **Height:** match `CarDef.height_m` (the default cockpit eye is proportional to it).
- Current CarDefs: Falcon GT 4.5 × 1.9 × 1.25 m, wheelbase 2.65; Night Viper 4.6 × 1.95 × 1.15, wheelbase 2.6; Brute V8 4.8 × 1.95 × 1.35, wheelbase 2.8.
- The body must fit the garage turntable disc (radius 2.85 m, `turntable_disc_radius_m`): any car up to 5.2 m long fits.

#### 3.6.3 Wheels

The four wheels are drawn as **one MultiMesh** (one draw call) only if they share geometry (`CarModel._merge_wheels`, `_same_wheel`; test: "the four wheels share one MultiMesh"). So:

- **One tire mesh and one rim mesh for all four wheels:** in Blender, make `Tire_FR` and `Rim_FR`, then create the others as **linked duplicates** (Alt+D) so the four `Tire_*` share one mesh datablock and the four `Rim_*` share another. The exporter then writes one glTF mesh per datablock, and Godot shares it.
- **Tire:** a flat-shaded cylinder around the **X axis**, centred on its origin (the tread symmetric about x = 0). The wheel radius is read from the tire mesh (`max(size.y, size.z) / 2`), and the hub height must equal it (±2 cm). 12–20 sides is plenty (the stub uses 12). Tread and sidewall in `trim_ink`, `trim_asphalt`.
- **Rim:** its face toward **+X** (Blender +X), sitting just outside the tire's outer sidewall (at about x = tire width / 2 + 1 cm), origin at the hub centre (the same point as the tire's origin). **≤ 800 triangles.** Trim materials only (for example `trim_steel` face, `trim_steel_dark` spokes, `trim_ink` hub), so tire and rim merge into one surface.
- **Pivots:** each `Wheel_XX` is an Empty at the hub centre with **no rotation** (the game steers the front pivots about their Y axis and spins the Rim/Tire about X). `Tire_XX` and `Rim_XX` are **direct children** of their `Wheel_XX` at local position 0.
- **Left wheels:** `Tire_FL/RL` and `Rim_FL/RL` are rotated **180° about Blender Z** (the object's rotation, not applied), so the +X-facing rim faces outward (−X). This is exactly how the stub wheels are built (`CarModel._stub_wheels`, "left wheels turn it around"), keeps the rim's placement relative to the tire identical on all four wheels, and lets garage rims swap in (`CarModel.apply_rim` keeps each Rim node's transform and replaces its mesh).
- The rim swap scales the garage rim to `wheel_radius × radius_frac` (0.62–0.68, `RimStyle`); the stock rim is yours and can be any size up to the tire's inner radius.
- Wheels are **not** in the collision box (it is the Body bounds only).

#### 3.6.4 Lights

- Each light is its **own mesh object** under `Lights`, named exactly as in §3.6.1, using only its slot's material (§3.3.1). Face the lens outward: headlights toward the front (Blender +Y), tail, brake and reverse lamps toward the back (−Y). Stand lenses **~1.5 cm proud** of the body surface (the stub's `STUB_LIGHT_STANDOFF_M`) so they never z-fight.
- `headlight_L/R` and `taillight_L/R` are merged into one always-on draw (`Lights/MergedLamps`); `brake_L/R` into one draw shown while braking (`MergedBrakes`). Blinkers and reverse stay separate nodes, **hidden until used** (G1 hides every signal-slot light at import; the stubs start hidden, `CarModel._stub_light`).
- The game uses `headlight_L`/`headlight_R` positions as the origin of the player's fake headlight beam (`src/vehicle/player_headlights.gd`) and `headlight_L` alone for the first-hit "flickering headlight" (`CarModel.split_light`). Put each headlight node's origin at its lamp's centre.
- The Daily Drive ghost merges the whole car into one translucent draw and treats the four head/tail lamps and two brake lamps by name (`src/world/ghost/ghost_car.gd`).
- **Taillights and brake lamps may overlap in shape** (a tail lamp that turns brighter when braking), but then place the brake mesh 5 mm proud of the tail mesh.
- **Every car gets a distinct taillight signature** (§4.1.2): at night, in the chase camera, the player sees their own car mostly by its taillights.

#### 3.6.5 Interior and the cockpit camera

The cockpit camera was **hidden from players** until better car and interior models existed (owner, 2026-10-01, plan D11 and O6). The modelled interiors (P1–P3) brought it back the same day: `CameraTuning.cockpit_player_enabled = true`.

What the game does today (docs/COCKPIT.md, `src/camera/camera_rig.gd`, `src/camera/cockpit/cockpit.gd`):

- The eye is the model's **`Markers/cam_cockpit`** position when it is authored (a stubbed marker doesn't count). Only the **position** is used; the head looks along the car's −Z toward a point 40 m ahead and 0.3 m high. The default eye without a marker is x = −0.19 × width (the left seat: right-hand traffic), y = 0.86 × height, z = 0.04 × length behind the axle centre.
- A **generic procedural cockpit** (3 draws, ~800 triangles: dash, A-pillars, windscreen header, roof liner, door tops, mirror, a wheel that turns, gauges) is drawn around the eye, and the car body is hidden.
- The steering wheel turns by `steer_angle × 12` (`vehicle.tres` `steering_wheel_ratio_factor`): up to ±360° at a standstill and about ±42° at 250 km/h. It must look right at any angle.

What the game does (**G4**, done) when a model brings an `Interior` (and what you model for it):

- In cockpit mode the game shows **the model's Body and Interior** and hides the procedural cockpit. Outside cockpit mode it **hides the Interior** (spec budget: "Interior 5k, cockpit camera only"; it would otherwise break the 5-draw car budget).
- Seen from the eye, the Body's outward faces behind you are culled, but the **hood** (and fenders) show through the windscreen: that is your real hood. Glass faces outward, so from inside the view is clear.
- So the Interior models **only the inward-facing surfaces**: dashboard and binnacle, door cards and door tops, the **inner faces of the A-pillars**, windscreen header and roof liner, the rear-view mirror (a frame; the "glass" can be a flat dark `interior_steel_dark` face), seats (the driver's seat is mostly out of view; the passenger seat shows at the right edge), console and shifter.
- **`SteeringWheel`**: its own object, origin at the hub. G4 and `CarVisual` turn it about its **local Godot +Z axis**, which is the object's **local −Y axis in Blender**. So: at rest the wheel's local −Y points back along the steering column toward the driver; tilt the object about its local X to match the column rake (keep that rotation, don't apply it). Rim, three spokes and hub; an accent mark at 12 o'clock so the rotation reads.
- **`Gauges`**: one quad in the binnacle (§3.3.2).
- **`cam_cockpit`**: an Empty at the driver's eye: on the driver's seat centreline, about 0.65 m above the seat cushion, and roughly 0.6–0.7 m behind the steering wheel hub. Check the view in Blender with a camera at the marker, FOV 62° vertical (up to 78° at top speed), looking along +Y and 1° down: the road must be visible over the dash, the hood edge in the lower fifth, the A-pillars not covering the adjacent lanes.
- Faces at least **0.25 m from the eye** (the procedural dash top is 0.66 m ahead and 0.24 m below the eye).

#### 3.6.6 Markers

All are Empties under `Markers` (G1 turns them into `Marker3D`; `CarModel.marker()` returns only `Marker3D`s). Only the position matters; leave rotation at zero.

| Marker | Where | Used by (today) |
| --- | --- | --- |
| `cam_cockpit` | Driver's eye (§3.6.5) | Cockpit camera eye (`CameraRig._authored_cockpit_marker`) |
| `cam_hood` | On the hood centreline, 10–15 cm above the hood surface, about 20–25 % of the length behind the front (the stub: `STUB_HOOD_Z_FRAC` 0.22, +0.12 m); it must clear scoops and fenders and see the road | Hood camera mount: the rig takes an **authored** `Markers/cam_hood` from the player's `CarModel` (G6, done); a stubbed one (the placeholders) falls back to `camera.tres` offsets |
| `smoke_hood` | On the hood surface at the same spot | First-hit smoke (`src/run/player_fx.gd`; hidden in hood and cockpit views, plan D16) |
| `exhaust_L`, `exhaust_R` | At the tailpipe tips, on the rear face (both at the single pipe for a one-pipe car) | Required by the convention; not used yet (future backfire and boost flames) |
| `shadow` | On the ground at the footprint centre (0, 0, ~0) | Required; not used (the blob shadow is sized from the CarDef) |

### 3.7 Traffic vehicle convention (CONTRACTS §13 "Traffic models"; `tools/traffic_models/`)

- **One mesh, one surface, one material** per model; every part (body, glass, wheels, every lamp group) is in it and switched per vertex (§3.3.3). This is what lets every instance of a model be one MultiMesh draw.
- **Blender tree** for model `sedan_a` (the converter G3 flattens it):

```
Traffic_sedan_a                  Empty at the origin
  Body                           mesh: every non-wheel part (paint, fixed, glass, head_, rear_, brake_, blinkL_, blinkR_ materials)
  Wheel_FL, Wheel_FR, ...        mesh per wheel, origin at its hub centre, material wheel_* only (tire + hub face + spokes);
                                 any number (a semi has 10+; name them Wheel_1 ... Wheel_N if not four)
  glow_front                     Empty at the right front lamp's centre: x = half the lamp spacing (0 for a single central lamp), z = the lamp face
  glow_rear                      Empty at the right rear lamp's centre (same rule)
```

- **Dimensions** must match the `VehicleType` (`data/vehicle_types/<type>.tres`): length within ±5 %, width −5 %/+12 % (mirrors allowed), height ±12 %, on the ground, centred (test, `test_every_vehicle_type_has_valid_models`).
- **Wheels:** any wheel with a hub on the X axis. The shader spins every `wheel_*` vertex about the X axis through its hub, so a wheel must be a body of revolution around X (8 sides is the procedural standard: `WHEEL_SIDES`). The lowest wheel vertex must be at y = 0 (±2 cm; the procedural builder uses a circumscribed polygon so the flat bottom face touches the ground). Motorbikes show a hub on both faces.
- **Articulation:** none. A semi is one rigid 16 m mesh (tractor + trailer); it yaws as one body in lane changes.
- **Required parts** (test): paint, wheel, head, rear, blinkL, blinkR must each exist. Glass and brake-only are optional.
- **Fixed paint palettes:** a model can use its own paint colours instead of the biome's (the coach's livery, the motorbikes' tanks: `paint_palette` mesh meta). Put them in the sidecar (§3.10).
- **Lamps** stand 4 cm proud of their face (`LAMP_DEPTH`).
- **The rear matters most**: players spend the game behind traffic. Each model's rear must be distinct at 20 px.
- The converter (G3) writes the mesh meta `TrafficView` reads: `glow_front`, `glow_rear`, `wheel_radius_m`, `vehicle_type`, `tris`, optional `paint_palette` (see the build script header).

### 3.8 Prop convention (roadside, biome props)

- **One mesh, one surface, `world.tres`** (or `world_windows.tres` for lit-window buildings), ≤ 400 triangles, unit normals, colours in 0–1, sitting on the ground (tests in `test_roadside_biomes.gd`, `test_biome_coast_city_valley.gd`).
- **Frame:** §3.1 (origin at the placement point on the ground, +X away from the road).
- **Rhythm props** (light pole, reflector post, guardrail post) are placed by the road edges at fixed spacing (`data/tuning/road.tres`: poles every 50 m, reflector posts every 25 m, guardrail posts every 4 m). Their origin is the point that stands on the edge line: the **median** for the twin-arm light pole (its arms reach both carriageways: 7.1 m across today), the guardrail line for posts.
- **Fence segments** carry a `length_m` (the fence is laid segment after segment along the road; today 10–12 m). **Sign gantries** carry `span_m` (17.5 m today). Put these in the sidecar.
- **Crop and meadow tiles** are unit squares (1 × 1 m, scaled to the field tile by the game), a few cm to 0.8 m tall.
- **Forests are copses** (8–9 trees in one mesh, ~144 triangles) so woods cost few instances (docs/BIOMES.md).
- **City buildings** reach **12 m below their origin** (footings), so next to an elevated stretch they stand on the lowered ground (`FOOTING_M`, docs/BIOMES.md).
- **Coast islets** (sea stacks, lighthouse) are copied into the water mesh at sea level; their lantern uses `__lamp`.
- **Nothing may enter the road.** The game keeps every instance's footprint beyond the scenery line; very wide props (mesas: 372 m) are set far back by data.

### 3.9 Landmark and set-piece kit parts (later phases)

Today every landmark (toll gantry, suspension bridge, sign gantry, tunnel portal, warning sign) and every set-piece prop (warning signs, cones, barrier, arrow board, attenuator, road legends) is **generated in code, in road space, for the current cross-section** (2, 3 or 4 lanes) and bent along the road in the shader (docs/LANDMARKS.md, docs/SET_PIECES.md). Modelled versions are therefore **kits of parts** that a game-side assembler (G10) places for each cross-section. Rules for kit parts:

- Road-space frame (§3.1): x = `d` (right +), y = along the road (travel +Y), z = height, origin as specified per part.
- **Long parts bend with the road**: split any geometry longer than **8 m** along Y into segments at most 8 m long (`bend_station_step_m` = 8 m; the shader moves each vertex by its station).
- **Clearance:** nothing below **5.5 m** above any lane or shoulder (`overhead_clearance_m`). Only the median (|d| ≤ 0.5 m, `median_half_width_m`) and beyond the guardrails may hold columns and walls.
- **Text** is drawn by the game from a font atlas onto flat panel faces: model sign panels blank, with a material `<colour>__reflector`, and give the game the panel rectangles as Empties named `text_<n>` at each panel's centre (G10 defines the exact sizes).
- Cross-section numbers (`data/tuning/road.tres`): lane 3.6 m, shoulder 3.0 m, inner shoulder 1.2 m, median half-width 0.5 m, guardrail 0.5 m beyond the shoulder; 2–4 lanes per direction.

### 3.10 Export and file layout

**Blender glTF export** (Blender 4.2 LTS or later; check parameter names against `bpy.ops.export_scene.gltf` on your version):

| Setting | Value | Why |
| --- | --- | --- |
| `export_format` | `'GLB'` | one file |
| `use_active_collection` / `use_selection` | export exactly one asset's collection | one asset per file |
| `export_yup` | `True` | Blender Z-up → glTF Y-up (§3.1) |
| `export_apply` | `True` | apply modifiers |
| `export_normals` | `True` | flat normals |
| `export_texcoords` | `True` | UV0 for paint (livery later) and the gauges quad |
| `export_tangents` | `False` | not used (`meshes/ensure_tangents=false`) |
| `export_materials` | `'EXPORT'` | material **names** carry the colour and slot |
| `export_image_format` | `'NONE'` | no textures |
| `export_vertex_color` | `'NONE'` | colours come from material names (§3.3) |
| `export_cameras`, `export_lights`, `export_animations`, `export_skins`, `export_morph` | `False` | none allowed |
| `export_draco_mesh_compression_enable` | `False` | Godot's importer doesn't read Draco |
| `export_extras` | `False` | metadata goes in the sidecar JSON |

**Where files go:**

| What | Path | Imported by |
| --- | --- | --- |
| Blender sources | `art/blender/<group>/<name>.blend` (group: `cars`, `traffic`, `props/<biome>`, `furniture`, `set_pieces`, `landmarks`) | nobody (`art/` holds a `.gdignore`, like `westbound-server/`, so Godot skips it) |
| Player car | `assets/cars/<id>/<id>.glb` + `<id>.car.json` (`"modular": true`), and `<id>_lod1.glb` | Godot's scene importer with `assets/cars/car_import.gd` (the `.import` file's `import_script/path`; the game side writes it, G7). `<id>_lod1.glb` takes the same import script (a Body only, nothing stubbed) |
| Garage rim | `assets/cars/rims/<rim id>.glb` + `.rim.json` (its presence selects the rim path) | `assets/cars/car_import.gd` (rim path), then `RimStyle.mesh_path` (G5) |
| Traffic model | `art/export/traffic/<model>.glb` + `<model>.traffic.json` (+ `<model>_lod1.glb`) | `tools/art/convert.gd --kind=traffic` (G3) → `assets/traffic/<model>.res` + `.tscn` (+ `<model>_lod1.res`) |
| Prop, furniture | `art/export/props/<biome or common>/<name>.glb` + `<name>.prop.json` | `tools/art/convert.gd --kind=props` (G2) → `assets/props/<biome>/<name>.res` |
| Set-piece and landmark kits | `art/export/set_pieces/`, `art/export/landmarks/` | G10 |
| Reference renders | `art/renders/<asset>/*.png` (optional, small) | people |

`art/` is a new top-level folder: **needs the orchestrator's OK** (§7.6, Q9). The game side works either way: `tools/art/convert.gd --src=<dir>` reads any folder (default `art/export`). **Create `art/.gdignore` first** (an empty file): without it Godot imports every `.glb` there as a scene, and every `.blend` through its Blender importer, which fails on a machine without Blender and breaks `tools/test.sh`'s import step. Keeping `.blend` sources in the repo lets the game side and later agents rework assets; they are small for low-poly work (keep each under ~10 MB).

**Sidecar JSON** (next to each `.glb`; the car one already exists for the placeholders, `assets/cars/placeholder/*.car.json`):

```jsonc
// assets/cars/falcon_gt/falcon_gt.car.json
{ "root_name": "Car_FalconGT", "modular": true, "forward_axis": "-Z",
  "source": "in-house, Blender: art/blender/cars/falcon_gt.blend" }
// modular models are exact size: no length_m / width_m / height_m / wheel_*_frac scaling hints

// art/export/traffic/sedan_a.traffic.json
{ "model": "sedan_a", "vehicle_type": "sedan", "paint_palette": [] }   // palette: sRGB hex list ("#rrggbb"), empty = the biome's

// art/export/props/farmland/fence_ranch.prop.json
{ "mesh": "fence_ranch", "material": "world", "meta": { "length_m": 10.0 } }   // material: world | world_windows
// optional: "biome" (default: the folder name; picks the sand/scrub set), "window_lit_chance" (0.5),
// "tris_budget" (400; the unit crop tiles and copses keep 400 too)

// assets/cars/rims/mesh.rim.json   (G5: the file's presence selects the rim import)
{ "root_name": "Rim_Mesh", "rim": "mesh" }
```

### 3.11 Import and registration (game side)

Nothing you deliver is used until the game side registers it. The tasks, with their current state:

| # | Task | Needed before | State |
| --- | --- | --- | --- |
| **G1** | **Modular path in `assets/cars/car_import.gd`**, taken when the sidecar says `"modular": true` (or the file has a `Body` node): keep the node tree; rename `Tire_*`/`Rim_*` under a wheel to `Tire`/`Rim`; map materials by name to the slot materials (§3.3.1) and write COLOR from the name (palette or the fixed vehicle colours) or the shade for `paint*`; merge each mesh's surfaces per slot; turn `Markers` Empties into `Marker3D`; hide signal-slot lights; hide `Interior` (and `Damage`); build `CollisionBox` via `CarModel.conform`; record anything stubbed in `car_import_stubbed` (should be nothing). Keep the placeholder path unchanged | the first real car (P1) | ✅ `tools/art/car_modular_import.gd` (`CarModularImport.convert`), called by `assets/cars/car_import.gd`. Also: identical meshes are shared even if the exporter wrote one per object (so the four wheels stay one MultiMesh); problems (unknown material names, `.001` suffixes, a light in the wrong slot, unshared wheels, interior materials outside `Interior`) land in the root meta `car_import_problems` and as import warnings; blinkers and reverse are driven by `CarVisual` (`set_blinkers`, reverse while rolling backwards). Palette names: `tools/art/art_palette.gd`, material names: `tools/art/art_materials.gd` |
| G2 | Prop converter: `.glb` → one-surface `ArrayMesh` `.res` with `world.tres` / `world_windows.tres`, COLOR and UV2 from material names (§3.3.4), mesh meta from the sidecar. A headless script like `tools/props/build_props.gd` (`GLTFDocument` can read files in the gdignored `art/`) | P6 | ✅ `tools/godot.sh --headless --path . --script res://tools/art/convert.gd -- --kind=props [--src=art/export] [--only=<name>] [--check]` (`ArtConvert.prop`). Window rooms: deterministic per face from the mesh name. Also records `text_<n>` Empties as `text_panels` meta (for G10). The prop builders (`tools/props/build_props*.gd`) keep a converted mesh |
| G3 | Traffic converter: `.glb` → one-surface traffic `ArrayMesh` (UV.x parts, UV2 hubs, meta from `glow_front`/`glow_rear`/wheels/sidecar) and the `.tscn` wrapper; retire the matching recipe in `tools/traffic_models/build_traffic_models.gd` so a rerun doesn't overwrite it | P5 | ✅ `tools/art/convert.gd -- --kind=traffic` (`ArtConvert.traffic`): checks the §3.7 parts, the size against the VehicleType and the budgets, and writes nothing for a model with problems (exit 1). **Retirement:** a converted mesh carries the meta `art_source`; `build_traffic_models.gd` keeps it (`ArtConvert.is_converted`). Delete the `.res` to go back to the recipe |
| G4 | Model interiors in the cockpit camera: show Body + Interior in cockpit mode, hide the procedural cockpit (`CameraRig._apply_cockpit_view`), hide Interior outside it; interior and gauges materials by name (§3.3.2); SteeringWheel already turns (`CarVisual`) | P1 interior review | ✅ `CameraRig._apply_cockpit_view` (`CarModel.has_authored_interior`, `set_interior_visible`, `set_gauges`); `CarModel.from_root` hides every Interior. Outside the cockpit the car stays at 5 draws (tested). Dev view: `car_preview --cam=cockpit` |
| G5 | Authored garage rims: an optional `mesh_path` on `RimStyle` (`src/vehicle/rim_style.gd`); `CarModel.apply_rim` scales it to `wheel_radius × radius_frac` | P4 | ✅ `RimStyle.mesh_path` (an imported `assets/cars/rims/<id>.glb` or a Mesh), `CarModel.load_rim_mesh` / `place_authored_rim`; a missing file falls back to the procedural rim. To switch a style: set its `mesh_path` in `data/cars/garage/catalog.tres` |
| G6 | Hood camera marker: resolve `Markers/cam_hood` through the player's `CarModel` (as the cockpit eye already does) | P1 | ✅ `CameraRig._authored_marker` (a stubbed marker still falls back to the offsets) |
| G7 | Registering a car: the `.glb.import` with `import_script/path`; `data/cars/<id>.tres` (`model_scene_path`, stats, body dims, `default_paint`); `Run.CAR_PATHS` (`src/run/run.gd`, the replay verifier builds runs from it); the slot in `data/cars/garage/catalog.tres` (**slot id = CarDef id**, tested); a save migration from `car/slot_N` to `car/<id>` so recorded unlocks of a "coming soon" slot carry over; `CAR_PATHS` in `src/dev/car_drive.gd` | each new car (P3) | ✅ the migration is data: put the old id in the slot's `former_ids` (`GarageSlot`, e.g. `former_ids = PackedStringArray("slot_4")` when slot 4 becomes `kestrel_rs`); `Garage.profile()` runs `SaveMigrations.rename_car_ids` (unlocks, selected car, look) on every load. The rest is per car (checklist in §6.3) |
| G8 | LOD1 use: far remote cars (`RemoteCarView`) and the ghost (`GhostCar`) from `<id>_lod1.glb`; a LOD1 budget check in `test_check_car_assets.gd` | when multiplayer needs it | ✅ traffic: `TrafficView` draws a model's vehicles beyond `traffic_view.tres` `lod1_distance_m` (60 m) with its LOD1 (mesh meta `lod1_path`, from `<model>_lod1.glb` via G3); one more draw while a model has both. Player cars: `CarModel.load_lod1_mesh(car)` and the LOD1 budget test are in; wiring `RemoteCarView` and `GhostCar` to it is for their owners (both draw near the player today) |
| **G9** | **Colour round-trip test**: import the P0 calibration file and check every palette name arrives as its exact sRGB value in COLOR (±1/255), and the orientation and hierarchy survive | P0 | ✅ `tests/art/test_art_pipeline.gd` on the game-side calibration car (through the editor import and through `GLTFDocument`), the swatch prop and the traffic model; `test_delivered_modular_cars_import_cleanly` checks every modular car under `assets/cars/` (your `calib_box` included) |
| G10 | Kit assembler for landmarks and set-piece props (per cross-section, bending, text panels, clearance zones) | P7 | ⏳ not built (P7; the kit list waits on §7.6 Q8). Ready: `ArtConvert.prop` converts a kit part in LandmarkMeshBuilder's frame (x = d, y = up, z = −s) and records its `text_<n>` Empties |
| G11 | Update docs and the acceptance rows (SP-A2, plan D26) as the placeholders go | each phase | ongoing: this brief, docs/COCKPIT.md and docs/GARAGE.md are up to date for G1–G9; SP-A2 and D26 change when the first placeholder goes |

G1 has landed: a modular `.glb` with `import_script/path="res://assets/cars/car_import.gd"` in its `.import` keeps its tree. Godot reimports only when the file's content (or its `.import`) changes: after changing an import script, delete the file's entries in `.godot/imported/` to force it.

### 3.12 Validation

#### 3.12.1 In Blender, before every export (your `tools/blender/wb_validate.py`)

- [ ] Scene units metric, scale 1.0; every exported object has scale (1, 1, 1); rotation applied except the allowed objects (§3.4.7).
- [ ] Orientation: the nose at +Y; bounds: min z within ±2 cm of 0; the car's axle centre on the origin (±5 cm); traffic box centre on the origin.
- [ ] Every required name present, spelled exactly (§3.6.1, §3.7); no `.001`; no forbidden suffixes (§3.2).
- [ ] Every material name parses: a known slot or part prefix plus a palette name that exists in §2.2 (parse `assets/palette/palette.tres`, `tools/props/palette_biomes_4_6.tres` and `tools/props/biome_colors.gd` with a regex).
- [ ] Light meshes use only their slot's materials; wheels use only trim (cars) or `wheel_*` (traffic).
- [ ] Triangle counts per §3.5 (Body, interior total, rim, LOD1, traffic, prop).
- [ ] Car: Body X and Z size within 5 % of the CarDef's `width_m` and `length_m` (read `data/cars/<id>.tres`); the four tires and four rims each share one mesh datablock; left tires and rims rotated 180° about Z.
- [ ] Traffic: size within the VehicleType tolerances (read `data/vehicle_types/<type>.tres`); required parts present; `glow_front` and `glow_rear` present.
- [ ] No degenerate faces; normals outward (the script can check that a face's normal points away from the object's bounding-box centre for convex-ish shells, and report the rest for a manual look).
- [ ] Self-review renders (Workbench, flat lighting, object colour = material) from the standard views: the chase view (7 m behind, 3.6 m up, 62°), the garage front three-quarter (8.2 m, 2.3 m up, 30°, yaw 215°), the rear at 50 m (traffic) and the cockpit eye. Save to `art/renders/<asset>/`.

#### 3.12.2 In Godot (the game-side agent runs these; you can run the first line if you have Godot)

```
tools/test.sh --filter=art/                    # G1-G9: import paths, colour round trip, converters, cockpit, hood, rims, ids
tools/test.sh --filter=check_car_assets        # convention, budgets, orientation, scale, materials, collision box, LOD1 budget
tools/test.sh --filter=car_visual              # ≤ 5 merged draws, one wheel MultiMesh, braking adds one
tools/test.sh --filter=car_look                # every garage rim on every car, within budget
tools/test.sh --filter=cockpit                 # cockpit camera (G4 adds the model-interior cases)
tools/test.sh --filter=garage                  # garage screen and turntable: project shaders only
tools/test.sh --filter=ghost                   # the Daily Drive ghost merges the car
tools/test.sh --filter=traffic_view            # traffic models: budget, dims, parts, orientation, shader
tools/test.sh --filter=roadside                # prop budgets, clear zone, look contract
tools/test.sh --filter=biome                   # biome data and props
tools/test.sh                                  # the full fast tier (the merge gate)
tools/lint                                     # rendering budget and working rules
tools/snap.sh src/vehicle/dev/car_preview.tscn --renderer=both --car=<id> --cam=chase3q --sweep=sky_t:0,0.2,0.38,0.5,0.58,0.66,0.85
tools/snap.sh src/vehicle/dev/car_preview.tscn --renderer=both --car=<id> --cam=front3q --speed_kmh=120 --steer=0.3 --brake=1 --sky_t=0.66
tools/snap.sh src/run/run.tscn --renderer=both --state=menu --title=garage --pick=<id> --sweep=sky_t:0.2,0.42
tools/snap.sh src/run/run.tscn --state=menu --title=garage --tab=paint --pick=obsidian --xp=6000000       # the paint extremes
tools/parity.sh src/vehicle/dev/car_preview.tscn --car=<id> --cam=chase3q --sky_t=0.38
tools/drawcalls.sh src/run/run.tscn --set=leg_override:8 --cam=chase --speed_kmh=150 --leg=6 --hud=false
```

`car_preview --car=` loads any `data/cars/<id>.tres` (`--car_def=<res path>` any CarDef, e.g. the calibration car); its other options are `--cam=chase|chase3q|front3q|side|front|rear|top|orbit|hood|cockpit` (cockpit: the authored eye with the model's Interior shown, G4), `--speed_kmh`, `--steer`, `--brake`, `--blinkers=left|right|hazard`, `--paint=#rrggbb`, `--sky_t`.

The game-side calibration car (the shape your P0 file should have):

```
tools/snap.sh src/vehicle/dev/car_preview.tscn --renderer=both --car_def=res://tests/art/fixtures/calib_car/calib_car.tres --cam=chase3q --speed_kmh=0 --sweep=sky_t:0.2,0.66
tools/snap.sh src/vehicle/dev/car_preview.tscn --renderer=both --car_def=res://tests/art/fixtures/calib_car/calib_car.tres --cam=cockpit --speed_kmh=60 --steer=0.3 --sky_t=0.38
```

---

## 4. Asset inventory

Priority: **P1** now (player cars, the owner's first ask), **P2** next (traffic, the most-seen objects), **P3** world (furniture, set pieces, biome props), **P4** landmarks and later extras. "Procedural" means generated by GDScript today (in-house, working, within budget); "placeholder" means owner-supplied cool_drive/Tripo models.

### 4.1 Player cars (8 roster slots)

#### 4.1.1 Current state

`data/cars/garage/catalog.tres` (docs/GARAGE.md, plan D26):

| Slot | Car (CarDef id) | Unlock | Model today |
| --- | --- | --- | --- |
| 1 | Falcon GT (`falcon_gt`) | start | placeholder: cool_drive Tripo body (~4.9k tris, 3 surfaces after the texture bake), **stub** wheels, lights and markers, no interior |
| 2 | Night Viper (`night_viper`) | driver level 4 | placeholder, as above (~4.8k) |
| 3 | Brute V8 (`brute_v8`) | milestone: reach leg 4 | placeholder, as above (~4.7k) |
| 4 | COMING SOON (`slot_4`) | driver level 8 | none (an empty disc, "IN THE WORKS · LEVEL 8") |
| 5 | COMING SOON (`slot_5`) | milestone: reach the coast | none |
| 6 | COMING SOON (`slot_6`) | driver level 12 | none |
| 7 | COMING SOON (`slot_7`) | milestone: 7-day Daily Drive streak | none |
| 8 | COMING SOON (`slot_8`) | milestone: 100 lifetime threads | none |

Stats (CarDef): Falcon GT 270 km/h, 0–200 in 8.8 s, handling 1.00, boost 1.00; Night Viper 285, 9.4 s, 0.92 (quicker lane changes), 0.95; Brute V8 260, 8.2 s, 1.08, 1.05. All stats stay within ±10 % across the roster (`vehicle.tres` `car_stat_spread_pct`), with no upgrades (spec). Stats are the game side's; the briefs below give each car a "lean" only.

#### 4.1.2 Roster design

The cars are an invented Americana-and-beyond collection driving west into the sunset: each from a different era and body type, so eight silhouettes read apart at 100 px in the chase view and on the garage turntable. The three existing names stay (the spec calls them placeholders, but the names are established in saves, leaderboards and the replay verifier's car ids). The five new names are proposals: the owner picks, and should clear all eight for trademark proximity (§7.6, Q1).

Shared rules for every car:

- **Footprint** within **4.3–4.9 m × 1.86–1.98 m** (the three existing cars span 4.5–4.8 × 1.9–1.95). A narrower or shorter car has a smaller hit box (§3.6.2), so the owner signs off every new CarDef size (§7.6, Q4).
- **Paint-agnostic design:** the car must read in obsidian and in pearl. Shape carries the identity; `paint_shade`/`paint_dark` and trim add the second and third tones.
- **A distinct taillight signature** (night readability of your own car) and a distinct front for the garage.
- **Stock rim** of the car's own design (the garage's STOCK option = "the model's own rims").
- **Interior** themed to the car (§4.1.5).
- **Hood view:** the hood camera looks over the hood from `cam_hood`; the hood shape (bulge, scoop, louvres, the paint colour) is the only part of the car visible there, so give it one strong feature.

| Slot | Name (proposal) | Unlock story | Concept and silhouette | Signature details | Taillight signature | Default paint (sRGB) | Stat lean | CarDef body (L × W × H, wheelbase) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | **Falcon GT** (keep) | The starter: the hero | Early-70s fastback GT coupe. Long hood, short deck, a fastback roofline that runs into a small ducktail; slight coke-bottle hips | Twin round headlamps in a dark grille bar; bonnet bulge; side vents behind the front wheels; ducktail spoiler | Three horizontal bars per side in a full-width black panel | (0.9, 0.2, 0.15) (keep) | Balanced, the reference car | 4.5 × 1.9 × 1.25, 2.65 (keep) |
| 2 | **Night Viper** (keep) | Level 4: the first "fast" car | Mid-80s wedge supercar. Knife-edge nose, flat deck, a steep cab-forward windscreen, big side intakes, a wing | **No pop-up headlamps** (they can't animate): a thin full-width headlight slit under the leading edge; NACA ducts; louvred rear glass (trim slats over glass) | One full-width red light bar | (0.12, 0.12, 0.16) (keep): near-black, so the light bar and trim carry the design | Top speed, quickest lane changes, slow off the line | 4.6 × 1.95 × 1.15, 2.6 (keep) |
| 3 | **Brute V8** (keep) | Reach leg 4: earned by distance | Early-70s muscle car. Boxy, wide, a long flat hood with a raised **shaker scoop**, flat roof, wide rear haunches | Chrome front bumper, quad headlamps, side exhaust pipes, a rear spoiler lip, raised white-letter tires | Two large square lamps per side | (0.95, 0.65, 0.1) (keep) | Acceleration and boost, heavier handling | 4.8 × 1.95 × 1.35, 2.8 (keep) |
| 4 | **Kestrel RS** | Level 8 | Late-80s rally-homologation hot hatch/coupé. Short and tall for the roster, boxy, with big bolted-on fender flares, a roof scoop and a tall rear wing | A front **light pod** bar with four round lamps (trim with lamp lenses); mud flaps; a roof vent; wide track | Round quad lamps (two per side) | `brand_teal` #1a9499 | Nimble handling, good acceleration, lower top speed | 4.3 × 1.9 × 1.38, 2.5 |
| 5 | **Coastliner** | Reach the coast: the journey's reward | Early-60s grand tourer **speedster**: long, low, a wraparound low windscreen, twin humps behind the seats, small tail fins, lots of chrome | Chrome bumpers and side spear; oval grille; whitewall tires; wire-look stock rim (thick spokes, ≥ 1 cm) | Bullet lamps at the tips of the fins A 60s pastel: `sky_pale` #b2d1e0 | Cruiser: top speed and boost, softer handling | 4.7 × 1.9 × 1.12 (to the windscreen top), 2.7 |
| 6 | **Afterglow** | Level 12: late-game prestige | Modern mid-engine **longtail** endurance racer: cab-forward bubble canopy, a long tail with a central shark fin and an integrated wing | Low split front splitter, vertical headlamp stacks, big rear diffuser, closed wheel covers at the back (trim discs) | Thin wraparound C-shapes plus a centre strip | `brand_orange` #f57521 | Top speed, balanced otherwise | 4.8 × 1.98 × 1.12, 2.75 |
| 7 | **Daybreak** | 7-day Daily Drive streak: the daily driver | A 70s–80s **coupé utility** (a sport pickup built on a coupe): cab with a short roof, an open bed under a tonneau cover, a roll bar with a light bar | Tonneau (paint_shade) over the bed; roll bar (trim) with 4 lamps (trim lenses, not lights); step-side hint; big rear bumper | Tall vertical lamps at the bed corners `hazard_yellow` #fac729 (sunrise yellow) | Acceleration, heavier, stable | 4.9 × 1.95 × 1.40, 2.95 |
| 8 | **Needle** | 100 lifetime threads: for the threaders | A late-50s **streamliner barchetta**: needle nose, separate pontoon fenders, a single low aero-screen and a head fairing, a very tapered tail. Visually the narrowest car | Tiny oval grille, exposed-look front suspension shapes between nose and fenders (trim), a racing number roundel area (trim_white) | A single round lamp per side, like a jet nozzle `white` #f0ede3, with `trim_reflector_red` accents | Handling specialist, lower boost | 4.5 × 1.86 × 1.10, 2.6 |

Notes on the table: the default paints in slots 4–8 are suggestions from the palette; pick them after the model exists. Slots 5 and 8 are **open cars**, which raises an engineering question (§7.6, Q3): an open cockpit is visible from the chase camera, so its seats, steering wheel and dash top must be drawn outside cockpit mode too. Options: (a) an extra `OpenCabin` mesh (seat tops, dash top, a static steering wheel; trim only) that the game shows outside cockpit mode and hides inside it, while the Interior serves the cockpit camera: one more draw call in the outside views (6 instead of the tested 5, an orchestrator decision) plus a small G4 extension; (b) make them closed (a targa roof for the Coastliner, a bubble canopy for the Needle). Default to (b) until the owner decides.

#### 4.1.3 Paint

- One `paint` slot per car (§3.3.1): everything the player recolours. `paint_shade` and `paint_dark` follow the paint, darker.
- `CarModel.apply_paint` sets the paint colour on every Body surface in the paint slot; the garage changes it in place (no rebuild). Multiplayer recolours remote cars to the crew colour the same way.
- Contrast parts (a black roof, stripes, a black bonnet) are trim and so fixed: use them where the design needs them, knowing the player can't recolour them.
- Test all 12 paints (§2.2) in the garage snap before handing off (§3.12.2).

#### 4.1.4 Rims

- **STOCK** is each car's own `Rim` mesh (≤ 800 triangles, trim only).
- The five other garage rims (MESH level 3, DEEP DISH 4, BLACKOUT 6, GOLD 8, TURBINE 11) are **procedural** today (`CarModel.build_styled_rim_mesh` from the `RimStyle` fields in `catalog.tres`: spoke count 5–12, `radius_frac` 0.62–0.68, optional lip ring, three colours; ≤ 100 triangles). They are swapped in before the draw merge (`CarModel.apply_rim`) and shared by the four wheels.
- **Deliverable (P4):** five authored rim meshes, one per style, replacing the procedural ones via G5. Author each at **radius 1.0 m** (the game scales it to `wheel_radius × radius_frac`), face toward +X, origin at the hub centre on the face plane, depth ≤ 0.15 (inward, −X), ≤ 800 triangles, trim materials in the style's colours (MESH: 10 thin spokes, steel/steel_dark; DEEP DISH: 6 spokes, a wide polished lip; BLACKOUT: 5 wide spokes, all dark; GOLD: 6 spokes, gold face (`trim_` + a gold: needs a palette colour, e.g. `wheat_gold` or a new `rim_gold`), a lip; TURBINE: 12 curved fan blades, a dark lip). Keep the style's name and silhouette: the list, its names and unlock levels are data the game already shows.

#### 4.1.5 Interiors

Per car (§3.6.5), ≤ 5,000 triangles total, three objects (`Cabin`, `SteeringWheel`, `Gauges`). Theme each to its car:

| Car | Interior theme |
| --- | --- |
| Falcon GT | Wood-look (`bark`) dash strip, three-spoke wheel, twin round gauges in a hooded binnacle |
| Night Viper | Angular binnacle, digital-look gauge quad, a thick two-spoke wheel, a high centre console |
| Brute V8 | Flat metal dash (`steel_dark`), a big thin-rimmed wheel, a pistol-grip shifter |
| Kestrel RS | Upright rally dash, a roll cage (trim tubes, ≥ 3 cm), a small three-spoke wheel |
| Coastliner | Body-colour-look dash top (use a trim tone close to the default paint; paint can't be used in the Interior), chrome gauge rings, a big two-spoke wheel |
| Afterglow | Carbon-look (`ink`) tub, a yoke-like wheel (still round enough to spin through 360°), a screen strip (`interior_screen`) |
| Daybreak | Bench-seat look, a column shifter, a large thin wheel |
| Needle | A minimal cockpit: a single central gauge pair, a wood-rim wheel |

**Acceptance for interiors** uses G4: the cockpit mode shows Body + Interior (`CameraRig.set_mode(&"cockpit")`, the dev tools), and `car_preview --cam=cockpit` snaps the same view.

#### 4.1.6 Lights

Per §3.6.4. Every car has all 11 light nodes, even if a lamp is shared (for a car with one reverse lamp, `reverse` holds that one; for combined tail/brake lamps, the brake mesh sits just proud of the tail mesh). Lamp faces: at least 15 cm × 8 cm each (the stub lamp is 34 × 12 cm, a signal 14 × 9 cm) so they read at range.

#### 4.1.7 Garage presentation

The turntable (`src/ui/screens/garage_turntable.gd`, docs/GARAGE.md) spins the car at 14°/s from a front three-quarter (yaw 215°) under the title's live sky at golden hour (`attract_sky_t` 0.42), with the same shaders as the road and the run's blob shadow. The car sits on a procedural disc (radius 2.85 m; nothing to model). This is the closest view in the game: the sills, wheel faces, lamp shapes and the front must hold up at 1 cm ≈ 3 px.

#### 4.1.8 Damage (later)

Spec: "alternate bumper_F/R and hood meshes" under `Damage`, and "real damage states come with the new modular models". Nothing reads `Damage` yet except the body motion and the ghost (which skips it). Not in scope until the game side designs the states; leave room (separate bumper geometry in the Body is fine for now).

#### 4.1.9 Per-car deliverables and acceptance

Deliverables per car: `art/blender/cars/<id>.blend`; `assets/cars/<id>/<id>.glb`, `<id>.car.json`, `<id>_lod1.glb` (one object `Body` with the same slots, wheels merged in at rest, ≤ 5k triangles); `art/renders/<id>/` (chase, garage three-quarter, rear, side, cockpit eye); a LICENSES row.

Acceptance (all by the game side after G1/G7): `test_check_car_assets` and `test_car_visual` green with nothing stubbed; ≤ 5 merged draws; the Body within 5 % of the CarDef; garage snaps in all 12 paints and all 6 rims; the car preview across the 7 keyframes on both renderers and `tools/parity.sh` within limits; the cockpit view (after G4) with the road visible, the hood in the lower fifth and the wheel turning; the owner's approval of the look.

### 4.2 Traffic vehicles (10 types, 17 models)

The spec asks for about 14 models ("3 sedans, 2 hatchbacks, 2 SUVs, a pickup, a delivery van, a semi with 2 trailer variants, a coach bus, 2 motorbikes and 2 sports cars"); the coupe type adds one. All 17 exist as **procedural in-house models** (`tools/traffic_models/build_traffic_models.gd`, logged in `assets/LICENSES.md`), 360–704 triangles each. They work; the art track replaces them with modelled versions that read better (spec: "made in-house with AI 3D generators and Blender").

| Type (`data/vehicle_types/`) | Driver profiles | Body L × W × H (m) | Models (`assets/traffic/`) | Tris today | Paint | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| `sedan` | cruiser, commuter, hesitant | 4.8 × 1.85 × 1.45 | `sedan_a`, `sedan_b`, `sedan_c` | 384 each | biome palette | The most common car: three clearly different sedans (e.g. a boxy 80s saloon, a rounded 2000s family car, a notchback with a tall greenhouse) |
| `hatchback` | cruiser, hesitant | 4.2 × 1.8 × 1.5 | `hatchback_a`, `hatchback_b` | 384 | biome | Upright tail with big vertical lamps |
| `suv` | commuter, hesitant | 4.9 × 1.95 × 1.8 | `suv_a`, `suv_b` | 408 / 384 | biome | One boxy off-roader (spare wheel on the back), one crossover |
| `pickup` | commuter, hesitant | 5.4 × 2.0 × 1.9 | `pickup_a` | 424 | biome | Open bed with a load (a covered crate) |
| `van` | van | 5.9 × 2.05 × 2.6 | `van_a` | 360 | biome | Tall, blocks sightlines: the rear doors must read |
| `semi` | truck | 16.0 × 2.55 × 4.0 | `semi_box`, `semi_tank` | 662 / 704 | tractor: biome; trailer: fixed white / steel | One rigid mesh; box trailer and tank trailer; a light bar and reflectors on the trailer rear |
| `coach` | bus | 12.0 × 2.55 × 3.5 | `coach_a` | 398 | **fixed** livery palette (5 colours: teal, orange, navy, barn red, sign green) | White body, the livery as a paint stripe, a window band |
| `motorbike` | motorbike | 2.2 × 0.8 × 1.3 | `motorbike_sport`, `motorbike_cruiser` | 406 / 432 | **fixed** palette (ink, barn red, sign blue, orange, white, yellow, …) | **With riders** (fixed colours); a single central head and tail lamp (glow spacing 0) |
| `sports` | aggressive, racer, hesitant | 4.5 × 1.95 × 1.2 | `sports_a`, `sports_b` | 372 / 408 | biome | Racers pass the player at 190–250 km/h: a clear, aggressive rear |
| `coupe` | aggressive, racer, hesitant | 4.6 × 1.9 × 1.3 | `coupe_a` | 384 | biome | |

Deliverables per model: `art/blender/traffic/<model>.blend`, `art/export/traffic/<model>.glb` + `.traffic.json`, renders (rear at 50 m, three-quarter, side). Keep the 17 model ids (data points at them). Adding a model is a draw call when on screen (§3.5): ask first.

Acceptance (after G3): `test_every_vehicle_type_has_valid_models` green; the lineup snap (`--scenario=lineup --cam=quarter`, and `--pick=<index>` close-ups) on both renderers; the chase snap at 0.2 / 0.38 / 0.66 with brake lights and blinkers readable; `tools/drawcalls.sh` at leg 8 (city and valley) under 150k triangles and at most +0 draw calls against the reference.

Traffic also serves the **opposite carriageway** (visual only, same models) and the **set pieces** (truck walls, convoys of one model and colour with hazards). No extra models needed.

### 4.3 Set-piece props

All procedural today (`src/world/set_pieces/set_piece_mesh_builder.gd`, numbers in `data/set_pieces/look.tres`), one draw per live piece plus one MultiMesh for cones. Low triangle counts, retro-reflective faces (class 1) and a flashing arrow (class 4). Candidates for modelled kit parts (P3, needs G10):

| Part | Today (look.tres) | Where | Priority |
| --- | --- | --- | --- |
| Traffic cone | 0.75 m tall, 0.42 base, 6 sides, `brand_orange` with a `white` reflective collar | Road works (up to 160, one MultiMesh); hit test uses a square footprint | P3 (seen close at speed) |
| Barrier segment | 3.8 m long, 0.9 m high, `white` with `reflector_red` stripes, 0.2 m gaps | Road works closed lanes | P3 |
| Arrow board trailer | board 1.5 m high from 1.6 m, `ink` board, `hazard_yellow` frame, `brand_orange` trailer, `reflector_amber` arrow lamps flashing | Road works | P3 |
| Crash attenuator | 3.0 × 0.9 × 0.9 m, `hazard_yellow` with `ink` stripes | Merge-zone gore nose | P3 |
| Warning sign (post + panel) | 3.2 × 1.8 m panel at 1.4 m, text drawn by the game | Road works ("ROAD WORKS"), merge zone ("MERGING TRAFFIC") | P4 |

The toll booths and canopies belong to the toll gantry landmark (§4.6); the on-ramp, gore and road legends are road geometry (keep procedural).

### 4.4 Road furniture (common to every biome)

In-house procedural meshes (`tools/props/build_props.gd`, `assets/props/common/`), placed as MultiMesh rhythm by `src/road/roadside.gd`. These pass the camera constantly: they "sell speed" (spec).

| Mesh | Size today (W × H × D m) | Tris | Emissive | Placement | Priority |
| --- | --- | --- | --- | --- | --- |
| `light_pole` | 7.1 × 10.45 × 0.42 (twin-arm, on the median) | 92 | heads `lamp_warm__lamp` (with street-lamp light pools on the road) | every 50 m | P3 |
| `reflector_post` | 0.1 × 1.16 × 0.11 | 32 | reflector `__reflector` (amber / red) | every 25 m at the guardrail | P3 |
| `guardrail_post` | 0.15 × 0.76 × 0.1 | 10 | — | every 4 m along the guardrail (the rail itself is road geometry) | P3 (keep tiny: one of the most-instanced meshes) |
| `sign_gantry` | 18.0 × 8.5 × 1.18, `span_m` 17.5 | 218 | sign faces `__reflector` | roadside gantries | P3 |
| `billboard_sundog`, `billboard_mesa_cola`, `billboard_coyote_motel` | 12 × 9.5 × 1.2 | 88–100 | optional `__lamp` floodlights | scattered, toe-in to face drivers | P3: invented brands (Sundog Diner, Mesa Cola, Coyote Motel) told in flat relief shapes, no text textures |

The guardrails, median barrier, road surface, lane markings, raised reflectors, tunnel shells, canyon cliffs, the city's elevated deck and the ocean are built into the road chunk meshes or feature nodes (`src/road/road_chunk_mesher.gd`, `src/world/**`): **not modelled**.

### 4.5 Biome props (56 meshes today, all procedural in-house)

Leg order (docs/BIOMES.md): farmland (leg 1) → desert (2–3) → canyon (4–5) → city (6–7) → valley fog (8) → coast (9+, endless). Every prop: ≤ 400 triangles, one surface, §3.8. Keep the file names (the biome data points at them); new variants go through the game side (draw calls).

| Biome (`data/biomes/`) | Meshes (`assets/props/<biome>/`, triangles today) | Signature (spec) | Priority |
| --- | --- | --- | --- |
| **Farmland** (`farmland.tres`) | crop tiles `crop_wheat` 24, `crop_straw` 32, `crop_green` 28, `crop_plowed` 36 (unit squares); yards `farmstead` 158, `grain_bins` 274, `windpump` 292, `water_tower` 204; trees `tree_poplar` 39, `tree_round` 56; `wind_turbine` 74 (108 m tall); `fence_ranch` 26 (10 m) | Golden fields, silos, windmills, water towers, long views | P3 (first biome players see) |
| **Desert mesas** (`desert.tres`) | `mesa` 154 (372 m wide), `butte` 115; `saguaro` 86, `cactus_small` 138; `scrub` 88; `rocks` 140; `fence_desert` 34 (12 m, barbed wire) | Red rock mesas, cacti, long straights | P3 |
| **Canyon pass** (`canyon.tres`) | `boulders` 112, `pine` 49, `spire` 89 (hoodoo, 30 m), `scrub` 88 (cliffs and tunnels are road geometry) | Cliffs, tunnels, curves | P3 |
| **City at night** (`city.tres`) | buildings on `world_windows.tres`: `office_tower` 380, `apartment_block` 314, `midrise` 234, `warehouse` 112, `skyscraper` 372 (134 m); `sound_wall` 70; `street_tree` 66; `neon_board` 110, `neon_blade` 88 (`__lamp` neon); `plaza_tile` 2 | Skyline, elevated highway, neon billboards with invented names ("Volt Noodle Bar", "Starline Motel") | P3 |
| **Valley fog** (`valley_fog.tres`) | `conifer` 40, `broadleaf` 46; copses `conifer_clump` 144, `mixed_clump` 144; `valley_barn` 118, `valley_farm` 96; meadow tiles `meadow_green` 16, `meadow_flowers` 20, `meadow_hay` 16; `fence_rail` 34 (10 m) | Forests, meadows, farms, low fog | P3 |
| **Coastal highway** (`coast.tres`) | `cliff_rock` 63, `coast_house` 76, `palm` 146, `scrub` 123; islets `sea_stacks` 140, `lighthouse_islet` 239 (lantern `__lamp`) | Ocean, cliffs, the sun sinking into the sea | P3 (the destination and the endless road) |

Horizon silhouettes (mesas, mountains, skyline, headlands, islands, ridges) are **procedural in `assets/shaders/horizon.gdshader`** (styles per layer in `BiomeDef.horizon_layer_style`; `BiomeDef.horizon_cards` is unused). No Blender work unless the owner wants authored silhouettes; then they would be height profiles, not meshes (§7.6, Q10).

### 4.6 Checkpoint landmarks

Procedural placeholders (`src/world/landmarks/landmark_builds.gd`, docs/LANDMARKS.md), one style set for all biomes; biomes choose which kinds appear (`BiomeDef.landmark_styles`). Spec: "Each is a hand-built scene per biome style."

| Landmark | Today | Kit parts to model (P4, G10) |
| --- | --- | --- |
| **Express toll gantry** | beam and columns across the road (middle column on the median), booth islands with canopies on both sides, lane panels; ~0.8k tris | column, beam module (per 3.6 m lane), booth, canopy module, lane-panel frame, lamp strips (`__lamp`) |
| **Suspension bridge** | 360 m span, 54 m towers, cables and suspenders, backstays and anchor blocks, cable lamps, tower beacons; ~3.3k tris | tower (per cross-section width), deck-edge and walkway module (8 m), suspender module, anchor block |
| **Big sign gantry** | median upright to the outer footing, a panel with the leg name and distance (text by the game); ~0.3k tris | upright, truss module, panel frame (blank `__reflector` face, `text_1..2` Empties) |
| **Tunnel portal** | portal faces with chamfered openings, twin bores, the hill (road geometry); ~0.6k tris | portal face per lane count (2 / 3 / 4), wing walls; the hill and shell stay procedural |
| Warning sign | panel on two posts, `CHECKPOINT 1 KM` etc. by the game; ~0.1k tris | post and panel frame (blank) |

Per-biome variants (a desert-adobe toll plaza, a city steel gantry, a coast bridge) are the spec's intent; decide the variant list with the owner after the base kits work (§7.6, Q8). The multiplayer loop uses the same kinds as sector gantries (docs/LOOP_MAP.md: a toll gantry start/finish, sign gantries, a tunnel portal, the bridge).

### 4.7 Procedural, derived or out of scope (no modelling)

| Asset | Why no modelling | Where |
| --- | --- | --- |
| Road surface, markings, raised reflectors, guardrails, median barrier, tunnel shells, canyon cliffs, road-tunnel hills, the fork's gore | Built per chunk from the road's cross-section | `src/road/road_chunk_mesher.gd` |
| Sky dome, sun, stars, clouds, horizon cards, heat shimmer | Shaders driven by the colour script | `assets/shaders/sky*.gdshader`, `clouds.gdshader`, `horizon.gdshader` |
| Ocean and river, elevated stretches, fog cards | Feature nodes built along the road | `src/world/ocean/`, `src/world/elevated/`, `src/world/fog_cards/` |
| Light pools, headlight cones, glow sprites, blob shadows, speed lines, particles | Additive decals and sprites | `assets/shaders/light_decal.gdshader`, `glow.gdshader`, `blob_shadow.gdshader`, `fx_particles.gdshader` |
| Daily Drive ghost car | Merged from the player car model | `src/world/ghost/ghost_car.gd` |
| Other players' cars (multiplayer) | The player car models, recoloured and faded | `src/net/rooms/remote_car_view.gd` |
| Garage turntable disc | Procedural disc | `src/ui/screens/garage_turntable.gd` |
| The generic cockpit | Procedural fallback for cars without an interior | `src/camera/cockpit/cockpit.gd` |
| Crash bodies | The car's `CollisionBox` and the traffic box | `src/run/crash_sequence.gd` |
| HUD, icons, achievements, app icons, fonts | 2D (out of scope for this brief) | `src/ui/**`, `platform/**` |

### 4.8 Wishlist (optional; each needs a game-side slot and a budget check)

Not required by the spec; would add variety. Ask the owner before starting any of them.

- A roadside **diner and gas station** set for the invented brands (Sundog Diner, Mesa Cola, Coyote Motel): 1–2 meshes per biome as scatter props.
- **Overpass** or pedestrian bridge crossing the highway (would need road-space bending and clearance, like landmarks).
- A **car-carrier truck** (spec, Car Hopper: "a car-carrier truck works as a ramp"), for the future mode.
- **Livery masks** for the player cars (the shader supports one; spec: "liveries later").

### 4.9 Counts

| Group | Assets | Of which exist as placeholder / procedural |
| --- | --- | --- |
| Player cars | 8 cars (3 remodels + 5 new), each with an interior and a LOD1 | 3 placeholder bodies (stub wheels, lights, markers; no interiors) |
| Garage rims | 5 authored (STOCK comes with each car) | 5 procedural |
| Traffic | 17 models (10 types) | 17 procedural |
| Set-piece props | 5 kit parts | 5 procedural |
| Road furniture | 7 meshes | 7 procedural |
| Biome props | 56 meshes (incl. 3 fences, 7 crop/meadow tiles) — 49 excluding the 7 unit tiles | 56 procedural |
| Landmarks | 5 kinds as kit parts (4 landmarks + the warning sign) | 5 procedural |
| **Total** | **103 deliverables** (8 + 5 + 17 + 5 + 7 + 56 + 5) plus 8 interiors and 8 LOD1s inside the car files | |

---

## 5. Production order

Player cars first, as the owner wants. Each phase ends with a handoff (§6) and the game side's acceptance before the next phase starts; P5–P7 can overlap once P0 is done.

| Phase | You deliver | Game side does | Acceptance |
| --- | --- | --- | --- |
| **P0 Pipeline** | `tools/blender/` scripts: `wb_palette.py` (reads the three palette sources), `wb_scaffold_car.py` (builds the §3.6 tree and a dimension box from `data/cars/<id>.tres`), `wb_validate.py` (§3.12.1), `wb_export.py` (§3.10 settings + sidecar), and the same for traffic and props. A **calibration file**: `assets/cars/calib_box/calib_box.glb` (a box car with every convention node, one face per palette colour on the Body as `trim_<name>`, the three paint shades, every lamp material) and `art/export/props/common/calib_swatch.glb` (one quad per palette name, one per emissive suffix) | G1, G9, G6 (done; the game side reruns them on your files) | G9 green: every palette name arrives exact; the calib car passes `test_check_car_assets` (with its own temporary CarDef, as `tests/art/fixtures/calib_car/calib_car.tres` does) with nothing stubbed; 5 merged draws; `tools/art/convert.gd --check` clean on your swatch |
| **P1 Hero car: Falcon GT** | The full car (§4.1.9) including interior and LOD1. First a **design sheet** for the owner (side, top, front, rear, three-quarter renders on a flat-colour background, and the chase view) before detailing | G7 (repoint `data/cars/falcon_gt.tres`), G4 (cockpit with model interiors) | §4.1.9; owner approves the look in the web build |
| **P2 Night Viper, Brute V8** | Two remodels to the same standard | G7 | §4.1.9 for each |
| **P3 Five new cars** | Design sheets for all five first (owner picks names and approves silhouettes), then the cars in slot order 4 → 8 | G7 per car (CarDef stats and dims, `Run.CAR_PATHS`, catalog slot id, the save migration) | §4.1.9; each slot drivable in the garage; `meta/test_progression.gd` green |
| **P4 Rims and cockpit polish** | Five authored rims (§4.1.4); interior fixes from the owner's cockpit playtest | G5; the owner decides whether to re-enable the cockpit camera (`cockpit_player_enabled`) | `test_car_look` green; garage snaps with every rim on every car |
| **P5 Traffic** | 17 models, in order of frequency: sedans, hatchbacks, SUVs, sports and coupe, pickup, van, semis, coach, motorbikes | G3 | §4.2 |
| **P6 World** | Road furniture (§4.4), then biome props in leg order: farmland, desert, canyon, city, valley, coast | G2 | per biome: `test_roadside*`, `test_biome*` green; `tools/snap.sh src/road/dev/biome_preview.tscn --biome=<id> --renderer=both --sweep=sky_t:0,0.38,0.5,0.58,0.66`; the run's draw calls and triangles per biome (docs/PERF.md table) not worse by more than 10 % |
| **P7 Set pieces and landmarks** | Kit parts (§4.3, §4.6) | G10 | `tests/world/test_set_piece_view.gd`, `test_landmarks.gd`, `test_landmark_clearance.gd` green; landmark preview snaps |
| Later | Damage meshes, liveries, wishlist | as designed | as designed |

---

## 6. Handoff protocol

### 6.1 Branch and commits

- Branch from `claude/game-implementation-phases-asl5jz` (the integration branch; plan §1 "Git"): `art/<phase>-<asset>`, for example `art/p1-falcon-gt`. One phase or one asset group per branch.
- Commit only your owned paths (§1.1). Commit the `.blend`, the exports, the sidecars, the renders and the scripts together, one commit per asset where practical: `ART P1: Falcon GT model, interior and LOD1 (in-house, Blender)`.
- Push the branch and tell the owner; the orchestrator merges after the game side's gate (§6.3). Never commit to the integration branch directly.
- **Never overwrite** a file you don't own (the existing `assets/traffic/*.res`, `assets/props/**/*.res`, `data/**`): the converters write those.

### 6.2 Your checklist per delivery

- [ ] §3.12.1 validation passes (paste the script's summary into the handoff note: triangle counts, sizes, names, draws expected).
- [ ] Exported with the §3.10 settings; sidecar JSON present; no textures in the `.glb`.
- [ ] Renders in `art/renders/<asset>/` from the standard views.
- [ ] A row in `assets/LICENSES.md` under **"In-house generated assets"**: asset, files, generator. For example: `| Falcon GT (player car, interior, LOD1) | assets/cars/falcon_gt/*, art/blender/cars/falcon_gt.blend | in-house, Blender (tools/blender/wb_export.py), <your name/agent> |`. If an AI 3D generator was used for a base mesh, name the tool and note that the owner holds the rights under its terms (the placeholders' row, "Owner-supplied placeholders", is the pattern).
- [ ] No third-party meshes. References (photos, blueprints) are for looking only and never enter the repo.
- [ ] The handoff note (below).

**Handoff note template** (in the commit message body or a message to the owner):

```
ART <phase>: <asset(s)>
Built: <what>, <triangles per part>, <size vs CarDef / VehicleType>
Files: <paths>
Validation: <wb_validate summary>
Snaps: <run by me | needs the container>
Deviations / open questions: <anything that bends §3, or a design choice for the owner>
needs: <game-side tasks, e.g. "G7: CarDef dims 4.3 x 1.9 x 1.38, wheelbase 2.5 for kestrel_rs">
```

### 6.3 What the game side does after each delivery

1. Merge the art branch into a work-package branch; run `tools/godot.sh --headless --path . --import`.
2. Register (G7 for cars, G3 for traffic, G2 for props, G10 for kits):
    - **Car:** write `assets/cars/<id>/<id>.glb.import` (and `_lod1`) with `import_script/path="res://assets/cars/car_import.gd"`, `nodes/use_name_suffixes=true`, `meshes/ensure_tangents=false` (`tools/art/make_calibration.gd`'s `IMPORT_TEMPLATE` is the template); import; `data/cars/<id>.tres` (`model_scene_path`, stats, body, `default_paint`); `Run.CAR_PATHS` (`src/run/run.gd`) and `CAR_PATHS` in `src/dev/car_drive.gd`; the slot in `data/cars/garage/catalog.tres` with **id = the CarDef id** and, for a COMING SOON slot, `former_ids = PackedStringArray("slot_N")` (the save migration). A remodel keeps its id: only `model_scene_path` changes.
    - **Traffic:** `tools/godot.sh --headless --path . --script res://tools/art/convert.gd -- --kind=traffic` (writes `assets/traffic/<model>.res`, `.tscn`, `_lod1.res`; the model ids and `data/vehicle_types/*.tres` stay).
    - **Props:** `... convert.gd -- --kind=props` (writes `assets/props/<biome>/<mesh>.res`; the biome data keeps pointing at the same paths).
    - **Rim:** import `assets/cars/rims/<id>.glb` (its `.rim.json` selects the rim path), then set the style's `mesh_path` in the catalog.
3. Run the §3.12.2 tests and the full fast tier; `tools/lint`; `tools/check_warnings.sh`.
4. Take the §3.12.2 snaps on both renderers across the keyframes, `tools/parity.sh`, and `tools/drawcalls.sh` in the busiest biome; compare with the phase's reference set.
5. Report problems back to you as a list against §3 (rule, asset, what to change). Fix in the same art branch.
6. Update `assets/LICENSES.md` (remove the replaced placeholder row when a placeholder is gone), `docs/GARAGE.md`, `docs/ACCEPTANCE.md` (SP-A2) and the plan's D26 row (orchestrator).

---

## 7. Appendix

### 7.1 Files

| Path | What |
| --- | --- |
| `WESTBOUND HANDOFF.md` | The spec: Performance budget; World, road and visual direction; Cars, garage, progression and art pipeline |
| `docs/IMPLEMENTATION_PLAN.md` | Art track ART1–ART5; deviations D2 (CC0 interim), D11 (cockpit), D26 (roster placeholders); O6 (cockpit hidden) |
| `docs/CONTRACTS.md` §13 | Look contract: shader globals, vertex conventions, materials, renderer parity, traffic model convention |
| `docs/GARAGE.md`, `docs/COCKPIT.md`, `docs/NIGHT.md`, `docs/BIOMES.md`, `docs/LANDMARKS.md`, `docs/SET_PIECES.md`, `docs/PERF.md`, `docs/TOOLS.md` | The systems your assets plug into |
| `src/vehicle/car_model.gd` | `CarModel`: the convention, stubbing, `apply_paint`, `apply_rim`, draw merging |
| `src/vehicle/car_visual.gd` | Body roll and pitch, wheel spin and steer, brake lights, steering wheel |
| `src/vehicle/car_def.gd`, `data/cars/*.tres` | `CarDef` |
| `src/vehicle/rim_style.gd`, `src/vehicle/car_look.gd`, `data/cars/garage/catalog.tres` | Rims, paints, roster slots |
| `assets/cars/car_import.gd`, `assets/cars/placeholder/*` | The import script and the placeholders |
| `assets/shaders/vehicle.gdshader`, `assets/shaders/materials/vehicle_*.tres` | The car shader and its slot materials |
| `src/camera/camera_rig.gd`, `src/camera/cockpit/*` | Hood and cockpit cameras, the procedural cockpit |
| `src/traffic/traffic_view.gd`, `src/traffic/view/traffic_lights.gd`, `assets/shaders/traffic.gdshader` | Traffic drawing, parts, lamp bits |
| `src/vehicle/vehicle_type.gd`, `data/vehicle_types/*.tres` | `VehicleType` |
| `tools/traffic_models/*` | The procedural traffic models (their recipes and the mesh builder) |
| `assets/palette/*`, `tools/props/palette_biomes_4_6.tres`, `tools/props/biome_colors.gd` | Colours |
| `tools/props/*`, `src/road/roadside.gd`, `src/road/roadside/*`, `src/road/biome_def.gd`, `data/biomes/*.tres` | Props and their placement |
| `assets/shaders/world_common.gdshaderinc`, `world.gdshader`, `world_windows.gdshader` | World shading and emissive classes |
| `src/world/landmarks/*`, `data/tuning/landmarks.tres` | Landmarks |
| `src/world/set_pieces/*`, `data/set_pieces/look.tres` | Set-piece props |
| `data/tuning/progression.tres` (`ProgressionTuning`) | Asset triangle budgets, turntable numbers |
| `data/tuning/quality.tres` (`QualityTuning`) | Draw-call and triangle budgets |
| `data/tuning/lives.tres` | `collision_inset_m` = 0.08 |
| `tests/unit/test_check_car_assets.gd`, `test_car_visual.gd`, `test_traffic_view.gd`, `test_roadside.gd`, `test_roadside_biomes.gd`, `test_biome_coast_city_valley.gd`, `tests/meta/test_car_look.gd`, `tests/camera/test_cockpit_camera.gd`, `tests/ui/test_garage.gd`, `tests/world/test_ghost_car.gd` | The tests that load models |
| `assets/LICENSES.md` | Asset log |

### 7.2 Classes and fields you will meet

| Class | Fields that matter for art |
| --- | --- |
| `CarDef` | `id`, `display_name`, `model_scene_path`, `length_m`, `width_m`, `height_m`, `wheelbase_m`, `default_paint`, stats (`top_speed_kmh`, `zero_to_200_s`, `handling_scale`, `boost_capacity_scale`) |
| `CarModel` | `SLOT_NAMES` (paint, trim, glass, lamp, signal), `WHEEL_NAMES`, `LIGHT_NAMES`, `MARKER_NAMES`, `required_paths()`, `MERGED_DRAW_SURFACES_MAX` (5), `COLOR_*` |
| `RimStyle` | `id`, `display_name`, `model_default`, `unlock_level`, `spokes`, `radius_frac`, `spoke_width_frac`, `lip_frac`, `face_color`, `spoke_color`, `lip_color` (+ `mesh_path`, G5) |
| `GarageSlot` / `PaintOption` | `id` (= CarDef id), `car_path`, `unlock` (start, level, leg, coast, daily_streak, threads), `unlock_level`; paint `color` |
| `VehicleType` | `id`, `length_m`, `width_m`, `height_m`, `blocks_sightlines`, `is_motorbike`, `model_scene_paths` |
| `RoadsideProp` | `mesh_paths`, `variant_weights`, `pattern`, `density_per_km`, setbacks, `facing`, `yaw_offset_deg`, scale range |
| `BiomeDef` | `scatter_props`, `field_grid` (crop, yard and tree meshes), `fence_mesh_path`, `landmark_styles`, `traffic_palette`, look colours |
| `ProgressionTuning` | `player_body_tris_lod0/1`, `player_interior_tris`, `traffic_tris_lod0/1`, `rim_tris`, `turntable_*` |
| `CameraTuning` | `mode_marker` (Markers/cam_hood, Markers/cam_cockpit), `cockpit_eye_*_frac`, `cockpit_player_enabled`, FOV |

### 7.3 Axis cheat sheet

| | Blender | glTF / Godot |
| --- | --- | --- |
| Up | +Z | +Y |
| Forward (nose, direction of travel) | +Y | −Z |
| Right | +X | +X |
| Car left side | −X | −X |
| Steering wheel turn axis (toward the driver) | object local −Y | node local +Z |
| Tire and rim spin axis | X | X |
| Rim face (right wheels) | +X | +X |

### 7.4 Commands

```
# Godot (container or GODOT=... locally)
tools/godot.sh --headless --path . --import
tools/test.sh [--filter=<substring>]
tools/lint
tools/check_warnings.sh
tools/snap.sh <scene.tscn> [--renderer=compat|mobile|both] [--sweep=sky_t:...] [--key=value ...]
tools/parity.sh <scene.tscn> [snap options]
tools/drawcalls.sh <scene.tscn> [--set=prop:value] [--key=value ...]

# Game-side art pipeline (WP-ART-G)
tools/godot.sh --headless --path . --script res://tools/art/convert.gd -- --kind=traffic|props|all [--src=art/export] [--out=res://assets] [--only=<name>] [--check]
tools/godot.sh --headless --path . --script res://tools/art/make_calibration.gd     # rewrite tests/art/fixtures, then --import
tools/test.sh --filter=art/

# Rebuilding today's procedural assets (game side; they keep converted meshes)
tools/godot.sh --headless --path . --script res://tools/props/build_props.gd
tools/godot.sh --headless --path . --script res://tools/props/build_props_desert_canyon.gd
tools/godot.sh --headless --path . --script res://tools/props/build_props_4_6.gd
tools/godot.sh --headless --path . --script res://tools/traffic_models/build_traffic_models.gd

# Blender (your scripts; examples)
blender -b art/blender/cars/falcon_gt.blend --python tools/blender/wb_validate.py
blender -b art/blender/cars/falcon_gt.blend --python tools/blender/wb_export.py -- --asset=car --id=falcon_gt
```

### 7.5 Colour-script keyframes (for snaps and self-review)

`sky_t`: 0 morning · 0.2 afternoon (run start) · 0.38 golden hour · 0.42 the title and garage · 0.5 sunset · 0.58 dusk · 0.66 night · 0.85 dawn (`data/tuning/sun.tres`, `camera.tres`).

### 7.6 Open questions for the owner

| # | Question | Default until answered |
| --- | --- | --- |
| Q1 | **Names.** "Falcon GT" and "Night Viper" sit close to real car names (Ford Falcon GT, Dodge Viper). Keep them, or rename with the remodels? And pick the five new names (§4.1.2) | Keep the three; new names as proposed, clearly marked as proposals |
| Q2 | **How faceted?** The spec says flat-shaded low-poly. For the player car in the garage, a moderate facet count (6–10k triangles) looks refined; 2–4k looks deliberately chunky like the traffic. Which? | 6–10k, big clean facets |
| Q3 | **Open cars** (Coastliner, Needle): real open cockpits need an extra draw and a G4 variant (§4.1.2) | Closed: targa roof, canopy |
| Q4 | **New car sizes** set hit boxes (§3.6.2). Approve the proposed dimensions (4.3–4.9 × 1.86–1.98 m)? | As proposed, subject to the orchestrator |
| Q5 | **Mirrors** count toward the tested width (5 %). Allow the test (and the collision box) to exclude mirrors, as traffic's test allows +12 %? | Compact mirrors within 5 % |
| Q6 | **AI 3D generators** (spec: "AI 3D generators + Blender"): may the Blender agent use one for base meshes, and which (its terms decide ownership)? | Blender only |
| Q7 | **Replace the procedural traffic?** It is in-house and within budget; modelled traffic reads better but costs P5's time | Yes, after the cars (P5) |
| Q8 | **Landmark variants per biome** (spec: "a hand-built scene per biome style"): which biomes get their own toll plaza, bridge or gantry style? | One kit, biome colours only |
| Q9 | **`art/` folder** for `.blend` sources and exports in the repo (with `.gdignore`)? Orchestrator decision | Yes |
| Q10 | **Horizon silhouettes** stay procedural (shader)? | Yes |
| Q11 | **Default paints** for the new cars (§4.1.2) | Proposed in the table |
| Q12 | The owner's PC OS (the Godot test tools need bash; snaps need Linux) | Snaps run in the container |
| Q13 | **Traffic LOD1 distance** (G8): `traffic_view.tres` `lod1_distance_m` = 60 m (a car is ~14 px wide there). Each model with a LOD1 costs one more draw while it has near and far vehicles; worth it only if a modelled traffic car is well above the ~400-triangle procedural ones | 60 m; `<= 0` turns LOD off |
| Q14 | **Far player cars** (G8): remote multiplayer cars and the Daily Drive ghost could draw `<id>_lod1` at distance (`CarModel.load_lod1_mesh`); both are near the player today. Wire it when multiplayer needs it (the net and ghost owners) | Not wired |
