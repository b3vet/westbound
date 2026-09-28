class_name RoadsidePool
extends RefCounted
## One MultiMeshInstance3D (one mesh, one draw call) with a fixed-capacity,
## densely packed instance buffer. Spec: World → Road ("Roadside rhythm (all
## MultiMeshInstance3D)"); Performance budget (draw calls, triangles).
##
## Instances belong to blocks (a layer's ring of s-cells). Adding appends at
## `count`; clearing a block swap-removes its instances, so live instances stay
## in [0, count) and `visible_instance_count = count`: no hidden instances are
## drawn. Everything is allocated in `build`; afterwards nothing grows.
## The CPU buffer is the source of truth (it is also what tests read) and is
## uploaded once per change with RenderingServer.multimesh_set_buffer.

const FLOATS := 12

var mesh: Mesh
var mmi: MultiMeshInstance3D
var multimesh: MultiMesh
## Row-major 3x4 transforms (MultiMesh TRANSFORM_3D layout).
var buf := PackedFloat32Array()
var capacity: int = 0
var count: int = 0
var per_block: int = 0
## Instances dropped because a block was full (sizing error; tests assert 0).
var dropped: int = 0
var triangles_per_instance: int = 0
var dirty: bool = false

var _slot_block := PackedInt32Array()
var _slot_pos := PackedInt32Array()
var _block_slots := PackedInt32Array()
var _block_count := PackedInt32Array()


func _init(pool_mesh: Mesh, max_per_block: int) -> void:
	mesh = pool_mesh
	per_block = max_per_block
	var faces := 0
	for i in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(i)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		faces += int((idx.size() if idx.size() > 0 else verts.size()) / 3.0)
	triangles_per_instance = faces


func build(parent: Node3D, blocks: int, node_name: String) -> void:
	capacity = blocks * per_block
	buf.resize(capacity * FLOATS)
	buf.fill(0.0)
	_slot_block.resize(capacity)
	_slot_pos.resize(capacity)
	_block_slots.resize(capacity)
	_block_count.resize(blocks)
	_block_count.fill(0)
	count = 0
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = capacity
	multimesh.visible_instance_count = 0
	mmi = MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = multimesh
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	mmi.visible = false
	parent.add_child(mmi)


## Appends one instance to `block`. Returns false (and counts a drop) when full.
func add(block: int, b: Basis, o: Vector3) -> bool:
	var n := _block_count[block]
	if n >= per_block or count >= capacity:
		dropped += 1
		return false
	var i := count
	_write(i, b, o)
	_slot_block[i] = block
	_slot_pos[i] = n
	_block_slots[block * per_block + n] = i
	_block_count[block] = n + 1
	count += 1
	dirty = true
	return true


## Removes every instance of `block` (swap-remove keeps the buffer dense).
func clear_block(block: int) -> void:
	var n := _block_count[block]
	if n == 0:
		return
	for k in range(n - 1, -1, -1):
		_remove(_block_slots[block * per_block + k])
	_block_count[block] = 0
	dirty = true


func block_count(block: int) -> int:
	return _block_count[block]


## Uploads the buffer if it changed. Allocation-free on our side.
func flush() -> void:
	if not dirty:
		return
	dirty = false
	RenderingServer.multimesh_set_buffer(multimesh.get_rid(), buf)
	multimesh.visible_instance_count = count
	mmi.visible = count > 0


## Moves every live instance by (dx, dy, dz): re-anchoring after an origin shift
## without re-placing anything. Each instance picks up at most half a float32 ulp
## of its (few-km) local position per re-anchor, and lives through one or two.
func translate(dx: float, dy: float, dz: float) -> void:
	for i in count:
		var k := i * FLOATS
		buf[k + 3] = buf[k + 3] + dx
		buf[k + 7] = buf[k + 7] + dy
		buf[k + 11] = buf[k + 11] + dz
	dirty = dirty or count > 0


## Instance `i` as a Transform3D, relative to the node (tests, tools).
func get_transform(i: int) -> Transform3D:
	var o := i * FLOATS
	return Transform3D(
		Vector3(buf[o], buf[o + 4], buf[o + 8]),
		Vector3(buf[o + 1], buf[o + 5], buf[o + 9]),
		Vector3(buf[o + 2], buf[o + 6], buf[o + 10]),
		Vector3(buf[o + 3], buf[o + 7], buf[o + 11]))


func _write(i: int, b: Basis, o: Vector3) -> void:
	var k := i * FLOATS
	buf[k] = b.x.x
	buf[k + 1] = b.y.x
	buf[k + 2] = b.z.x
	buf[k + 3] = o.x
	buf[k + 4] = b.x.y
	buf[k + 5] = b.y.y
	buf[k + 6] = b.z.y
	buf[k + 7] = o.y
	buf[k + 8] = b.x.z
	buf[k + 9] = b.y.z
	buf[k + 10] = b.z.z
	buf[k + 11] = o.z


func _remove(i: int) -> void:
	var last := count - 1
	if i != last:
		var src := last * FLOATS
		var dst := i * FLOATS
		for f in FLOATS:
			buf[dst + f] = buf[src + f]
		var blk := _slot_block[last]
		var pos := _slot_pos[last]
		_slot_block[i] = blk
		_slot_pos[i] = pos
		_block_slots[blk * per_block + pos] = i
	var lo := last * FLOATS
	for f in FLOATS:
		buf[lo + f] = 0.0
	count = last
