extends Node

@export var mouse_raycast: Node
@export var active: bool = false
@export var preview_material: Material = preload("res://materials/WallPreview.tres")

var current_type: String = "door"
var current_scene_path: String = ""

var _preview_node: Node3D    = null
var _preview_wall_key: String = ""
var _preview_offset_t: float  = 0.5
var _preview_valid: bool      = false

# Opening catalog — add entries as you get more assets
const OPENING_CATALOG = {
	"door":   { "scene": "res://scenes/furniture/DoorSimple.tscn",    "type": "door"   },
	"window": { "scene": "res://scenes/furniture/WindowSimple.tscn",  "type": "window" },
}

func _app() -> Node:
	return get_node_or_null("/root/App")

func _wall_service() -> Node:
	var app = _app()
	if app == null:
		return null
	return app.call("get_wall_service")

func _grid_service() -> Node:
	var app = _app()
	if app == null:
		return null
	return app.call("get_grid_service")

func _floor_service() -> Node:
	var app = _app()
	if app == null:
		return null
	return app.call("get_floor_service")

func _history_service() -> Node:
	var app = _app()
	if app == null:
		return null
	return app.call("get_history_service")

func _opening_system() -> Node:
	var app = _app()
	if app == null:
		return null
	return app.call("get_opening_service")

func _make_wall_key(a: Vector2i, b: Vector2i, floor_index: int) -> String:
	var wall_service = _wall_service()
	if wall_service != null and wall_service.has_method("make_key"):
		return str(wall_service.call("make_key", a, b, floor_index))
	if a.x < b.x or (a.x == b.x and a.y < b.y):
		if floor_index == 0:
			return "%d,%d|%d,%d" % [a.x, a.y, b.x, b.y]
		return "%d,%d,%d|%d,%d,%d" % [a.x, a.y, floor_index, b.x, b.y, floor_index]
	if floor_index == 0:
		return "%d,%d|%d,%d" % [b.x, b.y, a.x, a.y]
	return "%d,%d,%d|%d,%d,%d" % [b.x, b.y, floor_index, a.x, a.y, floor_index]

func _has_wall_on_floor(a: Vector2i, b: Vector2i, floor_index: int) -> bool:
	var wall_service = _wall_service()
	if wall_service == null:
		return false
	return wall_service.get_wall_by_key(_make_wall_key(a, b, floor_index)) != null

func _get_wall_centerline(from_tile: Vector2i, to_tile: Vector2i) -> Dictionary:
	var grid_service = _grid_service()
	if grid_service == null:
		return {}
	var from_w = grid_service.tile_to_world(from_tile)
	var to_w = grid_service.tile_to_world(to_tile)
	var midpoint = (from_w + to_w) * 0.5
	var diff = to_tile - from_tile
	var is_parallel_z = diff.x != 0
	var half_len = grid_service.TILE_SIZE * 0.5

	var start_w = midpoint
	var end_w = midpoint
	if is_parallel_z:
		start_w.z -= half_len
		end_w.z += half_len
	else:
		start_w.x -= half_len
		end_w.x += half_len

	return {
		"start_world": start_w,
		"end_world": end_w,
		"midpoint": midpoint,
		"is_parallel_z": is_parallel_z,
	}

func activate(opening_key: String) -> void:
	var entry: Dictionary = OPENING_CATALOG.get(opening_key, {})
	if entry.is_empty():
		push_error("OpeningPlacer: unknown opening key: " + opening_key)
		return
	current_type       = entry["type"]
	current_scene_path = entry["scene"]
	active = true
	_spawn_preview()

func deactivate() -> void:
	active = false
	_destroy_preview()

func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return
	if event is InputEventKey:
		var ke = event as InputEventKey
		if ke.pressed and ke.keycode == KEY_ESCAPE:
			deactivate()
			return
	if event is InputEventMouseButton:
		var mb = event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			deactivate()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			if _preview_valid:
				_commit_opening()

func _process(_delta: float) -> void:
	if not active:
		return
	_update_preview()

# -------------------------------------------------------
# Wall detection under mouse
# -------------------------------------------------------

func _find_wall_under_mouse() -> Dictionary:
	# Returns {key, from_tile, to_tile, offset_t} or empty dict
	var world_pos : Vector3 = mouse_raycast.get_world_position_under_mouse()
	var tile      : Vector2i = mouse_raycast.get_tile_under_mouse()

	var best: Dictionary = {}
	var best_dist = INF
	var floor_service = _floor_service()
	var grid_service = _grid_service()
	if floor_service == null or grid_service == null:
		return best
	var current_floor: int = int(floor_service.current_floor)

	# Check the 4 edges of the tile under cursor + its 4 neighbors
	var candidates: Array[Vector2i] = [
		Vector2i(1, 0), Vector2i(-1, 0),
		Vector2i(0, 1), Vector2i(0, -1)
	]
	for offset in candidates:
		var neighbor = tile + offset
		if not _has_wall_on_floor(tile, neighbor, current_floor):
			continue
		var key = _make_wall_key(tile, neighbor, current_floor)
		var line_data = _get_wall_centerline(tile, neighbor)
		if line_data.is_empty():
			continue
		var start_w: Vector3 = line_data["start_world"]
		var end_w: Vector3 = line_data["end_world"]

		# Project mouse position onto wall centerline to get offset_t.
		var wall_vec = end_w - start_w
		var wall_len_sq = wall_vec.length_squared()
		if wall_len_sq <= 0.0001:
			continue

		var free_mode  = Input.is_key_pressed(KEY_ALT)
		var raw_t = (world_pos - start_w).dot(wall_vec) / wall_len_sq

		raw_t = clampf(raw_t, 0.05, 0.95)

		# Snap to grid unless Alt held
		var offset_t: float
		if free_mode:
			offset_t = raw_t
		else:
			# Snap to 0.5 (center) only — could expand to more snaps later
			offset_t = 0.5

		# Distance from mouse to wall midline (perpendicular)
		var nearest = start_w.lerp(end_w, offset_t)
		var perp_dist = Vector2(world_pos.x - nearest.x, world_pos.z - nearest.z).length()

		if perp_dist < best_dist and perp_dist < grid_service.TILE_SIZE * 0.8:
			best_dist = perp_dist
			best = {
				"key":       key,
				"from_tile": tile,
				"to_tile":   neighbor,
				"offset_t":  offset_t,
				"is_parallel_z": bool(line_data["is_parallel_z"]),
				"start_world": start_w,
				"end_world":   end_w,
				"floor_index": current_floor,
			}

	return best

# -------------------------------------------------------
# Preview
# -------------------------------------------------------

func _spawn_preview() -> void:
	_destroy_preview()
	if current_scene_path == "":
		return
	var scene: PackedScene = load(current_scene_path)
	if scene == null:
		return
	_preview_node = scene.instantiate()
	add_child(_preview_node)
	_tint_preview(_preview_node, true)

func _destroy_preview() -> void:
	if is_instance_valid(_preview_node):
		_preview_node.queue_free()
	_preview_node = null
	_preview_wall_key = ""

func _update_preview() -> void:
	if not is_instance_valid(_preview_node):
		_spawn_preview()
		return

	var hit = _find_wall_under_mouse()
	if hit.is_empty():
		_preview_valid   = false
		_preview_wall_key = ""
		_preview_node.visible = false
		return

	_preview_wall_key = hit["key"]
	_preview_offset_t = hit["offset_t"]
	var opening_system = _opening_system()
	_preview_valid = opening_system != null and not opening_system.call("has_opening", hit["key"])
	_preview_node.visible = true

	# Position along the wall
	var start_w: Vector3 = hit["start_world"]
	var end_w: Vector3   = hit["end_world"]
	var pos = start_w.lerp(end_w, hit["offset_t"])
	var grid_service = _grid_service()
	if grid_service == null:
		_preview_valid = false
		_preview_node.visible = false
		return
	pos.y = grid_service.get_wall_y_base(hit["floor_index"])
	_preview_node.global_position = pos

	if hit["is_parallel_z"]:
		_preview_node.rotation_degrees.y = 90.0
	else:
		_preview_node.rotation_degrees.y = 0.0

	_tint_preview(_preview_node, _preview_valid)

func _tint_preview(node: Node3D, valid: bool) -> void:
	var color = Color(0.3, 0.9, 0.3, 0.55) if valid else Color(0.9, 0.2, 0.2, 0.55)
	_tint_recursive(node, color)

func _tint_recursive(node: Node3D, color: Color) -> void:
	if node is MeshInstance3D:
		var mat = StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color  = color
		mat.shading_mode  = BaseMaterial3D.SHADING_MODE_UNSHADED
		node.material_override = mat
	for child in node.get_children():
		if child is Node3D:
			_tint_recursive(child, color)

# -------------------------------------------------------
# Commit
# -------------------------------------------------------

func _commit_opening() -> void:
	var key   = _preview_wall_key
	var off_t = _preview_offset_t
	var type  = current_type
	var path  = current_scene_path
	var opening_system = _opening_system()
	if opening_system == null:
		return

	var history_service = _history_service()
	if history_service == null:
		return
	history_service.execute(
		"place " + type,
		func(): opening_system.call("place_opening", key, type, off_t, path),
		func(): opening_system.call("remove_opening", key)
	)
