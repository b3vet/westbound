class_name BiomeDirector
extends Node
## Which biome is where, and the look blending between them. Spec: World → Biomes
## ("Each leg is one biome. Default order ...; forks swap the next biome"; "every
## biome must look good across the whole color script"; tint offsets, horizon
## silhouette set, lane count), Color script ("Biomes can add tint offsets"), Sky
## (horizon silhouette cards), Core loop → Legs and checkpoints, The journey goal.
## docs/BIOMES.md.
##
## World-system node (docs/CONTRACTS.md §13): `setup(ctx, road, origin)`, then
## `update_view(focus_s)` once per frame.
##
## - **Plan:** a BiomePlan (leg -> BiomeDef), by default the journey from
##   LegsTuning.leg_biome_ids / endless_biome_id. At setup it is handed to a
##   ProceduralRoadPath (set_biome_plan), which latches each leg's road rules (lane
##   count, curve / crest / tunnel frequency). Forks: `plan_next(leg, biome)`.
## - **Boundaries:** the next leg's biome takes over at the checkpoint line: props swap
##   there (Roadside fills each cell from `biome_at`); ground, verge and rock colours
##   (RoadBuilder, per mesh row) and the world / fog tint offsets blend over
##   LegsTuning.biome_blend_before_m / _after_m around the line; the horizon
##   silhouettes crossfade over horizon_blend_before_m / _after_m.
## - **Events:** `Events.biome_changed(id)` once at setup and whenever the focus
##   crosses into a different biome.
## - **Sky:** pushes the blended tint offsets, horizon sets and heat shimmer to the
##   SkyRig (`sky`, else the one in SkyRig.GROUP) when they change.
##
## Checkpoint landmark styles (WP5.5, CONTRACTS §3: "the biome director fills the
## CHECKPOINT tag"): `checkpoint_style(leg, s)` is the style of the biome whose leg ends
## at s (BiomeDef.checkpoint_style, seeded from the run's props stream), and
## `tag_checkpoints(features)` writes it into the untagged CHECKPOINT features a
## consumer got from RoadPath.features_in (Landmarks, LandmarkClearance). The road
## creates its features per query, so every consumer tags its own copies.

const DEFAULT_BIOME_PATH := "res://data/biomes/farmland.tres"
## World systems that need the director but are not handed one (StreetLampPools)
## find it in this group.
const GROUP := &"wb_biome_director"
## Props sub-stream that seeds the per-biome landmark style cycle.
const STYLE_STREAM := &"landmark_styles"
## The biome of the leg ending at a checkpoint is the one just before the line.
const LEG_END_EPS_M := 0.5   # lint: allow-number tolerance on the checkpoint position, not tuning

## The plan to use; null at setup = the journey from tuning (or `default_biome`
## everywhere when `journey` is false).
var plan: BiomePlan
## false: one biome (`default_biome`) everywhere (previews, isolated tests).
var journey: bool = true
## The biome for a uniform plan (loaded from DEFAULT_BIOME_PATH when left null).
var default_biome: BiomeDef
## Hand the plan to a ProceduralRoadPath at setup (its lanes, curves and tunnels).
var apply_to_road: bool = true
## Receives the blended look (null: the SkyRig in SkyRig.GROUP, found at setup).
var sky: SkyRig

## Moves whenever the plan changes (setup, forks): caches of biome-derived data
## (LandmarkClearance, RoadBuilder colours) refill when it moves.
var plan_version: int = 0

var _current: BiomeDef
var _style_seed: int = 0
var _seen_plan_version: int = -1
var _blend_before: float = 0.0
var _blend_after: float = 0.0
var _horizon_before: float = 0.0
var _horizon_after: float = 0.0
var _blend := BiomePlan.Blend.new()
var _hblend := BiomePlan.Blend.new()
# The look last pushed to the sky.
var _pushed_tint := Color(INF, INF, INF, INF)
var _pushed_fog := Color(INF, INF, INF, INF)
var _pushed_h_from: BiomeDef
var _pushed_h_to: BiomeDef
var _pushed_h_t: float = -1.0
var _pushed_shimmer: float = -1.0


func _enter_tree() -> void:
	add_to_group(GROUP)


func setup(ctx: RunContext, road: RoadPath, _origin: FloatingOrigin) -> void:
	if default_biome == null:
		default_biome = load(DEFAULT_BIOME_PATH) as BiomeDef
	var legs: LegsTuning = ctx.tuning.legs if ctx != null else Tuning.load_default().legs
	if plan == null:
		plan = BiomePlan.from_tuning(legs) if journey else BiomePlan.uniform(default_biome, legs.leg_length_m())
	_blend_before = legs.biome_blend_before_m
	_blend_after = legs.biome_blend_after_m
	_horizon_before = legs.horizon_blend_before_m
	_horizon_after = legs.horizon_blend_after_m
	_style_seed = ctx.rng_props.derive(STYLE_STREAM).get_seed() if ctx != null else 0
	if apply_to_road and road is ProceduralRoadPath:
		(road as ProceduralRoadPath).set_biome_plan(plan)
	if sky == null and is_inside_tree():
		sky = get_tree().get_first_node_in_group(SkyRig.GROUP) as SkyRig
	plan_version += 1
	_seen_plan_version = plan.version
	_pushed_tint = Color(INF, INF, INF, INF)
	_pushed_fog = Color(INF, INF, INF, INF)
	_pushed_h_from = null
	_pushed_h_to = null
	_pushed_h_t = -1.0
	_pushed_shimmer = -1.0
	_current = null
	_set_current(biome_at(0.0))
	_push_look(0.0)


func update_view(focus_s: float) -> void:
	if plan == null:
		return
	if plan.version != _seen_plan_version:
		_seen_plan_version = plan.version
		plan_version += 1
	var b := biome_at(focus_s)
	if b != _current:
		_set_current(b)
	_push_look(focus_s)


## The biome of the leg containing s (the next leg's from its checkpoint line on).
func biome_at(s: float) -> BiomeDef:
	if plan == null:
		return default_biome
	var b := plan.biome_at(s)
	return b if b != null else default_biome


func current() -> BiomeDef:
	return _current


## Forks: leg `leg` (1-based) becomes `biome` ("forks swap the next biome"). Its road
## rules only change if the road has not latched that leg yet (BiomeRoadRules).
func plan_next(leg: int, biome: BiomeDef) -> void:
	if plan == null:
		return
	plan.plan_next(leg, biome)
	plan_version += 1
	_seen_plan_version = plan.version


## Every leg from `leg` on becomes `biome` (a fork onto another route; tests).
func set_biome_from_leg(leg: int, biome: BiomeDef) -> void:
	if plan == null:
		return
	plan.set_biome_from_leg(leg, biome)
	plan_version += 1
	_seen_plan_version = plan.version


## The landmark style of the checkpoint at `checkpoint_s` ending leg `leg_index`: the
## style of the biome whose leg ends there ("" without a biome). Deterministic by seed.
func checkpoint_style(leg_index: int, checkpoint_s: float) -> StringName:
	var b := biome_at(checkpoint_s - LEG_END_EPS_M)
	return b.checkpoint_style(leg_index, _style_seed) if b != null else &""


## Fills the tag (landmark style) of every untagged CHECKPOINT feature in `features`.
## Director rate (a consumer's feature query).
func tag_checkpoints(features: Array[RoadFeature]) -> void:
	for f in features:
		if f.kind == RoadFeature.Kind.CHECKPOINT and f.tag == &"":
			f.tag = checkpoint_style(int(f.value), f.s_start)


## Every biome the run may show (roadside builds prop layers for each at setup).
func biomes() -> Array[BiomeDef]:
	if plan == null:
		var one: Array[BiomeDef] = [default_biome]
		return one
	return plan.catalog()


# ---------------------------------------------------------------- Blended look (director rate)

## Blend state of the ground look at s (from, to, t). Allocation-free; the object is
## reused, read it before the next call.
func look_blend_at(s: float) -> BiomePlan.Blend:
	if plan == null:
		_blend.from = default_biome
		_blend.to = default_biome
		_blend.t = 0.0
	else:
		plan.blend_into(s, _blend_before, _blend_after, _blend)
	return _blend


func verge_color_at(s: float) -> Color:
	var b := look_blend_at(s)
	return b.from.verge_color.lerp(b.to.verge_color, b.t)


func ground_color_at(s: float) -> Color:
	var b := look_blend_at(s)
	return b.from.ground_color.lerp(b.to.ground_color, b.t)


func rock_color_at(s: float) -> Color:
	var b := look_blend_at(s)
	return b.from.rock_color.lerp(b.to.rock_color, b.t)


func rock_shade_color_at(s: float) -> Color:
	var b := look_blend_at(s)
	return b.from.rock_shade_color.lerp(b.to.rock_shade_color, b.t)


## World tint offset (linear RGB, added to world albedo) at s.
func world_tint_at(s: float) -> Color:
	var b := look_blend_at(s)
	return b.from.world_tint_offset.lerp(b.to.world_tint_offset, b.t)


## Fog tint offset (sRGB, added to the fog colour) at s.
func fog_tint_at(s: float) -> Color:
	var b := look_blend_at(s)
	return b.from.fog_tint_offset.lerp(b.to.fog_tint_offset, b.t)


## Horizon crossfade at s: from, to and t over the horizon blend distances.
func horizon_blend_at(s: float) -> BiomePlan.Blend:
	if plan == null:
		_hblend.from = default_biome
		_hblend.to = default_biome
		_hblend.t = 0.0
	else:
		plan.blend_into(s, _horizon_before, _horizon_after, _hblend)
	return _hblend


# ---------------------------------------------------------------- Internals

func _set_current(b: BiomeDef) -> void:
	_current = b
	if b != null:
		Events.biome_changed.emit(b.id)


## Pushes the blended look at s to the sky, only what changed.
func _push_look(s: float) -> void:
	if sky == null or not is_instance_valid(sky):
		return
	var tint := world_tint_at(s)
	var fog := fog_tint_at(s)
	if tint != _pushed_tint:
		_pushed_tint = tint
		sky.set_biome_tint_offset(Vector3(tint.r, tint.g, tint.b))
	if fog != _pushed_fog:
		_pushed_fog = fog
		sky.set_fog_tint_offset(fog)
	var h := horizon_blend_at(s)
	if h.from != _pushed_h_from or h.to != _pushed_h_to or h.t != _pushed_h_t:
		_pushed_h_from = h.from
		_pushed_h_to = h.to
		_pushed_h_t = h.t
		sky.set_horizon_blend(h.from.horizon_layer_style, h.from.horizon_layer_height_m,
			h.to.horizon_layer_style, h.to.horizon_layer_height_m, h.t)
		var shimmer := lerpf(h.from.heat_shimmer, h.to.heat_shimmer, h.t)
		if shimmer != _pushed_shimmer:
			_pushed_shimmer = shimmer
			sky.set_heat_shimmer(shimmer)
