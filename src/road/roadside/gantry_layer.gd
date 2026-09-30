class_name GantryLayer
extends RoadsideLayer
## Occasional overhead sign gantries, one carriageway each (the opposite one is
## its own gantry, mirrored). Spec: World → Road (roadside rhythm: sign
## gantries). At most one per cell per carriageway, with chance
## cell / mean spacing, placed midway between two light poles so the two never
## collide. The mesh spans the median (x = 0) to beyond the guardrail (meta
## `span_m`) and is stretched in x to the local carriageway width.

const SALT_RIGHT := 1
const SALT_LEFT := 2

var _span_m: float = 1.0
var _chance: float = 0.0
var _pole_spacing_m: float = 1.0


func _init(context: RoadsideContext, mesh: Mesh) -> void:
	var t := context.tuning
	super(context, &"sign_gantry", t.sign_gantry_cell_length_m)
	_span_m = float(mesh.get_meta(&"span_m", 1.0))
	_chance = clampf(t.sign_gantry_cell_length_m / t.sign_gantry_mean_spacing_m, 0.0, 1.0)
	_pole_spacing_m = t.light_pole_spacing_m
	add_pool(mesh, 2)


func _emit(c: int) -> void:
	_side(c, SALT_RIGHT, 0.0)
	_side(c, SALT_LEFT, PI)


## yaw 0 = the player's carriageway; PI = the opposite one (mirrored through d = 0).
func _side(c: int, salt: int, yaw: float) -> void:
	ctx.seed_cell(_seed, c, salt)
	if not ctx.rng.chance(_chance):
		return
	var s0 := float(c) * cell_length_m
	var poles := int(floor(cell_length_m / _pole_spacing_m))
	var k := ctx.rng.int_range(0, maxi(poles - 1, 0))
	var s := s0 + (float(k) + 0.5) * _pole_spacing_m
	_sample(s)
	var span := ctx.road.guardrail_d(s) + ctx.tuning.sign_gantry_upright_offset_m
	_place(0, 0.0, yaw, span / _span_m)
