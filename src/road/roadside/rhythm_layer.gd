class_name RhythmLayer
extends RoadsideLayer
## Evenly spaced road furniture at exact multiples of `cell_length_m` in absolute
## s: light poles (50 m), reflector posts (25 m), guardrail posts, fence
## segments. Spec: World → Road ("Roadside rhythm: light poles every 50 m,
## reflector posts every 25 m, guardrail posts, ... fences. This rhythm sells
## speed"). One item per side per cell, at s = c * spacing.

enum Edge {
	REFERENCE,  ## d measured from the reference line (median center)
	GUARDRAIL,  ## d measured outward from the guardrail face
	SCENERY,    ## d measured outward from the scenery line (guardrail + prop clearance)
}

var edge: Edge = Edge.REFERENCE
var offset_m: float = 0.0
## Both carriageways (mirrored); otherwise one instance at +offset (median).
var both_sides: bool = true
## Segment mode: the mesh spans [s, s + spacing] (fences).
var segment: bool = false


func _init(context: RoadsideContext, layer_id: StringName, spacing_m: float, mesh: Mesh,
		d_edge: Edge, d_offset_m: float, mirrored: bool, as_segment: bool = false) -> void:
	super(context, layer_id, spacing_m)
	edge = d_edge
	offset_m = d_offset_m
	both_sides = mirrored
	segment = as_segment
	add_pool(mesh, 2 if mirrored else 1)


func _emit(c: int) -> void:
	var s := float(c) * cell_length_m
	var d := _edge_d(s) + offset_m
	if segment:
		var s1 := s + cell_length_m
		_place_segment(0, s, s1, d, cell_length_m)
		if both_sides:
			_place_segment(0, s, s1, -d, cell_length_m)
		return
	_sample(s)
	_place(0, d, 0.0)
	if both_sides:
		_place(0, -d, PI)


func _edge_d(s: float) -> float:
	match edge:
		Edge.GUARDRAIL:
			return ctx.road.guardrail_d(s)
		Edge.SCENERY:
			return ctx.road.guardrail_d(s) + ctx.tuning.prop_clearance_m
	return 0.0
