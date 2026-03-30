extends Node

# The 4 cardinal neighbors of a tile
const NEIGHBORS := [
	Vector2i(1, 0),
	Vector2i(-1, 0),
	Vector2i(0, 1),
	Vector2i(0, -1),
]

# Maximum tiles a flood fill will visit before declaring "open space"
# Set this larger than your biggest possible room
const MAX_FILL_TILES := 10000

func _make_wall_key(a: Vector2i, b: Vector2i, floor_index: int) -> String:
	if a.x < b.x or (a.x == b.x and a.y < b.y):
		if floor_index == 0:
			return "%d,%d|%d,%d" % [a.x, a.y, b.x, b.y]
		return "%d,%d,%d|%d,%d,%d" % [a.x, a.y, floor_index, b.x, b.y, floor_index]
	if floor_index == 0:
		return "%d,%d|%d,%d" % [b.x, b.y, a.x, a.y]
	return "%d,%d,%d|%d,%d,%d" % [b.x, b.y, floor_index, a.x, a.y, floor_index]

func _has_wall_on_floor(a: Vector2i, b: Vector2i, floor_index: int) -> bool:
	return WallSystem.get_wall_by_key(_make_wall_key(a, b, floor_index)) != null

func _wall_candidates_for_floor(floor_index: int) -> Dictionary:
	var candidates: Dictionary = {}
	for key in WallSystem.get_wall_keys_for_floor(floor_index):
		var wall_data = WallSystem.get_wall_by_key(key)
		if wall_data == null:
			continue
		candidates[wall_data.from_tile] = true
		candidates[wall_data.to_tile] = true
	return candidates

func _compute_bounds(candidates: Dictionary) -> Dictionary:
	if candidates.is_empty():
		return {"valid": false}

	var min_x := 2147483647
	var min_y := 2147483647
	var max_x := -2147483648
	var max_y := -2147483648

	for tile in candidates.keys():
		var t: Vector2i = tile
		min_x = mini(min_x, t.x)
		min_y = mini(min_y, t.y)
		max_x = maxi(max_x, t.x)
		max_y = maxi(max_y, t.y)

	# Margin gives room for valid interior flood before marking as open space.
	var margin := 2
	return {
		"valid": true,
		"min_x": min_x - margin,
		"min_y": min_y - margin,
		"max_x": max_x + margin,
		"max_y": max_y + margin,
	}

func _is_outside_bounds(tile: Vector2i, bounds: Dictionary) -> bool:
	if not bounds.get("valid", false):
		return false
	if tile.x < int(bounds["min_x"]):
		return true
	if tile.x > int(bounds["max_x"]):
		return true
	if tile.y < int(bounds["min_y"]):
		return true
	if tile.y > int(bounds["max_y"]):
		return true
	return false

func _flood_from_tile_on_floor(start_tile: Vector2i, floor_index: int, bounds: Dictionary) -> Dictionary:
	var visited: Dictionary = {}
	var queue: Array[Vector2i] = [start_tile]
	visited[start_tile] = true
	var enclosed := true

	while queue.size() > 0:
		var current: Vector2i = queue.pop_front()

		if visited.size() > MAX_FILL_TILES:
			enclosed = false
			break

		if _is_outside_bounds(current, bounds):
			enclosed = false
			break

		for offset in NEIGHBORS:
			var neighbor: Vector2i = current + offset

			if visited.has(neighbor):
				continue

			if _has_wall_on_floor(current, neighbor, floor_index):
				continue

			visited[neighbor] = true
			queue.append(neighbor)

	return {
		"enclosed": enclosed,
		"visited": visited,
	}

# -------------------------------------------------------
# Main entry point
# Call this after any wall is placed or removed
# -------------------------------------------------------

func detect_room_from_tile(start_tile: Vector2i) -> Array[Vector2i]:
	var floor_index := FloorManager.current_floor
	var candidates := _wall_candidates_for_floor(floor_index)
	if candidates.is_empty():
		return []
	var bounds := _compute_bounds(candidates)
	var flood := _flood_from_tile_on_floor(start_tile, floor_index, bounds)
	if not flood["enclosed"]:
		# Escaped to open space — not a room
		return []

	# If we're here, the fill was contained — it's a room!
	var room_tiles: Array[Vector2i] = []
	for tile in (flood["visited"] as Dictionary).keys():
		room_tiles.append(tile)
	return room_tiles

# -------------------------------------------------------
# Detect ALL rooms on the map
# Call this when you need a full map update
# -------------------------------------------------------

func detect_all_rooms() -> Array:
	var rooms: Array = []
	var floors: Dictionary = {}
	for key in WallSystem.get_all_wall_keys():
		floors[WallSystem.get_floor_from_key(key)] = true

	for floor_value in floors.keys():
		rooms.append_array(detect_all_rooms_on_floor(int(floor_value)))

	return rooms

func detect_all_rooms_on_floor(floor_index: int) -> Array:
	var all_assigned: Dictionary = {}
	var rooms: Array = []
	var candidates := _wall_candidates_for_floor(floor_index)
	if candidates.is_empty():
		return rooms

	var bounds := _compute_bounds(candidates)

	for tile in candidates.keys():
		if all_assigned.has(tile):
			continue
		var flood := _flood_from_tile_on_floor(tile, floor_index, bounds)
		var visited := flood["visited"] as Dictionary
		for t in visited.keys():
			all_assigned[t] = true
		if flood["enclosed"]:
			var room: Array[Vector2i] = []
			for t in visited.keys():
				room.append(t)
			rooms.append(room)
	return rooms
