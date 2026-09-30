class_name NetScoreClient
extends RefCounted
## The client side of multiplayer scoring (N6.2): claims, the official score, crew
## proximity and trains. Spec: WESTBOUND_MULTIPLAYER_HANDOFF.md → Scoring in multiplayer
## (server-authoritative scoring: "the client detects events locally for instant feedback,
## and the server keeps the official score"; claims; score sync: "the client eases its
## display to the server's values at banking moments, so corrections never look like score
## being taken away mid-chain"; crew mechanics: proximity +0.25× per crewmate within 30 m,
## capped at ×2, trains, the session crew total), Client changes (`score_client.gd`: claims,
## hit reports, score sync, crew and train feedback). Contract: docs/SERVER.md → Scoring
## (N6.1) → Claims; docs/PROTOCOL.md §4 (`score_claim`, `score_sync`, `score_event`).
## docs/ROOMS_CLIENT.md → Scoring in a room. WP N6.2.
##
## RunRoom owns one per room run. The run's own Scoring (src/scoring/, unchanged) scores the
## network cars; this reads its events:
##
##   score.wire_id = src.car_id     # N4.3's NetworkTrafficSource: slot -> wire car id
##   score.observe(events, from, to, tick, player_d, traffic, total)   # per 120 Hz tick
##   score.flush()                  # per frame: the queued claims go up
##   score.advance(dt)              # per frame: the display offset eases, the train badge ages
##   score.display_offset()         # add to the local banked total on the HUD
##
## - **Claims** (SERVER.md's table): a pass or close pass at the tick it was paid, the car's
##   wire id and its measured minimum clearance, its side (the car's d against the car's
##   then); a thread at the second pass's tick, after that pass's own claim, naming the first
##   car (the most recent unused opposite-side pass under the thread clearance) and the second
##   one, each with its clearance, the first car's side; a cut at its tick, the nearest car,
##   clearance 0, side none. In event order. Cars the client was not streamed (the local
##   director before the server's traffic arrives) are never claimed. Queued in pre-sized
##   arrays in the tick (no allocation), sent from the frame.
## - **Official score:** every `score_sync` is compared with the local total (banked + chain)
##   this client had at `sync.tick` (a ring per room tick): the difference is the official
##   correction. It is applied only at banking moments (`flags.banking`), eased in (up within
##   score_ease_up_s, down over score_ease_down_s), so the display never loses points
##   mid-chain nor jumps back. A new run starts from no correction; syncs dated before the
##   local run started describe the run before and are ignored.
## - **Crew:** crewmates (same crew slot) driving within crew_range_m along the loop, from
##   the remote tracks each frame: the factor 1 + 0.25 n, capped (instant; the server's
##   `crew_in_range` comes 1.5 s late and is kept as `official_crew_in_range`).
## - **Trains:** `score_event.train` for this player counts the run's trains and shows
##   TRAIN ×n (signal `train`); a crewmate's goes to `crew_train`.
## - **Sectors:** the loop run pays its own sector bonuses (the sector toast); an official
##   sector bonus the local run did not pay (same kind within sector_match_s) is signalled
##   (`sector_bonus`) for the event stack.

## One of this player's train links (TRAIN ×link) and its points.
signal train(link: int, points: int)
## A crewmate's train link (score events go to the whole crew).
signal crew_train(player_id: int, link: int)
## An official sector bonus the local run did not pay: bonus kind (LegTracker.BONUS_*),
## points, the sector completed (1-based).
signal sector_bonus(kind: StringName, points: int, sector: int)
## The server rejected a claim (dev HUD).
signal claim_rejected(claim_id: int)

## NetCodec.CLAIM_KIND and SIDE indices.
const CLAIM_PASS := 0
const CLAIM_CLOSE_PASS := 1
const CLAIM_CUT := 2
const CLAIM_THREAD := 3
const SIDE_NONE := 0
const SIDE_LEFT := 1
const SIDE_RIGHT := 2
const MM_PER_M := 1000.0   # lint: allow-number unit conversion
const MILLI := 1000.0   # lint: allow-number wire milli units
## The official sector bonus kinds, in LegTracker's bonus order.
const SECTOR_EVENTS: Array[String] = ["sector_clean", "sector_pace", "sector_threads", "sector_heat"]
const SECTOR_BONUSES: Array[StringName] = [LegTracker.BONUS_CLEAN, LegTracker.BONUS_PACE,
	LegTracker.BONUS_THREADS, LegTracker.BONUS_HEAT]

var session: NetRoomSession
var net: NetTuning
var tick_rate: float = 20.0
## The local rules' thread clearance (a thread's first car passed under it).
var thread_clearance_m: float = 1.5
## (slot: int) -> int: the wire car id of a TrafficState slot (NetworkTrafficSource.car_id);
## not valid (no network traffic yet): nothing is claimed.
var wire_id: Callable

## Claims queued, sent, not made (no wire id: a local car), dropped (queue full or not in
## the room), rejected by the server, threads whose first car was not found.
var claims_queued: int = 0
var claims_sent: int = 0
var claims_skipped: int = 0
var claims_dropped: int = 0
var claims_rejected: int = 0
var threads_unmatched: int = 0
var last_claim_id: int = 0

## The newest score_sync: its tick (the official timeline), run, values.
var syncs: int = 0
var official_tick: int = -1
var official_run_seq: int = -1
var official_banked: int = 0
var official_chain: int = 0
var official_multiplier: float = 1.0
var official_lives: int = 0
var official_crew_in_range: int = 0
var official_night: bool = false
var unverified: bool = false
## The official total minus the local one at the newest comparable sync (dev HUD).
var pending_offset: int = 0
## The correction being eased in, and where the easing stands.
var offset_target: float = 0.0
var offset_shown: float = 0.0

## Crewmates within range now and the crew factor.
var crew_in_range: int = 0
var crew_factor: float = 1.0
## This run's train links and the newest link (the badge), and how long the badge stays.
var run_trains: int = 0
var last_link: int = 0
var train_left_s: float = 0.0

# Claim queue (structure of arrays, pre-sized).
var _q_kind := PackedInt32Array()
var _q_tick := PackedInt64Array()
var _q_side := PackedInt32Array()
var _q_n := PackedInt32Array()
var _q_car0 := PackedInt32Array()
var _q_clr0 := PackedInt32Array()
var _q_car1 := PackedInt32Array()
var _q_clr1 := PackedInt32Array()
var _q_len: int = 0

# Recent passes (a ring): car, tick, side, clearance (mm and m), used by a thread.
var _rp_car := PackedInt32Array()
var _rp_tick := PackedInt64Array()
var _rp_side := PackedInt32Array()
var _rp_clr := PackedInt32Array()
var _rp_clr_m := PackedFloat64Array()
var _rp_used := PackedByteArray()
var _rp_head: int = 0
var _thread_ticks: int = 0

# The local total (banked + chain) per room tick: a ring keyed by tick.
var _h_total := PackedInt64Array()
var _h_tick := PackedInt64Array()
var _h_last_tick: int = -1
var _h_last_total: int = 0
var _run_start_tick: int = 0
var _offset_rate: float = 0.0

# When the local run last paid each sector bonus kind (room tick; -1 never).
var _local_bonus_tick := PackedInt64Array()

# Reused message dictionaries (claims go up from the frame, not the tick).
var _car_a := {"car_id": 0, "clearance_mm": 0}
var _car_b := {"car_id": 0, "clearance_mm": 0}
var _cars_one: Array = [_car_a]
var _cars_two: Array = [_car_a, _car_b]
var _msg := {"type": "score_claim", "claim_id": 0, "tick": 0, "kind": "pass", "side": "none", "cars": _cars_one}
var _one: Array = [_msg]


func _init(room_session: NetRoomSession, net_tuning: NetTuning, thread_clearance: float = 1.5) -> void:
	session = room_session
	net = net_tuning
	thread_clearance_m = thread_clearance
	tick_rate = room_session.room.tick_rate if room_session != null else net_tuning.tick_rate_hz
	var q := maxi(net.score_claim_queue, 1)
	_q_kind.resize(q)
	_q_side.resize(q)
	_q_n.resize(q)
	_q_car0.resize(q)
	_q_clr0.resize(q)
	_q_car1.resize(q)
	_q_clr1.resize(q)
	_q_tick.resize(q)
	var r := maxi(net.score_recent_passes, 2)
	_rp_car.resize(r)
	_rp_tick.resize(r)
	_rp_side.resize(r)
	_rp_clr.resize(r)
	_rp_clr_m.resize(r)
	_rp_used.resize(r)
	var h := maxi(ceili(net.score_history_s * tick_rate), 2)
	_h_total.resize(h)
	_h_tick.resize(h)
	_local_bonus_tick.resize(SECTOR_BONUSES.size())
	_thread_ticks = ceili(net.score_thread_match_s * tick_rate)
	reset_run(0)
	if session != null:
		session.client.frame_received.connect(_on_frame)


## Lets go of the session's signal (the run leaves the room).
func detach() -> void:
	if session != null and session.client.frame_received.is_connected(_on_frame):
		session.client.frame_received.disconnect(_on_frame)


## A fresh local run started at room tick `tick` (a join's or a respawn's placement): no
## correction, no recent passes, no trains; syncs dated before it are the run before.
func reset_run(tick: int) -> void:
	_run_start_tick = tick
	offset_target = 0.0
	offset_shown = 0.0
	_offset_rate = 0.0
	pending_offset = 0
	_rp_used.fill(1)
	_rp_head = 0
	_h_tick.fill(-1)
	_h_last_tick = -1
	_h_last_total = 0
	_local_bonus_tick.fill(-1)
	run_trains = 0
	last_link = 0
	train_left_s = 0.0
	_q_len = 0


# ---------------------------------------------------------------- Tick (allocation-free)

## The run's events [from, to) of one 120 Hz tick at room tick `tick` (the first room tick
## at or after the sim tick's instant), with the car's d and the traffic they refer to
## (wire ids from `wire_id`); `total` is the local banked + chain after that tick.
## Allocation-free.
func observe(events: ScoreEventBuffer, from: int, to: int, tick: int, player_d: float,
		traffic: TrafficState, total: int) -> void:
	for i in range(from, to):
		var k := events.kind[i]
		if k == ScoreEvents.PASS or k == ScoreEvents.CLOSE_PASS:
			_on_pass(k == ScoreEvents.CLOSE_PASS, events.slot[i], events.clearance_m[i], tick, player_d, traffic)
		elif k == ScoreEvents.THREAD:
			_on_thread(events.slot[i], tick, traffic)
		elif k == ScoreEvents.CUT:
			var car := _wire_id(events.slot[i], traffic)
			if car > 0:
				_enqueue(CLAIM_CUT, tick, SIDE_NONE, car, 0, 0, 0, 1)
			else:
				claims_skipped += 1
		elif k == ScoringRuleSet.KIND_BONUS:
			var b := SECTOR_BONUSES.find(events.tag[i])
			if b >= 0:
				_local_bonus_tick[b] = tick
	_record(tick, total)


func _on_pass(close: bool, slot: int, clearance: float, tick: int, player_d: float, traffic: TrafficState) -> void:
	var car := _wire_id(slot, traffic)
	if car <= 0:
		claims_skipped += 1
		return
	var side := SIDE_RIGHT if traffic.d[slot] >= player_d else SIDE_LEFT
	var mm := _mm(clearance)
	var r := _rp_head
	_rp_car[r] = car
	_rp_tick[r] = tick
	_rp_side[r] = side
	_rp_clr[r] = mm
	_rp_clr_m[r] = clearance
	_rp_used[r] = 0
	_rp_head = (r + 1) % _rp_car.size()
	_enqueue(CLAIM_CLOSE_PASS if close else CLAIM_PASS, tick, side, car, mm, 0, 0, 1)


## A thread: the second car is the one whose pass was just paid (Scoring writes the pass,
## then the thread); the first is the most recent unused pass on the other side.
func _on_thread(slot: int, tick: int, traffic: TrafficState) -> void:
	var car := _wire_id(slot, traffic)
	if car <= 0:
		claims_skipped += 1
		return
	var n := _rp_car.size()
	var second := -1
	for j in n:
		var r := (_rp_head - 1 - j + n) % n
		if _rp_used[r] == 0 and _rp_car[r] == car:
			second = r
			break
	if second < 0:
		threads_unmatched += 1
		return
	var first := -1
	for j in n:
		var r := (_rp_head - 1 - j + n) % n
		if r == second or _rp_used[r] != 0 or _rp_car[r] == car or _rp_side[r] == _rp_side[second]:
			continue
		if absi(tick - _rp_tick[r]) > _thread_ticks or _rp_clr_m[r] >= thread_clearance_m:
			continue
		first = r
		break
	if first < 0:
		threads_unmatched += 1
		return
	_rp_used[first] = 1
	_rp_used[second] = 1
	_enqueue(CLAIM_THREAD, tick, _rp_side[first], _rp_car[first], _rp_clr[first], _rp_car[second],
		_rp_clr[second], 2)


func _wire_id(slot: int, traffic: TrafficState) -> int:
	if not wire_id.is_valid() or slot < 0 or slot >= traffic.capacity or traffic.active[slot] == 0:
		return -1
	return int(wire_id.call(slot))


func _enqueue(kind: int, tick: int, side: int, car0: int, clr0: int, car1: int, clr1: int, n: int) -> void:
	if _q_len >= _q_kind.size():
		claims_dropped += 1
		return
	var q := _q_len
	_q_kind[q] = kind
	_q_tick[q] = maxi(tick, 0)
	_q_side[q] = side
	_q_n[q] = n
	_q_car0[q] = car0
	_q_clr0[q] = clr0
	_q_car1[q] = car1
	_q_clr1[q] = clr1
	_q_len += 1
	claims_queued += 1


static func _mm(m: float) -> int:
	return clampi(roundi(m * MM_PER_M), 0, NetCodec.U16_MAX)


## The local total after the ticks up to `tick` (skipped ticks keep the total before).
func _record(tick: int, total: int) -> void:
	var n := _h_tick.size()
	if _h_last_tick >= 0 and tick > _h_last_tick:
		var from := maxi(_h_last_tick + 1, tick - n + 1)
		for t in range(from, tick):
			_h_tick[t % n] = t
			_h_total[t % n] = _h_last_total
	if tick >= _h_last_tick:
		_h_tick[tick % n] = tick
		_h_total[tick % n] = total
		_h_last_tick = tick
		_h_last_total = total


## The local total (banked + chain) this client had at room tick `tick`; -1 when the ring
## no longer holds it (or never did).
func local_total_at(tick: int) -> int:
	if _h_last_tick < 0 or tick < 0:
		return -1
	if tick > _h_last_tick:
		return _h_last_total
	var i := tick % _h_tick.size()
	return _h_total[i] if _h_tick[i] == tick else -1


# ---------------------------------------------------------------- Frame

## Sends the queued claims (in event order), one small frame each. Not in a room (the
## connection is reconnecting): they are dropped (the server would not see those passes).
func flush() -> void:
	if _q_len == 0:
		return
	if session == null or not session.is_in_room():
		claims_dropped += _q_len
		_q_len = 0
		return
	for q in _q_len:
		last_claim_id = (last_claim_id % NetCodec.U16_MAX) + 1
		_msg["claim_id"] = last_claim_id
		_msg["tick"] = _q_tick[q]
		_msg["kind"] = NetCodec.CLAIM_KIND[_q_kind[q]]
		_msg["side"] = NetCodec.SIDE[_q_side[q]]
		_car_a["car_id"] = _q_car0[q]
		_car_a["clearance_mm"] = _q_clr0[q]
		if _q_n[q] == 2:
			_car_b["car_id"] = _q_car1[q]
			_car_b["clearance_mm"] = _q_clr1[q]
			_msg["cars"] = _cars_two
		else:
			_msg["cars"] = _cars_one
		if session.client.send_messages(_one) == "":
			claims_sent += 1
		else:
			claims_dropped += 1
	_q_len = 0


## Claims waiting for flush().
func queued() -> int:
	return _q_len


## The claim at queue position q as the wire's vector JSON (tests, dev).
func queued_claim(q: int) -> Dictionary:
	var cars: Array = [{"car_id": _q_car0[q], "clearance_mm": _q_clr0[q]}]
	if _q_n[q] == 2:
		cars.append({"car_id": _q_car1[q], "clearance_mm": _q_clr1[q]})
	return {"tick": _q_tick[q], "kind": NetCodec.CLAIM_KIND[_q_kind[q]], "side": NetCodec.SIDE[_q_side[q]],
		"cars": cars}


## Per frame: the display correction eases toward its target, the train badge ages.
func advance(dt: float) -> void:
	if offset_shown != offset_target:
		var step := _offset_rate * dt
		if offset_shown < offset_target:
			offset_shown = minf(offset_shown + step, offset_target)
		else:
			offset_shown = maxf(offset_shown - step, offset_target)
	if train_left_s > 0.0:
		train_left_s = maxf(train_left_s - dt, 0.0)


## Points to add to the local banked total on the HUD (the official correction, eased).
func display_offset() -> int:
	return roundi(offset_shown)


## The TRAIN ×n badge is showing.
func train_shown() -> bool:
	return train_left_s > 0.0 and last_link > 0


## Crewmates within crew_range_m of `my_s` (wrapped) along the loop, from the remote tracks
## as sampled this frame: those in this player's crew slot whose run is going. Sets
## crew_in_range and crew_factor.
func update_crew(remotes: NetRemotePlayers, room: NetRoomState, my_s: float, loop_length: float) -> void:
	var me := room.me()
	var n := 0
	if me != null:
		for i in remotes.capacity:
			var pid := remotes.player_id[i]
			if pid < 0 or pid == room.you:
				continue
			var t := remotes.tracks[i]
			if t.alpha <= 0.0 or (t.run_state != NetRoomSession.RUN_DRIVING and t.run_state != NetRoomSession.RUN_PROTECTED):
				continue
			var m := room.member(pid)
			if m == null or m.crew_slot != me.crew_slot:
				continue
			var ds := fposmod(t.s - my_s, loop_length) if loop_length > 0.0 else t.s - my_s
			if loop_length > 0.0 and ds > loop_length * 0.5:
				ds -= loop_length
			if absf(ds) <= net.crew_range_m:
				n += 1
	set_crew(n)


func set_crew(n: int) -> void:
	crew_in_range = n
	crew_factor = factor_for(n, net)


## The crew factor for `n` crewmates in range (spec: +0.25× each, capped at ×2.0).
static func factor_for(n: int, t: NetTuning) -> float:
	return minf(1.0 + t.crew_bonus_per_mate * float(maxi(n, 0)), t.crew_factor_cap)


## The session crew total of this player's crew (room_snapshot.crews / room_event.crew).
func crew_total() -> int:
	var me := session.room.me() if session != null else null
	if me == null:
		return 0
	return int(session.room.crew_totals.get(me.crew_slot, 0))


# ---------------------------------------------------------------- Server messages

func _on_frame(frame: NetServerFrame) -> void:
	if not session.is_in_room():
		return
	for msg in frame.messages:
		var type := String(msg.get("type", ""))
		if type == "score_sync" or type == "score_event":
			on_message(msg)


## A `score_sync` or `score_event` (vector JSON).
func on_message(msg: Dictionary) -> void:
	match String(msg.get("type", "")):
		"score_sync":
			_on_sync(msg)
		"score_event":
			_on_event(msg)


func _on_sync(msg: Dictionary) -> void:
	var seq := int(msg.get("run_seq", 0))
	if seq < official_run_seq:
		return   # a late sync of a run that is over
	syncs += 1
	var tick := int(msg.get("tick", 0))
	var f: Dictionary = msg.get("flags", {})
	official_tick = tick
	official_run_seq = seq
	official_banked = int(msg.get("banked", 0))
	official_chain = int(msg.get("chain", 0))
	official_multiplier = float(int(msg.get("multiplier_milli", 0))) / MILLI
	official_lives = int(msg.get("lives", 0))
	official_crew_in_range = int(msg.get("crew_in_range", 0))
	official_night = bool(f.get("night", false))
	unverified = bool(f.get("unverified", false))
	if tick < _run_start_tick:
		return   # dated before this local run: the run before
	var local := local_total_at(tick)
	if local < 0:
		return
	pending_offset = official_banked + official_chain - local
	if bool(f.get("banking", false)):
		set_offset_target(float(pending_offset))


## The correction to ease to: up within score_ease_up_s, down over score_ease_down_s.
func set_offset_target(v: float) -> void:
	offset_target = v
	var up := v > offset_shown
	var secs := net.score_ease_up_s if up else net.score_ease_down_s
	_offset_rate = absf(v - offset_shown) / maxf(secs, 1.0 / tick_rate)


func _on_event(msg: Dictionary) -> void:
	var kind := String(msg.get("kind", ""))
	var pid := int(msg.get("player_id", -1))
	var you := session.room.you if session != null else pid
	match kind:
		"claim_rejected":
			if pid == you:
				claims_rejected += 1
				claim_rejected.emit(int(msg.get("ref_id", 0)))
		"train":
			var link := int(msg.get("link", 0))
			if pid == you:
				run_trains += 1
				last_link = link
				train_left_s = net.train_show_s
				train.emit(link, int(msg.get("points", 0)))
			else:
				crew_train.emit(pid, link)
		_:
			var b := SECTOR_EVENTS.find(kind)
			if b < 0 or pid != you:
				return
			var tick := int(msg.get("tick", 0))
			var local := _local_bonus_tick[b]
			if local >= 0 and absi(tick - local) <= ceili(net.sector_match_s * tick_rate):
				return   # the local run paid it: the sector toast showed it
			sector_bonus.emit(SECTOR_BONUSES[b], int(msg.get("points", 0)), int(msg.get("sector", 0)))
