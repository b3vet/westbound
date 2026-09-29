class_name FeatureMesh
extends RefCounted
## Vertex arrays for one BiomeFeature rebuild (director rate: allocates). Spec:
## Performance budget (one surface, one draw call; vertex-lit world conventions).
## Vertex conventions follow docs/CONTRACTS.md §13 for world-material geometry:
## COLOR.rgb sRGB albedo, UV2 = (emissive class, tint class), a normal per vertex
## (flat faces use their own vertices). Feature shaders may give UV/UV2/COLOR.a
## their own meaning (documented in each shader).

var verts := PackedVector3Array()
var normals := PackedVector3Array()
var colors := PackedColorArray()
var uvs := PackedVector2Array()
var uv2s := PackedVector2Array()
var indices := PackedInt32Array()


func vertex_count() -> int:
	return verts.size()


func triangle_count() -> int:
	return int(indices.size() / 3.0)


## Appends one vertex and returns its index.
func vertex(p: Vector3, n: Vector3, c: Color, uv: Vector2 = Vector2.ZERO, uv2: Vector2 = Vector2.ZERO) -> int:
	verts.append(p)
	normals.append(n)
	colors.append(c)
	uvs.append(uv)
	uv2s.append(uv2)
	return verts.size() - 1


## Triangle a-b-c wound so its front face (Godot: clockwise) faces `outward`.
func tri(a: int, b: int, c: int, outward: Vector3) -> void:
	var fn := (verts[c] - verts[a]).cross(verts[b] - verts[a])
	indices.append(a)
	if fn.dot(outward) < 0.0:
		indices.append(c)
		indices.append(b)
	else:
		indices.append(b)
		indices.append(c)


## Quad a-b-c-d (a loop) as two triangles facing `outward`.
func quad_idx(a: int, b: int, c: int, d: int, outward: Vector3) -> void:
	tri(a, b, c, outward)
	tri(a, c, d, outward)


## A flat quad with its own four vertices (flat shading), facing `outward`.
func flat_quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, outward: Vector3, col: Color,
		uv2: Vector2 = Vector2.ZERO) -> void:
	var n := (c - a).cross(b - a)
	if n.length_squared() <= 0.0:
		return
	n = n.normalized()
	if n.dot(outward) < 0.0:
		n = -n
	var i0 := vertex(a, n, col, Vector2.ZERO, uv2)
	var i1 := vertex(b, n, col, Vector2.ZERO, uv2)
	var i2 := vertex(c, n, col, Vector2.ZERO, uv2)
	var i3 := vertex(d, n, col, Vector2.ZERO, uv2)
	quad_idx(i0, i1, i2, i3, n)


## Appends a whole mesh surface (Mesh.surface_get_arrays, world conventions)
## transformed by `xf`: triangle soup or indexed. Its vertices get COLOR.a = 0 and
## UV2 = (UV2.x of the mesh, 0) (feature shaders read COLOR.a as "not water").
func append_arrays(arrays: Array, xf: Transform3D) -> void:
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var c: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var u2: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2] if arrays[Mesh.ARRAY_TEX_UV2] != null else PackedVector2Array()
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var base := verts.size()
	var nb := xf.basis.inverse().transposed()
	for i in v.size():
		var col := c[i]
		col.a = 0.0
		vertex(xf * v[i], (nb * n[i]).normalized(), col, Vector2.ZERO,
			Vector2(u2[i].x if i < u2.size() else 0.0, 0.0))
	if idx.is_empty():
		for i in v.size():
			indices.append(base + i)
	else:
		for i in idx:
			indices.append(base + i)


## Replaces `mesh`'s surfaces (none when empty).
func commit(mesh: ArrayMesh) -> void:
	mesh.clear_surfaces()
	if indices.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
