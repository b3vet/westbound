class_name NetHttpResponse
extends RefCounted
## One HTTP exchange as a NetHttpBackend returns it: the transport result
## (HTTPRequest.Result), the status, the headers and the body. Spec: multiplayer handoff →
## Client changes (`api.gd`: HTTP client using HTTPRequest). WP N1.2; docs/NET_CLIENT.md →
## Accounts client.

## HTTPRequest.Result: RESULT_SUCCESS when a response arrived (any status).
var result: int = HTTPRequest.RESULT_SUCCESS
## HTTP status (0 when no response arrived).
var status: int = 0
## "Name: value" lines, as HTTPRequest gives them.
var headers: PackedStringArray = PackedStringArray()
var body: PackedByteArray = PackedByteArray()


## A response with `status` and a UTF-8 `body_text`.
static func make(status_code: int, body_text: String = "",
		header_lines: PackedStringArray = PackedStringArray()) -> NetHttpResponse:
	var r := NetHttpResponse.new()
	r.status = status_code
	r.body = body_text.to_utf8_buffer()
	r.headers = header_lines
	return r


## No response: a transport failure (HTTPRequest.RESULT_*).
static func failed(transport_result: int) -> NetHttpResponse:
	var r := NetHttpResponse.new()
	r.result = transport_result
	return r


## A response arrived (possibly an error status).
func arrived() -> bool:
	return result == HTTPRequest.RESULT_SUCCESS


## The value of header `header_name` (case-insensitive), "" when absent.
func header(header_name: String) -> String:
	var want := header_name.to_lower()
	for line in headers:
		var colon := line.find(":")
		if colon > 0 and line.substr(0, colon).strip_edges().to_lower() == want:
			return line.substr(colon + 1).strip_edges()
	return ""


func text() -> String:
	return body.get_string_from_utf8()
