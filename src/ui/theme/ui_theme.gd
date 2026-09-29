class_name UiTheme
extends RefCounted
## The design system as one Godot Theme (src/ui/theme/theme.tres, the spec's
## ui/theme.tres). Spec: UI, HUD and design system → Design system (faceted panels,
## neon edge, Chakra Petch 600/700, colors, "one Godot Theme resource holds all of
## the above"); CONTRACTS §14. docs/HUD.md.
##
## build() makes the theme from HudTuning (bevels, border, font sizes, tracking) and
## the spec's color table; build_theme.gd saves it. Everything that draws UI reads
## colors, fonts and sizes from the theme (type "Hud"), so the numbers live in one place.
##
##   Faceted panels: StyleBoxFlat, corner_radius = bevel, corner_detail = 1 (straight
##   chamfers). StyleBoxFlat borders are whole pixels, so theme boxes use the 1.5 px
##   neon edge rounded (2 px); the HUD draws its edges itself at exactly 1.5 px.
##   Tabular numbers: Chakra Petch has no `tnum` feature, so the HUD draws digits in
##   fixed cells (HudDraw.number).
##   Accent: the sky's neon at run time (SkyRig.get_accent()); the theme holds the
##   run-start accent, and apply_accent() retints the accent-colored items.

const PATH := "res://src/ui/theme/theme.tres"
const FONT_SEMIBOLD_PATH := "res://assets/fonts/ChakraPetch-SemiBold.ttf"
const FONT_BOLD_PATH := "res://assets/fonts/ChakraPetch-Bold.ttf"

## Spec colors (Design system → Colors).
const INK := Color("#0b1020")
const PANEL := Color("#111a30")
const TEXT := Color("#f4f7ff")
const MUTED := Color("#8a93ad")
const GOLD := Color("#ffd24a")
const HOT := Color("#ff5a4d")

## The theme type every HUD and screen item lives under.
const TYPE := &"Hud"

## Color names (type Hud).
const C_INK := &"ink"
const C_PANEL := &"panel"
const C_TEXT := &"text"
const C_MUTED := &"muted"
const C_GOLD := &"gold"
const C_HOT := &"hot"
const C_ACCENT := &"accent"

## Font names (type Hud): display = 700 for readouts; label = 600 tracked for the
## uppercase labels and buttons; body = 600 for smaller numbers and text.
const F_DISPLAY := &"display"
const F_LABEL := &"label"
const F_BODY := &"body"

## Font size names (type Hud).
const S_LABEL := &"label"
const S_SMALL := &"small"
const S_SCORE := &"score"
const S_READOUT := &"readout"
const S_EVENT := &"event"
const S_SPEED := &"speed"
const S_BUTTON := &"button"

## Stylebox names (type Hud).
const B_PANEL := &"panel"
const B_CONTROL := &"control"

## Constant names (type Hud), whole canvas pixels.
const K_PANEL_BEVEL := &"panel_bevel"
const K_CONTROL_BEVEL := &"control_bevel"
const K_BORDER := &"border"
const K_GRID := &"grid"
const K_SPACING := &"spacing"

static var _cached: Theme


## The saved theme (cached). Falls back to a freshly built one if the file is missing.
static func load_theme() -> Theme:
	if _cached == null:
		if ResourceLoader.exists(PATH):
			_cached = load(PATH) as Theme
		if _cached == null:
			_cached = build(Tuning.load_default().hud)
	return _cached


## The design-system theme from the tuning numbers and the spec colors.
static func build(hud: HudTuning) -> Theme:
	var th := Theme.new()
	var semibold := _font(FONT_SEMIBOLD_PATH)
	var bold := _font(FONT_BOLD_PATH)
	var label := FontVariation.new()
	label.base_font = semibold
	label.spacing_glyph = hud.label_tracking_px
	var body := FontVariation.new()
	body.base_font = semibold
	var display := FontVariation.new()
	display.base_font = bold

	th.default_font = body
	th.default_font_size = hud.font_small_px
	th.set_font(F_DISPLAY, TYPE, display)
	th.set_font(F_LABEL, TYPE, label)
	th.set_font(F_BODY, TYPE, body)
	th.set_font_size(S_LABEL, TYPE, hud.font_label_px)
	th.set_font_size(S_SMALL, TYPE, hud.font_small_px)
	th.set_font_size(S_SCORE, TYPE, hud.font_score_px)
	th.set_font_size(S_READOUT, TYPE, hud.font_readout_px)
	th.set_font_size(S_EVENT, TYPE, hud.font_event_px)
	th.set_font_size(S_SPEED, TYPE, hud.font_speed_px)
	th.set_font_size(S_BUTTON, TYPE, hud.font_button_px)

	var accent := default_accent()
	th.set_color(C_INK, TYPE, INK)
	th.set_color(C_PANEL, TYPE, PANEL)
	th.set_color(C_TEXT, TYPE, TEXT)
	th.set_color(C_MUTED, TYPE, MUTED)
	th.set_color(C_GOLD, TYPE, GOLD)
	th.set_color(C_HOT, TYPE, HOT)
	th.set_color(C_ACCENT, TYPE, accent)

	th.set_constant(K_PANEL_BEVEL, TYPE, roundi(hud.panel_bevel_px))
	th.set_constant(K_CONTROL_BEVEL, TYPE, roundi(hud.control_bevel_px))
	th.set_constant(K_BORDER, TYPE, border_px(hud))
	th.set_constant(K_GRID, TYPE, roundi(hud.layout_grid_px))
	th.set_constant(K_SPACING, TYPE, roundi(hud.spacing_grid_px))

	var panel := box(hud.panel_bevel_px, border_px(hud), Color(PANEL, Units.pct_to_frac(hud.panel_alpha_pct)), MUTED)
	var control := box(hud.control_bevel_px, border_px(hud), PANEL, MUTED)
	th.set_stylebox(B_PANEL, TYPE, panel)
	th.set_stylebox(B_CONTROL, TYPE, control)
	th.set_stylebox(&"panel", &"Panel", panel)
	th.set_stylebox(&"panel", &"PanelContainer", panel)

	# Buttons: faceted small controls; hover, focus and pressed switch the edge to the accent.
	var pad := hud.spacing_grid_px
	th.set_stylebox(&"normal", &"Button", _padded(control, pad))
	th.set_stylebox(&"hover", &"Button", _padded(box(hud.control_bevel_px, border_px(hud), PANEL, accent), pad))
	th.set_stylebox(&"pressed", &"Button", _padded(box(hud.control_bevel_px, border_px(hud), INK, accent), pad))
	th.set_stylebox(&"focus", &"Button", _padded(box(hud.control_bevel_px, border_px(hud), Color(PANEL, 0.0), accent), pad))
	th.set_stylebox(&"disabled", &"Button", _padded(box(hud.control_bevel_px, border_px(hud),
			Color(PANEL, Units.pct_to_frac(hud.panel_alpha_pct)), Color(MUTED, 0.5)), pad))
	th.set_font(&"font", &"Button", label)
	th.set_font_size(&"font_size", &"Button", hud.font_button_px)
	th.set_color(&"font_color", &"Button", TEXT)
	th.set_color(&"font_hover_color", &"Button", TEXT)
	th.set_color(&"font_focus_color", &"Button", TEXT)
	th.set_color(&"font_pressed_color", &"Button", accent)
	th.set_color(&"font_hover_pressed_color", &"Button", accent)
	th.set_color(&"font_disabled_color", &"Button", MUTED)

	th.set_color(&"font_color", &"Label", TEXT)
	th.set_color(&"font_outline_color", &"Label", INK)
	return th


## A faceted panel box: chamfered corners (corner_detail 1) and a neon edge.
static func box(bevel_px: float, border: int, fill: Color, edge: Color) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = fill
	b.border_color = edge
	b.set_border_width_all(border)
	b.set_corner_radius_all(roundi(bevel_px))
	b.corner_detail = 1
	b.anti_aliasing = true
	return b


## StyleBoxFlat borders are whole pixels: the neon edge rounded, at least 1.
static func border_px(hud: HudTuning) -> int:
	return maxi(1, roundi(hud.neon_border_px))


## The accent at the run's start time (the color script's ui_accent); the sky
## overrides it every frame at run time.
static func default_accent() -> Color:
	var t := Tuning.load_default()
	var cs := ColorScript.load_default()
	if not cs.is_bound():
		cs.bind(t.sun)
	return cs.accent_at(t.sun.sky_t_run_start)


## Retints the accent-colored theme items (button edges and pressed text) and the
## Hud accent color. For screens; the HUD takes the accent directly.
static func apply_accent(th: Theme, accent: Color) -> void:
	th.set_color(C_ACCENT, TYPE, accent)
	for state: StringName in [&"hover", &"pressed", &"focus"]:
		var b := th.get_stylebox(state, &"Button") as StyleBoxFlat
		if b != null:
			b.border_color = accent
	th.set_color(&"font_pressed_color", &"Button", accent)
	th.set_color(&"font_hover_pressed_color", &"Button", accent)


static func _padded(b: StyleBoxFlat, pad: float) -> StyleBoxFlat:
	b.content_margin_left = pad * 2.0
	b.content_margin_right = pad * 2.0
	b.content_margin_top = pad
	b.content_margin_bottom = pad
	return b


static func _font(path: String) -> Font:
	var f: Font = null
	if ResourceLoader.exists(path):
		f = load(path) as Font
	if f == null:
		push_warning("UiTheme: %s missing; using the fallback font" % path)
		f = ThemeDB.fallback_font
	return f
