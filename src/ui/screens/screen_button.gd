class_name ScreenButton
extends BaseButton
## A big touch button in the design system. Spec: UI, HUD and design system → Design
## system (faceted cut-corner controls, 7 px bevel, 1.5 px neon edge that switches to
## the accent when pressed, uppercase tracked labels; never gradient pills); Screens.
## docs/SCREENS.md.
##
## Kinds: PRIMARY (accent fill, ink text, a speed chevron: RESUME, RETRY), NORMAL
## (panel fill, line edge), DANGER (the edge turns hot when pressed: QUIT) and OPTION
## (a segment of a settings row; `selected` fills it with the accent). A disabled
## button dims and can carry a `note` ("SOON"). The shapes are one triangle array
## (HudMesh, one draw call) with the label on top; it redraws only when its look
## changes. Touch: BaseButton takes the mouse events Godot emulates from touches, so
## raw touch ids (large on iOS Safari) never index anything here.

enum Kind { NORMAL, PRIMARY, DANGER, OPTION }

## Selected option fill (accent at this opacity) and a disabled button's opacity.
const SELECTED_FILL_A := 0.26   # lint: allow-number look
const DISABLED_A := 0.45   # lint: allow-number look
## Pressed: the face sinks this far (px) toward the lower right ("cards lean on focus").
const PRESS_SHIFT := 2.0   # lint: allow-number look
## The primary chevron: height as a share of the label's cap height, and its lean.
const CHEVRON_EM := 1.25   # lint: allow-number glyph proportion
const CHEVRON_W := 0.55   # lint: allow-number glyph proportion
const CHEVRON_STROKE := 0.32   # lint: allow-number glyph proportion

var style: HudStyle
var kind: Kind = Kind.NORMAL
var text: String = "":
	set(value):
		if value != text:
			text = value
			queue_redraw()
## Small second line (muted), e.g. "SOON" on a disabled button.
var note: String = "":
	set(value):
		if value != note:
			note = value
			queue_redraw()
var selected: bool = false:
	set(value):
		if value != selected:
			selected = value
			queue_redraw()
var align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT
## Label size in canvas px at 100% text size.
var size_px: int = 24
## _draw calls (tests: idle buttons never redraw).
var redraws: int = 0

var _mesh := HudMesh.new()
var _chev := PackedVector2Array()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	action_mode = BaseButton.ACTION_MODE_BUTTON_RELEASE
	_chev.resize(HudDraw.CHAMFER_POINTS)
	button_down.connect(queue_redraw)
	button_up.connect(queue_redraw)
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)


static func make(label: String, button_kind: Kind, base_px: int) -> ScreenButton:
	var b := ScreenButton.new()
	b.text = label
	b.kind = button_kind
	b.size_px = base_px
	if button_kind == Kind.OPTION:
		b.align = HORIZONTAL_ALIGNMENT_CENTER
	return b


func setup(s: HudStyle) -> void:
	style = s
	queue_redraw()


func font_px() -> int:
	if style == null:
		return size_px
	return maxi(1, roundi(float(size_px) * style.ts))


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


func _draw() -> void:
	redraws += 1
	if style == null:
		return
	var s := style
	var mode := get_draw_mode()
	var down := mode == DRAW_PRESSED or mode == DRAW_HOVER_PRESSED
	var hover := mode == DRAW_HOVER
	var off := Vector2(PRESS_SHIFT, PRESS_SHIFT) if down else Vector2.ZERO
	var r := Rect2(off, size - Vector2(PRESS_SHIFT, PRESS_SHIFT))
	var fill := s.panel_fill
	var edge := s.edge_idle
	var ink := s.text
	match kind:
		Kind.PRIMARY:
			fill = s.accent.darkened(PRESSED_DARKEN) if down else s.accent
			edge = s.text if down or hover else s.accent.lightened(EDGE_LIGHTEN)
			ink = s.ink
		Kind.DANGER:
			fill = Color(s.ink, 1.0) if down else s.panel_fill
			edge = s.hot if down or hover else s.edge_idle
			ink = s.hot if down else s.text
		Kind.OPTION:
			if selected:
				fill = Color(s.accent, SELECTED_FILL_A)
				edge = s.accent
			elif down:
				fill = Color(s.ink, 1.0)
				edge = s.accent
			edge = s.accent if hover and not selected else edge
			ink = s.text if selected else s.muted
			if down:
				ink = s.accent
		_:
			fill = Color(s.ink, 1.0) if down else s.panel_fill
			edge = s.accent if down or hover else s.edge_idle
			ink = s.accent if down else s.text
	if disabled:
		fill = Color(fill, fill.a * DISABLED_A)
		edge = Color(s.muted, DISABLED_A)
		ink = Color(s.muted, s.muted.a * DISABLED_A * 2.0)
	var fs := font_px()
	var cap := HudDraw.cap_height(fs)
	var pad := s.tuning.spacing_grid_px * 2.0
	_mesh.begin()
	_mesh.panel(r, s.bevel_control, fill, edge, s.edge_w)
	if kind == Kind.OPTION and selected:
		# The accent tab on the top edge, like the HUD panels.
		_mesh.rect(Rect2(r.position + Vector2(s.bevel_control + s.edge_w, s.edge_w),
				s.tuning.accent_tab_size_px), s.accent)
	if kind == Kind.PRIMARY and not disabled:
		_chevron(r, cap, pad, ink)
	_mesh.flush(self)
	var tw := HudDraw.text_width(s.label, text, fs)
	var x := r.position.x + pad
	if align == HORIZONTAL_ALIGNMENT_CENTER:
		x = r.position.x + (r.size.x - tw) * 0.5
	var y := r.position.y + (r.size.y + cap) * 0.5
	if not note.is_empty():
		var ns := maxi(1, roundi(float(s.size_label) * NOTE_SCALE))
		y -= HudDraw.cap_height(ns) * NOTE_LIFT
		var nw := HudDraw.text_width(s.label, note, ns)
		var nx := x if align == HORIZONTAL_ALIGNMENT_LEFT else r.position.x + (r.size.x - nw) * 0.5
		HudDraw.text(self, s.label, Vector2(nx, y + cap * NOTE_GAP + HudDraw.cap_height(ns)), note, ns,
				Color(s.muted, ink.a))
	HudDraw.text(self, s.label, Vector2(x, y), text, fs, ink)


## Two slanted strokes (">>" leaning like the speed-tilted type) at the right end.
func _chevron(r: Rect2, cap: float, pad: float, c: Color) -> void:
	var h := cap * CHEVRON_EM
	var w := h * CHEVRON_W
	var stroke := w * CHEVRON_STROKE * 2.0
	var cy := r.position.y + r.size.y * 0.5
	var x0 := r.end.x - pad - w * 2.0 - stroke
	for i in 2:
		var x := x0 + float(i) * (w * 0.5 + stroke)
		_chev[0] = Vector2(x, cy - h * 0.5)
		_chev[1] = Vector2(x + stroke, cy - h * 0.5)
		_chev[2] = Vector2(x + stroke + w * 0.5, cy)
		_chev[3] = Vector2(x + w * 0.5, cy)
		_mesh.fan(_chev, 4, c)
		_chev[0] = Vector2(x + w * 0.5, cy)
		_chev[1] = Vector2(x + stroke + w * 0.5, cy)
		_chev[2] = Vector2(x + stroke, cy + h * 0.5)
		_chev[3] = Vector2(x, cy + h * 0.5)
		_mesh.fan(_chev, 4, c)


const PRESSED_DARKEN := 0.25   # lint: allow-number look
const EDGE_LIGHTEN := 0.35   # lint: allow-number look
## The note line: size as a share of the label size, and how the two lines stack.
const NOTE_SCALE := 1.0
const NOTE_LIFT := 0.7   # lint: allow-number layout proportion
const NOTE_GAP := 0.45   # lint: allow-number layout proportion
