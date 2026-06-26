# grid_manager.gd
class_name GridService
extends Node

const TILE_SIZE = GridMath.TILE_SIZE

var tiles: Dictionary = {}      # "x,y,floor" -> {occupied: bool, type: String}
var walls: Dictionary = {}      # String key -> bool
var furniture: Dictionary = {}  # Vector2i -> Node3D

func _tile_key(tile: Vector2i, floor_index: int) -> String:
	return "%d,%d,%d" % [tile.x, tile.y, floor_index]

func _get_or_create_tile_data(tile: Vector2i, floor_index: int) -> Dictionary:
	var key := _tile_key(tile, floor_index)
	if not tiles.has(key):
		tiles[key] = {
			"occupied": false,
			"type": "empty",
		}
	return tiles[key]

func is_tile_occupied(tile: Vector2i, floor_index: int = -1) -> bool:
	var f: int = floor_index if floor_index >= 0 else int(App.get_floor_service().current_floor)
	var key := _tile_key(tile, f)
	if not tiles.has(key):
		return false
	var data : Dictionary = tiles[key]
	if data is Dictionary and data.has("occupied"):
		return bool(data["occupied"])
	return false

func set_tile_occupied(tile: Vector2i, occupied: bool, floor_index: int = -1) -> void:
	var f: int = floor_index if floor_index >= 0 else int(App.get_floor_service().current_floor)
	var data := _get_or_create_tile_data(tile, f)
	data["occupied"] = occupied
	tiles[_tile_key(tile, f)] = data

func world_to_tile(world_pos: Vector3) -> Vector2i:
	return GridMath.world_to_tile(world_pos)

func tile_to_world(tile: Vector2i) -> Vector3:
	return GridMath.tile_to_world(tile)

func snap_to_tile_center(world_pos: Vector3) -> Vector3:
	return GridMath.snap_to_tile_center(world_pos)
	
func tile_to_world_on_floor(tile: Vector2i, floor_index: int) -> Vector3:
	var base := tile_to_world(tile)
	base.y = App.get_floor_service().get_floor_y_offset(floor_index)
	return base

func get_wall_y_base(floor_index: int) -> float:
	return App.get_floor_service().get_floor_y_offset(floor_index)

func _get_ground_grid_node() -> MeshInstance3D:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var ground := scene.get_node_or_null("Ground")
	if ground is MeshInstance3D:
		return ground as MeshInstance3D
	return null

func _get_mesh_bounds_xz(mesh_instance: MeshInstance3D) -> Dictionary:
	if mesh_instance == null or mesh_instance.mesh == null:
		return {"valid": false}

	var aabb := mesh_instance.get_aabb()
	var origin := aabb.position
	var size := aabb.size
	var corners := [
		origin,
		origin + Vector3(size.x, 0.0, 0.0),
		origin + Vector3(0.0, 0.0, size.z),
		origin + Vector3(size.x, 0.0, size.z),
		origin + Vector3(0.0, size.y, 0.0),
		origin + Vector3(size.x, size.y, 0.0),
		origin + Vector3(0.0, size.y, size.z),
		origin + size,
	]

	var min_x := INF
	var min_z := INF
	var max_x := -INF
	var max_z := -INF
	for c in corners:
		var wc: Vector3 = mesh_instance.global_transform * c
		min_x = minf(min_x, wc.x)
		min_z = minf(min_z, wc.z)
		max_x = maxf(max_x, wc.x)
		max_z = maxf(max_z, wc.z)

	return {
		"valid": true,
		"min_x": min_x,
		"min_z": min_z,
		"max_x": max_x,
		"max_z": max_z,
	}

func get_build_bounds_xz() -> Dictionary:
	var ground := _get_ground_grid_node()
	if ground == null:
		return {"valid": false}
	return _get_mesh_bounds_xz(ground)

func is_world_position_inside_build_bounds(world_pos: Vector3, margin: float = 0.0) -> bool:
	var bounds := get_build_bounds_xz()
	if not bool(bounds.get("valid", false)):
		return true

	var min_x := float(bounds["min_x"]) + margin
	var min_z := float(bounds["min_z"]) + margin
	var max_x := float(bounds["max_x"]) - margin
	var max_z := float(bounds["max_z"]) - margin

	return (
		world_pos.x >= min_x and world_pos.x <= max_x
		and world_pos.z >= min_z and world_pos.z <= max_z
	)

func is_world_rect_inside_build_bounds(center_xz: Vector2, half_extents: Vector2, margin: float = 0.0) -> bool:
	var bounds := get_build_bounds_xz()
	if not bool(bounds.get("valid", false)):
		return true

	var min_x := float(bounds["min_x"]) + margin
	var min_z := float(bounds["min_z"]) + margin
	var max_x := float(bounds["max_x"]) - margin
	var max_z := float(bounds["max_z"]) - margin

	return (
		(center_xz.x - half_extents.x) >= min_x
		and (center_xz.x + half_extents.x) <= max_x
		and (center_xz.y - half_extents.y) >= min_z
		and (center_xz.y + half_extents.y) <= max_z
	)

func is_tile_inside_build_bounds(tile: Vector2i) -> bool:
	var world_pos := tile_to_world(tile)
	return is_world_position_inside_build_bounds(world_pos)

func are_tiles_inside_build_bounds(tiles_to_check: Array) -> bool:
	for tile_value in tiles_to_check:
		if not (tile_value is Vector2i):
			return false
		if not is_tile_inside_build_bounds(tile_value as Vector2i):
			return false
	return true
