extends SceneTree
## Builds the desert mesas and canyon pass prop meshes (WP6.4a, in-house procedural
## art like the farmland set; plan D2). Spec: World → Biomes ("Desert mesas: red rock
## mesas, cacti, long straights"; "Canyon pass: cliffs, tunnels"), Art pipeline
## (palette colours, flat shading, low poly, no textures), Performance budget.
##
##   tools/godot.sh --headless --path . --script res://tools/props/build_props_desert_canyon.gd
##
## Writes assets/props/desert/*.res and assets/props/canyon/*.res (one surface each,
## world material, vertex colours from the palette plus BiomeColors). Deterministic:
## every jitter comes from a fixed Rng seed per prop. The canyon's rock walls are not
## meshes here: RoadChunkMesher builds them along the road (CliffDef).
##
## Prop frame (roadside.gd): origin on the ground at the placement point, +X away
## from the road, -Z the direction of travel.

const DESERT := "res://assets/props/desert/"
const CANYON := "res://assets/props/canyon/"

var _b: PropMeshBuilder
var _written: PackedStringArray = []


func _initialize() -> void:
	_b = PropMeshBuilder.new(WBPalette.load_default())
	_b.extra_colors = BiomeColors.COLORS
	for dir: String in [DESERT, CANYON]:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	# Desert mesas.
	_mesa(DESERT + "mesa.res", 11, Vector2(150.0, 90.0), 62.0, 12)
	_butte(DESERT + "butte.res", 23, 34.0, 88.0)
	_saguaro(DESERT + "saguaro.res")
	_cactus_small(DESERT + "cactus_small.res")
	_scrub(DESERT + "scrub.res", 31, &"sage", &"scrub")
	_rocks(DESERT + "rocks.res", 37, [&"red_rock_dark", &"red_rock"], Vector2(0.5, 1.6), 5)
	_fence_desert(DESERT + "fence_desert.res")
	# Canyon pass.
	_rocks(CANYON + "boulders.res", 41, [&"canyon_rock_dark", &"canyon_rock"], Vector2(1.2, 3.4), 4)
	_pine(CANYON + "pine.res")
	_spire(CANYON + "spire.res", 53)
	_scrub(CANYON + "scrub.res", 59, &"scrub", &"sage")
	for p in _written:
		print("wrote ", p)
	quit(0)


func _save(path: String, meta: Dictionary = {}) -> void:
	# A mesh converted from a modelled .glb (tools/art/convert.gd) retires this recipe.
	if ArtConvert.is_converted(path):
		_written.append("%s (kept: converted from a .glb)" % path)
		_b.clear()
		return
	var mesh := _b.commit(meta)
	var err := ResourceSaver.save(mesh, path)
	if err != OK:
		push_error("build_props_desert_canyon: cannot save %s (%d)" % [path, err])
	_written.append("%s (%d tris)" % [path, _b.triangle_count()])
	_b.clear()


# ---------------------------------------------------------------- Rock masses

## A layered rock mass: an irregular `sides`-gon (radii rx, rz, jittered per corner)
## stacked through `levels` (height fractions of h) with radius factors `scales`; each
## band between two levels takes its colour from `bands`; a flat top in `top`.
func _layered_mass(rng: Rng, center: Vector3, rx: float, rz: float, h: float, sides: int,
		levels: PackedFloat64Array, scales: PackedFloat64Array, bands: Array, top: StringName,
		jitter: float) -> void:
	var corner := PackedFloat64Array()
	var phase := rng.float_range(0.0, TAU)
	for i in sides:
		corner.append(rng.float_range(1.0 - jitter, 1.0 + jitter))
	var rings: Array[PackedVector3Array] = []
	for k in levels.size():
		var ring := PackedVector3Array()
		var wob := rng.float_range(-0.03, 0.03)
		for i in sides:
			var a := phase + TAU * float(i) / float(sides)
			var r := corner[i] * (scales[k] + wob)
			ring.append(center + Vector3(cos(a) * rx * r, levels[k] * h, sin(a) * rz * r))
		rings.append(ring)
	for k in levels.size() - 1:
		var lo := rings[k]
		var hi := rings[k + 1]
		var col: StringName = bands[mini(k, bands.size() - 1)]
		for i in sides:
			var j := (i + 1) % sides
			var mid := (lo[i] + lo[j]) * 0.5 - center
			mid.y = 0.0
			_b.face(PackedVector3Array([lo[i], lo[j], hi[j]]), mid, col)
			_b.face(PackedVector3Array([lo[i], hi[j], hi[i]]), mid, col)
	_b.face(rings[rings.size() - 1], Vector3.UP, top)


## Desert mesa: talus apron, dark foot, red cliff bands with a pale stratum, flat top.
func _mesa(path: String, seed_value: int, radii: Vector2, h: float, sides: int) -> void:
	var rng := Rng.new(seed_value)
	_layered_mass(rng, Vector3.ZERO, radii.x, radii.y, h, sides,
		PackedFloat64Array([0.0, 0.16, 0.3, 0.55, 0.64, 0.9, 1.0]),
		PackedFloat64Array([1.32, 1.12, 1.02, 1.0, 0.99, 0.97, 0.95]),
		[&"sand_dark", &"red_rock_dark", &"red_rock", &"rock_band_pale", &"red_rock", &"red_rock_light"],
		&"mesa_top", 0.16)
	_save(path)


## Butte: a narrow, tall mesa with a broad talus apron and a small cap rock.
func _butte(path: String, seed_value: int, radius: float, h: float) -> void:
	var rng := Rng.new(seed_value)
	_layered_mass(rng, Vector3.ZERO, radius, radius * 0.8, h, 9,
		PackedFloat64Array([0.0, 0.22, 0.34, 0.7, 0.78, 0.94, 1.0]),
		PackedFloat64Array([1.9, 1.3, 1.02, 0.96, 0.94, 0.9, 0.84]),
		[&"sand_dark", &"red_rock_dark", &"red_rock", &"rock_band_pale", &"red_rock", &"red_rock_light"],
		&"mesa_top", 0.14)
	_save(path)


## Canyon hoodoo spire: a thin banded pillar on a rubble apron.
func _spire(path: String, seed_value: int) -> void:
	var rng := Rng.new(seed_value)
	_layered_mass(rng, Vector3.ZERO, 7.0, 6.0, 30.0, 7,
		PackedFloat64Array([0.0, 0.14, 0.4, 0.5, 0.78, 0.86, 1.0]),
		PackedFloat64Array([2.0, 1.2, 0.95, 0.82, 0.8, 0.95, 0.7]),
		[&"canyon_rock_dark", &"canyon_rock", &"canyon_rock_pale", &"canyon_rock", &"canyon_rock_dark",
			&"canyon_rock"],
		&"canyon_rock_pale", 0.18)
	_save(path)


## A cluster of faceted boulders (dry-wash rocks, canyon boulders): each a jittered
## prism with a pointed top. Sizes in [size.x, size.y] m.
func _rocks(path: String, seed_value: int, colors: Array, size: Vector2, count: int) -> void:
	var rng := Rng.new(seed_value)
	for n in count:
		var r := rng.float_range(size.x, size.y)
		var c := Vector3(rng.float_range(-2.5, 2.5) * size.y * 0.5, -0.1 * r, rng.float_range(-2.5, 2.5) * size.y * 0.5)
		if n == 0:
			c = Vector3(0.0, -0.1 * r, 0.0)
		var col: StringName = colors[n % colors.size()]
		var top: StringName = colors[(n + 1) % colors.size()]
		_layered_mass(rng, c, r, r * rng.float_range(0.7, 1.0), r * rng.float_range(0.9, 1.4), 6,
			PackedFloat64Array([0.0, 0.55, 1.0]), PackedFloat64Array([1.0, 0.85, 0.35]), [col, top], top, 0.25)
	_save(path)


# ---------------------------------------------------------------- Plants

## Saguaro: a ribbed column with two arms that turn up.
func _saguaro(path: String) -> void:
	var h := 7.2
	_b.prism(Vector3.ZERO, 0.4, 0.34, h, 8, &"cactus", &"cactus_dark")
	_b.prism(Vector3(0.0, h, 0.0), 0.34, 0.0, 0.35, 8, &"cactus_dark")
	for arm: Array in [[1.0, 2.8, 1.25, 2.6], [-1.0, 3.9, 1.0, 1.9]]:
		var sx: float = arm[0]
		var y0: float = arm[1]
		var out: float = arm[2]
		var up: float = arm[3]
		_b.tube(Vector3(0.0, y0, 0.0), Vector3(sx * out, y0, 0.0), 0.26, 0.26, 6, &"cactus", false)
		_b.prism(Vector3(sx * out, y0 - 0.26, 0.0), 0.26, 0.22, up, 6, &"cactus", &"cactus_dark")
	_save(path)


## Low cacti: three barrels with flowers and a prickly-pear clump.
func _cactus_small(path: String) -> void:
	for p: Vector3 in [Vector3(0.0, 0.0, 0.0), Vector3(0.9, 0.0, 0.5), Vector3(-0.6, 0.0, -0.8)]:
		var h := 0.6 + absf(p.x) * 0.3
		_b.prism(p, 0.34, 0.3, h, 7, &"cactus", &"cactus_dark")
		_b.prism(p + Vector3(0.0, h, 0.0), 0.3, 0.0, 0.18, 7, &"cactus_dark")
		_b.box(p + Vector3(0.0, h + 0.12, 0.0), Vector3(0.12, 0.08, 0.12), &"cactus_flower")
	# Prickly pear: flat pads standing on edge.
	var base := Vector3(-1.4, 0.0, 0.8)
	for pad: Array in [[Vector3(0.0, 0.45, 0.0), 0.0], [Vector3(0.35, 0.95, 0.1), 0.6], [Vector3(-0.35, 0.9, 0.0), -0.5]]:
		var c: Vector3 = base + (pad[0] as Vector3)
		_b.xform = Transform3D(Basis(Vector3.UP, float(pad[1])), Vector3.ZERO)
		_b.box(c, Vector3(0.7, 0.8, 0.12), &"cactus", &"cactus_dark")
		_b.xform = Transform3D.IDENTITY
	_save(path)


## Desert scrub (sagebrush / creosote): a clump of low faceted bushes.
func _scrub(path: String, seed_value: int, col: StringName, top: StringName) -> void:
	var rng := Rng.new(seed_value)
	for n in 4:
		var c := Vector3(rng.float_range(-1.6, 1.6), 0.0, rng.float_range(-1.6, 1.6))
		if n == 0:
			c = Vector3.ZERO
		var r := rng.float_range(0.45, 0.9)
		var h := r * rng.float_range(0.7, 1.1)
		_b.prism(c, r * 0.6, r, h * 0.5, 6, col, top, false, rng.unit())
		_b.prism(c + Vector3(0.0, h * 0.5, 0.0), r, 0.0, h * 0.6, 6, top, &"", false, rng.unit())
	_save(path)


## Pine: a trunk and three stacked cones.
func _pine(path: String) -> void:
	_b.prism(Vector3.ZERO, 0.32, 0.22, 3.0, 5, &"bark")
	var y := 1.8
	var r := 2.6
	for k in 3:
		var hh := 4.2 - float(k) * 0.6
		_b.prism(Vector3(0.0, y, 0.0), r, 0.0, hh, 7, &"pine_dark" if k % 2 == 0 else &"pine", &"", true)
		y += hh * 0.55
		r *= 0.72
	_save(path)


# ---------------------------------------------------------------- Fence

## Desert barbed-wire fence segment, 12 m along -Z: a weathered post at z = 0, three wires.
func _fence_desert(path: String) -> void:
	var length := 12.0
	_b.box(Vector3(0.0, 0.6, 0.0), Vector3(0.12, 1.2, 0.12), &"dead_wood")
	for y: float in [0.45, 0.8, 1.1]:
		_b.beam(Vector3(0.0, y, 0.0), Vector3(0.0, y, -length), 0.035, &"steel_dark", false)
	_save(path, {"length_m": length})
