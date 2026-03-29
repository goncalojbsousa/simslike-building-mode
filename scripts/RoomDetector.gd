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

func _flood_from_tile(start_tile: Vector2i) -> Dictionary:
	var visited: Dictionary = {}
	var queue: Array[Vector2i] = [start_tile]
	visited[start_tile] = true
	var enclosed := true

	while queue.size() > 0:
		var current: Vector2i = queue.pop_front()

		if visited.size() > MAX_FILL_TILES:
			enclosed = false
			break

		for offset in NEIGHBORS:
			var neighbor: Vector2i = current + offset

			if visited.has(neighbor):
				continue

			# Check if there's a wall between current and neighbor
			if WallSystem.has_wall(current, neighbor):
				continue   # blocked by wall — don't cross

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
	var flood := _flood_from_tile(start_tile)
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
	var all_assigned: Dictionary = {}
	var rooms: Array = []   # Array of Array[Vector2i]

	# Collect all tiles that are adjacent to at least one wall
	var candidates: Dictionary = {}
	for wall_data in WallSystem.get_all_walls():
		candidates[wall_data.from_tile] = true
		candidates[wall_data.to_tile] = true

	for tile in candidates.keys():
		if all_assigned.has(tile):
			continue

		var flood := _flood_from_tile(tile)
		var visited := flood["visited"] as Dictionary
		for t in visited.keys():
			all_assigned[t] = true

		if flood["enclosed"]:
			var room: Array[Vector2i] = []
			for t in visited.keys():
				room.append(t)
			rooms.append(room)

	return rooms
