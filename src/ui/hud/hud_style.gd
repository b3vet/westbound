class_name HudStyle
extends RefCounted
## What every HUD widget draws with: the theme's fonts, colors and sizes at the
## current text size, the live accent, and the tuning. Spec: UI, HUD and design system
## (Design system; Accessibility → text size). One per Hud; widgets hold a reference.

var tuning: HudTuning
var ts: float = 1.0
var accent: Color = Color.WHITE
## Reduced motion (Settings `reduced_motion`, WP9.3): widgets fade only. No pops,
## slides, flights, bursts, wobbles or pulses (docs/ACCESSIBILITY.md → Reduced motion).
var reduced_motion: bool = false

var ink: Color
var panel: Color
var text: Color
var muted: Color
var gold: Color
var hot: Color
## Panel fill (panel color at the tuned opacity) and the text outline color.
var panel_fill: Color
var outline: Color
## Idle panel edge (muted line color, dimmed).
var edge_idle: Color

var display: Font
var label: Font
var body: Font

## Font sizes at the current text size (size_speed: the D14 cluster's speed number).
var size_label: int
var size_small: int
var size_score: int
var size_readout: int
var size_event: int
var size_speed: int
var size_button: int
var outline_px: int

var bevel_panel: float
var bevel_control: float
var edge_w: float
var tilt_rad: float

## Digit cell widths by font and size (tabular numbers), filled on first use.
var _cells: Dictionary[int, float] = {}
var _font_ids: Dictionary[Font, int] = {}


func setup(th: Theme, hud: HudTuning, text_scale: float) -> void:
	tuning = hud
	ts = text_scale
	var t := UiTheme.TYPE
	ink = th.get_color(UiTheme.C_INK, t)
	panel = th.get_color(UiTheme.C_PANEL, t)
	text = th.get_color(UiTheme.C_TEXT, t)
	muted = th.get_color(UiTheme.C_MUTED, t)
	gold = th.get_color(UiTheme.C_GOLD, t)
	hot = th.get_color(UiTheme.C_HOT, t)
	if accent == Color.WHITE:
		accent = th.get_color(UiTheme.C_ACCENT, t)
	panel_fill = Color(panel, Units.pct_to_frac(hud.panel_alpha_pct))
	edge_idle = Color(muted, Units.pct_to_frac(hud.panel_edge_alpha_pct))
	outline = Color(ink, Units.pct_to_frac(hud.text_outline_alpha_pct))
	display = th.get_font(UiTheme.F_DISPLAY, t)
	label = th.get_font(UiTheme.F_LABEL, t)
	body = th.get_font(UiTheme.F_BODY, t)
	size_label = _sz(th.get_font_size(UiTheme.S_LABEL, t))
	size_small = _sz(th.get_font_size(UiTheme.S_SMALL, t))
	size_score = _sz(th.get_font_size(UiTheme.S_SCORE, t))
	size_readout = _sz(th.get_font_size(UiTheme.S_READOUT, t))
	size_event = _sz(th.get_font_size(UiTheme.S_EVENT, t))
	# Plan D14: the bottom-centre cluster's number, a share of the theme's speed size.
	size_speed = maxi(1, roundi(float(th.get_font_size(UiTheme.S_SPEED, t))
			* Units.pct_to_frac(hud.cluster_speed_font_pct) * ts))
	size_button = _sz(th.get_font_size(UiTheme.S_BUTTON, t))
	outline_px = maxi(1, roundi(hud.text_outline_px * ts))
	HudDraw.shadow_em = Units.pct_to_frac(hud.text_shadow_em_pct)
	bevel_panel = hud.panel_bevel_px
	bevel_control = hud.control_bevel_px
	edge_w = hud.neon_border_px
	tilt_rad = hud.speed_tilt_rad()
	_cells.clear()


## A length at the current text size.
func px(v: float) -> float:
	return v * ts


## The widest digit of `font` at `size`: tabular numbers put every digit in this cell.
func digit_cell(font: Font, size: int) -> float:
	if not _font_ids.has(font):
		_font_ids[font] = _font_ids.size()
	var key := _font_ids[font] * HudDraw.CELL_KEY_STRIDE + size
	if _cells.has(key):
		return _cells[key]
	var w := 0.0
	for d in HudDraw.DIGITS:
		w = maxf(w, font.get_char_size(HudDraw.ZERO + d, size).x)
	_cells[key] = w
	return w


func _sz(base: int) -> int:
	return maxi(1, roundi(float(base) * ts))
