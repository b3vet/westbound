class_name NetTrafficControls
extends DriveControls
# lint: not-sim dev-only sandbox controls (Node); they run the network traffic harness in the sandbox
## Traffic sandbox: network mode (N4.3). Spec: multiplayer handoff → Implementation
## milestones, N4 ("network overlays in the traffic sandbox"), Client network traffic;
## plan N4.3. docs/NET_TRAFFIC.md → Sandbox.
##
## Buttons, top right under the tab bar, the set-piece rows and the fast-traffic rows:
##   NET ON/OFF  network mode: the sandbox's traffic comes from a fake server (the real
##               TrafficSim + director at 20 Hz with the multiplayer rules, NetTrafficHarness)
##               over a simulated link, through NetworkTrafficSource into the sandbox's own
##               TrafficState, which TrafficView, contacts and the overlays read as usual.
##               The local sim and director stop (the opposite carriageway keeps running:
##               it is local-only in multiplayer too). OFF re-seeds local traffic.
##   LINK        the link: 2 % loss on the WebSocket stream (the acceptance link, 150 ms
##               RTT ± 30 ms), no loss, or 2 % loss on a datagram path.
## The overlays (NetTrafficOverlay) and a stats line; the dev HUD's net rows.
## Snap: net=true (link=tcp|clean|udp) starts network mode before the warm-up.
##
## The sandbox owns one (traffic_sandbox.gd adds it after its own UI) and asks `active`
## every tick; it reads the sandbox's `sim`, `car`, `road`, `origin`, `tuning`,
## `traffic_seed` and `overlay` each time.

enum Link { STREAM, CLEAN, DATAGRAM }
const LINK_NAMES: Array[String] = ["2% TCP", "NO LOSS", "2% UDP"]
const LINK_ARGS: Array[String] = ["tcp", "clean", "udp"]
const BUTTON_SIZE := Vector2(132.0, 48.0)
## Rows above: the tab bar, the two set-piece rows, the two fast-traffic rows.
const ROWS_ABOVE_H: Array[float] = [56.0, 48.0, 48.0, 48.0, 48.0]
## The road is kept this far behind the player in network mode (the fake server's cars
## and the client's lane-drop zones reach back further than local traffic).
const REACH_BEHIND_M := 800.0

var sandbox: Node
var active: bool = false
var link: Link = Link.STREAM
var harness: NetTrafficHarness
var overlay: NetTrafficOverlay

var _net_button: Button
var _link_button: Button
var _saved_idm: bool = true
var _saved_mobil: bool = true


func _ready() -> void:
	super()
	for k in ROWS_ABOVE_H.size():
		var spacer := add_label(Corner.TOP_RIGHT, k, 1.0)
		spacer.custom_minimum_size.y = ROWS_ABOVE_H[k]
	var row := ROWS_ABOVE_H.size()
	_net_button = add_button(Corner.TOP_RIGHT, row, "", BUTTON_SIZE, func() -> void: set_active(not active), true)
	_link_button = add_button(Corner.TOP_RIGHT, row, "", BUTTON_SIZE, cycle_link, true)
	overlay = NetTrafficOverlay.new()
	overlay.name = "NetTrafficOverlay"
	overlay.visible = false
	sandbox.get_node(^"Overlay").add_child(overlay)
	_refresh()


func _process(_delta: float) -> void:
	if active:
		var cam: Camera3D = sandbox.get(&"cam").call(&"current_camera")
		overlay.camera = cam
		overlay.text_scale = float((sandbox.get(&"overlay") as Node).get(&"text_scale"))


## Network mode on / off.
func set_active(on: bool) -> void:
	if on == active:
		return
	if on:
		_start(true)
	else:
		_stop()
	_refresh()


## Next link; restarts the harness when on.
func cycle_link() -> void:
	link = ((link + 1) % LINK_NAMES.size()) as Link
	if active:
		_stop_harness()
		_start(false)
	_refresh()


## One sandbox tick (120 Hz): the harness (server ticks, link, clock, client step).
func tick(dt: float) -> void:
	harness.advance(dt)


## A contact with slot i: the client's hit reaction now, and the hit report (the fake
## server's reaction streams back as intents).
func notify_hit(slot: int) -> void:
	harness.source.notify_hit(slot)
	harness.authority.notify_hit(harness.source.car_id(slot))


func set_headlights(on: bool) -> void:
	if harness != null:
		harness.source.set_headlights(on)


## The re-seeded sandbox has a new sim: start again on its TrafficState.
func restart() -> void:
	if active:
		_stop_harness()
		_start(false)


## Lines for the sandbox's stats panel.
func stats_line() -> String:
	var s := harness.source.stats
	return "net %s  corr %d (%.0f/s)  mean %.1f cm  p99 %.1f cm  max %.0f cm  late %d  teleports %d" % [
		LINK_NAMES[link], s.corrections, s.rate(NetTrafficStats.Counter.CORRECTIONS),
		s.mean_error() * NetTrafficOverlay.M_TO_CM, s.percentile(NetTrafficStats.P99) * NetTrafficOverlay.M_TO_CM,
		s.err_max * NetTrafficOverlay.M_TO_CM, s.late_intents, s.teleports]


func report_dev_stats() -> void:
	harness.source.stats.report_dev_stats()
	NetTrafficStats.report_link(harness.clock)


## Snap hook: net=true (link=tcp|clean|udp) turns network mode on; truth=false hides the
## server's true car.
func snap_run(args: Dictionary) -> void:
	if not bool(args.get("net", false)):
		return
	var li := LINK_ARGS.find(String(args.get("link", "tcp")))
	link = maxi(li, 0) as Link
	_stop_harness()
	active = false
	set_active(true)
	overlay.show_truth = bool(args.get("truth", true))


## `save_layers`: remember the overlay's IDM / MOBIL layers (turned off here, restored by
## _stop); false when restarting while on.
func _start(save_layers: bool) -> void:
	var sim := sandbox.get(&"sim") as TrafficSim
	var car := sandbox.get(&"car") as PlayerCar
	sim.clear()
	var mode := NetDelayLink.Mode.DATAGRAM if link == Link.DATAGRAM else NetDelayLink.Mode.STREAM
	harness = NetTrafficHarness.new(sandbox.get(&"tuning") as Tuning, sandbox.get(&"road") as RoadPath,
		car.state, car.car.length_m, car.car.width_m, int(sandbox.get(&"traffic_seed")), mode,
		link != Link.CLEAN, sim.state)
	harness.source.set_headlights(sim.headlights())
	active = true
	var ov := sandbox.get(&"overlay") as TrafficOverlay
	if save_layers:
		_saved_idm = ov.show_idm
		_saved_mobil = ov.show_mobil
	ov.show_idm = false   # they describe the local model, which is off
	ov.show_mobil = false
	ov.selected_slot = -1
	overlay.bind(harness, sandbox.get(&"road") as RoadPath, sandbox.get(&"origin") as FloatingOrigin, car.state)
	overlay.link_name = LINK_NAMES[link]
	overlay.visible = true
	print("sandbox: network traffic on (%s)" % LINK_NAMES[link])


func _stop() -> void:
	_stop_harness()
	active = false
	var ov := sandbox.get(&"overlay") as TrafficOverlay
	ov.show_idm = _saved_idm
	ov.show_mobil = _saved_mobil
	sandbox.call(&"reseed", int(sandbox.get(&"traffic_seed")))
	print("sandbox: network traffic off")


func _stop_harness() -> void:
	harness = null
	if overlay != null:
		overlay.visible = false
		overlay.harness = null


func _refresh() -> void:
	DriveControls.set_text(_net_button, "NET %s" % ("ON" if active else "OFF"))
	DriveControls.set_text(_link_button, LINK_NAMES[link])
