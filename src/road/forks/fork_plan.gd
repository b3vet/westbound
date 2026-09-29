class_name ForkPlan
extends RefCounted
# lint: sim
## Which checkpoints fork and where each branch leads (WP6.5). Spec: Core loop → Legs
## and checkpoints → Forks ("Some checkpoints split the road OutRun-style into two
## branches leading to different biomes"), The journey goal (the coast after 8 legs),
## Modes at launch (Daily Drive: the same route and forks for everyone that day).
## docs/FORKS.md.
##
## Pure data from the run seed (ctx.rng_road.derive(STREAM)) and LegsTuning:
##
##   var forks := ForkPlan.build(ctx.tuning.legs, ctx.rng_road.derive(ForkPlan.STREAM))
##   forks.route(choices)           # leg -> biome id for the journey's legs_to_coast legs
##   forks.left_id(i, choices)      # the biomes fork i offers (&"" if it offers none)
##
## The journey is the stage sequence of LegsTuning.leg_biome_ids (farmland, desert,
## canyon, city, valley fog: consecutive equal ids form one stage, their count its
## default length), then the coast. A fork at checkpoint c picks leg c + 1 from the only
## two real alternatives: STAY in the stage of leg c, or ADVANCE to the next stage (a
## skip ahead). Every later stage keeps its default length and the chosen stage takes
## the rest, so the journey stays legs_to_coast legs, visits the stages in order and
## never skips one; a fork with only one feasible option is not a fork on that route.
## The LEFT branch goes on as the route planned (the default journey, or the route an
## earlier fork set), the RIGHT branch takes the other option, so a journey with every
## fork unresolved is exactly LegsTuning's default plan.
##
## choices[i]: LEFT (-1), RIGHT (+1) or UNRESOLVED (0, routed as LEFT: the main road
## always follows the left branch until the player picks, docs/FORKS.md).

const STREAM := &"forks"
const LEFT := -1
const RIGHT := 1
const UNRESOLVED := 0

var legs_to_coast: int = 0
## Fork checkpoints (the fork at checkpoint c picks leg c + 1), increasing.
var checkpoints := PackedInt32Array()
## The stages in journey order and their default lengths in legs.
var stage_ids: Array[StringName] = []
var stage_legs := PackedInt32Array()
var endless_id: StringName = &""


## The run's forks: fork_count_min..max checkpoints (seeded) among those where both
## options exist on the default journey, at least fork_min_spacing_legs apart.
static func build(legs: LegsTuning, rng: Rng) -> ForkPlan:
	var p := ForkPlan.new()
	p.legs_to_coast = legs.legs_to_coast
	p.endless_id = legs.endless_biome_id
	for id in legs.leg_biome_ids:
		if p.stage_ids.is_empty() or p.stage_ids[p.stage_ids.size() - 1] != id:
			p.stage_ids.append(id)
			p.stage_legs.append(1)
		else:
			p.stage_legs[p.stage_legs.size() - 1] += 1
	var base := p._default_stages()
	var open := PackedInt32Array()
	for c in range(maxi(legs.fork_first_checkpoint, 1), p.legs_to_coast):
		if p._options(base, c).size() == 2:
			open.append(c)
	var want := rng.int_range(mini(legs.fork_count_min, legs.fork_count_max), legs.fork_count_max)
	var spacing := maxi(legs.fork_min_spacing_legs, 1)
	var picked := PackedInt32Array()
	for i in want:
		if open.is_empty():
			break
		var c := open[rng.int_range(0, open.size() - 1)]
		picked.append(c)
		var keep := PackedInt32Array()
		for o in open:
			if absi(o - c) >= spacing:
				keep.append(o)
		open = keep
	picked.sort()
	for c in picked:
		p.checkpoints.append(c)
	return p


## No forks (tests, previews, a plain journey).
static func none(legs: LegsTuning) -> ForkPlan:
	var p := ForkPlan.new()
	p.legs_to_coast = legs.legs_to_coast
	p.endless_id = legs.endless_biome_id
	for id in legs.leg_biome_ids:
		if p.stage_ids.is_empty() or p.stage_ids[p.stage_ids.size() - 1] != id:
			p.stage_ids.append(id)
			p.stage_legs.append(1)
		else:
			p.stage_legs[p.stage_legs.size() - 1] += 1
	return p


func count() -> int:
	return checkpoints.size()


## Index of the fork at checkpoint c, or -1.
func index_at_checkpoint(c: int) -> int:
	for i in checkpoints.size():
		if checkpoints[i] == c:
			return i
	return -1


## Leg -> biome id (legs_to_coast of them; later legs are endless_id) on the route of
## `choices` (missing entries are UNRESOLVED).
func route(choices: PackedInt32Array) -> Array[StringName]:
	var st := _stages_for(choices, checkpoints.size())
	var out: Array[StringName] = []
	for leg in legs_to_coast:
		out.append(stage_ids[st[leg]])
	return out


## The look of the route while forks are pending: like route(), but the leg after each
## unresolved fork keeps the biome of the leg before it (nothing hints at a branch
## before the player picks one).
func look_route(choices: PackedInt32Array) -> Array[StringName]:
	var ids := route(choices)
	for i in checkpoints.size():
		var c := checkpoints[i]
		if _choice(choices, i) == UNRESOLVED and is_real(i, choices) and c < legs_to_coast:
			ids[c] = ids[c - 1]
	return ids


## True when fork i offers two biomes on the route of the earlier choices.
func is_real(i: int, choices: PackedInt32Array) -> bool:
	if i < 0 or i >= checkpoints.size():
		return false
	return _options(_stages_for(choices, i), checkpoints[i]).size() == 2


## The biome fork i's left (right) branch leads to, or &"" when fork i offers no choice.
func left_id(i: int, choices: PackedInt32Array) -> StringName:
	return _side_id(i, choices, LEFT)


func right_id(i: int, choices: PackedInt32Array) -> StringName:
	return _side_id(i, choices, RIGHT)


## `choices` with fork i set to `side` (the rest copied).
func with_choice(choices: PackedInt32Array, i: int, side: int) -> PackedInt32Array:
	var out := choices.duplicate()
	while out.size() < checkpoints.size():
		out.append(UNRESOLVED)
	out[i] = side
	return out


## Mixes the plan into `h` (determinism tests).
func hash_into(h: int) -> int:
	h = TraceHash.mix_int(h, checkpoints.size())
	for i in checkpoints.size():
		h = TraceHash.mix_int(h, checkpoints[i])
	return h


# ---------------------------------------------------------------- Internals

func _choice(choices: PackedInt32Array, i: int) -> int:
	return choices[i] if i < choices.size() else UNRESOLVED


func _side_id(i: int, choices: PackedInt32Array, side: int) -> StringName:
	if i < 0 or i >= checkpoints.size():
		return &""
	var st := _stages_for(choices, i)
	var c := checkpoints[i]
	var opts := _options(st, c)
	if opts.size() != 2:
		return &""
	var planned := st[c]
	var other := opts[1] if planned == opts[0] else opts[0]
	return stage_ids[planned if side == LEFT else other]


## Stage index per leg (0-based legs) on the default journey.
func _default_stages() -> PackedInt32Array:
	var st := PackedInt32Array()
	for j in stage_ids.size():
		for n in stage_legs[j]:
			st.append(j)
	while st.size() < legs_to_coast:
		st.append(stage_ids.size() - 1)
	st.resize(legs_to_coast)
	return st


## Stage per leg after resolving the first `upto` forks as `choices` says.
func _stages_for(choices: PackedInt32Array, upto: int) -> PackedInt32Array:
	var st := _default_stages()
	for i in mini(upto, checkpoints.size()):
		var c := checkpoints[i]
		var opts := _options(st, c)
		if opts.size() != 2 or _choice(choices, i) != RIGHT:
			continue
		var planned := st[c]
		_refill(st, c, opts[1] if planned == opts[0] else opts[0])
	return st


## [stay, advance] stage indices at checkpoint c when both keep the journey feasible
## (every later stage still gets a leg), else fewer.
func _options(st: PackedInt32Array, c: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if c < 1 or c >= legs_to_coast:
		return out
	var cur := st[c - 1]
	var n_stages := stage_ids.size()
	var left_after := legs_to_coast - (c + 1)
	if n_stages - 1 - cur <= left_after:
		out.append(cur)
	if cur + 1 < n_stages and n_stages - 2 - cur <= left_after:
		out.append(cur + 1)
	return out


## Legs c + 1 .. legs_to_coast: stage j first, every later stage its default length,
## stage j the rest (later stages shrink from the back, never below one leg).
func _refill(st: PackedInt32Array, c: int, j: int) -> void:
	var n_stages := stage_ids.size()
	var lens := PackedInt32Array()
	lens.resize(n_stages)
	var rest := legs_to_coast - c
	var later := 0
	for k in range(j + 1, n_stages):
		lens[k] = stage_legs[k]
		later += stage_legs[k]
	var k := n_stages - 1
	while later > rest - 1 and k > j:
		if lens[k] > 1:
			lens[k] -= 1
			later -= 1
		else:
			k -= 1
	lens[j] = rest - later
	var leg := c
	for s in range(j, n_stages):
		for n in lens[s]:
			if leg < legs_to_coast:
				st[leg] = s
				leg += 1
