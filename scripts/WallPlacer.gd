extends Node

@export var mouse_raycast: Node
@export var active: bool = true
@export var wall_preview_material: Material = preload("res://materials/WallPreview.tres")
@export var wall_delete_material: Material = preload("res://materials/WallDelete.tres")
@export var preview_height: float = 3.0
@export var preview_thickness: float = 0.15
@export var start_pointer_material: Material = preload("res://materials/WallPreview.tres")
@export var pointer_radius: float = 0.28
@export var pointer_height: float = 0.04
@export var pointer_y_offset: float = 0.02

var _is_placing: bool = false
var _delete_mode: bool = false
var _drag_start_corner: Vector2i = Vector2i.ZERO
var _preview_tiles: Array[Vector2i] = []
var _preview_nodes: Array[MeshInstance3D] = []
var _preview_keys: Array[String] = []
var _start_pointer_node: MeshInstance3D = null

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

	# --- Mode switch: track Ctrl key ---
	if event is InputEventKey:
		var ke := event as InputEventKey
		if ke.keycode == KEY_CTRL or ke.keycode == KEY_META:
			# Update delete mode only when not mid-drag to avoid mode-switch accidents
			if not _is_placing:
				_delete_mode = ke.pressed

		# Escape cancels an active drag
		if ke.pressed and ke.keycode == KEY_ESCAPE:
			if _is_placing:
				_cancel_drag()
			return

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton

		# Right mouse button cancels an active drag (mirrors Escape)
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if _is_placing:
				_cancel_drag()
			return

		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				# Lock delete mode at drag start so Ctrl release mid-drag doesn't flip it
				_delete_mode = Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_META)
				_drag_start_corner = _get_corner_under_mouse()
				_is_placing = true
			else:
				if _is_placing:
					var end_corner: Vector2i = _get_corner_under_mouse()
					_commit_drag(end_corner)

# -------------------------------------------------------
# Process: preview update
# -------------------------------------------------------

func _process(_delta: float) -> void:
	if not active:
		_clear_start_pointer()
		return

	var pointer_corner: Vector2i = _drag_start_corner if _is_placing else _get_corner_under_mouse()
	_update_start_pointer(pointer_corner)

	if not _is_placing:
		return

	var current_corner: Vector2i = _get_corner_under_mouse()
	_update_preview(_drag_start_corner, current_corner)

# -------------------------------------------------------
# Commit and cancel
# -------------------------------------------------------

func _commit_drag(end_corner: Vector2i) -> void:
	var pairs : Array = WallSystem.get_wall_pairs_for_corner_segment(_drag_start_corner, end_corner)
	if pairs.is_empty():
		_is_placing = false
		_clear_preview()
		return

	if _delete_mode:
		# Snapshot which walls actually exist so undo restores only those
		var existing_pairs: Array[Vector2i] = []
		for i in range(0, pairs.size(), 2):
			if WallSystem.has_wall(pairs[i], pairs[i + 1]):
				existing_pairs.append(pairs[i])
				existing_pairs.append(pairs[i + 1])

		if not existing_pairs.is_empty():
			UndoHistory.execute(
				"delete walls",
				func():
					WallSystem.begin_batch()
					for i in range(0, existing_pairs.size(), 2):
						WallSystem.remove_wall(existing_pairs[i], existing_pairs[i + 1])
					WallSystem.end_batch(),
				func():
					WallSystem.begin_batch()
					for i in range(0, existing_pairs.size(), 2):
						WallSystem.place_wall(existing_pairs[i], existing_pairs[i + 1])
					WallSystem.end_batch()
			)
	else:
		# Snapshot which walls are NEW so undo removes only those
		var new_pairs: Array[Vector2i] = []
		for i in range(0, pairs.size(), 2):
			if not WallSystem.has_wall(pairs[i], pairs[i + 1]):
				new_pairs.append(pairs[i])
				new_pairs.append(pairs[i + 1])

		if not new_pairs.is_empty():
			UndoHistory.execute(
				"place walls",
				func():
					WallSystem.begin_batch()
					for i in range(0, new_pairs.size(), 2):
						WallSystem.place_wall(new_pairs[i], new_pairs[i + 1])
					WallSystem.end_batch(),
				func():
					WallSystem.begin_batch()
					for i in range(0, new_pairs.size(), 2):
						WallSystem.remove_wall(new_pairs[i], new_pairs[i + 1])
					WallSystem.end_batch()
			)

	_is_placing = false
	_clear_preview()
	_delete_mode = Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_META)


func _cancel_drag() -> void:
	_is_placing = false
	_clear_preview()
	# Keep delete mode in sync with actual key state
	_delete_mode = Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_META)

# -------------------------------------------------------
# Delete segment (mirrors WallSystem's placement logic)
# -------------------------------------------------------

func _delete_segment(from_corner: Vector2i, to_corner: Vector2i) -> void:
	var pairs : Array = WallSystem.get_wall_pairs_for_corner_segment(from_corner, to_corner)
	WallSystem.begin_batch()
	for i in range(0, pairs.size(), 2):
		WallSystem.remove_wall(pairs[i], pairs[i + 1])
	WallSystem.end_batch()

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
	var world_pos := Vector3(
		corner.x * GridManager.TILE_SIZE,
		pointer_y_offset + pointer_height * 0.5,
		corner.y * GridManager.TILE_SIZE
	)
	_start_pointer_node.position = world_pos
	# Tint pointer to match current mode
	if start_pointer_material != null:
		_start_pointer_node.material_override = \
			wall_delete_material if _delete_mode else start_pointer_material

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

# -------------------------------------------------------
# Preview meshes
# -------------------------------------------------------

func _update_preview(from_corner: Vector2i, to_corner: Vector2i) -> void:
	_preview_tiles = WallSystem.get_wall_pairs_for_corner_segment(from_corner, to_corner)
	if _preview_tiles.is_empty():
		_clear_preview()
		return
	_rebuild_preview_meshes_if_needed()

func _rebuild_preview_meshes_if_needed() -> void:
	var new_keys: Array[String] = []
	for i in range(0, _preview_tiles.size(), 2):
		new_keys.append(WallSystem.make_key(_preview_tiles[i], _preview_tiles[i + 1]))

	# Also rebuild if mode changed (place ↔ delete changes material)
	var mode_changed := (_preview_nodes.size() > 0 and
		_preview_nodes[0].material_override != _current_preview_material())

	if new_keys == _preview_keys and not mode_changed:
		return

	_clear_preview_nodes()
	_preview_keys = new_keys

	for i in range(0, _preview_tiles.size(), 2):
		_create_preview_wall(_preview_tiles[i], _preview_tiles[i + 1])

func _current_preview_material() -> Material:
	return wall_delete_material if _delete_mode else wall_preview_material

func _create_preview_wall(from_tile: Vector2i, to_tile: Vector2i) -> void:
	var mesh_instance := MeshInstance3D.new()
	var box := BoxMesh.new()
	mesh_instance.mesh = box

	# In delete mode: red if wall EXISTS (valid target), gray if no wall there
	# In place mode:  red if wall EXISTS (blocked),     blue if free
	var wall_exists := WallSystem.has_wall(from_tile, to_tile)
	var mat: Material
	if _delete_mode:
		mat = wall_delete_material if wall_exists else wall_preview_material
	else:
		mat = wall_delete_material if wall_exists else wall_preview_material
		# Place mode: blocked = red (reuse delete material as "error" color)
		mat = wall_delete_material if wall_exists else wall_preview_material

	mesh_instance.material_override = mat

	var from_world: Vector3 = GridManager.tile_to_world(from_tile)
	var to_world: Vector3   = GridManager.tile_to_world(to_tile)
	var midpoint: Vector3   = (from_world + to_world) * 0.5
	midpoint.y = preview_height * 0.5

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
