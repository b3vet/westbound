class_name NetPlayerState
extends RefCounted
## One PlayerState in wire units (typed ints, no Dictionary): the 20 Hz upstream message and
## each `player_states` entry. Spec: multiplayer handoff → Networking protocol (quantization)
## and Players; docs/PROTOCOL.md §4 "PlayerState". WP N2.2.
##
## Build it from physical values with `set_physical()` (quantization mirrors quant.rs), then
## `NetCodec.push_player_state()` writes it without allocating. Reuse one instance per tick.

var tick: int = 0
var s_mm: int = 0
var d_cm: int = 0
var heading_e4: int = 0
var speed_cms: int = 0
var lat_vel_cms: int = 0
var yaw_rate_mrad_s: int = 0
var steer_e4: int = 0
## Bit set: NetCodec.PLAYER_FLAG_BRAKE | _BOOST | _HEADLIGHTS | _GHOST.
var flags: int = 0
## Index into NetCodec.RUN_STATE.
var run_state: int = 0


## Quantizes physical state (m, rad, m/s, rad/s, steer -1..1). `s_m` must already be wrapped
## into [0, loop length). Returns "" or the quantization error ("not_finite",
## "out_of_range"); on error the fields are unchanged.
func set_physical(tick_: int, s_meters: float, d_meters: float, heading_radians: float,
		speed_m_s: float, lat_vel_mps: float, yaw_rate_rad_s: float, steer: float,
		flag_bits: int, run_state_: int) -> String:
	var s := NetCodec.s_to_wire(s_meters)
	var d := NetCodec.d_to_wire(d_meters)
	var h := NetCodec.heading_to_wire(heading_radians)
	var v := NetCodec.speed_to_wire(speed_m_s)
	var lv := NetCodec.lat_vel_to_wire(lat_vel_mps)
	var yr := NetCodec.yaw_rate_to_wire(yaw_rate_rad_s)
	var st := NetCodec.steer_to_wire(steer)
	var bad := NetCodec.QUANT_INVALID
	if d == bad or h == bad or v == bad or lv == bad or yr == bad or st == bad:
		return NetCodec.E_NOT_FINITE
	if s == bad:
		return NetCodec.quant_error("s", s_meters)
	tick = tick_
	s_mm = s
	d_cm = d
	heading_e4 = h
	speed_cms = v
	lat_vel_cms = lv
	yaw_rate_mrad_s = yr
	steer_e4 = st
	flags = flag_bits
	run_state = run_state_
	return ""


## Protocol rules (messages.rs PlayerState): "" or the first error kind.
func validate() -> String:
	if tick < 0 or tick > NetCodec.U32_MAX or s_mm < 0 or s_mm > NetCodec.U32_MAX:
		return NetCodec.E_OUT_OF_RANGE
	if absi(d_cm) > NetCodec.MAX_ABS_D_CM or absi(heading_e4) > NetCodec.MAX_HEADING_E4:
		return NetCodec.E_OUT_OF_RANGE
	if speed_cms < 0 or speed_cms > NetCodec.MAX_SPEED_CMS:
		return NetCodec.E_OUT_OF_RANGE
	if absi(lat_vel_cms) > NetCodec.MAX_ABS_I16 or absi(yaw_rate_mrad_s) > NetCodec.MAX_ABS_I16:
		return NetCodec.E_OUT_OF_RANGE
	if absi(steer_e4) > NetCodec.MAX_STEER_E4:
		return NetCodec.E_OUT_OF_RANGE
	if flags < 0 or flags & ~NetCodec.PLAYER_FLAGS_MASK != 0:
		return NetCodec.E_RESERVED_BITS
	if run_state < 0 or run_state >= NetCodec.RUN_STATE.size():
		return NetCodec.E_INVALID_ENUM
	return ""


func s_m() -> float:
	return NetCodec.s_from_wire(s_mm)


func d_m() -> float:
	return NetCodec.d_from_wire(d_cm)


func heading_rad() -> float:
	return NetCodec.heading_from_wire(heading_e4)


func speed_mps() -> float:
	return NetCodec.speed_from_wire(speed_cms)


func has_flag(bit: int) -> bool:
	return flags & bit != 0


## Vector-JSON form (`{"type": "player_state", ...}` when `with_type`).
func to_dict(with_type: bool = true) -> Dictionary:
	var d := {
		"tick": tick, "s_mm": s_mm, "d_cm": d_cm, "heading_e4": heading_e4,
		"speed_cms": speed_cms, "lat_vel_cms": lat_vel_cms, "yaw_rate_mrad_s": yaw_rate_mrad_s,
		"steer_e4": steer_e4, "flags": NetCodec.bits_to_flags(flags, NetCodec.PLAYER_FLAGS),
		"run_state": NetCodec.RUN_STATE[run_state] if run_state >= 0
			and run_state < NetCodec.RUN_STATE.size() else "",
	}
	if with_type:
		d["type"] = "player_state"
	return d


## From the vector-JSON form. Returns "" or an error kind.
func from_dict(d: Dictionary) -> String:
	var keys := ["tick", "s_mm", "d_cm", "heading_e4", "speed_cms", "lat_vel_cms",
		"yaw_rate_mrad_s", "steer_e4", "flags", "run_state"]
	for k: String in keys:
		if not d.has(k):
			return NetCodec.E_MISSING_FIELD
	var fl: Variant = d["flags"]
	if not (fl is Dictionary):
		return NetCodec.E_INVALID_VALUE
	var bits := NetCodec.flags_to_bits(fl, NetCodec.PLAYER_FLAGS)
	var rs := NetCodec.RUN_STATE.find(d["run_state"])
	if bits < 0:
		return NetCodec.E_INVALID_VALUE
	if rs < 0:
		return NetCodec.E_INVALID_ENUM
	tick = int(d["tick"])
	s_mm = int(d["s_mm"])
	d_cm = int(d["d_cm"])
	heading_e4 = int(d["heading_e4"])
	speed_cms = int(d["speed_cms"])
	lat_vel_cms = int(d["lat_vel_cms"])
	yaw_rate_mrad_s = int(d["yaw_rate_mrad_s"])
	steer_e4 = int(d["steer_e4"])
	flags = bits
	run_state = rs
	return ""
