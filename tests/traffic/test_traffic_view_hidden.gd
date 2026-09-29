extends WBTest
## TrafficView.set_slot_hidden (WP4.2): the crash sequence draws the hit car on a
## physics body and hides it in the view. Spec: Lives, hits and crashes → Second hit
## (run over). Contracts §5 (the view reads TrafficState read-only), §14.

const SEED := 20260929
const S0 := 100.0
const SPEED_MPS := 30.0
const GAP_M := 30.0

var _ctx: RunContext
var _road: StraightRoadPath
var _reg: TrafficRegistry
var _state: TrafficState
var _origin: FloatingOrigin
var _view: TrafficView


func before_each() -> void:
	_ctx = RunContext.new(SEED)
	_road = StraightRoadPath.new(3, _ctx.tuning.road)
	_reg = TrafficRegistry.load_default(_ctx.tuning.traffic)
	_state = TrafficState.new(_ctx.tuning.traffic.max_active_vehicles)
	_origin = FloatingOrigin.new()
	tree.root.add_child(_origin)
	_origin.setup(_ctx.tuning.road.floating_origin_shift_km)
	_view = TrafficView.new()
	tree.root.add_child(_view)
	_view.setup(_ctx, _road, _origin, _reg, _state)


func after_each() -> void:
	for n: Node in [_view, _origin]:
		if is_instance_valid(n):
			n.free()


func _spawn(s: float, flags: int = 0) -> int:
	var i := _state.allocate()
	var t := _reg.type_index(&"sedan")
	_state.s[i] = s
	_state.d[i] = _road.lane_center_d(1, s)
	_state.v[i] = SPEED_MPS
	_state.length[i] = _reg.length[t]
	_state.width[i] = _reg.width[t]
	_state.lane[i] = 1
	_state.type_id[i] = t
	_state.flags[i] = flags
	return i


func test_hidden_slot_is_not_drawn_and_shows_again() -> void:
	var a := _spawn(S0, TrafficState.FLAG_BRAKE)
	var b := _spawn(S0 + GAP_M, TrafficState.FLAG_BRAKE)
	_view.capture_tick()
	_view.render(1.0)
	eq(_view.visible_count(), 2, "both drawn")
	var shadows := _view.shadow_count()
	var glows := _view.glow_count()
	_view.set_slot_hidden(a, true)
	_view.render(1.0)
	eq(_view.visible_count(), 1, "hidden slot not drawn")
	eq(_view.shadow_count(), shadows - 1, "no shadow for the hidden slot")
	lt(_view.glow_count(), glows, "no glow for the hidden slot")
	_view.capture_tick()
	_view.render(1.0)
	eq(_view.visible_count(), 1, "stays hidden across ticks")
	_view.set_slot_hidden(a, false)
	_view.render(1.0)
	eq(_view.visible_count(), 2, "shown again")
	ne(a, b, "two slots")


func test_new_vehicle_in_a_hidden_slot_is_drawn() -> void:
	var a := _spawn(S0)
	_view.capture_tick()
	_view.set_slot_hidden(a, true)
	_state.free_slot(a)
	_view.capture_tick()
	var again := _spawn(S0 + GAP_M)
	eq(again, a, "slot reused")
	_view.capture_tick()
	_view.render(1.0)
	eq(_view.visible_count(), 1, "the new vehicle is drawn")


func test_out_of_range_slots_are_ignored() -> void:
	_view.set_slot_hidden(-1, true)
	_view.set_slot_hidden(_state.capacity, true)
	_view.set_slot_hidden(0, true, true)   # no opposite carriageway bound
	_spawn(S0)
	_view.capture_tick()
	_view.render(1.0)
	eq(_view.visible_count(), 1, "nothing else hidden")
