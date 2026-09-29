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
