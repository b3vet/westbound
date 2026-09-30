extends SceneTree
## Builds the traffic vehicle models (WP3.1, ART3 start: generated in-house, no
## third-party content). Spec: Traffic → Visuals; Traffic roster (~14 models: 3
## sedans, 2 hatchbacks, 2 SUVs, a pickup, a delivery van, a semi with 2 trailer
## variants, a coach bus, 2 motorbikes, 2 sports cars; plus the coupe type); Cars →
## Modular car convention (simplified for traffic), Art pipeline (palette, flat
## shading), Traffic vehicle budget (3k tris LOD0).
##
##   tools/godot.sh --headless --path . --script res://tools/traffic_models/build_traffic_models.gd
##
## Writes assets/traffic/<model>.res (ArrayMesh, traffic material) and
## assets/traffic/<model>.tscn (root Traffic_<model> + Body MeshInstance3D, the path
## VehicleType.model_scene_paths lists). Deterministic; rerun after changing a recipe.
## A model already converted from a modelled .glb (tools/art/convert.gd, G3) is kept:
## its recipe is retired (ArtConvert.is_converted; delete the .res to bring it back).
##
## Frame: -Z forward, +X right, Y up, meters; origin on the ground at the center of
## the body box (TrafficState's s, d), which for cars is also between the axles.
## Dimensions come from data/vehicle_types/<type>.tres. Mesh meta (read by TrafficView):
##   glow_front / glow_rear  Vector3(lamp half spacing, lamp height, z of the lamp face)
##   wheel_radius_m          for the spin rate
##   paint_palette           optional fixed paint colors (sRGB) instead of the biome's
##   vehicle_type            the VehicleType id the model was built for
##   tris                    triangle count

const OUT := "res://assets/traffic/"
const TYPES := "res://data/vehicle_types/"
## Colors added to the style palette for traffic only: paint shade multipliers (the
## instance paint is multiplied by COLOR.r; see traffic.gdshader).
const PAINT := &"paint"
const PAINT_SHADE := &"paint_shade"
const PAINT_DARK := &"paint_dark"
const GLASS := &"roof_slate"
const TIRE := &"ink"
const TRIM := &"asphalt"
const LAMP_HEAD := &"cream"
const LAMP_TAIL := &"reflector_red"
const LAMP_AMBER := &"reflector_amber"
const WHEEL_SIDES := 8
## Wheel arch: gap around the tire and arc segments.
const ARCH_GAP := 0.06
const ARCH_SEGMENTS := 6
## Lamps stand proud of their face by this much (no z-fighting at range).
const LAMP_DEPTH := 0.04
const SCENE_TEMPLATE := """[gd_scene load_steps=2 format=3]

[ext_resource type="ArrayMesh" path="%s" id="1_mesh"]

[node name="%s" type="Node3D"]

[node name="Body" type="MeshInstance3D" parent="."]
mesh = ExtResource("1_mesh")
"""
const P := preload("res://tools/traffic_models/traffic_mesh_builder.gd")

var _pal: WBPalette
var _b: TrafficMeshBuilder
var _written: PackedStringArray = []
var _type: VehicleType


func _initialize() -> void:
	_pal = _traffic_palette()
	_b = TrafficMeshBuilder.new(_pal)
	_sedan_a()
	_sedan_b()
	_sedan_c()
	_hatchback_a()
	_hatchback_b()
	_suv_a()
	_suv_b()
	_pickup_a()
	_van_a()
	_semi(&"semi_box")
	_semi(&"semi_tank")
	_coach_a()
	_motorbike_sport()
	_motorbike_cruiser()
	_sports_a()
	_sports_b()
	_coupe_a()
	for p in _written:
		print("wrote ", p)
	quit(0)


## The style palette plus the paint shade multipliers.
func _traffic_palette() -> WBPalette:
	var base := WBPalette.load_default()
	var p := WBPalette.new()
	p.names = base.names.duplicate()
	p.colors = base.colors.duplicate()
	for pair: Array in [[PAINT, 1.0], [PAINT_SHADE, 0.8], [PAINT_DARK, 0.55]]:
		p.names.append(String(pair[0]))
		var k: float = pair[1]
		p.colors.append(Color(k, k, k))
	return p


func _begin(type_id: StringName) -> void:
	_type = load(TYPES + String(type_id) + ".tres") as VehicleType
	_b.clear()


func _save(model: StringName, glow_front: Vector3, glow_rear: Vector3, wheel_r: float,
		paint_palette: PackedColorArray = PackedColorArray()) -> void:
	var tris := _b.triangle_count()
	var bb := _b.bounds()
	var meta := {
		"glow_front": glow_front, "glow_rear": glow_rear, "wheel_radius_m": wheel_r,
		"vehicle_type": _type.id, "tris": tris,
	}
	if not paint_palette.is_empty():
		meta["paint_palette"] = paint_palette
	var mesh_path := OUT + String(model) + ".res"
	# Recipe retirement (WP-ART-G, G3): a model converted from a modelled .glb
	# (tools/art/convert.gd; mesh meta art_source) wins; this recipe no longer writes it.
	if ArtConvert.is_converted(mesh_path):
		_written.append("%s (kept: converted from a .glb)" % mesh_path)
		return
	var mesh := _b.commit(meta)
	var err := ResourceSaver.save(mesh, mesh_path)
	if err != OK:
		push_error("build_traffic_models: cannot save %s (%d)" % [mesh_path, err])
		return
	# The wrapper scene is written as text so reruns are byte-identical (a packed
	# scene gets fresh random ids every time).
	var scene_path := OUT + String(model) + ".tscn"
	var f := FileAccess.open(scene_path, FileAccess.WRITE)
	if f == null:
		push_error("build_traffic_models: cannot write %s" % scene_path)
		return
	f.store_string(SCENE_TEMPLATE % [mesh_path, "Traffic_" + String(model)])
	f.close()
	_written.append("%s (%d tris, size %.2f x %.2f x %.2f, type %s %.2f x %.2f x %.2f)" % [
		scene_path, tris, bb.size.x, bb.size.y, bb.size.z, _type.id, _type.width_m, _type.height_m, _type.length_m])


func _pal_colors(names: Array[StringName]) -> PackedColorArray:
	var out := PackedColorArray()
	for n in names:
		out.append(_pal.color(n))
	return out


# ---------------------------------------------------------------- Car kit

## A passenger car: lower body (hood, flanks, trunk) above the wheel arches, a cabin
## with glass, bumpers and rocker panels below the sill (so the arches read), wheels,
## mirrors and the lamp set. Keys (meters, fwd > 0 toward the nose):
##   sill, belt_rear, hood, nose, tail, rake_nose, rake_tail   lower body profile
##   ws_base, roof_front, roof_rear, rg_base                    cabin (windshield base, roof, rear glass base)
##   tumble                                                     cabin top inset per side
##   wheel_r, wheelbase, clear                                  wheels, ground clearance
##   head_y, head_w, tail_y, tail_w, tail_h                     lamps
## Returns the lamp layout [glow_front, glow_rear].
func _car(k: Dictionary) -> Array[Vector3]:
	var l := _type.length_m
	var w := _type.width_m
	var h := _type.height_m
	var hl := l * 0.5
	var hw := w * 0.5
	var sill: float = k.get("sill", 0.5)
	var clear: float = k.get("clear", 0.2)
	var belt_rear: float = k.get("belt_rear", 0.95)
	var hood: float = k.get("hood", 0.88)
	var nose: float = k.get("nose", 0.72)
	var tail: float = k.get("tail", 0.82)
	var rake_nose: float = k.get("rake_nose", 0.35)
	var rake_tail: float = k.get("rake_tail", 0.2)
	var wheel_r: float = k.get("wheel_r", 0.33)
	var wheelbase: float = k.get("wheelbase", l * 0.58)
	var tumble: float = k.get("tumble", 0.16)
	var ws_base: float = k.get("ws_base", hl * 0.3)
	var roof_front: float = k.get("roof_front", 0.0)
	var roof_rear: float = k.get("roof_rear", -hl * 0.4)
	var rg_base: float = k.get("rg_base", -hl * 0.62)
	# Lower body: from the sill up, arches implied by the gap under it.
	var lower := PackedVector2Array([
		Vector2(-hl + 0.12, sill), Vector2(-hl, sill + 0.1), Vector2(-hl, tail),
		Vector2(-hl + rake_tail, belt_rear), Vector2(hl - rake_nose, hood), Vector2(hl, nose),
		Vector2(hl, sill + 0.1), Vector2(hl - 0.12, sill)])
	var top_split: float = k.get("top_split", NAN)
	var lower_edges: Array[StringName] = [TRIM, PAINT, PAINT, PAINT, PAINT, PAINT, TRIM, &"ink"]
	if not is_nan(top_split):
		# Pickup bed: split the top edge; the bed part is dark.
		var y_split := lerpf(belt_rear, hood, inverse_lerp(-hl + rake_tail, hl - rake_nose, top_split))
		lower.insert(4, Vector2(top_split, y_split))
		lower_edges = [TRIM, PAINT, PAINT, &"ink", PAINT, PAINT, PAINT, TRIM, &"ink"]
	_b.part = P.PART_PAINT
	_b.slab(lower, hw, PAINT, PAINT, lower_edges, _parts_for(lower_edges))
	# Bumpers and rocker panels below the sill.
	var bump_len: float = k.get("bump_len", minf(0.5, hl - wheelbase * 0.5 - wheel_r - 0.08))
	var bump_h := sill - clear + 0.06
	_b.part = P.PART_PAINT
	_b.box(Vector3(0.0, clear + bump_h * 0.5, -(hl - bump_len * 0.5) - 0.01),
		Vector3(w - 0.04, bump_h, bump_len), PAINT_SHADE, PAINT_SHADE, true)
	_b.box(Vector3(0.0, clear + bump_h * 0.5, hl - bump_len * 0.5 + 0.01),
		Vector3(w - 0.04, bump_h, bump_len), PAINT_SHADE, PAINT_SHADE, true)
	var rock_len := wheelbase - 2.0 * wheel_r - 0.2
	if rock_len > 0.1:
		_b.box(Vector3(0.0, clear + 0.04 + (sill - clear) * 0.5, 0.0),
			Vector3(w - 0.1, sill - clear, rock_len), PAINT_DARK, PAINT_DARK, true)
	# Dark lower lips on the bumpers (grounding in silhouette).
	_b.part = P.PART_FIXED
	_b.box(Vector3(0.0, clear + 0.06, -hl - 0.012), Vector3(w - 0.3, 0.1, 0.04), TRIM, TRIM, true)
	_b.box(Vector3(0.0, clear + 0.06, hl + 0.012), Vector3(w - 0.3, 0.1, 0.04), TRIM, TRIM, true)
	# Cabin.
	var y_at := func(f: float) -> float:
		return lerpf(belt_rear, hood, clampf(inverse_lerp(-hl + rake_tail, hl - rake_nose, f), 0.0, 1.0)) - 0.02
	var cabin := PackedVector2Array([
		Vector2(rg_base, y_at.call(rg_base)), Vector2(roof_rear, h), Vector2(roof_front, h),
		Vector2(ws_base, y_at.call(ws_base))])
	var cw := PackedFloat32Array([hw - 0.04, hw - tumble, hw - tumble, hw - 0.04])
	var cabin_edges: Array[StringName] = [GLASS, PAINT, GLASS, PAINT]
	var roof_color: StringName = k.get("roof_color", PAINT)
	cabin_edges[1] = roof_color
	var cabin_parts := PackedInt32Array([P.PART_GLASS, P.PART_PAINT if roof_color == PAINT else P.PART_FIXED,
		P.PART_GLASS, P.PART_PAINT])
	_b.part = P.PART_PAINT
	_b.loft(cabin, cw, PAINT, GLASS, cabin_edges, cabin_parts, P.PART_GLASS)
	# B-pillar: a paint band across the side glass (on the tumblehome plane).
	var pillar: float = k.get("pillar", lerpf(roof_rear, roof_front, 0.45))
	var pw := 0.09
	for sx: float in [-1.0, 1.0]:
		var yb: float = y_at.call(pillar) + 0.02
		_b.part = P.PART_PAINT
		_b.quad(Vector3(sx * (hw - 0.035), yb, -(pillar - pw)), Vector3(sx * (hw - 0.035), yb, -(pillar + pw)),
			Vector3(sx * (hw - tumble + 0.005), h - 0.01, -(pillar + pw)),
			Vector3(sx * (hw - tumble + 0.005), h - 0.01, -(pillar - pw)), Vector3(sx, 0.3, 0.0), PAINT)
	# Mirrors.
	var my: float = y_at.call(ws_base) + 0.12
	for sx: float in [-1.0, 1.0]:
		_b.box(Vector3(sx * (hw + 0.01), my, -(ws_base - 0.1)), Vector3(0.06, 0.09, 0.15), PAINT, PAINT, true)
	# Roof rails (SUVs).
	if k.get("rails", false):
		_b.part = P.PART_FIXED
		for sx: float in [-1.0, 1.0]:
			_b.box(Vector3(sx * (hw - tumble - 0.08), h + 0.04, -(roof_front + roof_rear) * 0.5),
				Vector3(0.05, 0.08, roof_front - roof_rear - 0.1), &"steel_dark", &"steel", true)
	# Wheels and dark arches on the flanks.
	var ww: float = k.get("wheel_w", 0.24)
	for f: float in [wheelbase * 0.5, -wheelbase * 0.5]:
		_arches(hw, sill, wheel_r, -f)
		for sx: float in [-1.0, 1.0]:
			_b.wheel(sx * (hw - 0.03), wheel_r, -f, wheel_r, ww, WHEEL_SIDES)
	# Lamps.
	var head_y: float = k.get("head_y", nose - 0.1)
	var head_w: float = k.get("head_w", 0.34)
	var head_h: float = k.get("head_h", 0.12)
	var head_x := hw - 0.08 - head_w * 0.5
	var tail_y: float = k.get("tail_y", tail - 0.12)
	var tail_w: float = k.get("tail_w", 0.34)
	var tail_h: float = k.get("tail_h", 0.14)
	var tail_x := hw - 0.08 - tail_w * 0.5
	for sx: float in [-1.0, 1.0]:
		_b.lamp(Vector3(sx * head_x, head_y, -hl), Vector2(head_w, head_h), false, LAMP_HEAD, P.PART_HEAD, LAMP_DEPTH)
		_b.lamp(Vector3(sx * (hw - 0.05), head_y, -hl), Vector2(0.06, head_h), false, LAMP_AMBER,
			P.PART_BLINK_L if sx < 0.0 else P.PART_BLINK_R, LAMP_DEPTH)
		_b.lamp(Vector3(sx * tail_x, tail_y, hl), Vector2(tail_w, tail_h), true, LAMP_TAIL, P.PART_REAR, LAMP_DEPTH)
		_b.lamp(Vector3(sx * tail_x, tail_y - tail_h * 0.5 - 0.05, hl), Vector2(tail_w * 0.6, 0.06), true,
			LAMP_AMBER, P.PART_BLINK_L if sx < 0.0 else P.PART_BLINK_R, LAMP_DEPTH)
	# Grille, plate, third brake light.
	_b.part = P.PART_FIXED
	var grille_w: float = k.get("grille_w", w - 2.0 * (head_w + 0.2))
	if grille_w > 0.1:
		_b.box(Vector3(0.0, head_y - 0.02, -hl - 0.01), Vector3(grille_w, head_h + 0.06, 0.04), &"ink", &"ink", true)
	_b.box(Vector3(0.0, sill + 0.14, hl + 0.015), Vector3(0.44, 0.12, 0.03), &"cream", &"cream", true)
	if not k.get("no_third_brake", false):
		_b.lamp(Vector3(0.0, h - 0.06, -roof_rear + 0.03), Vector2(0.44, 0.05), true, LAMP_TAIL, P.PART_BRAKE, 0.03)
	var z_front := -hl - LAMP_DEPTH - 0.01
	var z_rear := hl + LAMP_DEPTH + 0.01
	return [Vector3(head_x, head_y, z_front), Vector3(tail_x, tail_y, z_rear)]


## Dark wheel-arch cutouts on both flanks (proud of the side at +-hw) over the wheel
## at z, from the sill up around the tire, so the wheels read under the body.
func _arches(hw: float, sill: float, wheel_r: float, z: float) -> void:
	var r := wheel_r + ARCH_GAP
	if sill >= wheel_r + r:
		return
	var a0 := asin(clampf((sill - wheel_r) / r, -1.0, 1.0))
	var old := _b.part
	_b.part = P.PART_FIXED
	for sx: float in [-1.0, 1.0]:
		var pts := PackedVector3Array()
		for k in ARCH_SEGMENTS + 1:
			var a := lerpf(a0, PI - a0, float(k) / float(ARCH_SEGMENTS))
			pts.append(Vector3(sx * (hw + 0.004), wheel_r + r * sin(a), z + r * cos(a)))
		_b.face(pts, Vector3(sx, 0.0, 0.0), &"ink")
	_b.part = old


## Parts for a list of edge colors: paint shades are PART_PAINT, the rest fixed.
func _parts_for(colors: Array[StringName]) -> PackedInt32Array:
	var out := PackedInt32Array()
	for c in colors:
		out.append(P.PART_PAINT if c == PAINT or c == PAINT_SHADE or c == PAINT_DARK else P.PART_FIXED)
	return out


func _finish_car(model: StringName, k: Dictionary) -> void:
	var lamps := _car(k)
	_save(model, lamps[0], lamps[1], k.get("wheel_r", 0.33))


# ---------------------------------------------------------------- Cars

## Three-box family sedan.
func _sedan_a() -> void:
	_begin(&"sedan")
	_finish_car(&"sedan_a", {"wheelbase": 2.8, "ws_base": 0.75, "roof_front": 0.0, "roof_rear": -1.0,
		"rg_base": -1.55, "hood": 0.9, "belt_rear": 0.97, "tail": 0.86})


## Fastback sedan: long sloping rear glass, slimmer lamps.
func _sedan_b() -> void:
	_begin(&"sedan")
	_finish_car(&"sedan_b", {"wheelbase": 2.85, "ws_base": 0.85, "roof_front": 0.15, "roof_rear": -0.55,
		"rg_base": -1.85, "hood": 0.86, "belt_rear": 0.95, "tail": 0.9, "head_h": 0.08, "head_w": 0.42,
		"tail_h": 0.08, "tail_w": 0.5, "tumble": 0.2, "rake_nose": 0.45})


## Boxy older sedan: upright glass, square lamps, big grille.
func _sedan_c() -> void:
	_begin(&"sedan")
	_finish_car(&"sedan_c", {"wheelbase": 2.7, "ws_base": 0.55, "roof_front": 0.05, "roof_rear": -1.05,
		"rg_base": -1.35, "hood": 0.95, "belt_rear": 0.98, "tail": 0.92, "nose": 0.82, "head_w": 0.26,
		"head_h": 0.16, "tail_h": 0.2, "tail_w": 0.26, "tumble": 0.12, "rake_nose": 0.15, "rake_tail": 0.1,
		"grille_w": 0.9})


func _hatchback_a() -> void:
	_begin(&"hatchback")
	_finish_car(&"hatchback_a", {"wheelbase": 2.6, "ws_base": 0.85, "roof_front": 0.25, "roof_rear": -1.6,
		"rg_base": -1.95, "hood": 0.9, "belt_rear": 0.98, "tail": 0.95, "rake_tail": 0.05, "tail_y": 0.82,
		"tail_h": 0.2, "tail_w": 0.16, "wheel_r": 0.31})


## Hatchback with a contrasting dark roof and round-ish lamps.
func _hatchback_b() -> void:
	_begin(&"hatchback")
	_finish_car(&"hatchback_b", {"wheelbase": 2.55, "ws_base": 0.7, "roof_front": 0.1, "roof_rear": -1.55,
		"rg_base": -1.9, "hood": 0.92, "belt_rear": 1.0, "tail": 0.9, "rake_tail": 0.1, "roof_color": &"ink",
		"head_w": 0.24, "head_h": 0.16, "tail_w": 0.2, "tail_h": 0.18, "wheel_r": 0.31, "tumble": 0.2})


func _suv_a() -> void:
	_begin(&"suv")
	_finish_car(&"suv_a", {"wheelbase": 2.85, "sill": 0.62, "clear": 0.26, "ws_base": 0.95, "roof_front": 0.45,
		"roof_rear": -2.2, "rg_base": -2.35, "hood": 1.08, "belt_rear": 1.12, "nose": 0.98, "tail": 1.08,
		"rake_tail": 0.08, "wheel_r": 0.38, "wheel_w": 0.27, "rails": true, "tail_y": 1.0, "tail_h": 0.2,
		"tail_w": 0.2, "tumble": 0.12, "no_third_brake": false})


func _suv_b() -> void:
	_begin(&"suv")
	_finish_car(&"suv_b", {"wheelbase": 2.9, "sill": 0.6, "clear": 0.24, "ws_base": 1.05, "roof_front": 0.3,
		"roof_rear": -1.9, "rg_base": -2.3, "hood": 1.02, "belt_rear": 1.08, "nose": 0.9, "tail": 1.02,
		"rake_nose": 0.45, "rake_tail": 0.12, "wheel_r": 0.37, "wheel_w": 0.26, "tail_w": 0.42, "tail_h": 0.1,
		"head_w": 0.4, "head_h": 0.09, "tumble": 0.2, "roof_color": &"ink"})


## Pickup: crew cab and an open bed (dark bed floor, paint rails).
func _pickup_a() -> void:
	_begin(&"pickup")
	var k := {"wheelbase": 3.4, "sill": 0.68, "clear": 0.28, "ws_base": 1.15, "roof_front": 0.7,
		"roof_rear": -0.55, "rg_base": -0.62, "hood": 1.12, "belt_rear": 1.1, "nose": 1.02, "tail": 1.1,
		"rake_nose": 0.3, "rake_tail": 0.04, "wheel_r": 0.4, "wheel_w": 0.28, "top_split": -0.7,
		"tail_y": 0.98, "tail_w": 0.14, "tail_h": 0.3, "tumble": 0.1, "head_w": 0.3, "head_h": 0.16,
		"grille_w": 0.95}
	var lamps := _car(k)
	# Bed rails and tailgate cap.
	var hl := _type.length_m * 0.5
	var hw := _type.width_m * 0.5
	_b.part = P.PART_PAINT
	var bed_len := hl - 0.7
	for sx: float in [-1.0, 1.0]:
		_b.box(Vector3(sx * (hw - 0.05), 1.14, (0.7 + hl) * 0.5), Vector3(0.1, 0.08, bed_len), PAINT, PAINT, true)
	_b.box(Vector3(0.0, 1.14, hl - 0.05), Vector3(_type.width_m - 0.2, 0.08, 0.1), PAINT, PAINT, true)
	_save(&"pickup_a", lamps[0], lamps[1], 0.4)


## Sports car: low wedge, wide wheels, split lamps.
func _sports_a() -> void:
	_begin(&"sports")
	_finish_car(&"sports_a", {"wheelbase": 2.6, "sill": 0.42, "clear": 0.13, "ws_base": 0.55, "roof_front": -0.3,
		"roof_rear": -0.9, "rg_base": -1.75, "hood": 0.74, "belt_rear": 0.86, "nose": 0.56, "tail": 0.84,
		"rake_nose": 0.7, "rake_tail": 0.12, "wheel_r": 0.34, "wheel_w": 0.3, "head_w": 0.4, "head_h": 0.07,
		"tail_w": 0.62, "tail_h": 0.07, "tumble": 0.28, "grille_w": 0.7, "no_third_brake": true})


## Sports car with a rear wing.
func _sports_b() -> void:
	_begin(&"sports")
	var k := {"wheelbase": 2.55, "sill": 0.4, "clear": 0.12, "ws_base": 0.65, "roof_front": -0.1,
		"roof_rear": -0.75, "rg_base": -1.55, "hood": 0.72, "belt_rear": 0.84, "nose": 0.55, "tail": 0.86,
		"rake_nose": 0.6, "rake_tail": 0.25, "wheel_r": 0.34, "wheel_w": 0.3, "head_w": 0.3, "head_h": 0.1,
		"tail_w": 0.24, "tail_h": 0.12, "tumble": 0.26, "roof_color": &"ink", "no_third_brake": true}
	var lamps := _car(k)
	var hl := _type.length_m * 0.5
	_b.part = P.PART_FIXED
	for sx: float in [-0.55, 0.55]:
		_b.box(Vector3(sx, 0.98, hl - 0.3), Vector3(0.06, 0.2, 0.14), &"ink", &"ink", true)
	_b.part = P.PART_PAINT
	_b.box(Vector3(0.0, 1.1, hl - 0.28), Vector3(_type.width_m - 0.3, 0.05, 0.34), PAINT, PAINT_SHADE, true)
	_save(&"sports_b", lamps[0], lamps[1], 0.34)


## Two-door coupe: long hood, short fastback cabin.
func _coupe_a() -> void:
	_begin(&"coupe")
	_finish_car(&"coupe_a", {"wheelbase": 2.75, "sill": 0.45, "clear": 0.15, "ws_base": 0.4, "roof_front": -0.25,
		"roof_rear": -0.95, "rg_base": -1.7, "hood": 0.8, "belt_rear": 0.88, "nose": 0.64, "tail": 0.86,
		"rake_nose": 0.55, "rake_tail": 0.18, "wheel_r": 0.33, "wheel_w": 0.27, "head_w": 0.36, "head_h": 0.09,
		"tail_w": 0.4, "tail_h": 0.09, "tumble": 0.22, "pillar": -0.2})


# ---------------------------------------------------------------- Van

## Delivery van: one tall body, glass cab, blank cargo sides.
func _van_a() -> void:
	_begin(&"van")
	var l := _type.length_m
	var w := _type.width_m
	var h := _type.height_m
	var hl := l * 0.5
	var hw := w * 0.5
	var sill := 0.62
	var clear := 0.22
	var wheel_r := 0.36
	var wheelbase := 3.65
	var body := PackedVector2Array([
		Vector2(-hl + 0.05, sill), Vector2(-hl, sill + 0.08), Vector2(-hl, h - 0.08), Vector2(-hl + 0.1, h),
		Vector2(hl - 1.05, h), Vector2(hl - 0.5, 1.2), Vector2(hl, 1.0), Vector2(hl, sill + 0.08),
		Vector2(hl - 0.08, sill)])
	var edges: Array[StringName] = [TRIM, PAINT, PAINT, PAINT, GLASS, PAINT, PAINT, TRIM, &"ink"]
	var parts := _parts_for(edges)
	parts[4] = P.PART_GLASS
	_b.part = P.PART_PAINT
	_b.slab(body, hw, PAINT, PAINT, edges, parts)
	# Cab side windows (proud of the side), rear door windows, door seam.
	for sx: float in [-1.0, 1.0]:
		var x := sx * (hw + 0.005)
		_b.part = P.PART_GLASS
		_b.quad(Vector3(x, 1.3, -(hl - 0.62)), Vector3(x, 1.3, -(hl - 1.5)), Vector3(x, h - 0.3, -(hl - 1.5)),
			Vector3(x, h - 0.3, -(hl - 1.12)), Vector3(sx, 0.0, 0.0), GLASS)
		_b.part = P.PART_PAINT
		_b.quad(Vector3(x, sill + 0.05, -(hl - 1.6)), Vector3(x, sill + 0.05, -(hl - 1.65)),
			Vector3(x, h - 0.1, -(hl - 1.65)), Vector3(x, h - 0.1, -(hl - 1.6)), Vector3(sx, 0.0, 0.0), PAINT_DARK)
	_b.part = P.PART_GLASS
	for sx: float in [-1.0, 1.0]:
		_b.quad(Vector3(sx * 0.1, 1.55, hl + 0.005), Vector3(sx * (hw - 0.15), 1.55, hl + 0.005),
			Vector3(sx * (hw - 0.15), h - 0.3, hl + 0.005), Vector3(sx * 0.1, h - 0.3, hl + 0.005), Vector3.BACK, GLASS)
	_b.part = P.PART_PAINT
	var bump_h := sill - clear + 0.06
	_b.box(Vector3(0.0, clear + bump_h * 0.5, -(hl - 0.2)), Vector3(w - 0.04, bump_h, 0.42), TRIM, TRIM, true)
	_b.box(Vector3(0.0, clear + bump_h * 0.5, hl - 0.2), Vector3(w - 0.04, bump_h, 0.42), TRIM, TRIM, true)
	_b.box(Vector3(0.0, clear + 0.04 + (sill - clear) * 0.5, 0.0), Vector3(w - 0.12, sill - clear,
		wheelbase - 2.0 * wheel_r - 0.2), PAINT_DARK, PAINT_DARK, true)
	for sx: float in [-1.0, 1.0]:
		_b.box(Vector3(sx * (hw + 0.06), 1.5, -(hl - 0.7)), Vector3(0.1, 0.24, 0.12), &"ink", &"ink", true)
	for f: float in [wheelbase * 0.5, -wheelbase * 0.5]:
		_arches(hw, sill, wheel_r, -f)
		for sx: float in [-1.0, 1.0]:
			_b.wheel(sx * (hw - 0.04), wheel_r, -f, wheel_r, 0.26, WHEEL_SIDES)
	var head_x := hw - 0.28
	var head_y := 0.92
	var tail_x := hw - 0.1
	var tail_y := 1.05
	for sx: float in [-1.0, 1.0]:
		_b.lamp(Vector3(sx * head_x, head_y, -hl), Vector2(0.34, 0.16), false, LAMP_HEAD, P.PART_HEAD)
		_b.lamp(Vector3(sx * (hw - 0.06), head_y, -hl + 0.02), Vector2(0.08, 0.16), false, LAMP_AMBER,
			P.PART_BLINK_L if sx < 0.0 else P.PART_BLINK_R)
		_b.lamp(Vector3(sx * tail_x, tail_y, hl), Vector2(0.14, 0.34), true, LAMP_TAIL, P.PART_REAR)
		_b.lamp(Vector3(sx * tail_x, tail_y - 0.26, hl), Vector2(0.14, 0.12), true, LAMP_AMBER,
			P.PART_BLINK_L if sx < 0.0 else P.PART_BLINK_R)
	_b.lamp(Vector3(0.0, h - 0.08, hl), Vector2(0.5, 0.06), true, LAMP_TAIL, P.PART_BRAKE, 0.03)
	_b.part = P.PART_FIXED
	_b.box(Vector3(0.0, head_y, -hl - 0.01), Vector3(0.9, 0.24, 0.04), &"ink", &"ink", true)
	_b.box(Vector3(0.0, sill + 0.2, hl + 0.015), Vector3(0.44, 0.12, 0.03), &"cream", &"cream", true)
	_save(&"van_a", Vector3(head_x, head_y, -hl - 0.05), Vector3(tail_x, tail_y, hl + 0.05), wheel_r)


# ---------------------------------------------------------------- Semi

## Conventional tractor (long hood, sleeper, fairing) with a box or tank trailer.
## Tractor paint comes from the biome palette; the trailer is fixed white or steel.
func _semi(model: StringName) -> void:
	_begin(&"semi")
	var l := _type.length_m
	var w := _type.width_m
	var h := _type.height_m
	var hl := l * 0.5
	var hw := w * 0.5
	var r := 0.52
	var cab_w := hw - 0.08
	# Chassis rails, fuel tanks, fifth wheel.
	_b.part = P.PART_FIXED
	_b.box(Vector3(0.0, 0.85, -(hl - 3.3)), Vector3(1.0, 0.35, 6.4), &"ink", &"ink", true)
	for sx: float in [-1.0, 1.0]:
		_b.tube(Vector3(sx * (hw - 0.3), 0.8, -(hl - 3.6)), Vector3(sx * (hw - 0.3), 0.8, -(hl - 4.6)), 0.3, 0.3, 8,
			&"steel")
	# Tractor: hood and cab (paint), bumper, grille, windshield, sleeper, fairing.
	var hood := PackedVector2Array([
		Vector2(hl - 2.6, 1.0), Vector2(hl - 2.6, 2.0), Vector2(hl - 0.3, 1.85), Vector2(hl, 1.6),
		Vector2(hl, 1.0)])
	var hood_edges: Array[StringName] = [PAINT, PAINT, PAINT, &"steel", PAINT_DARK]
	_b.part = P.PART_PAINT
	_b.slab(hood, cab_w - 0.25, PAINT, PAINT, hood_edges, _parts_for(hood_edges))
	var cab := PackedVector2Array([
		Vector2(hl - 4.3, 1.0), Vector2(hl - 4.3, h - 0.55), Vector2(hl - 3.3, h - 0.25), Vector2(hl - 2.75, 3.0),
		Vector2(hl - 2.45, 2.0), Vector2(hl - 2.45, 1.0)])
	var cab_edges: Array[StringName] = [PAINT, PAINT, PAINT, GLASS, PAINT, PAINT_DARK]
	var cab_parts := _parts_for(cab_edges)
	cab_parts[3] = P.PART_GLASS
	_b.slab(cab, cab_w, PAINT, PAINT, cab_edges, cab_parts)
	for sx: float in [-1.0, 1.0]:
		var x := sx * (cab_w + 0.005)
		_b.part = P.PART_GLASS
		_b.quad(Vector3(x, 2.15, -(hl - 2.55)), Vector3(x, 2.15, -(hl - 3.35)), Vector3(x, 2.95, -(hl - 3.35)),
			Vector3(x, 2.95, -(hl - 2.8)), Vector3(sx, 0.0, 0.0), GLASS)
		_b.part = P.PART_FIXED
		_b.box(Vector3(sx * (cab_w + 0.14), 2.4, -(hl - 2.4)), Vector3(0.08, 0.5, 0.14), &"steel", &"steel", true)
		_b.beam(Vector3(sx * (cab_w - 0.1), h - 0.5, -(hl - 3.9)), Vector3(sx * (cab_w - 0.1), 1.2, -(hl - 3.9)),
			0.12, &"steel")
	_b.part = P.PART_FIXED
	_b.box(Vector3(0.0, 0.8, -(hl + 0.05)), Vector3(w - 0.1, 0.36, 0.3), &"steel", &"steel", true)
	_b.box(Vector3(0.0, 1.35, -(hl + 0.01)), Vector3(1.1, 0.5, 0.04), &"steel_dark", &"steel_dark", true)
	# Roof marker lamps (fixed amber, not lamp groups).
	for i in 5:
		_b.box(Vector3(-0.6 + 0.3 * float(i), h - 0.2, -(hl - 3.3 - 0.1)), Vector3(0.08, 0.06, 0.06),
			LAMP_AMBER, LAMP_AMBER, true)
	# Trailer.
	var t_front := hl - 4.45
	var t_rear := -hl
	var t_len := t_front - t_rear
	var t_mid := (t_front + t_rear) * 0.5
	if model == &"semi_tank":
		_b.part = P.PART_FIXED
		_b.box(Vector3(0.0, 1.1, -t_mid), Vector3(1.0, 0.3, t_len), &"ink", &"ink", true)
		_b.tube(Vector3(0.0, 2.35, -(t_front - 0.2)), Vector3(0.0, 2.35, -(t_rear + 0.35)), 1.08, 1.08, 10,
			&"silo_metal", true)
		_b.box(Vector3(0.0, 3.45, -t_mid), Vector3(0.5, 0.08, t_len - 1.2), &"steel_dark", &"steel", true)
		_b.box(Vector3(0.0, 1.2, -(t_rear + 0.2)), Vector3(w - 0.1, 0.6, 0.4), &"steel_dark", &"steel_dark", true)
	else:
		_b.part = P.PART_FIXED
		var box_prof := PackedVector2Array([
			Vector2(t_rear, 1.3), Vector2(t_rear, h), Vector2(t_front, h), Vector2(t_front, 1.3)])
		var box_edges: Array[StringName] = [&"white", &"white", &"white", &"steel_dark"]
		_b.slab(box_prof, hw, &"white", &"white", box_edges, PackedInt32Array([0, 0, 0, 0]))
		# Side stripe and rear door seams.
		for sx: float in [-1.0, 1.0]:
			var x := sx * (hw + 0.005)
			_b.quad(Vector3(x, 1.45, -(t_front - 0.3)), Vector3(x, 1.45, -(t_rear + 0.3)),
				Vector3(x, 1.6, -(t_rear + 0.3)), Vector3(x, 1.6, -(t_front - 0.3)), Vector3(sx, 0.0, 0.0),
				&"sign_blue")
		_b.quad(Vector3(-0.02, 1.35, -t_rear + 0.005), Vector3(0.02, 1.35, -t_rear + 0.005),
			Vector3(0.02, h - 0.05, -t_rear + 0.005), Vector3(-0.02, h - 0.05, -t_rear + 0.005), Vector3.BACK,
			&"steel_dark")
		_b.box(Vector3(0.0, 1.2, -t_mid), Vector3(1.0, 0.2, t_len), &"ink", &"ink", true)
	# Underride guard.
	_b.box(Vector3(0.0, 0.62, -(t_rear + 0.25)), Vector3(w - 0.2, 0.12, 0.1), &"steel_dark", &"steel", true)
	# Wheels: steer axle, drive tandem, trailer tandem (duals drawn as one wide tire).
	for z: float in [-(hl - 1.3)]:
		for sx: float in [-1.0, 1.0]:
			_b.wheel(sx * (hw - 0.1), r, z, r, 0.3, WHEEL_SIDES)
	for z: float in [-(hl - 5.1), -(hl - 6.45), -(t_rear + 1.2), -(t_rear + 2.55)]:
		for sx: float in [-1.0, 1.0]:
			_b.wheel(sx * (hw - 0.04), r, z, r, 0.5, WHEEL_SIDES)
	# Lamps.
	var head_x := cab_w - 0.45
	var head_y := 1.15
	var tail_x := hw - 0.22
	var tail_y := 1.05
	for sx: float in [-1.0, 1.0]:
		_b.lamp(Vector3(sx * head_x, head_y, -hl), Vector2(0.34, 0.18), false, LAMP_HEAD, P.PART_HEAD)
		_b.lamp(Vector3(sx * head_x, head_y + 0.2, -hl), Vector2(0.2, 0.1), false, LAMP_AMBER,
			P.PART_BLINK_L if sx < 0.0 else P.PART_BLINK_R)
		_b.lamp(Vector3(sx * tail_x, tail_y, -t_rear + 0.05), Vector2(0.26, 0.2), true, LAMP_TAIL, P.PART_REAR)
		_b.lamp(Vector3(sx * (tail_x - 0.3), tail_y, -t_rear + 0.05), Vector2(0.2, 0.2), true, LAMP_AMBER,
			P.PART_BLINK_L if sx < 0.0 else P.PART_BLINK_R)
		_b.lamp(Vector3(sx * (hw - 0.1), h - 0.15, -t_rear), Vector2(0.1, 0.1), true, LAMP_TAIL, P.PART_REAR)
	_save(model, Vector3(head_x, head_y, -hl - 0.06), Vector3(tail_x, tail_y, -t_rear + 0.1), r)


# ---------------------------------------------------------------- Coach

## Coach bus: fixed white body, paint stripe (a fixed livery palette), window band.
func _coach_a() -> void:
	_begin(&"coach")
	var l := _type.length_m
	var w := _type.width_m
	var h := _type.height_m
	var hl := l * 0.5
	var hw := w * 0.5
	var sill := 0.55
	var r := 0.5
	var body := PackedVector2Array([
		Vector2(-hl + 0.05, sill), Vector2(-hl, sill + 0.08), Vector2(-hl, h - 0.15), Vector2(-hl + 0.2, h),
		Vector2(hl - 0.45, h), Vector2(hl - 0.08, h - 0.4), Vector2(hl, 1.25), Vector2(hl, sill + 0.08),
		Vector2(hl - 0.05, sill)])
	var edges: Array[StringName] = [TRIM, &"white", &"white", &"white", &"white", GLASS, &"white", TRIM, &"ink"]
	var parts := PackedInt32Array([0, 0, 0, 0, 0, P.PART_GLASS, 0, 0, 0])
	_b.part = P.PART_FIXED
	_b.slab(body, hw, &"white", &"white", edges, parts)
	for sx: float in [-1.0, 1.0]:
		var x := sx * (hw + 0.005)
		_b.part = P.PART_GLASS
		_b.quad(Vector3(x, 1.6, -(hl - 0.35)), Vector3(x, 1.6, -(-hl + 0.45)), Vector3(x, h - 0.4, -(-hl + 0.45)),
			Vector3(x, h - 0.4, -(hl - 0.3)), Vector3(sx, 0.0, 0.0), GLASS)
		_b.part = P.PART_PAINT
		_b.quad(Vector3(x, 1.12, -(hl - 0.1)), Vector3(x, 1.12, -(-hl + 0.1)), Vector3(x, 1.42, -(-hl + 0.1)),
			Vector3(x, 1.42, -(hl - 0.1)), Vector3(sx, 0.0, 0.0), PAINT)
		_b.part = P.PART_FIXED
		_b.box(Vector3(sx * (hw + 0.1), h - 0.55, -(hl - 0.15)), Vector3(0.08, 0.4, 0.12), &"ink", &"ink", true)
	_b.part = P.PART_GLASS
	_b.quad(Vector3(-hw + 0.25, 2.2, hl + 0.005), Vector3(hw - 0.25, 2.2, hl + 0.005),
		Vector3(hw - 0.25, h - 0.3, hl + 0.005), Vector3(-hw + 0.25, h - 0.3, hl + 0.005), Vector3.BACK, GLASS)
	_b.part = P.PART_PAINT
	_b.quad(Vector3(-hw + 0.1, 1.12, -hl - 0.005), Vector3(hw - 0.1, 1.12, -hl - 0.005),
		Vector3(hw - 0.1, 1.24, -hl - 0.005), Vector3(-hw + 0.1, 1.24, -hl - 0.005), Vector3.FORWARD, PAINT)
	_b.part = P.PART_FIXED
	_b.box(Vector3(0.0, 1.2, hl + 0.01), Vector3(1.4, 0.5, 0.04), &"steel_dark", &"steel_dark", true)
	_b.box(Vector3(0.0, sill - 0.1, -hl - 0.02), Vector3(w - 0.06, 0.3, 0.12), TRIM, TRIM, true)
	_b.box(Vector3(0.0, sill - 0.1, hl + 0.02), Vector3(w - 0.06, 0.3, 0.12), TRIM, TRIM, true)
	for z: float in [-(hl - 2.2), hl - 3.2, hl - 2.1]:
		_arches(hw, sill, r, z)
		for sx: float in [-1.0, 1.0]:
			_b.wheel(sx * (hw - 0.06), r, z, r, 0.32, WHEEL_SIDES)
	var head_x := hw - 0.35
	var head_y := 0.85
	var tail_x := hw - 0.15
	var tail_y := 1.0
	for sx: float in [-1.0, 1.0]:
		_b.lamp(Vector3(sx * head_x, head_y, -hl), Vector2(0.4, 0.16), false, LAMP_HEAD, P.PART_HEAD)
		_b.lamp(Vector3(sx * (hw - 0.08), head_y, -hl), Vector2(0.1, 0.16), false, LAMP_AMBER,
			P.PART_BLINK_L if sx < 0.0 else P.PART_BLINK_R)
		_b.lamp(Vector3(sx * tail_x, tail_y, hl), Vector2(0.18, 0.4), true, LAMP_TAIL, P.PART_REAR)
		_b.lamp(Vector3(sx * tail_x, tail_y + 0.35, hl), Vector2(0.18, 0.16), true, LAMP_AMBER,
			P.PART_BLINK_L if sx < 0.0 else P.PART_BLINK_R)
	_b.lamp(Vector3(0.0, h - 0.12, hl), Vector2(0.6, 0.06), true, LAMP_TAIL, P.PART_BRAKE, 0.03)
	_save(&"coach_a", Vector3(head_x, head_y, -hl - 0.05), Vector3(tail_x, tail_y, hl + 0.05), r,
		_pal_colors([&"brand_teal", &"brand_orange", &"brand_navy", &"barn_red", &"sign_green"]))


# ---------------------------------------------------------------- Motorbikes

## Sport bike with a crouched rider (paint on the fairing and the helmet).
func _motorbike_sport() -> void:
	_begin(&"motorbike")
	var r := 0.31
	var wb := 1.42
	var hw := _type.width_m * 0.5
	_bike_wheels(r, wb)
	_b.part = P.PART_PAINT
	var fairing := PackedVector2Array([
		Vector2(-0.35, 0.5), Vector2(-0.3, 0.86), Vector2(0.45, 0.98), Vector2(0.95, 0.95), Vector2(1.02, 0.7),
		Vector2(0.6, 0.42)])
	_b.slab(fairing, 0.17, PAINT, PAINT)
	var tailp := PackedVector2Array([
		Vector2(-1.0, 0.82), Vector2(-0.95, 0.9), Vector2(-0.3, 0.9), Vector2(-0.3, 0.72)])
	_b.slab(tailp, 0.1, PAINT, PAINT_SHADE)
	_b.part = P.PART_GLASS
	_b.quad(Vector3(-0.14, 0.98, -0.52), Vector3(0.14, 0.98, -0.52), Vector3(0.12, 1.12, -0.72),
		Vector3(-0.12, 1.12, -0.72), Vector3(0.0, 1.0, -0.6), GLASS)
	_b.part = P.PART_FIXED
	_b.box(Vector3(0.0, 0.46, -0.1), Vector3(0.3, 0.3, 0.6), &"steel_dark", &"steel_dark", true)
	_b.tube(Vector3(0.14, 0.45, 0.25), Vector3(0.16, 0.6, 0.75), 0.06, 0.07, 6, &"steel")
	_b.beam(Vector3(0.0, r, -wb * 0.5), Vector3(0.0, 0.92, -0.62), 0.07, &"steel")
	_b.beam(Vector3(0.0, r, wb * 0.5), Vector3(0.0, 0.5, 0.1), 0.07, &"steel_dark")
	for sx: float in [-1.0, 1.0]:
		_b.beam(Vector3(sx * 0.12, 0.95, -0.45), Vector3(sx * (hw - 0.02), 0.94, -0.42), 0.04, &"ink")
	_rider(0.5, true)
	var lamps := _bike_lamps(0.8, 1.02, -1.02, 0.88, 0.22)
	_save(&"motorbike_sport", lamps[0], lamps[1], r, _bike_palette())


## Cruiser: low seat, tall bars, round headlight, upright rider.
func _motorbike_cruiser() -> void:
	_begin(&"motorbike")
	var r := 0.33
	var wb := 1.5
	var hw := _type.width_m * 0.5
	_bike_wheels(r, wb)
	_b.part = P.PART_PAINT
	var tank := PackedVector2Array([
		Vector2(-0.05, 0.72), Vector2(0.05, 0.9), Vector2(0.5, 0.92), Vector2(0.62, 0.78), Vector2(0.45, 0.66)])
	_b.slab(tank, 0.15, PAINT, PAINT)
	_b.box(Vector3(0.0, 0.62, 0.85), Vector3(0.22, 0.08, 0.5), PAINT, PAINT, true)
	_b.part = P.PART_FIXED
	_b.box(Vector3(0.0, 0.72, 0.3), Vector3(0.3, 0.1, 0.6), &"ink", &"ink", true)
	_b.box(Vector3(0.0, 0.45, -0.2), Vector3(0.32, 0.36, 0.5), &"steel", &"steel_dark", true)
	for sx: float in [-1.0, 1.0]:
		_b.tube(Vector3(sx * 0.18, 0.38, -0.1), Vector3(sx * 0.2, 0.4, 1.05), 0.05, 0.05, 6, &"steel")
	_b.beam(Vector3(0.0, r, -wb * 0.5), Vector3(0.0, 1.0, -0.62), 0.07, &"steel")
	_b.beam(Vector3(0.0, r, wb * 0.5), Vector3(0.0, 0.55, 0.2), 0.07, &"steel_dark")
	for sx: float in [-1.0, 1.0]:
		_b.beam(Vector3(0.0, 1.0, -0.62), Vector3(sx * (hw - 0.02), 1.12, -0.5), 0.035, &"steel")
	_rider(0.55, false)
	var lamps := _bike_lamps(0.92, 0.98, -1.06, 0.8, 0.16)
	_save(&"motorbike_cruiser", lamps[0], lamps[1], r, _bike_palette())


func _bike_palette() -> PackedColorArray:
	return _pal_colors([&"ink", &"barn_red", &"sign_blue", &"brand_orange", &"white", &"hazard_yellow",
		&"brand_teal"])


func _bike_wheels(r: float, wb: float) -> void:
	for f: float in [wb * 0.5, -wb * 0.5]:
		_b.wheel(0.07, r, -f, r, 0.14, WHEEL_SIDES, true)


## Rider: legs, torso (leaning forward when `crouch`), arms, paint helmet.
func _rider(seat_y: float, crouch: bool) -> void:
	_b.part = P.PART_FIXED
	var hip := Vector3(0.0, seat_y + 0.1, 0.28 if crouch else 0.35)
	for sx: float in [-1.0, 1.0]:
		var knee := Vector3(sx * 0.2, seat_y - 0.02, -0.02 if crouch else -0.15)
		_b.beam(hip + Vector3(sx * 0.12, 0.0, 0.0), knee, 0.14, &"brand_navy")
		_b.beam(knee, Vector3(sx * 0.18, 0.38, 0.12 if crouch else -0.3), 0.11, &"brand_navy")
	var lean := 0.9 if crouch else 0.35
	var torso := 0.55 if crouch else 0.45
	var shoulder := hip + Vector3(0.0, torso * cos(lean) + 0.05, -torso * sin(lean))
	_b.beam(hip, shoulder, 0.36, &"asphalt")
	var hand_z := -0.45 if crouch else -0.5
	var hand_y := 0.95 if crouch else 1.05
	for sx: float in [-1.0, 1.0]:
		_b.beam(shoulder + Vector3(sx * 0.17, -0.04, 0.0), Vector3(sx * 0.3, hand_y, hand_z), 0.09, &"asphalt")
	_b.part = P.PART_PAINT
	var head := shoulder + Vector3(0.0, 0.08, -0.08 if crouch else 0.0)
	_b.prism(head, 0.14, 0.14, 0.12, 8, PAINT, PAINT, true)
	_b.dome(head + Vector3(0.0, 0.12, 0.0), 0.14, 0.12, 8, 2, PAINT)
	_b.part = P.PART_GLASS
	_b.box(head + Vector3(0.0, 0.1, -0.13), Vector3(0.2, 0.08, 0.04), &"ink", &"ink", true)


func _bike_lamps(head_y: float, head_fwd: float, tail_fwd: float, tail_y: float, blink_x: float) -> Array[Vector3]:
	_b.lamp(Vector3(0.0, head_y, -head_fwd), Vector2(0.16, 0.12), false, LAMP_HEAD, P.PART_HEAD)
	_b.lamp(Vector3(0.0, tail_y, -tail_fwd), Vector2(0.14, 0.07), true, LAMP_TAIL, P.PART_REAR)
	for sx: float in [-1.0, 1.0]:
		var part := P.PART_BLINK_L if sx < 0.0 else P.PART_BLINK_R
		_b.lamp(Vector3(sx * blink_x, head_y - 0.08, -head_fwd + 0.08), Vector2(0.06, 0.05), false, LAMP_AMBER, part)
		_b.lamp(Vector3(sx * blink_x, tail_y - 0.04, -tail_fwd - 0.04), Vector2(0.06, 0.05), true, LAMP_AMBER, part)
	return [Vector3(0.0, head_y, -head_fwd - 0.06), Vector3(0.0, tail_y, -tail_fwd + 0.06)]
