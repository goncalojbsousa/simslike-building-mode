extends Node

# --- Storage ---
var _placed: Dictionary = {}   # Vector2i -> FurniturePlacement
var _free_placements: Array = []   # Array[FurniturePlacement]

# --- Signals ---
signal furniture_placed(tile: Vector2i)
signal furniture_removed(tile: Vector2i)

class FurniturePlacement:
	var tile: Vector2i
	var scene_path: String
	var rotation_index: int = 0   # 0=0°, 1=90°, 2=180°, 3=270°
	var node: Node3D = null
	var size: Vector2i = Vector2i(1, 1)   # tiles occupied (W × H)
	var uses_grid_occupancy: bool = true
	var collision_half_extents: Vector2 = Vector2.ZERO

	func _init(
			t: Vector2i,
			path: String,
			rot: int,
			sz: Vector2i,
			grid_occupancy: bool = true,
			collision_half: Vector2 = Vector2.ZERO
	) -> void:
		tile = t
		scene_path = path
		rotation_index = rot
		size = sz
		uses_grid_occupancy = grid_occupancy
		collision_half_extents = collision_half

func _resolve_target_container(container: Node3D) -> Node3D:
	if is_instance_valid(container):
		return container

	var scene := get_tree().current_scene
	if scene is Node3D:
		return scene as Node3D

	return null

# -------------------------------------------------------
# Queries
# -------------------------------------------------------

func get_snapped_world_position(tile: Vector2i, size: Vector2i, rotation_index: int) -> Vector3:
	var occupied := _get_occupied_tiles(tile, size, rotation_index)
	if occupied.is_empty():
		return GridManager.tile_to_world(tile)

	var sum := Vector3.ZERO
	for t in occupied:
		sum += GridManager.tile_to_world(t)
	return sum / float(occupied.size())

func can_place(tile: Vector2i, size: Vector2i, rotation_index: int) -> bool:
	var tiles := _get_occupied_tiles(tile, size, rotation_index)
	if tiles.is_empty():
		return false

	var world_pos := get_snapped_world_position(tile, size, rotation_index)
	if _overlaps_existing_furniture(world_pos, size, rotation_index):
		return false

	var occupied_lookup: Dictionary = {}
	for t in tiles:
		if GridManager.is_tile_occupied(t):
			return false
		occupied_lookup[t] = true

	# If a wall runs between any 2 tiles inside the furniture footprint,
	# placement would visually intersect the wall.
	for t in tiles:
		var neighbors := [
			Vector2i(t.x + 1, t.y),
			Vector2i(t.x - 1, t.y),
			Vector2i(t.x, t.y + 1),
			Vector2i(t.x, t.y - 1),
		]
		for n in neighbors:
			if occupied_lookup.has(n) and WallSystem.has_wall(t, n):
				return false

	return true

func can_place_free_world(
		world_pos: Vector3,
		size: Vector2i,
		rotation_index: int,
		candidate_half_extents: Vector2 = Vector2.ZERO
) -> bool:
	if _overlaps_existing_furniture(world_pos, size, rotation_index, candidate_half_extents):
		return false

	if _overlaps_any_wall(world_pos, size, rotation_index, candidate_half_extents):
		return false

	return true

func has_furniture_blocking_wall(from_tile: Vector2i, to_tile: Vector2i) -> bool:
	var wall_a: Vector3 = GridManager.tile_to_world(from_tile)
	var wall_b: Vector3 = GridManager.tile_to_world(to_tile)
	var wall_center := Vector2((wall_a.x + wall_b.x) * 0.5, (wall_a.z + wall_b.z) * 0.5)
	var wall_half := _wall_half_extents_from_tiles(from_tile, to_tile)

	for placement in _all_placements():
		if not is_instance_valid(placement.node):
			continue
		var furniture_half := _placement_half_extents(placement)
		var furniture_center := Vector2(placement.node.global_position.x, placement.node.global_position.z)
		if _rects_overlap(furniture_center, furniture_half, wall_center, wall_half):
			return true

	return false

func _all_placements() -> Array:
	var result: Array = []
	result.append_array(_placed.values())
	result.append_array(_free_placements)
	return result

func _overlaps_existing_furniture(
		world_pos: Vector3,
		size: Vector2i,
		rotation_index: int,
		candidate_half_extents: Vector2 = Vector2.ZERO
) -> bool:
	var half := candidate_half_extents if candidate_half_extents != Vector2.ZERO else _get_world_half_extents(size, rotation_index)
	var center := Vector2(world_pos.x, world_pos.z)

	for placement in _all_placements():
		if not is_instance_valid(placement.node):
			continue
		var other_half := _placement_half_extents(placement)
		var other_center := Vector2(placement.node.global_position.x, placement.node.global_position.z)
		if _rects_overlap(center, half, other_center, other_half):
			return true

	return false

func _overlaps_any_wall(
		world_pos: Vector3,
		size: Vector2i,
		rotation_index: int,
		candidate_half_extents: Vector2 = Vector2.ZERO
) -> bool:
	var half := candidate_half_extents if candidate_half_extents != Vector2.ZERO else _get_world_half_extents(size, rotation_index)
	var center := Vector2(world_pos.x, world_pos.z)

	for wall_data in WallSystem.get_all_walls():
		var wall_a: Vector3 = GridManager.tile_to_world(wall_data.from_tile)
		var wall_b: Vector3 = GridManager.tile_to_world(wall_data.to_tile)
		var wall_center := Vector2((wall_a.x + wall_b.x) * 0.5, (wall_a.z + wall_b.z) * 0.5)
		var wall_half := _wall_half_extents_from_tiles(wall_data.from_tile, wall_data.to_tile)
		if _rects_overlap(center, half, wall_center, wall_half):
			return true

	return false

func _placement_half_extents(placement: FurniturePlacement) -> Vector2:
	if placement.collision_half_extents != Vector2.ZERO:
		return placement.collision_half_extents
	return _get_world_half_extents(placement.size, placement.rotation_index)

func _compute_mesh_half_extents_xz(root: Node3D) -> Vector2:
	var bounds := _compute_mesh_bounds_xz(root)
	if not bounds["valid"]:
		return Vector2.ZERO

	var min_v: Vector2 = bounds["min"]
	var max_v: Vector2 = bounds["max"]
	var size := max_v - min_v
	return Vector2(maxf(size.x * 0.5, 0.01), maxf(size.y * 0.5, 0.01))

func _compute_mesh_bounds_xz(root: Node3D) -> Dictionary:
	var result := {
		"valid": false,
		"min": Vector2.ZERO,
		"max": Vector2.ZERO,
	}
	_collect_mesh_bounds_xz(root, result)
	return result

func _collect_mesh_bounds_xz(node: Node, result: Dictionary) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh != null:
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

			for c in corners:
				var wp: Vector3 = mesh_instance.global_transform * c
				var p2 := Vector2(wp.x, wp.z)
				if not result["valid"]:
					result["valid"] = true
					result["min"] = p2
					result["max"] = p2
				else:
					result["min"] = Vector2(minf(result["min"].x, p2.x), minf(result["min"].y, p2.y))
					result["max"] = Vector2(maxf(result["max"].x, p2.x), maxf(result["max"].y, p2.y))

	for child in node.get_children():
		_collect_mesh_bounds_xz(child, result)

func _wall_half_extents_from_tiles(from_tile: Vector2i, to_tile: Vector2i) -> Vector2:
	var wall_diff: Vector2i = to_tile - from_tile
	if wall_diff.x != 0:
		# Shared vertical edge (parallel to Z)
		return Vector2(0.08, GridManager.TILE_SIZE * 0.5)
	# Shared horizontal edge (parallel to X)
	return Vector2(GridManager.TILE_SIZE * 0.5, 0.08)

func _get_occupied_tiles(origin: Vector2i, size: Vector2i, rotation_index: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var dims := _get_rotated_size(size, rotation_index)
	var w := dims.x
	var h := dims.y
	var start := _get_centered_start_tile(origin, dims)
	for x in range(w):
		for y in range(h):
			result.append(start + Vector2i(x, y))
	return result

func _get_rotated_size(size: Vector2i, rotation_index: int) -> Vector2i:
	if rotation_index % 2 == 0:
		return size
	return Vector2i(size.y, size.x)

func _get_centered_start_tile(origin: Vector2i, dims: Vector2i) -> Vector2i:
	# Even footprints are centered between 2 cells by biasing one tile negative.
	var start_x := origin.x - int(ceili((dims.x - 1) * 0.5))
	var start_y := origin.y - int(ceili((dims.y - 1) * 0.5))
	return Vector2i(start_x, start_y)

func _get_world_half_extents(size: Vector2i, rotation_index: int) -> Vector2:
	var safe_size := size
	if safe_size == Vector2i.ZERO:
		safe_size = Vector2i.ONE
	var dims := _get_rotated_size(safe_size, rotation_index)
	return Vector2(
		dims.x * GridManager.TILE_SIZE * 0.5 * 0.95,
		dims.y * GridManager.TILE_SIZE * 0.5 * 0.95
	)

func _rects_overlap(a_center: Vector2, a_half: Vector2, b_center: Vector2, b_half: Vector2) -> bool:
	return (
		abs(a_center.x - b_center.x) < (a_half.x + b_half.x) and
		abs(a_center.y - b_center.y) < (a_half.y + b_half.y)
	)

# -------------------------------------------------------
# Placement
# -------------------------------------------------------

func place_furniture(
		tile: Vector2i,
		scene_path: String,
		size: Vector2i,
		rotation_index: int,
		container: Node3D
) -> bool:
	var target_container := _resolve_target_container(container)
	if target_container == null:
		push_error("FurnitureSystem: no valid container to place furniture.")
		return false

	if not can_place(tile, size, rotation_index):
		return false

	var scene: PackedScene = load(scene_path)
	if scene == null:
		push_error("FurnitureSystem: scene not found at " + scene_path)
		return false

	var instance: Node3D = scene.instantiate()
	target_container.add_child(instance)

	# Position at footprint center
	instance.global_position = get_snapped_world_position(tile, size, rotation_index)
	instance.rotation_degrees.y = rotation_index * 90.0
	var collision_half := _compute_mesh_half_extents_xz(instance)
	if collision_half == Vector2.ZERO:
		collision_half = _get_world_half_extents(size, rotation_index)

	# Mark tiles occupied
	var occupied := _get_occupied_tiles(tile, size, rotation_index)
	for t in occupied:
		GridManager.set_tile_occupied(t, true)

	var placement := FurniturePlacement.new(tile, scene_path, rotation_index, size, true, collision_half)
	placement.node = instance
	_placed[tile] = placement

	furniture_placed.emit(tile)
	return true

func remove_furniture(tile: Vector2i) -> bool:
	if not _placed.has(tile):
		return false

	var placement: FurniturePlacement = _placed[tile]
	if placement.uses_grid_occupancy:
		var occupied := _get_occupied_tiles(placement.tile, placement.size, placement.rotation_index)
		for t in occupied:
			GridManager.set_tile_occupied(t, false)

	placement.node.queue_free()
	_placed.erase(tile)
	furniture_removed.emit(tile)
	return true


# Used by both snapped and free placement
func place_furniture_at(
		tile: Vector2i,
		world_pos: Vector3,
		rotation_index: int,
		scene_path: String,
		size: Vector2i,
		container: Node3D,
		use_grid_occupancy: bool = true
) -> bool:
	var target_container := _resolve_target_container(container)
	if target_container == null:
		push_error("FurnitureSystem: no valid container to place furniture.")
		return false

	var scene: PackedScene = load(scene_path)
	if scene == null:
		push_error("FurnitureSystem: scene not found: " + scene_path)
		return false

	var instance: Node3D = scene.instantiate()
	target_container.add_child(instance)
	instance.global_position = world_pos
	instance.rotation_degrees.y = rotation_index * 90.0
	var collision_half := _compute_mesh_half_extents_xz(instance)
	if collision_half == Vector2.ZERO:
		collision_half = _get_world_half_extents(size, rotation_index)

	# Grid occupancy is optional (disabled in free mode).
	if use_grid_occupancy and size != Vector2i.ZERO:
		var occupied := _get_occupied_tiles(tile, size, rotation_index)
		for t in occupied:
			GridManager.set_tile_occupied(t, true)

	var placement := FurniturePlacement.new(tile, scene_path, rotation_index, size, use_grid_occupancy, collision_half)
	placement.node = instance
	if use_grid_occupancy:
		_placed[tile] = placement
	else:
		_free_placements.append(placement)
	furniture_placed.emit(tile)
	return true

# Removes by tile key (snapped mode)
func remove_furniture_at_tile(tile: Vector2i) -> bool:
	return remove_furniture(tile)   # your existing method

# Removes by approximate world position (free mode)
func remove_furniture_at_world(world_pos: Vector3) -> bool:
	var best_index := -1
	var best_distance := INF
	for i in range(_free_placements.size()):
		var free_placement: FurniturePlacement = _free_placements[i]
		if not is_instance_valid(free_placement.node):
			continue
		var d := free_placement.node.global_position.distance_to(world_pos)
		if d < GridManager.TILE_SIZE and d < best_distance:
			best_distance = d
			best_index = i

	if best_index >= 0:
		var removed: FurniturePlacement = _free_placements[best_index]
		if is_instance_valid(removed.node):
			removed.node.queue_free()
		_free_placements.remove_at(best_index)
		furniture_removed.emit(removed.tile)
		return true

	var closest_tile := GridManager.world_to_tile(world_pos)
	# Search a small radius around the tile in case of float rounding
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var t := closest_tile + Vector2i(dx, dy)
			if _placed.has(t):
				var p: FurniturePlacement = _placed[t]
				if p.node.global_position.distance_to(world_pos) < GridManager.TILE_SIZE:
					return remove_furniture(t)
	return false
