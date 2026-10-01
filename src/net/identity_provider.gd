class_name NetIdentityProvider
extends RefCounted
## One sign-in provider on the client (Apple or Google): shows the provider's own sheet
## with the server's nonce and returns its ID token. Spec: multiplayer handoff → Accounts
## and authentication ("Native side: a small native plugin per platform"; Sign in with
## Apple / Google); WP N11; docs/NET_CLIENT.md → Sign in with Apple / Google.
##
## Implementations:
##   NetWebIdentity      the web build: the custom shell's `window.wbIdentity` (Sign in with
##                       Apple JS, Google Identity Services), loaded only when configured
##   NetNativeIdentity   iOS / Android: a native plugin singleton when one is installed;
##                       until then unavailable (the buttons say so)
##   NetFakeIdentity     tests and previews: tokens the fake server accepts
##
## Every implementation speaks the same small contract (also the native plugins'): begin
## with a nonce, then poll for a JSON result {state: "done", id_token, code} |
## {state: "cancelled"} | {state: "error", error}. This base polls it.

const APPLE := "apple"
const GOOGLE := "google"
const ALL: Array[String] = [APPLE, GOOGLE]
## How often the result is polled while the sheet is open (seconds).
const POLL_S := 0.1   # lint: allow-number poll period, not gameplay

## `apple` or `google`.
var provider: String = ""
## Give up after this long (NetTuning.identity_sign_in_timeout_s).
var timeout_s: float = 180.0   # lint: allow-number default; NetSession sets it from NetTuning
## (seconds: float) -> Signal-awaitable wait; tests replace it. Default: a real-time timer.
var wait: Callable

var _busy: bool = false


func _init(provider_id: String = "") -> void:
	provider = provider_id


## Whether this build can show the provider's sheet at all.
func available() -> bool:
	return false


## The server's public config for the provider ({enabled, client_id, redirect_uri}).
func configure(_config: Dictionary) -> void:
	pass


## Shows the sheet with `nonce` and returns what it gave back. One at a time.
func sign_in(nonce: String) -> NetIdentityResult:
	if _busy:
		return NetIdentityResult.failure(NetIdentityResult.BUSY)
	if not available():
		await _sleep(0.0)
		return NetIdentityResult.failure(NetIdentityResult.UNAVAILABLE)
	_busy = true
	var r: NetIdentityResult
	if not _begin(nonce):
		r = NetIdentityResult.failure(NetIdentityResult.UNAVAILABLE)
	else:
		r = await _poll_loop()
	_busy = false
	return r


func busy() -> bool:
	return _busy


# ---------------------------------------------------------------- The contract

## Opens the sheet; false when it cannot.
func _begin(_nonce: String) -> bool:
	return false


## The result as JSON text, "" while the sheet is open.
func _poll() -> String:
	return ""


## Closes the sheet (timeout).
func _cancel() -> void:
	pass


func _poll_loop() -> NetIdentityResult:
	var waited := 0.0
	while waited < timeout_s:
		await _sleep(POLL_S)
		waited += POLL_S
		var text := _poll()
		if not text.is_empty():
			return NetIdentityResult.from_page(text)
	_cancel()
	return NetIdentityResult.failure(NetIdentityResult.TIMEOUT)


func _sleep(seconds: float) -> void:
	if wait.is_valid():
		await wait.call(seconds)
		return
	var tree := Engine.get_main_loop() as SceneTree
	if seconds <= 0.0:
		await tree.process_frame
	else:
		await tree.create_timer(seconds, true, false, true).timeout
