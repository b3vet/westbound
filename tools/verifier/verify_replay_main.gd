extends Node
## The replay verifier's command line as a Node (WP N8.1; N8.2 moved it here from the
## SceneTree script so an exported build can run it: Godot's export templates ignore
## `--script`). Two ways in, the same arguments (docs/REPLAY_FORMAT.md → Verification):
##
##   tools/godot.sh --headless --path . --script res://tools/verifier/verify_replay.gd -- \
##       --replay=/data/replays/917.wbr --out=/tmp/917.json \
##       [--claimed-score=183200] [--claimed-hits=1] [--seed=2538700399935769545] [--server=off]
##       [--require-inputs=1]
##   /verifier/1/westbound --headless -- --verifier=1 --replay=... --out=... [...]
##       (the exported verifier, tools/verifier/export_verifier.sh: Run._ready hands its main
##       scene over to this node on `--verifier=1`)
##
## `--key value` works as well as `--key=value`. The claims and the seed are the server's
## (the run row); left out, the replay header's are used. `--server=off` keeps the Net
## autoload from signing in.
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
## Run._ready's hand-over flag for the exported verifier.
const BOOT_PARAM := "verifier"
## N8.3: refuse (exit 3) replays without the input stream instead of playing them back.
const REQUIRE_INPUTS := "require-inputs"


func _ready() -> void:
	name = "VerifyReplay"
	_main.call_deferred()


func _main() -> void:
	await get_tree().process_frame
	var args := parse_args(OS.get_cmdline_user_args())
	var replay_path := String(args.get("replay", ""))
	var out_path := String(args.get("out", ""))
	if replay_path.is_empty():
		printerr("verify_replay: --replay=<file> is required")
		get_tree().quit(EXIT_USAGE)
		return
	var bytes := FileAccess.get_file_as_bytes(replay_path)
	if bytes.is_empty():
		_finish({"error": "cannot read %s (%s)" % [replay_path, error_string(FileAccess.get_open_error())]},
			out_path, EXIT_USAGE)
		return
	var errs: Array[String] = []
	var replay := NetReplayFile.decode(bytes, errs)
	if replay == null:
		_finish({"error": "unreadable replay: %s" % ", ".join(errs)}, out_path, EXIT_USAGE)
		return
	var why := inputs_error(replay, args)
	if not why.is_empty():
		_finish({"error": why}, out_path, EXIT_CANNOT)
		return
	var v := ReplayVerifier.new(replay)
	v.claimed_score = int_arg(args, "claimed-score")
	v.claimed_hits = int_arg(args, "claimed-hits")
	v.expected_seed = int_arg(args, "seed")
	var res := v.verify(get_tree().root)
	await get_tree().process_frame
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
			get_tree().quit(EXIT_USAGE)
			return
		f.store_string(text)
		f.close()
		DirAccess.rename_absolute(tmp, out_path)
	print("verify_replay: %s reason=%s recomputed=%s claimed=%s diff_pct=%s unreported_hits=%s violations=%s playback=%s" % [
		"accepted" if code == EXIT_ACCEPTED else ("rejected" if code == EXIT_REJECTED else "error"),
		res.get("reason", res.get("error", "")), res.get("recomputed_score", "-"), res.get("claimed_score", "-"),
		res.get("diff_pct", "-"), res.get("unreported_hits", "-"), res.get("violation_count", "-"),
		res.get("playback", "-")])
	get_tree().quit(code)


## `--key=value` and `--key value` pairs (keys without the dashes).
static func parse_args(raw: PackedStringArray) -> Dictionary:
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


## N8.3: with `--require-inputs=1` (the production sidecar), a replay without the input
## stream (an N8.1 client's) is "cannot verify" instead of the kinematic playback, which
## rejects long honest runs (docs/DETERMINISM.md → Replays). Empty when it may be verified.
static func inputs_error(replay: NetReplayFile, args: Dictionary) -> String:
	if not args.has(REQUIRE_INPUTS) or String(args[REQUIRE_INPUTS]) in ["0", "false"] or replay.has_inputs():
		return ""
	return "no_inputs: the replay has no input stream (an N8.1 client); only re-simulation is trusted here"


static func int_arg(args: Dictionary, key: String) -> int:
	var v := String(args.get(key, ""))
	return v.to_int() if v.is_valid_int() and v.to_int() >= 0 else -1
