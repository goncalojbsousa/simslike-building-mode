class_name OpeningService
extends Node

signal opening_added(wall_key: String)
signal opening_removed(wall_key: String)

class OpeningData:
	var wall_key: String
	var type: String       # "door" or "window"
	var offset_t: float    # 0.0..1.0 along the wall (0.5 = center)
	var scene_path: String
	var mesh_node: Node3D = null

	func _init(key: String, t: String, off: float, path: String) -> void:
		wall_key   = key
		type       = t
		offset_t   = off
		scene_path = path

var _openings: Dictionary = {}   # wall_key -> OpeningData

func has_opening(wall_key: String) -> bool:
	return _openings.has(wall_key)

func get_opening(wall_key: String) -> OpeningData:
	return _openings.get(wall_key, null)

func get_all_keys() -> Array:
	return _openings.keys()

func place_opening(
		wall_key: String,
		type: String,
		offset_t: float,
		scene_path: String
) -> bool:
	if not App.get_wall_service().get_wall_by_key(wall_key):
		return false   # no wall here
	if _openings.has(wall_key):
		return false   # already has an opening

	var data := OpeningData.new(wall_key, type, offset_t, scene_path)
	_openings[wall_key] = data
	opening_added.emit(wall_key)
	return true

func remove_opening(wall_key: String) -> bool:
	if not _openings.has(wall_key):
		return false
	_openings.erase(wall_key)
	opening_removed.emit(wall_key)
	return true
