class_name NetHttpNode
extends NetHttpBackend
## The real NetHttpBackend: one HTTPRequest node per request under a host node (the
## session), freed when it completes. Spec: multiplayer handoff → Client changes
## (`api.gd` uses HTTPRequest). WP N1.2; docs/NET_CLIENT.md → Accounts client.
##
## On the web HTTPRequest goes through the browser's fetch (CORS: the server allows it).
## The host should process while the tree is paused (NetSession does), or requests
## stall under the pause menu. Requests are rare (sign-in, refresh, profile), so a node
## per request costs nothing that matters.
##
## Timeouts and waits run on the monotonic clock (NetTimeSource), not on HTTPRequest.timeout
## or a SceneTreeTimer. Those count down by the engine's *raw* frame step
## (Engine::get_process_step), which, unlike the process delta, is not clamped by
## `max_physics_steps_per_frame`. So a request started in a long frame (a synchronous scene
## load, the boot frame, a first-use shader compile) timed out on the next frame when that
## frame outlasted the timeout, whatever the wall time since the request began.

const USEC_PER_S := 1000000.0

var host: Node
## TLS options for https (null = the platform trust store). `TLSOptions.client_unsafe()`
## only for a local dev server with a self-signed certificate.
var tls: TLSOptions
## The clock the timeout and wait() run on (NetVirtualTime in tests).
var clock: NetTimeSource


func _init(host_node: Node, tls_options: TLSOptions = null,
		time_source: NetTimeSource = null) -> void:
	host = host_node
	tls = tls_options
	clock = time_source if time_source != null else NetTimeSource.new()


func request(method: int, url: String, headers: PackedStringArray, body: String,
		timeout_s: float) -> NetHttpResponse:
	return await _send(method, url, headers, body, timeout_s)


## A binary body (HTTPRequest.request_raw; the replay upload).
func request_raw(method: int, url: String, headers: PackedStringArray, body: PackedByteArray,
		timeout_s: float) -> NetHttpResponse:
	return await _send(method, url, headers, body, timeout_s)


## `body`: a String (HTTPRequest.request) or a PackedByteArray (request_raw).
## `timeout_s` <= 0: no timeout.
func _send(method: int, url: String, headers: PackedStringArray, body: Variant,
		timeout_s: float) -> NetHttpResponse:
	if not _host_ready():
		return NetHttpResponse.failed(HTTPRequest.RESULT_CANT_CONNECT)
	var req := HTTPRequest.new()
	req.timeout = 0.0  # The deadline below replaces it (see the header).
	req.accept_gzip = true
	if tls != null:
		req.set_tls_options(tls)
	host.add_child(req)
	var done: Array = []
	req.request_completed.connect(func(result: int, status: int, hdrs: PackedStringArray,
			bytes: PackedByteArray) -> void: done.append_array([result, status, hdrs, bytes]),
			CONNECT_ONE_SHOT)
	var err: Error
	if body is PackedByteArray:
		err = req.request_raw(url, headers, method as HTTPClient.Method, body as PackedByteArray)
	else:
		err = req.request(url, headers, method as HTTPClient.Method, String(body))
	if err != OK:
		req.queue_free()
		return NetHttpResponse.failed(HTTPRequest.RESULT_CANT_CONNECT)
	var tree := host.get_tree()
	var deadline := clock.now_usec() + roundi(timeout_s * USEC_PER_S) if timeout_s > 0.0 else -1
	# Resumed from process_frame, never inside the signal emission, so the caller may free
	# the host at once.
	while true:
		await tree.process_frame
		if not done.is_empty():
			break
		if not is_instance_valid(req) or not req.is_inside_tree():
			# The host left the tree (HTTPRequest cancels on exit) or was freed with it.
			return NetHttpResponse.failed(HTTPRequest.RESULT_CANT_CONNECT)
		if deadline >= 0 and clock.now_usec() >= deadline:
			req.cancel_request()
			req.queue_free()
			return NetHttpResponse.failed(HTTPRequest.RESULT_TIMEOUT)
	if is_instance_valid(req):
		req.queue_free()
	var r := NetHttpResponse.new()
	r.result = int(done[0])
	r.status = int(done[1])
	r.headers = done[2] as PackedStringArray
	r.body = done[3] as PackedByteArray
	return r


## Waits `seconds` on the monotonic clock (ignores pause and Engine.time_scale).
func wait(seconds: float) -> void:
	if not _host_ready():
		return
	var tree := host.get_tree()
	var until := clock.now_usec() + roundi(maxf(seconds, 0.0) * USEC_PER_S)
	await tree.process_frame
	while clock.now_usec() < until:
		await tree.process_frame


func _host_ready() -> bool:
	return host != null and is_instance_valid(host) and host.is_inside_tree()
