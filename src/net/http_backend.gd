class_name NetHttpBackend
extends RefCounted
## The transport under NetApi: one HTTP request, and a wait (retry backoff). Spec:
## multiplayer handoff → Client changes (`api.gd`, HTTPRequest). WP N1.2;
## docs/NET_CLIENT.md → Accounts client.
##
## Implementations: NetHttpNode (HTTPRequest nodes; the game) and NetFakeAccounts (an
## in-memory accounts server; tests and previews). Both methods are coroutines: callers
## always `await` them. This base answers every request with a connection failure, so an
## unconfigured API is simply offline.


## Sends one request and returns what came back (never null). `method` is an
## HTTPClient.Method; `body` is "" for none.
func request(_method: int, _url: String, _headers: PackedStringArray, _body: String,
		_timeout_s: float) -> NetHttpResponse:
	await _tree().process_frame
	return NetHttpResponse.failed(HTTPRequest.RESULT_CANT_CONNECT)


## Waits `seconds` of real time (ignores pause and Engine.time_scale).
func wait(seconds: float) -> void:
	await _tree().create_timer(maxf(seconds, 0.0), true, false, true).timeout


static func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree
