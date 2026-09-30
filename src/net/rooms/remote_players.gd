class_name NetRemotePlayers
extends RefCounted
# lint: sim
## The other players' tracks: a fixed pool of NetRemoteTrack slots keyed by player id.
## Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Players ("The server relays every room
## member's state to everyone (at most 7 others)"; interpolation and extrapolation);
## docs/PROTOCOL.md §4 player_states. docs/ROOMS_CLIENT.md → Remote players. WP N5.2.
##
## Every slot and track is built once (capacity = NetTuning.room_max_remotes); a player
## takes a free slot on their first state and gives it back when they leave, and the
## next player reuses the same track object: no allocation after init. A full pool drops
## the extra players' states (`overflow`).

var capacity: int = 0
## Player id per slot (-1 = free).
var player_id := PackedInt32Array()
var tracks: Array[NetRemoteTrack] = []
## States that found no free slot.
var overflow: int = 0


func _init(slots: int, samples: int, loop_length_m: float, ticks_per_s: float, snap_distance_m: float) -> void:
	capacity = maxi(slots, 0)
	player_id.resize(capacity)
	player_id.fill(-1)
	for i in capacity:
		tracks.append(NetRemoteTrack.new(samples, loop_length_m, ticks_per_s, snap_distance_m))


## Slot of `pid`, or -1.
func slot_of(pid: int) -> int:
	for i in capacity:
		if player_id[i] == pid:
			return i
	return -1


## The slot for `pid`: its own, else a free one (cleared), else -1.
func acquire(pid: int) -> int:
	var i := slot_of(pid)
	if i >= 0:
		return i
	for k in capacity:
		if player_id[k] < 0:
			player_id[k] = pid
			tracks[k].clear()
			return k
	return -1


## The player left (or was kicked): the slot is free again.
func release(pid: int) -> void:
	var i := slot_of(pid)
	if i >= 0:
		player_id[i] = -1
		tracks[i].clear()


func clear() -> void:
	player_id.fill(-1)
	for t in tracks:
		t.clear()


## Occupied slots.
func active_count() -> int:
	var n := 0
	for i in capacity:
		if player_id[i] >= 0:
			n += 1
	return n


## Stores the frame's player_states entries of everyone but `you` (physical units).
## Allocation-free.
func ingest_into(frame: NetServerFrame, you: int) -> void:
	for k in frame.ps_count:
		var pid := frame.ps_player_id[k]
		if pid == you:
			continue
		var i := acquire(pid)
		if i < 0:
			overflow += 1
			continue
		tracks[i].push(frame.ps_tick[k], NetCodec.s_from_wire(frame.ps_s_mm[k]),
			NetCodec.d_from_wire(frame.ps_d_cm[k]), NetCodec.heading_from_wire(frame.ps_heading_e4[k]),
			NetCodec.speed_from_wire(frame.ps_speed_cms[k]), frame.ps_flags[k], frame.ps_run_state[k])


## Samples every occupied track at `render_tick` (see NetRemoteTrack.sample).
## Allocation-free.
func sample_all(render_tick: float, extrap_max_ticks: float, fade_ticks: float) -> void:
	for i in capacity:
		if player_id[i] >= 0:
			tracks[i].sample(render_tick, extrap_max_ticks, fade_ticks)
