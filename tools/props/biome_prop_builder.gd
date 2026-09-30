class_name BiomePropBuilder
extends PropMeshBuilder
## PropMeshBuilder plus what the coast, city and valley props need (WP6.4b): the
## style-guide palette extended with the biome colors (tools/props/palette_biomes_4_6.tres),
## single triangles and jagged rock rings, and lit-window faces for the city's
## world_windows material. Spec: World → Biomes, Art pipeline (palette, flat shading).
##
## Windows: `window_quad` writes emissive class 4 (world_windows.gdshader) with UV2.y =
## the room brightness at night (0 = never lit). Meshes that use it are committed with
## `commit_windows()` (material assets/shaders/materials/world_windows.tres).

const EXTRA_PALETTE := "res://tools/props/palette_biomes_4_6.tres"
const WINDOWS_MATERIAL := "res://assets/shaders/materials/world_windows.tres"
const EMISSIVE_WINDOW := 4


## The style-guide palette followed by the biome colors (names must not repeat).
static func merged_palette() -> WBPalette:
	var base := WBPalette.load_default()
	var extra := load(EXTRA_PALETTE) as WBPalette
	var p := WBPalette.new()
	p.names = base.names.duplicate()
	p.colors = base.colors.duplicate()
	for i in extra.names.size():
		if p.names.has(extra.names[i]):
			push_error("BiomePropBuilder: palette name %s repeats" % extra.names[i])
			continue
		p.names.append(extra.names[i])
		p.colors.append(extra.colors[i])
	return p


func _init(p: WBPalette = null) -> void:
	super(p if p != null else merged_palette())


## One triangle facing `outward`.
func tri(a: Vector3, b: Vector3, c: Vector3, outward: Vector3, color_name: StringName,
		emissive: int = EMISSIVE_NONE) -> void:
	face(PackedVector3Array([a, b, c]), outward, color_name, emissive)


## Side band between two rings of equal size (closed loops around `center`), as
## triangles (rings need not be planar). Colors cycle per segment.
func ring_band(lo: PackedVector3Array, hi: PackedVector3Array, center: Vector3, colors: Array) -> void:
	var n := lo.size()
	for i in n:
		var j := (i + 1) % n
		var col: StringName = colors[i % colors.size()]
		var mid := (lo[i] + lo[j] + hi[i] + hi[j]) * 0.25
		var out := mid - center
		out.y = 0.0
		tri(lo[i], lo[j], hi[j], out, col)
		tri(lo[i], hi[j], hi[i], out, col)


## Cap a ring with a fan from its centroid (optionally raised to `apex`).
func ring_cap(ring: PackedVector3Array, apex: Vector3, outward: Vector3, color_name: StringName) -> void:
	var n := ring.size()
	for i in n:
		tri(ring[i], ring[(i + 1) % n], apex, outward, color_name)


## A jagged ring of `n` points around `center` at height y: radii rx (x) and rz (z),
## each point's radius jittered by +-jitter (fraction) from `rng`.
func jagged_ring(center: Vector3, y: float, rx: float, rz: float, n: int, jitter: float, rng: Rng,
		phase: float = 0.0) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in n:
		var a := TAU * (float(i) + phase) / float(n)
		var k := 1.0 + rng.float_range(-jitter, jitter)
		out.append(center + Vector3(cos(a) * rx * k, y, sin(a) * rz * k))
	return out


## A window face: glass by day, lit at night with brightness `lit` (0 = dark room).
func window_quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, outward: Vector3, glass: StringName,
		lit: float) -> void:
	var start := _uv2.size()
	quad(a, b, c, d, outward, glass, EMISSIVE_WINDOW)
	for i in range(start, _uv2.size()):
		_uv2[i] = Vector2(float(EMISSIVE_WINDOW), lit)


## commit() with the lit-window material.
func commit_windows(meta: Dictionary = {}) -> ArrayMesh:
	var mesh := commit(meta)
	mesh.surface_set_material(0, load(WINDOWS_MATERIAL))
	return mesh
