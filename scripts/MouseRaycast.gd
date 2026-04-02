extends Node

@export var camera: Camera3D
@export var raycast_length: float = 1000.0

var last_valid_world_pos: Vector3 = Vector3.ZERO
var last_valid_tile: Vector2i = Vector2i.ZERO

func get_world_position_under_mouse() -> Vector3:
	var viewport := get_viewport()
	var mouse_pos := viewport.get_mouse_position()

	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir := camera.project_ray_normal(mouse_pos)
	var floor_y : float = App.get_floor_service().get_current_y_offset()

	# Intersect with the active build floor plane.
	if abs(ray_dir.y) < 0.001:
		return last_valid_world_pos  # ray is nearly parallel to ground

	var t := (floor_y - ray_origin.y) / ray_dir.y
	if t < 0.0:
		return last_valid_world_pos  # intersection is behind camera

	var hit := ray_origin + ray_dir * t
	last_valid_world_pos = hit
	last_valid_tile = App.get_grid_service().world_to_tile(hit)
	return hit

func get_tile_under_mouse() -> Vector2i:
	get_world_position_under_mouse()
	return last_valid_tile
