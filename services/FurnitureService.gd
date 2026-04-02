class_name FurnitureService
extends Node

# --- Storage ---
var _placed: Dictionary = {}   # "x,y,floor" -> FurniturePlacement
var _free_placements: Array = []   # Array[FurniturePlacement]

# --- Signals ---
signal furniture_placed(tile: Vector2i)
signal furniture_removed(tile: Vector2i)

class FurniturePlacement:
	var tile: Vector2i
	var floor_index: int = 0
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
			collision_half: Vector2 = Vector2.ZERO,
			f: int = 0
	) -> void:
		tile = t
		floor_index = f
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

func _grid_key(tile: Vector2i, floor_index: int) -> String:
	return "%d,%d,%d" % [tile.x, tile.y, floor_index]

func _world_y_to_floor_index(world_y: float) -> int:
	if App.get_floor_service().FLOOR_HEIGHT <= 0.0:
		return App.get_floor_service().current_floor
	return clampi(roundi(world_y / App.get_floor_service().FLOOR_HEIGHT), 0, App.get_floor_service().MAX_FLOORS - 1)

func _placement_floor_index(placement: FurniturePlacement) -> int:
	if placement == null:
		return App.get_floor_service().current_floor
	return placement.floor_index

# -------------------------------------------------------
# Queries
# -------------------------------------------------------

func get_snapped_world_position(tile: Vector2i, size: Vector2i, rotation_index: int) -> Vector3:
	var floor_index : int = App.get_floor_service().current_floor
	var occupied := _get_occupied_tiles(tile, size, rotation_index)
	if occupied.is_empty():
		return App.get_grid_service().tile_to_world_on_floor(tile, floor_index)

	var sum := Vector3.ZERO
	for t in occupied:
		sum += App.get_grid_service().tile_to_world_on_floor(t, floor_index)
	return sum / float(occupied.size())

func can_place(tile: Vector2i, size: Vector2i, rotation_index: int) -> bool:
	var floor_index : int = App.get_floor_service().current_floor
	var tiles := _get_occupied_tiles(tile, size, rotation_index)
	if tiles.is_empty():
		return false

	var world_pos := get_snapped_world_position(tile, size, rotation_index)
	if _overlaps_existing_furniture(world_pos, size, rotation_index, Vector2.ZERO, floor_index):
		return false

	var occupied_lookup: Dictionary = {}
	for t in tiles:
		if App.get_grid_service().is_tile_occupied(t, floor_index):
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
			if occupied_lookup.has(n) and App.get_wall_service().has_wall(t, n, floor_index):
				return false

	return true

func can_place_free_world(
		world_pos: Vector3,
		size: Vector2i,
		rotation_index: int,
		candidate_half_extents: Vector2 = Vector2.ZERO
) -> bool:
	var floor_index := _world_y_to_floor_index(world_pos.y)
	if _overlaps_existing_furniture(world_pos, size, rotation_index, candidate_half_extents, floor_index):
		return false

	if _overlaps_any_wall(world_pos, size, rotation_index, candidate_half_extents, floor_index):
		return false

	return true

func has_furniture_blocking_wall(from_tile: Vector2i, to_tile: Vector2i, floor_index: int = -1) -> bool:
	var f : int = floor_index if floor_index >= 0 else App.get_floor_service().current_floor
	var wall_a: Vector3 = App.get_grid_service().tile_to_world(from_tile)
	var wall_b: Vector3 = App.get_grid_service().tile_to_world(to_tile)
	var wall_center := Vector2((wall_a.x + wall_b.x) * 0.5, (wall_a.z + wall_b.z) * 0.5)
	var wall_half := _wall_half_extents_from_tiles(from_tile, to_tile)

	for placement in _all_placements():
		if not is_instance_valid(placement.node):
			continue
		if _placement_floor_index(placement) != f:
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

func get_all_snapshots() -> Array[Dictionary]:
	var snapshots: Array[Dictionary] = []
	for placement in _all_placements():
		var snapshot := _make_snapshot(placement)
		if snapshot.is_empty():
			continue
		snapshots.append(snapshot)
	return snapshots

func clear_all() -> void:
	for placement_key_value in _placed.keys():
		var placement_key := str(placement_key_value)
		var placement: FurniturePlacement = _placed[placement_key]
		if placement == null:
			continue
		if placement.uses_grid_occupancy:
			var occupied := _get_occupied_tiles(placement.tile, placement.size, placement.rotation_index)
			for t in occupied:
				App.get_grid_service().set_tile_occupied(t, false, placement.floor_index)
		if is_instance_valid(placement.node):
			placement.node.queue_free()

	for placement in _free_placements:
		if placement == null:
			continue
		if is_instance_valid(placement.node):
			placement.node.queue_free()

	_placed.clear()
	_free_placements.clear()

func get_object_node_ids_in_tiles(tile_set: Dictionary) -> Array[int]:
	var ids_lookup: Dictionary = {}
	var floor_index : int = App.get_floor_service().current_floor
	for placement in _all_placements():
		if placement == null or not is_instance_valid(placement.node):
			continue
		if _placement_floor_index(placement) != floor_index:
			continue
		var world_tile : Vector2i = App.get_grid_service().world_to_tile(placement.node.global_position)
		if not tile_set.has(world_tile):
			continue
		ids_lookup[placement.node.get_instance_id()] = true

	var ids: Array[int] = []
	for id_value in ids_lookup.keys():
		ids.append(int(id_value))
	return ids

func _translate_grid_placement(tile_key: String, placement: FurniturePlacement, delta_tiles: Vector2i) -> bool:
	if placement == null or not is_instance_valid(placement.node):
		return false
	var floor_index := placement.floor_index

	if placement.uses_grid_occupancy:
		var old_occupied := _get_occupied_tiles(placement.tile, placement.size, placement.rotation_index)
		for t in old_occupied:
			App.get_grid_service().set_tile_occupied(t, false, floor_index)

	placement.tile += delta_tiles
	placement.node.global_position += Vector3(delta_tiles.x * App.get_grid_service().TILE_SIZE, 0.0, delta_tiles.y * App.get_grid_service().TILE_SIZE)

	if placement.uses_grid_occupancy:
		var new_occupied := _get_occupied_tiles(placement.tile, placement.size, placement.rotation_index)
		for t in new_occupied:
			App.get_grid_service().set_tile_occupied(t, true, floor_index)

	_placed.erase(tile_key)
	_placed[_grid_key(placement.tile, floor_index)] = placement
	return true

func _translate_free_placement(index: int, placement: FurniturePlacement, delta_tiles: Vector2i) -> bool:
	if index < 0 or index >= _free_placements.size():
		return false
	if placement == null or not is_instance_valid(placement.node):
		return false

	placement.tile += delta_tiles
	placement.node.global_position += Vector3(delta_tiles.x * App.get_grid_service().TILE_SIZE, 0.0, delta_tiles.y * App.get_grid_service().TILE_SIZE)
	_free_placements[index] = placement
	return true

func _translate_object_by_node_id(node_id: int, delta_tiles: Vector2i) -> bool:
	for placement_key_value in _placed.keys():
		var placement_key := str(placement_key_value)
		var placement: FurniturePlacement = _placed[placement_key]
		if placement == null or not is_instance_valid(placement.node):
			continue
		if placement.node.get_instance_id() != node_id:
			continue
		return _translate_grid_placement(placement_key, placement, delta_tiles)

	for i in range(_free_placements.size()):
		var free_placement: FurniturePlacement = _free_placements[i]
		if free_placement == null or not is_instance_valid(free_placement.node):
			continue
		if free_placement.node.get_instance_id() != node_id:
			continue
		return _translate_free_placement(i, free_placement, delta_tiles)

	return false

func translate_objects_by_node_ids(node_ids: Array[int], delta_tiles: Vector2i) -> void:
	if delta_tiles == Vector2i.ZERO:
		return
	for node_id in node_ids:
		_translate_object_by_node_id(int(node_id), delta_tiles)

func _overlaps_existing_furniture(
		world_pos: Vector3,
		size: Vector2i,
		rotation_index: int,
		candidate_half_extents: Vector2 = Vector2.ZERO,
		floor_index: int = -1
) -> bool:
	var f := floor_index if floor_index >= 0 else _world_y_to_floor_index(world_pos.y)
	var half := candidate_half_extents if candidate_half_extents != Vector2.ZERO else _get_world_half_extents(size, rotation_index)
	var center := Vector2(world_pos.x, world_pos.z)

	for placement in _all_placements():
		if not is_instance_valid(placement.node):
			continue
		if _placement_floor_index(placement) != f:
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
		candidate_half_extents: Vector2 = Vector2.ZERO,
		floor_index: int = -1
) -> bool:
	var f := floor_index if floor_index >= 0 else _world_y_to_floor_index(world_pos.y)
	var half := candidate_half_extents if candidate_half_extents != Vector2.ZERO else _get_world_half_extents(size, rotation_index)
	var center := Vector2(world_pos.x, world_pos.z)

	for key in App.get_wall_service().get_wall_keys_for_floor(f):
		var wall_data = App.get_wall_service().get_wall_by_key(key)
		if wall_data == null:
			continue
		var wall_a: Vector3 = App.get_grid_service().tile_to_world(wall_data.from_tile)
		var wall_b: Vector3 = App.get_grid_service().tile_to_world(wall_data.to_tile)
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
		return Vector2(0.08, App.get_grid_service().TILE_SIZE * 0.5)
	# Shared horizontal edge (parallel to X)
	return Vector2(App.get_grid_service().TILE_SIZE * 0.5, 0.08)

func _make_snapshot(placement: FurniturePlacement) -> Dictionary:
	if placement == null or not is_instance_valid(placement.node):
		return {}
	return {
		"node_id": placement.node.get_instance_id(),
		"tile": placement.tile,
		"floor_index": placement.floor_index,
		"scene_path": placement.scene_path,
		"rotation_index": placement.rotation_index,
		"size": placement.size,
		"uses_grid_occupancy": placement.uses_grid_occupancy,
		"world_pos": placement.node.global_position,
	}

func get_snapshot_at_world(world_pos: Vector3, floor_index: int = -1) -> Dictionary:
	var f := floor_index if floor_index >= 0 else _world_y_to_floor_index(world_pos.y)
	var best_snapshot: Dictionary = {}
	var best_distance := INF

	for placement in _all_placements():
		if placement == null or not is_instance_valid(placement.node):
			continue
		if _placement_floor_index(placement) != f:
			continue
		var distance: float = placement.node.global_position.distance_to(world_pos)
		if distance >= App.get_grid_service().TILE_SIZE or distance >= best_distance:
			continue
		var snapshot := _make_snapshot(placement)
		if snapshot.is_empty():
			continue
		best_distance = distance
		best_snapshot = snapshot

	return best_snapshot

func remove_matching_snapshot(snapshot: Dictionary) -> bool:
	if snapshot.is_empty():
		return false

	var floor_index := int(snapshot.get("floor_index", App.get_floor_service().current_floor))
	if bool(snapshot.get("uses_grid_occupancy", true)):
		if not snapshot.has("tile"):
			return false
		var tile: Vector2i = snapshot.get("tile", Vector2i.ZERO)
		return remove_furniture_at_tile(tile, floor_index)

	var world_pos: Vector3 = snapshot.get("world_pos", Vector3.ZERO)
	return remove_furniture_at_world(world_pos, floor_index)

func get_snapshots_blocking_wall(from_tile: Vector2i, to_tile: Vector2i, floor_index: int = -1) -> Array[Dictionary]:
	var f : float = floor_index if floor_index >= 0 else App.get_floor_service().current_floor
	var snapshots: Array[Dictionary] = []
	var wall_a: Vector3 = App.get_grid_service().tile_to_world(from_tile)
	var wall_b: Vector3 = App.get_grid_service().tile_to_world(to_tile)
	var wall_center := Vector2((wall_a.x + wall_b.x) * 0.5, (wall_a.z + wall_b.z) * 0.5)
	var wall_half := _wall_half_extents_from_tiles(from_tile, to_tile)

	for placement in _all_placements():
		if placement == null or not is_instance_valid(placement.node):
			continue
		if _placement_floor_index(placement) != f:
			continue
		var furniture_half := _placement_half_extents(placement)
		var furniture_center := Vector2(placement.node.global_position.x, placement.node.global_position.z)
		if not _rects_overlap(furniture_center, furniture_half, wall_center, wall_half):
			continue
		var snapshot := _make_snapshot(placement)
		if not snapshot.is_empty():
			snapshots.append(snapshot)

	return snapshots

func _remove_by_node_id(node_id: int) -> bool:
	for placement_key_value in _placed.keys():
		var placement_key := str(placement_key_value)
		var placement: FurniturePlacement = _placed[placement_key]
		if placement == null or not is_instance_valid(placement.node):
			continue
		if placement.node.get_instance_id() == node_id:
			return remove_furniture_at_tile(placement.tile, placement.floor_index)

	for i in range(_free_placements.size()):
		var placement: FurniturePlacement = _free_placements[i]
		if placement == null or not is_instance_valid(placement.node):
			continue
		if placement.node.get_instance_id() != node_id:
			continue
		var removed: FurniturePlacement = _free_placements[i]
		if is_instance_valid(removed.node):
			removed.node.queue_free()
		_free_placements.remove_at(i)
		furniture_removed.emit(removed.tile)
		return true

	return false

func handle_invalid_snapshot(snapshot: Dictionary) -> bool:
	# Single hook used by RoomEditor. Replace this method with inventory storage in the future.
	if snapshot.is_empty():
		return false
	if not snapshot.has("node_id"):
		return false
	return _remove_by_node_id(int(snapshot["node_id"]))

func restore_snapshot(snapshot: Dictionary, container: Node3D = null) -> bool:
	if snapshot.is_empty():
		return false
	if not snapshot.has("scene_path"):
		return false

	var tile: Vector2i = snapshot.get("tile", Vector2i.ZERO)
	var world_pos: Vector3 = snapshot.get("world_pos", Vector3.ZERO)
	var rotation_index := int(snapshot.get("rotation_index", 0))
	var scene_path := str(snapshot.get("scene_path", ""))
	var size: Vector2i = snapshot.get("size", Vector2i.ONE)
	var uses_grid := bool(snapshot.get("uses_grid_occupancy", true))
	var floor_index := int(snapshot.get("floor_index", _world_y_to_floor_index(world_pos.y)))

	if scene_path == "":
		return false

	return place_furniture_at(tile, world_pos, rotation_index, scene_path, size, container, uses_grid, floor_index)

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
		dims.x * App.get_grid_service().TILE_SIZE * 0.5 * 0.95,
		dims.y * App.get_grid_service().TILE_SIZE * 0.5 * 0.95
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
	var floor_index : int = App.get_floor_service().current_floor
	var target_container := _resolve_target_container(container)
	if target_container == null:
		push_error("App.get_furniture_service(): no valid container to place furniture.")
		return false

	if not can_place(tile, size, rotation_index):
		return false

	var scene: PackedScene = load(scene_path)
	if scene == null:
		push_error("App.get_furniture_service(): scene not found at " + scene_path)
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
		App.get_grid_service().set_tile_occupied(t, true, floor_index)

	var placement := FurniturePlacement.new(tile, scene_path, rotation_index, size, true, collision_half, floor_index)
	placement.node = instance
	_placed[_grid_key(tile, floor_index)] = placement

	furniture_placed.emit(tile)
	return true

func remove_furniture(tile: Vector2i, floor_index: int = -1) -> bool:
	var f: int = floor_index if floor_index >= 0 else int(App.get_floor_service().current_floor)
	var placement_key := _grid_key(tile, f)
	if not _placed.has(placement_key):
		return false

	var placement: FurniturePlacement = _placed[placement_key]
	if placement.uses_grid_occupancy:
		var occupied := _get_occupied_tiles(placement.tile, placement.size, placement.rotation_index)
		for t in occupied:
			App.get_grid_service().set_tile_occupied(t, false, f)

	placement.node.queue_free()
	_placed.erase(placement_key)
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
		use_grid_occupancy: bool = true,
		floor_index: int = -1
) -> bool:
	var f := floor_index if floor_index >= 0 else _world_y_to_floor_index(world_pos.y)
	var target_container := _resolve_target_container(container)
	if target_container == null:
		push_error("App.get_furniture_service(): no valid container to place furniture.")
		return false

	var scene: PackedScene = load(scene_path)
	if scene == null:
		push_error("App.get_furniture_service(): scene not found: " + scene_path)
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
			App.get_grid_service().set_tile_occupied(t, true, f)

	var placement := FurniturePlacement.new(tile, scene_path, rotation_index, size, use_grid_occupancy, collision_half, f)
	placement.node = instance
	if use_grid_occupancy:
		_placed[_grid_key(tile, f)] = placement
	else:
		_free_placements.append(placement)
	furniture_placed.emit(tile)
	return true

# Removes by tile key (snapped mode)
func remove_furniture_at_tile(tile: Vector2i, floor_index: int = -1) -> bool:
	return remove_furniture(tile, floor_index)

# Removes by approximate world position (free mode)
func remove_furniture_at_world(world_pos: Vector3, floor_index: int = -1) -> bool:
	var f := floor_index if floor_index >= 0 else _world_y_to_floor_index(world_pos.y)
	var best_index := -1
	var best_distance := INF
	for i in range(_free_placements.size()):
		var free_placement: FurniturePlacement = _free_placements[i]
		if not is_instance_valid(free_placement.node):
			continue
		if _placement_floor_index(free_placement) != f:
			continue
		var d := free_placement.node.global_position.distance_to(world_pos)
		if d < App.get_grid_service().TILE_SIZE and d < best_distance:
			best_distance = d
			best_index = i

	if best_index >= 0:
		var removed: FurniturePlacement = _free_placements[best_index]
		if is_instance_valid(removed.node):
			removed.node.queue_free()
		_free_placements.remove_at(best_index)
		furniture_removed.emit(removed.tile)
		return true

	var closest_tile : Vector2i = App.get_grid_service().world_to_tile(world_pos)
	# Search a small radius around the tile in case of float rounding
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var t := closest_tile + Vector2i(dx, dy)
			var key := _grid_key(t, f)
			if _placed.has(key):
				var p: FurniturePlacement = _placed[key]
				if p.node.global_position.distance_to(world_pos) < App.get_grid_service().TILE_SIZE:
					return remove_furniture(t, f)
	return false
