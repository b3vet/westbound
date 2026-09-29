# HUD and theme (WP4.3)

The gameplay HUD and the design-system theme. Spec: *UI, HUD and design system*, *Scoring → Score feedback / Multiplier / Chain and banking / Boost*, *Sky timeline and sun clock → HUD*. Contract: CONTRACTS §14.

## Using it

```gdscript
var hud := preload("res://src/ui/hud/hud.tscn").instantiate() as Hud   # CanvasLayer, layer 5
add_child(hud)
hud.bind(feed)                        # the run's HudFeed; null unbinds
hud.pause_pressed.connect(...)        # [II]
hud.camera_pressed.connect(...)       # [CAM]
hud.high_beam_pressed.connect(...)    # the headlamp button (WP5.5): the run toggles hub.toggle_high_beam()
```

- The HUD reads the `HudFeed` every frame and listens to `Events`: `scored`, `chain_banked`, `chain_lost`, `hesitated`, `bonus_awarded`, `hit`, `life_restored`, `ghost_started/ended`, `shoulder_penalty_changed`, `night_started`, `gear_shifted`, `run_started` and `settings_changed`. It never writes gameplay state.
- **Accent:** the HUD follows the `SkyRig` in the tree (`accent_changed`). Without one it uses the theme's run-start accent. `set_accent()` sets it by hand. It redraws only on an 8-bit color change.
- **Touches:** only the buttons take touches (`MOUSE_FILTER_STOP`). Everything else ignores them, so `PlayerInput` gets them in `_unhandled_input`.
- **Settings read:** `units` (km/h or mph, km or miles), `text_scale` (clamped to `hud.text_scales`, 100% / 125%), and the control settings (for placement).
- **Tests and previews:** `set_screen(full, safe)` pins the canvas. Set `auto_process = false` and call `advance(dt)` yourself.

## Layout

`HudLayout` (pure) places everything in canvas pixels inside the display safe area (`DisplayServer.get_display_safe_area()`, converted to canvas coordinates):

- **Top-left:** banked total and best.
- **Top-centre:** the sun bar with the checkpoint distance, then the chain and multiplier (they meet at the centre line), then the 4-line event stack. The chain row spans the sun bar's width unless a raised bottom panel or the objective chip needs that room (WP5.6: a six-digit chain and its CHAIN label fit its half); the stack and the toast keep `chain_row_size_px.x`. A chain too long for the label as well shows its number alone.
- **Top-right:** the lives panel, [II] and [CAM], and the high-beam button under [CAM] (WP5.5).
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

## Leg objective and leg toast (WP5.2)

Spec: *Core loop → Legs and checkpoints* (warning signs, crossing step 5 "a 2.5-second leg summary toast that does not pause play", the leg objective shown on entry), *Night*, *UI → Screens* ("Leg summary: a non-blocking toast").

- **Objective chip** (`widgets/hud_objective.gd`, `layout.objective`): "LEG 2 OBJECTIVE" over a diamond, the text ("5 CLOSE PASSES", from `LegObjectives.label`, in the units setting) and the progress ("3/5"). It is read from the feed: `objective`, `objective_progress` / `objective_target` (0 = nothing to count), `objective_done` and `objective_failed`.
    - **New objective:** it pops in (scale).
    - **Completed:** the edge, text and icon turn gold with a tick.
    - **Failed ("no X" broken):** the edge and icon turn hot with a cross, and the text reads FAILED.
    - **After completing or failing,** it holds `objective_end_hold_s`, then fades (`objective_fade_s`) and hides until the next leg.
    - The pop and fade are scale and modulate only, so they cause no redraws. The text redraws only when the count changes.
    - **Width (WP5.6):** as wide as its caption, icon, text and progress need (`HudObjective.content_width()`), from `objective_chip_size_px.x` up to `objective_chip_max_width_px` (both scaled by the text size). The layout reserves the widest chip (`layout.objective`); the chip sits in it anchored to its side (`objective_anchor`, `objective_fit()`). A label too long even then drops to the label size.
    - **Placement:** under the score panel. If a raised bottom-left panel needs that space, it moves under the lives and buttons. If both corners are raised (extreme control scales only), it goes centred under the toast slot.
- **Leg toast** (`widgets/hud_leg_toast.gd`, `layout.toast`): the event stack's slot, `leg_toast_size_px.y` tall. At 125% text it still ends above 45% of the height, so the middle third stays clear. It takes no touches and lasts `leg_toast_s` (2.5 s), fading in and out with modulate only, so it draws once per crossing.
    - **Contents:** "LEG 2 COMPLETE", BANKED (the chain banked at the line), then the items flowing over `leg_toast_item_rows` rows: NIGHT ×2, the leg bonuses with their points (already ×2), OBJECTIVE (paid at the line, or earlier in the leg from the summary's `objective_points`), LIFE RESTORED. Under a rule: "LEG 3 — <biome display name>" and the new objective. When the footer is too long, the leg text drops to the label size, then the objective does, then the objective goes (the chip shows it). The place name stays; only a name too long for the card on its own falls back to "LEG 3" (WP5.6).
    - **How it fills:** the Hud starts it on `checkpoint_crossed`. The crossing's other events, which arrive in the same frame (`chain_banked` with reason checkpoint, `bonus_awarded`, `life_restored`, `leg_started`), fill the toast instead of the stack until the next `advance()`.
    - **The stack while it shows:** `HudEventStack.muted` hides the stack. Lines keep arriving and ageing, so nothing shows up stale afterwards.
    - **Worst case** (night, all four leg bonuses, the objective, the life): 7 items fit at 100% and 125%. The journey bonus is an 8th item at the coast crossing (WP6.5's finale); it can drop the last item.
- **Stack messages:** `checkpoint_warning` → "CHECKPOINT 1 KM" / "CHECKPOINT 500 M" ("0.6 MI" / "0.3 MI" in miles), `night_started` → "NIGHT ×2", `dawn_started` → "DAWN", `morning_reached` → "MORNING". A night crossing's DAWN line is under the toast; the sun bar reads DAWN for the whole 6 s.
- **Tuning:** `hud.tres` group Legs: `leg_toast_size_px`, `leg_toast_in_s` / `leg_toast_out_s`, `leg_toast_item_rows`, `objective_chip_size_px`, `objective_chip_max_width_px`, `objective_pop_s` / `objective_pop_from_pct`, `objective_end_hold_s` / `objective_fade_s`.
- **Draw calls:**
    - The chip is 2 (a plate and the label font). The toast is 3 (a plate, display and label).
    - Measured with `hud_preview` at 1280x720 on Compatibility: idle 16 (was 14), busy 22 (was 20), night 20 (was 18). With the toast and chip up (`leg_toast`) it is 23; `objective` and `warning` are 20 each.
    - The preview now shows an objective in every state.
- **Preview states:** `leg_toast` (`--night=true|false`), `objective` (`--done=true`, `--failed=true`) and `warning`. The review cycle also runs crossings, warnings and objective progress.

  ```
  tools/snap.sh src/ui/hud/dev/hud_preview.tscn --renderer=both --state=leg_toast --tag=leg_toast
  tools/snap.sh src/ui/hud/dev/hud_preview.tscn --renderer=both --state=objective --done=true --tag=objective_done
  tools/snap.sh src/ui/hud/dev/hud_preview.tscn --renderer=both --state=warning --tag=warning
  ```

## Text fit (WP5.6)

No text the HUD or the in-run screens draw runs out of its widget or into another text, at 100% and 125% text, km/h and mph, either hand, on 1280x720 and a notched 1560x720 canvas.

- **Probe:** `HudDraw.probe` (a `HudTextProbe`, null by default) records every string drawn through `HudDraw.text` / `number` (and the event stack's lines, `HudDraw.note`): the canvas item, the box (advance width, baseline up one cap height) and the text. Off, it costs one null check per string.
- **Tests** (`tests/ui/test_text_fit.gd`):
    - HUD: every box inside its widget and no two overlapping (the bank fly-in and the glitter are transients and skipped), in a long-number state (88,888,888 banked, 999× multiplier, a full stack, TOO SLOW, the ghost); a six-digit chain keeps its CHAIN label.
    - Objective chip: every `LegObjectives` id in both units, pending, done and failed: at most `objective_chip_max_width_px`, inside its slot, the text at full size, nothing overlapping.
    - Leg toast: the worst case with every objective as the next one: 7 items shown, the footer names the biome.
    - Screens: countdown (leg chip with the biome and objective, gyro card), the motion-permission tap, pause (with RECALIBRATE), settings, crash and results (no record and a new best): each box inside its ScreenText, inside the panel or button it is drawn in and inside the safe area; no two overlapping; nothing outside a button runs under one. The countdown's leg chip and gyro card stay clear of the HUD's panels.
- **Fixed by it:** the chip's "5 S OF SLIPSTREAM" ran into its "0/5" (the chip was a fixed 244 px); the CHAIN label ran left out of its half from six-digit chains; the toast's footer dropped the place name first, so most legs read just "LEG 4" (`tests/run/test_run_legs.gd::test_every_leg_toast_names_its_biome` checks nine legs of a real run); the countdown's info column ran into the objective chip at 125% text with the gyro card (`CountdownScreen.hud_rects`, from the HUD's own `HudLayout`).
- **Countdown leg chip:** LEG n OF 8, the biome's display name (from the run's `leg_started` for leg 1, in the countdown's first frame; `Hud.biome_name()`), and the objective as the HUD labels it ("5 CLOSE PASSES", in the units setting; it used to show the raw id).
- **Preview:** `--objective=<id>` sets the chip's objective and the toast's next one; `--chain=<n>` the chain.

  ```
  tools/snap.sh src/ui/hud/dev/hud_preview.tscn --renderer=both --state=objective --objective=slipstream --chain=186400 --text_scale=1.25
  tools/snap.sh src/ui/hud/dev/hud_preview.tscn --renderer=both --state=leg_toast --objective=slipstream
  tools/snap.sh src/ui/screens/dev/screens_preview.tscn --renderer=both --screen=countdown --gyro --text_scale=1.25
  ```

## High-beam button (WP5.5)

Plan D8: the player's manual high beams get a HUD control. Spec: *UI, HUD and design system* (top-right cluster, faceted small controls), *World → Night lighting*. docs/NIGHT.md → High beams.

- **Where:** `layout.high_beam`, right-aligned under [CAM], the same size as the other buttons (`button_size_px`, scaled with the text size). It is in `HudLayout.rects()`, so the layout tests keep it clear of the pedals, the safe area, the middle third and every other panel at every handedness, controls scale, aspect and text size. The objective chip's right-side fallback and the raised bottom panels avoid it.
- **Glyph:** the headlamp symbol (a lamp, flat side left, and four straight beams), drawn with `HudMesh` in the button's plate. Chakra Petch has no such icon. The button is one draw call and draws no text.
- **Press:** `HudButton` takes the touch (`MOUSE_FILTER_STOP`, the mouse press Godot emulates from the touch) and the Hud emits `high_beam_pressed`. `Run._install_hud` connects it to `hub.toggle_high_beam`. The touch never reaches `PlayerInput`'s steering.
- **Lit:** it follows `Events.high_beam_changed` (the hub relays H, gamepad X and the button there): a gold fill with an ink glyph. When the Hud first finds the hub, it syncs from `hub.high_beam`. It redraws only when the state changes.
- **When it shows:** only while headlights matter. The color script's headlight ramp (the `SkyRig` found by group, or `set_headlight_ramp()` in previews and tests) must be at or above `hud.high_beam_min_ramp` (0.3). That is where traffic switches its headlights on (`Run.HEADLIGHTS_ON_RAMP`): sky_t ≈ 0.44, between golden hour and sunset, through dusk and night and into dawn. `NightTuning.visible_min_ramp` (0.05) is reached at sky_t ≈ 0.29, in mid-afternoon, which is too early for a night control. The button fades in and out over `hud.high_beam_fade_s` with modulate only (no redraws). By day it is `visible = false`: no canvas item, no draw call, no touches.
- **The cluster does not jump:** the slot is reserved whether or not the button shows, so nothing else moves when it appears.
- **Draw calls** (hud_preview, 1280x720, Compatibility): night 21 (was 20), with the beams on or off. idle 16 and busy 22 are unchanged: the button is hidden at the preview's day sky.
- **Preview:** `--high_beam=true` lights it. `hud_preview` connects the button to its hub, and `snap_setup` finishes the fade (`Hud.settle_high_beam()`).

  ```
  tools/snap.sh src/ui/hud/dev/hud_preview.tscn --renderer=both --state=night --tag=hb_off
  tools/snap.sh src/ui/hud/dev/hud_preview.tscn --renderer=both --state=night --high_beam=true --tag=hb_on
  ```
- **Tuning:** `hud.tres` group High beams: `high_beam_fade_s`, `high_beam_min_ramp`.
- **Tests:** `tests/ui/test_hud_high_beam.gd` covers a tap with iOS touch id 1_893_457_201 through `Input.parse_input_event` (the toggle, the lit state, and no steering), the run's wiring, the lit state following the event and the hub, hidden by day and fading in at dusk and night with its slot unchanged and +1 canvas item, following a real `SkyRig`, and clearance of the cluster.

