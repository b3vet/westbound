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
## The governor (WP9.1, src/platform/governor.gd) runs here: every frame (not headless,
## unless a thermal override is given) the real frame time, the frame cap and the
## thermal level (src/platform/thermal.gd) go into `governor`, and a new rung goes
## through `set_governor_rung()`. The rung is a separate offset: it never writes the
## user's `quality_tier` setting, and no rung raises any value above what the user's tier
## gives. docs/QUALITY.md.
##
## Simulation safety (WP9.1): the rungs change rendering only (render scale, particles,
## the frame cap), except that the view distance still feeds the simulation (the
## director's spawn distance at run start, how far ahead the road and the leg planner
## generate: docs/QUALITY.md → Simulation safety; N8.2). So the view-distance rung is
## held from a run's start (Game COUNTDOWN) to its end (RESULTS / MENU) and applied between
## runs (`QualityTuning.governor_view_distance_between_runs`): a governor step mid-run never
## changes the run. `run_view_distance_m` is the user tier's view distance, never the
## governor's, for simulation uses once N8.2 moves them off `view_distance_m`.
##
## All numbers come from a `QualityTuning` resource (read duck-typed, so tests
## can pass a double).
##
## Dev override (WP4.6, the dev HUD's quality row): `set_dev_override(scale, msaa)`
## pins the render scale and/or MSAA for this session (never saved), on top of
## whatever tier, governor rung, platform or game state apply() computes, so it
## survives tier re-application. It also bypasses the web MSAA-off rule, so MSAA can be
## tried on the web build (Compatibility supports 2x/4x there). `clear_dev_override()`
## goes back to the tier.

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
## "No dev override" for either value.
const NO_OVERRIDE := -1
## Dev cycle steps when the tuning has none (a test double).
const DEFAULT_DEV_RENDER_SCALES: Array[float] = [0.6, 0.75, 0.85, 1.0]
const DEFAULT_DEV_MSAA: Array[int] = [0, 2, 4]
## Scale steps closer than this count as the same step.
const STEP_EPS := 1e-3  # lint: allow-number comparison tolerance, not a tuning value
const USEC_PER_S := 1_000_000.0   # lint: allow-number unit conversion
## How often the governor's dev HUD numbers are reported (the dev HUD reads at 4 Hz).
const REPORT_INTERVAL_S := 0.25   # lint: allow-number dev report cadence
## DevStats keys (WP9.1): the governor's pressure ("calm", "hold", "frames", "thermal",
## "idle"), the last step's reason, the window's frame p95 (ms) and miss share, the
## thermal source ("native", "forced", "none") and whether the cooling icon shows.
const DEV_GOVERNOR_PRESSURE := &"governor_pressure"
const DEV_GOVERNOR_REASON := &"governor_reason"
const DEV_GOVERNOR_P95_MS := &"governor_p95_ms"
const DEV_GOVERNOR_MISS := &"governor_miss"
const DEV_THERMAL_SOURCE := &"thermal_source"
const DEV_COOLING := &"cooling"
## Rung names (dev HUD), index = rung.
const RUNG_NAMES: PackedStringArray = ["none", "scale", "particles", "view", "30fps"]


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
	## True when a dev override set the render scale or MSAA.
	var dev_override: bool = false
	## The rung the view distance and far plane were computed with (held during a run).
	var view_rung: int = RUNG_NONE
	## The governor's view-distance rung is waiting for the run to end.
	var view_pending: bool = false


## A `QualityTuning` (or a double with the same fields). Inject before adding
## the node to the tree, or leave null to load it on ready.
var tuning: Resource
## When false and no tuning was injected, `_ready` does not look for one.
var load_tuning_on_ready: bool = true
## MSAA is always off on web.
var is_web: bool = OS.has_feature("web")
## Frame caps are skipped headless (no display to pace; keeps tests fast).
var pace_frames: bool = DisplayServer.get_name() != "headless"
## Thermal state source (native plugin, dev override or none).
var thermal: Thermal = Thermal.new()
## The adaptive governor (configured from the tuning on ready).
var governor: Governor = Governor.new()
## Run the governor every frame. Off headless (tests drive `step_governor()` themselves)
## unless a thermal override was given at boot.
var governor_enabled: bool = DisplayServer.get_name() != "headless"

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

## The user tier's view distance, never the governor's: for simulation uses (N8.2).
var run_view_distance_m: float:
	get:
		if tuning == null or effective == null:
			return 0.0
		return float(tuning.view_distance_m[effective.tier_index])

var particle_scale: float:
	get:
		return effective.particle_scale if effective != null else 1.0

var max_fps: int:
	get:
		return effective.max_fps if effective != null else 0

## The applied MSAA sample count (0 = off).
var msaa_samples: int:
	get:
		return effective.msaa_samples if effective != null else 0

## Dev override values (NO_OVERRIDE = the tier's). Session only.
var dev_render_scale: float:
	get:
		return _dev_scale

var dev_msaa_samples: int:
	get:
		return _dev_msaa

var _governor_rung: int = RUNG_NONE
var _view_rung: int = RUNG_NONE
var _in_gameplay: bool = false
var _in_run: bool = false
var _last_frame_usec: int = 0
var _report_t: float = 0.0
var _dev_scale: float = float(NO_OVERRIDE)
var _dev_msaa: int = NO_OVERRIDE


# ---------------------------------------------------------------- Pure part

## Effective settings for `tier` (unknown names fall back to the tuning's
## default tier) with `governor_rung` rungs applied on top.
## `dev_scale` / `dev_msaa` >= 0 replace the final render scale / MSAA (dev override;
## MSAA then ignores the web rule).
## `view_rung` >= 0 computes the view distance and far plane at that rung instead (the
## run-held rung, see Simulation safety above).
static func compute(t: Resource, tier_name: StringName, rung: int, web: bool,
		battery_saver: bool, in_gameplay: bool, dev_scale: float = NO_OVERRIDE,
		dev_msaa: int = NO_OVERRIDE, view_rung: int = -1) -> Effective:
	var e := Effective.new()
	var i := tier_index(t, tier_name)
	var r := clampi(rung, RUNG_NONE, RUNG_MAX)
	var vr := r if view_rung < 0 else clampi(view_rung, RUNG_NONE, RUNG_MAX)
	e.tier_index = i
	e.tier = StringName(t.tier_names[i])
	e.governor_rung = r
	e.view_rung = vr
	e.view_pending = (r >= RUNG_VIEW_DISTANCE) != (vr >= RUNG_VIEW_DISTANCE)

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
	if vr >= RUNG_VIEW_DISTANCE:
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
	if dev_scale >= 0.0:
		e.render_scale = dev_scale
		e.dev_override = true
	if dev_msaa >= 0:
		e.msaa_samples = dev_msaa
		e.dev_override = true
	return e


## The step after `current` in `steps` (ascending), wrapping to the first.
static func next_step_f(steps: Array[float], current: float) -> float:
	for v in steps:
		if v > current + STEP_EPS:
			return v
	return steps[0]


static func next_step_i(steps: Array[int], current: int) -> int:
	for v in steps:
		if v > current:
			return v
	return steps[0]


## Internal 3D resolution for a window size and render scale (what the 3D renders at
## before the upscale to the window).
static func internal_3d_size(window_size: Vector2i, scale: float) -> Vector2i:
	return Vector2i(roundi(float(window_size.x) * scale), roundi(float(window_size.y) * scale))


## "off", "2x", "4x".
static func msaa_label(samples: int) -> String:
	return "off" if samples <= 0 else "%dx" % samples


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
	process_mode = Node.PROCESS_MODE_ALWAYS   # thermal and the frame clock run in pause too
	if tuning == null and load_tuning_on_ready:
		tuning = _load_tuning()
	_in_gameplay = is_gameplay_state(Game.state)
	_in_run = is_run_state(Game.state)
	Events.settings_changed.connect(_on_settings_changed)
	Events.game_state_changed.connect(_on_game_state_changed)
	if tuning != null:
		governor.configure(tuning)
		thermal.configure(tuning)
	thermal.changed.connect(_on_thermal_changed)
	thermal.detect()
	var over := boot_param(Thermal.BOOT_PARAM)
	if not over.is_empty() and thermal.apply_override(over):
		governor_enabled = true
	_report_thermal()
	apply()


func _process(_delta: float) -> void:
	if not governor_enabled:
		return
	var now := Time.get_ticks_usec()
	if _last_frame_usec > 0:
		step_governor(float(now - _last_frame_usec) / USEC_PER_S)
	_last_frame_usec = now


## One frame of `frame_s` real seconds: thermal, then the governor; applies a new rung.
## The autoload calls it every frame; tests call it with synthetic frame times.
func step_governor(frame_s: float) -> void:
	thermal.advance(frame_s)
	if tuning == null:
		return
	var target := 1.0 / float(maxi(max_fps, 1))
	if governor.tick(frame_s, target, thermal.level(), _in_gameplay):
		set_governor_rung(governor.rung)
	_report_t += frame_s
	if _report_t >= REPORT_INTERVAL_S:
		_report_t = 0.0
		report_governor()


## The governor's dev HUD numbers (DevStats): pressure, last reason, frame p95, miss share.
func report_governor() -> void:
	DevStats.report(DEV_GOVERNOR_PRESSURE, governor.pressure_name())
	DevStats.report(DEV_GOVERNOR_REASON, governor.reason_name())
	DevStats.report(DEV_GOVERNOR_P95_MS, governor.frame_report_s() * Governor.MS_PER_S)
	DevStats.report(DEV_GOVERNOR_MISS, governor.miss_fraction())
	DevStats.report(DEV_COOLING, is_cooling())


## Recompute from the current settings, game state and rung, and apply.
func apply() -> void:
	if tuning == null:
		return
	var prev_tier := tier
	var user_tier: StringName = Settings.get_value(&"quality_tier")
	if not tuning.tier_names.has(String(user_tier)):
		push_warning("Quality: unknown tier %s, using %s" % [user_tier, tuning.default_tier])
	var saver: bool = Settings.get_value(&"battery_saver")
	if not (_in_run and _hold_view_in_run()):
		_view_rung = _governor_rung
	effective = compute(tuning, user_tier, _governor_rung, is_web, saver, _in_gameplay,
		_dev_scale, _dev_msaa, _view_rung)
	_update_useful_rungs(user_tier, saver)

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
	DevStats.report(DevStats.RENDER_SCALE, effective.render_scale)
	DevStats.report(DevStats.MSAA, msaa_label(effective.msaa_samples))
	DevStats.report(DevStats.QUALITY_DEV_OVERRIDE, effective.dev_override)

	if effective.tier != prev_tier:
		Events.quality_changed.emit(effective.tier)


## Governor offset (WP9.1). 0 = none, 1..4 = the spec's rungs, cumulative. The governor
## calls it; a call from elsewhere (dev, tests) also moves the governor to that rung.
func set_governor_rung(rung: int) -> void:
	var r := clampi(rung, RUNG_NONE, RUNG_MAX)
	governor.set_rung(r)
	if r == _governor_rung:
		return
	_governor_rung = r
	apply()
	Events.governor_changed.emit(r)
	DevStats.report(DEV_COOLING, is_cooling())


## The HUD's cooling icon: the governor is active for thermal reasons (or for any reason
## with QualityTuning.cooling_icon_any_reason).
func is_cooling() -> bool:
	var any := tuning != null and &"cooling_icon_any_reason" in tuning \
		and bool(tuning.get(&"cooling_icon_any_reason"))
	return governor.cooling(any)


## Dev HUD THERMAL button: auto → nominal → fair → serious → critical → auto.
func cycle_dev_thermal() -> void:
	thermal.cycle_force()
	if thermal.is_forced():
		governor_enabled = true
	_report_thermal()


## Game states from a run's start to its end (the view-distance rung is held there).
static func is_run_state(state: StringName) -> bool:
	return state == Game.COUNTDOWN or state == Game.RUNNING or state == Game.PAUSED \
		or state == Game.CRASH


## A boot parameter: `?key=value` on the web, `--key=value` on the command line.
static func boot_param(key: String) -> String:
	var prefix := "%s=" % key
	if OS.has_feature("web"):
		var query: Variant = JavaScriptBridge.eval("window.location.search", true)
		if query is String:
			for part: String in (query as String).trim_prefix("?").split("&"):
				if part.begins_with(prefix):
					return part.trim_prefix(prefix).uri_decode()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--" + prefix):
			return a.trim_prefix("--" + prefix)
	for a in OS.get_cmdline_args():
		if a.begins_with("--" + prefix):
			return a.trim_prefix("--" + prefix)
	return ""


func _hold_view_in_run() -> bool:
	if tuning != null and &"governor_view_distance_between_runs" in tuning:
		return bool(tuning.get(&"governor_view_distance_between_runs"))
	return true


## Tells the governor which rungs change anything for this tier (it skips the rest).
func _update_useful_rungs(user_tier: StringName, saver: bool) -> void:
	var prev := compute(tuning, user_tier, RUNG_NONE, is_web, saver, true, _dev_scale, _dev_msaa)
	for r in range(RUNG_NONE + 1, RUNG_MAX + 1):
		var e := compute(tuning, user_tier, r, is_web, saver, true, _dev_scale, _dev_msaa)
		governor.set_useful(r, not is_equal_approx(e.render_scale, prev.render_scale)
			or not is_equal_approx(e.particle_scale, prev.particle_scale)
			or not is_equal_approx(e.view_distance_m, prev.view_distance_m)
			or e.max_fps != prev.max_fps)
		prev = e


func _on_thermal_changed(state: StringName) -> void:
	_report_thermal()
	Events.thermal_state_changed.emit(state)


func _report_thermal() -> void:
	DevStats.report(DevStats.THERMAL, thermal.get_state())
	DevStats.report(DEV_THERMAL_SOURCE, thermal.source())


## Dev override for this session: `render_scale_value` / `msaa` >= 0 pin that value
## (NO_OVERRIDE leaves the tier's). Survives apply(); never saved.
func set_dev_override(render_scale_value: float, msaa: int) -> void:
	_dev_scale = render_scale_value if render_scale_value >= 0.0 else float(NO_OVERRIDE)
	_dev_msaa = msaa if msaa >= 0 else NO_OVERRIDE
	apply()


func clear_dev_override() -> void:
	set_dev_override(NO_OVERRIDE, NO_OVERRIDE)


func has_dev_override() -> bool:
	return _dev_scale >= 0.0 or _dev_msaa >= 0


## Dev HUD: the next render scale step after the current one (keeps the MSAA).
func cycle_dev_render_scale() -> void:
	set_dev_override(next_step_f(_dev_render_scales(), render_scale), _dev_msaa)


## Dev HUD: the next MSAA step after the current one (keeps the render scale).
func cycle_dev_msaa() -> void:
	set_dev_override(_dev_scale, next_step_i(_dev_msaa_steps(), msaa_samples))


func _dev_render_scales() -> Array[float]:
	var out: Array[float] = []
	if tuning != null and &"dev_render_scale_steps" in tuning:
		for v: float in tuning.get(&"dev_render_scale_steps"):
			out.append(v)
	return out if not out.is_empty() else DEFAULT_DEV_RENDER_SCALES


func _dev_msaa_steps() -> Array[int]:
	var out: Array[int] = []
	if tuning != null and &"dev_msaa_steps" in tuning:
		for v: int in tuning.get(&"dev_msaa_steps"):
			out.append(v)
	return out if not out.is_empty() else DEFAULT_DEV_MSAA


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
	var in_run := is_run_state(to)
	if gameplay == _in_gameplay and in_run == _in_run:
		return
	_in_gameplay = gameplay
	_in_run = in_run
	var held := _view_rung
	apply()
	if _view_rung != held:
		# The run ended: the held view-distance rung applies now; view readers re-read.
		Events.governor_changed.emit(_governor_rung)


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
