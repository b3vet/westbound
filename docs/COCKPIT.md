# Cockpit camera (WP4.7, plan D11)

> **Hidden from players (owner, 2026-10-01; WP9.8).** "Removed until further notice; keep the code and the assets, remove the option only." `CameraTuning.cockpit_player_enabled = false` (`data/tuning/camera.tres`) leaves the cockpit out of `CameraTuning.player_modes()`: the C key and the HUD's [CAM] cycle (`CameraRig.cycle_mode()`) skip it, the settings CAMERA row doesn't offer it, and a saved `camera_mode = "cockpit"` loads as `cockpit_fallback_mode` (`hood`, the other mounted view; `Settings.sanitize` → `CameraTuning.player_mode`, no save migration, so it comes back with the switch). The mode, the procedural cockpit, its shaders and its tests are unchanged. **To bring it back:** set `cockpit_player_enabled = true`; nothing else. **Dev access meanwhile:** `CameraRig.set_mode(&"cockpit")` and `cycle_mode(true)`: the traffic sandbox's VIEW → RIG button, the camera preview's C key, and the snap arguments below (`car_drive --cam=cockpit`, `camera_preview --mode=cockpit`, `hud_run_snap --cam=cockpit`, `fx_preview --cam=cockpit`).

The owner asked for an in-cabin camera before the cars have interiors. Until they do (ART5), a **generic procedural cockpit** is drawn around a driver's-eye camera. Spec: Cameras; Cars → Modular car convention; Performance budget.

Code: `src/camera/camera_rig.gd` (the mode), `src/camera/cockpit/cockpit.gd` (geometry), `cockpit.gdshader` (interior), `cockpit_gauges.gdshader` (binnacle). Numbers: `CameraTuning` → `data/tuning/camera.tres` (the `cockpit_*` fields and the last entry of every `mode_*` array). Tests: `tests/camera/test_cockpit_camera.gd`.

## The mode

- `cockpit` is the fifth mode in `CameraTuning.modes`: chase → far → hood → overhead → cockpit → chase. With `cockpit_player_enabled` on, the C key, the CAM button and the saved `camera_mode` setting work as for the other modes (off since 2026-10-01: see the note above). `CameraTuning.cockpit_mode` names the mode that gets the cockpit behaviour.
- **Eye.** The eye is the model's `Markers/cam_cockpit` when it was authored. A marker that `CarModel.conform()` stubbed doesn't count (import meta `car_import_stubbed` or `CarModel.stubbed`), so today's placeholders use the default. The default is proportional to the CarDef body: `cockpit_eye_right_frac` × width (−0.19: left seat, for right-hand traffic), `cockpit_eye_up_frac` × height (0.86, about 1.08 m on a 1.25 m car) and `cockpit_eye_back_frac` × length (0.04 behind the axle centre).
- **Rigid seat frame.** The rig node takes the car's full pose at the eye (0 Hz springs, road pitch included). It has no lag and no jitter.
- **Roll.** `mode_roll_factor = −1`: the seat frame leans *out* of the turn with the body. It is bounded by `roll_max_deg` (1.5°), and the chase modes lean into the turn.
- **Head.** The `Camera3D` carries the head, so the dash moves in the view and the world doesn't shake the cockpit:
    - **Look direction:** toward a point `mode_look_ahead_m` (40 m) ahead and `mode_look_height_m` (0.3 m) high in the car's frame. That is about 1° down, with the horizon just above mid-screen.
    - **Look-ahead:** the look point shifts by the shared lateral look-ahead (up to 1.2 m), which turns the head at most atan(1.2/40) ≈ 1.7° into the lane you are moving into. Chase turns about 3.6°.
    - **Head sway:** the head lags the accelerations. Turning right moves it left, braking moves it forward. The rates are `cockpit_head_sway_*_m_per_mps2`, bounded at 4 cm, on a slightly under-damped spring (1.8 Hz, ζ 0.75).
- **FOV.** The spec's speed response (62° → 78°) with `mode_fov_offset_deg = 0`. We tried wider: the cockpit shrinks and the road reads the same. Narrower felt claustrophobic at 62°.
- **Shake and FOV punch** apply to the head, scaled by `mode_shake_scale` (0.6) and `mode_punch_scale` (0.7). Hits, close passes and boost still read, but more subtly.
- **Reduced motion** turns off shake, roll, head sway and the punch, as in every mode. The seat frame stays level with the car and the head is fixed.
- **Body hidden.** On entering cockpit mode the rig calls `target.set_body_visible(false)` when the target has that method (`PlayerCar`: the CarVisual with the model, and the blob shadow). It calls `set_body_visible(true)` when leaving the mode, when the target changes, and when the rig leaves the tree.

## The cockpit

It is built in the seat frame (origin at the eye, −Z forward), as a child of the rig node. It therefore shares the rig's physics-interpolated transform, and a test holds it at zero relative motion to the camera and the car across interpolated frames. Faces are flat shaded, and static faces are wound toward the eye, so the back-face cull keeps only what the driver can see.

| Node | Draw calls | Contents |
| --- | --- | --- |
| `Interior` | 1 | Dash top (crowned facets, chamfered lip), dash face and knee panel, centre-stack screen, wiper cowl, a sliver of hood in the car's paint, A-pillars, windscreen header and roof liner, door tops and panels, binnacle visor, rear-view mirror frame with a static gradient "glass" |
| `SteeringPivot/SteeringWheel` | 1 | Low-poly rim with an accent stripe at 12 o'clock, three spokes and a hub. It turns by `VehicleState.steer_angle × VehicleTuning.steering_wheel_ratio_factor` (clockwise to the right, as in `CarVisual`) |
| `Gauges` | 1 | One quad. `cockpit_gauges.gdshader` draws the speedometer (full scale `cockpit_speedo_max_kmh`) and the tachometer (full scale `cockpit_tach_max_rpm`, red band from `engine_redline_rpm`) from the uniforms `speed_frac` and `rpm_frac` |

That is **3 draw calls** and about 800 triangles (the wheel is most of them). No lights, shadows or `StandardMaterial3D`.

**Lighting.**

- `cockpit.gdshader` uses the shared world include: single sun, vertex-lit, colours from the color script, `wb_output` for renderer parity. It adds a sky fill (`albedo × wb_sky_horizon × sky_fill`), because a cabin is lit mostly by skylight through the glass. Without it, every face turned toward the driver goes black when driving into the low western sun.
- The interior reads as dark neutral greys by day, warm at golden hour and sunset, and deep blue at night.
- The gauge marks and needles have a small constant backlight plus the `wb_emissive_headlight` ramp, so they glow at night. The centre-stack screen uses the vehicle-light emissive class.

Geometry proportions are art constants in `cockpit.gd` (like `CarModel`'s stub constants). They are metres relative to the eye (human scale) or fractions of the CarDef width (cabin, windscreen, roof).

## Snaps

```
tools/snap.sh src/dev/car_drive.tscn --renderer=both --cam=cockpit --sweep=sky_t:0,0.2,0.38,0.5,0.58,0.7,0.85
tools/snap.sh src/camera/dev/camera_preview.tscn --mode=cockpit --steer=1 --frames=20   # wheel turned, head into the lane
```

## Later (ART5)

When a model brings its own `Interior` and an authored `Markers/cam_cockpit`, the rig already uses the marker. Hiding the procedural cockpit and showing the model's interior instead (body hidden, interior shown) is a small switch in `CameraRig._apply_cockpit_view()`.
