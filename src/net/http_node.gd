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

var host: Node
## TLS options for https (null = the platform trust store). `TLSOptions.client_unsafe()`
## only for a local dev server with a self-signed certificate.
var tls: TLSOptions


func _init(host_node: Node, tls_options: TLSOptions = null) -> void:
	host = host_node
	tls = tls_options


func request(method: int, url: String, headers: PackedStringArray, body: String,
		timeout_s: float) -> NetHttpResponse:
	return await _send(method, url, headers, body, timeout_s)


## A binary body (HTTPRequest.request_raw; the replay upload).
func request_raw(method: int, url: String, headers: PackedStringArray, body: PackedByteArray,
		timeout_s: float) -> NetHttpResponse:
	return await _send(method, url, headers, body, timeout_s)


## `body`: a String (HTTPRequest.request) or a PackedByteArray (request_raw).
func _send(method: int, url: String, headers: PackedStringArray, body: Variant,
		timeout_s: float) -> NetHttpResponse:
	if host == null or not is_instance_valid(host) or not host.is_inside_tree():
		return NetHttpResponse.failed(HTTPRequest.RESULT_CANT_CONNECT)
	var req := HTTPRequest.new()
	req.timeout = timeout_s
	req.accept_gzip = true
	if tls != null:
		req.set_tls_options(tls)
	host.add_child(req)
	var err: Error
	if body is PackedByteArray:
		err = req.request_raw(url, headers, method as HTTPClient.Method, body as PackedByteArray)
	else:
		err = req.request(url, headers, method as HTTPClient.Method, String(body))
	if err != OK:
		req.queue_free()
		return NetHttpResponse.failed(HTTPRequest.RESULT_CANT_CONNECT)
	var tree := host.get_tree()
	var done: Array = await req.request_completed
	req.queue_free()
	# Resume the caller outside the signal emission, so it may free the host at once.
	await tree.process_frame
	var r := NetHttpResponse.new()
	r.result = int(done[0])
	r.status = int(done[1])
	r.headers = done[2] as PackedStringArray
	r.body = done[3] as PackedByteArray
	return r


func wait(seconds: float) -> void:
	if host == null or not is_instance_valid(host) or not host.is_inside_tree():
		return
	await host.get_tree().create_timer(maxf(seconds, 0.0), true, false, true).timeout
