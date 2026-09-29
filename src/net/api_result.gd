class_name NetApiResult
extends RefCounted
## The typed outcome of one NetApi call. Spec: multiplayer handoff → Accounts and
## authentication; docs/SERVER.md → Accounts API → Errors. WP N1.2; docs/NET_CLIENT.md →
## Accounts client.
##
## `ok` with `data` (the JSON body; {} for 204), or not `ok` with `error`:
##   - a server code (`invalid_name`, `rename_cooldown`, `banned`, `token_expired`, ...),
##     with `banned_until`, `next_rename_at` or `retry_after_s` when the server sent them;
##   - or a client code: NETWORK (no response: offline, DNS, TLS, timeout, reset),
##     SERVER (5xx after the retries), BAD_RESPONSE (not the JSON we expect),
##     OFFLINE (online features are off: no server configured).
## Account ids stay decimal Strings (a JSON number would lose bits above 2^53).

const NETWORK := "network"
const SERVER := "server_unavailable"
const BAD_RESPONSE := "bad_response"
const OFFLINE := "offline"
## Server codes the client acts on (docs/SERVER.md → Errors).
const RATE_LIMITED := "rate_limited"
const BANNED := "banned"
const TOKEN_EXPIRED := "token_expired"
const INVALID_CREDENTIALS := "invalid_credentials"
## `banned_until` of a permanent ban (9999-12-31T23:59:59Z).
const BANNED_FOREVER := 253402300799

var ok: bool = false
## HTTP status (0: no response).
var status: int = 0
var error: String = ""
## The server's English text (for logs; players see NetSession.error_text()).
var message: String = ""
## The parsed JSON body (a success body, or the error body).
var data: Dictionary = {}
## Server hint for 429 (the Retry-After header or `retry_after_secs`), seconds.
var retry_after_s: float = 0.0
## Unix seconds; 0 when absent.
var banned_until: int = 0
var next_rename_at: int = 0
## How many attempts the call took (1 = no retry).
var attempts: int = 0
## HTTPRequest.Result of the last attempt (network failures).
var transport_result: int = HTTPRequest.RESULT_SUCCESS


static func success(http_status: int, body: Dictionary) -> NetApiResult:
	var r := NetApiResult.new()
	r.ok = true
	r.status = http_status
	r.data = body
	return r


static func failure(http_status: int, code: String, text: String = "") -> NetApiResult:
	var r := NetApiResult.new()
	r.status = http_status
	r.error = code
	r.message = text
	return r


## No response, or the server failing (5xx): worth retrying later; not the player's fault.
func is_transient() -> bool:
	return not ok and (error == NETWORK or error == SERVER or error == RATE_LIMITED
			or error == BAD_RESPONSE or error == OFFLINE)


## A String field of `data` ("" when absent). Numbers are formatted as integers, so an
## id sent as a number still reads as its decimal digits.
func str_field(key: String) -> String:
	return NetApiResult.as_id(data.get(key, ""))


func int_field(key: String) -> int:
	var v: Variant = data.get(key, 0)
	if v is float or v is int:
		return int(v)
	return 0


## An id or name from JSON as a String: Strings as they are, whole numbers as digits.
static func as_id(v: Variant) -> String:
	if v is String:
		return v
	if v is int:
		return String.num_int64(v)
	if v is float and is_finite(v as float):
		return String.num_int64(int(v))
	return ""
