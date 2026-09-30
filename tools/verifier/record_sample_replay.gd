extends SceneTree
## Records a real replay headless: the Run scene with a weaving, boosting bot in real
## traffic, NetReplayRecorder on it, for --seconds (or until its crash). For the server's
## end-to-end test (westbound-server/crates/server/tests/replays.rs →
## end_to_end_with_the_godot_verifier) and for trying the verifier by hand. WP N8.1;
## docs/REPLAY_FORMAT.md.
##
##   tools/godot.sh --headless --path . --script res://tools/verifier/record_sample_replay.gd -- \
##       --out=/tmp/sample.wbr --claims=/tmp/sample.json [--seed=20260929] [--seconds=20] \
##       [--date=2026-09-29] [--car=0] [--server=off]
##
## --claims gets the run's submission numbers: {"seed", "score", "hits", "car",
## "client_build", "duration_s", "distance_m", "date"}.

const RUN_SCENE_PATH := "res://src/run/run.tscn"
const RECORDER_PATH := "res://src/net/replay_recorder.gd"
const BOT_PATH := "res://src/traffic/dev/sandbox_bot.gd"
const NET_TUNING_PATH := "res://src/core/tuning/net_tuning.gd"
const DEFAULT_SEED := 20260929
const DEFAULT_SECONDS := 20.0
const BOT_SEED := 11
const BOT_SPEED_MPS := 52.0
const TICKS_PER_FRAME := 2
const FRAME_S := 1.0 / 60.0
## The weaving mode of SandboxBot.Mode.
const WEAVE := 1
const STATE_RUNNING := &"running"


func _initialize() -> void:
	_main.call_deferred()


func _main() -> void:
	await process_frame
	var args := _args(OS.get_cmdline_user_args())
	var out_path := String(args.get("out", ""))
	if out_path.is_empty():
		printerr("record_sample_replay: --out=<file> is required")
		quit(2)
		return
	var run_seed := int(String(args.get("seed", str(DEFAULT_SEED))))
	var seconds := float(String(args.get("seconds", str(DEFAULT_SECONDS))))
	var date := String(args.get("date", Time.get_date_string_from_system(true)))
	var net: Resource = (load(NET_TUNING_PATH) as GDScript).call(&"load_default")
	var r: Node = (load(RUN_SCENE_PATH) as PackedScene).instantiate()
	r.set(&"run_seed", run_seed)
	r.set(&"manual_ticks", true)
	r.set(&"crash_cinematic", false)
	r.set(&"record_best", false)
	r.set(&"car_index", int(String(args.get("car", "0"))))
	root.add_child(r)
	var rec: Node = (load(RECORDER_PATH) as GDScript).new(net, int(net.get(&"client_build")))
	rec.set(&"auto_attach", false)
	root.add_child(rec)
	var car: Object = r.get(&"car")
	var bot: Object = (load(BOT_PATH) as GDScript).new(r.get(&"road"), r.get(&"sim").get(&"state"),
		car.get(&"params"), BOT_SEED)
	bot.set(&"mode", WEAVE)
	bot.set(&"v_target", BOT_SPEED_MPS)
	bot.set(&"length_m", car.get(&"car").get(&"length_m"))
	bot.set(&"width_m", car.get(&"car").get(&"width_m"))
	r.set(&"drive_controller", bot)
	r.call(&"go")
	rec.call(&"begin", r)
	var tuning: Object = r.get(&"tuning")
	var ticks := roundi(seconds * float(tuning.get(&"vehicle").get(&"physics_tick_hz")))
	for i in ticks:
		if r.get(&"state") != STATE_RUNNING:
			break
		r.call(&"tick")
		rec.call(&"capture")
		if int(r.get(&"tick_count")) % TICKS_PER_FRAME == 0:
			r.call(&"frame", FRAME_S)
	for i in TICKS_PER_FRAME * 2:
		r.call(&"tick")
		rec.call(&"capture")
		r.call(&"frame", FRAME_S)
	var stats: Object = r.get(&"stats")
	var score: int = r.get(&"scoring").call(&"banked")
	var hits: int = stats.get(&"hits")
	var results := {&"score": score, &"hits": hits, &"distance_m": stats.get(&"distance_m")}
	var bytes: PackedByteArray = rec.call(&"finish", results, date)
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null or bytes.is_empty():
		printerr("record_sample_replay: nothing recorded or cannot write %s" % out_path)
		quit(1)
		return
	f.store_buffer(bytes)
	f.close()
	var claims := {
		"seed": str(r.get(&"current_seed")), "score": score, "hits": hits,
		"car": String(car.get(&"car").get(&"id")), "client_build": int(net.get(&"client_build")),
		"duration_s": stats.get(&"duration_s"), "distance_m": stats.get(&"distance_m"), "date": date,
	}
	var claims_path := String(args.get("claims", ""))
	if not claims_path.is_empty():
		var c := FileAccess.open(claims_path, FileAccess.WRITE)
		c.store_string(JSON.stringify(claims))
		c.close()
	print("record_sample_replay: %d bytes, %s" % [bytes.size(), JSON.stringify(claims)])
	r.queue_free()
	rec.queue_free()
	await process_frame
	quit(0)


static func _args(raw: PackedStringArray) -> Dictionary:
	var out := {}
	for a in raw:
		if a.begins_with("--") and a.contains("="):
			var eq := a.find("=")
			out[a.substr(2, eq - 2)] = a.substr(eq + 1)
	return out
