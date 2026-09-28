extends Control
## Dev plot of the procedural road (WP1.1 review tool, not shipped in gameplay):
## plan view, heading against the sun band, elevation with blind crests, and
## curvature. Spec: World → Road; Cameras → Glare rule.
##   tools/snap.sh src/road/dev/road_path_plot.tscn --size=1600x1000 --seed=7
## Options: --seed=N, --plan_km, --heading_km, --profile_km, --curvature_km.

const BG := Color(0.08, 0.09, 0.11)
const GRID := Color(0.25, 0.27, 0.3)
const ROAD := Color(0.9, 0.9, 0.9)
const BEND := Color(1.0, 0.6, 0.2)
const CREST := Color(1.0, 0.25, 0.25)
const BAND := Color(0.3, 0.7, 1.0, 0.35)
const CHECKPOINT := Color(0.4, 1.0, 0.5)
const SUN := Color(1.0, 0.8, 0.3)
const MARGIN := 16.0
const LABEL_SIZE := 14

var seed_value: int = 1
var plan_km: float = 40.0
var heading_km: float = 200.0
var profile_km: float = 25.0
var curvature_km: float = 12.0

var _road: ProceduralRoadPath
var _feats: Array[RoadFeature] = []


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_rebuild()


func snap_setup(args: Dictionary) -> void:
	seed_value = int(args.get("seed", seed_value))
	plan_km = float(args.get("plan_km", plan_km))
	heading_km = float(args.get("heading_km", heading_km))
	profile_km = float(args.get("profile_km", profile_km))
	curvature_km = float(args.get("curvature_km", curvature_km))
	_rebuild()


func _rebuild() -> void:
	_road = ProceduralRoadPath.new(RunContext.new(seed_value))
	var far := Units.km_to_m(maxf(maxf(plan_km, heading_km), maxf(profile_km, curvature_km)))
	_road.ensure_generated_to(far)
	_feats.clear()
	_road.features_in(0.0, far, _feats)
	queue_redraw()


func _draw() -> void:
	var r := get_viewport_rect()
	draw_rect(r, BG)
	var w := r.size.x - MARGIN * 2.0
	var h := (r.size.y - MARGIN * 5.0) / 4.0
	var y := MARGIN
	_draw_plan(Rect2(MARGIN, y, w, h))
	y += h + MARGIN
	_draw_heading(Rect2(MARGIN, y, w, h))
	y += h + MARGIN
	_draw_profile(Rect2(MARGIN, y, w, h))
	y += h + MARGIN
	_draw_curvature(Rect2(MARGIN, y, w, h))


func _label(p: Vector2, text: String, c: Color = ROAD) -> void:
	draw_string(ThemeDB.fallback_font, p, text, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_SIZE, c)


## Plan view, uniform scale, west (the sun, world -Z) to the left, +X up.
func _draw_plan(box: Rect2) -> void:
	draw_rect(box, GRID, false)
	var len_m := Units.km_to_m(plan_km)
	var step := 20.0
	var pts := PackedVector2Array()
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	var s := 0.0
	while s <= len_m:
		var smp := _road.sample(s)
		pts.append(Vector2(smp.pos_z, -smp.pos_x))
		min_x = minf(min_x, smp.pos_x)
		max_x = maxf(max_x, smp.pos_x)
		min_z = minf(min_z, smp.pos_z)
		max_z = maxf(max_z, smp.pos_z)
		s += step
	var scale := minf(box.size.x / maxf(max_z - min_z, 1.0), box.size.y / maxf(max_x - min_x, 1.0)) * 0.95
	var center := Vector2((min_z + max_z) * 0.5, -(min_x + max_x) * 0.5)
	var to_screen := func(p: Vector2) -> Vector2: return box.get_center() + (p - center) * scale
	var screen := PackedVector2Array()
	for p in pts:
		screen.append(to_screen.call(p))
	draw_polyline(screen, ROAD, 1.5)
	for f in _feats:
		if f.kind == RoadFeature.Kind.BEND and f.s_end <= len_m:
			var seg := PackedVector2Array()
			var b := f.s_start
			while b <= f.s_end:
				var smp := _road.sample(b)
				seg.append(to_screen.call(Vector2(smp.pos_z, -smp.pos_x)))
				b += step
			if seg.size() > 1:
				draw_polyline(seg, BEND, 3.0)
		elif f.kind == RoadFeature.Kind.CHECKPOINT and f.s_start <= len_m:
			var smp := _road.sample(f.s_start)
			draw_circle(to_screen.call(Vector2(smp.pos_z, -smp.pos_x)), 4.0, CHECKPOINT)
	draw_line(box.position + Vector2(40, 30), box.position + Vector2(10, 30), SUN, 3.0)
	_label(box.position + Vector2(48, 36), "sun (heading 0, -Z)", SUN)
	_label(box.position + Vector2(8, box.size.y - 8), "plan view %d km, seed %d, uniform scale 1 px = %.0f m (bends orange, checkpoints green)" % [
		plan_km, seed_value, 1.0 / scale])


func _draw_heading(box: Rect2) -> void:
	draw_rect(box, GRID, false)
	var t := Tuning.load_default().road
	var span := t.sun_offset_max_deg * 1.2
	var len_m := Units.km_to_m(heading_km)
	var yv := func(deg: float) -> float: return box.get_center().y - deg / span * box.size.y * 0.5
	for sgn: float in [-1.0, 1.0]:
		var y0: float = yv.call(sgn * t.sun_offset_min_deg)
		var y1: float = yv.call(sgn * t.sun_offset_max_deg)
		draw_rect(Rect2(box.position.x, minf(y0, y1), box.size.x, absf(y1 - y0)), BAND)
	draw_line(Vector2(box.position.x, yv.call(0.0)), Vector2(box.end.x, yv.call(0.0)), GRID)
	var pts := PackedVector2Array()
	var s := 0.0
	var step := len_m / box.size.x
	while s <= len_m:
		pts.append(Vector2(box.position.x + s / len_m * box.size.x, yv.call(rad_to_deg(_road.heading_at(s)))))
		s += step
	draw_polyline(pts, ROAD, 1.5)
	_label(box.position + Vector2(8, 18), "heading vs s, %d km (blue: sun band +-%d..%d deg; 0 = straight at the sun)" % [
		heading_km, t.sun_offset_min_deg, t.sun_offset_max_deg])


func _draw_profile(box: Rect2) -> void:
	draw_rect(box, GRID, false)
	var len_m := Units.km_to_m(profile_km)
	var lo := INF
	var hi := -INF
	var s := 0.0
	var step := len_m / box.size.x
	while s <= len_m:
		var e := _road.elevation_at(s)
		lo = minf(lo, e)
		hi = maxf(hi, e)
		s += step
	var yv := func(e: float) -> float: return box.end.y - 8.0 - (e - lo) / maxf(hi - lo, 1.0) * (box.size.y - 30.0)
	for f in _feats:
		if f.kind == RoadFeature.Kind.BLIND_CREST and f.s_start <= len_m:
			var x0 := box.position.x + f.s_start / len_m * box.size.x
			var x1 := box.position.x + minf(f.s_end, len_m) / len_m * box.size.x
			draw_rect(Rect2(x0, box.position.y, maxf(x1 - x0, 2.0), box.size.y), Color(CREST, 0.3))
		elif f.kind == RoadFeature.Kind.CHECKPOINT and f.s_start <= len_m:
			var xc := box.position.x + f.s_start / len_m * box.size.x
			draw_line(Vector2(xc, box.position.y), Vector2(xc, box.end.y), CHECKPOINT)
	var pts := PackedVector2Array()
	s = 0.0
	while s <= len_m:
		pts.append(Vector2(box.position.x + s / len_m * box.size.x, yv.call(_road.elevation_at(s))))
		s += step
	draw_polyline(pts, ROAD, 1.5)
	_label(box.position + Vector2(8, 18), "elevation vs s, %d km, %.0f..%.0f m (red: BLIND_CREST, green: checkpoints)" % [
		profile_km, lo, hi])


func _draw_curvature(box: Rect2) -> void:
	draw_rect(box, GRID, false)
	var t := Tuning.load_default().road
	var kmax := t.max_curvature()
	var len_m := Units.km_to_m(curvature_km)
	var yv := func(k: float) -> float: return box.get_center().y - k / kmax * box.size.y * 0.45
	for sgn: float in [-1.0, 1.0]:
		draw_line(Vector2(box.position.x, yv.call(sgn * kmax)), Vector2(box.end.x, yv.call(sgn * kmax)), CREST)
	var pts := PackedVector2Array()
	var s := 0.0
	var step := len_m / box.size.x
	while s <= len_m:
		pts.append(Vector2(box.position.x + s / len_m * box.size.x, yv.call(_road.curvature_at(s))))
		s += step
	draw_polyline(pts, ROAD, 1.5)
	_label(box.position + Vector2(8, 18), "curvature vs s, %d km (red: +-1/%d m)" % [curvature_km, t.min_curve_radius_m])
