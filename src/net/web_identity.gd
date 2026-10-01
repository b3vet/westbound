class_name NetWebIdentity
extends NetIdentityProvider
## Sign in with Apple / Google on the web build, through the custom shell's
## `window.wbIdentity` (platform/web/shell.html; docs/WEB.md → Sign-in). Spec: multiplayer
## handoff → Accounts and authentication. WP N11; docs/NET_CLIENT.md → Sign in with Apple /
## Google.
##
## The shell loads Sign in with Apple JS or Google Identity Services only after
## configure() hands it a client id from the server (`GET /auth/providers`), so a build
## whose server has no providers never loads a third-party script. A popup must open
## inside a real click, which a canvas button is not (Godot handles input on its next
## frame), so begin() shows a small sheet over the canvas with the provider's own button;
## the player's click on it opens the provider's popup. The result is polled.

var bridge: NetJsBridge
## The shell confirmed the provider's client id (configure()).
var configured: bool = false


func _init(provider_id: String = "", js: NetJsBridge = null) -> void:
	super(provider_id)
	bridge = js if js != null else NetJsBridge.new()


func available() -> bool:
	return configured and _shell()


func configure(config: Dictionary) -> void:
	configured = false
	if not _shell() or not bool(config.get("enabled", false)):
		return
	var cid: Variant = config.get("client_id", "")
	if not (cid is String) or (cid as String).is_empty():
		return
	var ok: Variant = bridge.eval("window.wbIdentity.configure(%s, %s)"
			% [JSON.stringify(provider), JSON.stringify(config)])
	configured = ok == true


func _shell() -> bool:
	return bridge.available() and bridge.eval("!!(window.wbIdentity)") == true


func _begin(nonce: String) -> bool:
	return bridge.eval("window.wbIdentity.begin(%s, %s)" % [JSON.stringify(provider), JSON.stringify(nonce)]) == true


func _poll() -> String:
	var v: Variant = bridge.eval("window.wbIdentity.poll()")
	return v if v is String else ""


func _cancel() -> void:
	bridge.eval("window.wbIdentity.cancel()")
