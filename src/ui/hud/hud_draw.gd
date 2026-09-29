class_name HudDraw
extends RefCounted
## Drawing helpers for the HUD's design language. Spec: UI, HUD and design system →
## Design system (faceted cut-corner panels, 1.5 px neon edge, tabular numbers).
##
## Shapes go through HudMesh (one triangle array per widget); this holds the shared
## geometry (chamfers, n-gons) and the text helpers.
## Numbers draw each character with Font.draw_char and digits centred in a fixed cell:
## tabular figures without a `tnum` feature, and no strings built while drawing.
## Called from _draw only, which runs when a widget's shown value changed.

const ZERO := 48   # "0"
const DIGITS := 10
const CELL_KEY_STRIDE := 4096
const CHAMFER_POINTS := 8
## Chakra Petch cap height per em (OS/2 sCapHeight 700 / unitsPerEm 1000).
const CAP_EM := 0.7   # lint: allow-number font metric

## Drop shadow of outlined text, per em (hud.text_shadow_em_pct; set by HudStyle).
static var shadow_em: float = 0.0
## Tests (WP5.6): records every string drawn through text() / number() / note(); null
## (the default) records nothing.
static var probe: HudTextProbe = null


## The 8 corners of `r` with every corner cut by `bevel`, clockwise from the top left.
static func chamfer(r: Rect2, bevel: float, out: PackedVector2Array) -> void:
	var b := minf(bevel, minf(r.size.x, r.size.y) * 0.5)
	var p := r.position
	var e := r.end
	out[0] = Vector2(p.x + b, p.y)
	out[1] = Vector2(e.x - b, p.y)
	out[2] = Vector2(e.x, p.y + b)
	out[3] = Vector2(e.x, e.y - b)
	out[4] = Vector2(e.x - b, e.y)
	out[5] = Vector2(p.x + b, e.y)
	out[6] = Vector2(p.x, e.y - b)
	out[7] = Vector2(p.x, p.y + b)


## Width of `s` with digits in `cell`-wide slots.
static func number_width(font: Font, s: String, size: int, cell: float) -> float:
	var w := 0.0
	for i in s.length():
		var c := s.unicode_at(i)
		w += cell if _is_digit(c) else font.get_char_size(c, size).x
	return w


## Draws `s` from the baseline point `pos` with tabular digits (outline first when
## outline_px > 0). Returns the drawn width.
static func number(ci: CanvasItem, font: Font, pos: Vector2, s: String, size: int, cell: float,
		color: Color, outline_px: int = 0, outline_color: Color = Color.BLACK) -> float:
	var rid := ci.get_canvas_item()
	if outline_px > 0:
		glyphs(rid, font, pos + shadow_offset(size), s, size, cell, outline_color, 0)
		glyphs(rid, font, pos, s, size, cell, outline_color, outline_px)
	var w := glyphs(rid, font, pos, s, size, cell, color, 0)
	if probe != null:
		note(ci, pos, w, size, s)
	return w


## Plain text (labels, words) with an optional outline under it.
static func text(ci: CanvasItem, font: Font, pos: Vector2, s: String, size: int, color: Color,
		outline_px: int = 0, outline_color: Color = Color.BLACK) -> void:
	if outline_px > 0:
		ci.draw_string(font, pos + shadow_offset(size), s, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size, outline_color)
		ci.draw_string_outline(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size, outline_px, outline_color)
	ci.draw_string(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size, color)
	if probe != null:
		note(ci, pos, text_width(font, s, size), size, s)


## Records a string drawn at baseline `pos`, `width` wide, in the probe (tests). Widgets
## that draw text with the font directly call it too.
static func note(ci: CanvasItem, pos: Vector2, width: float, size: int, s: String) -> void:
	if probe != null and not s.is_empty():
		var cap := cap_height(size)
		probe.add(ci, Rect2(pos.x, pos.y - cap, width, cap), s)


static func text_width(font: Font, s: String, size: int) -> float:
	return font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size).x


## Drop shadow under outlined text (over the world), proportional to the size.
static func shadow_offset(size: int) -> Vector2:
	return Vector2(0.0, float(size) * shadow_em)


## Cap height at font `size` (for centring uppercase text and digits on a line).
static func cap_height(size: int) -> float:
	return float(size) * CAP_EM


## A regular n-gon (flat top) around `c` into `out` (n points).
static func ngon(c: Vector2, radius: float, n: int, out: PackedVector2Array, angle: float = 0.0) -> void:
	for i in n:
		var a := angle + TAU * (float(i) + 0.5) / float(n)
		out[i] = c + Vector2(cos(a), sin(a)) * radius


## Tabular glyphs straight into canvas item `rid` (outline pass when outline_px > 0).
static func glyphs(rid: RID, font: Font, pos: Vector2, s: String, size: int, cell: float,
		color: Color, outline_px: int) -> float:
	var x := pos.x
	for i in s.length():
		var c := s.unicode_at(i)
		var adv := font.get_char_size(c, size).x
		var off := 0.0
		if _is_digit(c):
			off = (cell - adv) * 0.5
			adv = cell
		if outline_px > 0:
			font.draw_char_outline(rid, Vector2(x + off, pos.y), c, size, outline_px, color)
		else:
			font.draw_char(rid, Vector2(x + off, pos.y), c, size, color)
		x += adv
	return x - pos.x


static func _is_digit(c: int) -> bool:
	return c >= ZERO and c < ZERO + DIGITS

