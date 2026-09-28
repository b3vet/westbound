class_name TouchSlots
extends RefCounted
## Maps engine touch indices to a small fixed range of slots (0..capacity-1).
##
## Godot's web export passes the browser's raw `Touch.identifier` as the touch
## index. Chrome numbers touches 0, 1, 2…, but iOS Safari uses large arbitrary
## ids, so code that indexes arrays by `event.index` silently drops every iPhone
## touch (M2 playtest: no drag steering, no hold-to-brake on the web build).
## Acquire a slot on press, look it up on drag, release it on lift.
## Allocation-free after construction.

const FREE := -1

var _ids := PackedInt64Array()


func _init(capacity: int) -> void:
	_ids.resize(capacity)
	_ids.fill(FREE)


func capacity() -> int:
	return _ids.size()


## Slot already bound to `touch_index`, or -1.
func find(touch_index: int) -> int:
	for i in _ids.size():
		if _ids[i] == touch_index:
			return i
	return FREE


## Slot for a new press (re-uses the slot if this index is already down);
## -1 when every slot is taken.
func acquire(touch_index: int) -> int:
	var slot := find(touch_index)
	if slot != FREE:
		return slot
	for i in _ids.size():
		if _ids[i] == FREE:
			_ids[i] = touch_index
			return i
	return FREE


## Frees the slot bound to `touch_index`; returns it, or -1 if none was bound.
func release(touch_index: int) -> int:
	var slot := find(touch_index)
	if slot != FREE:
		_ids[slot] = FREE
	return slot


func clear() -> void:
	_ids.fill(FREE)
