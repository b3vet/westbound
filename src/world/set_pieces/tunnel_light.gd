class_name TunnelLight
extends RefCounted
## The light change at a road tunnel's entry and exit (WP6.3). Spec: Traffic →
## set-piece table ("Tunnel squeeze | Two lanes, tighter traffic, light change at entry
## and exit | Tunnel portal"); World → Color script (one set of globals drives every
## color); Night lighting (lamps are emissive, no real lights). docs/SET_PIECES.md.
##
## Every road tunnel changes the light (the squeeze is the traffic that makes use of
## it): factor_at(s) is 0 outside, 1 inside, ramped with a smoothstep over
## tunnel_light_ramp_m centred on each portal and exit. The run hands it to
## SkyRig.set_tunnel_light(), which darkens the ambient and sun light by
## tunnel_dark_frac and turns the lamp strips on (the street-lamp ramp at least
## tunnel_lamp_on). Numbers: data/set_pieces/tunnel_squeeze.tres.
##
## The TUNNEL features near s are cached and re-queried every refresh_every_m (director
## rate: a features_in query); factor_at is allocation-free.

const DEF_PATH := "res://data/set_pieces/tunnel_squeeze.tres"

var road: RoadPath
var def: SetPieceDef
## Cache window: [s - behind, s + ahead], re-queried when s moves past half of it.
var cache_behind_m: float = 1000.0
var cache_ahead_m: float = 3000.0

var _t0 := PackedFloat64Array()
var _t1 := PackedFloat64Array()
var _from: float = INF
var _to: float = -INF
var _found: Array[RoadFeature] = []


func _init(road_path: RoadPath, tunnel_def: SetPieceDef = null) -> void:
	road = road_path
	def = tunnel_def if tunnel_def != null else load(DEF_PATH) as SetPieceDef


## 0 outside every road tunnel, 1 inside, smooth at the portals.
func factor_at(s: float) -> float:
	if s < _from or s > _to - cache_ahead_m * 0.5:
		_refresh(s)
	var ramp := maxf(def.tunnel_light_ramp_m, 1e-3)
	var f := 0.0
	for k in _t0.size():
		var a := smoothstep(_t0[k] - ramp * 0.5, _t0[k] + ramp * 0.5, s)
		var b := 1.0 - smoothstep(_t1[k] - ramp * 0.5, _t1[k] + ramp * 0.5, s)
		f = maxf(f, minf(a, b))
	return f


func _refresh(s: float) -> void:
	_from = s - cache_behind_m
	_to = s + cache_ahead_m
	_t0.clear()
	_t1.clear()
	_found.clear()
	road.ensure_generated_to(_to)
	road.features_in(_from, _to, _found)
	for f in _found:
		if f.kind == RoadFeature.Kind.TUNNEL:
			_t0.append(f.s_start)
			_t1.append(f.s_end)
