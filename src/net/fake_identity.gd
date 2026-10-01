class_name NetFakeIdentity
extends NetIdentityProvider
## A provider sheet for tests and previews: answers at once with a token NetFakeAccounts
## accepts (`fake.<provider>.<sub>.<nonce>`), or with a scripted cancel / error. WP N11;
## docs/NET_CLIENT.md → Sign in with Apple / Google.
##
##   var g := NetFakeIdentity.new("google")
##   g.sub = "g-123"            # the identity the "player" picks in the sheet
##   g.outcome = "cancelled"    # or an error code; "" = a token
##   session.identity["google"] = g

var sub: String = "fake-sub"
## "" = sign in; otherwise the error code returned (NetIdentityResult.CANCELLED, ...).
var outcome: String = ""
## Apple's authorization code to hand back ("" = none).
var code: String = ""
var is_available: bool = true
## Nonces the sheet was opened with.
var nonces: PackedStringArray = PackedStringArray()
## The last configure() call.
var config: Dictionary = {}

var _result: String = ""


func available() -> bool:
	return is_available


func configure(c: Dictionary) -> void:
	config = c


func _begin(nonce: String) -> bool:
	nonces.append(nonce)
	if outcome.is_empty():
		_result = JSON.stringify({"state": "done", "id_token": token_for(provider, sub, nonce), "code": code})
	elif outcome == NetIdentityResult.CANCELLED:
		_result = JSON.stringify({"state": "cancelled"})
	else:
		_result = JSON.stringify({"state": "error", "error": outcome})
	return true


func _poll() -> String:
	var r := _result
	_result = ""
	return r


## The fake ID token for `sub` with `nonce` (NetFakeAccounts reads it back).
static func token_for(provider_id: String, subject: String, nonce: String) -> String:
	return "fake.%s.%s.%s" % [provider_id, subject, nonce]
