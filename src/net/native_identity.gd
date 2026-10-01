class_name NetNativeIdentity
extends NetIdentityProvider
## Sign in with Apple / Google on iOS and Android: a native plugin per platform, reached
## through an engine singleton. Spec: multiplayer handoff → Accounts and authentication
## ("Native side: a small native plugin per platform (or a maintained community plugin if
## one fits)"); plan MP-D2. WP N11; docs/NET_CLIENT.md → Native plugins.
##
## No plugin ships yet: until one registers its singleton, available() is false and the
## account screen shows the provider as not available in this build. A plugin needs only
## this contract (the same as the web shell's `wbIdentity`):
##   configure(config: Dictionary)   the server's {enabled, client_id, redirect_uri}
##   begin(nonce: String) -> bool    open the system sheet (ASAuthorizationController /
##                                   Credential Manager) with that nonce
##   poll() -> String                "" while open, then one JSON result:
##                                   {"state": "done", "id_token": "...", "code": "..."} |
##                                   {"state": "cancelled"} | {"state": "error", "error": "..."}
##   cancel()
## iOS passes the nonce as given (or its SHA-256 hex, which the server also accepts); the
## server checks the token's audience against `identity.apple_client_ids` (the bundle id)
## and `identity.google_client_ids` (the iOS / Android OAuth clients).

const SINGLETONS := {
	"apple": "WestboundSignInWithApple",
	"google": "WestboundGoogleSignIn",
}


func available() -> bool:
	return _plugin() != null


func configure(config: Dictionary) -> void:
	var p := _plugin()
	if p != null and p.has_method(&"configure"):
		p.call(&"configure", config)


func _plugin() -> Object:
	var n := String(SINGLETONS.get(provider, ""))
	if n.is_empty() or not Engine.has_singleton(n):
		return null
	return Engine.get_singleton(n)


func _begin(nonce: String) -> bool:
	var p := _plugin()
	return p != null and p.has_method(&"begin") and p.call(&"begin", nonce) == true


func _poll() -> String:
	var p := _plugin()
	if p == null or not p.has_method(&"poll"):
		return JSON.stringify({"state": "error", "error": NetIdentityResult.UNAVAILABLE})
	var v: Variant = p.call(&"poll")
	return v if v is String else ""


func _cancel() -> void:
	var p := _plugin()
	if p != null and p.has_method(&"cancel"):
		p.call(&"cancel")
