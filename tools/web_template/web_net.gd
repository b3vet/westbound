extends Node
## WP9.9 (docs/WEB.md → Slim engine): the engine's networking inside a web build, against a
## local westbound-server (tools/web_template/probe.mjs --net URL): an HTTPRequest to
## /api/v1/health (the browser's fetch underneath), then a WebSocketPeer to /ws/echo
## sending one binary and one text message that must come back unchanged. Prints
##   PROBE net http <status> <body>
##   PROBE net ws binary <ok|FAIL> text <ok|FAIL>
##   PROBE done net <ok|FAIL>

const TIMEOUT_MS := 15000
const PAYLOAD_SIZE := 1024
const TEXT := "Şahin#1234 echo"

var _server := ""
var _http := HTTPRequest.new()
var _ws := WebSocketPeer.new()
var _payload := PackedByteArray()
var _http_ok := false
var _got_binary := false
var _got_text := false
var _sent := false
var _deadline := 0
var _finished := false


func _ready() -> void:
	var v: Variant = JavaScriptBridge.eval("new URLSearchParams(window.location.search).get('probe_server') || ''", true)
	_server = str(v).trim_suffix("/")
	for i in PAYLOAD_SIZE:
		_payload.append(i % 256)
	_deadline = Time.get_ticks_msec() + TIMEOUT_MS
	add_child(_http)
	_http.accept_gzip = false
	_http.request_completed.connect(_on_http)
	if _http.request(_server + "/api/v1/health") != OK:
		print("PROBE net http request failed to start")


func _on_http(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	print("PROBE net http %d %d %s" % [result, code, body.get_string_from_utf8()])
	_http_ok = result == HTTPRequest.RESULT_SUCCESS and code == 200
	var err := _ws.connect_to_url(_server.replace("http", "ws") + "/ws/echo")
	if err != OK:
		_finish()


func _process(_delta: float) -> void:
	if _finished:
		return
	if Time.get_ticks_msec() > _deadline:
		_finish()
		return
	if not _http_ok:
		return
	_ws.poll()
	if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	if not _sent:
		_ws.send(_payload)
		_ws.send_text(TEXT)
		_sent = true
	while _ws.get_available_packet_count() > 0:
		var pkt := _ws.get_packet()
		if _ws.was_string_packet():
			_got_text = pkt.get_string_from_utf8() == TEXT
		else:
			_got_binary = pkt == _payload
	if _got_binary and _got_text:
		_finish()


func _finish() -> void:
	_finished = true
	print("PROBE net ws binary %s text %s" % ["ok" if _got_binary else "FAIL", "ok" if _got_text else "FAIL"])
	_ws.close()
	var ok := _http_ok and _got_binary and _got_text
	print("PROBE done net %s" % ("ok" if ok else "FAIL"))
