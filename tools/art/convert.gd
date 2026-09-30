extends SceneTree
## G2 / G3 command line: converts the Blender agent's exports into the meshes the game
## loads (docs/ART_PRODUCTION.md §3.10, §3.11, §6.3; ArtConvert does the work).
##
##   tools/godot.sh --headless --path . --script res://tools/art/convert.gd -- \
##       [--kind=traffic|props|all] [--src=art/export] [--out=res://assets] [--only=<name>] [--check]
##
##   traffic  <src>/traffic/<model>.glb + <model>.traffic.json (+ <model>_lod1.glb)
##            -> <out>/traffic/<model>.res, <model>.tscn (+ <model>_lod1.res, meta lod1_path)
##   props    <src>/props/<biome>/<name>.glb + <name>.prop.json
##            -> <out>/props/<biome>/<mesh>.res
## --src is a project path (res://...) or any directory (the art/ folder is gdignored, so
## GLTFDocument reads it straight from disk); --out defaults to res://assets. --check
## converts and reports without writing. An asset with problems (§3 rules: names,
## materials, parts, size against its VehicleType, budgets) is reported and not written;
## the exit code is 1 if any asset had problems.
## Rerunning a procedural builder afterwards keeps converted meshes (ArtConvert.is_converted).

## The asset budgets (loaded directly: Tuning pulls in autoloads a --script run lacks).
const PROGRESSION_PATH := "res://data/tuning/progression.tres"

var _src := "res://art/export"
var _out := "res://assets"
var _kind := "all"
var _only := ""
var _check := false
var _failed := 0
var _written := 0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--src="):
			_src = a.trim_prefix("--src=")
		elif a.begins_with("--out="):
			_out = a.trim_prefix("--out=")
		elif a.begins_with("--kind="):
			_kind = a.trim_prefix("--kind=")
		elif a.begins_with("--only="):
			_only = a.trim_prefix("--only=")
		elif a == "--check":
			_check = true
		else:
			printerr("convert: unknown argument %s" % a)
			quit(2)
			return
	var palette := ArtPalette.new()
	var conv := ArtConvert.new(palette)
	var pt := load(PROGRESSION_PATH) as ProgressionTuning
	if _kind == "traffic" or _kind == "all":
		_traffic(conv, pt)
	if _kind == "props" or _kind == "all":
		_props(conv)
	print("convert: %d written, %d with problems%s" % [_written, _failed, " (check only)" if _check else ""])
	quit(1 if _failed > 0 else 0)


func _dir(path: String) -> String:
	return path if path.begins_with("res://") or path.begins_with("user://") or path.is_absolute_path() \
		else ProjectSettings.globalize_path("res://").path_join(path)


static func _glbs(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	if not DirAccess.dir_exists_absolute(dir):
		return out
	for f in DirAccess.get_files_at(dir):
		if f.get_extension().to_lower() == "glb":
			out.append(dir.path_join(f))
	out.sort()
	return out


func _report(what: String, r: ArtConvert.Result) -> void:
	for n in r.notes:
		print("  %s: %s" % [what, n])
	for p in r.problems:
		printerr("  %s: PROBLEM %s" % [what, p])


func _traffic(conv: ArtConvert, pt: ProgressionTuning) -> void:
	var dir := _dir(_src).path_join("traffic")
	for glb in _glbs(dir):
		var model := glb.get_file().get_basename()
		if model.ends_with(ArtConvert.LOD1_SUFFIX) or (not _only.is_empty() and model != _only):
			continue
		var problems := PackedStringArray()
		var side := ArtConvert.load_sidecar(glb, ".traffic.json", problems)
		model = str(side.get("model", model))
		var r := _convert_traffic(conv, glb, side)
		r.problems.append_array(problems)
		if r.mesh != null and CarModel.triangle_count(r.mesh) > pt.traffic_tris_lod0:
			r.problems.append("%d tris > the LOD0 budget %d" % [CarModel.triangle_count(r.mesh), pt.traffic_tris_lod0])
		var lod_glb := glb.get_basename() + ArtConvert.LOD1_SUFFIX + ".glb"
		var lod: ArtConvert.Result = null
		if FileAccess.file_exists(lod_glb):
			lod = _convert_traffic(conv, lod_glb, side)
			for p in lod.problems:
				r.problems.append("LOD1: " + p)
			if lod.mesh != null and CarModel.triangle_count(lod.mesh) > pt.traffic_tris_lod1:
				r.problems.append("LOD1: %d tris > the budget %d" % [CarModel.triangle_count(lod.mesh), pt.traffic_tris_lod1])
		_report(model, r)
		if not r.problems.is_empty() or r.mesh == null:
			_failed += 1
			continue
		var out_dir := _dir(_out).path_join("traffic")
		if lod != null:
			var lod_path := out_dir.path_join(model + ArtConvert.LOD1_SUFFIX + ".res")
			r.mesh.set_meta(&"lod1_path", lod_path)
			if not _check and ResourceSaver.save(lod.mesh, lod_path) != OK:
				printerr("  %s: cannot write %s" % [model, lod_path])
				_failed += 1
				continue
		if _check:
			continue
		var err := ArtConvert.save_traffic(r.mesh, model, out_dir)
		if err != OK:
			printerr("  %s: cannot write to %s (%d)" % [model, out_dir, err])
			_failed += 1
			continue
		_written += 1
		print("wrote %s" % out_dir.path_join(model + ".tscn"))


func _convert_traffic(conv: ArtConvert, glb: String, side: Dictionary) -> ArtConvert.Result:
	var scene := ArtCalib.read_glb(glb)
	if scene == null:
		var bad := ArtConvert.Result.new()
		bad.problems.append("cannot read %s" % glb)
		return bad
	var r := conv.traffic(scene, side, glb)
	scene.free()
	return r


func _props(conv: ArtConvert) -> void:
	var base := _dir(_src).path_join("props")
	if not DirAccess.dir_exists_absolute(base):
		return
	for biome in DirAccess.get_directories_at(base):
		for glb in _glbs(base.path_join(biome)):
			var problems := PackedStringArray()
			var side := ArtConvert.load_sidecar(glb, ".prop.json", problems)
			if not side.has("biome"):
				side["biome"] = biome
			var mesh_name := str(side.get("mesh", glb.get_file().get_basename()))
			if not _only.is_empty() and mesh_name != _only:
				continue
			var scene := ArtCalib.read_glb(glb)
			if scene == null:
				printerr("  %s: PROBLEM cannot read %s" % [mesh_name, glb])
				_failed += 1
				continue
			var r := conv.prop(scene, side, glb)
			scene.free()
			r.problems.append_array(problems)
			var budget := int(side.get("tris_budget", ArtConvert.PROP_TRIS_BUDGET))
			if r.mesh != null and CarModel.triangle_count(r.mesh) > budget:
				r.problems.append("%d tris > the prop budget %d" % [CarModel.triangle_count(r.mesh), budget])
			_report(mesh_name, r)
			if not r.problems.is_empty() or r.mesh == null:
				_failed += 1
				continue
			if _check:
				continue
			var out_dir := _dir(_out).path_join("props").path_join(biome)
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
			var path := out_dir.path_join(mesh_name + ".res")
			if ResourceSaver.save(r.mesh, path) != OK:
				printerr("  %s: cannot write %s" % [mesh_name, path])
				_failed += 1
				continue
			_written += 1
			print("wrote %s" % path)
