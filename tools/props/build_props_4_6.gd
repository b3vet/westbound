extends SceneTree
## Builds the props of biomes 4-6 (WP6.4b): coastal highway, city at night, valley fog.
## Generated in-house like the farmland set (tools/props/build_props.gd; plan §1
## "Interim assets: generated placeholders"). Spec: World → Biomes (coast: ocean,
## cliffs, palms, lighthouse; city: skyline, buildings, neon billboards, sound walls;
## valley: forests, meadows, farmhouses), Art pipeline (palette, flat shading, no
## photo textures), Night lighting (emissive faces: lamps and neon use class 2, city
## windows class 4 of world_windows.gdshader).
##
##   tools/godot.sh --headless --path . --script res://tools/props/build_props_4_6.gd
##
## Writes assets/props/{coast,city,valley}/*.res. Deterministic (fixed Rng seeds).
## Prop frame as in build_props.gd: origin on the ground at the placement point, +X
## away from the road, -Z the direction of travel. City props that stand beside
## elevated stretches reach below y = 0 (FOOTING_M) so they meet the lowered ground.

const COAST := "res://assets/props/coast/"
const CITY := "res://assets/props/city/"
const VALLEY := "res://assets/props/valley/"
## City footings below the road plane (>= ElevatedDef.height_m in data/biomes/city.tres).
const FOOTING_M := 12.0
const FLOOR_M := 3.6
## Neon tube width and how far tubes stand proud of their board.
const TUBE_M := 0.28
const TUBE_RELIEF := 0.12
## Window bays per facade: one per this width, at most MAX_BAYS.
const WINDOW_BAY_M := 11.0
const MAX_BAYS := 3

var _b: BiomePropBuilder
var _written: PackedStringArray = []


func _initialize() -> void:
	_b = BiomePropBuilder.new()
	for dir: String in [COAST, CITY, VALLEY]:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	# Coast
	_palm()
	_scrub()
	_cliff_rock()
	_lighthouse_islet()
	_sea_stacks()
	_coast_house()
	# City
	_office_tower()
	_apartment_block()
	_warehouse()
	_midrise()
	_skyscraper()
	_plaza_tile()
	_street_tree()
	_sound_wall()
	_neon_board()
	_neon_blade()
	# Valley
	_conifer()
	_broadleaf()
	_clump(&"conifer_clump", 9, 0.0, 601)
	_clump(&"mixed_clump", 8, 0.4, 602)
	_meadow(&"meadow_green", 0.12, 4, [&"meadow", &"meadow_light"], &"meadow")
	_meadow(&"meadow_flowers", 0.15, 6, [&"meadow", &"meadow_light", &"flower_yellow"], &"meadow")
	_meadow(&"meadow_hay", 0.25, 4, [&"straw", &"grass_dry"], &"wheat_shade")
	_valley_farm()
	_valley_barn()
	_fence_rail()
	for p in _written:
		print("wrote ", p)
	quit(0)


func _save(path: String, meta: Dictionary = {}, windows: bool = false) -> void:
	var mesh := _b.commit_windows(meta) if windows else _b.commit(meta)
	var err := ResourceSaver.save(mesh, path)
	if err != OK:
		push_error("build_props_4_6: cannot save %s (%d)" % [path, err])
	_written.append("%s (%d tris)" % [path, _b.triangle_count()])
	_b.clear()


## Two-sided flat quad (fronds, signs seen from both sides).
func _two_sided(a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, col: StringName,
		emissive: int = PropMeshBuilder.EMISSIVE_NONE) -> void:
	_b.quad(a, b, c, d, n, col, emissive)
	_b.quad(a, b, c, d, -n, col, emissive)


# ================================================================ Coast

## Leaning coconut palm, ~10 m: segmented trunk, seven drooping folded fronds.
func _palm() -> void:
	var rng := Rng.new(401)
	var segs := 5
	var h := 9.5
	var lean := Vector3(1.6, 0.0, -0.4)
	var prev := Vector3.ZERO
	for i in segs:
		var t1 := float(i + 1) / float(segs)
		var p := lean * (t1 * t1) + Vector3(0.0, h * t1, 0.0)
		var r0 := lerpf(0.34, 0.2, float(i) / float(segs))
		var r1 := lerpf(0.34, 0.2, t1)
		_b.tube(prev, p, r0, r1, 5, &"palm_trunk" if i % 2 == 0 else &"bark", false)
		prev = p
	var crown := prev
	_b.box(crown + Vector3(0.0, -0.35, 0.0), Vector3(0.7, 0.6, 0.7), &"bark", &"bark", true)
	var fronds := 7
	for i in fronds:
		var a := TAU * (float(i) + rng.float_range(-0.2, 0.2)) / float(fronds)
		var dir := Vector3(cos(a), 0.0, sin(a))
		var side := Vector3(-dir.z, 0.0, dir.x)
		var reach := rng.float_range(3.4, 4.4)
		var mid := crown + dir * (reach * 0.5) + Vector3(0.0, rng.float_range(0.5, 0.9), 0.0)
		var tip := crown + dir * reach + Vector3(0.0, rng.float_range(-1.6, -0.9), 0.0)
		var w := 0.75
		var fold := Vector3(0.0, -0.25, 0.0)
		var col: StringName = &"palm_frond" if i % 2 == 0 else &"palm_frond_dark"
		# Each half of the frond is a folded pair of faces (a shallow V).
		_two_sided(crown, crown + fold, mid + fold, mid + side * w, Vector3.UP, col)
		_two_sided(crown, crown + fold, mid + fold, mid - side * w, Vector3.UP, col)
		_b.tri(mid + side * w, mid + fold, tip, Vector3.UP, col)
		_b.tri(mid + side * w, mid + fold, tip, Vector3.DOWN, col)
		_b.tri(mid - side * w, mid + fold, tip, Vector3.UP, col)
		_b.tri(mid - side * w, mid + fold, tip, Vector3.DOWN, col)
	_save(COAST + "palm.res")


## Coastal scrub: a low cluster of faceted bushes and a stone.
func _scrub() -> void:
	var rng := Rng.new(402)
	for i in 5:
		var c := Vector3(rng.float_range(-2.6, 2.6), 0.0, rng.float_range(-2.6, 2.6))
		var r := rng.float_range(0.8, 1.7)
		var h := rng.float_range(0.7, 1.5)
		var col: StringName = &"scrub" if i % 3 != 2 else &"scrub_dry"
		_b.prism(c, r, r * 0.55, h * 0.6, 6, col, col, false, rng.unit())
		_b.prism(c + Vector3(0.0, h * 0.6, 0.0), r * 0.55, 0.0, h * 0.4, 6, col, &"", false, rng.unit())
	_b.prism(Vector3(1.2, 0.0, 2.2), 0.7, 0.35, 0.5, 5, &"rock", &"rock_light")
	_save(COAST + "scrub.res")


## Sea-cliff / road-cut rock mass (~36 m long, 20 deep, 18 high): dark base strata,
## a paler band, a scrubby cap. Rows of these make the cliff wall on the land side.
func _cliff_rock() -> void:
	var rng := Rng.new(403)
	var n := 9
	var c := Vector3(0.0, 0.0, 0.0)
	var r0 := _b.jagged_ring(c, 0.0, 11.0, 18.0, n, 0.12, rng)
	var r1 := _b.jagged_ring(c, 7.0, 10.0, 17.0, n, 0.18, rng, 0.3)
	var r2 := _b.jagged_ring(c, 13.0, 8.0, 14.5, n, 0.2, rng, 0.1)
	var r3 := _b.jagged_ring(c, 17.5, 4.5, 9.5, n, 0.25, rng, 0.45)
	_b.ring_band(r0, r1, c, [&"rock_dark", &"rock"])
	_b.ring_band(r1, r2, c, [&"rock", &"rock_light", &"rock"])
	_b.ring_band(r2, r3, c, [&"rock_light", &"scrub_dry"])
	_b.ring_cap(r3, c + Vector3(0.8, 18.8, -1.0), Vector3.UP, &"scrub")
	_save(COAST + "cliff_rock.res")


## Tower, gallery, lantern and cottage from y = 0 (under `_b.xform`).
func _lighthouse_parts() -> void:
	var y := 0.0
	var bands := [[6.0, &"white"], [3.0, &"reflector_red"], [5.0, &"white"], [2.4, &"reflector_red"]]
	var r := 2.5
	for band: Array in bands:
		var hh: float = band[0]
		var r1 := r - hh * 0.045
		_b.prism(Vector3(0.0, y, 0.0), r, r1, hh, 8, band[1], band[1])
		y += hh
		r = r1
	_b.prism(Vector3(0.0, y, 0.0), r + 0.7, r + 0.7, 0.35, 8, &"ink", &"steel_dark")
	y += 0.35
	# The lantern glass glows (class 2), so it reads as a beacon at dusk and night.
	for i in 8:
		var a0 := TAU * (float(i) + 0.5) / 8.0
		var a1 := TAU * (float(i) + 1.5) / 8.0
		var p0 := Vector3(cos(a0) * 1.37, y + 0.2, sin(a0) * 1.37)
		var p1 := Vector3(cos(a1) * 1.37, y + 0.2, sin(a1) * 1.37)
		_b.quad(p0, p1, p1 + Vector3(0.0, 1.8, 0.0), p0 + Vector3(0.0, 1.8, 0.0), (p0 + p1) * 0.5 - Vector3(0, y, 0),
			&"lamp_warm", PropMeshBuilder.EMISSIVE_STREETLAMP)
	_b.prism(Vector3(0.0, y, 0.0), 1.35, 1.35, 0.2, 8, &"steel_dark", &"steel_dark")
	_b.prism(Vector3(0.0, y + 2.0, 0.0), 1.35, 1.35, 0.2, 8, &"steel_dark", &"steel_dark")
	y += 2.2
	_b.prism(Vector3(0.0, y, 0.0), 1.6, 0.0, 1.6, 8, &"reflector_red")
	_b.box(Vector3(-4.2, 0.9, 3.2), Vector3(3.6, 4.2, 5.0), &"white")
	_b.gable_roof(Vector2(-4.2, 3.2), 1.8, 2.5, 3.0, 4.4, &"reflector_red", &"white", 0.3)


## A lighthouse on a rocky islet (placed in the sea by WaterRibbon: origin at the
## water level, the rock reaching below it).
func _lighthouse_islet() -> void:
	var rng := Rng.new(406)
	var c := Vector3.ZERO
	var r0 := _b.jagged_ring(c, -2.0, 16.0, 13.0, 9, 0.18, rng)
	var r1 := _b.jagged_ring(c, 3.5, 11.0, 9.0, 9, 0.2, rng, 0.4)
	var r2 := _b.jagged_ring(c, 6.0, 6.5, 5.5, 9, 0.15, rng, 0.1)
	_b.ring_band(r0, r1, c, [&"rock_dark", &"rock"])
	_b.ring_band(r1, r2, c, [&"rock", &"rock_light"])
	_b.ring_cap(r2, c + Vector3(0.0, 6.3, 0.0), Vector3.UP, &"scrub_dry")
	_b.xform = Transform3D(Basis(), Vector3(0.0, 5.0, 0.0))
	_lighthouse_parts()
	_b.xform = Transform3D.IDENTITY
	_save(COAST + "lighthouse_islet.res")


## Sea stacks: a cluster of craggy rock pillars standing in the surf (placed in the
## sea by WaterRibbon: origin at the water level).
func _sea_stacks() -> void:
	var rng := Rng.new(407)
	var spots := [Vector3(0.0, 0.0, 0.0), Vector3(9.0, 0.0, -7.0), Vector3(-7.0, 0.0, 8.0), Vector3(12.0, 0.0, 9.0)]
	var heights := [22.0, 14.0, 9.0, 5.0]
	for i in spots.size():
		var c: Vector3 = spots[i]
		var h: float = heights[i]
		var r := h * 0.28
		var lo := _b.jagged_ring(c, -2.0, r * 1.2, r, 7, 0.2, rng)
		var mid := _b.jagged_ring(c, h * 0.55, r * 0.9, r * 0.75, 7, 0.25, rng, 0.5)
		var hi := _b.jagged_ring(c, h * 0.9, r * 0.6, r * 0.5, 7, 0.25, rng, 0.2)
		_b.ring_band(lo, mid, c, [&"rock_dark", &"rock"])
		_b.ring_band(mid, hi, c, [&"rock", &"rock_light"])
		_b.ring_cap(hi, c + Vector3(rng.float_range(-0.5, 0.5), h, 0.0), Vector3.UP, &"scrub")
	_save(COAST + "sea_stacks.res")


## Stucco beach house with a terracotta hip roof and a porch (land side).
func _coast_house() -> void:
	_b.box(Vector3(0.0, 2.6, 0.0), Vector3(9.0, 5.2, 12.0), &"stucco")
	_b.gable_roof(Vector2(0.0, 0.0), 4.5, 6.0, 5.2, 7.4, &"terracotta", &"stucco", 0.6)
	_b.box(Vector3(-5.3, 1.3, 0.0), Vector3(1.6, 0.2, 8.0), &"timber", &"timber")
	for z: float in [-3.6, 0.0, 3.6]:
		_b.box(Vector3(-5.9, 1.4, z), Vector3(0.2, 2.8, 0.2), &"white")
	_b.box(Vector3(-4.52, 2.8, -2.5), Vector3(0.05, 1.6, 2.0), &"brand_teal")
	_b.box(Vector3(-4.52, 2.8, 2.5), Vector3(0.05, 1.6, 2.0), &"brand_teal")
	_save(COAST + "coast_house.res")


# ================================================================ City

## Facade with floor bands: per face and floor a spandrel strip under a window strip,
## the window strip split into bays (one per ~WINDOW_BAY_M, at most MAX_BAYS), each lit
## by chance, tiling the face exactly (no overlapping faces, no z-fighting). The box
## spans x0..x1, z0..z1, from y0 to y1.
func _facade_box(x0: float, x1: float, z0: float, z1: float, y0: float, y1: float, floors: int,
		wall: StringName, glass: StringName, window_frac: float, lit_chance: float, rng: Rng,
		max_bays: int = MAX_BAYS) -> void:
	var fh := (y1 - y0) / float(floors)
	var faces := [
		[Vector3(x1, 0, z0), Vector3(x1, 0, z1), Vector3.RIGHT],
		[Vector3(x0, 0, z1), Vector3(x0, 0, z0), Vector3.LEFT],
		[Vector3(x1, 0, z1), Vector3(x0, 0, z1), Vector3.BACK],
		[Vector3(x0, 0, z0), Vector3(x1, 0, z0), Vector3.FORWARD],
	]
	for f: Array in faces:
		var a: Vector3 = f[0]
		var b: Vector3 = f[1]
		var n: Vector3 = f[2]
		var bays := clampi(roundi(a.distance_to(b) / WINDOW_BAY_M), 1, max_bays)
		for k in floors:
			var ya := y0 + float(k) * fh
			var ym := ya + fh * (1.0 - window_frac)
			var yb := ya + fh
			_b.quad(a + Vector3(0, ya, 0), b + Vector3(0, ya, 0), b + Vector3(0, ym, 0), a + Vector3(0, ym, 0), n, wall)
			for j in bays:
				var p := a.lerp(b, float(j) / float(bays))
				var q := a.lerp(b, float(j + 1) / float(bays))
				var lit := rng.float_range(0.5, 1.0) if rng.chance(lit_chance) else 0.0
				_b.window_quad(p + Vector3(0, ym, 0), q + Vector3(0, ym, 0), q + Vector3(0, yb, 0),
					p + Vector3(0, yb, 0), n, glass, lit)


## Glass office tower (~58 m) on a concrete podium, with a rooftop plant and a red
## aircraft light.
func _office_tower() -> void:
	var rng := Rng.new(501)
	_b.box(Vector3(0.0, (7.0 - FOOTING_M) * 0.5, 0.0), Vector3(26.0, 7.0 + FOOTING_M, 26.0), &"concrete_dark",
		&"concrete")
	_facade_box(-10.0, 10.0, -10.0, 10.0, 7.0, 58.0, 14, &"concrete_blue", &"glass", 0.62, 0.55, rng)
	_b.quad(Vector3(-10, 58, -10), Vector3(10, 58, -10), Vector3(10, 58, 10), Vector3(-10, 58, 10), Vector3.UP,
		&"concrete_dark")
	_b.box(Vector3(2.0, 60.0, 1.0), Vector3(9.0, 4.0, 8.0), &"steel", &"steel_dark")
	_b.box(Vector3(-6.0, 63.0, -6.0), Vector3(0.6, 10.0, 0.6), &"steel_dark")
	_b.box(Vector3(-6.0, 68.2, -6.0), Vector3(0.7, 0.5, 0.7), &"reflector_red", &"reflector_red", true,
		PropMeshBuilder.EMISSIVE_STREETLAMP)
	_save(CITY + "office_tower.res", {}, true)


## Brick apartment slab (8 floors, 38 x 14 m), rooftop water tank.
func _apartment_block() -> void:
	var rng := Rng.new(502)
	_b.box(Vector3(0.0, -FOOTING_M * 0.5, 0.0), Vector3(14.0, FOOTING_M, 38.0), &"concrete_dark")
	_facade_box(-7.0, 7.0, -19.0, 19.0, 0.0, 28.0, 8, &"brick", &"glass_dark", 0.5, 0.6, rng)
	_b.quad(Vector3(-7, 28, -19), Vector3(7, 28, -19), Vector3(7, 28, 19), Vector3(-7, 28, 19), Vector3.UP,
		&"roof_slate")
	for z: float in [-12.0, 10.0]:
		for p: Vector2 in [Vector2(-1.2, -1.2), Vector2(1.2, -1.2), Vector2(1.2, 1.2), Vector2(-1.2, 1.2)]:
			_b.box(Vector3(p.x, 29.0, z + p.y), Vector3(0.15, 2.0, 0.15), &"steel_dark")
	_b.prism(Vector3(0.0, 30.0, -12.0), 1.9, 1.9, 3.0, 8, &"timber")
	_b.prism(Vector3(0.0, 33.0, -12.0), 2.0, 0.0, 1.2, 8, &"roof_dark")
	_save(CITY + "apartment_block.res", {}, true)


## Low warehouse (52 x 30 x 9 m): corrugated walls, loading doors, a painted stripe,
## rooftop units.
func _warehouse() -> void:
	_b.box(Vector3(0.0, (9.0 - FOOTING_M) * 0.5, 0.0), Vector3(30.0, 9.0 + FOOTING_M, 52.0), &"concrete_blue",
		&"steel")
	_b.box(Vector3(-15.02, 7.2, 0.0), Vector3(0.05, 0.9, 52.0), &"brand_teal")
	for z: float in [-18.0, -9.0, 0.0, 9.0, 18.0]:
		_b.box(Vector3(-15.03, 2.4, z), Vector3(0.05, 4.8, 5.0), &"concrete_dark")
	for p: Vector2 in [Vector2(6.0, -14.0), Vector2(-4.0, 6.0), Vector2(5.0, 16.0)]:
		_b.box(Vector3(p.x, 9.9, p.y), Vector3(4.0, 1.8, 3.0), &"steel", &"steel_dark")
	# A lit sign over the office door.
	_b.box(Vector3(-15.08, 5.6, -22.0), Vector3(0.1, 1.0, 6.0), &"neon_cyan", &"neon_cyan", true,
		PropMeshBuilder.EMISSIVE_STREETLAMP)
	_save(CITY + "warehouse.res")


## Mid-rise office (6 floors, 28 x 28 m) with glass bands and a rooftop neon logo.
func _midrise() -> void:
	var rng := Rng.new(503)
	_b.box(Vector3(0.0, -FOOTING_M * 0.5, 0.0), Vector3(28.0, FOOTING_M, 28.0), &"concrete_dark")
	_facade_box(-14.0, 14.0, -14.0, 14.0, 0.0, 24.0, 6, &"concrete", &"glass", 0.55, 0.5, rng)
	_b.quad(Vector3(-14, 24, -14), Vector3(14, 24, -14), Vector3(14, 24, 14), Vector3(-14, 24, 14), Vector3.UP,
		&"concrete_dark")
	# Rooftop logo facing the road (-X side): a neon ring and a bar on a dark frame.
	_b.box(Vector3(-11.0, 28.0, 0.0), Vector3(0.4, 6.0, 12.0), &"board_dark", &"board_dark")
	_b.xform = Transform3D(Basis(Vector3.UP, -PI * 0.5), Vector3(-11.25, 28.0, 0.0))
	_b.disc(Vector3(-3.0, 0.0, 0.0), Vector3.BACK, 2.2, 10, &"neon_pink", PropMeshBuilder.EMISSIVE_STREETLAMP)
	_b.disc(Vector3(-3.0, 0.0, 0.05), Vector3.BACK, 1.4, 10, &"board_dark")
	_b.quad(Vector3(0.2, 0.6, 0.0), Vector3(5.2, 0.6, 0.0), Vector3(5.2, 1.6, 0.0), Vector3(0.2, 1.6, 0.0),
		Vector3.BACK, &"neon_cyan", PropMeshBuilder.EMISSIVE_STREETLAMP)
	_b.quad(Vector3(0.2, -1.4, 0.0), Vector3(3.8, -1.4, 0.0), Vector3(3.8, -0.6, 0.0), Vector3(0.2, -0.6, 0.0),
		Vector3.BACK, &"white", PropMeshBuilder.EMISSIVE_STREETLAMP)
	_b.xform = Transform3D.IDENTITY
	_save(CITY + "midrise.res", {}, true)


## Tall glass skyscraper (~110 m) with a setback crown and a spire (distant scatter).
func _skyscraper() -> void:
	var rng := Rng.new(504)
	_b.box(Vector3(0.0, -FOOTING_M * 0.5, 0.0), Vector3(30.0, FOOTING_M, 30.0), &"concrete_dark")
	_facade_box(-15.0, 15.0, -15.0, 15.0, 0.0, 78.0, 11, &"glass_dark", &"glass", 0.7, 0.5, rng, 2)
	_b.quad(Vector3(-15, 78, -15), Vector3(15, 78, -15), Vector3(15, 78, 15), Vector3(-15, 78, 15), Vector3.UP,
		&"concrete_dark")
	_facade_box(-10.0, 10.0, -10.0, 10.0, 78.0, 104.0, 4, &"glass_dark", &"glass", 0.7, 0.5, rng, 1)
	_b.prism(Vector3(0.0, 104.0, 0.0), 10.0, 5.0, 4.0, 4, &"concrete_blue", &"concrete_blue", false, 0.5)
	_b.prism(Vector3(0.0, 108.0, 0.0), 0.6, 0.15, 14.0, 4, &"steel")
	_b.box(Vector3(0.0, 122.2, 0.0), Vector3(0.6, 0.6, 0.6), &"reflector_red", &"reflector_red", true,
		PropMeshBuilder.EMISSIVE_STREETLAMP)
	_save(CITY + "skyscraper.res", {}, true)


## Paved plaza tile (unit square; the city field grid keeps crops off, so this is a
## placeholder that its pool needs).
func _plaza_tile() -> void:
	_b.quad(Vector3(-0.5, 0.05, -0.5), Vector3(0.5, 0.05, -0.5), Vector3(0.5, 0.05, 0.5), Vector3(-0.5, 0.05, 0.5),
		Vector3.UP, &"concrete")
	_save(CITY + "plaza_tile.res")


## Street tree in a planter (city block edges); the planter reaches down to the footing.
func _street_tree() -> void:
	_b.box(Vector3(0.0, (0.6 - FOOTING_M) * 0.5, 0.0), Vector3(1.6, 0.6 + FOOTING_M, 1.6), &"concrete", &"soil_dark")
	_b.prism(Vector3(0.0, 0.6, 0.0), 0.2, 0.15, 2.4, 5, &"bark")
	_b.prism(Vector3(0.0, 2.6, 0.0), 1.6, 2.0, 1.4, 7, &"broadleaf", &"broadleaf_light", true)
	_b.prism(Vector3(0.0, 4.0, 0.0), 2.0, 0.6, 1.8, 7, &"broadleaf_light")
	_save(CITY + "street_tree.res")


## Highway sound-wall stretch: a 12 m concrete panel with ribs and posts, on a
## footing that reaches the lowered ground beside elevated stretches.
func _sound_wall() -> void:
	var h := 4.6
	_b.box(Vector3(0.0, (h - FOOTING_M) * 0.5, 0.0), Vector3(0.35, h + FOOTING_M, 12.0), &"concrete_blue",
		&"concrete")
	for z: float in [-6.0, 6.0]:
		_b.box(Vector3(0.0, (h + 0.4 - FOOTING_M) * 0.5, z), Vector3(0.6, h + 0.4 + FOOTING_M, 0.6), &"concrete_dark",
			&"concrete")
	# Ribs on the road face (-X) and a colored band near the top.
	for z: float in [-3.0, 0.0, 3.0]:
		_b.box(Vector3(-0.25, h * 0.5, z), Vector3(0.15, h - 0.6, 0.5), &"concrete")
	_b.box(Vector3(-0.19, h - 0.45, 0.0), Vector3(0.04, 0.35, 11.4), &"brand_teal")
	_save(CITY + "sound_wall.res")


## Neon billboard ("Volt Noodle Bar", an invented brand): a dark board on one tall
## pole, the art as neon tubes (class 2: bright at night, colored bars by day), on
## both faces.
func _neon_board() -> void:
	var y0 := 11.0
	var y1 := 16.0
	var x0 := -6.0
	var x1 := 6.0
	_b.box(Vector3(0.0, (y0 - FOOTING_M) * 0.5, 0.0), Vector3(0.6, y0 + FOOTING_M, 0.6), &"steel_dark")
	_b.box(Vector3(0.0, (y0 + y1) * 0.5, 0.0), Vector3(x1 - x0, y1 - y0, 0.4), &"board_dark", &"board_dark", true)
	for s: float in [1.0, -1.0]:
		var z := s * (0.2 + TUBE_RELIEF)
		var n := Vector3(0.0, 0.0, s)
		# Frame tubes.
		_tube_rect(s, x0 + 0.3, y0 + 0.3, x1 - 0.3, y1 - 0.3, z, n, &"neon_cyan")
		# A bowl: arc of tube segments, with steam "zigzags".
		var cx := -3.4 * s
		var cy := y0 + 2.2
		for i in 6:
			var a0 := PI + PI * float(i) / 6.0
			var a1 := PI + PI * float(i + 1) / 6.0
			var p0 := Vector3(cx + cos(a0) * 1.6 * s, cy - sin(a0) * -1.3 - 0.0, z)
			var p1 := Vector3(cx + cos(a1) * 1.6 * s, cy - sin(a1) * -1.3 - 0.0, z)
			_tube(p0, p1, n, &"neon_pink")
		_tube(Vector3(cx - 1.7 * s, cy, z), Vector3(cx + 1.7 * s, cy, z), n, &"neon_pink")
		for k in 3:
			var sx := cx + (float(k) - 1.0) * 0.7 * s
			_tube(Vector3(sx, cy + 0.4, z), Vector3(sx + 0.3 * s, cy + 1.0, z), n, &"white")
			_tube(Vector3(sx + 0.3 * s, cy + 1.0, z), Vector3(sx, cy + 1.6, z), n, &"white")
		# "Lettering": two bars and a lightning bolt.
		_tube(Vector3(-0.8 * s, y1 - 1.3, z), Vector3(4.8 * s, y1 - 1.3, z), n, &"neon_lime")
		_tube(Vector3(-0.8 * s, y1 - 2.4, z), Vector3(3.2 * s, y1 - 2.4, z), n, &"neon_cyan")
		_tube(Vector3(4.2 * s, y0 + 2.8, z), Vector3(3.6 * s, y0 + 1.6, z), n, &"neon_violet")
		_tube(Vector3(3.6 * s, y0 + 1.6, z), Vector3(4.4 * s, y0 + 1.6, z), n, &"neon_violet")
		_tube(Vector3(4.4 * s, y0 + 1.6, z), Vector3(3.8 * s, y0 + 0.5, z), n, &"neon_violet")
	_save(CITY + "neon_board.res")


## Vertical blade sign ("Starline Motel", invented): tall narrow sign on a pole, a
## stack of neon "letters", an arrow with a chaser row, both faces.
func _neon_blade() -> void:
	var y0 := 6.0
	var y1 := 19.0
	_b.box(Vector3(0.0, (y0 - FOOTING_M) * 0.5, 0.0), Vector3(0.5, y0 + FOOTING_M, 0.5), &"steel_dark")
	_b.box(Vector3(0.0, (y0 + y1) * 0.5, 0.0), Vector3(3.2, y1 - y0, 0.5), &"board_dark", &"brand_navy", true)
	for s: float in [1.0, -1.0]:
		var z := s * (0.25 + TUBE_RELIEF)
		var n := Vector3(0.0, 0.0, s)
		_tube_rect(s, -1.4, y0 + 0.2, 1.4, y1 - 0.2, z, n, &"neon_violet")
		for k in 6:
			var yc := y1 - 1.4 - float(k) * 1.8
			var col: StringName = &"neon_pink" if k % 2 == 0 else &"hazard_yellow"
			_tube(Vector3(-0.7 * s, yc, z), Vector3(0.7 * s, yc, z), n, col)
			_tube(Vector3(-0.7 * s, yc - 0.9, z), Vector3(-0.7 * s, yc, z), n, col)
	# Arrow pointing down to the (imagined) motel, hanging on the road side.
	for s: float in [1.0, -1.0]:
		var z := s * (0.25 + TUBE_RELIEF)
		_b.face(PackedVector3Array([Vector3(-1.6, y0 + 0.6, z), Vector3(-3.6, y0 + 1.6, z), Vector3(-3.6, y0 - 0.4, z)]),
			Vector3(0.0, 0.0, s), &"neon_cyan", PropMeshBuilder.EMISSIVE_STREETLAMP)
	_save(CITY + "neon_blade.res")


## A neon tube from a to b in the plane facing n (a flat emissive strip).
func _tube(a: Vector3, b: Vector3, n: Vector3, col: StringName) -> void:
	var along := (b - a).normalized()
	var w := along.cross(n).normalized() * (TUBE_M * 0.5)
	_b.quad(a - w, b - w, b + w, a + w, n, col, PropMeshBuilder.EMISSIVE_STREETLAMP)


func _tube_rect(s: float, x0: float, y0: float, x1: float, y1: float, z: float, n: Vector3, col: StringName) -> void:
	var a := Vector3(x0 * s, y0, z)
	var b := Vector3(x1 * s, y0, z)
	var c := Vector3(x1 * s, y1, z)
	var d := Vector3(x0 * s, y1, z)
	_tube(a, b, n, col)
	_tube(b, c, n, col)
	_tube(c, d, n, col)
	_tube(d, a, n, col)


# ================================================================ Valley

## Spruce: short trunk, three overlapping cones (the valley forest silhouette). Light
## (forests are dense): about 40 triangles.
func _conifer() -> void:
	_b.prism(Vector3.ZERO, 0.28, 0.2, 1.6, 4, &"bark", &"bark")
	_b.prism(Vector3(0.0, 1.2, 0.0), 2.7, 0.0, 5.2, 6, &"conifer_dark", &"", true)
	_b.prism(Vector3(0.0, 3.8, 0.0), 2.1, 0.0, 4.6, 6, &"conifer", &"", true, 0.0)
	_b.prism(Vector3(0.0, 6.6, 0.0), 1.4, 0.0, 4.4, 6, &"conifer", &"", true, 0.5)
	_save(VALLEY + "conifer.res")


## Broadleaf (maple/oak): a lumpy two-tier crown, about 60 triangles.
func _broadleaf() -> void:
	_b.prism(Vector3.ZERO, 0.38, 0.26, 2.8, 4, &"bark", &"bark")
	_b.prism(Vector3(0.0, 2.4, 0.0), 2.3, 3.4, 2.0, 7, &"broadleaf", &"broadleaf", true)
	_b.prism(Vector3(0.0, 4.4, 0.0), 3.4, 0.0, 3.6, 7, &"broadleaf_light", &"", false, 0.2)
	_b.prism(Vector3(1.3, 3.4, 1.0), 1.5, 0.0, 2.8, 5, &"broadleaf", &"", false, 0.1)
	_save(VALLEY + "broadleaf.res")


## A copse of `count` trees in a ~26 m patch (one instance = a piece of forest, so
## scattered clumps make woods cheaply). `broadleaf_share` of them are broadleaf.
func _clump(id: StringName, count: int, broadleaf_share: float, seed_value: int) -> void:
	var rng := Rng.new(seed_value)
	for i in count:
		var a := TAU * (float(i) + rng.float_range(-0.3, 0.3)) / float(count)
		var r := rng.float_range(2.0, 12.0) if i > 0 else 0.0
		var p := Vector3(cos(a) * r, 0.0, sin(a) * r)
		var k := rng.float_range(0.75, 1.5)
		if rng.chance(broadleaf_share):
			_b.prism(p, 0.3 * k, 0.2 * k, 2.4 * k, 4, &"bark", &"bark")
			_b.prism(p + Vector3(0.0, 2.2 * k, 0.0), 2.6 * k, 0.0, 4.6 * k, 6, &"broadleaf_light" if i % 2 == 0 else &"broadleaf",
				&"", true, rng.unit())
		else:
			_b.prism(p + Vector3(0.0, 0.8 * k, 0.0), 2.4 * k, 0.0, 5.0 * k, 6, &"conifer_dark", &"", true, rng.unit())
			_b.prism(p + Vector3(0.0, 3.6 * k, 0.0), 1.7 * k, 0.0, 5.2 * k, 6, &"conifer" if i % 3 != 0 else &"conifer_dark",
				&"", false, rng.unit())
	_save(VALLEY + String(id) + ".res")


## Meadow tile (unit square, low), rows along z like the farmland crops.
func _meadow(id: StringName, height: float, stripes: int, tops: Array, side: StringName) -> void:
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
	_save(VALLEY + String(id) + ".res")


## Valley farmhouse: timber-and-cream house with a steep dark roof, a porch, a
## woodpile and two spruces.
func _valley_farm() -> void:
	_b.box(Vector3(0.0, 1.6, 0.0), Vector3(9.0, 3.2, 12.0), &"cream")
	_b.box(Vector3(0.0, 4.3, 0.0), Vector3(9.0, 2.2, 12.0), &"timber")
	_b.gable_roof(Vector2(0.0, 0.0), 4.5, 6.0, 5.4, 10.2, &"roof_dark", &"timber", 0.8)
	_b.box(Vector3(-5.6, 1.2, 0.0), Vector3(2.2, 0.2, 9.0), &"timber", &"timber")
	_b.box(Vector3(2.0, 10.0, 3.0), Vector3(0.8, 2.2, 0.8), &"brick")
	_b.box(Vector3(3.5, 0.6, -8.0), Vector3(4.0, 1.2, 1.4), &"bark", &"timber")
	for p: Vector3 in [Vector3(-7.0, 0.0, -9.0), Vector3(6.0, 0.0, 9.5)]:
		_b.prism(p, 0.25, 0.18, 1.2, 5, &"bark")
		_b.prism(p + Vector3(0.0, 1.0, 0.0), 2.2, 0.0, 7.5, 7, &"conifer")
	_save(VALLEY + "valley_farm.res")


## Red barn with a hay loft door and round hay bales.
func _valley_barn() -> void:
	_b.box(Vector3(0.0, 3.2, 0.0), Vector3(12.0, 6.4, 16.0), &"barn_red")
	_b.gable_roof(Vector2(0.0, 0.0), 6.0, 8.0, 6.4, 11.0, &"roof_dark", &"barn_red", 0.5)
	_b.box(Vector3(0.0, 2.4, 8.05), Vector3(4.4, 4.8, 0.1), &"cream")
	_b.box(Vector3(0.0, 2.4, 8.15), Vector3(3.6, 4.0, 0.1), &"barn_red")
	_b.box(Vector3(0.0, 8.0, 8.05), Vector3(2.0, 1.8, 0.1), &"timber")
	for p: Vector2 in [Vector2(-9.0, -4.0), Vector2(-9.5, 0.5), Vector2(-8.5, 5.0)]:
		_b.tube(Vector3(p.x, 0.8, p.y - 0.7), Vector3(p.x, 0.8, p.y + 0.7), 0.8, 0.8, 7, &"straw")
	_save(VALLEY + "valley_barn.res")


## Post-and-three-rail timber fence, 10 m along -Z (length_m meta).
func _fence_rail() -> void:
	var length := 10.0
	_b.box(Vector3(0.0, 0.6, 0.0), Vector3(0.16, 1.2, 0.16), &"timber")
	for y: float in [0.35, 0.7, 1.05]:
		_b.beam(Vector3(0.0, y, 0.0), Vector3(0.0, y, -length), 0.08, &"bark", false)
	_save(VALLEY + "fence_rail.res", {"length_m": length})
