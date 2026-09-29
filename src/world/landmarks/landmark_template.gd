class_name LandmarkTemplate
extends RefCounted
## One built landmark or sign mesh in the template frame of LandmarkMeshBuilder
## (x = d, y = height, z = -(s - anchor s)), shared by every pooled instance of its
## kind (WP5.3). Spec: World → Checkpoint landmarks; Performance budget (one surface =
## one draw call). Built once per kind and cross-section, at warm-up.

## BiomeDef.LANDMARK_* or Landmarks.KIND_SIGN.
var kind: StringName = &""
var mesh: ArrayMesh
## Template vertices (the mesh's, kept for tests and bounds).
var vertices := PackedVector3Array()
## How far the build reaches before (s < anchor) and after (s > anchor) its anchor s.
var s_before: float = 0.0
var s_after: float = 0.0
## True: bent along the road through stations. False: placed rigidly (signs).
var bends: bool = true
## Width / height of each text line strip (LandmarkMeshBuilder.add_line order).
var line_aspect := PackedFloat64Array()
var max_abs_x: float = 0.0
var min_y: float = 0.0
var max_y: float = 0.0
var triangles: int = 0


static func from_builder(k: StringName, b: LandmarkMeshBuilder, bend: bool) -> LandmarkTemplate:
	var t := LandmarkTemplate.new()
	t.kind = k
	t.bends = bend
	t.vertices = b.vertices()
	t.line_aspect = b.line_aspect
	t.triangles = b.triangle_count()
	t.mesh = b.commit()
	var zmin := INF
	var zmax := -INF
	t.min_y = INF
	t.max_y = -INF
	for v in t.vertices:
		zmin = minf(zmin, v.z)
		zmax = maxf(zmax, v.z)
		t.min_y = minf(t.min_y, v.y)
		t.max_y = maxf(t.max_y, v.y)
		t.max_abs_x = maxf(t.max_abs_x, absf(v.x))
	t.s_before = maxf(zmax, 0.0)
	t.s_after = maxf(-zmin, 0.0)
	return t


func line_count() -> int:
	return line_aspect.size()
