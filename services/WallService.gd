class_name WallService
extends Node

# --- Storage ---
# Walls are stored by a sorted edge key: "x1,y1|x2,y2"
# The smaller tile always comes first → direction-independent
var _walls: Dictionary = {}   # String -> WallData
var _known_room_signatures: Dictionary = {}   # String -> bool
var _room_detector: Node = null
var _room_detection_dirty: bool = false
var _room_detection_scheduled: bool = false
var _room_batch_depth: int = 0
var _room_identity_counter: int = 1
var _room_entries_by_floor: Dictionary = {}   # floor -> Array[{id, signature, tiles: Dictionary}]
var _wall_identities: Dictionary = {}          # wall_key -> Dictionary
var _wall_side_colors: Dictionary = {}         # wall_key -> {front: Color, back: Color}

const ROOM_DETECTOR_SCRIPT := preload("res://scripts/RoomDetector.gd")
const UPPER_FLOOR_OVERHANG_CELLS := 2
const DEFAULT_WALL_COLOR := Color(0.88, 0.86, 0.82, 1.0)

# --- Signals ---
signal wall_placed(from_tile: Vector2i, to_tile: Vector2i, floor: int)
signal wall_removed(from_tile: Vector2i, to_tile: Vector2i, floor: int)
signal wall_identities_changed
signal wall_side_color_changed(wall_key: String)

# --- WallData ---
class WallData:
	var from_tile: Vector2i
	var to_tile: Vector2i
	var mesh_instance: Node3D = null   # the visual node

	func _init(a: Vector2i, b: Vector2i) -> void:
		from_tile = a
		to_tile = b

func _ready() -> void:
	_room_detector = ROOM_DETECTOR_SCRIPT.new()
	add_child(_room_detector)

func _app() -> Node:
	return get_node_or_null("/root/App")

func _floor_service() -> Node:
	var app = _app()
	if app == null:
		return null
	return app.call("get_floor_service")

func _furniture_service() -> Node:
	var app = _app()
	if app == null:
		return null
	return app.call("get_furniture_service")

func _current_floor() -> int:
	var floor_service = _floor_service()
	if floor_service == null:
		return 0
	return int(floor_service.current_floor)

func _opening_system() -> Node:
	var app = _app()
	if app == null:
		return null
	return app.call("get_opening_service")

func _begin_room_batch() -> void:
	_room_batch_depth += 1

func _end_room_batch() -> void:
	if _room_batch_depth > 0:
		_room_batch_depth -= 1
	if _room_batch_depth == 0 and _room_detection_dirty:
		_schedule_room_detection()

func _mark_room_detection_dirty() -> void:
	_room_detection_dirty = true
	if _room_batch_depth > 0:
		return
	_schedule_room_detection()

func _schedule_room_detection() -> void:
	if _room_detection_scheduled:
		return
	_room_detection_scheduled = true
	call_deferred("_run_room_detection_if_dirty")

func _run_room_detection_if_dirty() -> void:
	_room_detection_scheduled = false
	if _room_batch_depth > 0:
		return
	if not _room_detection_dirty:
		return
	_room_detection_dirty = false
	_update_room_detection()

# -------------------------------------------------------
# Key generation — always sorted so A→B == B→A
# -------------------------------------------------------

func make_key(a: Vector2i, b: Vector2i, floor_index: int = -1) -> String:
	var f: int = floor_index if floor_index >= 0 else _current_floor()
	if a.x < b.x or (a.x == b.x and a.y < b.y):
		if f == 0:
			return "%d,%d|%d,%d" % [a.x, a.y, b.x, b.y]
		return "%d,%d,%d|%d,%d,%d" % [a.x, a.y, f, b.x, b.y, f]
	if f == 0:
		return "%d,%d|%d,%d" % [b.x, b.y, a.x, a.y]
	return "%d,%d,%d|%d,%d,%d" % [b.x, b.y, f, a.x, a.y, f]

func get_floor_from_key(key: String) -> int:
	var parts := key.split("|")
	if parts.size() != 2:
		return 0
	var coords := parts[0].split(",")
	if coords.size() == 2:
		return 0
	if coords.size() == 3:
		return int(coords[2])
	return 0

func get_all_wall_keys() -> Array[String]:
	var keys: Array[String] = []
	for k in _walls.keys():
		keys.append(k)
	return keys

func get_wall_keys_for_floor(floor_index: int) -> Array[String]:
	var keys: Array[String] = []
	for key in _walls.keys():
		if get_floor_from_key(key) == floor_index:
			keys.append(key)
	return keys

# -------------------------------------------------------
# Queries
# -------------------------------------------------------

func has_wall(a: Vector2i, b: Vector2i, floor_index: int = -1) -> bool:
	var f: int = floor_index if floor_index >= 0 else _current_floor()
	return _walls.has(make_key(a, b, f))

func get_wall(a: Vector2i, b: Vector2i, floor_index: int = -1) -> WallData:
	return _walls.get(make_key(a, b, floor_index), null)

func get_wall_by_key(key: String) -> WallData:
	return _walls.get(key, null)

func get_all_walls() -> Array:
	return _walls.values()

# -------------------------------------------------------
# Get walls touching a specific tile (for room detection)
# -------------------------------------------------------

func get_walls_of_tile(tile: Vector2i, floor_index: int = -1) -> Array[String]:
	var f: int = floor_index if floor_index >= 0 else _current_floor()
	var keys: Array[String] = []
	var neighbors := [
		Vector2i(tile.x + 1, tile.y),
		Vector2i(tile.x - 1, tile.y),
		Vector2i(tile.x, tile.y + 1),
		Vector2i(tile.x, tile.y - 1),
	]
	for n in neighbors:
		var key := make_key(tile, n, f)
		if _walls.has(key):
			keys.append(key)
	return keys

# -------------------------------------------------------
# Placement
# -------------------------------------------------------

func can_place_wall(a: Vector2i, b: Vector2i, floor_index: int = -1) -> bool:
	var f: int = floor_index if floor_index >= 0 else _current_floor()
	var diff := b - a
	if abs(diff.x) + abs(diff.y) != 1:
		return false
	if has_wall(a, b, f):
		return false
	# Upper floors can overhang the floor below by a limited number of cells.
	if f > 0 and not _has_upper_floor_support(a, b, f):
		return false
	var furniture_service = _furniture_service()
	if furniture_service != null and furniture_service.has_method("has_furniture_blocking_wall"):
		if furniture_service.has_furniture_blocking_wall(a, b, f):
			return false
	return true

func _has_upper_floor_support(a: Vector2i, b: Vector2i, floor_index: int) -> bool:
	var below_floor := floor_index - 1
	if below_floor < 0:
		return true

	# Exact wall alignment is always valid structural support.
	if has_wall(a, b, below_floor):
		return true

	# Also allow building on the roof footprint with a controlled overhang.
	return _is_segment_within_floor_limit(a, b, below_floor, UPPER_FLOOR_OVERHANG_CELLS)

func _is_segment_within_floor_limit(a: Vector2i, b: Vector2i, floor_index: int, margin: int) -> bool:
	var bounds := _get_floor_bounds(floor_index)
	if not bool(bounds.get("valid", false)):
		return false

	var min_x := int(bounds["min_x"]) - margin
	var min_y := int(bounds["min_y"]) - margin
	var max_x := int(bounds["max_x"]) + margin
	var max_y := int(bounds["max_y"]) + margin

	return _is_point_in_bounds(a, min_x, min_y, max_x, max_y) and _is_point_in_bounds(b, min_x, min_y, max_x, max_y)

func _is_point_in_bounds(p: Vector2i, min_x: int, min_y: int, max_x: int, max_y: int) -> bool:
	return p.x >= min_x and p.x <= max_x and p.y >= min_y and p.y <= max_y

func _get_floor_bounds(floor_index: int) -> Dictionary:
	var min_x := 2147483647
	var min_y := 2147483647
	var max_x := -2147483648
	var max_y := -2147483648
	var has_any := false

	for key in get_wall_keys_for_floor(floor_index):
		var wall_data: WallData = get_wall_by_key(key)
		if wall_data == null:
			continue
		has_any = true
		min_x = mini(min_x, wall_data.from_tile.x)
		min_x = mini(min_x, wall_data.to_tile.x)
		min_y = mini(min_y, wall_data.from_tile.y)
		min_y = mini(min_y, wall_data.to_tile.y)
		max_x = maxi(max_x, wall_data.from_tile.x)
		max_x = maxi(max_x, wall_data.to_tile.x)
		max_y = maxi(max_y, wall_data.from_tile.y)
		max_y = maxi(max_y, wall_data.to_tile.y)

	if not has_any:
		return {"valid": false}

	return {
		"valid": true,
		"min_x": min_x,
		"min_y": min_y,
		"max_x": max_x,
		"max_y": max_y,
	}

func place_wall(a: Vector2i, b: Vector2i, floor_index: int = -1) -> bool:
	var f: int = floor_index if floor_index >= 0 else _current_floor()
	if not can_place_wall(a, b, f):
		return false
	var key := make_key(a, b, f)
	var data := WallData.new(a, b)
	_walls[key] = data
	wall_placed.emit(a, b, f)
	_mark_room_detection_dirty()
	return true

func remove_wall(a: Vector2i, b: Vector2i, floor_index: int = -1) -> bool:
	var f: int = floor_index if floor_index >= 0 else _current_floor()
	var key := make_key(a, b, f)
	if not _walls.has(key):
		return false
	_walls.erase(key)
	_wall_side_colors.erase(key)
	wall_side_color_changed.emit(key)
	# Also remove any opening on this wall.
	var opening_system := _opening_system()
	if opening_system != null and opening_system.has_method("has_opening"):
		if opening_system.call("has_opening", key):
			opening_system.call("remove_opening", key)
	wall_removed.emit(a, b, f)
	_mark_room_detection_dirty()
	return true

func _update_room_detection() -> void:
	if _room_detector == null:
		return

	var floors: Dictionary = {}
	for key in _walls.keys():
		floors[get_floor_from_key(key)] = true

	var next_entries_by_floor: Dictionary = {}
	var current_signatures: Dictionary = {}

	for floor_value in floors.keys():
		var floor_index := int(floor_value)
		var prev_entries: Array = _room_entries_by_floor.get(floor_index, [])
		var available_prev: Array = []
		for prev in prev_entries:
			available_prev.append(prev)

		var new_entries: Array = []
		var rooms: Array = _room_detector.call("detect_all_rooms_on_floor", floor_index)
		for room in rooms:
			if not (room is Array):
				continue
			var signature := _make_room_signature(room)
			if signature == "":
				continue

			var room_tiles := _array_to_tile_set(room)
			var matched_prev_idx := _find_best_overlap_prev_index(room_tiles, available_prev)
			var room_id := -1
			if matched_prev_idx >= 0:
				room_id = int((available_prev[matched_prev_idx] as Dictionary).get("id", -1))
				available_prev.remove_at(matched_prev_idx)
			else:
				room_id = _room_identity_counter
				_room_identity_counter += 1

			new_entries.append({
				"id": room_id,
				"signature": signature,
				"tiles": room_tiles,
			})
			current_signatures[signature] = true

		next_entries_by_floor[floor_index] = new_entries

	_room_entries_by_floor = next_entries_by_floor
	_known_room_signatures = current_signatures
	_rebuild_wall_identities()

func _array_to_tile_set(room: Array) -> Dictionary:
	var tile_set: Dictionary = {}
	for tile in room:
		if tile is Vector2i:
			tile_set[tile] = true
	return tile_set

func _count_overlap(a: Dictionary, b: Dictionary) -> int:
	var overlap := 0
	for tile in a.keys():
		if b.has(tile):
			overlap += 1
	return overlap

func _find_best_overlap_prev_index(room_tiles: Dictionary, prev_entries: Array) -> int:
	var best_idx := -1
	var best_overlap := 0
	for i in range(prev_entries.size()):
		var prev: Dictionary = prev_entries[i]
		var prev_tiles: Dictionary = prev.get("tiles", {})
		var overlap := _count_overlap(room_tiles, prev_tiles)
		if overlap > best_overlap:
			best_overlap = overlap
			best_idx = i
	return best_idx

func _get_room_entry_for_tile(tile: Vector2i, floor_index: int) -> Dictionary:
	var entries: Array = _room_entries_by_floor.get(floor_index, [])
	for entry in entries:
		var tiles: Dictionary = (entry as Dictionary).get("tiles", {})
		if tiles.has(tile):
			return entry
	return {}

func _compute_wall_side_tiles(from_tile: Vector2i, to_tile: Vector2i) -> Dictionary:
	var diff := to_tile - from_tile
	if abs(diff.x) == 1:
		var min_x := mini(from_tile.x, to_tile.x)
		var y := from_tile.y
		return {
			"orientation": "vertical",
			"front_tile": Vector2i(min_x, y),
			"back_tile": Vector2i(min_x + 1, y),
		}

	var x := from_tile.x
	var min_y := mini(from_tile.y, to_tile.y)
	return {
		"orientation": "horizontal",
		"front_tile": Vector2i(x, min_y),
		"back_tile": Vector2i(x, min_y + 1),
	}

func _make_wall_side_info(tile: Vector2i, floor_index: int) -> Dictionary:
	var entry := _get_room_entry_for_tile(tile, floor_index)
	if entry.is_empty():
		return {
			"tile": tile,
			"room_id": -1,
			"room_signature": "exterior",
		}
	return {
		"tile": tile,
		"room_id": int(entry.get("id", -1)),
		"room_signature": str(entry.get("signature", "exterior")),
	}

func _rebuild_wall_identities() -> void:
	_wall_identities.clear()
	for key in _walls.keys():
		var wall: WallData = _walls[key]
		if wall == null:
			continue
		var floor_index := get_floor_from_key(key)
		var side_tiles := _compute_wall_side_tiles(wall.from_tile, wall.to_tile)
		var front_tile: Vector2i = side_tiles["front_tile"]
		var back_tile: Vector2i = side_tiles["back_tile"]
		var front_side := _make_wall_side_info(front_tile, floor_index)
		var back_side := _make_wall_side_info(back_tile, floor_index)

		_wall_identities[key] = {
			"key": key,
			"floor": floor_index,
			"orientation": str(side_tiles["orientation"]),
			"from_tile": wall.from_tile,
			"to_tile": wall.to_tile,
			"front_side": front_side,
			"back_side": back_side,
			"separates": {
				"a": front_side.get("room_id", -1),
				"b": back_side.get("room_id", -1),
			},
		}

	wall_identities_changed.emit()

func get_wall_identity_by_key(key: String) -> Dictionary:
	return _wall_identities.get(key, {})

func get_wall_identities_for_floor(floor_index: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for key in _wall_identities.keys():
		var identity: Dictionary = _wall_identities[key]
		if int(identity.get("floor", -1)) == floor_index:
			result.append(identity)
	return result

func get_room_entries_for_floor(floor_index: int) -> Array:
	return _room_entries_by_floor.get(floor_index, [])

func get_room_id_for_tile(tile: Vector2i, floor_index: int = -1) -> int:
	var f: int = floor_index if floor_index >= 0 else _current_floor()
	var entry := _get_room_entry_for_tile(tile, f)
	if entry.is_empty():
		return -1
	return int(entry.get("id", -1))

func get_room_tiles_by_id(room_id: int, floor_index: int = -1) -> Dictionary:
	var f: int = floor_index if floor_index >= 0 else _current_floor()
	for entry in get_room_entries_for_floor(f):
		var room_entry := entry as Dictionary
		if int(room_entry.get("id", -1)) != room_id:
			continue
		var tiles: Dictionary = room_entry.get("tiles", {})
		return tiles.duplicate(true)
	return {}

func get_default_wall_color() -> Color:
	return DEFAULT_WALL_COLOR

func get_wall_colors_by_key(key: String) -> Dictionary:
	var entry: Dictionary = _wall_side_colors.get(key, {})
	return {
		"front": entry.get("front", DEFAULT_WALL_COLOR),
		"back": entry.get("back", DEFAULT_WALL_COLOR),
	}

func get_wall_side_color_by_key(key: String, side: String) -> Color:
	if side != "front" and side != "back":
		return DEFAULT_WALL_COLOR
	var entry: Dictionary = _wall_side_colors.get(key, {})
	return entry.get(side, DEFAULT_WALL_COLOR)

func set_wall_side_color_by_key(key: String, side: String, color: Color) -> void:
	if side != "front" and side != "back":
		return
	if not _walls.has(key):
		return
	var entry: Dictionary = _wall_side_colors.get(key, {})
	if entry.get(side, DEFAULT_WALL_COLOR) == color:
		return
	entry[side] = color
	_wall_side_colors[key] = entry
	wall_side_color_changed.emit(key)

func set_wall_colors_by_key(key: String, front_color: Color, back_color: Color) -> void:
	if not _walls.has(key):
		return
	var next_entry := {
		"front": front_color,
		"back": back_color,
	}
	if _wall_side_colors.get(key, {}) == next_entry:
		return
	_wall_side_colors[key] = next_entry
	wall_side_color_changed.emit(key)

func _make_room_signature(room: Array) -> String:
	var cells: Array[String] = []
	for tile in room:
		if tile is Vector2i:
			cells.append("%d,%d" % [tile.x, tile.y])

	if cells.is_empty():
		return ""

	cells.sort()
	return ";".join(cells)

# -------------------------------------------------------
# Drag-to-place a segment (multiple walls at once)
# -------------------------------------------------------

func get_wall_pairs_for_corner_segment(from_corner: Vector2i, to_corner: Vector2i) -> Array[Vector2i]:
	var pairs: Array[Vector2i] = []
	var diff := to_corner - from_corner

	if abs(diff.x) >= abs(diff.y):
		# Horizontal line on corner row y = from_corner.y
		var step_x := sign(diff.x) as int
		if step_x == 0:
			return pairs

		var x := from_corner.x
		while x != to_corner.x:
			var seg_x := x if step_x > 0 else x - 1
			pairs.append(Vector2i(seg_x, from_corner.y - 1))
			pairs.append(Vector2i(seg_x, from_corner.y))
			x += step_x
	else:
		# Vertical line on corner column x = from_corner.x
		var step_y := sign(diff.y) as int
		if step_y == 0:
			return pairs

		var y := from_corner.y
		while y != to_corner.y:
			var seg_y := y if step_y > 0 else y - 1
			pairs.append(Vector2i(from_corner.x - 1, seg_y))
			pairs.append(Vector2i(from_corner.x, seg_y))
			y += step_y

	return pairs

func place_wall_segment_from_corners(from_corner: Vector2i, to_corner: Vector2i) -> void:
	var pairs := get_wall_pairs_for_corner_segment(from_corner, to_corner)
	_begin_room_batch()
	for i in range(0, pairs.size(), 2):
		place_wall(pairs[i], pairs[i + 1])
	_end_room_batch()

func place_wall_segment(from_tile: Vector2i, to_tile: Vector2i) -> void:
	var diff := to_tile - from_tile
	_begin_room_batch()

	if abs(diff.x) >= abs(diff.y):
		# Horizontal drag → place X-aligned walls between tile rows.
		var step := sign(diff.x) as int
		if step == 0:
			_end_room_batch()
			return
		var x := from_tile.x
		while x != to_tile.x:
			place_wall(Vector2i(x, from_tile.y), Vector2i(x, from_tile.y + 1))
			x += step
	else:
		# Vertical drag → place Z-aligned walls between tile columns.
		var step := sign(diff.y) as int
		if step == 0:
			_end_room_batch()
			return
		var y := from_tile.y
		while y != to_tile.y:
			place_wall(Vector2i(from_tile.x, y), Vector2i(from_tile.x + 1, y))
			y += step

	_end_room_batch()

func begin_batch() -> void:
	_begin_room_batch()

func end_batch() -> void:
	_end_room_batch()

func get_room_detector() -> Node:
	return _room_detector
