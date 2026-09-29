class_name NetRunSubmission
extends RefCounted
## One finished run on its way to the server, and the receipt that came back. Spec:
## multiplayer handoff → Leaderboards → Single-player runs (summary, plausibility checks,
## "the score shows as verifying until checked"); docs/SERVER.md → POST /runs. WP N7.2;
## docs/NET_CLIENT.md → Runs client.
##
## NetRunsClient makes one per run_over and updates it; the results screen shows it.
## `results` is the run_over payload itself (the results screen finds its run by it).

enum State {
	## Stored on the device, waiting for the session, the network or a 429 to pass.
	QUEUED,
	## The request is out.
	SENDING,
	## The server took it (`verification` pending / unverified / verified).
	DONE,
	## The server stored it but refused it (`reason`: build_unsupported, score_rate...).
	REJECTED,
	## The server refused the request itself (a 4xx other than auth); dropped.
	FAILED,
	## Too old for the server's date window, or pushed out of a full queue; dropped.
	EXPIRED,
}

## Why a QUEUED run waits.
const WAIT_OFFLINE := "offline"
const WAIT_RATE_LIMITED := "rate_limited"
const WAIT_SIGN_IN := "sign_in"
const WAIT_BANNED := "banned"

const REASON_BUILD := "build_unsupported"
const VERIFICATION_PENDING := "pending"
const VERIFICATION_REJECTED := "rejected"
const PERIOD_ALL := "all"

var key: String = ""
var mode: String = ""
## The UTC date sent with the run (the Daily board's period).
var date: String = ""
var results: Dictionary = {}
var state: State = State.QUEUED
var waiting: String = WAIT_OFFLINE
## The last failure's code (NetApiResult.error).
var error: String = ""
## The receipt (the 201 / 200 body).
var receipt: Dictionary = {}
var run_id: String = ""
var verification: String = ""
var verifying: bool = false
var replay_required: bool = false
var duplicate: bool = false
var reason: String = ""
var placements: Array[Dictionary] = []


## Takes a receipt (201, or 200 with `duplicate: true`).
func apply_receipt(body: Dictionary) -> void:
	receipt = body
	run_id = NetApiResult.as_id(body.get("run_id", ""))
	verification = NetApiResult.as_id(body.get("verification", ""))
	verifying = bool(body.get("verifying", false)) or verification == VERIFICATION_PENDING
	replay_required = bool(body.get("replay_required", false))
	duplicate = bool(body.get("duplicate", false))
	var r: Variant = body.get("reason")
	reason = r if r is String else ""
	placements.clear()
	var ps: Variant = body.get("placements", [])
	if ps is Array:
		for p: Variant in ps:
			if p is Dictionary:
				placements.append(p as Dictionary)
	state = State.REJECTED if verification == VERIFICATION_REJECTED else State.DONE
	error = ""
	waiting = ""


func is_done() -> bool:
	return state == State.DONE


func update_required() -> bool:
	return state == State.REJECTED and reason == REASON_BUILD


## The placement on `board` / `period` ({} when the receipt has none). `period` "" = any.
func placement(board: String, period: String = "") -> Dictionary:
	for p in placements:
		if String(p.get("board", "")) == board and (period.is_empty() or String(p.get("period", "")) == period):
			return p
	return {}


## The placements of the run's own mode, in the server's order (Journey: the week, then
## all time; Daily: the date).
func mode_placements() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p in placements:
		if String(p.get("board", "")) == mode:
			out.append(p)
	return out


## A new personal best: the run improved the mode's all-time entry (Journey) or the
## day's entry (Daily Drive).
func new_pb() -> bool:
	for p in mode_placements():
		var period := String(p.get("period", ""))
		if bool(p.get("improved", false)) and (period == PERIOD_ALL or mode == NetRunPayload.MODE_DAILY):
			return true
	return false


## The run improved the player's Distance entry.
func distance_pb() -> bool:
	return bool(placement("distance", PERIOD_ALL).get("improved", false))


static func rank_of(p: Dictionary) -> int:
	var r: Variant = p.get("rank")
	if r is int or r is float:
		return int(r)
	return 0
