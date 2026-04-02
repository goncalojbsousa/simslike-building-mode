# WallPlacer.gd
extends Node

@export var mouse_raycast: Node
@export var active: bool = false
@export var wall_preview_material: Material = preload("res://materials/WallPreview.tres")
@export var wall_delete_material: Material = preload("res://materials/WallDelete.tres")
@export var preview_height: float = 3.0
@export var preview_thickness: float = 0.15
@export var start_pointer_material: Material = preload("res://materials/WallPreview.tres")
@export var pointer_radius: float = 0.28
@export var pointer_height: float = 0.04
@export var pointer_y_offset: float = 0.02

# Internal state
var _is_placing: bool = false
var _delete_mode: bool = false
var _room_mode: bool = false
var _selection_mode: bool = false
var _forced_action: String = ""
var _drag_start_corner: Vector2i = Vector2i.ZERO
var _preview_tiles: Array[Vector2i] = []
var _preview_nodes: Array[MeshInstance3D] = []
var _preview_keys: Array[String] = []
var _start_pointer_node: MeshInstance3D = null
var _selection_preview_valid: bool = true
var _selected_wall_from: Vector2i = Vector2i.ZERO
var _selected_wall_to: Vector2i = Vector2i.ZERO
var _selected_wall_floor: int = 0
var _has_selected_wall: bool = false
var _wall_drag_start_world: Vector3 = Vector3.ZERO
var _wall_drag_axis: Vector2i = Vector2i.ZERO
var _wall_drag_steps: int = 0
var _wall_target_from: Vector2i = Vector2i.ZERO
var _wall_target_to: Vector2i = Vector2i.ZERO
var _wall_target_valid: bool = false

func _ready() -> void:
	preview_height = App.get_floor_service().FLOOR_HEIGHT

func activate(action: String = "") -> void:
	active = true
	_forced_action = action
	_sync_mode_flags_from_context()

func deactivate() -> void:
	active = false
	_forced_action = ""
	_cancel_drag()
	_clear_wall_selection_state()
	_clear_start_pointer()

# -------------------------------------------------------
# Input
# -------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return
	if _selection_mode:
		_handle_selection_mode_input(event)
		return

	if event is InputEventKey:
		var ke := event as InputEventKey

		# Escape cancels drag
		if ke.pressed and ke.keycode == KEY_ESCAPE:
			if _is_placing:
				_cancel_drag()
			return

		# Ctrl/Shift state only updates when not mid-drag
		if not _is_placing:
			if ke.keycode == KEY_CTRL or ke.keycode == KEY_META or ke.keycode == KEY_SHIFT:
				_sync_mode_flags_from_context()

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton

		# RMB cancels drag
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if _is_placing:
				_cancel_drag()
			return

		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				# Lock mode flags at drag start
				_sync_mode_flags_from_context()
				_drag_start_corner = _get_corner_under_mouse()
				_is_placing = true
			else:
				if _is_placing:
					_commit_drag(_get_corner_under_mouse())

# -------------------------------------------------------
# Process
# -------------------------------------------------------

func _process(_delta: float) -> void:
	if not active:
		_clear_start_pointer()
		return

	if _selection_mode:
		if _is_placing:
			_update_wall_move_preview()
		elif _has_selected_wall:
			_set_selection_preview(_selected_wall_from, _selected_wall_to, true)
		else:
			var hovered := _find_wall_under_mouse()
			if hovered.is_empty():
				_clear_preview()
			else:
				_set_selection_preview(hovered["from"], hovered["to"], true)
		_clear_start_pointer()
		return

	# Keep mode flags in sync when not dragging
	if not _is_placing:
		_sync_mode_flags_from_context()

	var pointer_corner: Vector2i = _drag_start_corner if _is_placing else _get_corner_under_mouse()
	_update_start_pointer(pointer_corner)

	if not _is_placing:
		return

	_update_preview(_drag_start_corner, _get_corner_under_mouse())

# -------------------------------------------------------
# Commit and cancel
# -------------------------------------------------------

func _commit_drag(end_corner: Vector2i) -> void:
	if _room_mode:
		_commit_room(_drag_start_corner, end_corner)
	elif _delete_mode:
		_commit_delete_segment(_drag_start_corner, end_corner)
	else:
		_commit_place_segment(_drag_start_corner, end_corner)

	_is_placing = false
	_clear_preview()
	_sync_mode_flags_from_context()

func _cancel_drag() -> void:
	if _selection_mode:
		_cancel_wall_move_drag()
		return
	_is_placing = false
	_clear_preview()
	_sync_mode_flags_from_context()

func _sync_mode_flags_from_context() -> void:
	if _forced_action == "select":
		_selection_mode = true
		_delete_mode = false
		_room_mode = false
		return

	_selection_mode = false
	if _forced_action == "delete":
		_delete_mode = true
		_room_mode = false
		return
	if _forced_action == "room":
		_delete_mode = false
		_room_mode = true
		return

	_delete_mode = Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_META)
	_room_mode = Input.is_key_pressed(KEY_SHIFT)

func _handle_selection_mode_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var ke := event as InputEventKey
		if ke.pressed and ke.keycode == KEY_ESCAPE:
			_cancel_wall_move_drag()
			return

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_cancel_wall_move_drag()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_begin_wall_move_drag()
			elif _is_placing:
				_commit_wall_move_drag()

func _begin_wall_move_drag() -> void:
	var hovered := _find_wall_under_mouse()
	if hovered.is_empty():
		_has_selected_wall = false
		_clear_preview()
		return

	_selected_wall_from = hovered["from"]
	_selected_wall_to = hovered["to"]
	_selected_wall_floor = int(hovered["floor_index"])
	_has_selected_wall = true

	_wall_drag_axis = _perpendicular_axis_for_wall(_selected_wall_from, _selected_wall_to)
	_wall_drag_start_world = mouse_raycast.get_world_position_under_mouse()
	_wall_drag_steps = 0
	_wall_target_from = _selected_wall_from
	_wall_target_to = _selected_wall_to
	_wall_target_valid = false

	_is_placing = true
	_set_selection_preview(_selected_wall_from, _selected_wall_to, true)

func _cancel_wall_move_drag() -> void:
	_is_placing = false
	_wall_drag_steps = 0
	_wall_target_valid = false
	if _has_selected_wall:
		_set_selection_preview(_selected_wall_from, _selected_wall_to, true)
	else:
		_clear_preview()

func _update_wall_move_preview() -> void:
	if not _has_selected_wall:
		_cancel_wall_move_drag()
		return

	var world_pos : Vector3 = mouse_raycast.get_world_position_under_mouse()
	var drag_axis_world := Vector3(float(_wall_drag_axis.x), 0.0, float(_wall_drag_axis.y))
	var projected := (world_pos - _wall_drag_start_world).dot(drag_axis_world)
	var steps := roundi(projected / App.get_grid_service().TILE_SIZE)
	if steps == _wall_drag_steps:
		return

	_wall_drag_steps = steps
	var offset := _wall_drag_axis * steps
	_wall_target_from = _selected_wall_from + offset
	_wall_target_to = _selected_wall_to + offset
	_wall_target_valid = steps != 0 and App.get_wall_service().can_place_wall(_wall_target_from, _wall_target_to, _selected_wall_floor)
	_set_selection_preview(_wall_target_from, _wall_target_to, _wall_target_valid)

func _commit_wall_move_drag() -> void:
	if not _has_selected_wall:
		_cancel_wall_move_drag()
		return

	var from_a := _selected_wall_from
	var from_b := _selected_wall_to
	var to_a := _wall_target_from
	var to_b := _wall_target_to
	var floor_index := _selected_wall_floor

	if not _wall_target_valid:
		_cancel_wall_move_drag()
		return

	var wall_key : String = App.get_wall_service().make_key(from_a, from_b, floor_index)
	var opening_snapshot := _build_opening_snapshot_for_wall(wall_key)
	var did_move := [false]

	App.get_history_service().execute(
		"move wall",
		func():
			did_move[0] = _move_wall_segment(from_a, from_b, to_a, to_b, floor_index, opening_snapshot)
			return did_move[0],
		func():
			return _move_wall_segment(to_a, to_b, from_a, from_b, floor_index, opening_snapshot)
	)

	_is_placing = false
	_wall_drag_steps = 0
	_wall_target_valid = false

	if did_move[0]:
		_selected_wall_from = to_a
		_selected_wall_to = to_b
		_set_selection_preview(_selected_wall_from, _selected_wall_to, true)
	else:
		_set_selection_preview(_selected_wall_from, _selected_wall_to, true)

func _build_opening_snapshot_for_wall(wall_key: String) -> Dictionary:
	var opening_service := App.get_opening_service()
	if opening_service == null or not opening_service.has_opening(wall_key):
		return {"has_opening": false}

	var opening = opening_service.get_opening(wall_key)
	if opening == null:
		return {"has_opening": false}

	return {
		"has_opening": true,
		"type": str(opening.type),
		"offset_t": float(opening.offset_t),
		"scene_path": str(opening.scene_path),
	}

func _move_wall_segment(from_a: Vector2i, from_b: Vector2i, to_a: Vector2i, to_b: Vector2i, floor_index: int, opening_snapshot: Dictionary) -> bool:
	var wall_service := App.get_wall_service()
	if not wall_service.has_wall(from_a, from_b, floor_index):
		return false
	if not wall_service.can_place_wall(to_a, to_b, floor_index):
		return false

	wall_service.begin_batch()
	var removed : bool = wall_service.remove_wall(from_a, from_b, floor_index)
	if not removed:
		wall_service.end_batch()
		return false

	var placed : bool = wall_service.place_wall(to_a, to_b, floor_index)
	if not placed:
		wall_service.place_wall(from_a, from_b, floor_index)
		wall_service.end_batch()
		return false
	wall_service.end_batch()

	if bool(opening_snapshot.get("has_opening", false)):
		var opening_service := App.get_opening_service()
		if opening_service != null:
			var new_key : String = wall_service.make_key(to_a, to_b, floor_index)
			if not opening_service.has_opening(new_key):
				opening_service.place_opening(
					new_key,
					str(opening_snapshot.get("type", "door")),
					float(opening_snapshot.get("offset_t", 0.5)),
					str(opening_snapshot.get("scene_path", ""))
				)

	return true

func _set_selection_preview(from_tile: Vector2i, to_tile: Vector2i, valid: bool) -> void:
	_preview_tiles.clear()
	_preview_tiles.append(from_tile)
	_preview_tiles.append(to_tile)
	_selection_preview_valid = valid
	_rebuild_preview_meshes_if_needed()

func _clear_wall_selection_state() -> void:
	_has_selected_wall = false
	_selected_wall_from = Vector2i.ZERO
	_selected_wall_to = Vector2i.ZERO
	_selected_wall_floor = 0
	_wall_drag_axis = Vector2i.ZERO
	_wall_drag_steps = 0
	_wall_target_valid = false

func _perpendicular_axis_for_wall(from_tile: Vector2i, to_tile: Vector2i) -> Vector2i:
	var diff := to_tile - from_tile
	if diff.x != 0:
		return Vector2i(0, 1)
	return Vector2i(1, 0)

func _find_wall_under_mouse() -> Dictionary:
	var tile: Vector2i = _get_corner_under_mouse()
	var floor_index: int = App.get_floor_service().current_floor
	var offsets := [
		Vector2i(1, 0),
		Vector2i(-1, 0),
		Vector2i(0, 1),
		Vector2i(0, -1),
	]

	for offset in offsets:
		var neighbor : Vector2i = tile + offset
		if App.get_wall_service().has_wall(tile, neighbor, floor_index):
			return {
				"from": tile,
				"to": neighbor,
				"floor_index": floor_index,
			}

	return {}

# -------------------------------------------------------
# Room commit — 4 sides as one undo action
# -------------------------------------------------------

func _commit_room(from_corner: Vector2i, to_corner: Vector2i) -> void:
	var pairs := _get_room_wall_pairs(from_corner, to_corner)
	if pairs.is_empty():
		return
	var floor_index : int = App.get_floor_service().current_floor

	# Only keep pairs that can actually be placed
	var new_pairs: Array[Vector2i] = []
	for i in range(0, pairs.size(), 2):
		if App.get_wall_service().can_place_wall(pairs[i], pairs[i + 1], floor_index):
			new_pairs.append(pairs[i])
			new_pairs.append(pairs[i + 1])

	if new_pairs.is_empty():
		return

	App.get_history_service().execute(
		"place room",
		func():
			App.get_wall_service().begin_batch()
			for i in range(0, new_pairs.size(), 2):
				App.get_wall_service().place_wall(new_pairs[i], new_pairs[i + 1], floor_index)
			App.get_wall_service().end_batch(),
		func():
			App.get_wall_service().begin_batch()
			for i in range(0, new_pairs.size(), 2):
				App.get_wall_service().remove_wall(new_pairs[i], new_pairs[i + 1], floor_index)
			App.get_wall_service().end_batch()
	)

# -------------------------------------------------------
# Wall segment commits (same as before)
# -------------------------------------------------------

func _commit_place_segment(from_corner: Vector2i, to_corner: Vector2i) -> void:
	var pairs : Array = App.get_wall_service().get_wall_pairs_for_corner_segment(from_corner, to_corner)
	if pairs.is_empty():
		return
	var floor_index : int = App.get_floor_service().current_floor
	var new_pairs: Array[Vector2i] = []
	for i in range(0, pairs.size(), 2):
		if App.get_wall_service().can_place_wall(pairs[i], pairs[i + 1], floor_index):
			new_pairs.append(pairs[i])
			new_pairs.append(pairs[i + 1])
	if new_pairs.is_empty():
		return
	App.get_history_service().execute(
		"place walls",
		func():
			App.get_wall_service().begin_batch()
			for i in range(0, new_pairs.size(), 2):
				App.get_wall_service().place_wall(new_pairs[i], new_pairs[i + 1], floor_index)
			App.get_wall_service().end_batch(),
		func():
			App.get_wall_service().begin_batch()
			for i in range(0, new_pairs.size(), 2):
				App.get_wall_service().remove_wall(new_pairs[i], new_pairs[i + 1], floor_index)
			App.get_wall_service().end_batch()
	)

func _commit_delete_segment(from_corner: Vector2i, to_corner: Vector2i) -> void:
	var pairs : Array = App.get_wall_service().get_wall_pairs_for_corner_segment(from_corner, to_corner)
	if pairs.is_empty():
		return
	var floor_index : int = App.get_floor_service().current_floor
	var existing_pairs: Array[Vector2i] = []
	for i in range(0, pairs.size(), 2):
		if App.get_wall_service().has_wall(pairs[i], pairs[i + 1], floor_index):
			existing_pairs.append(pairs[i])
			existing_pairs.append(pairs[i + 1])
	if existing_pairs.is_empty():
		return
	App.get_history_service().execute(
		"delete walls",
		func():
			App.get_wall_service().begin_batch()
			for i in range(0, existing_pairs.size(), 2):
				App.get_wall_service().remove_wall(existing_pairs[i], existing_pairs[i + 1], floor_index)
			App.get_wall_service().end_batch(),
		func():
			App.get_wall_service().begin_batch()
			for i in range(0, existing_pairs.size(), 2):
				App.get_wall_service().place_wall(existing_pairs[i], existing_pairs[i + 1], floor_index)
			App.get_wall_service().end_batch()
	)

# -------------------------------------------------------
# Room geometry helpers
# -------------------------------------------------------

func _get_room_wall_pairs(from_corner: Vector2i, to_corner: Vector2i) -> Array[Vector2i]:
	# A room is 4 wall segments connecting the 4 corners of the rectangle
	# corners:  from_corner, (to.x, from.y), to_corner, (from.x, to.y)
	var pairs: Array[Vector2i] = []
	var c0 := from_corner
	var c1 := Vector2i(to_corner.x, from_corner.y)
	var c2 := to_corner
	var c3 := Vector2i(from_corner.x, to_corner.y)

	# Build 4 sides by running the same corner-segment logic for each edge
	_append_segment_pairs(pairs, c0, c1)  # top
	_append_segment_pairs(pairs, c1, c2)  # right
	_append_segment_pairs(pairs, c2, c3)  # bottom
	_append_segment_pairs(pairs, c3, c0)  # left
	return pairs

func _append_segment_pairs(pairs: Array[Vector2i], from_corner: Vector2i, to_corner: Vector2i) -> void:
	var segment : Array = App.get_wall_service().get_wall_pairs_for_corner_segment(from_corner, to_corner)
	pairs.append_array(segment)

# -------------------------------------------------------
# Preview
# -------------------------------------------------------

func _update_preview(from_corner: Vector2i, to_corner: Vector2i) -> void:
	if _room_mode:
		_preview_tiles = _get_room_wall_pairs(from_corner, to_corner)
	else:
		_preview_tiles = App.get_wall_service().get_wall_pairs_for_corner_segment(from_corner, to_corner)

	if _preview_tiles.is_empty():
		_clear_preview()
		return
	_rebuild_preview_meshes_if_needed()

func _rebuild_preview_meshes_if_needed() -> void:
	var new_keys: Array[String] = []
	for i in range(0, _preview_tiles.size(), 2):
		new_keys.append(_make_preview_pair_key(_preview_tiles[i], _preview_tiles[i + 1]))

	var mode_changed := (
		_preview_nodes.size() > 0 and
		_preview_nodes[0].material_override != _current_preview_material(_preview_tiles[0], _preview_tiles[1])
	)

	if new_keys == _preview_keys and not mode_changed:
		return

	_clear_preview_nodes()
	_preview_keys = new_keys

	for i in range(0, _preview_tiles.size(), 2):
		_create_preview_wall(_preview_tiles[i], _preview_tiles[i + 1])

func _current_preview_material(from_tile: Vector2i, to_tile: Vector2i) -> Material:
	if _selection_mode:
		return wall_preview_material if _selection_preview_valid else wall_delete_material

	var wall_exists : bool = App.get_wall_service().has_wall(from_tile, to_tile)
	if _delete_mode:
		return wall_delete_material if wall_exists else wall_preview_material
	else:
		return wall_preview_material if App.get_wall_service().can_place_wall(from_tile, to_tile) else wall_delete_material

func _create_preview_wall(from_tile: Vector2i, to_tile: Vector2i) -> void:
	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	mesh_instance.mesh = box

	var wall_exists : bool = App.get_wall_service().has_wall(from_tile, to_tile)
	var can_place : bool = App.get_wall_service().can_place_wall(from_tile, to_tile)
	if _delete_mode:
		# Delete mode: red = will be removed, blue = nothing to delete
		mesh_instance.material_override = wall_delete_material if wall_exists else wall_preview_material
	elif _room_mode:
		# Room mode: red = blocked, blue = will be placed
		mesh_instance.material_override = wall_preview_material if can_place else wall_delete_material
	else:
		# Place mode: red = blocked, blue = free
		mesh_instance.material_override = wall_preview_material if can_place else wall_delete_material

	var from_world: Vector3 = App.get_grid_service().tile_to_world(from_tile)
	var to_world: Vector3   = App.get_grid_service().tile_to_world(to_tile)
	var midpoint: Vector3   = (from_world + to_world) * 0.5
	midpoint.y = App.get_grid_service().get_wall_y_base(App.get_floor_service().current_floor) + preview_height * 0.5

	var diff := to_tile - from_tile
	if diff.x != 0:
		box.size = Vector3(preview_thickness, preview_height, App.get_grid_service().TILE_SIZE)
	else:
		box.size = Vector3(App.get_grid_service().TILE_SIZE, preview_height, preview_thickness)

	mesh_instance.position = midpoint
	if get_parent() is Node3D:
		(get_parent() as Node3D).add_child(mesh_instance)
	else:
		add_child(mesh_instance)
	_preview_nodes.append(mesh_instance)

func _clear_preview_nodes() -> void:
	for node in _preview_nodes:
		if is_instance_valid(node):
			node.queue_free()
	_preview_nodes.clear()

func _clear_preview() -> void:
	_preview_tiles.clear()
	_preview_keys.clear()
	_clear_preview_nodes()

# -------------------------------------------------------
# Corner detection
# -------------------------------------------------------

func _get_corner_under_mouse() -> Vector2i:
	var world_pos: Vector3 = mouse_raycast.get_world_position_under_mouse()
	return Vector2i(
		roundi(world_pos.x / App.get_grid_service().TILE_SIZE),
		roundi(world_pos.z / App.get_grid_service().TILE_SIZE)
	)

# -------------------------------------------------------
# Start pointer
# -------------------------------------------------------

func _update_start_pointer(corner: Vector2i) -> void:
	_ensure_start_pointer()
	if _start_pointer_node == null:
		return
	_start_pointer_node.position = Vector3(
		corner.x * App.get_grid_service().TILE_SIZE,
		App.get_grid_service().get_wall_y_base(App.get_floor_service().current_floor) + pointer_y_offset + pointer_height * 0.5,
		corner.y * App.get_grid_service().TILE_SIZE
	)
	# Tint matches current mode
	if _room_mode:
		_start_pointer_node.material_override = preload("res://materials/WallPreview.tres")
	elif _delete_mode:
		_start_pointer_node.material_override = wall_delete_material
	else:
		_start_pointer_node.material_override = start_pointer_material

func _ensure_start_pointer() -> void:
	if is_instance_valid(_start_pointer_node):
		return
	var pointer := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = pointer_radius
	mesh.bottom_radius = pointer_radius
	mesh.height = pointer_height
	mesh.radial_segments = 24
	pointer.mesh = mesh
	pointer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pointer.material_override = start_pointer_material
	if get_parent() is Node3D:
		(get_parent() as Node3D).add_child(pointer)
	else:
		add_child(pointer)
	_start_pointer_node = pointer

func _clear_start_pointer() -> void:
	if is_instance_valid(_start_pointer_node):
		_start_pointer_node.queue_free()
	_start_pointer_node = null

func _make_preview_pair_key(a: Vector2i, b: Vector2i) -> String:
	if a.x < b.x or (a.x == b.x and a.y < b.y):
		return "%d,%d|%d,%d" % [a.x, a.y, b.x, b.y]
	return "%d,%d|%d,%d" % [b.x, b.y, a.x, a.y]
