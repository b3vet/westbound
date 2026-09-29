extends SceneTree
## The replay verifier's command line (the server's verification worker runs it; WP N8.1).
## Spec: multiplayer handoff → Leaderboards (single-player runs, step 4: a headless build
## of the same game plays the recorded path back), Resource budget (one job at a time,
## `nice 10`, 1 GB). docs/REPLAY_FORMAT.md → Verification; docs/SERVER.md → Replays.
##
##   tools/godot.sh --headless --path . --script res://tools/verifier/verify_replay.gd -- \
##       --replay=/data/replays/917.wbr --out=/tmp/917.json \
##       [--claimed-score=183200] [--claimed-hits=1] [--seed=2538700399935769545] [--server=off]
##
## `--key value` works as well as `--key=value`. The claims and the seed are the server's
## (the run row); left out, the replay header's are used. `--server=off` keeps an exported
## build's Net autoload from signing in.
##
## Writes the result JSON to --out (a temporary file renamed into place) and one summary
## line to stdout:
##   {"accepted": true, "reason": "accepted", "recomputed_score": 183150,
##    "claimed_score": 183200, "diff_pct": 0.027, "unreported_hits": 0, "violations": [], ...}
## Exit status: 0 accepted, 1 rejected, 2 bad arguments or an unreadable replay, 3 cannot
## be verified by this build (another tuning, an unknown car): not a verdict.

const EXIT_ACCEPTED := 0
const EXIT_REJECTED := 1
const EXIT_USAGE := 2
const EXIT_CANNOT := 3
## Loaded at run time, once the autoloads exist: a `--script` main loop is compiled before
## the autoloads are registered, so it cannot name classes that use them.
const REPLAY_FILE_PATH := "res://src/net/replay_file.gd"
const VERIFIER_PATH := "res://tools/verifier/replay_verifier.gd"


func _initialize() -> void:
	_main.call_deferred()


func _main() -> void:
	await process_frame
	var args := _args(OS.get_cmdline_user_args())
	var replay_path := String(args.get("replay", ""))
	var out_path := String(args.get("out", ""))
	if replay_path.is_empty():
		printerr("verify_replay: --replay=<file> is required")
		quit(EXIT_USAGE)
		return
	var bytes := FileAccess.get_file_as_bytes(replay_path)
	if bytes.is_empty():
		_finish({"error": "cannot read %s (%s)" % [replay_path, error_string(FileAccess.get_open_error())]},
			out_path, EXIT_USAGE)
		return
	var errs: Array[String] = []
	var replay: Variant = (load(REPLAY_FILE_PATH) as GDScript).call(&"decode", bytes, errs)
	if replay == null:
		_finish({"error": "unreadable replay: %s" % ", ".join(errs)}, out_path, EXIT_USAGE)
		return
	var v: Object = (load(VERIFIER_PATH) as GDScript).new(replay)
	v.set(&"claimed_score", _int_arg(args, "claimed-score"))
	v.set(&"claimed_hits", _int_arg(args, "claimed-hits"))
	v.set(&"expected_seed", _int_arg(args, "seed"))
	var res: Dictionary = v.call(&"verify", root)
	await process_frame
	if res.has("error"):
		_finish(res, out_path, EXIT_CANNOT)
		return
	_finish(res, out_path, EXIT_ACCEPTED if bool(res.get("accepted", false)) else EXIT_REJECTED)


func _finish(res: Dictionary, out_path: String, code: int) -> void:
	var text := JSON.stringify(res)
	if not out_path.is_empty():
		var tmp := out_path + ".tmp"
		var f := FileAccess.open(tmp, FileAccess.WRITE)
		if f == null:
			printerr("verify_replay: cannot write %s" % tmp)
			quit(EXIT_USAGE)
			return
		f.store_string(text)
		f.close()
		DirAccess.rename_absolute(tmp, out_path)
	print("verify_replay: %s reason=%s recomputed=%s claimed=%s diff_pct=%s unreported_hits=%s violations=%s" % [
		"accepted" if code == EXIT_ACCEPTED else ("rejected" if code == EXIT_REJECTED else "error"),
		res.get("reason", res.get("error", "")), res.get("recomputed_score", "-"), res.get("claimed_score", "-"),
		res.get("diff_pct", "-"), res.get("unreported_hits", "-"), res.get("violation_count", "-")])
	quit(code)


## `--key=value` and `--key value` pairs (keys without the dashes).
static func _args(raw: PackedStringArray) -> Dictionary:
	var out := {}
	var i := 0
	while i < raw.size():
		var a := raw[i]
		if a.begins_with("--"):
			var body := a.substr(2)
			var eq := body.find("=")
			if eq >= 0:
				out[body.left(eq)] = body.substr(eq + 1)
			elif i + 1 < raw.size() and not raw[i + 1].begins_with("--"):
				out[body] = raw[i + 1]
				i += 1
			else:
				out[body] = ""
		i += 1
	return out


static func _int_arg(args: Dictionary, key: String) -> int:
	var v := String(args.get(key, ""))
	return v.to_int() if v.is_valid_int() and v.to_int() >= 0 else -1
