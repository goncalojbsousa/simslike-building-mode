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

const ROOM_DETECTOR_SCRIPT := preload("res://scripts/RoomDetector.gd")
const UPPER_FLOOR_OVERHANG_CELLS := 2

# --- Signals ---
signal wall_placed(from_tile: Vector2i, to_tile: Vector2i, floor: int)
signal wall_removed(from_tile: Vector2i, to_tile: Vector2i, floor: int)

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

func _opening_system() -> Node:
	return get_node_or_null("/root/OpeningSystem")

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
	var f := floor_index if floor_index >= 0 else FloorManager.current_floor
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
	var f := floor_index if floor_index >= 0 else FloorManager.current_floor
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
	var f := floor_index if floor_index >= 0 else FloorManager.current_floor
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
	var f := floor_index if floor_index >= 0 else FloorManager.current_floor
	var diff := b - a
	if abs(diff.x) + abs(diff.y) != 1:
		return false
	if has_wall(a, b, f):
		return false
	# Upper floors can overhang the floor below by a limited number of cells.
	if f > 0 and not _has_upper_floor_support(a, b, f):
		return false
	if FurnitureSystem != null and FurnitureSystem.has_method("has_furniture_blocking_wall"):
		if FurnitureSystem.has_furniture_blocking_wall(a, b):
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
	var f := floor_index if floor_index >= 0 else FloorManager.current_floor
	if not can_place_wall(a, b, f):
		return false
	var key := make_key(a, b, f)
	var data := WallData.new(a, b)
	_walls[key] = data
	wall_placed.emit(a, b, f)
	_mark_room_detection_dirty()
	return true

func remove_wall(a: Vector2i, b: Vector2i, floor_index: int = -1) -> bool:
	var f := floor_index if floor_index >= 0 else FloorManager.current_floor
	var key := make_key(a, b, f)
	if not _walls.has(key):
		return false
	_walls.erase(key)
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

	var rooms: Array = _room_detector.call("detect_all_rooms")
	var current_signatures: Dictionary = {}

	for room in rooms:
		var signature := _make_room_signature(room)
		if signature == "":
			continue

		current_signatures[signature] = true

	_known_room_signatures = current_signatures

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
