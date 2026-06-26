# FurniturePlacer.gd
extends Node

@export var mouse_raycast: Node
@export var furniture_container: Node3D
@export var active: bool = false
@export var free_collision_padding: float = 0.03

const MODE_PLACE := 0
const MODE_DELETE := 1
const MODE_EDIT := 2
const PREVIEW_COLLISION_TIGHTEN_FACTOR := 0.92

# Set these when player selects a furniture item from the UI
var current_scene_path: String = ""
var current_size: Vector2i = Vector2i(1, 1)   # in tiles
var current_item_id: String = ""
var current_attachment_slots: Array = []

# Internal state
var _tool_mode: int = MODE_PLACE
var _rotation_index: int = 0        # 0=0, 1=90, 2=180, 3=270
var _free_mode: bool = false         # Alt held (place mode)
var _preview_instance: Node3D = null
var _preview_valid: bool = false

# Edit-mode selection
var _selected_snapshot: Dictionary = {}
var _selected_rotation_index: int = 0
var _is_edit_dragging: bool = false
var _edit_drag_origin_snapshot: Dictionary = {}

func is_room_selection_locked() -> bool:
	return active and _tool_mode == MODE_EDIT and (_is_edit_dragging or not _selected_snapshot.is_empty())

func _resolve_furniture_container() -> Node3D:
	if is_instance_valid(furniture_container):
		return furniture_container

	var parent_3d := get_parent() as Node3D
	if parent_3d == null:
		return null

	var existing := parent_3d.get_node_or_null("FurnitureContainer")
	if existing is Node3D:
		furniture_container = existing as Node3D
		return furniture_container

	var runtime_container := Node3D.new()
	runtime_container.name = "FurnitureContainer"
	parent_3d.add_child(runtime_container)
	furniture_container = runtime_container
	return furniture_container

func activate(scene_path: String, size: Vector2i, item_id: String = "", attachment_slots: Array = []) -> void:
	current_scene_path = scene_path
	current_size = size
	current_item_id = item_id
	current_attachment_slots = attachment_slots.duplicate(true)
	active = true
	_tool_mode = MODE_PLACE
	_rotation_index = 0
	_clear_edit_drag_state()
	_clear_selected_snapshot()
	_resolve_furniture_container()
	_spawn_preview()

func activate_delete_mode() -> void:
	active = true
	_tool_mode = MODE_DELETE
	current_scene_path = ""
	current_item_id = ""
	current_attachment_slots.clear()
	_rotation_index = 0
	_clear_edit_drag_state()
	_clear_selected_snapshot()
	_resolve_furniture_container()
	_destroy_preview()

func activate_edit_mode() -> void:
	active = true
	_tool_mode = MODE_EDIT
	current_scene_path = ""
	current_item_id = ""
	current_attachment_slots.clear()
	_rotation_index = 0
	_resolve_furniture_container()
	_destroy_preview()
	_clear_edit_drag_state()
	_clear_selected_snapshot()

func deactivate() -> void:
	active = false
	_tool_mode = MODE_PLACE
	current_item_id = ""
	current_attachment_slots.clear()
	_destroy_preview()
	_clear_edit_drag_state()
	_clear_selected_snapshot()

# -------------------------------------------------------
# Input
# -------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return

	if event is InputEventKey:
		var ke := event as InputEventKey

		if ke.pressed and ke.keycode == KEY_ESCAPE:
			deactivate()
			return

		if ke.pressed and ke.keycode == KEY_R:
			if _tool_mode == MODE_PLACE:
				_rotation_index = (_rotation_index + 1) % 4
				if is_instance_valid(_preview_instance):
					_preview_instance.rotation_degrees.y = _rotation_index * 90.0
			elif _tool_mode == MODE_EDIT:
				if _is_edit_dragging:
					_selected_rotation_index = (_selected_rotation_index + 1) % 4
					_rotation_index = _selected_rotation_index
					_update_edit_drag_preview()
				else:
					_rotate_selected_furniture()

		if ke.pressed and ke.keycode == KEY_DELETE and _tool_mode == MODE_EDIT:
			_delete_selected_furniture()

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton

		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			deactivate()
			return

		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if _tool_mode == MODE_DELETE:
					_delete_furniture_under_cursor()
				elif _tool_mode == MODE_EDIT:
					if _is_edit_dragging:
						_try_commit_edit_drag()
					else:
						_handle_edit_left_pressed()
				elif _preview_valid:
					_place_furniture()

func _process(_delta: float) -> void:
	if not active:
		return
	if _tool_mode == MODE_EDIT and _is_edit_dragging:
		_free_mode = Input.is_key_pressed(KEY_ALT)
		_rotation_index = _selected_rotation_index
		_update_edit_drag_preview()
		return
	if _tool_mode != MODE_PLACE:
		return
	if current_scene_path == "":
		return

	_free_mode = Input.is_key_pressed(KEY_ALT)
	_update_preview_position()

# -------------------------------------------------------
# Edit mode
# -------------------------------------------------------

func _handle_edit_left_pressed() -> void:
	var floor_index : int = int(App.get_floor_service().current_floor)
	var world_pos: Vector3 = mouse_raycast.get_world_position_under_mouse()
	var clicked_snapshot: Dictionary = App.get_furniture_service().get_snapshot_at_world(world_pos, floor_index)

	if _selected_snapshot.is_empty():
		if clicked_snapshot.is_empty():
			return
		_set_selected_snapshot(clicked_snapshot)
		_begin_edit_drag()
		return

	var selected_node_id := int(_selected_snapshot.get("node_id", -1))
	var clicked_node_id := int(clicked_snapshot.get("node_id", -1))

	if not clicked_snapshot.is_empty() and clicked_node_id >= 0 and clicked_node_id != selected_node_id:
		_set_selected_snapshot(clicked_snapshot)
		_begin_edit_drag()
		return

	if not clicked_snapshot.is_empty() and clicked_node_id == selected_node_id:
		_begin_edit_drag()

func select_edit_from_external_click(start_drag: bool = false) -> bool:
	if not active or _tool_mode != MODE_EDIT:
		return false

	var floor_index : int = int(App.get_floor_service().current_floor)
	var world_pos: Vector3 = mouse_raycast.get_world_position_under_mouse()
	var clicked_snapshot: Dictionary = App.get_furniture_service().get_snapshot_at_world(world_pos, floor_index)
	if clicked_snapshot.is_empty():
		return false

	var selected_node_id := int(_selected_snapshot.get("node_id", -1))
	var clicked_node_id := int(clicked_snapshot.get("node_id", -1))
	if selected_node_id != clicked_node_id:
		_set_selected_snapshot(clicked_snapshot)

	if start_drag:
		_begin_edit_drag()
	return true

func _try_commit_edit_drag() -> void:
	if not _is_edit_dragging or _edit_drag_origin_snapshot.is_empty():
		return

	var old_snapshot: Dictionary = _edit_drag_origin_snapshot.duplicate(true)
	var new_snapshot := _build_target_snapshot_from_cursor(old_snapshot)
	if new_snapshot.is_empty():
		return

	# Allow putting it back in the original position even if self-overlap made preview invalid.
	if _snapshot_pose_equal(old_snapshot, new_snapshot):
		_end_edit_drag_cleanup()
		return

	if not _preview_valid:
		return

	if _move_snapshot(old_snapshot, new_snapshot):
		_set_selected_snapshot(new_snapshot)
		_end_edit_drag_cleanup()

func _begin_edit_drag() -> void:
	if _selected_snapshot.is_empty():
		return
	if _is_edit_dragging:
		return
	_is_edit_dragging = true
	_edit_drag_origin_snapshot = _selected_snapshot.duplicate(true)
	current_scene_path = str(_selected_snapshot.get("scene_path", ""))
	current_size = _selected_snapshot.get("size", Vector2i.ONE)
	current_item_id = str(_selected_snapshot.get("item_id", ""))
	var slot_meta : Variant = _selected_snapshot.get("attachment_slots", [])
	current_attachment_slots = slot_meta.duplicate(true) if slot_meta is Array else []
	_rotation_index = _selected_rotation_index
	_set_selected_node_visible(false)
	_spawn_edit_drag_preview()
	_update_edit_drag_preview()

func _end_edit_drag_cleanup() -> void:
	_is_edit_dragging = false
	_edit_drag_origin_snapshot.clear()
	_set_selected_node_visible(true)
	_destroy_preview()

func _move_selected_to_cursor() -> void:
	if _selected_snapshot.is_empty():
		return

	var old_snapshot: Dictionary = _selected_snapshot.duplicate(true)
	var new_snapshot := _build_target_snapshot_from_cursor(old_snapshot)
	if new_snapshot.is_empty() or _snapshot_pose_equal(old_snapshot, new_snapshot):
		return

	if _move_snapshot(old_snapshot, new_snapshot):
		_set_selected_snapshot(new_snapshot)

func _move_snapshot(old_snapshot: Dictionary, new_snapshot: Dictionary) -> bool:
	var target_container := _resolve_furniture_container()
	if target_container == null:
		push_error("FurniturePlacer: no valid furniture container.")
		return false

	var did_apply := [false]
	App.execute_build_command(
		"move furniture",
		func():
			did_apply[0] = _replace_snapshot(old_snapshot, new_snapshot, target_container)
			return did_apply[0],
		func():
			return _replace_snapshot(new_snapshot, old_snapshot, target_container)
	)
	return did_apply[0]

func _rotate_selected_furniture() -> void:
	if _selected_snapshot.is_empty():
		return

	var target_container := _resolve_furniture_container()
	if target_container == null:
		push_error("FurniturePlacer: no valid furniture container.")
		return

	var old_snapshot: Dictionary = _selected_snapshot.duplicate(true)
	var new_snapshot: Dictionary = old_snapshot.duplicate(true)
	var next_rotation := (_selected_rotation_index + 1) % 4
	new_snapshot["rotation_index"] = next_rotation

	var size: Vector2i = new_snapshot.get("size", Vector2i.ONE)
	var use_grid := bool(new_snapshot.get("uses_grid_occupancy", true))
	if use_grid:
		var tile: Vector2i = new_snapshot.get("tile", Vector2i.ZERO)
		new_snapshot["world_pos"] = App.get_furniture_service().get_snapped_world_position(tile, size, next_rotation)

	var did_apply := [false]
	App.execute_build_command(
		"rotate furniture",
		func():
			did_apply[0] = _replace_snapshot(old_snapshot, new_snapshot, target_container)
			return did_apply[0],
		func():
			return _replace_snapshot(new_snapshot, old_snapshot, target_container)
	)

	if did_apply[0]:
		_set_selected_snapshot(new_snapshot)

func _delete_selected_furniture() -> void:
	if _selected_snapshot.is_empty():
		return

	var target_container := _resolve_furniture_container()
	if target_container == null:
		push_error("FurniturePlacer: no valid furniture container.")
		return

	var snapshot: Dictionary = _selected_snapshot.duplicate(true)
	var did_delete := [false]
	App.execute_build_command(
		"delete furniture",
		func():
			did_delete[0] = App.get_furniture_service().remove_matching_snapshot(snapshot)
			return did_delete[0],
		func():
			return App.get_furniture_service().restore_snapshot(snapshot, target_container)
	)

	if did_delete[0]:
		_clear_selected_snapshot()

func _set_selected_snapshot(snapshot: Dictionary) -> void:
	_selected_snapshot = snapshot.duplicate(true)
	_selected_rotation_index = int(_selected_snapshot.get("rotation_index", 0))

func _clear_selected_snapshot() -> void:
	_set_selected_node_visible(true)
	_selected_snapshot.clear()
	_selected_rotation_index = 0

func _clear_edit_drag_state() -> void:
	_is_edit_dragging = false
	_edit_drag_origin_snapshot.clear()
	_set_selected_node_visible(true)
	_destroy_preview()

func _spawn_edit_drag_preview() -> void:
	_spawn_preview()

func _update_edit_drag_preview() -> void:
	var ignored_node_id := _get_edit_drag_ignored_node_id()
	_update_preview_position(ignored_node_id)

func _get_edit_drag_ignored_node_id() -> int:
	if _edit_drag_origin_snapshot.has("node_id"):
		return int(_edit_drag_origin_snapshot.get("node_id", -1))
	if _selected_snapshot.has("node_id"):
		return int(_selected_snapshot.get("node_id", -1))
	return -1

func _set_selected_node_visible(visible: bool) -> void:
	if _selected_snapshot.is_empty():
		return
	var node_id := int(_selected_snapshot.get("node_id", -1))
	if node_id < 0:
		return
	var obj := instance_from_id(node_id)
	if obj is Node3D and is_instance_valid(obj):
		(obj as Node3D).visible = visible

func _build_target_snapshot_from_cursor(base_snapshot: Dictionary) -> Dictionary:
	if base_snapshot.is_empty():
		return {}

	var next_snapshot: Dictionary = base_snapshot.duplicate(true)
	var use_grid_requested := not Input.is_key_pressed(KEY_ALT)
	var floor_index := int(next_snapshot.get("floor_index", App.get_floor_service().current_floor))
	var raw_tile : Vector2i = mouse_raycast.get_tile_under_mouse()
	var raw_world : Vector3 = App.get_furniture_service().get_snapped_world_position(raw_tile, current_size, _selected_rotation_index)
	if not use_grid_requested:
		raw_world = mouse_raycast.get_world_position_under_mouse()
	var candidate := _resolve_placement_candidate(raw_tile, raw_world, _selected_rotation_index, use_grid_requested, _get_edit_drag_ignored_node_id())

	next_snapshot["tile"] = candidate.get("tile", Vector2i.ZERO)
	next_snapshot["world_pos"] = candidate.get("world_pos", Vector3.ZERO)
	next_snapshot["rotation_index"] = int(candidate.get("rotation_index", _selected_rotation_index))
	next_snapshot["uses_grid_occupancy"] = bool(candidate.get("use_grid", true))
	next_snapshot["attached_to_node_id"] = int(candidate.get("attached_to_node_id", -1))
	next_snapshot["attached_slot_id"] = str(candidate.get("attached_slot_id", ""))
	next_snapshot["allow_overlap_node_ids"] = candidate.get("allow_overlap_node_ids", [])
	next_snapshot["floor_index"] = floor_index
	return next_snapshot

func _snapshot_pose_equal(a: Dictionary, b: Dictionary) -> bool:
	if bool(a.get("uses_grid_occupancy", true)) != bool(b.get("uses_grid_occupancy", true)):
		return false
	if int(a.get("rotation_index", 0)) != int(b.get("rotation_index", 0)):
		return false
	if int(a.get("attached_to_node_id", -1)) != int(b.get("attached_to_node_id", -1)):
		return false
	if str(a.get("attached_slot_id", "")) != str(b.get("attached_slot_id", "")):
		return false
	if int(a.get("floor_index", 0)) != int(b.get("floor_index", 0)):
		return false
	if (a.get("tile", Vector2i.ZERO) as Vector2i) != (b.get("tile", Vector2i.ZERO) as Vector2i):
		return false
	return (a.get("world_pos", Vector3.ZERO) as Vector3).is_equal_approx(b.get("world_pos", Vector3.ZERO))

func _replace_snapshot(old_snapshot: Dictionary, new_snapshot: Dictionary, target_container: Node3D) -> bool:
	if old_snapshot.is_empty() or new_snapshot.is_empty():
		return false

	if not App.get_furniture_service().remove_matching_snapshot(old_snapshot):
		return false

	var tile: Vector2i = new_snapshot.get("tile", Vector2i.ZERO)
	var world_pos: Vector3 = new_snapshot.get("world_pos", Vector3.ZERO)
	var rotation_index := int(new_snapshot.get("rotation_index", 0))
	var scene_path := str(new_snapshot.get("scene_path", ""))
	var item_id := str(new_snapshot.get("item_id", ""))
	var size: Vector2i = new_snapshot.get("size", Vector2i.ONE)
	var use_grid := bool(new_snapshot.get("uses_grid_occupancy", true))
	var floor_index := int(new_snapshot.get("floor_index", App.get_floor_service().current_floor))
	var attached_to_node_id := int(new_snapshot.get("attached_to_node_id", -1))
	var attached_slot_id := str(new_snapshot.get("attached_slot_id", ""))
	var attachment_slots : Variant = new_snapshot.get("attachment_slots", [])
	if not (attachment_slots is Array):
		attachment_slots = []
	var allowed_overlap_node_ids : Variant = new_snapshot.get("allow_overlap_node_ids", [])
	if attached_to_node_id >= 0:
		if not (allowed_overlap_node_ids is Array):
			allowed_overlap_node_ids = []
		var overlap_ids := allowed_overlap_node_ids as Array
		if not overlap_ids.has(attached_to_node_id):
			overlap_ids.append(attached_to_node_id)
		allowed_overlap_node_ids = overlap_ids

	var valid_target := true
	if use_grid:
		valid_target = App.get_furniture_service().can_place(tile, size, rotation_index)
	else:
		valid_target = App.get_furniture_service().can_place_free_world(world_pos, size, rotation_index, Vector2.ZERO, Vector2.ZERO, -1, allowed_overlap_node_ids)
	if not valid_target:
		App.get_furniture_service().restore_snapshot(old_snapshot, target_container)
		return false

	if scene_path == "":
		App.get_furniture_service().restore_snapshot(old_snapshot, target_container)
		return false

	var placed: bool = bool(App.get_furniture_service().place_furniture_at(
		tile,
		world_pos,
		rotation_index,
		scene_path,
		size,
		target_container,
		use_grid,
		floor_index,
		item_id,
		attachment_slots,
		attached_to_node_id,
		attached_slot_id
	))
	if placed:
		return true

	App.get_furniture_service().restore_snapshot(old_snapshot, target_container)
	return false

# -------------------------------------------------------
# Position logic
# -------------------------------------------------------

func _get_snapped_world_pos() -> Vector3:
	var tile : Vector2i = mouse_raycast.get_tile_under_mouse()
	return App.get_furniture_service().get_snapped_world_position(tile, current_size, _rotation_index)

func _get_free_world_pos() -> Vector3:
	return mouse_raycast.get_world_position_under_mouse()

func _current_world_pos() -> Vector3:
	if _free_mode:
		return _get_free_world_pos()
	return _get_snapped_world_pos()

# -------------------------------------------------------
# Preview management
# -------------------------------------------------------

func _spawn_preview() -> void:
	_destroy_preview()
	if current_scene_path == "":
		return
	var scene: PackedScene = load(current_scene_path)
	if scene == null:
		return
	_preview_instance = scene.instantiate()
	# Disable any collision on the preview so it does not interfere
	for child in _preview_instance.get_children():
		if child is CollisionObject3D:
			child.collision_layer = 0
			child.collision_mask = 0
	add_child(_preview_instance)
	_apply_preview_tint(_preview_instance, true)

func _destroy_preview() -> void:
	if is_instance_valid(_preview_instance):
		_preview_instance.queue_free()
	_preview_instance = null

func _update_preview_position(ignored_node_id: int = -1) -> void:
	if not is_instance_valid(_preview_instance):
		_spawn_preview()
		return

	var raw_tile : Vector2i = mouse_raycast.get_tile_under_mouse()
	var raw_world := _current_world_pos()
	var use_grid_requested := not _free_mode
	var candidate := _resolve_placement_candidate(raw_tile, raw_world, _rotation_index, use_grid_requested, ignored_node_id)
	_preview_instance.global_position = candidate.get("world_pos", raw_world)
	_preview_instance.rotation_degrees.y = int(candidate.get("rotation_index", _rotation_index)) * 90.0
	_preview_valid = _is_candidate_valid(candidate, ignored_node_id)

	_apply_preview_tint(_preview_instance, _preview_valid)

func _resolve_placement_candidate(raw_tile: Vector2i, raw_world_pos: Vector3, rotation_index: int, use_grid_requested: bool, ignored_node_id: int = -1) -> Dictionary:
	var candidate := {
		"tile": raw_tile,
		"world_pos": raw_world_pos,
		"rotation_index": rotation_index,
		"use_grid": use_grid_requested,
		"attached_to_node_id": -1,
		"attached_slot_id": "",
		"allow_overlap_node_ids": [],
	}

	if current_item_id == "":
		return candidate

	var floor_index := int(App.get_floor_service().current_floor)
	var attachment : Variant = App.get_furniture_service().resolve_attachment_target(current_item_id, raw_world_pos, floor_index, ignored_node_id)
	if attachment.is_empty():
		return candidate

	var host_node_id := int(attachment.get("host_node_id", -1))
	candidate["world_pos"] = attachment.get("world_pos", raw_world_pos)
	candidate["tile"] = App.get_grid_service().world_to_tile(candidate["world_pos"])
	candidate["rotation_index"] = int(attachment.get("rotation_index", rotation_index))
	candidate["use_grid"] = false
	candidate["attached_to_node_id"] = host_node_id
	candidate["attached_slot_id"] = str(attachment.get("slot_id", ""))
	if host_node_id >= 0:
		candidate["allow_overlap_node_ids"] = [host_node_id]

	return candidate

func _is_candidate_valid(candidate: Dictionary, ignored_node_id: int = -1) -> bool:
	var use_grid := bool(candidate.get("use_grid", true))
	var rotation_index := int(candidate.get("rotation_index", _rotation_index))
	if use_grid:
		var tile: Vector2i = candidate.get("tile", Vector2i.ZERO)
		return App.get_furniture_service().can_place(tile, current_size, rotation_index, ignored_node_id)

	var world_pos: Vector3 = candidate.get("world_pos", Vector3.ZERO)
	var allow_overlap_node_ids : Variant = candidate.get("allow_overlap_node_ids", [])
	if not (allow_overlap_node_ids is Array):
		allow_overlap_node_ids = []
	var profile := _get_preview_collision_profile_xz()
	return App.get_furniture_service().can_place_free_world(
		world_pos,
		current_size,
		rotation_index,
		profile.get("half_extents", Vector2.ZERO),
		profile.get("center_offset", Vector2.ZERO),
		ignored_node_id,
		allow_overlap_node_ids
	)

# -------------------------------------------------------
# Placement
# -------------------------------------------------------

func _place_furniture() -> void:
	if _free_mode:
		_place_free()
	else:
		_place_snapped()

func _place_snapped() -> void:
	var target_container := _resolve_furniture_container()
	if target_container == null:
		push_error("FurniturePlacer: no valid furniture container.")
		return

	var raw_tile : Vector2i = mouse_raycast.get_tile_under_mouse()
	var raw_world : Vector3 = App.get_furniture_service().get_snapped_world_position(raw_tile, current_size, _rotation_index)
	var candidate := _resolve_placement_candidate(raw_tile, raw_world, _rotation_index, true)
	if not _is_candidate_valid(candidate):
		return

	var tile: Vector2i = candidate.get("tile", raw_tile)
	var world_pos: Vector3 = candidate.get("world_pos", raw_world)
	var rot := int(candidate.get("rotation_index", _rotation_index))
	var use_grid := bool(candidate.get("use_grid", true))
	var attached_to_node_id := int(candidate.get("attached_to_node_id", -1))
	var attached_slot_id := str(candidate.get("attached_slot_id", ""))
	var path := current_scene_path
	var size := current_size
	var item_id := current_item_id
	var attachment_slots := current_attachment_slots.duplicate(true)
	var floor_index : int = int(App.get_floor_service().current_floor)
	var snapshot_for_remove := {
		"tile": tile,
		"floor_index": floor_index,
		"uses_grid_occupancy": use_grid,
		"world_pos": world_pos,
	}

	App.execute_build_command(
		"place furniture",
		func():
			return App.get_furniture_service().place_furniture_at(tile, world_pos, rot, path, size, target_container, use_grid, floor_index, item_id, attachment_slots, attached_to_node_id, attached_slot_id),
		func():
			return App.get_furniture_service().remove_matching_snapshot(snapshot_for_remove)
	)

func _place_free() -> void:
	var target_container := _resolve_furniture_container()
	if target_container == null:
		push_error("FurniturePlacer: no valid furniture container.")
		return

	var raw_world := _preview_instance.global_position
	var raw_tile : Vector2i = App.get_grid_service().world_to_tile(raw_world)
	var candidate := _resolve_placement_candidate(raw_tile, raw_world, _rotation_index, false)
	if not _is_candidate_valid(candidate):
		return

	var path := current_scene_path
	var world_pos: Vector3 = candidate.get("world_pos", raw_world)
	var rot := int(candidate.get("rotation_index", _rotation_index))
	var tile : Vector2i = candidate.get("tile", raw_tile)
	var use_grid := bool(candidate.get("use_grid", false))
	var attached_to_node_id := int(candidate.get("attached_to_node_id", -1))
	var attached_slot_id := str(candidate.get("attached_slot_id", ""))
	var item_id := current_item_id
	var attachment_slots := current_attachment_slots.duplicate(true)
	var floor_index : int = int(App.get_floor_service().current_floor)
	var snapshot_for_remove := {
		"tile": tile,
		"floor_index": floor_index,
		"uses_grid_occupancy": use_grid,
		"world_pos": world_pos,
	}

	App.execute_build_command(
		"place furniture (free)",
		func():
			return App.get_furniture_service().place_furniture_at(tile, world_pos, rot, path, current_size, target_container, use_grid, floor_index, item_id, attachment_slots, attached_to_node_id, attached_slot_id),
		func():
			return App.get_furniture_service().remove_matching_snapshot(snapshot_for_remove)
	)

func _delete_furniture_under_cursor() -> void:
	var target_container := _resolve_furniture_container()
	if target_container == null:
		push_error("FurniturePlacer: no valid furniture container.")
		return

	var floor_index : int = int(App.get_floor_service().current_floor)
	var world_pos: Vector3 = mouse_raycast.get_world_position_under_mouse()
	var snapshot: Dictionary = App.get_furniture_service().get_snapshot_at_world(world_pos, floor_index)
	if snapshot.is_empty():
		return

	if int(_selected_snapshot.get("node_id", -1)) == int(snapshot.get("node_id", -2)):
		_clear_selected_snapshot()

	App.execute_build_command(
		"delete furniture",
		func():
			return App.get_furniture_service().remove_matching_snapshot(snapshot),
		func():
			return App.get_furniture_service().restore_snapshot(snapshot, target_container)
	)

# -------------------------------------------------------
# Free-placement collision check using ShapeCast3D
# -------------------------------------------------------

var _shape_cast: ShapeCast3D = null

func _check_free_placement_valid(world_pos: Vector3) -> bool:
	var profile := _get_preview_collision_profile_xz()
	return App.get_furniture_service().can_place_free_world(
		world_pos,
		current_size,
		_rotation_index,
		profile.get("half_extents", Vector2.ZERO),
		profile.get("center_offset", Vector2.ZERO)
	)

func _get_preview_collision_profile_xz() -> Dictionary:
	var profile := {
		"half_extents": Vector2.ZERO,
		"center_offset": Vector2.ZERO,
	}
	if not is_instance_valid(_preview_instance):
		return profile

	var bounds := _compute_mesh_bounds_xz(_preview_instance)
	if not bounds["valid"]:
		return profile

	var min_v: Vector2 = bounds["min"]
	var max_v: Vector2 = bounds["max"]
	var size := max_v - min_v
	var half := Vector2(maxf(size.x * 0.5 * PREVIEW_COLLISION_TIGHTEN_FACTOR, 0.01), maxf(size.y * 0.5 * PREVIEW_COLLISION_TIGHTEN_FACTOR, 0.01))
	half.x = maxf(0.01, half.x - free_collision_padding)
	half.y = maxf(0.01, half.y - free_collision_padding)
	var center := (min_v + max_v) * 0.5
	var node_center := Vector2(_preview_instance.global_position.x, _preview_instance.global_position.z)
	profile["half_extents"] = half
	profile["center_offset"] = center - node_center
	return profile

func _get_preview_half_extents_xz() -> Vector2:
	if not is_instance_valid(_preview_instance):
		return Vector2.ZERO

	var bounds := _compute_mesh_bounds_xz(_preview_instance)
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

func _setup_shape_cast() -> void:
	_shape_cast = ShapeCast3D.new()
	var shape := BoxShape3D.new()
	# Approximate size — adjust to match your furniture's average footprint
	shape.size = Vector3(
		current_size.x * App.get_grid_service().TILE_SIZE * 0.9,
		1.8,
		current_size.y * App.get_grid_service().TILE_SIZE * 0.9
	)
	_shape_cast.shape = shape
	_shape_cast.collision_mask = 2   # layer 2 = furniture (set this in project settings)
	_shape_cast.target_position = Vector3.ZERO   # point cast, no sweep
	_shape_cast.enabled = true
	add_child(_shape_cast)

# -------------------------------------------------------
# Preview tinting
# -------------------------------------------------------

func _apply_preview_tint(node: Node3D, valid: bool) -> void:
	var color := Color(0.3, 0.9, 0.3, 0.55) if valid else Color(0.9, 0.2, 0.2, 0.55)
	_tint_recursive(node, color)

func _tint_recursive(node: Node3D, color: Color) -> void:
	if node is MeshInstance3D:
		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = color
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		node.material_override = mat
	for child in node.get_children():
		if child is Node3D:
			_tint_recursive(child, color)
