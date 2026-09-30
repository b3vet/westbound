class_name HudAchievementLayer
extends CanvasLayer
## Where the achievement unlock toast shows (WP8.3): its own canvas layer over the HUD and
## the run's screens, so an unlock on the results or the title shows too. Spec: Garage and
## progression (Achievements); UI → Screens (toasts never pause play); HUD layout (the
## middle third stays clear; plan D14: nothing in the thumb zones); Accessibility (text
## size, safe areas). docs/ACHIEVEMENTS.md → Toast.
##
##   var layer := HudAchievementLayer.new()     # AchievementService makes one
##   add_child(layer)
##   layer.show_unlock(def)                     # in the frame of the unlock
##
## Place: top-right, under the lives and the HUD buttons (the objective chip there when
## it sits right), in the span between the middle third (and the event stack beside it)
## and the safe edge; while the HUD's JOURNEY COMPLETE banner is up it waits. The HUD's own
## layout gives the rects (the live Hud's, or one built from the settings like the Hud
## builds it). If that ever reached a thumb area (very short canvases), it goes under the
## score on the left instead. Laid out again for each unlock (text size, hand and
## controls may have changed). Processes only while a toast shows, with real time (slow
## motion does not stretch it). Hidden: no canvas item draws.

var tuning: AchievementTuning
var hud_tuning: HudTuning
var style := HudStyle.new()
var widget: HudAchievementToast
## The toast's rect (canvas px) at the last layout, and the HUD layout it avoided.
var toast_rect: Rect2 = Rect2()
var layout: HudLayout

var _theme: Theme
var _pinned: bool = false
var _pinned_full: Rect2 = Rect2()
var _pinned_safe: Rect2 = Rect2()
var _own_controls := ControlsLayout.new()
var _hud_layout := HudLayout.new()


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	widget = HudAchievementToast.new()
	widget.name = "Toast"
	add_child(widget)
	set_process(false)


func _ready() -> void:
	set_process(false)   # a script with _process starts processing at ready
	name = "AchievementToast"
	if tuning == null:
		tuning = AchievementTuning.load_default()
	layer = tuning.toast_layer
	hud_tuning = Tuning.load_default().hud
	_theme = UiTheme.load_theme()
	widget.tuning = tuning


## Pins the canvas and safe rects (tests, previews); otherwise the viewport and the
## display safe area.
func set_screen(full: Rect2, safe: Rect2) -> void:
	_pinned = true
	_pinned_full = full
	_pinned_safe = safe


## Shows `def`'s unlock (queued behind one on show; held under the journey banner).
func show_unlock(def: AchievementDef) -> void:
	if def == null or not is_inside_tree():
		return
	widget.held = banner_up()
	if not widget.busy():
		_restyle()
		_relayout()
	widget.show_unlock(def.title)
	set_process(true)


func showing() -> bool:
	return widget.showing() and not widget.held


## Canvas items drawing now (0 when no toast shows).
func visible_item_count() -> int:
	return 1 if widget.is_visible_in_tree() else 0


func _process(delta: float) -> void:
	advance(delta / Engine.time_scale if Engine.time_scale > 0.0 else delta)


## Advances the toast by `real_dt` seconds (tests call it directly).
func advance(real_dt: float) -> void:
	var was := widget.title_text()
	widget.held = banner_up()
	widget.animate(real_dt)
	if widget.showing() and widget.title_text() != was:
		_relayout()   # the next one in the queue
	if not widget.busy():
		set_process(false)


## The HUD's JOURNEY COMPLETE banner is up (the toast waits: it would sit on it).
func banner_up() -> bool:
	if not is_inside_tree():
		return false
	var hud := get_tree().get_first_node_in_group(Hud.GROUP) as Hud
	return hud != null and hud.is_node_ready() and hud.visible and hud.journey_toast_visible()


func _restyle() -> void:
	var ts := hud_tuning.clamp_text_scale(float(Settings.get_value(&"text_scale")))
	style.setup(_theme, hud_tuning, ts)
	var sky := get_tree().get_first_node_in_group(SkyRig.GROUP) as SkyRig
	style.accent = sky.get_accent() if sky != null else _theme.get_color(UiTheme.C_ACCENT, UiTheme.TYPE)
	widget.setup(style)


func _relayout() -> void:
	var full := _pinned_full if _pinned else Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size)
	var safe := _pinned_safe if _pinned else HudLayout.canvas_safe_rect(full)
	var hud := get_tree().get_first_node_in_group(Hud.GROUP) as Hud
	var lay: HudLayout
	if hud != null and not _pinned and hud.layout.full == full:
		lay = hud.layout
	else:
		_hud_layout.build(hud_tuning, full, safe, _controls(full, safe), style.ts)
		lay = _hud_layout
	layout = lay
	toast_rect = place(lay, tuning, hud_tuning, style.ts)
	widget.position = toast_rect.position
	widget.size = toast_rect.size


## The toast's rect in `lay` (canvas px): top-right under the lives and buttons, else
## under the score on the left; clear of the middle third and the thumb areas.
static func place(lay: HudLayout, t: AchievementTuning, hud: HudTuning, ts: float) -> Rect2:
	var gap := hud.spacing_grid_px
	var m := hud.edge_margin_px
	var mid := lay.middle_column()
	var h := t.toast_size_px.y * ts
	# Right: from the middle third's right edge to the safe edge.
	var right := lay.safe.end.x - m
	var top := maxf(maxf(lay.lives.end.y, lay.camera.end.y), lay.high_beam.end.y) + gap
	if lay.objective_anchor >= 1.0:
		top = maxf(top, lay.objective.end.y + gap)
	# Right of the top-centre readouts it would sit beside (the event stack and the leg
	# toast's slot can be wider than the middle third at 125 %).
	var left := mid.end.x
	for c: Rect2 in [lay.sun, lay.chain, lay.stack, lay.toast]:
		if c.position.y < top + h and c.end.y > top:
			left = maxf(left, c.end.x)
	var w := minf(t.toast_size_px.x * ts, right - (left + gap))
	var r := Rect2(Vector2(right - w, top), Vector2(w, h))
	if clear_of_thumbs(lay, r, hud):
		return r
	# Left: under the score (and the objective chip when it sits there).
	var lx := lay.safe.position.x + m
	var lw := minf(t.toast_size_px.x * ts, mid.position.x - gap - lx)
	var ltop := lay.score.end.y + gap
	if lay.objective_anchor <= 0.0:
		ltop = maxf(ltop, lay.objective.end.y + gap)
	var l := Rect2(Vector2(lx, ltop), Vector2(lw, h))
	return l if clear_of_thumbs(lay, l, hud) else r


## `r` keeps the pedal clearance from every thumb zone and pedal.
static func clear_of_thumbs(lay: HudLayout, r: Rect2, hud: HudTuning) -> bool:
	for a in lay.thumb_areas():
		if a.grow(hud.pedal_clearance_px).intersects(r):
			return false
	return true


## The touch controls' layout: the run's input hub's, else one from the settings (as the
## Hud builds its own).
func _controls(full: Rect2, safe: Rect2) -> ControlsLayout:
	var hub := get_tree().get_first_node_in_group(PlayerInput.GROUP) as PlayerInput
	if hub != null and not _pinned:
		return hub.layout
	var c := Tuning.load_default().controls
	var px_per_cm := PlayerInput.canvas_px_per_cm(c, full.size, DisplayServer.window_get_size())
	var size_scale := clampf(float(Settings.get_value(&"controls_scale")), c.controls_scale_min_factor,
			c.controls_scale_max_factor)
	_own_controls.build(c, full, safe, px_per_cm, StringName(str(Settings.get_value(&"steering_mode"))),
			StringName(str(Settings.get_value(&"throttle_mode"))), bool(Settings.get_value(&"left_handed")), size_scale)
	return _own_controls
