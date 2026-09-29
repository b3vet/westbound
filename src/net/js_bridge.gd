class_name NetJsBridge
extends RefCounted
## The slice of JavaScriptBridge the web session needs: run a snippet and read a URL
## parameter. Spec: multiplayer handoff → Accounts (web: local storage); plan MP-D2.
## WP N1.2; docs/NET_CLIENT.md → Storage.
##
## Tests swap in a mock (tests/net/test_session_storage.gd) to run the web path headless.
## Off the web `available()` is false and nothing is evaluated.


func available() -> bool:
	return OS.has_feature("web")


## Evaluates `code` in the page (global scope) and returns its value: a String, a number,
## a bool or null.
func eval(code: String) -> Variant:
	if not available():
		return null
	return JavaScriptBridge.eval(code, true)


## The page URL's query parameter `param_name` ("" when absent or off the web).
func query_param(param_name: String) -> String:
	var v: Variant = eval("(function(){try{var v=new URLSearchParams(window.location.search).get(%s);"
			% JSON.stringify(param_name) + "return v===null?'':String(v);}catch(e){return '';}})()")
	return v if v is String else ""
