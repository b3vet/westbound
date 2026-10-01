class_name NetCloudSaveTarget
extends RefCounted
## The local save as NetCloudSave sees it: read a snapshot, put a merged document in place,
## and whether that may happen now. This default is the `Save` autoload (and `Game` for
## "not mid-run"); tests hand NetCloudSave an in-memory one. WP N11; docs/SAVE.md → Cloud
## sync.


## A deep copy of the local document (settings included).
func snapshot() -> Dictionary:
	return Save.snapshot()


## The document may be replaced now (not mid-run, not a newer build's read-only save).
func can_apply() -> bool:
	return Save.can_apply_cloud()


## Puts `doc` in place (a backup of the old one is kept). False when it may not now.
func apply(doc: Dictionary) -> bool:
	return Save.apply_cloud(doc)


## A newer build's save: never uploaded over (it would lose what this build cannot read).
func read_only() -> bool:
	return Save.read_only


## A sync may run now (not during gameplay: never take time from a run).
func idle() -> bool:
	return Game.state != Game.RUNNING
