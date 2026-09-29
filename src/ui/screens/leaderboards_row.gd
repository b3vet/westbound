class_name LeaderboardsRow
extends Control
## One leaderboard row, pooled by LeaderboardsList: rank, name#tag, the crew tag chip,
## the LEGACY / VERIFYING markers and the score. Spec: multiplayer handoff →
## Leaderboards (views; legacy entries "shown with a marker"; "the score shows as
## verifying until checked"); UI, HUD and design system → Design system (faceted panels,
## neon edge, tabular numbers, gold for records). WP N7.2; docs/SCREENS.md → Leaderboards.
##
## Custom-drawn: one HudMesh triangle array (the row's panel and chips) plus its texts
## through HudDraw, so a row is one canvas item however much it shows. It redraws only
## when rebound to different content. The player's own row is accent-filled; a selected
## row (report / block) gets the accent edge. Never takes touches: the list does.

const TEXT_LEGACY := "LEGACY"
const TEXT_VERIFYING := "VERIFYING"
const ELLIPSIS := "…"
const UNIT_KM := "KM"
const UNIT_MI := "MI"
## Ranks drawn in gold (the podium).
const PODIUM := 3
## The own row's fill (accent at this opacity) and a plain row's separator opacity.
const MINE_FILL_A := 0.22   # lint: allow-number look
const SEPARATOR_A := 0.5   # lint: allow-number look
## Column shares of the row width: the rank column, and the score column's minimum.
const RANK_COL := 0.07   # lint: allow-number layout proportion
const SCORE_COL := 0.16   # lint: allow-number layout proportion

var style: HudStyle
var net: NetTuning
var entry: NetBoardPage.Entry
var mine: bool = false
var selected: bool = false
## The distance board: scores are metres, shown in km or mi.
var distance: bool = false
var miles: bool = false
## _draw calls (tests: an unchanged row does not redraw).
var redraws: int = 0

var _mesh := HudMesh.new()
var _bound_run: String = ""
var _bound_rank: int = -1


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE


func setup(s: HudStyle, t: NetTuning) -> void:
	style = s
	net = t
	queue_redraw()


## Shows `e`; redraws only when something it shows changed.
func bind(e: NetBoardPage.Entry, is_mine: bool, is_selected: bool, is_distance: bool, in_miles: bool) -> void:
	var run := e.run_id + "|" + e.account_id + "|" + e.crew_id if e != null else ""
	var rank := e.rank if e != null else -1
	if e == entry and run == _bound_run and rank == _bound_rank and is_mine == mine and is_selected == selected \
			and is_distance == distance and in_miles == miles:
		return
	entry = e
	_bound_run = run
	_bound_rank = rank
	mine = is_mine
	selected = is_selected
	distance = is_distance
	miles = in_miles
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


func font_px() -> int:
	return maxi(1, roundi(float(net.boards_row_font_px) * style.ts))


func chip_px() -> int:
	return maxi(1, roundi(float(net.boards_chip_font_px) * style.ts))


## The score column text ("183,200", "24.0 KM").
func score_text() -> String:
	if entry == null:
		return ""
	if distance:
		var km := float(entry.score) / Units.M_PER_KM
		var v := Units.kmh_to_mph(km) if miles else km
		return "%s %s" % [HudFormat.tenths_text(roundi(v * HudFormat.TENTHS)), UNIT_MI if miles else UNIT_KM]
	return HudFormat.thousands(entry.score)


func rank_text() -> String:
	return HudFormat.thousands(entry.rank) if entry != null and entry.rank > 0 else ""


## The markers the row shows, in order.
func markers() -> PackedStringArray:
	var out := PackedStringArray()
	if entry == null:
		return out
	if entry.legacy:
		out.append(TEXT_LEGACY)
	elif entry.verifying:
		out.append(TEXT_VERIFYING)
	return out


func _draw() -> void:
	redraws += 1
	if style == null or net == null or entry == null:
		return
	var s := style
	var w := size.x
	var h := size.y
	var g := s.tuning.spacing_grid_px
	var pad := g * 2.0
	var fs := font_px()
	var cs := chip_px()
	var cap := HudDraw.cap_height(fs)
	var base := (h + cap) * 0.5
	var chip_h := HudDraw.cap_height(cs) + g * 1.5
	var chip_pad := g
	_mesh.begin()
	var r := Rect2(Vector2(0.0, g * 0.25), Vector2(w, h - g * 0.5))
	if mine:
		_mesh.panel(r, s.bevel_control, Color(s.accent, MINE_FILL_A), s.accent, s.edge_w)
	elif selected:
		_mesh.panel(r, s.bevel_control, Color(s.ink, s.panel_fill.a), s.accent, s.edge_w)
	else:
		_mesh.rect(Rect2(Vector2(pad, h - s.edge_w), Vector2(w - pad * 2.0, s.edge_w)), Color(s.edge_idle, s.edge_idle.a * SEPARATOR_A))
	# Right to left: the score, the markers; left to right: the rank, the name, the crew chip.
	var score := score_text()
	var cell := s.digit_cell(s.body, fs)
	var sw := HudDraw.number_width(s.body, score, fs, cell)
	var sx := w - pad - sw
	var right := minf(sx, w - pad - w * SCORE_COL) - g * 2.0
	var chips: Array[Array] = []   # [x, text, ink]
	for m in markers():
		var mw := HudDraw.text_width(s.label, m, cs) + chip_pad * 2.0
		right -= mw
		var ink := s.accent if m == TEXT_VERIFYING else s.muted
		_mesh.panel(Rect2(Vector2(right, (h - chip_h) * 0.5), Vector2(mw, chip_h)), s.bevel_control * 0.5,
				Color(s.ink, s.panel_fill.a), ink, s.edge_w)
		chips.append([right + chip_pad, m, ink])
		right -= g
	var rx := pad
	var rank := rank_text()
	var rw := maxf(w * RANK_COL, HudDraw.number_width(s.body, rank, fs, cell) + g)
	var nx := rx + rw + g
	var crew := entry.crew_tag if not entry.is_crew() else ""
	var crew_w := HudDraw.text_width(s.label, crew, cs) + chip_pad * 2.0 if not crew.is_empty() else 0.0
	var tag := entry.tag_text()
	var tag_w := HudDraw.text_width(s.body, tag, fs)
	var room := right - nx - (crew_w + g if crew_w > 0.0 else 0.0) - tag_w
	var nm := elide(s.body, entry.name_text(), fs, room)
	var nw := HudDraw.text_width(s.body, nm, fs)
	var cx := nx + nw + tag_w + g
	if crew_w > 0.0:
		_mesh.panel(Rect2(Vector2(cx, (h - chip_h) * 0.5), Vector2(crew_w, chip_h)), s.bevel_control * 0.5,
				Color(s.ink, s.panel_fill.a), s.accent, s.edge_w)
	_mesh.flush(self)
	var rank_ink := s.gold if entry.rank > 0 and entry.rank <= PODIUM else (s.text if mine else s.muted)
	HudDraw.number(self, s.body, Vector2(rx + rw - HudDraw.number_width(s.body, rank, fs, cell), base), rank, fs,
			cell, rank_ink)
	HudDraw.text(self, s.body, Vector2(nx, base), nm, fs, s.text)
	if not tag.is_empty():
		HudDraw.text(self, s.body, Vector2(nx + nw, base), tag, fs, s.muted)
	var chip_base := (h + HudDraw.cap_height(cs)) * 0.5
	if crew_w > 0.0:
		HudDraw.text(self, s.label, Vector2(cx + chip_pad, chip_base), crew, cs, s.accent)
	for c in chips:
		HudDraw.text(self, s.label, Vector2(float(c[0]), chip_base), String(c[1]), cs, c[2] as Color)
	HudDraw.number(self, s.body, Vector2(sx, base), score, fs, cell, s.gold if mine else s.text)


## `text` cut to `width` (with an ellipsis) in `font` at `font_size`.
static func elide(font: Font, text: String, font_size: int, width: float) -> String:
	if HudDraw.text_width(font, text, font_size) <= width:
		return text
	var n := text.length()
	while n > 0 and HudDraw.text_width(font, text.left(n) + ELLIPSIS, font_size) > width:
		n -= 1
	return text.left(n) + ELLIPSIS if n > 0 else ""
