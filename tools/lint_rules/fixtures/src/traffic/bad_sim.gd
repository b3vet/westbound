extends Node3D # expect: WB103
## A sim file (src/traffic/*.gd) breaking every sim rule.

const MAX_VEHICLES := 60
const GRAVITY := 9.81 # expect: WB101
const FLAG_BRAKING := 1 << 3

var _v := PackedFloat64Array()


func accelerate(v: float, gap: float) -> float:
	var a := 1.7 * (1.0 - pow(v / 33.3, 4)) # expect: WB101, WB105
	if gap < 12 && v > 3: # expect: WB101
		a -= 0x10 # expect: WB101
	return a + 1e-6 # expect: WB101


func escapes(v: float) -> float:
	var kmh := v * 3.6 # lint: allow-number unit conversion for the debug readout
	var bad := v * 7.5 # lint: allow-number # expect: WB100, WB101
	return kmh + bad # lint: allow-numbers typo # expect: WB100


func nondeterministic() -> float:
	randomize() # expect: WB102
	var r := randf() + randf_range(0.0, 2.0) # expect: WB102
	var g := RandomNumberGenerator.new() # expect: WB102
	var t := Time.get_ticks_usec() # expect: WB102
	var f := Engine.get_physics_frames() # expect: WB102
	var h := "lane".hash() # expect: WB102
	return r + g.randf() + t + f + h + get_physics_process_delta_time() # expect: WB102


func impure() -> void:
	var tree := get_tree() # expect: WB103
	var car := $Car # expect: WB103
	Events.emit_signal("pass") # expect: WB103
	if Input.is_action_pressed("boost"): # expect: WB103
		Game.change_state(&"menu") # expect: WB103
	print(tree, car)


func step(dt: float) -> void:
	var tmp := [] # expect: WB104
	var d := {} # expect: WB104
	var names := PackedStringArray() # expect: WB104
	var label := "v=%f" % dt # expect: WB104
	var copy := _v.duplicate() # expect: WB104
	var o := RefCounted.new() # expect: WB104
	var s := str(dt) # expect: WB104
	var cb := func(x: float) -> float: return x # expect: WB104
	var ok := _v[0] + tmp.size() # indexing is fine
	var pre := [1] # lint: allow-alloc once per run, guarded by a flag
	print(d, names, label, copy, o, s, cb, ok, pre)


func fill_into(out: PackedFloat64Array) -> void:
	out.append_array([0.0]) # expect: WB104


func platform_math(yaw: float, v: float, v_lat: float) -> float:
	var c := cos(yaw) + sin(yaw) # expect: WB105
	var k := atan2(v_lat, v) + exp(-v) # expect: WB105
	var r := Vector2(v, v_lat).angle() # expect: WB105
	var p := sin(yaw) # lint: allow-libm # expect: WB100, WB105
	var ok := DetMath.sin(yaw) + DetMath.atan2(v_lat, v) + DetMath.exp(-v)
	var drawn := cos(yaw) # lint: allow-libm rendering only, never fed back
	return c + k + r + p + ok + drawn
