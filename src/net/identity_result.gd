class_name NetIdentityResult
extends RefCounted
## What a provider's sign-in sheet (the web popup, a native plugin) gave back: an ID token
## (and Apple's authorization code), a cancel, or an error. Spec: multiplayer handoff →
## Accounts and authentication (Sign in with Apple / Google). WP N11;
## docs/NET_CLIENT.md → Sign in with Apple / Google.

## Client-side codes (`error`).
const CANCELLED := "cancelled"
const UNAVAILABLE := "provider_unavailable_here"
const TIMEOUT := "sign_in_timeout"
const FAILED := "sign_in_failed"
const BUSY := "sign_in_busy"

var ok: bool = false
var error: String = ""
## The provider's ID token (JWT) and, from Apple, the authorization code (optional).
var id_token: String = ""
var authorization_code: String = ""


static func token(jwt: String, code: String = "") -> NetIdentityResult:
	var r := NetIdentityResult.new()
	r.ok = not jwt.is_empty()
	r.error = "" if r.ok else FAILED
	r.id_token = jwt
	r.authorization_code = code
	return r


static func failure(code: String) -> NetIdentityResult:
	var r := NetIdentityResult.new()
	r.error = code
	return r


## The player closed the sheet: nothing to report as an error.
func cancelled() -> bool:
	return not ok and error == CANCELLED


## A result from the page's `wbIdentity.poll()` (a JSON object as text):
## {state: "done", id_token, code} | {state: "cancelled"} | {state: "error", error}.
static func from_page(text: String) -> NetIdentityResult:
	var j := JSON.new()
	if j.parse(text) != OK or not (j.data is Dictionary):
		return failure(FAILED)
	var d := j.data as Dictionary
	match str(d.get("state", "")):
		"done":
			var t: Variant = d.get("id_token", "")
			var c: Variant = d.get("code", "")
			return token(t if t is String else "", c if c is String else "")
		"cancelled":
			return failure(CANCELLED)
	var e: Variant = d.get("error", "")
	return failure(FAILED if not (e is String) or (e as String).is_empty() else String(e))
