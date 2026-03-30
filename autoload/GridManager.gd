# grid_manager.gd
extends Node

const TILE_SIZE = 2.0  # world units per tile

var tiles: Dictionary = {}      # Vector2i -> {occupied: bool, type: String}
var walls: Dictionary = {}      # String key -> bool
var furniture: Dictionary = {}  # Vector2i -> Node3D

func _get_or_create_tile_data(tile: Vector2i) -> Dictionary:
	if not tiles.has(tile):
		tiles[tile] = {
			"occupied": false,
			"type": "empty",
		}
	return tiles[tile]

func is_tile_occupied(tile: Vector2i) -> bool:
	if not tiles.has(tile):
		return false
	var data : Dictionary = tiles[tile]
	if data is Dictionary and data.has("occupied"):
		return bool(data["occupied"])
	return false

func set_tile_occupied(tile: Vector2i, occupied: bool) -> void:
	var data := _get_or_create_tile_data(tile)
	data["occupied"] = occupied
	tiles[tile] = data

func world_to_tile(world_pos: Vector3) -> Vector2i:
	return Vector2i(
		floori(world_pos.x / TILE_SIZE),
		floori(world_pos.z / TILE_SIZE)
	)

func tile_to_world(tile: Vector2i) -> Vector3:
	return Vector3(
		(tile.x + 0.5) * TILE_SIZE,
		0.0,
		(tile.y + 0.5) * TILE_SIZE
	)

func snap_to_tile_center(world_pos: Vector3) -> Vector3:
	return tile_to_world(world_to_tile(world_pos))
	
func tile_to_world_on_floor(tile: Vector2i, floor_index: int) -> Vector3:
	var base := tile_to_world(tile)
	base.y = FloorManager.get_floor_y_offset(floor_index)
	return base

func get_wall_y_base(floor_index: int) -> float:
	return FloorManager.get_floor_y_offset(floor_index)
