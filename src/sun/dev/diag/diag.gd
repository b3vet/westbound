extends Node3D

const VALS := [0.02, 0.05, 0.1, 0.2, 0.3, 0.5, 0.8, 1.0]

func _ready() -> void:
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 8.0
	cam.position = Vector3(0, 0, 5)
	add_child(cam)
	var sh: Shader = load("res://src/sun/dev/diag/diag.gdshader")
	# rows: modes 0..6 ; columns: values
	for row in 7:
		for col in VALS.size():
			var v: float = VALS[col]
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			var x0 := -6.5 + col * 1.6
			var y0 := 3.2 - row * 1.0
			var pts := [Vector3(x0, y0 - 0.9, 0), Vector3(x0 + 1.5, y0 - 0.9, 0), Vector3(x0 + 1.5, y0, 0), Vector3(x0, y0, 0)]
			for k in [0, 1, 2, 0, 2, 3]:
				st.set_color(Color(v, v, v))
				st.add_vertex(pts[k])
			var mi := MeshInstance3D.new()
			mi.mesh = st.commit()
			var m := ShaderMaterial.new()
			m.shader = sh
			m.set_shader_parameter("mode", row)
			m.set_shader_parameter("val", v)
			m.set_shader_parameter("u_src", Color(v, v, v))
			m.set_shader_parameter("u_plain", Color(v, v, v))
			mi.material_override = m
			# global can only have one value: use per-instance? use row 2 with 0.5 only
			add_child(mi)
	RenderingServer.global_shader_parameter_set(&"wb_road_tone", Color(0.2, 0.2, 0.2, 1.0))
	RenderingServer.global_shader_parameter_set(&"wb_ambient", Color(0.2, 0.2, 0.2, 1.0))
