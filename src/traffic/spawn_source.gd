class_name SpawnSource
extends RefCounted
## Pluggable source of traffic for the director. Base contract. Spec: Traffic
## director ("pluggable SpawnSource interface. Built-in sources: Flow (default),
## SetPiece, and Daily (Flow seeded by date). Future: Beatmap, HopTargets").
##
## The director calls plan_batch() at director rate (once per ~300 m batch, and
## again for each passability re-roll), never per tick, so plans may allocate
## Records. All randomness comes from ctx.rng (never global RNG): a re-roll just
## calls plan_batch() again and draws new numbers from the same stream.
## Sources only plan; the director runs passability, then commits Records into
## TrafficState through traffic_sim's spawn API.


## What the director knows when it asks for a batch. Read-only for sources.
class Context:
	var run: RunContext
	var rng: Rng                   ## usually run.rng_traffic (or a stream derived from it)
	var road: RoadPath
	var traffic: TrafficState      ## current traffic (to keep IDM-consistent gaps)
	var player: VehicleState
	var leg: int = 1               ## 1-based leg index
	var density_per_km_lane: float = 0.0   ## after waves, difficulty and caps
	var aggressive_share: float = 0.0      ## 0..1
	var hesitant_allowed: bool = false
	var intensity: float = 0.0     ## 0..1 wave phase (0 = breather, 1 = peak)
	var set_pieces_allowed: bool = false   ## false inside blind windows
	var is_night: bool = false
	var biome: BiomeDef


## One planned vehicle. Units SI, road space.
class Record:
	var s: float = 0.0             ## m (box center)
	var lane: int = 0              ## spawn lane (0 = next to the median)
	var d: float = NAN             ## m; NAN = lane center
	var v: float = 0.0             ## m/s initial speed (lane flow speed, IDM-consistent)
	var v0: float = 0.0            ## m/s desired speed from the profile's range
	var type_id: int = 0
	var profile_id: int = 0
	var model_variant: int = 0
	var color_index: int = 0
	var flags: int = 0             ## TrafficState.FLAG_* to start with (e.g. FLAG_SCRIPTED, FLAG_HAZARD)
	var set_piece: StringName = &""   ## SetPieceDef id when part of a set piece


## Stable id for logs, metrics and the sandbox (e.g. &"flow", &"set_piece", &"daily").
func source_id() -> StringName:
	return &""


## Appends planned vehicles with s in [s_from, s_to) to out_spawns (sorted by s is
## not required). Must be deterministic given ctx (including ctx.rng's state).
func plan_batch(_ctx: Context, _s_from: float, _s_to: float, _out_spawns: Array[Record]) -> void:
	push_error("SpawnSource.plan_batch not implemented")
