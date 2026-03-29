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

# --- Signals ---
signal wall_placed(from_tile: Vector2i, to_tile: Vector2i)
signal wall_removed(from_tile: Vector2i, to_tile: Vector2i)

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

func make_key(a: Vector2i, b: Vector2i) -> String:
	if a.x < b.x or (a.x == b.x and a.y < b.y):
		return "%d,%d|%d,%d" % [a.x, a.y, b.x, b.y]
	else:
		return "%d,%d|%d,%d" % [b.x, b.y, a.x, a.y]

# -------------------------------------------------------
# Queries
# -------------------------------------------------------

func has_wall(a: Vector2i, b: Vector2i) -> bool:
	return _walls.has(make_key(a, b))

func get_wall(a: Vector2i, b: Vector2i) -> WallData:
	return _walls.get(make_key(a, b), null)

func get_all_walls() -> Array:
	return _walls.values()

# -------------------------------------------------------
# Get walls touching a specific tile (for room detection)
# -------------------------------------------------------

func get_walls_of_tile(tile: Vector2i) -> Array[String]:
	var keys: Array[String] = []
	var neighbors := [
		Vector2i(tile.x + 1, tile.y),
		Vector2i(tile.x - 1, tile.y),
		Vector2i(tile.x, tile.y + 1),
		Vector2i(tile.x, tile.y - 1),
	]
	for n in neighbors:
		var key := make_key(tile, n)
		if _walls.has(key):
			keys.append(key)
	return keys

# -------------------------------------------------------
# Placement
# -------------------------------------------------------

func place_wall(a: Vector2i, b: Vector2i) -> bool:
	# Only allow adjacent tiles (no diagonal walls)
	var diff := b - a
	if abs(diff.x) + abs(diff.y) != 1:
		return false
	if has_wall(a, b):
		return false   # already exists

	var data := WallData.new(a, b)
	_walls[make_key(a, b)] = data
	wall_placed.emit(a, b)
	_mark_room_detection_dirty()
	return true

func remove_wall(a: Vector2i, b: Vector2i) -> bool:
	var key := make_key(a, b)
	if not _walls.has(key):
		return false
	_walls.erase(key)
	wall_removed.emit(a, b)
	_mark_room_detection_dirty()
	return true

func _update_room_detection() -> void:
	if _room_detector == null:
		return

	var rooms: Array = _room_detector.detect_all_rooms()
	var current_signatures: Dictionary = {}
	var new_rooms: int = 0

	for room in rooms:
		var signature := _make_room_signature(room)
		if signature == "":
			continue

		current_signatures[signature] = true
		if not _known_room_signatures.has(signature):
			new_rooms += 1
			print("Room created: %d tiles" % room.size())

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
			return
		var x := from_tile.x
		while x != to_tile.x:
			place_wall(Vector2i(x, from_tile.y), Vector2i(x, from_tile.y + 1))
			x += step
	else:
		# Vertical drag → place Z-aligned walls between tile columns.
		var step := sign(diff.y) as int
		if step == 0:
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
