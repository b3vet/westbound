class_name TunnelSqueezePiece
extends SetPieceSource.Controller
## Tunnel squeeze (WP6.3). Spec: Traffic → Traffic director, set-piece table: "Tunnel
## squeeze | Two lanes, tighter traffic, light change at entry and exit | Tunnel
## portal"; World → Road ("tunnels ... drop to 2"). docs/SET_PIECES.md.
##
## Triggered by a road tunnel (SetPieceDef.trigger TUNNEL: the director offers it every
## tunnel of at least tunnel_min_length_m, seeded chance feature_chance_pct). The zone is
## the tunnel, portal to exit; the road already narrows to its tunnel lanes before the
## portal (ProceduralRoadPath) and the portal is the warning. setup_zone() makes the
## traffic inside follow closer: every vehicle's IDM headway x headway_scale over the
## tunnel (TrafficSim.add_headway_zone, tag = the serial). The piece's own platoon,
## vehicles_min .. vehicles_max cars staggered over the two lanes row_gap_m apart (never
## under s*), is planned by the meeting map to be met zone_meet_m inside and keeps its
## slots (keep_formation). The light change at entry and exit belongs to every road
## tunnel and is the view's (TunnelLight, SkyRig.set_tunnel_light).

var portal_s: float = 0.0
var exit_s: float = 0.0


func setup_zone(src: SetPieceSource, inst: SetPieceSource.Instance) -> bool:
	if src.road == null or not src.can_zone:
		return false
	var found: Array[RoadFeature] = []
	src.road.features_in(inst.zone_s0 - 1.0, inst.zone_s0 + 1.0, found)
	var tunnel: RoadFeature = null
	for f in found:
		if f.kind == RoadFeature.Kind.TUNNEL and absf(f.s_start - inst.zone_s0) < 1.0:
			tunnel = f
	if tunnel == null:
		return false
	portal_s = tunnel.s_start
	exit_s = tunnel.s_end
	inst.zone_s1 = exit_s
	inst.lanes = src.road.lane_count(portal_s)
	return bool(src.sim.call(&"add_headway_zone", portal_s, exit_s, inst.def.headway_scale, inst.serial))


func plan(src: SetPieceSource, ctx: SpawnSource.Context, inst: SetPieceSource.Instance) -> void:
	var d := inst.def
	var n := src.rng.int_range(d.vehicles_min, d.vehicles_max)
	var lane := src.rng.int_range(0, inst.lanes - 1)
	var s := inst.s_rear
	for k in n:
		var rec := SpawnSource.Record.new()
		if not src.draw_vehicle(ctx, inst, lane, rec):
			continue
		var ln := src.flow.length_of(rec.type_id)
		rec.s = s + ln * 0.5
		src.add_record(inst, rec, k)
		# Staggered: the next car in the other lane, a row gap on (s* holds in each lane:
		# a lane's cars are two rows apart).
		s += ln + maxf(d.row_gap_m, (src.flow.min_spacing(rec.profile_id, inst.speed, ln, inst.speed, ln) - ln) * 0.5)
		lane = (lane + 1) % maxi(inst.lanes, 1)


func on_bound(src: SetPieceSource, inst: SetPieceSource.Instance) -> void:
	mark_formation(src, inst)


func step(src: SetPieceSource, inst: SetPieceSource.Instance, dt: float, _player: VehicleState) -> void:
	if inst.n > 0:
		keep_formation(src, inst, dt)
