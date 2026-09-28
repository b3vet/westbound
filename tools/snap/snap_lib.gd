class_name WBSnap
extends RefCounted
## Option parsing and capture planning for tools/snap.sh (review tooling, plan §3).
## Pure helpers, so tests/unit/test_snap.gd can check them headless; the
## SceneTree driver that renders and saves images is tools/snap/snap.gd.
##
## Reserved options (everything else passes through to the scene's snap_setup):
##   --frames=N          frames to wait after snap_setup before capturing (default 30)
##   --seconds=S         extra simulated seconds to wait (frames at the fixed snap fps)
##   --sweep=key:a,b,c   one capture per value; repeatable (cartesian product)
##   --out=DIR           output directory (absolute path; snap.sh resolves it)
##   --tag=NAME          extra filename suffix, e.g. to keep --cam=hood and --cam=chase apart
##   --size=WxH          window size (applied by snap.sh; accepted and ignored here)

const DEFAULT_FRAMES := 30
## snap.sh runs Godot with --fixed-fps at this rate, so simulated time is exact.
const SNAP_FPS := 60
const DEFAULT_OUT := "res://tests/out/snaps"
const RESERVED := ["frames", "seconds", "sweep", "out", "tag", "size"]


## Parses `[scene, --key=value, ...]`. Returns a Dictionary with keys
## scene, frames, seconds, out, tag, params (Dictionary), sweeps (Array of
## [key, PackedStringArray]) and errors (PackedStringArray, empty when valid).
static func parse_args(args: PackedStringArray) -> Dictionary:
	var opts := {
		"scene": "",
		"frames": DEFAULT_FRAMES,
		"seconds": 0.0,
		"out": DEFAULT_OUT,
		"tag": "",
		"params": {},
		"sweeps": [],
		"errors": PackedStringArray(),
	}
	var errors: PackedStringArray = opts["errors"]
	for a in args:
		if not a.begins_with("--"):
			if opts["scene"] != "":
				errors.append("more than one scene given: %s" % a)
			opts["scene"] = a
			continue
		var body := a.substr(2)
		var eq := body.find("=")
		var key := body if eq < 0 else body.substr(0, eq)
		var value := "true" if eq < 0 else body.substr(eq + 1)
		if key.is_empty():
			errors.append("bad option: %s" % a)
			continue
		match key:
			"frames":
				if not value.is_valid_int() or value.to_int() < 1:
					errors.append("--frames must be a positive integer: %s" % value)
				else:
					opts["frames"] = value.to_int()
			"seconds":
				if not value.is_valid_float() or value.to_float() < 0.0:
					errors.append("--seconds must be a non-negative number: %s" % value)
				else:
					opts["seconds"] = value.to_float()
			"sweep":
				var colon := value.find(":")
				var values := value.substr(colon + 1).split(",", false) if colon > 0 else PackedStringArray()
				if values.is_empty():
					errors.append("--sweep must look like key:v1,v2,...: %s" % value)
				else:
					opts["sweeps"].append([value.substr(0, colon), values])
			"out":
				opts["out"] = value
			"tag":
				opts["tag"] = value
			"size":
				pass
			_:
				opts["params"][key] = coerce(value)
	if opts["scene"] == "":
		errors.append("no scene given")
	return opts


## "true"/"false" -> bool, integer text -> int, float text -> float, else String.
static func coerce(text: String) -> Variant:
	if text == "true":
		return true
	if text == "false":
		return false
	if text.is_valid_int():
		return text.to_int()
	if text.is_valid_float():
		return text.to_float()
	return text


## Frames to wait before each capture.
static func wait_frames(opts: Dictionary) -> int:
	return int(opts["frames"]) + ceili(float(opts["seconds"]) * SNAP_FPS)


## One entry per capture: {"params": Dictionary for snap_setup, "file": String}.
## With no sweeps this is a single capture of the pass-through params.
static func plan(opts: Dictionary) -> Array[Dictionary]:
	var base := String(opts["scene"]).get_file().get_basename()
	if opts["tag"] != "":
		base += "_" + sanitize(String(opts["tag"]))
	var out: Array[Dictionary] = [{"params": opts["params"].duplicate(), "file": base}]
	for sweep: Array in opts["sweeps"]:
		var key: String = sweep[0]
		var next: Array[Dictionary] = []
		for entry in out:
			for v: String in sweep[1]:
				var params: Dictionary = entry["params"].duplicate()
				params[key] = coerce(v)
				next.append({"params": params, "file": "%s_%s-%s" % [entry["file"], sanitize(key), sanitize(v)]})
		out = next
	for entry in out:
		entry["file"] = String(opts["out"]).path_join(entry["file"] + ".png")
	return out


## Keeps filenames portable: anything but [A-Za-z0-9._-] becomes "_".
static func sanitize(text: String) -> String:
	var out := ""
	for c in text:
		var ok := (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c in "._-"
		out += c if ok else "_"
	return out


## Normalizes a scene argument to a res:// path.
static func scene_path(arg: String) -> String:
	if arg.begins_with("res://"):
		return arg
	return "res://" + arg.trim_prefix("./")
