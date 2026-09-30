class_name DevReport
extends RefCounted
## Plain-text snapshot for playtest feedback (owner request, M2): build,
## device, renderer, scene, every dev HUD row and every DevStats value.
## Shared by the dev HUD's COPY button. Dev-only; allocates freely.

const BUILD_INFO_PATH := "res://build_info.cfg"
const QUALITY_SCRIPT := preload("res://src/platform/quality.gd")


static func build_line() -> String:
	var cfg := ConfigFile.new()
	var debug := "debug" if OS.is_debug_build() else "release"
	if cfg.load(BUILD_INFO_PATH) != OK:
		return "local (no build_info.cfg) %s" % debug
	return "%s %s %s" % [cfg.get_value("build", "commit", "?"), cfg.get_value("build", "date", "?"), debug]


## What the 3D renders at (WP4.6): tier, render scale, internal resolution, MSAA and
## whether a dev override set them, so a pasted report says what was tested.
static func render_line(window_size: Vector2i) -> String:
	var tree := Engine.get_main_loop() as SceneTree
	var vp: Viewport = tree.root if tree != null else null
	var scale_3d := vp.scaling_3d_scale if vp != null else 1.0
	var internal := QUALITY_SCRIPT.internal_3d_size(window_size, scale_3d)
	var msaa := viewport_msaa_label(vp) if vp != null else "?"
	var dev: bool = DevStats.get_value(DevStats.QUALITY_DEV_OVERRIDE, false)
	return "render    tier %s, 3d scale %.2f -> %dx%d, msaa %s%s" % [
		str(DevStats.get_value(DevStats.QUALITY_TIER, "?")), scale_3d, internal.x, internal.y, msaa,
		" (dev override)" if dev else ""]


## A viewport's 3D MSAA as "off", "2x", "4x" or "8x".
static func viewport_msaa_label(vp: Viewport) -> String:
	if vp.msaa_3d == Viewport.MSAA_DISABLED or vp.msaa_3d == Viewport.MSAA_MAX:
		return "off"
	return "%dx" % (1 << int(vp.msaa_3d))


## `hud_rows`: [[name, value], ...] from the dev HUD.
static func compose(hud_rows: Array, scene_name: String) -> String:
	var lines := PackedStringArray()
	lines.append("Westbound dev report")
	lines.append("build     %s" % build_line())
	lines.append("time      %s UTC, uptime %.0f s" % [
		Time.get_datetime_string_from_system(true, true), Time.get_ticks_msec() / 1000.0])
	lines.append("platform  %s / %s%s" % [OS.get_name(), OS.get_model_name(),
		" (web)" if OS.has_feature("web") else ""])
	lines.append("renderer  %s, %s" % [RenderingServer.get_current_rendering_method(),
		RenderingServer.get_video_adapter_name()])
	var win := DisplayServer.window_get_size()
	lines.append("screen    %dx%d, canvas %s, safe %s" % [win.x, win.y,
		str(Engine.get_main_loop().root.get_visible_rect().size),
		str(DisplayServer.get_display_safe_area())])
	lines.append(render_line(win))
	lines.append("scene     %s" % scene_name)
	lines.append("traffic   %s" % traffic_line(scene_traffic_sim()))
	lines.append("racers    %s" % racers_line(scene_traffic_director()))
	lines.append("-- hud")
	for row: Array in hud_rows:
		lines.append("%-9s %s" % [row[0], row[1]])
	var keys := DevStats.keys()
	keys.sort()
	if not keys.is_empty():
		lines.append("-- stats")
		for k: Variant in keys:
			lines.append("%-14s %s" % [String(k), str(DevStats.get_value(k))])
	return "\n".join(lines)


## The current scene's TrafficSim (its `sim` property: the run, the traffic sandbox), or null.
static func scene_traffic_sim() -> TrafficSim:
	var tree := Engine.get_main_loop() as SceneTree
	var scene: Node = tree.current_scene if tree != null else null
	return scene.get(&"sim") as TrafficSim if scene != null else null


## The current scene's TrafficDirector (its `director` property: the run, the traffic
## sandbox), or null.
static func scene_traffic_director() -> TrafficDirector:
	var tree := Engine.get_main_loop() as SceneTree
	var scene: Node = tree.current_scene if tree != null else null
	return scene.get(&"director") as TrafficDirector if scene != null else null


## Racers from behind (plan D17, WP6.7), this run: racers that passed the player and
## that the player overtook, and the arrivals spawned behind the player (of them, how
## many got past it).
static func racers_line(director: TrafficDirector) -> String:
	if director == null:
		return "-"
	return "passed you %d, you overtook %d, arrivals %d (%d passed you)%s" % [director.racers_passed_player,
		director.racers_overtaken, director.racer_arrivals, director.arrivals_passed_player,
		"" if director.racer_arrivals_enabled else ", arrivals off"]


## Live traffic speeds on the player's carriageway (plan D15, owner M5: "the traffic is
## quite slow"): count, mean, the share faster than each TrafficTuning.dev_speed_bands_kmh,
## the mean per lane (lane 0 = next to the median) and the aggressive + racer count.
static func traffic_line(sim: TrafficSim) -> String:
	if sim == null or sim.state == null:
		return "-"
	var st := sim.state
	var bands := sim.tuning.dev_speed_bands_kmh
	var over := PackedInt32Array()
	over.resize(bands.size())
	var lane_sum := PackedFloat64Array()
	var lane_n := PackedInt32Array()
	var agg := sim.registry.profile_index(sim.tuning.spawn_aggressive_profile_id)
	var racer := sim.registry.profile_index(sim.tuning.spawn_racer_profile_id)
	var n := 0
	var fast := 0
	var racers := 0
	var sum := 0.0
	for i in st.capacity:
		if st.active[i] == 0:
			continue
		var kmh := Units.mps_to_kmh(st.v[i])
		n += 1
		sum += kmh
		for b in bands.size():
			if kmh > bands[b]:
				over[b] += 1
		var ln := st.lane[i]
		if ln >= lane_sum.size():
			lane_sum.resize(ln + 1)
			lane_n.resize(ln + 1)
		if ln >= 0:
			lane_sum[ln] += kmh
			lane_n[ln] += 1
		if st.profile_id[i] == racer:
			racers += 1
		if st.profile_id[i] == racer or st.profile_id[i] == agg:
			fast += 1
	if n == 0:
		return "0 vehicles"
	var parts := PackedStringArray()
	for b in bands.size():
		parts.append(">%.0f %.0f%%" % [bands[b], 100.0 * float(over[b]) / float(n)])
	var lanes := PackedStringArray()
	for l in lane_sum.size():
		lanes.append("%.0f" % (lane_sum[l] / float(lane_n[l])) if lane_n[l] > 0 else "-")
	return "%d veh, mean %.0f km/h, %s, lanes [%s], fast %d (racer %d)" % [
		n, sum / float(n), ", ".join(parts), " ".join(lanes), fast, racers]


## Web: an HTML overlay with a native Copy button (iOS Safari only allows
## clipboard writes inside a real DOM gesture). Native: the OS clipboard.
## Returns true when the text went straight to the clipboard.
static func share(text: String) -> bool:
	if OS.has_feature("web"):
		JavaScriptBridge.eval(_overlay_js(JSON.stringify(text)), true)
		return false
	DisplayServer.clipboard_set(text)
	return true


static func _overlay_js(text_literal: String) -> String:
	return """(function(t){
var old=document.getElementById('wb-report'); if(old){old.remove();}
var d=document.createElement('div'); d.id='wb-report';
d.style.cssText='position:fixed;inset:0;z-index:9999;background:rgba(11,16,32,.94);display:flex;flex-direction:column;gap:10px;box-sizing:border-box;padding:max(16px,env(safe-area-inset-top)) max(16px,env(safe-area-inset-right)) max(16px,env(safe-area-inset-bottom)) max(16px,env(safe-area-inset-left));color:#f4f7ff;font:600 15px sans-serif';
var ta=document.createElement('textarea'); ta.value=t; ta.readOnly=true;
ta.style.cssText='flex:1;min-height:0;background:#111a30;color:#f4f7ff;border:1px solid #8a93ad;font:12px monospace;padding:8px;resize:none';
var row=document.createElement('div'); row.style.cssText='display:flex;gap:10px;align-items:center';
var status=document.createElement('span'); status.style.cssText='min-width:140px';
function mk(label,fn){var b=document.createElement('button');b.textContent=label;
b.style.cssText='flex:1;padding:14px;font:600 16px sans-serif;background:#111a30;color:#f4f7ff;border:2px solid #8a93ad;border-radius:0';
b.onclick=fn;return b;}
row.append(mk('Copy',function(){
  function manual(){ta.focus();ta.setSelectionRange(0,t.length);status.textContent='Selected: use Copy';}
  if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(t).then(function(){status.textContent='Copied';},manual);}else{manual();}
}), mk('Close',function(){d.remove();}), status);
d.append(ta,row); document.body.appendChild(d);
})(%s)""" % text_literal
