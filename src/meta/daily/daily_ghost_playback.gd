class_name DailyGhostPlayback
extends RefCounted
# lint: sim
## Plays a Daily Drive ghost back in road space: the pose at any RUNNING tick, linear
## between the 20 Hz samples. Spec: Core loop → Modes at launch ("shown as a translucent
## ghost car on later attempts"). WP8.4; docs/DAILY.md → Playback.
##
##   playback.setup(ghost)
##   if playback.pose_into(k, pose):   # k = RUNNING ticks since GO (may be fractional)
##       ... pose.s, pose.d, pose.yaw, pose.v, pose.flags, pose.forks_done
##
## - Before the first sample the ghost waits at it (the grid); after the last one it is
##   gone (pose_into returns false: the ghost's run ended there).
## - A sample flagged as a jump (a fork swap to the right branch, a safety-net reset) is
##   never interpolated into: the pose holds the sample before it (recorded one tick
##   earlier) until the jump's tick.
## - `forks_done`: how many of the ghost's forks resolved at or before k (the caller maps
##   the ghost onto the player's road: DailyDrive.path_for).
## Cursors make the usual forward playback O(1) per call; going back (a retry) rewinds.
## pose_into allocates nothing.

class Pose:
	extends RefCounted
	var s: float = 0.0
	var d: float = 0.0
	var yaw: float = 0.0
	var v: float = 0.0
	var flags: int = 0
	var forks_done: int = 0

var ghost: DailyGhost
var _i: int = 0
var _f: int = 0


func setup(g: DailyGhost) -> void:
	ghost = g
	_i = 0
	_f = 0


## True with a ghost that has samples.
func has_ghost() -> bool:
	return ghost != null and ghost.sample_count > 0


## The pose at RUNNING tick `k`. False when there is no ghost or its run ended before k.
func pose_into(k: float, out: Pose) -> bool:
	if ghost == null or ghost.sample_count == 0:
		return false
	var g := ghost
	var n := g.sample_count
	if k > float(g.tick[n - 1]):
		return false
	# Sample cursor: tick[_i] <= k < tick[_i + 1] (or _i = 0 before the first sample).
	_i = clampi(_i, 0, n - 1)
	while _i > 0 and float(g.tick[_i]) > k:
		_i -= 1
	while _i + 1 < n and float(g.tick[_i + 1]) <= k:
		_i += 1
	var a := _i
	var b := mini(a + 1, n - 1)
	var ta := float(g.tick[a])
	var tb := float(g.tick[b])
	var u := 0.0
	if b != a and k > ta and (int(g.flags[b]) & DailyGhost.JUMP_FLAGS) == 0 and tb > ta:
		u = (k - ta) / (tb - ta)
	out.s = lerpf(g.s_at(a), g.s_at(b), u)
	out.d = lerpf(g.d_at(a), g.d_at(b), u)
	out.yaw = lerpf(g.yaw_at(a), g.yaw_at(b), u)
	out.v = lerpf(g.v_at(a), g.v_at(b), u)
	out.flags = int(g.flags[a])
	# Fork cursor: forks resolved at or before k.
	_f = clampi(_f, 0, g.fork_count)
	while _f > 0 and float(g.fork_tick[_f - 1]) > k:
		_f -= 1
	while _f < g.fork_count and float(g.fork_tick[_f]) <= k:
		_f += 1
	out.forks_done = _f
	return true
