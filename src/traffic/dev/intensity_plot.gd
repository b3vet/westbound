class_name IntensityPlot
extends Control
# lint: not-sim dev-only panel (Node) that draws the director's intensity curve read-only
## Traffic sandbox panel: the director's intensity waves around the player (WP6.2).
## Spec: Traffic → Traffic director (intensity waves: build, peak, breather; a breather
## before every checkpoint); Fairness rule 6 (blind windows); Traffic sandbox. Read-only.
##
## x axis: the player's road position from BEHIND_M behind to AHEAD_M ahead; y: the
## intensity (0 breather .. 1 peak), colored by phase. Grey bands: blind crests and
## bends + blind_window_m after them; white lines: checkpoints; orange ticks: live set
## pieces (their rear, in road s); the green line is the player. The text row: phase and
## intensity here, the window's density (effective / wave-shaped target / flat target),
## the gain, and set pieces (spawned, live, per kind).

const BEHIND_M := 500.0
const AHEAD_M := 4000.0
const SAMPLES := 240
const SIZE := Vector2(620.0, 150.0)
const PAD := 10.0
const TEXT_H := 22.0
const FONT_SIZE := 14
## Above the sandbox's bottom button row.
const MARGIN_BOTTOM := 80.0
const LINE_W := 2.0
const BG := Color(0.067, 0.102, 0.188, 0.82)
const EDGE := Color(0.54, 0.576, 0.678, 0.9)
const TEXT := Color(0.957, 0.969, 1.0)
const BUILD := Color(0.95, 0.75, 0.3)
const PEAK := Color(0.95, 0.35, 0.3)
const BREATHER := Color(0.4, 0.75, 0.95)
const BLIND := Color(1.0, 1.0, 1.0, 0.15)
const CHECKPOINT := Color(1.0, 1.0, 1.0, 0.85)
const PLAYER := Color(0.4, 1.0, 0.5)
const PIECE := Color(1.0, 0.55, 0.1)
const PHASE_NAMES: Array[String] = ["BUILD", "PEAK", "BREATHER"]

var director: TrafficDirector
var player_s: float = 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = SIZE
	anchor_left = 0.5
	anchor_right = 0.5
	offset_left = -SIZE.x * 0.5
	offset_right = SIZE.x * 0.5
	anchor_top = 1.0
	anchor_bottom = 1.0
	offset_top = -MARGIN_BOTTOM - SIZE.y
	offset_bottom = -MARGIN_BOTTOM


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BG)
	draw_rect(Rect2(Vector2.ZERO, size), EDGE, false, 1.0)
	if director == null:
		return
	var w := director.waves
	var font := ThemeDB.fallback_font
	var graph := Rect2(PAD, PAD, size.x - 2.0 * PAD, size.y - 3.0 * PAD - TEXT_H)
	var x0 := player_s - BEHIND_M
	var x1 := player_s + AHEAD_M
	var win := director.director_tuning.blind_window_m
	for j in w.blind_s0.size():
		var a := _px(w.blind_s0[j], x0, x1, graph)
		var b := _px(w.blind_s1[j] + win, x0, x1, graph)
		if b > graph.position.x and a < graph.end.x:
			draw_rect(Rect2(maxf(a, graph.position.x), graph.position.y, minf(b, graph.end.x) - maxf(a, graph.position.x),
				graph.size.y), BLIND)
	for c in w.checkpoints:
		var cx := _px(c, x0, x1, graph)
		if cx >= graph.position.x and cx <= graph.end.x:
			draw_line(Vector2(cx, graph.position.y), Vector2(cx, graph.end.y), CHECKPOINT, 1.0)
	var prev := Vector2.ZERO
	for k in SAMPLES + 1:
		var x := lerpf(x0, x1, float(k) / float(SAMPLES))
		var p := Vector2(_px(x, x0, x1, graph), graph.end.y - w.intensity_at(x) * graph.size.y)
		if k > 0:
			draw_line(prev, p, _phase_color(w.phase_at(x)), LINE_W)
		prev = p
	for inst in director.set_pieces.instances:
		if inst.stage == SetPieceSource.Stage.FREE:
			continue
		var sx := _px(inst.s_rear, x0, x1, graph)
		if sx >= graph.position.x and sx <= graph.end.x:
			draw_line(Vector2(sx, graph.position.y), Vector2(sx, graph.position.y + graph.size.y * 0.5), PIECE, LINE_W)
	var px := _px(player_s, x0, x1, graph)
	draw_line(Vector2(px, graph.position.y), Vector2(px, graph.end.y), PLAYER, LINE_W)
	var sp := director.set_pieces
	var kinds := ""
	for id: StringName in sp.spawned_by_kind:
		kinds += " %s %d" % [id, sp.spawned_by_kind[id]]
	var text := "%s %.2f | dens %.1f / wave %.1f / flat %.1f | gain %.2f | pieces %d (live %d)%s" % [
		PHASE_NAMES[w.phase_at(player_s)], w.intensity_at(player_s), director.window_density, director.window_target,
		director.target_density_per_km_lane(), director.density_gain, sp.spawned, sp.active_count(), kinds]
	draw_string(font, Vector2(PAD, size.y - PAD), text, HORIZONTAL_ALIGNMENT_LEFT, size.x - 2.0 * PAD, FONT_SIZE, TEXT)


static func _px(x: float, x0: float, x1: float, graph: Rect2) -> float:
	return graph.position.x + (x - x0) / (x1 - x0) * graph.size.x


static func _phase_color(phase: int) -> Color:
	match phase:
		IntensityWaves.Phase.PEAK:
			return PEAK
		IntensityWaves.Phase.BREATHER:
			return BREATHER
	return BUILD
