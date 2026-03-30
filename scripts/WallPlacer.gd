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
var _drag_start_corner: Vector2i = Vector2i.ZERO
var _preview_tiles: Array[Vector2i] = []
var _preview_nodes: Array[MeshInstance3D] = []
var _preview_keys: Array[String] = []
var _start_pointer_node: MeshInstance3D = null

func _ready() -> void:
	preview_height = FloorManager.FLOOR_HEIGHT

func activate() -> void:
	active = true

func deactivate() -> void:
	active = false
	_cancel_drag()
	_clear_start_pointer()

# -------------------------------------------------------
# Input
# -------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not active:
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
			if ke.keycode == KEY_CTRL or ke.keycode == KEY_META:
				_delete_mode = ke.pressed
			if ke.keycode == KEY_SHIFT:
				_room_mode = ke.pressed

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
				_delete_mode = Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_META)
				_room_mode   = Input.is_key_pressed(KEY_SHIFT)
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

	# Keep mode flags in sync when not dragging
	if not _is_placing:
		_delete_mode = Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_META)
		_room_mode   = Input.is_key_pressed(KEY_SHIFT)

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
	_delete_mode = Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_META)
	_room_mode   = Input.is_key_pressed(KEY_SHIFT)

func _cancel_drag() -> void:
	_is_placing = false
	_clear_preview()
	_delete_mode = Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_META)
	_room_mode   = Input.is_key_pressed(KEY_SHIFT)

# -------------------------------------------------------
# Room commit — 4 sides as one undo action
# -------------------------------------------------------

func _commit_room(from_corner: Vector2i, to_corner: Vector2i) -> void:
	var pairs := _get_room_wall_pairs(from_corner, to_corner)
	if pairs.is_empty():
		return
	var floor_index := FloorManager.current_floor

	# Only keep pairs that can actually be placed
	var new_pairs: Array[Vector2i] = []
	for i in range(0, pairs.size(), 2):
		if WallSystem.can_place_wall(pairs[i], pairs[i + 1], floor_index):
			new_pairs.append(pairs[i])
			new_pairs.append(pairs[i + 1])

	if new_pairs.is_empty():
		return

	UndoHistory.execute(
		"place room",
		func():
			WallSystem.begin_batch()
			for i in range(0, new_pairs.size(), 2):
				WallSystem.place_wall(new_pairs[i], new_pairs[i + 1], floor_index)
			WallSystem.end_batch(),
		func():
			WallSystem.begin_batch()
			for i in range(0, new_pairs.size(), 2):
				WallSystem.remove_wall(new_pairs[i], new_pairs[i + 1], floor_index)
			WallSystem.end_batch()
	)

# -------------------------------------------------------
# Wall segment commits (same as before)
# -------------------------------------------------------

func _commit_place_segment(from_corner: Vector2i, to_corner: Vector2i) -> void:
	var pairs : Array = WallSystem.get_wall_pairs_for_corner_segment(from_corner, to_corner)
	if pairs.is_empty():
		return
	var floor_index := FloorManager.current_floor
	var new_pairs: Array[Vector2i] = []
	for i in range(0, pairs.size(), 2):
		if WallSystem.can_place_wall(pairs[i], pairs[i + 1], floor_index):
			new_pairs.append(pairs[i])
			new_pairs.append(pairs[i + 1])
	if new_pairs.is_empty():
		return
	UndoHistory.execute(
		"place walls",
		func():
			WallSystem.begin_batch()
			for i in range(0, new_pairs.size(), 2):
				WallSystem.place_wall(new_pairs[i], new_pairs[i + 1], floor_index)
			WallSystem.end_batch(),
		func():
			WallSystem.begin_batch()
			for i in range(0, new_pairs.size(), 2):
				WallSystem.remove_wall(new_pairs[i], new_pairs[i + 1], floor_index)
			WallSystem.end_batch()
	)

func _commit_delete_segment(from_corner: Vector2i, to_corner: Vector2i) -> void:
	var pairs : Array = WallSystem.get_wall_pairs_for_corner_segment(from_corner, to_corner)
	if pairs.is_empty():
		return
	var floor_index := FloorManager.current_floor
	var existing_pairs: Array[Vector2i] = []
	for i in range(0, pairs.size(), 2):
		if WallSystem.has_wall(pairs[i], pairs[i + 1], floor_index):
			existing_pairs.append(pairs[i])
			existing_pairs.append(pairs[i + 1])
	if existing_pairs.is_empty():
		return
	UndoHistory.execute(
		"delete walls",
		func():
			WallSystem.begin_batch()
			for i in range(0, existing_pairs.size(), 2):
				WallSystem.remove_wall(existing_pairs[i], existing_pairs[i + 1], floor_index)
			WallSystem.end_batch(),
		func():
			WallSystem.begin_batch()
			for i in range(0, existing_pairs.size(), 2):
				WallSystem.place_wall(existing_pairs[i], existing_pairs[i + 1], floor_index)
			WallSystem.end_batch()
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
	var segment : Array = WallSystem.get_wall_pairs_for_corner_segment(from_corner, to_corner)
	pairs.append_array(segment)

# -------------------------------------------------------
# Preview
# -------------------------------------------------------

func _update_preview(from_corner: Vector2i, to_corner: Vector2i) -> void:
	if _room_mode:
		_preview_tiles = _get_room_wall_pairs(from_corner, to_corner)
	else:
		_preview_tiles = WallSystem.get_wall_pairs_for_corner_segment(from_corner, to_corner)

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
	var wall_exists := WallSystem.has_wall(from_tile, to_tile)
	if _delete_mode:
		return wall_delete_material if wall_exists else wall_preview_material
	else:
		return wall_preview_material if WallSystem.can_place_wall(from_tile, to_tile) else wall_delete_material

func _create_preview_wall(from_tile: Vector2i, to_tile: Vector2i) -> void:
	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	mesh_instance.mesh = box

	var wall_exists := WallSystem.has_wall(from_tile, to_tile)
	var can_place : bool = WallSystem.can_place_wall(from_tile, to_tile)
	if _delete_mode:
		# Delete mode: red = will be removed, blue = nothing to delete
		mesh_instance.material_override = wall_delete_material if wall_exists else wall_preview_material
	elif _room_mode:
		# Room mode: red = blocked, blue = will be placed
		mesh_instance.material_override = wall_preview_material if can_place else wall_delete_material
	else:
		# Place mode: red = blocked, blue = free
		mesh_instance.material_override = wall_preview_material if can_place else wall_delete_material

	var from_world: Vector3 = GridManager.tile_to_world(from_tile)
	var to_world: Vector3   = GridManager.tile_to_world(to_tile)
	var midpoint: Vector3   = (from_world + to_world) * 0.5
	midpoint.y = GridManager.get_wall_y_base(FloorManager.current_floor) + preview_height * 0.5

	var diff := to_tile - from_tile
	if diff.x != 0:
		box.size = Vector3(preview_thickness, preview_height, GridManager.TILE_SIZE)
	else:
		box.size = Vector3(GridManager.TILE_SIZE, preview_height, preview_thickness)

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
		roundi(world_pos.x / GridManager.TILE_SIZE),
		roundi(world_pos.z / GridManager.TILE_SIZE)
	)

# -------------------------------------------------------
# Start pointer
# -------------------------------------------------------

func _update_start_pointer(corner: Vector2i) -> void:
	_ensure_start_pointer()
	if _start_pointer_node == null:
		return
	_start_pointer_node.position = Vector3(
		corner.x * GridManager.TILE_SIZE,
		GridManager.get_wall_y_base(FloorManager.current_floor) + pointer_y_offset + pointer_height * 0.5,
		corner.y * GridManager.TILE_SIZE
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
