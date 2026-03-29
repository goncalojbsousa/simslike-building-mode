# grid_manager.gd
extends Node

const TILE_SIZE = 2.0  # world units per tile

var tiles: Dictionary = {}      # Vector2i -> {occupied: bool, type: String}
var walls: Dictionary = {}      # String key -> bool
var furniture: Dictionary = {}  # Vector2i -> Node3D

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
