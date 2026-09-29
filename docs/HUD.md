# HUD and theme (WP4.3)

The gameplay HUD and the design-system theme. Spec: *UI, HUD and design system*, *Scoring → Score feedback / Multiplier / Chain and banking / Boost*, *Sky timeline and sun clock → HUD*. Contract: CONTRACTS §14.

## Using it

```gdscript
var hud := preload("res://src/ui/hud/hud.tscn").instantiate() as Hud   # CanvasLayer, layer 5
add_child(hud)
hud.bind(feed)                        # the run's HudFeed; null unbinds
hud.pause_pressed.connect(...)        # [II]
hud.camera_pressed.connect(...)       # [CAM]
```

- The HUD reads the `HudFeed` every frame and listens to `Events`: `scored`, `chain_banked`, `chain_lost`, `hesitated`, `bonus_awarded`, `hit`, `life_restored`, `ghost_started/ended`, `shoulder_penalty_changed`, `night_started`, `gear_shifted`, `run_started` and `settings_changed`. It never writes gameplay state.
- **Accent:** the HUD follows the `SkyRig` in the tree (`accent_changed`). Without one it uses the theme's run-start accent. `set_accent()` sets it by hand. It redraws only on an 8-bit color change.
- **Touches:** only the two buttons take touches (`MOUSE_FILTER_STOP`). Everything else ignores them, so `PlayerInput` gets them in `_unhandled_input`.
- **Settings read:** `units` (km/h or mph, km or miles), `text_scale` (clamped to `hud.text_scales`, 100% / 125%), and the control settings (for placement).
- **Tests and previews:** `set_screen(full, safe)` pins the canvas. Set `auto_process = false` and call `advance(dt)` yourself.

## Layout

`HudLayout` (pure) places everything in canvas pixels inside the display safe area (`DisplayServer.get_display_safe_area()`, converted to canvas coordinates):

- **Top-left:** banked total and best.
- **Top-centre:** the sun bar with the checkpoint distance, then the chain and multiplier (they meet at the centre line), then the 4-line event stack.
- **Top-right:** the lives panel, [II] and [CAM].
- **Bottom-left:** the speedometer, with the minimum-speed strip reserved above it.
- **Bottom-right:** the boost meter.

The bottom panels avoid the touch controls: the gas column (gas pedal plus boost cap) and the brake, in either handedness and at any `controls_scale`. Each panel takes the first free spot from this list:

1. its corner
2. beside the controls, moving inward but not into the middle third of the width
3. above the controls, clear of the top readouts
4. beside the controls anyway (only at extreme control scales)

The controls' rects come from the `PlayerInput` hub's `ControlsLayout` when a hub exists. The HUD polls `layout_version` and re-places itself when it changes. Without a hub, the rects are built from Settings.

Sizes scale with the text size. Margins and the pedal clearance do not.

## Look

- **Theme:** `src/ui/theme/theme.tres` is built by `UiTheme.build(HudTuning)`. After changing the design numbers, regenerate it:

  ```
  tools/godot.sh --headless --path . --script res://src/ui/theme/build_theme.gd
  ```

  `test_saved_theme_is_up_to_date` fails if you forget.
- **Theme contents (type `Hud`):**
    - the spec colors: ink, panel, text, muted, gold, hot, and the accent
    - fonts: `display` (Chakra Petch 700), `label` (600, tracked +2 px), `body` (600)
    - font sizes and bevel constants
    - chamfered `StyleBoxFlat`s (`corner_detail = 1`): 13 px panels, 7 px controls
    - `Button`, `Panel` and `PanelContainer` styles for the screens (WP4.4). `UiTheme.apply_accent()` retints them.
- **Borders:** `StyleBoxFlat` borders are whole pixels, so the theme's boxes use 2 px. The HUD draws its own edges at exactly 1.5 px, antialiased.
- **Fonts:** imported as MSDF: crisp at any stretch, and one atlas per font. Chakra Petch has no `tnum` feature, so numbers are drawn glyph by glyph with each digit centred in the widest digit's cell (`HudDraw.number`). The results are tabular and don't jitter.
- **Speed tilt:** `speed_tilt.gdshader` is vertex-only (the skew, `hud.speed_tilt_deg`), so both renderers use their own fragment path. It is on the chain, multiplier, event stack and bank fly-in.
    - The multiplier's hue cycle is its `self_modulate`, and its wobble (above 20×) is its `rotation`. Neither needs a redraw.

## Draw calls and the update rule

- **Shapes:** each widget draws all its shapes on a plate behind it as one triangle array (`HudMesh`), so each plate is one draw call. The canvas renderer never batches polygons, which is why the plates exist. `HudMesh` feathers the edges by hand to antialias them.
- **Text:** drawn after the plate and grouped by font, so the glyphs batch.
- **Idle:** hidden things are `visible = false` (the flyer, glitter, an empty stack, the chain row at 1.0×, the minimum-speed strip).
- **Measured** by `hud_preview` (frame draw calls with the HUD minus without it, 1280x720, Compatibility and Mobile):

| State | HUD canvas items | HUD draw calls |
| --- | --- | --- |
| idle | 7 | 14 |
| busy (24.6×, 4 lines, glitter, boosting, ghost) | 11 | 20 |
| night | 10 | 18 |

- **When things redraw:**
    - A text redraws only when its shown value changes. Every readout compares an integer key (whole km/h, tenths of a multiplier, 0.1 km) and formats a string only on change.
    - A plate redraws when its shapes change: a new lit segment, the sun marker moving a pixel, or an animation running.
    - Nothing redraws while idle. `test_labels_change_only_when_the_shown_value_changes` checks this.

## Tuning (`data/tuning/hud.tres`)

The groups are Readouts, Animation, Layout, Type, Screens and Design system. Notable values:

- `event_hold_s` / `event_fade_s`
- `bank_fly_s` / `bank_count_s`
- the multiplier hue and wobble curves
- `glitter_count` / `glitter_max` (the clamp)
- `min_speed_bar_show_below_kmh` with its hysteresis
- panel sizes, font sizes, `panel_alpha_pct`

## Preview

`src/ui/hud/dev/hud_preview.tscn` shows the real HUD, `PlayerInput` and `ControlsOverlay` over a flat painted road. On its own it cycles fake events. `snap_setup` freezes a state:

```
tools/snap.sh src/ui/hud/dev/hud_preview.tscn --renderer=both --state=busy
tools/snap.sh src/ui/hud/dev/hud_preview.tscn --state=idle --hand=left --throttle=manual --controls_scale=1.2
tools/snap.sh src/ui/hud/dev/hud_preview.tscn --size=2496x1320 --state=night      # the owner's iPhone
tools/parity.sh src/ui/hud/dev/hud_preview.tscn --sweep=state:idle,busy,too_slow,night,bank
```

- **States:** `idle`, `busy`, `too_slow`, `night`, `dawn`, `bank`.
- **Options:**
    - `--hand`, `--throttle`, `--steering`, `--controls_scale`
    - `--text_scale`, `--units`
    - `--sky_t`
    - `--world=true` puts the 3D look preview behind the HUD.
