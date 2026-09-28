extends SceneTree
## Builds the roadside and farmland prop meshes (WP1.4 interim art, generated
## in-house; plan §1 "Interim assets: generated placeholders"). Spec: World →
## Road (roadside rhythm), Biomes (farmland: golden fields, silos, windmills,
## water towers), Art pipeline (palette, flat shading, no photo textures).
##
##   tools/godot.sh --headless --path . --script res://tools/props/build_props.gd
##
## Writes assets/props/common/*.res, assets/props/farmland/*.res and
## assets/palette/palette.png (the style-guide swatch sheet). Rerun after
## changing a recipe or the palette; the output is deterministic.
##
## Prop frame (what roadside.gd expects): origin on the ground at the placement
## point, +X away from the road (the right-hand side of travel), -Z the
## direction of travel, +Z toward approaching traffic. Opposite-side placements
## are rotated 180°, so one mesh serves both carriageways.

const COMMON := "res://assets/props/common/"
const FARMLAND := "res://assets/props/farmland/"
const PALETTE_PNG := "res://assets/palette/palette.png"
const SWATCH_PX := 32
const SWATCH_COLS := 8

var _pal: WBPalette
var _b: PropMeshBuilder
var _written: PackedStringArray = []


func _initialize() -> void:
	_pal = WBPalette.load_default()
	_b = PropMeshBuilder.new(_pal)
	var road: RoadTuning = Tuning.load_default().road
	_light_pole()
	_reflector_post()
	_guardrail_post()
	_sign_gantry(road)
	_billboard_sundog()
	_billboard_mesa_cola()
	_billboard_coyote_motel()
	_fence_ranch()
	_crop(&"crop_wheat", 0.8, 8, [&"wheat_gold", &"wheat_light"], &"wheat_shade")
	_crop(&"crop_straw", 0.3, 12, [&"straw", &"grass_dry"], &"wheat_shade")
	_crop(&"crop_green", 0.5, 10, [&"crop_green", &"grass"], &"leaf")
	_crop(&"crop_plowed", 0.2, 14, [&"soil", &"soil_dark"], &"soil_dark")
	_tree_round()
	_tree_poplar()
	_farmstead()
	_grain_bins()
	_windpump()
	_water_tower()
	_wind_turbine()
	_palette_png()
	for p in _written:
		print("wrote ", p)
	quit(0)


func _save(path: String, meta: Dictionary = {}) -> void:
	var mesh := _b.commit(meta)
	var err := ResourceSaver.save(mesh, path)
	if err != OK:
		push_error("build_props: cannot save %s (%d)" % [path, err])
	_written.append("%s (%d tris)" % [path, _b.triangle_count()])
	_b.clear()


# ---------------------------------------------------------------- Road furniture (common)

## Median-mounted twin-arm light pole: one pole lights both carriageways.
## Lamp heads (bottom faces) are emissive class 2 (street lamp).
func _light_pole() -> void:
	_b.prism(Vector3.ZERO, 0.14, 0.1, 10.2, 6, &"steel", &"steel")
	for sx: float in [1.0, -1.0]:
		_b.beam(Vector3(0.0, 9.5, 0.0), Vector3(sx * 1.2, 10.15, 0.0), 0.12, &"steel")
		_b.beam(Vector3(sx * 1.2, 10.15, 0.0), Vector3(sx * 2.6, 10.3, 0.0), 0.1, &"steel")
		var hx := sx * 3.05
		_b.box(Vector3(hx, 10.35, 0.0), Vector3(1.0, 0.2, 0.38), &"steel_dark", &"steel_dark")
		_b.quad(Vector3(hx - 0.45, 10.24, -0.17), Vector3(hx + 0.45, 10.24, -0.17),
			Vector3(hx + 0.45, 10.24, 0.17), Vector3(hx - 0.45, 10.24, 0.17),
			Vector3.DOWN, &"lamp_warm", PropMeshBuilder.EMISSIVE_STREETLAMP)
		# A thin glowing rim on the head's road-facing sides reads at a distance.
		_b.quad(Vector3(hx - 0.5, 10.25, 0.191), Vector3(hx + 0.5, 10.25, 0.191),
			Vector3(hx + 0.5, 10.33, 0.191), Vector3(hx - 0.5, 10.33, 0.191),
			Vector3.BACK, &"lamp_warm", PropMeshBuilder.EMISSIVE_STREETLAMP)
	_save(COMMON + "light_pole.res")


## Delineator post behind the guardrail; the reflector faces approaching traffic.
func _reflector_post() -> void:
	_b.box(Vector3(0.0, 0.5, 0.0), Vector3(0.1, 1.0, 0.07), &"white")
	_b.box(Vector3(0.0, 1.08, 0.0), Vector3(0.1, 0.16, 0.07), &"ink")
	_b.quad(Vector3(-0.04, 0.84, 0.037), Vector3(0.04, 0.84, 0.037), Vector3(0.04, 0.98, 0.037),
		Vector3(-0.04, 0.98, 0.037), Vector3.BACK, &"reflector_amber", PropMeshBuilder.EMISSIVE_REFLECTOR)
	_save(COMMON + "reflector_post.res")


## W-beam guardrail post (the rails themselves are WP1.2's road geometry).
func _guardrail_post() -> void:
	_b.box(Vector3(0.0, 0.38, 0.0), Vector3(0.15, 0.76, 0.1), &"steel_dark", &"steel")
	_save(COMMON + "guardrail_post.res")


## Overhead sign gantry spanning one carriageway: inner upright on the median
## (x = 0), outer upright beyond the guardrail (x = span). Sign faces are
## retro-reflective (emissive class 1). roadside.gd scales x for other widths.
func _sign_gantry(road: RoadTuning) -> void:
	var span := road.median_half_width_m + road.inner_shoulder_m + float(road.lanes_default) * road.lane_width_m \
		+ road.shoulder_m + road.guardrail_offset_m + road.sign_gantry_upright_offset_m
	var top := 7.6
	var low := 6.6
	for x: float in [0.0, span]:
		_b.box(Vector3(x, top * 0.5 + 0.1, 0.0), Vector3(0.4, top + 0.2, 0.4), &"steel", &"steel")
	for y: float in [low, top]:
		_b.beam(Vector3(-0.25, y, -0.35), Vector3(span + 0.25, y, -0.35), 0.18, &"steel")
		_b.beam(Vector3(-0.25, y, 0.35), Vector3(span + 0.25, y, 0.35), 0.18, &"steel")
	var bays := 6
	for i in bays:
		var xa := span * float(i) / float(bays)
		var xb := span * float(i + 1) / float(bays)
		_b.beam(Vector3(xa, low, 0.35), Vector3(xb, top, 0.35), 0.1, &"steel_dark", false)
		_b.beam(Vector3(xa, low, -0.35), Vector3(xb, top, -0.35), 0.1, &"steel_dark", false)
	# Two sign panels hanging on the approach side (+Z), bottoms above 5.5 m.
	var panels := [[1.6, 8.6], [9.4, 15.2]]
	for p: Array in panels:
		var x0: float = p[0]
		var x1: float = p[1]
		var y0 := 5.9
		var y1 := 8.5
		_b.box(Vector3((x0 + x1) * 0.5, (y0 + y1) * 0.5, 0.55), Vector3(x1 - x0, y1 - y0, 0.12),
			&"steel_dark", &"steel_dark", true)
		_b.quad(Vector3(x0, y0, 0.62), Vector3(x1, y0, 0.62), Vector3(x1, y1, 0.62), Vector3(x0, y1, 0.62),
			Vector3.BACK, &"sign_green", PropMeshBuilder.EMISSIVE_REFLECTOR)
		# "Text" and an arrow as raised white bars (no real text, no brands).
		var w := x1 - x0
		_bar(x0 + 0.5, x0 + w * 0.8, y1 - 0.75, 0.42)
		_bar(x0 + 0.5, x0 + w * 0.55, y1 - 1.45, 0.34)
		_bar(x0 + w * 0.5 - 0.12, x0 + w * 0.5 + 0.12, y0 + 0.25, 0.55)
		_b.face(PackedVector3Array([Vector3(x0 + w * 0.5 - 0.4, y0 + 0.8, 0.7), Vector3(x0 + w * 0.5 + 0.4, y0 + 0.8, 0.7),
			Vector3(x0 + w * 0.5, y0 + 0.25, 0.7)]), Vector3.BACK, &"white", PropMeshBuilder.EMISSIVE_REFLECTOR)
		# White border frame, in the panel plane (no overlap, no z-fighting).
		_b.quad(Vector3(x0, y1 - 0.1, 0.63), Vector3(x1, y1 - 0.1, 0.63), Vector3(x1, y1, 0.63), Vector3(x0, y1, 0.63),
			Vector3.BACK, &"white", PropMeshBuilder.EMISSIVE_REFLECTOR)
		_b.quad(Vector3(x0, y0, 0.63), Vector3(x1, y0, 0.63), Vector3(x1, y0 + 0.1, 0.63), Vector3(x0, y0 + 0.1, 0.63),
			Vector3.BACK, &"white", PropMeshBuilder.EMISSIVE_REFLECTOR)
	_save(COMMON + "sign_gantry.res", {"span_m": span})


func _bar(x0: float, x1: float, y_top: float, h: float) -> void:
	_b.quad(Vector3(x0, y_top - h, 0.7), Vector3(x1, y_top - h, 0.7), Vector3(x1, y_top, 0.7), Vector3(x0, y_top, 0.7),
		Vector3.BACK, &"white", PropMeshBuilder.EMISSIVE_REFLECTOR)


# ---------------------------------------------------------------- Billboards (invented brands)

## Double-sided roadside billboard frame: 12 x 4.5 m board, 5 m up. Returns the
## board's (x0, x1, y0, y1); art is added on both faces by the brand builders.
func _billboard_frame(board: StringName) -> Rect2:
	var x0 := -6.0
	var x1 := 6.0
	var y0 := 5.0
	var y1 := 9.5
	for x: float in [-3.8, 3.8]:
		_b.box(Vector3(x, 3.0, 0.0), Vector3(0.35, 6.0, 0.35), &"steel_dark")
	_b.box(Vector3(0.0, (y0 + y1) * 0.5, 0.0), Vector3(x1 - x0, y1 - y0, 0.3), board, board, true)
	_b.box(Vector3(0.0, y0 - 0.15, 0.0), Vector3(x1 - x0, 0.1, 1.2), &"steel_dark", &"steel", true)
	return Rect2(x0, y0, x1 - x0, y1 - y0)


## Adds a flat shape on both faces (z = ±(0.15 + relief)), mirrored in x on the back.
func _both_faces(fn: Callable) -> void:
	fn.call(1.0)
	fn.call(-1.0)


func _art_rect(side: float, x0: float, y0: float, x1: float, y1: float, color_name: StringName, relief: float) -> void:
	var z := side * (0.15 + relief)
	var ax0 := x0 * side
	var ax1 := x1 * side
	_b.quad(Vector3(ax0, y0, z), Vector3(ax1, y0, z), Vector3(ax1, y1, z), Vector3(ax0, y1, z),
		Vector3(0.0, 0.0, side), color_name)


func _art_disc(side: float, cx: float, cy: float, r: float, color_name: StringName, relief: float) -> void:
	_b.disc(Vector3(cx * side, cy, side * (0.15 + relief)), Vector3(0.0, 0.0, side), r, 12, color_name)


func _art_tri(side: float, a: Vector2, b: Vector2, c: Vector2, color_name: StringName, relief: float) -> void:
	var z := side * (0.15 + relief)
	_b.face(PackedVector3Array([Vector3(a.x * side, a.y, z), Vector3(b.x * side, b.y, z), Vector3(c.x * side, c.y, z)]),
		Vector3(0.0, 0.0, side), color_name)


## "Sundog Diner": orange board, a big yellow sun, cream "lettering" bars.
func _billboard_sundog() -> void:
	var r := _billboard_frame(&"brand_orange")
	_both_faces(func(s: float) -> void:
		_art_rect(s, r.position.x, r.position.y, r.end.x, r.position.y + 0.7, &"brand_navy", 0.02)
		_art_disc(s, -3.6, 7.5, 1.55, &"hazard_yellow", 0.04)
		_art_disc(s, -3.6, 7.5, 0.9, &"cream", 0.07)
		_art_rect(s, -1.4, 8.2, 4.9, 8.9, &"cream", 0.04)
		_art_rect(s, -1.4, 7.1, 3.2, 7.7, &"cream", 0.04)
		_art_rect(s, -1.4, 6.2, 1.8, 6.6, &"hazard_yellow", 0.04))
	_save(COMMON + "billboard_sundog.res")


## "Mesa Cola": teal board, a red bottle-cap disc, a white wave.
func _billboard_mesa_cola() -> void:
	var r := _billboard_frame(&"brand_teal")
	_both_faces(func(s: float) -> void:
		_art_tri(s, Vector2(-6.0, 5.0), Vector2(-1.5, 7.2), Vector2(3.0, 5.0), &"white", 0.02)
		_art_tri(s, Vector2(0.5, 5.0), Vector2(3.6, 6.3), Vector2(6.0, 5.0), &"cream", 0.03)
		_art_disc(s, 3.6, 8.0, 1.1, &"reflector_red", 0.04)
		_art_disc(s, 3.6, 8.0, 0.55, &"white", 0.07)
		_art_rect(s, -5.2, 8.3, 1.6, 9.0, &"white", 0.04)
		_art_rect(s, -5.2, 7.5, -1.0, 7.9, &"white", 0.04)
		_art_rect(s, r.position.x, r.end.y - 0.25, r.end.x, r.end.y, &"brand_navy", 0.02))
	_save(COMMON + "billboard_mesa_cola.res")


## "Coyote Motel": navy board, pink mesas, a yellow star, cream bars.
func _billboard_coyote_motel() -> void:
	var r := _billboard_frame(&"brand_navy")
	_both_faces(func(s: float) -> void:
		_art_tri(s, Vector2(-6.0, 5.0), Vector2(-4.2, 7.0), Vector2(-2.0, 5.0), &"brand_pink", 0.03)
		_art_rect(s, -4.6, 5.0, -3.2, 7.0, &"brand_pink", 0.03)
		_art_tri(s, Vector2(-3.4, 5.0), Vector2(-2.2, 6.2), Vector2(-0.6, 5.0), &"brand_orange", 0.04)
		_art_disc(s, 4.3, 8.3, 0.7, &"hazard_yellow", 0.04)
		_art_rect(s, -1.0, 7.9, 3.2, 8.7, &"cream", 0.04)
		_art_rect(s, -1.0, 6.9, 5.2, 7.4, &"cream", 0.04)
		_art_rect(s, -1.0, 6.0, 2.0, 6.4, &"brand_pink", 0.04)
		_art_rect(s, r.position.x, r.position.y, r.end.x, r.position.y + 0.2, &"hazard_yellow", 0.02))
	_save(COMMON + "billboard_coyote_motel.res")


# ---------------------------------------------------------------- Farmland

## Ranch fence segment, 10 m along -Z: one post at z = 0 and two rails.
## Placed end to end by roadside.gd (meta length_m).
func _fence_ranch() -> void:
	var length := 10.0
	_b.box(Vector3(0.0, 0.65, 0.0), Vector3(0.14, 1.3, 0.14), &"bark")
	for y: float in [0.65, 1.1]:
		_b.beam(Vector3(0.0, y, 0.0), Vector3(0.0, y, -length), 0.09, &"concrete_shade", false)
	_save(FARMLAND + "fence_ranch.res", {"length_m": length})


## A crop field tile: unit square (x, z in -0.5..0.5) of the given height, top
## striped along z (rows parallel to the road read as speed lines). roadside
## scales it to the field-grid tile.
func _crop(id: StringName, height: float, stripes: int, tops: Array, side: StringName) -> void:
	for i in stripes:
		var x0 := -0.5 + float(i) / float(stripes)
		var x1 := -0.5 + float(i + 1) / float(stripes)
		var col: StringName = tops[i % tops.size()]
		_b.quad(Vector3(x0, height, -0.5), Vector3(x1, height, -0.5), Vector3(x1, height, 0.5), Vector3(x0, height, 0.5),
			Vector3.UP, col)
	_b.quad(Vector3(-0.5, 0.0, 0.5), Vector3(0.5, 0.0, 0.5), Vector3(0.5, height, 0.5), Vector3(-0.5, height, 0.5),
		Vector3.BACK, side)
	_b.quad(Vector3(-0.5, 0.0, -0.5), Vector3(0.5, 0.0, -0.5), Vector3(0.5, height, -0.5), Vector3(-0.5, height, -0.5),
		Vector3.FORWARD, side)
	_b.quad(Vector3(-0.5, 0.0, -0.5), Vector3(-0.5, 0.0, 0.5), Vector3(-0.5, height, 0.5), Vector3(-0.5, height, -0.5),
		Vector3.LEFT, side)
	_b.quad(Vector3(0.5, 0.0, -0.5), Vector3(0.5, 0.0, 0.5), Vector3(0.5, height, 0.5), Vector3(0.5, height, -0.5),
		Vector3.RIGHT, side)
	_save(FARMLAND + String(id) + ".res")


func _tree_round() -> void:
	_b.prism(Vector3.ZERO, 0.35, 0.25, 2.6, 5, &"bark")
	_b.prism(Vector3(0.0, 2.2, 0.0), 2.0, 3.2, 1.6, 7, &"leaf_dark", &"leaf", true)
	_b.prism(Vector3(0.0, 3.8, 0.0), 3.2, 1.0, 3.0, 7, &"leaf", &"leaf")
	_save(FARMLAND + "tree_round.res")


## Columnar windbreak tree (poplar): the farmland tree-line silhouette.
func _tree_poplar() -> void:
	_b.prism(Vector3.ZERO, 0.3, 0.2, 1.6, 5, &"bark")
	_b.prism(Vector3(0.0, 1.4, 0.0), 1.1, 1.6, 3.0, 6, &"leaf_dark", &"", true)
	_b.prism(Vector3(0.0, 4.4, 0.0), 1.6, 0.0, 9.0, 6, &"leaf")
	_save(FARMLAND + "tree_poplar.res")


## Barn, farmhouse and a silo on one yard (about 40 x 40 m).
func _farmstead() -> void:
	# Barn: red walls, slate gable roof, long axis along z.
	_b.box(Vector3(6.0, 3.0, 0.0), Vector3(12.0, 6.0, 18.0), &"barn_red")
	_b.gable_roof(Vector2(6.0, 0.0), 6.0, 9.0, 6.0, 10.5, &"roof_slate", &"barn_red", 0.4)
	_b.box(Vector3(6.0, 2.2, 9.1), Vector3(4.0, 4.4, 0.2), &"cream")
	_b.box(Vector3(6.0, 2.0, 9.25), Vector3(3.2, 3.6, 0.2), &"barn_red")
	# Silo beside the barn.
	_b.prism(Vector3(15.0, 0.0, -4.0), 3.0, 3.0, 15.0, 10, &"silo_metal")
	_b.dome(Vector3(15.0, 15.0, -4.0), 3.0, 2.4, 10, 2, &"steel")
	# Farmhouse: cream walls, dark roof, a porch.
	_b.box(Vector3(-10.0, 2.6, 8.0), Vector3(8.0, 5.2, 10.0), &"cream")
	_b.gable_roof(Vector2(-10.0, 8.0), 4.0, 5.0, 5.2, 7.8, &"roof_slate", &"cream", 0.5)
	_b.box(Vector3(-13.9, 1.1, 8.0), Vector3(0.3, 2.2, 6.0), &"white")
	# Windbreak trees behind the house.
	_b.prism(Vector3(-16.0, 0.0, -8.0), 0.3, 0.2, 2.0, 5, &"bark")
	_b.prism(Vector3(-16.0, 1.8, -8.0), 1.6, 0.0, 8.0, 6, &"leaf")
	_b.prism(Vector3(-11.0, 0.0, -11.0), 0.3, 0.2, 2.0, 5, &"bark")
	_b.prism(Vector3(-11.0, 1.8, -11.0), 1.4, 0.0, 7.0, 6, &"leaf_dark")
	_save(FARMLAND + "farmstead.res")


## A row of corrugated grain bins with conical roofs and one tall silo.
func _grain_bins() -> void:
	for i in 3:
		var z := -9.0 + float(i) * 9.0
		_b.prism(Vector3(0.0, 0.0, z), 4.0, 4.0, 7.0, 12, &"silo_metal")
		_b.prism(Vector3(0.0, 7.0, z), 4.2, 0.6, 2.4, 12, &"steel", &"steel")
	_b.prism(Vector3(7.0, 0.0, 0.0), 2.4, 2.4, 20.0, 10, &"white")
	_b.dome(Vector3(7.0, 20.0, 0.0), 2.4, 1.8, 10, 2, &"sign_blue")
	_b.beam(Vector3(4.2, 9.2, -9.0), Vector3(7.0, 19.0, 0.0), 0.25, &"steel_dark")
	_save(FARMLAND + "grain_bins.res")


## American farm windpump: lattice tower, rotor facing the road, tail vane.
func _windpump() -> void:
	var h := 11.0
	var base := 1.6
	var top := 0.35
	var legs := [Vector2(1, 1), Vector2(1, -1), Vector2(-1, -1), Vector2(-1, 1)]
	for l: Vector2 in legs:
		_b.beam(Vector3(l.x * base, 0.0, l.y * base), Vector3(l.x * top, h, l.y * top), 0.12, &"steel")
	for k in 3:
		var f := float(k + 1) / 4.0
		var y := h * f
		var r := lerpf(base, top, f)
		for i in 4:
			var a: Vector2 = legs[i]
			var b: Vector2 = legs[(i + 1) % 4]
			_b.beam(Vector3(a.x * r, y, a.y * r), Vector3(b.x * r, y, b.y * r), 0.07, &"steel", false)
	var hub := Vector3(-0.6, h + 0.6, 0.0)
	_b.tube(Vector3(0.6, h + 0.6, 0.0), hub, 0.25, 0.3, 6, &"steel_dark")
	var blades := 14
	for i in blades:
		var a := TAU * float(i) / float(blades)
		var dir := Vector3(0.0, sin(a), cos(a))
		_b.beam(hub + dir * 0.4 + Vector3(-0.05, 0, 0), hub + dir * 2.4 + Vector3(-0.05, 0, 0), 0.22, &"white", false)
	_b.beam(Vector3(0.6, h + 0.6, 0.0), Vector3(3.4, h + 0.6, 0.0), 0.1, &"steel_dark")
	_b.quad(Vector3(2.6, h + 0.1, 0.0), Vector3(3.8, h + 0.1, 0.0), Vector3(3.8, h + 1.5, 0.0), Vector3(2.6, h + 1.2, 0.0),
		Vector3.BACK, &"reflector_red")
	_b.quad(Vector3(2.6, h + 0.1, -0.01), Vector3(3.8, h + 0.1, -0.01), Vector3(3.8, h + 1.5, -0.01),
		Vector3(2.6, h + 1.2, -0.01), Vector3.FORWARD, &"reflector_red")
	_save(FARMLAND + "windpump.res")


## Classic small-town water tower: four legs, cylindrical tank, cone roof.
func _water_tower() -> void:
	var tank_y := 16.0
	var legs := [Vector2(1, 1), Vector2(1, -1), Vector2(-1, -1), Vector2(-1, 1)]
	for l: Vector2 in legs:
		_b.beam(Vector3(l.x * 4.0, 0.0, l.y * 4.0), Vector3(l.x * 3.0, tank_y + 0.5, l.y * 3.0), 0.35, &"steel")
	for i in 4:
		var a: Vector2 = legs[i]
		var b: Vector2 = legs[(i + 1) % 4]
		_b.beam(Vector3(a.x * 3.5, 8.0, a.y * 3.5), Vector3(b.x * 3.5, 8.0, b.y * 3.5), 0.2, &"steel", false)
	_b.prism(Vector3(0.0, tank_y, 0.0), 5.2, 5.2, 6.0, 12, &"sky_pale", &"", true)
	_b.prism(Vector3(0.0, tank_y + 2.2, 0.0), 5.25, 5.25, 1.2, 12, &"brand_navy", &"brand_navy")
	_b.prism(Vector3(0.0, tank_y + 6.0, 0.0), 5.4, 0.0, 2.8, 12, &"steel_dark")
	_b.prism(Vector3(0.0, tank_y - 1.2, 0.0), 1.2, 5.2, 1.2, 12, &"sky_pale")
	_save(FARMLAND + "water_tower.res")


## Modern wind turbine (static): tapered tower, nacelle, three blades.
func _wind_turbine() -> void:
	var h := 72.0
	_b.prism(Vector3.ZERO, 2.2, 1.3, h, 8, &"white", &"white")
	_b.box(Vector3(1.5, h + 1.2, 0.0), Vector3(7.0, 2.6, 2.6), &"white", &"white", true)
	var hub := Vector3(-2.4, h + 1.2, 0.0)
	_b.tube(Vector3(-1.9, h + 1.2, 0.0), hub + Vector3(-1.0, 0.0, 0.0), 1.2, 0.2, 8, &"concrete")
	for i in 3:
		var a := TAU * float(i) / 3.0 + 0.3
		var dir := Vector3(0.0, cos(a), sin(a))
		var side := Vector3(0.0, -sin(a), cos(a))
		var root := hub + dir * 1.0
		var tip := hub + dir * 36.0
		_b.quad(root + side * 1.3, root - side * 0.6, tip - side * 0.25, tip + side * 0.35, Vector3.LEFT, &"white")
		_b.quad(root + side * 1.3, root - side * 0.6, tip - side * 0.25, tip + side * 0.35, Vector3.RIGHT, &"concrete")
	_save(FARMLAND + "wind_turbine.res")


# ---------------------------------------------------------------- Style-guide sheet

## assets/palette/palette.png: one 32 px swatch per palette color, 8 per row.
func _palette_png() -> void:
	var rows := ceili(float(_pal.size()) / float(SWATCH_COLS))
	var img := Image.create(SWATCH_COLS * SWATCH_PX, rows * SWATCH_PX, false, Image.FORMAT_RGB8)
	img.fill(Color.BLACK)
	for i in _pal.size():
		var x := (i % SWATCH_COLS) * SWATCH_PX
		var y := (i / SWATCH_COLS) * SWATCH_PX
		img.fill_rect(Rect2i(x + 1, y + 1, SWATCH_PX - 2, SWATCH_PX - 2), _pal.colors[i])
	img.save_png(ProjectSettings.globalize_path(PALETTE_PNG))
	_written.append(PALETTE_PNG)
