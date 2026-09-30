extends SceneTree
## Writes a tampered copy of a replay for the verifier image's smoke test (WP N8.3;
## docs/DETERMINISM.md → Verifier deploy): the second half of the recorded path moved
## ahead by --teleport-m (a teleport, as tests/verifier/test_verifier.gd's), the inputs and
## the header left as they were. The verifier must answer `rejected` (path_mismatch).
##
##   tools/godot.sh --headless --path . --script res://tools/verifier/tamper_replay.gd -- \
##       --in=/tmp/sample.wbr --out=/tmp/tampered.wbr [--teleport-m=20]

const DEFAULT_TELEPORT_M := 20.0
## Loaded at run time (a `--script` main loop cannot name classes that use autoloads).
const REPLAY_FILE_PATH := "res://src/net/replay_file.gd"
## NetReplayFile's position quantum (wire units per metre).
const Q_POS_NAME := "Q_POS"


func _initialize() -> void:
	_main.call_deferred()


func _main() -> void:
	var args := _args(OS.get_cmdline_user_args())
	var in_path := String(args.get("in", ""))
	var out_path := String(args.get("out", ""))
	if in_path.is_empty() or out_path.is_empty():
		printerr("tamper_replay: --in=<file> and --out=<file> are required")
		quit(2)
		return
	var teleport_m := float(String(args.get("teleport-m", str(DEFAULT_TELEPORT_M))))
	var replay_file: GDScript = load(REPLAY_FILE_PATH)
	var r: Object = replay_file.call(&"decode", FileAccess.get_file_as_bytes(in_path))
	if r == null:
		printerr("tamper_replay: %s is not a replay" % in_path)
		quit(1)
		return
	var n: int = r.get(&"sample_count")
	var s_q: PackedInt64Array = r.get(&"s_q")
	var shift := roundi(teleport_m * float(replay_file.get_script_constant_map()[Q_POS_NAME]))
	for i in range(n >> 1, n):
		s_q[i] += shift
	r.set(&"s_q", s_q)
	var bytes: PackedByteArray = r.call(&"encode")
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null or bytes.is_empty():
		printerr("tamper_replay: cannot write %s" % out_path)
		quit(1)
		return
	f.store_buffer(bytes)
	f.close()
	print("tamper_replay: %d of %d samples moved %.1f m ahead -> %s" % [n - (n >> 1), n, teleport_m, out_path])
	quit(0)


static func _args(raw: PackedStringArray) -> Dictionary:
	var out := {}
	for a in raw:
		if a.begins_with("--") and a.contains("="):
			var eq := a.find("=")
			out[a.substr(2, eq - 2)] = a.substr(eq + 1)
	return out
