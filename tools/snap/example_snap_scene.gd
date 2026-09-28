extends Node3D
## Example scene for tools/snap.sh (review tooling, plan §3): shows the
## snap_setup hook. Try:
##   tools/snap.sh tools/snap/example_snap_scene.tscn --sweep=sky_t:0,0.5,1 --label=hello
## sky_t blends the background and cube color from dawn blue to sunset orange.

const DAY_TOP := Color(0.35, 0.55, 0.85)
const DUSK_TOP := Color(0.95, 0.45, 0.2)

@onready var _cube: MeshInstance3D = $Cube
@onready var _label: Label = $UI/Label


func snap_setup(args: Dictionary) -> void:
	var t := clampf(float(args.get("sky_t", 0.0)), 0.0, 1.0)
	RenderingServer.set_default_clear_color(DAY_TOP.lerp(DUSK_TOP, t).darkened(0.5))
	var mat := _cube.get_surface_override_material(0) as ShaderMaterial
	mat.set_shader_parameter("albedo", DAY_TOP.lerp(DUSK_TOP, t))
	_label.text = "snap_setup %s" % str(args)
