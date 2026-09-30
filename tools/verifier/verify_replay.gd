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
##
## N8.2: the work is in verify_replay_main.gd (a Node), which the exported verifier runs
## through its main scene (export templates ignore `--script`); this script only adds it.

## Loaded at run time, once the autoloads exist: a `--script` main loop is compiled before
## the autoloads are registered, so it cannot name classes that use them.
const MAIN_PATH := "res://tools/verifier/verify_replay_main.gd"


func _initialize() -> void:
	_start.call_deferred()


func _start() -> void:
	root.add_child((load(MAIN_PATH) as GDScript).new() as Node)
