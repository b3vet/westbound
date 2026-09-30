# Night lighting (WP5.4)

Spec: World → Night lighting (no real lights), Core loop → Night, World → Color script,
Performance budget, Cameras → Glare rule. Plan decision D8: no traffic high-beam reactions;
the player has a manual high-beam toggle instead.

Nothing here is a real light. Every effect is emissive geometry, an additive road decal or
a term in the shared world shader, and every one follows the color script's emissive ramps
(`emissive_headlight`, `emissive_streetlamp`, `emissive_reflector`), which are 0 by day.

## Pieces

| Piece | Code | Draws | Driven by |
| --- | --- | --- | --- |
| Player fake light | `PlayerHeadlights` → `SkyRig.set_player_light()` → `wb_player_light_*` | no draw call (a shader term) | headlight ramp × beam gain |
| Player cone decal | `src/vehicle/player_headlights.gd`, `materials/light_cone.tres` | 1 (a road-following strip) | headlight ramp |
| Traffic cones | `src/traffic/view/headlight_cones.gd`, `materials/traffic_cone.tres` | 1 MultiMesh | headlight ramp, `FLAG_HEADLIGHTS` |
| Street-lamp pools | `src/road/roadside/street_lamp_pools.gd`, `materials/lamp_pool.tres` | 1 MultiMesh | street-lamp ramp |
| Lamp heads | light pole mesh, emissive class 2 (`world.gdshader`) | (part of the poles) | street-lamp ramp |
| Retro-reflectors, sign faces | emissive class 1 + `wb_retro_light()` in `world.gdshader` | (part of the props) | reflector ramp + the player's fake light |
| Traffic lamps and glow sprites | `traffic.gdshader`, `glow.gdshader` (WP3.1) | unchanged | headlight ramp, lamp bits |

**Budget.** At night the WP adds 3 draw calls (player cone, traffic cones, lamp pools). The
glow pass no longer draws per-vehicle headlight pools where the cones run
(`TrafficView.headlight_pools = false`), which saves their overdraw. By day every node is
hidden (not drawn at alpha 0) while its ramp is below `NightTuning.visible_min_ramp`.
Traffic cones are capped per quality tier (`traffic_cones_per_tier`: 6 / 10 / 16, the
nearest vehicles with headlights on, both carriageways). Lamp pools cover the poles from
`pool_behind_m` behind to `pool_ahead_m` ahead (about 20 pools).

## Shader terms (`assets/shaders/world_common.gdshaderinc`)

- `wb_player_light(lit, world_pos)`: the headlight brightening. It scales an albedo
  estimated from the lit color (lit ÷ the key's average shade of an upward and a
  shadow-side face, per channel), so dark night shading doesn't swallow the light, and the
  surface keeps its own hue. Cone: cos 0.85 → 0.97. Falloff `1 / (1 + (dist / reach)² × 0.002)`.
  Used by the world, road, traffic and glow shaders, so road, markings, guardrails, props
  and traffic all brighten in the beam.
- **Reach in the direction's length.** `wb_player_light_dir` is the beam axis and its
  length is the reach (1 = low beams, `NightTuning.high_beam_reach` for high beams). No
  new global was needed. Callers that pass a unit vector (previews) get the old falloff.
- `wb_retro_light(albedo, world_pos, world_normal)`: retro-reflection for emissive class 1
  faces (reflector posts, sign faces). A wider cone (cos 0.7), a long reach (half at about
  160 m × reach) and a facing term (the face looking back at the lamps).
  `world.gdshader` adds it per fragment, only on class 1 faces. Road raised reflectors
  (`road.gdshader`, WP4.6's) can adopt it later with the same two lines.
- Both return 0 when `wb_player_light_strength` is 0 (by day). Everything is linear math
  before `wb_output()`: identical on both renderers (`tools/parity.sh` on
  `src/sun/dev/look_preview.tscn` passes at dusk, night and dawn).

## Decals (`assets/shaders/light_decal.gdshader`)

One additive shader, three materials. The cone's across coordinate is interpolated as
`(u × width, width)` and divided per fragment, so it is exact on a trapezoid (no diagonal
seam). Brightness × the ramp × `(1 − fog)`. For renderer parity it follows the §13 additive
rule, as the glow pools do: on Compatibility it adds `wb_output(bg + c) − wb_output(bg)`
over the road's own radiance. The cones match Mobile to about 3 levels of 255 on average,
judged by eye as the contract asks.

- **Player cone:** 8 segments sampled from the RoadPath along the car's heading (s + x·cos
  yaw, d + x·sin yaw), so it follows grades and curves. Rows are written relative to the
  car's tick position; the node sits at the car's physics-interpolated position.
- **Traffic cones:** a flat trapezoid at the front bumper of each chosen vehicle, in the
  pose TrafficView draws (`slot_transform` at the frame's interpolation fraction). They fade
  out over the last `traffic_cone_fade_m` of the range.
- **Lamp pools:** a soft ellipse under each head of the median twin-arm poles (s = k × 50 m,
  d = ±`pool_d_m`), lying on the road plane. They are rewritten only when the window of
  poles moves or the origin shifts.

## High beams (D8)

- Controls: `H`, gamepad `X` (`KeysGamepad.HIGH_BEAM`, not in spec), or
  `PlayerInput.toggle_high_beam()` / `set_high_beam(on)`. The HUD has a high-beam
  button under [CAM] from late golden hour to dawn (see HUD.md → High-beam button).
- State: `PlayerInput.high_beam`, and a signal `PlayerInput.high_beam_changed(on)` until
  `Events.high_beam_changed(on: bool)` exists (needs: Events signal). The toggle is manual:
  it stays on until toggled again and survives `release_all()`.
- Effect: the fake light's gain goes 1.0 → 1.35 and its reach 1 → 2. The cone grows from 38
  to 85 m and from 14 to 16 m wide, at 1.3× brightness. Visual only: scoring, traffic and
  the run's trace hash are unchanged (`tests/night/test_high_beam.gd`).
- Not done: the car model's own lamp quads don't get brighter with high beams.
  `car_visual.gd` / the shared `vehicle_lamp.tres` have no per-car lamp level yet.

## Wiring

`Run` (and the `car_drive` dev scene) creates the three nodes, sets their `sky`, calls
`setup(ctx, road, origin)` with the other world systems, and calls `update_view(s)` every
frame. This happens in `Run.frame()`, before the sky (a child of the run) pushes the
globals, so the fake light is never a frame late. The ramps come from the sky's last
sample, one frame old, which is invisible at the color script's pace. Snap hook:
`--high_beam`.

Tuning: `NightTuning` (`src/core/tuning/night_tuning.gd`, `data/tuning/night.tres`),
loaded with `NightTuning.load_default()` until `Tuning.night` exists (needs: Tuning.night).
Light colors and decal looks are in the three materials.

## Color script

The night key is a little darker: ambient `#56649A` → `#4C588A`, moon energy 0.45 → 0.38.
This gives the headlights, pools and reflectors contrast. Traffic stays readable through
its taillights, glow sprites and cones. Dusk and dawn are unchanged.

## Tests

`tests/night/`:
- `test_high_beam.gd`: the API, H, gamepad X, the signal, `release_all`, and no effect on the run
- `test_player_headlights.gd`: the fake light follows the pose and the ramp, high beams, the cone is hidden by day or when disabled, rows sit on a curved road, no objects per frame
- `test_headlight_cones.gd`: hidden by day, the flag, the tier cap and nearest-first choice, range and hidden slots, the bumper position and fade, the opposite carriageway, the glow pools off, no objects per frame
- `test_street_lamp_pools.gd`: hidden by day, a pool under every pole in the window, rewrites, the generated-road limit, no objects per frame, `NightTuning`
