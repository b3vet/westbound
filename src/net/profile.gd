class_name NetProfile
extends RefCounted
## The player's online profile (`GET /api/v1/me`). Spec: multiplayer handoff → Accounts
## and authentication (display names `name#1234`, rename every 30 days);
## docs/SERVER.md → Accounts API → GET /me. WP N1.2.

const TAG_FMT := "#%04d"

## Decimal String (never a number: ids can exceed 2^53).
var account_id: String = ""
var display_name: String = ""
var name_tag: int = 0
## `name#1234`.
var full_name: String = ""
var created_at: int = 0
var name_changed_at: int = 0
## Unix seconds of the next allowed rename; 0 when a rename is allowed now.
var next_rename_at: int = 0
var linked_apple: bool = false
var linked_google: bool = false
## N11: the linked identities, provider -> {email_hint: String ("" = none), private_email}.
var identities: Dictionary = {}


## The profile in a /me body; null when it has no account id.
static func from_dict(d: Variant) -> NetProfile:
	if not (d is Dictionary):
		return null
	var dd := d as Dictionary
	var p := NetProfile.new()
	p.account_id = NetApiResult.as_id(dd.get("account_id", ""))
	if p.account_id.is_empty():
		return null
	p.display_name = NetApiResult.as_id(dd.get("display_name", ""))
	p.name_tag = _int(dd.get("name_tag", 0))
	p.full_name = NetApiResult.as_id(dd.get("full_name", ""))
	if p.full_name.is_empty() and not p.display_name.is_empty():
		p.full_name = p.display_name + TAG_FMT % p.name_tag
	p.created_at = _int(dd.get("created_at", 0))
	p.name_changed_at = _int(dd.get("name_changed_at", 0))
	p.next_rename_at = _int(dd.get("next_rename_at", 0))
	var linked: Variant = dd.get("linked", {})
	if linked is Dictionary:
		p.linked_apple = bool((linked as Dictionary).get("apple", false))
		p.linked_google = bool((linked as Dictionary).get("google", false))
	var ids: Variant = dd.get("identities", [])
	if ids is Array:
		for v: Variant in ids:
			if not (v is Dictionary):
				continue
			var e := v as Dictionary
			var prov := NetApiResult.as_id(e.get("provider", ""))
			if prov.is_empty():
				continue
			var hint: Variant = e.get("email_hint", "")
			p.identities[prov] = {"email_hint": hint if hint is String else "",
					"private_email": bool(e.get("private_email", false))}
	return p


## The /me form (the session caches it for offline display).
func to_dict() -> Dictionary:
	var next: Variant = null
	if next_rename_at > 0:
		next = next_rename_at
	return {
		"account_id": account_id,
		"display_name": display_name,
		"name_tag": name_tag,
		"full_name": full_name,
		"created_at": created_at,
		"name_changed_at": name_changed_at,
		"next_rename_at": next,
		"linked": {"apple": linked_apple, "google": linked_google},
		"identities": _identity_list(),
	}


func _identity_list() -> Array:
	var out: Array = []
	for prov: String in identities:
		var e: Dictionary = identities[prov]
		out.append({"provider": prov, "email_hint": e.get("email_hint", ""),
				"private_email": e.get("private_email", false)})
	return out


## N11: whether `provider` ("apple" / "google") is linked.
func is_linked(provider: String) -> bool:
	match provider:
		"apple":
			return linked_apple
		"google":
			return linked_google
	return false


## Any provider linked (the account can be signed into on another device).
func has_provider() -> bool:
	return linked_apple or linked_google


## The masked address of a linked identity ("" when none or private).
func email_hint(provider: String) -> String:
	var e: Variant = identities.get(provider)
	return String((e as Dictionary).get("email_hint", "")) if e is Dictionary else ""


func private_email(provider: String) -> bool:
	var e: Variant = identities.get(provider)
	return bool((e as Dictionary).get("private_email", false)) if e is Dictionary else false


## "#0042".
func tag_text() -> String:
	return TAG_FMT % name_tag


## A rename is allowed at `now_unix` (the server has the final say).
func can_rename(now_unix: float) -> bool:
	return next_rename_at <= 0 or float(next_rename_at) <= now_unix


static func _int(v: Variant) -> int:
	if v is int or v is float:
		return int(v)
	return 0
