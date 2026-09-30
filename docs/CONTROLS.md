# Controls (WP2.2, revised in WP2.6)

How every control layout turns fingers, tilt, keys and gamepads into the one set of signals physics reads. Spec: [Controls](../WESTBOUND%20HANDOFF.md#controls), UI → HUD elements (controls overlay), Accessibility. Contract: [CONTRACTS.md §4](CONTRACTS.md#4-vehicles) (`VehicleInput`, `VehicleController`).

Every layout produces the same `VehicleInput`: `steer` −1..1 (+ right), `throttle` 0..1, `brake` 0..1 and an edge-triggered `boost`. `tests/unit/test_player_controller.gd` proves it bit for bit (see [Equivalence](#equivalence)).

## Files

| File | Role |
| --- | --- |
| `src/input/player_input.gd` | `PlayerInput`, the hub Node: routes touches, keys and gamepads, owns the sources, combines them each physics tick |
| `src/input/player_controller.gd` | `PlayerController extends VehicleController`: copies the hub into `VehicleInput` |
| `src/input/steering_input.gd` | `SteeringInput`: the shared response curve (dead zone, exponent) |
| `src/input/drag_control.gd` | `DragControl`: floating anchor, follow, release ramp, down-drag brake |
| `src/input/flick_meter.gd` | `FlickMeter`: finger speed and the upward flick (drag + auto, gyro + auto) |
| `src/input/gyro_control.gd` | `GyroControl`: tilt angle, neutral, low-pass, curve |
| `src/input/gravity_source.gd` | `GravitySource`: where tilt comes from (native `Input.get_gravity()`), screen-frame rotation |
| `src/input/web_motion_source.gd` | `WebMotionSource`: the web build's own `devicemotion` bridge and iOS permission |
| `src/input/throttle_input.gd` | `ThrottleInput`: auto/manual throttle, brake priority, brake-pedal mapping |
| `src/input/keys_gamepad.gd` | `KeysGamepad`: runtime input actions, key ramp, stick and triggers, edge keys |
| `src/input/controls_layout.gd` | `ControlsLayout`: where each touch control sits (hit-testing and drawing share it) |
| `src/ui/controls_overlay.gd/.tscn` | `ControlsOverlay`: anchor ring and thumb dot or the steering wheel, the joined gas + boost control, the brake pedal |
| `src/input/dev/input_preview.tscn` | Dev scene: raw and mapped values per source, layout, visual and size buttons, the overlay |
| `src/input/dev/controls_snap.tscn` | Snap wrapper: the real drive scene (`car_drive.tscn`) with a scripted layout and fingers, for phone-size screenshots |

## Hub API

```gdscript
class_name PlayerInput extends Node          # one per run; group PlayerInput.GROUP
signal camera_cycle_requested()               # C / gamepad Y / request_camera_cycle() (HUD button)
signal pause_requested()                      # P / Esc / gamepad Start
signal mute_toggled()                         # M
var steer: float; var throttle: float; var brake: float
func consume_boost() -> bool                  # edge: true once per request
func set_layout(steering_mode: StringName, throttle_mode: StringName, left_handed: bool) -> void
func use_settings() -> void                   # follow Settings again (the default)
func recalibrate_gyro() -> void               # countdown; pause menu "Recalibrate"
func request_camera_cycle() -> void           # the HUD camera button
func is_gyro_supported() -> bool              # hide the gyro setting when false
var effective_steering: StringName            # gyro falls back to drag where there is no tilt
var controls_scale: float                     # the controls_scale setting, clamped 0.6..1.6
var drag_visual: StringName                   # PlayerInput.RING or PlayerInput.WHEEL (setting drag_visual)

class_name PlayerController extends VehicleController
func _init(hub: PlayerInput) -> void          # update() copies the hub; allocation-free
```

- **Timing.** The hub advances in `_physics_process` at `PHYSICS_PRIORITY` (−100), before default-priority nodes such as the player car, so `PlayerController.update()` reads this tick's values. Set `auto_advance = false` and call `advance(dt)` yourself for scripted or headless runs.
- **Pause.** The hub processes always, so P/Esc still reach it while the tree is paused. Touches are ignored while paused, and every finger and key is released when pausing, when resuming and on focus loss (no stuck input).
- **Routing.** Touches and the desktop mouse arrive in `_unhandled_input`, so GUI buttons (pause, camera, menus) keep their own touches: that is "the whole screen minus UI buttons". Mouse events that Godot emulates from touch (`device == DEVICE_ID_EMULATION`) are ignored, because the touch itself counts. Keys and gamepad arrive in `_input`, so the GUI never swallows a key release.

## Layouts

| | Auto | Manual |
| --- | --- | --- |
| **Drag** | Drag zone = whole screen. One thumb: left/right steers, down brakes, flick up boosts | Drag zone = left half. The gas column bottom-right (gas pedal with the boost cap on top), the brake pedal beside it, inward |
| **Gyro** | Tilt steers. Touch and hold anywhere brakes; swipe up boosts | Brake pedal bottom-left, the gas column bottom-right |

- **Gas column (plan D9).** One thumb per side: the boost cap sits directly on top of the gas pedal, same width, as one joined control (see [Gas and boost](#gas-and-boost-one-thumb)). There is no separate boost button in any layout.
- **Left-handed** mirrors every rect across the safe area's centre (and the manual drag zone across the screen).
- **Safe areas.** Pedals sit inside `DisplayServer.get_display_safe_area()`, converted to canvas pixels, with `controls_margin_cm` (0.4) to its edge.
- **Sizes** are physical and multiplied by the `controls_scale` setting (1.0, clamped `controls_scale_min_factor`..`controls_scale_max_factor` = 0.6..1.6):

| Control | Size (cm, at scale 1) | Before WP2.6 |
| --- | --- | --- |
| Gas pedal (`pedal_width_cm` × `pedal_height_cm`) | 1.3 × 1.6 | 2.2 × 2.6 |
| Boost cap (`pedal_width_cm` × `boost_cap_height_cm`) | 1.3 × 0.8, on the gas | 1.3 × 1.3 button |
| Brake (`brake_width_cm` × `brake_height_cm`) | 1.2 × 1.8 | 1.3 wide column (drag), 2.2 × 2.6 (gyro) |
| Gap gas ↔ brake (`controls_gap_cm`, drag + manual) | 0.3 | 0.3 |
| Margin to the safe-area edge (`controls_margin_cm`, not scaled) | 0.4 | 0.5 |

  The scale also applies to the gap, the capture and re-arm distances, the ring, dot, wheel and labels. The margin stays, so the controls stay in the corner.
- **Physical scale.** Native mobile uses `DisplayServer.screen_get_dpi()`, converted from window to canvas pixels. On web and desktop the DPI is unknown or in CSS inches, which are not physical on phones, so the canvas height is taken to be `fallback_screen_height_cm` (6.8 cm, a phone in landscape). The snaps therefore show the phone proportions.

## Math

### Response curve (drag, gyro, stick)

`u` is the normalized input (drag offset / max_drag, tilt / max angle, stick value):

```
curve(u) = 0                                              |u| <= dz
         = sign(u) · ((|u| − dz) / (1 − dz)) ^ exponent    dz < |u| < 1
         = sign(u)                                        |u| >= 1
```

The live range is rescaled after the dead zone, so the output is continuous at the edge and still reaches exactly ±1. The spec's numbers: drag dead zone 4%, gyro dead zone 2° of 25° (8%), exponent 1.6 for both. The midpoint of the live range maps to 0.5^1.6 = 0.33.

### Drag

- **Scale.** max_drag = 2.5 cm physical ÷ sensitivity.
- **Anchor.** Placed where the steering thumb lands. A second finger in the zone is ignored.
- **Steering.** `steer = curve(dx / max_drag)`, applied at once (the physics' own steering rate limit smooths it).
- **Anchor follow.** Per axis: when |dx| or |dy| exceeds max_drag, the anchor moves so the offset stays at max_drag. Re-centering is always one small move.
- **Release.** Steering returns to 0 linearly over 80 ms from whatever it was. The brake drops at once.
- **Auto verticals:**
  - Down past 30% of max_drag brakes, rising linearly to 1 at max_drag.
  - A flick fires boost (see below).

### Flick (boost)

- **Speed.** Finger velocity is measured between samples at least `flick_window_ms` (40 ms) apart, so a few milliseconds of event jitter can't fake a speed.
- **Fire.** Boost fires when the upward speed exceeds 0.6 m/s (physical, via the scale above) *and* exceeds the sideways speed, so hard steering never boosts.
- **Once per flick.** The meter re-arms when the upward speed falls below `flick_rearm_pct` (50%) of the threshold, or on the next touch.

### Gyro

- **Tilt.** `angle = asin(g_x / |g|)`: the elevation of the screen's long axis, with gravity in the screen frame (x right, y up, z out of the screen, pointing at the earth). Turning the phone like a steering wheel (right edge down) is positive whether it is held upright or tilted back towards flat. Pitching the phone (flat ↔ upright) leaves `g_x` at 0 and does not steer. The spec's "roll around the screen's long axis" is read as this steering-wheel tilt.
- **Neutral.** `recalibrate_gyro()` stores the current angle. If no calibration happened, the first reading becomes the neutral.
- **Low-pass.** First order with τ = 60 ms: `filtered += (angle − neutral − filtered) · (1 − e^(−dt/τ))`, which is frame-rate independent. The test measures 63.2% at one τ.
- **Steering.** `steer = curve(filtered / max_angle)`, where max_angle = 25° ÷ sensitivity and the dead zone is 2° (× the dead-zone setting) expressed as a share of max_angle.
- **Orientation.** Native Godot already rotates `Input.get_gravity()` into the current screen orientation: Android by display rotation, iOS by interface orientation. The web source rotates the device-frame vector by `screen.orientation.angle`. Landscape-left and landscape-right therefore read opposite device vectors as the same screen tilt, and flipping the phone mid-run keeps the sign right. The neutral is stored in the screen frame, so it survives the flip.
- **No sensor.** When |g| is below `gyro_min_gravity_mps2`, the steer is 0 and calibration waits for data.

### Throttle and brake

- **Auto.** Throttle is 1 unless braking.
- **Manual:**
  - The gas pedal (or W/↑, or the right trigger, analog) gives the throttle.
  - Released, the car coasts under the physics' engine braking.
  - The brake pedal is `brake = min + (1 − min) · up`. `up` is how far up the pedal the thumb sits (0 at the bottom edge, 1 at the top, clamped) and `min` = `pedal_brake_min_pct` (20%). A finger keeps its pedal if it slides off.

### Gas and boost (one thumb)

Plan D9 (owner, M2: "a single finger for a single side"). Per finger (touch slot), in `PlayerInput`:

- **Hold.** A finger that lands anywhere on the gas pedal or the boost cap is a gas finger: full throttle until it lifts.
- **Captured.** It keeps the gas wherever it slides (off the side, off the bottom, up past the cap). The one exception: sliding *clearly* onto the brake pedal (on the brake and more than `pedal_capture_cm` (0.6) outside the gas column) turns it into a brake finger. The same rule turns a brake finger back into a gas finger when it slides clearly onto the gas column. So in drag + manual one right thumb can move gas → brake → gas without lifting, and a thumb that drifts a little over the brake's edge keeps the gas.
- **Boost by slide.** Crossing the joint line (the top of the gas pedal) upwards fires one boost edge (`consume_boost()`), while the gas stays on. Landing directly on the cap is gas plus one boost.
- **Boost by flick.** An upward flick from the pedal (the same `FlickMeter` as drag + auto: over 0.6 m/s, mostly upward) also fires it. A real flick travels at least 2.4 cm in the 40 ms window, so it nearly always crosses the joint as well: both share one arming, so that is still one boost.
- **Re-arm.** After a boost the finger must come back below the joint by `boost_cap_rearm_cm` (0.25) with the flick meter settled before it can boost again, so jitter at the joint line never double-fires. Sliding down and up again is a new, deliberate boost.
- **Overlay.** `gas_pressed` lights the whole column; `boost_pressed` (a gas finger above the joint) fills the cap.
- **Both modes:**
  - Brake is the strongest brake source.
  - Any brake above 0 cuts the throttle to 0. The spec states this only for auto; it applies to manual too so that "brake 0.5" means the same to physics in every layout (equivalence).
- **Gyro + auto.** Touch and hold brakes fully at once, with no hold delay, so braking stays instant. A finger that swipes up (boost) stops braking for the rest of that touch.

### Keyboard and gamepad

- **Keyboard steering.** A/D or ←/→ ramp to full in 0.15 s (`move_toward`, so exactly full on the 18th tick at 120 Hz) and back to 0 in 0.15 s when released. Two keys on one action (A and ←) count separately, so releasing one keeps the other.
- **Stick.** Left stick X: dead zone `gamepad_dead_zone_pct` (12%) then the shared curve, with no ramp.
- **Mixing.** The larger magnitude of keyboard and stick wins. The same rule then applies between touch steering and keys/pad.
- **Triggers.** Analog, with the same dead zone: RT = gas, LT = brake.
- **Edges.** Shift or A = boost, C or Y = camera, P, Esc or Start = pause, M = mute.

### Settings

- **Look.** `controls_scale` (size of every touch control and drag visual, clamped 0.6..1.6) and `drag_visual` (`ring` | `wheel`) are followed even while a layout is pinned. Changing the scale rebuilds the layout (fingers are released); changing the visual only redraws.
- **Scales.** Sensitivity, dead zone and curve are multipliers of the tuned spec values (1.0 = spec), clamped to `setting_scale_min_factor`..`setting_scale_max_factor` (0.5..2).
  - Sensitivity divides max_drag and the max angle (higher = less travel).
  - The dead-zone setting scales both dead zones.
  - The curve setting scales the exponent.
- **Setting keys.** `steering_mode`, `throttle_mode` and `left_handed` already exist in `Settings.DEFAULTS`. **Needed** (orchestrator-owned): `steer_sensitivity`, `steer_dead_zone` and `steer_curve`, floats defaulting to 1.0. Until they exist the hub uses `PlayerInput.SETTING_FALLBACKS` (the same 1.0 defaults) and never calls `Settings.get_value` on a missing key.

### Input actions (registered at runtime)

`KeysGamepad.register_actions()` (called by the hub's `_ready`) adds any missing action to the `InputMap`, so `project.godot` needs no `[input]` section. An action already defined in the project wins.

| Action | Events |
| --- | --- |
| `wb_steer_left` | physical A, ← |
| `wb_steer_right` | physical D, → |
| `wb_gas` | physical W, ↑ |
| `wb_brake` | physical S, ↓ |
| `wb_boost` | Shift, gamepad A |
| `wb_camera` | C, gamepad Y |
| `wb_pause` | P, Esc, gamepad Start |
| `wb_mute` | M |
| `wb_high_beam` | H, gamepad X (high beams on/off: `toggle_high_beam()`, visual only) |

WASD are physical keys (the same positions on AZERTY and similar layouts). The left stick X and both triggers are read by axis (`JOY_AXIS_LEFT_X`, `JOY_AXIS_TRIGGER_RIGHT`, `JOY_AXIS_TRIGGER_LEFT`) to stay analog.

## Overlay

`ControlsOverlay` draws the hub's `ControlsLayout`, so what you see is exactly what the touch zones are, mirroring and safe areas included.

- **Drag, `drag_visual = ring`.**
  - A faint faceted (octagonal) anchor ring in the accent color, `overlay_ring_radius_px` wide, drawn with a 1.5 px antialiased edge.
  - A solid octagonal dot at the thumb. It turns hot (#ff5a4d) while the drag brakes.
- **Drag, `drag_visual = wheel` (plan D10; the default since 2026-10-01, owner).** Visual only: the input math is the same as the ring's.
  - A faceted low-poly steering wheel centred on the anchor, `wheel_visual_diameter_cm` (2.4) × `controls_scale` across: a `wheel_facets` (12)-sided rim, three spokes (left, right, bottom), an octagonal hub, and a solid rim facet at 12 o'clock so the rotation reads at a glance.
  - Rotation = `steer × wheel_visual_max_deg` (135°), clockwise for right. It follows the anchor (including anchor follow past max_drag) and appears and disappears with the touch, like the ring.
  - Subtle panel fill, accent edges at `wheel_edge_alpha_pct`; the edges and marker turn hot while the drag brakes (drag + auto). No thumb dot.
  - Two canvas commands (one triangle array for every fill, one antialiased multiline for every edge), so it costs one draw call more than the ring.
- **Pedals:**
  - Faceted panels: a `StyleBoxFlat` with the bevel as corner radius and `corner_detail = 1`, which draws chamfers.
  - A 1.5 px chamfered neon edge polyline (`HudTuning.neon_border_px`), in the line color at rest and the accent (gas) or hot (brake) when pressed.
  - The gas column is one panel and one edge around pedal + cap, with a divider at the joint, an up chevron and BOOST on the cap, GAS on the pedal. The cap fills with the accent while a gas finger is on it.
  - The brake pedal fills bottom-up with the brake amount.
  - Uppercase labels: GAS, BRAKE and BOOST. Color is never the only cue.
- **Gyro + auto.** A hot ring and dot where the braking finger holds.
- **Idle.** The overlay compares what it shows with the hub once per frame, with no allocation, and redraws only on change. Nothing redraws while the fingers are still (tested).
- **Accent.** Follows `SkyRig.accent_changed` when a sky rig exists; otherwise `set_accent()`, falling back to the color script's run-start accent.
- **Colors** are the design system's hex values until `ui/theme.tres` lands (WP4.3).

## Web gyro

**Finding: gyro works on the web, including the iOS Safari permission flow, through a JS listener the game installs. It is implemented. The spec's fallback (hide gyro on the web) is not needed, subject to one on-device check on an iPhone at the M2 gate.**

1. **Godot reads no motion on the web.** The 4.7 web engine JS (`godot.js` in the web templates) has no `devicemotion` or `deviceorientation` listener, so `Input.get_gravity()` is always zero in the web build. Gyro on the web therefore needs its own bridge in any case.
2. **iOS permission needs a user gesture.** iOS 13+ Safari exposes `DeviceMotionEvent.requestPermission()`. WebKit rejects it (NotAllowedError) unless it is called while a user gesture is being processed. The page must also be HTTPS; GitHub Pages is.
3. **The bridge.** `WebMotionSource` runs one `JavaScriptBridge.eval` at first use and installs `window.wbMotion`:
   - a `devicemotion` listener that stores `accelerationIncludingGravity`, negated to point at the earth like Godot's native gravity;
   - the screen angle (`screen.orientation.angle`, or `window.orientation` on older Safari), updated on orientation change;
   - `arm()`. Where no permission is needed (Android Chrome and the rest), `arm()` just starts listening. Where it is needed (iOS), it adds a one-shot **capture-phase `touchend`/`click` listener on `document`**, so the player's next tap anywhere calls `requestPermission()` synchronously *inside the browser's own gesture dispatch*. This does not depend on when Godot processes the touch.
   - `PlayerInput` calls `activate()` (which arms) whenever gyro steering is selected.
4. **Verified in headless Chromium.** Scratch harness, not committed: a web export of the input preview in Playwright with touch emulation and a simulated iOS rule (`requestPermission` grants only when `window.event` is a `touchend`/`click` being dispatched, and rejects otherwise):
   - The capture listener called `requestPermission()` inside the `touchend` dispatch, and the permission was granted.
   - Synthetic `devicemotion` events reached Godot.
   - With the screen orientation emulated as landscape-primary (90°) and landscape-secondary (270°), a +12° steering-wheel tilt gave `steer +0.264` and −12° gave `steer −0.264` in **both** orientations.
   - Neutral stayed 0 across the flip.
   - The web `accelerationIncludingGravity` sign was fixed automatically at calibration.
5. **Side finding.** In the 4.7 nothreads web build, Godot's own `_unhandled_input` for a touch release also ran *inside* the `touchend` dispatch (`window.event.type == "touchend"`). So a GDScript handler calling `JavaScriptBridge.eval("DeviceMotionEvent.requestPermission()")` would probably also qualify. We don't rely on it: it depends on Godot's input-flushing internals, and the capture listener doesn't.
6. **Sign across browsers.** Browsers disagree on the sign of `accelerationIncludingGravity` (the W3C reaction vector vs. iOS history). `WebMotionSource.sign_known()` is false, and `GyroControl` fixes the sign at calibration: in any normal landscape hold, from flat to upright, earth-pointing gravity has `g.y + g.z < 0`.
7. **Fallback kept.** If permission is denied, the API is missing, or the device has no touchscreen, `is_gyro_supported()` is false. The hub then steers with drag, and the settings UI (later) should hide gyro.

**Owner check at the M2 gate (iPhone, web build):**

- choose gyro, tap once, and accept the Safari motion prompt;
- steering sign in both landscape orientations;
- the sign after flipping mid-run.

If the prompt never appears, set the web build to hide gyro (`is_gyro_supported()` already gates it) and record it in the plan.

**Integration note (later phases).** Arm the permission while still in the menus: call `activate()` when gyro is chosen in the first-run chooser or in settings. The permission is per page, and `window.wbMotion` is global. That way the tap on Play (or any menu tap) grants it before the countdown calibrates. Otherwise the first tap in the run raises the prompt.

## Equivalence

`test_equivalence_identical_physics_all_layouts` runs a 5 s script (steer 0 / +1 / −1, full brake, two boosts) through eight input paths:

- drag + auto, drag + manual, gyro + auto, gyro + manual;
- keyboard in auto and in manual;
- gamepad in auto and in manual.

Each path gets its own raw events: thumb moves and flicks, pedals and buttons, tilt from a fake gravity source, keys, stick and triggers. The results must match the reference (the values written straight into `VehicleInput`) bit for bit:

- the per-tick `VehicleInput` trace hash;
- the `VehiclePhysics` state trace hash over 5 s at 120 Hz.

The layouts' own feel dynamics (80 ms release, 60 ms gyro filter, 0.15 s key ramp) differ by design and have their own tests. This test sets them to zero so every layout can jump to a value at once. `test_equivalence_steady_values_with_real_tuning` runs the same script with the spec's dynamics and checks that every held value (the end of each segment) is identical in all eight paths.

## Not in spec (tuning fields marked `# not in spec`)

- **Flick:** the measurement window (40 ms) and the one-boost-per-flick re-arm (50%).
- **Gyro:** the sensor-present threshold (2 m/s²).
- **Gamepad:** the stick/trigger dead zone (12%), and Start = pause.
- **Screen:** the fallback screen height (6.8 cm) when the DPI is unknown.
- **Pedals:** sizes, margins, gaps, the brake pedal's 20% floor at its bottom edge, the joined gas + boost column with its capture (0.6 cm) and re-arm (0.25 cm) distances (plan D9).
- **Look settings:** `controls_scale` (0.6–1.6) and `drag_visual` = ring | wheel (plan D10), with the wheel's size (2.4 cm), max angle (135°), facets and proportions.
- **Settings:** the range 0.5–2 for the sensitivity, dead-zone and curve scales.
- **Overlay:** ring alpha and radius, dot radius, idle alpha, label size.
- **Behavior:** brake cuts throttle in manual mode too; gyro + auto brakes immediately on touch, and a swipe-up cancels it for that finger; the drag + manual brake is a proportional pedal beside the gas column; a pedal finger can slide between gas and brake.
