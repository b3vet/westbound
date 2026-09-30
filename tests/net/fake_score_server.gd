extends "res://tests/net/fake_room_server.gd"
## The scripted room server plus N6 scoring (N6.2 tests): records every `score_claim` (in
## arrival order, decoded from the wire: what the real server would read) and builds the
## server's scoring messages (`score_sync`, `score_event`, `run_result` with the official
## score). Mirrors docs/SERVER.md → Scoring (N6.1). Not a test file.

var claims: Array[Dictionary] = []


func _handle(m: Dictionary) -> void:
	if established and String(m["type"]) == "score_claim":
		claims.append(m)
		return
	super._handle(m)


func sync_msg(tick: int, run_seq: int, banked: int, chain: int, banking: bool, crew: int = 0,
		night: bool = false, unverified: bool = false) -> Dictionary:
	return {"type": "score_sync", "tick": tick, "run_seq": run_seq, "banked": banked, "chain": chain,
		"multiplier_milli": 1000, "lives": 2, "crew_in_range": crew,
		"flags": {"banking": banking, "night": night, "unverified": unverified}}


func event_msg(tick: int, player_id: int, kind: String, points: int, link: int = 0, sector: int = 0,
		ref_id: int = 0) -> Dictionary:
	return {"type": "score_event", "tick": tick, "player_id": player_id, "kind": kind, "points": points,
		"multiplier_gain_milli": 2000 if kind == "train" else 0, "link": link, "sector": sector, "ref_id": ref_id}


func result_msg(player_id: int, run_seq: int, score: int, end_reason: String = "crashed", trains: int = 0,
		threads: int = 0) -> Dictionary:
	return {"type": "run_result", "player_id": player_id, "run_seq": run_seq, "end_reason": end_reason,
		"flags": {"verified": true, "leaderboard_eligible": true}, "score": score, "duration_ms": 60000,
		"distance_m": 2000, "passes": 10, "close_passes": 2, "cuts": 1, "threads": threads, "trains": trains,
		"max_multiplier_milli": 3000}
