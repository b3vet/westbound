extends Node
## Quality tiers and frame pacing (autoload `Quality`). Spec: Performance budget
## (frame rate, render resolution, anti-aliasing, view distance, quality tiers,
## adaptive governor).
##
## Two parts:
##   - `compute(...)` (static, pure): user tier + governor rung + platform +
##     battery saver + game state -> `Effective` settings. Headless-tested.
##   - this Node, a thin applier: reads `Settings`, listens on `Events`, writes
##     the result to the root viewport (`scaling_3d_scale`, `msaa_3d`) and
##     `Engine.max_fps`. Other systems read `view_distance_m`, `far_plane_m` and
##     `particle_scale`, and re-read them on `Events.quality_changed` /
##     `Events.governor_changed`.
##
## The governor (WP9.1) only calls `set_governor_rung()`. The rung is a separate
## offset: it never writes the user's `quality_tier` setting, and no rung raises
## any value above what the user's tier gives.
##
## All numbers come from a `QualityTuning` resource (read duck-typed, so tests
## can pass a double).

## Governor rungs, applied cumulatively (spec: Adaptive governor).
const RUNG_NONE := 0
const RUNG_RENDER_SCALE := 1
const RUNG_PARTICLES := 2
const RUNG_VIEW_DISTANCE := 3
const RUNG_FPS := 4
const RUNG_MAX := RUNG_FPS

## Where the tuning is looked up when none was injected: the root `Tuning`
## resource's `quality` field first, then the per-system file (plan D3).
const ROOT_TUNING_PATH := "res://data/tuning.tres"
const TUNING_PATH := "res://data/tuning/quality.tres"


## Effective settings after tier, platform, frame pacing and governor.
class Effective extends RefCounted:
	var tier: StringName = &""
	var tier_index: int = 0
	var governor_rung: int = RUNG_NONE
	var render_scale: float = 1.0
	var msaa_samples: int = 0
	var view_distance_m: float = 0.0
	## Camera far plane: just past the fog end (view distance + margin).
	var far_plane_m: float = 0.0
	var particle_scale: float = 1.0
	## Frame cap for `Engine.max_fps`.
	var max_fps: int = 0


## A `QualityTuning` (or a double with the same fields). Inject before adding
## the node to the tree, or leave null to load it on ready.
var tuning: Resource
## When false and no tuning was injected, `_ready` does not look for one.
var load_tuning_on_ready: bool = true
## MSAA is always off on web.
var is_web: bool = OS.has_feature("web")
## Frame caps are skipped headless (no display to pace; keeps tests fast).
var pace_frames: bool = DisplayServer.get_name() != "headless"
## Thermal state source (stub until WP9.1).
var thermal: Thermal = Thermal.new()

## The last applied settings (null until tuning is available).
var effective: Effective

## Current governor offset (0 = none). Set with `set_governor_rung()`.
var governor_rung: int:
	get:
		return _governor_rung

## The user's (resolved) tier, e.g. &"medium".
var tier: StringName:
	get:
		return effective.tier if effective != null else &""

var render_scale: float:
	get:
		return effective.render_scale if effective != null else 1.0

var view_distance_m: float:
	get:
		return effective.view_distance_m if effective != null else 0.0

var far_plane_m: float:
	get:
		return effective.far_plane_m if effective != null else 0.0

var particle_scale: float:
	get:
		return effective.particle_scale if effective != null else 1.0

var max_fps: int:
	get:
		return effective.max_fps if effective != null else 0

var _governor_rung: int = RUNG_NONE
var _in_gameplay: bool = false


# ---------------------------------------------------------------- Pure part

## Effective settings for `tier` (unknown names fall back to the tuning's
## default tier) with `governor_rung` rungs applied on top.
static func compute(t: Resource, tier_name: StringName, rung: int, web: bool,
		battery_saver: bool, in_gameplay: bool) -> Effective:
	var e := Effective.new()
	var i := tier_index(t, tier_name)
	var r := clampi(rung, RUNG_NONE, RUNG_MAX)
	e.tier_index = i
	e.tier = StringName(t.tier_names[i])
	e.governor_rung = r

	var base_scale: float = t.render_scale[i]
	var base_msaa: int = t.msaa_samples[i]
	var base_view: float = t.view_distance_m[i]
	var base_particles: float = t.particle_scale[i]

	# Frame cap: gameplay vs menus, battery saver, and never above the
	# gameplay cap (60) even on 120 Hz screens.
	var gameplay_fps: int = t.gameplay_fps
	var fps: int = gameplay_fps if in_gameplay else t.menu_fps
	if battery_saver:
		fps = mini(fps, t.battery_saver_fps)
	fps = mini(fps, gameplay_fps)

	var scale_3d := base_scale
	var particles := base_particles
	var view := base_view
	if r >= RUNG_RENDER_SCALE:
		var floor_scale: float = t.governor_render_scale_floor
		var stepped: float = base_scale - t.governor_render_scale_step
		scale_3d = minf(base_scale, maxf(floor_scale, stepped))
	if r >= RUNG_PARTICLES:
		var frac: float = t.governor_particle_step_frac
		particles = base_particles * clampf(1.0 - frac, 0.0, 1.0)
	if r >= RUNG_VIEW_DISTANCE:
		var step_m: float = t.governor_view_distance_step_m
		view = maxf(0.0, base_view - step_m)
	if r >= RUNG_FPS:
		fps = mini(fps, t.governor_fps_floor)

	e.render_scale = scale_3d
	e.msaa_samples = mini(base_msaa, t.web_msaa_samples) if web else base_msaa
	e.view_distance_m = view
	e.far_plane_m = view + float(t.far_plane_margin_m)
	e.particle_scale = particles
	e.max_fps = fps
	return e


## Index of `tier_name` in the tuning's tier list, else of its default tier.
static func tier_index(t: Resource, tier_name: StringName) -> int:
	var names: PackedStringArray = t.tier_names
	var i := names.find(String(tier_name))
	if i < 0:
		i = names.find(String(t.default_tier))
	return maxi(i, 0)


## MSAA sample count -> viewport setting.
static func msaa_mode(samples: int) -> Viewport.MSAA:
	if samples >= 8:
		return Viewport.MSAA_8X
	if samples >= 4:
		return Viewport.MSAA_4X
	if samples >= 2:
		return Viewport.MSAA_2X
	return Viewport.MSAA_DISABLED


## Game states that run at the gameplay frame cap; everything else is a menu.
static func is_gameplay_state(state: StringName) -> bool:
	return state == Game.RUNNING or state == Game.COUNTDOWN or state == Game.CRASH


# ---------------------------------------------------------------- Applier

func _ready() -> void:
	if tuning == null and load_tuning_on_ready:
		tuning = _load_tuning()
	_in_gameplay = is_gameplay_state(Game.state)
	Events.settings_changed.connect(_on_settings_changed)
	Events.game_state_changed.connect(_on_game_state_changed)
	DevStats.report(DevStats.THERMAL, thermal.get_state())
	apply()


## Recompute from the current settings, game state and rung, and apply.
func apply() -> void:
	if tuning == null:
		return
	var prev_tier := tier
	var user_tier: StringName = Settings.get_value(&"quality_tier")
	if not tuning.tier_names.has(String(user_tier)):
		push_warning("Quality: unknown tier %s, using %s" % [user_tier, tuning.default_tier])
	var saver: bool = Settings.get_value(&"battery_saver")
	effective = compute(tuning, user_tier, _governor_rung, is_web, saver, _in_gameplay)

	var vp := get_viewport()
	vp.scaling_3d_scale = effective.render_scale
	vp.msaa_3d = msaa_mode(effective.msaa_samples)
	if pace_frames:
		Engine.max_fps = effective.max_fps

	DevStats.report(DevStats.QUALITY_TIER, effective.tier)
	DevStats.report(DevStats.GOVERNOR_RUNG, effective.governor_rung)
	DevStats.report(DevStats.MAX_FPS, effective.max_fps)
	DevStats.report(DevStats.DRAW_CALL_BUDGET, tuning.draw_call_budget)
	DevStats.report(DevStats.TRIANGLE_BUDGET, tuning.triangle_budget)

	if effective.tier != prev_tier:
		Events.quality_changed.emit(effective.tier)


## Governor offset (WP9.1). 0 = none, 1..4 = the spec's rungs, cumulative.
func set_governor_rung(rung: int) -> void:
	var r := clampi(rung, RUNG_NONE, RUNG_MAX)
	if r == _governor_rung:
		return
	_governor_rung = r
	apply()
	Events.governor_changed.emit(r)


func get_thermal_state() -> StringName:
	return thermal.get_state()


## Point a camera's far plane at the current view distance (+ margin).
func apply_far_plane(camera: Camera3D) -> void:
	if effective != null:
		camera.far = effective.far_plane_m


func _on_settings_changed(key: StringName) -> void:
	if key == &"quality_tier" or key == &"battery_saver":
		apply()


func _on_game_state_changed(_from: StringName, to: StringName) -> void:
	var gameplay := is_gameplay_state(to)
	if gameplay == _in_gameplay:
		return
	_in_gameplay = gameplay
	apply()


func _load_tuning() -> Resource:
	if ResourceLoader.exists(ROOT_TUNING_PATH):
		var root_tuning: Resource = load(ROOT_TUNING_PATH)
		if root_tuning != null and &"quality" in root_tuning:
			var q: Variant = root_tuning.get(&"quality")
			if q is Resource:
				return q
	if ResourceLoader.exists(TUNING_PATH):
		return load(TUNING_PATH)
	push_warning("Quality: no quality tuning at %s or %s; tiers not applied" % [
		ROOT_TUNING_PATH, TUNING_PATH])
	return null
