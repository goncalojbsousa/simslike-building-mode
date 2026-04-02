class_name FloorService
extends Node

const FLOOR_HEIGHT: float = 3.2   # world units between floors
const MAX_FLOORS: int = 5

var current_floor: int = 0

signal floor_changed(old_floor: int, new_floor: int)

func get_floor_y_offset(floor_index: int) -> float:
	return floor_index * FLOOR_HEIGHT

func get_current_y_offset() -> float:
	return get_floor_y_offset(current_floor)

func go_up() -> void:
	if current_floor >= MAX_FLOORS - 1:
		return
	# Can only go up if floor below has structure
	if not _has_structure_on_floor(current_floor):
		return
	var old := current_floor
	current_floor += 1
	floor_changed.emit(old, current_floor)

func go_down() -> void:
	if current_floor <= 0:
		return
	var old := current_floor
	current_floor -= 1
	floor_changed.emit(old, current_floor)

func _has_structure_on_floor(floor_index: int) -> bool:
	# Check if any wall exists on this floor
	for key in App.get_wall_service().get_all_wall_keys():
		if App.get_wall_service().get_floor_from_key(key) == floor_index:
			return true
	return false
