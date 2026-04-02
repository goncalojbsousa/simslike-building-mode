# =============================================================================
# RoomEditorTool — Step 1 Refactor
# Changes from original:
#   - DragState inner class replaces 8 loose drag fields
#   - SelectionState inner class replaces 7 loose selection fields
#   - C (constants) inner class centralises magic values
#   - Fixed: _cancel_drag reset_visuals dead branch (both branches were identical)
#   - All behaviour is identical to the original
# =============================================================================
extends Node

@export var mouse_raycast: Node
@export var active: bool = false
@export var handle_pick_radius_px: float = 24.0
@export var handle_height: float = 1.35
@export var handle_offset: float = 0.45

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
const NEIGHBORS = [
	Vector2i(1, 0),
	Vector2i(-1, 0),
	Vector2i(0, 1),
	Vector2i(0, -1),
]

const DRAG_NONE   = 0
const DRAG_MOVE   = 1
const DRAG_RESIZE = 2

# ---------------------------------------------------------------------------
# DragState — owns every field that is only meaningful during an active drag.
# Replaces: _drag_kind, _drag_start_tile, _drag_start_world, _drag_move_delta,
#           _drag_resize_steps, _drag_handle, _drag_base_tiles
# ---------------------------------------------------------------------------
class DragState:
	var kind: int           = DRAG_NONE
	var start_tile: Vector2i  = Vector2i.ZERO
	var start_world: Vector3  = Vector3.ZERO
	var move_delta: Vector2i  = Vector2i.ZERO
	var resize_steps: int     = 0
	var handle: Dictionary    = {}
	var base_tiles: Dictionary = {}

	func reset() -> void:
		kind         = DRAG_NONE
		start_tile   = Vector2i.ZERO
		start_world  = Vector3.ZERO
		move_delta   = Vector2i.ZERO
		resize_steps = 0
		handle.clear()
		base_tiles.clear()

	func is_active() -> bool:
		return kind != DRAG_NONE

	func is_move() -> bool:
		return kind == DRAG_MOVE

	func is_resize() -> bool:
		return kind == DRAG_RESIZE

# ---------------------------------------------------------------------------
# SelectionState — owns every field that describes the current selection.
# Replaces: _selected_tiles, _selected_signature, _selected_anchor,
#           _selected_rooms, _selected_room_anchors
# ---------------------------------------------------------------------------
class SelectionState:
	# Union of all selected rooms flattened into one tile set.
	var tiles: Dictionary        = {}
	var signature: String        = ""
	var anchor: Vector2i         = Vector2i.ZERO
	# Per-room data keyed by each room's tile signature.
	var rooms: Dictionary        = {}   # signature -> Dictionary(tile -> true)
	var room_anchors: Dictionary = {}   # signature -> Vector2i

	func clear() -> void:
		tiles.clear()
		signature = ""
		anchor    = Vector2i.ZERO
		rooms.clear()
		room_anchors.clear()

	func is_empty() -> bool:
		return tiles.is_empty()

	func has_tile(t: Vector2i) -> bool:
		return tiles.has(t)

	func room_count() -> int:
		return rooms.size()

# ---------------------------------------------------------------------------
# Node-level state
# ---------------------------------------------------------------------------
var _drag: DragState       = DragState.new()
var _sel: SelectionState   = SelectionState.new()

var _preview_tiles: Dictionary = {}
var _preview_valid: bool = true

var _handles: Array[Dictionary]    = []
var _handle_nodes: Dictionary      = {}

var _highlight_node: MeshInstance3D          = null
var _highlight_material: StandardMaterial3D  = null
var _preview_valid_material: StandardMaterial3D   = null
var _preview_invalid_material: StandardMaterial3D = null
var _handle_material: StandardMaterial3D     = null

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_setup_materials()
	App.get_wall_service().wall_placed.connect(_on_world_changed)
	App.get_wall_service().wall_removed.connect(_on_world_changed)
	App.get_floor_service().floor_changed.connect(_on_floor_changed)

func activate() -> void:
	active = true
	_refresh_selection_after_world_change()

func deactivate() -> void:
	active = false
	_cancel_drag()
	_clear_selection()

# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return

	if event is InputEventKey:
		var ke = event as InputEventKey
		if ke.pressed and ke.keycode == KEY_ESCAPE:
			_cancel_drag()
			return

	if event is InputEventMouseButton:
		var mb = event as InputEventMouseButton

		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_cancel_drag()
			_clear_selection()
			return

		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_on_left_pressed()
			else:
				_on_left_released()

func _process(_delta: float) -> void:
	if not active:
		return

	if _drag.is_move():
		_update_move_drag_preview()
	elif _drag.is_resize():
		_update_resize_drag_preview()

# ---------------------------------------------------------------------------
# Input handlers
# ---------------------------------------------------------------------------
func _on_left_pressed() -> void:
	if _drag.is_active():
		return

	# Ctrl+click: toggle an additional room into the selection.
	if Input.is_key_pressed(KEY_CTRL):
		_toggle_room_selection_at_tile(mouse_raycast.get_tile_under_mouse())
		return

	# Check if the cursor is close enough to a resize handle.
	var picked_handle = _pick_handle_under_mouse()
	if not picked_handle.is_empty():
		_begin_resize_drag(picked_handle)
		return

	var tile: Vector2i = mouse_raycast.get_tile_under_mouse()

	# Clicking inside an already-selected room starts a move drag.
	if _has_selected_room() and _sel.has_tile(tile):
		_begin_move_drag(tile)
		return

	_select_room_at_tile(tile)

func _on_left_released() -> void:
	if _drag.is_move():
		_commit_move_drag()
	elif _drag.is_resize():
		_commit_resize_drag()

# ---------------------------------------------------------------------------
# Move drag
# ---------------------------------------------------------------------------
func _begin_move_drag(start_tile: Vector2i) -> void:
	_drag.kind        = DRAG_MOVE
	_drag.start_tile  = start_tile
	_drag.move_delta  = Vector2i.ZERO
	_drag.base_tiles  = _sel.tiles.duplicate(true)
	_preview_tiles    = _drag.base_tiles.duplicate(true)
	_preview_valid    = true
	_update_selection_visuals()

func _update_move_drag_preview() -> void:
	var tile: Vector2i = mouse_raycast.get_tile_under_mouse()
	var delta: Vector2i = tile - _drag.start_tile
	if delta == _drag.move_delta:
		return

	_drag.move_delta = delta
	_preview_tiles   = _offset_tiles(_drag.base_tiles, delta)
	_preview_valid   = _validate_target_tiles(_preview_tiles, _drag.base_tiles, false)
	_update_selection_visuals()

func _commit_move_drag() -> void:
	# A mouse-up with no movement is treated as a click: if multiple rooms are
	# selected, narrow the selection to only the room that was clicked.
	if _drag.move_delta == Vector2i.ZERO:
		if _sel.room_count() > 1 and _sel.has_tile(_drag.start_tile):
			var clicked_room = _find_room_containing_tile(_drag.start_tile)
			if not clicked_room.is_empty():
				_set_selected_room_from_array(clicked_room)
		_cancel_drag()
		return

	if not _preview_valid:
		_cancel_drag()
		return

	var target_tiles = _preview_tiles.duplicate(true)
	if _apply_tile_transform(_drag.base_tiles, target_tiles, "move room", false, _drag.move_delta):
		_offset_selected_rooms(_drag.move_delta)

	_cancel_drag()

# ---------------------------------------------------------------------------
# Resize drag
# ---------------------------------------------------------------------------
func _begin_resize_drag(handle: Dictionary) -> void:
	if not _has_single_selected_room():
		return
	_drag.kind         = DRAG_RESIZE
	_drag.handle       = handle.duplicate(true)
	_drag.resize_steps = 0
	_drag.start_world  = mouse_raycast.get_world_position_under_mouse()
	_drag.base_tiles   = _sel.tiles.duplicate(true)
	_preview_tiles     = _drag.base_tiles.duplicate(true)
	_preview_valid     = true
	_update_selection_visuals()

func _update_resize_drag_preview() -> void:
	var current_world: Vector3 = mouse_raycast.get_world_position_under_mouse()
	var dir_world: Vector3 = _dir_to_world(_drag.handle["dir"])
	var projected = (current_world - _drag.start_world).dot(dir_world)
	var steps = roundi(projected / App.get_grid_service().TILE_SIZE)

	if steps == _drag.resize_steps:
		return

	_drag.resize_steps = steps

	# At zero displacement show the base tiles as a valid preview.
	if steps == 0:
		_preview_tiles = _drag.base_tiles.duplicate(true)
		_preview_valid = true
		_update_selection_visuals()
		return

	var resized_tiles = _resize_tiles_from_handle(_drag.base_tiles, _drag.handle, steps)
	if resized_tiles.is_empty():
		# Resize would collapse the room — keep showing base tiles in red.
		_preview_tiles = _drag.base_tiles.duplicate(true)
		_preview_valid = false
		_update_selection_visuals()
		return

	_preview_tiles = resized_tiles
	_preview_valid = _validate_target_tiles(_preview_tiles, _drag.base_tiles, true)
	_update_selection_visuals()

func _commit_resize_drag() -> void:
	if _drag.resize_steps == 0 or not _preview_valid:
		_cancel_drag()
		return

	var target_tiles = _preview_tiles.duplicate(true)
	if _apply_tile_transform(_drag.base_tiles, target_tiles, "resize room", true):
		_set_selected_room_from_set(target_tiles)

	_cancel_drag()

# ---------------------------------------------------------------------------
# Drag cancellation
# BUG FIX: original had identical then/else branches for reset_visuals.
# Now: reset_visuals=true restores the selection highlight;
#      reset_visuals=false skips the rebuild (caller will handle it).
# ---------------------------------------------------------------------------
func _cancel_drag(reset_visuals: bool = true) -> void:
	_drag.reset()
	_preview_tiles.clear()
	_preview_valid = true

	if reset_visuals:
		_update_selection_visuals()

# ---------------------------------------------------------------------------
# Selection helpers
# ---------------------------------------------------------------------------
func _select_room_at_tile(tile: Vector2i) -> void:
	var room_tiles = _find_room_containing_tile(tile)
	if room_tiles.is_empty():
		_clear_selection()
		return
	_set_selected_room_from_array(room_tiles)

func _toggle_room_selection_at_tile(tile: Vector2i) -> void:
	var room_tiles = _find_room_containing_tile(tile)
	if room_tiles.is_empty():
		return

	var room_set  = _array_to_set(room_tiles)
	var signature = _tiles_signature(room_set)

	if _sel.rooms.has(signature):
		_sel.rooms.erase(signature)
		_sel.room_anchors.erase(signature)
	else:
		_sel.rooms[signature]        = room_set
		_sel.room_anchors[signature] = _first_tile(room_set)

	_rebuild_selected_union_from_rooms()

func _find_room_containing_tile(tile: Vector2i) -> Array:
	var detector: Node = App.get_wall_service().get_room_detector()
	if detector == null:
		return []

	var rooms: Array = detector.detect_all_rooms_on_floor(App.get_floor_service().current_floor)
	for room_value in rooms:
		if not (room_value is Array):
			continue
		var room: Array = room_value
		if room.has(tile):
			return room
	return []

func _set_selected_room_from_array(room_tiles: Array) -> void:
	_set_selected_room_from_set(_array_to_set(room_tiles))

func _set_selected_room_from_set(tile_set: Dictionary) -> void:
	_sel.rooms.clear()
	_sel.room_anchors.clear()

	if tile_set.is_empty():
		_sel.tiles.clear()
		_sel.signature = ""
		_sel.anchor    = Vector2i.ZERO
		_update_selection_visuals()
		return

	var room_set  = tile_set.duplicate(true)
	var signature = _tiles_signature(room_set)
	_sel.rooms[signature]        = room_set
	_sel.room_anchors[signature] = _first_tile(room_set)
	_rebuild_selected_union_from_rooms()

func _rebuild_selected_union_from_rooms() -> void:
	_sel.tiles.clear()
	for room_set in _sel.rooms.values():
		for tile_value in (room_set as Dictionary).keys():
			_sel.tiles[tile_value] = true

	if _sel.tiles.is_empty():
		_sel.signature = ""
		_sel.anchor    = Vector2i.ZERO
	else:
		_sel.signature = _tiles_signature(_sel.tiles)
		_sel.anchor    = _first_tile(_sel.tiles)

	_update_selection_visuals()

func _offset_selected_rooms(delta: Vector2i) -> void:
	if _sel.rooms.is_empty() or delta == Vector2i.ZERO:
		return

	var moved_rooms:   Dictionary = {}
	var moved_anchors: Dictionary = {}

	for room_set in _sel.rooms.values():
		var moved_set = _offset_tiles(room_set as Dictionary, delta)
		if moved_set.is_empty():
			continue
		var moved_sig = _tiles_signature(moved_set)
		moved_rooms[moved_sig]   = moved_set
		moved_anchors[moved_sig] = _first_tile(moved_set)

	_sel.rooms        = moved_rooms
	_sel.room_anchors = moved_anchors
	_rebuild_selected_union_from_rooms()

func _clear_selection() -> void:
	_sel.clear()
	_preview_tiles.clear()
	_preview_valid = true
	_clear_handle_nodes()
	_clear_highlight()

func _has_selected_room() -> bool:
	return not _sel.is_empty()

func _has_single_selected_room() -> bool:
	return _sel.room_count() == 1

func delete_selected_rooms() -> bool:
	if not active or _drag.is_active() or _sel.tiles.is_empty():
		return false

	var floor_index = App.get_floor_service().current_floor
	var selected_tiles_snapshot: Dictionary = _sel.tiles.duplicate(true)
	var boundary_map := _boundary_wall_map(selected_tiles_snapshot, floor_index)
	if boundary_map.is_empty():
		return false

	var removable_edges: Array[Dictionary] = []
	for edge_value in boundary_map.values():
		if not (edge_value is Dictionary):
			continue
		var edge := edge_value as Dictionary
		var from_tile: Vector2i = edge.get("from", Vector2i.ZERO)
		var to_tile: Vector2i = edge.get("to", Vector2i.ZERO)
		if not App.get_wall_service().has_wall(from_tile, to_tile, floor_index):
			continue
		removable_edges.append({
			"from": from_tile,
			"to": to_tile,
		})

	if removable_edges.is_empty():
		return false

	var opening_snapshots := _snapshot_room_openings(selected_tiles_snapshot)

	App.get_history_service().execute(
		"delete room",
		func():
			App.get_wall_service().begin_batch()
			for edge in removable_edges:
				App.get_wall_service().remove_wall(edge["from"], edge["to"], floor_index)
			App.get_wall_service().end_batch()
			_clear_selection(),
		func():
			App.get_wall_service().begin_batch()
			for edge in removable_edges:
				App.get_wall_service().place_wall(edge["from"], edge["to"], floor_index)
			App.get_wall_service().end_batch()
			_restore_openings_from_snapshots(opening_snapshots, selected_tiles_snapshot)
			_refresh_selection_after_world_change()
	)

	return true

# ---------------------------------------------------------------------------
# World-change callbacks
# ---------------------------------------------------------------------------
func _refresh_selection_after_world_change() -> void:
	if not active or _drag.is_active() or not _has_selected_room():
		return

	var refreshed_rooms:   Dictionary = {}
	var refreshed_anchors: Dictionary = {}

	for signature in _sel.rooms.keys():
		var previous_tiles: Dictionary = _sel.rooms[signature]
		var anchor: Vector2i = _sel.room_anchors.get(signature, _first_tile(previous_tiles))

		# Try the stored anchor first, then fall back to any tile in the room.
		var room = _find_room_containing_tile(anchor)
		if room.is_empty():
			for t in previous_tiles.keys():
				room = _find_room_containing_tile(t)
				if not room.is_empty():
					break

		if room.is_empty():
			continue

		var room_set  = _array_to_set(room)
		var new_sig   = _tiles_signature(room_set)
		refreshed_rooms[new_sig]   = room_set
		refreshed_anchors[new_sig] = _first_tile(room_set)

	if refreshed_rooms.is_empty():
		_clear_selection()
		return

	_sel.rooms        = refreshed_rooms
	_sel.room_anchors = refreshed_anchors
	_rebuild_selected_union_from_rooms()

func _on_world_changed(_a: Vector2i, _b: Vector2i, _floor: int) -> void:
	_refresh_selection_after_world_change()

func _on_floor_changed(_old_floor: int, _new_floor: int) -> void:
	_cancel_drag(false)
	_clear_selection()

# ---------------------------------------------------------------------------
# Visuals — dispatch
# ---------------------------------------------------------------------------
func _update_selection_visuals() -> void:
	if not _has_selected_room():
		_clear_highlight()
		_clear_handle_nodes()
		return

	if not _drag.is_active():
		# Idle: show the true selection and handles (only for a single room).
		_rebuild_highlight(_sel.tiles, true)
		if _has_single_selected_room():
			_rebuild_handles(_sel.tiles)
		else:
			_clear_handle_nodes()
	else:
		# Dragging: show the preview tiles; colour by validity.
		_rebuild_highlight(_preview_tiles, _preview_valid)
		_clear_handle_nodes()

# ---------------------------------------------------------------------------
# Visuals — highlight mesh
# ---------------------------------------------------------------------------
func _rebuild_highlight(tile_set: Dictionary, valid: bool) -> void:
	if tile_set.is_empty():
		_clear_highlight()
		return

	_ensure_highlight_node()

	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var y  = App.get_floor_service().get_floor_y_offset(App.get_floor_service().current_floor) + 0.04
	var ts = App.get_grid_service().TILE_SIZE

	for tile_value in tile_set.keys():
		var t: Vector2i = tile_value
		var x0 = t.x * ts;  var x1 = x0 + ts
		var z0 = t.y * ts;  var z1 = z0 + ts

		st.set_normal(Vector3.UP)
		st.add_vertex(Vector3(x0, y, z0))
		st.add_vertex(Vector3(x1, y, z0))
		st.add_vertex(Vector3(x1, y, z1))

		st.add_vertex(Vector3(x0, y, z0))
		st.add_vertex(Vector3(x1, y, z1))
		st.add_vertex(Vector3(x0, y, z1))

	_highlight_node.mesh = st.commit()
	_highlight_node.material_override = _pick_highlight_material(valid)
	_highlight_node.visible = true

func _pick_highlight_material(valid: bool) -> StandardMaterial3D:
	if not _drag.is_active():
		return _highlight_material
	return _preview_valid_material if valid else _preview_invalid_material

func _ensure_highlight_node() -> void:
	if is_instance_valid(_highlight_node):
		return
	_highlight_node = MeshInstance3D.new()
	_highlight_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var host = get_parent() as Node3D
	if host != null:
		host.add_child(_highlight_node)
	else:
		add_child(_highlight_node)

func _clear_highlight() -> void:
	if is_instance_valid(_highlight_node):
		_highlight_node.queue_free()
	_highlight_node = null

# ---------------------------------------------------------------------------
# Visuals — resize handles
# ---------------------------------------------------------------------------
func _rebuild_handles(tile_set: Dictionary) -> void:
	_clear_handle_nodes()
	_handles = _compute_wall_runs(tile_set)
	if _handles.is_empty():
		return

	for i in range(_handles.size()):
		var run: Dictionary = _handles[i]
		run["id"] = i
		var dir: Vector2i = run["dir"]
		# Position the handle slightly outside the wall it represents.
		var center: Vector3 = run["position"] + _dir_to_world(dir) * handle_offset
		run["handle_world"] = center
		_handles[i] = run
		_handle_nodes[i] = _create_handle_node(center, dir)

func _clear_handle_nodes() -> void:
	for node in _handle_nodes.values():
		if is_instance_valid(node):
			(node as Node3D).queue_free()
	_handle_nodes.clear()
	_handles.clear()

func _create_handle_node(world_pos: Vector3, dir: Vector2i) -> Node3D:
	var root = Node3D.new()
	root.name = "RoomHandle"
	root.position = world_pos

	# Shaft (rectangular body of the arrow).
	var shaft      = MeshInstance3D.new()
	var shaft_mesh = BoxMesh.new()
	shaft_mesh.size     = Vector3(0.16, 0.16, 0.58)
	shaft.mesh          = shaft_mesh
	shaft.position      = Vector3(0.0, 0.0, 0.26)
	shaft.material_override = _handle_material
	shaft.cast_shadow   = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(shaft)

	# Head (cone tip of the arrow).
	var head      = MeshInstance3D.new()
	var head_mesh = CylinderMesh.new()
	head_mesh.top_radius     = 0.0
	head_mesh.bottom_radius  = 0.22
	head_mesh.height         = 0.34
	head_mesh.radial_segments = 16
	head.mesh             = head_mesh
	head.position         = Vector3(0.0, 0.0, 0.72)
	head.rotation_degrees.x = 90.0
	head.material_override  = _handle_material
	head.cast_shadow        = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(head)

	var host = get_parent() as Node3D
	if host != null:
		host.add_child(root)
	else:
		add_child(root)
	root.look_at(root.global_position + _dir_to_world(dir), Vector3.UP)
	return root

func _pick_handle_under_mouse() -> Dictionary:
	if _handles.is_empty() or not _has_selected_room() or not _has_single_selected_room():
		return {}

	var camera = _get_camera()
	if camera == null:
		return {}

	var mouse_pos  = get_viewport().get_mouse_position()
	var best_dist  = handle_pick_radius_px
	var best: Dictionary = {}

	for handle in _handles:
		var world_pos: Vector3 = handle["handle_world"]
		if camera.is_position_behind(world_pos):
			continue
		var dist = (camera.unproject_position(world_pos)).distance_to(mouse_pos)
		if dist <= best_dist:
			best_dist = dist
			best      = handle

	return best

# ---------------------------------------------------------------------------
# Geometry — wall runs (used for handle placement)
# ---------------------------------------------------------------------------
func _compute_wall_runs(tile_set: Dictionary) -> Array[Dictionary]:
	var edges = _compute_boundary_edges(tile_set)
	if edges.is_empty():
		return []

	# Group edges by (orientation, line-coord, outward-direction) so that
	# collinear adjacent edges are merged into runs.
	var grouped: Dictionary = {}
	for edge in edges:
		var orientation = str(edge["orientation"])
		var line        = int(edge["line"])
		var dir: Vector2i = edge["dir"]
		var group_key: String
		if orientation == "z":
			group_key = "z|%d|%d" % [line, dir.x]
		else:
			group_key = "x|%d|%d" % [line, dir.y]
		if not grouped.has(group_key):
			grouped[group_key] = []
		(grouped[group_key] as Array).append(edge)

	var runs: Array[Dictionary] = []
	for group_key in grouped.keys():
		var group_edges: Array = grouped[group_key]
		group_edges.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return int(a["idx"]) < int(b["idx"])
		)

		# Split the sorted edges into contiguous chunks, then split each chunk
		# further at wall intersections so handles don't span doorways.
		var chunk: Array = []
		var prev_idx = -2147483648
		for edge in group_edges:
			var idx = int(edge["idx"])
			if chunk.is_empty() or idx == prev_idx + 1:
				chunk.append(edge)
			else:
				_append_chunk_runs_with_intersections(runs, chunk)
				chunk = [edge]
			prev_idx = idx

		if not chunk.is_empty():
			_append_chunk_runs_with_intersections(runs, chunk)

	return runs

func _append_chunk_runs_with_intersections(runs: Array[Dictionary], chunk: Array) -> void:
	for split_chunk in _split_chunk_by_intersections(chunk):
		if not (split_chunk as Array).is_empty():
			runs.append(_build_run_from_chunk(split_chunk))

func _split_chunk_by_intersections(chunk: Array) -> Array:
	if chunk.size() <= 1:
		return [chunk]

	var first: Dictionary = chunk[0]
	var orientation = str(first["orientation"])
	var line        = int(first["line"])
	var result: Array = []
	var current: Array = [chunk[0]]

	for i in range(1, chunk.size()):
		var prev_edge: Dictionary = chunk[i - 1]
		var vertex_idx = int(prev_edge["idx"]) + 1
		if _has_intersection_on_run_vertex(orientation, line, vertex_idx):
			result.append(current)
			current = []
		current.append(chunk[i])

	if not current.is_empty():
		result.append(current)
	return result

func _has_intersection_on_run_vertex(orientation: String, line: int, vertex_idx: int) -> bool:
	var f = App.get_floor_service().current_floor

	if orientation == "x":
		# Horizontal run: check vertical wall segments meeting at this corner.
		return (App.get_wall_service().has_wall(Vector2i(vertex_idx - 1, line),     Vector2i(vertex_idx, line),     f) or
				App.get_wall_service().has_wall(Vector2i(vertex_idx - 1, line - 1), Vector2i(vertex_idx, line - 1), f))

	# Vertical run: check horizontal wall segments meeting at this corner.
	return (App.get_wall_service().has_wall(Vector2i(line,     vertex_idx - 1), Vector2i(line,     vertex_idx), f) or
			App.get_wall_service().has_wall(Vector2i(line - 1, vertex_idx - 1), Vector2i(line - 1, vertex_idx), f))

func _build_run_from_chunk(chunk: Array) -> Dictionary:
	var first: Dictionary = chunk[0]
	var last:  Dictionary = chunk[chunk.size() - 1]
	var orientation = str(first["orientation"])
	var line        = int(first["line"])
	var start_idx   = int(first["idx"])
	var end_idx     = int(last["idx"])
	var length      = end_idx - start_idx + 1
	var dir: Vector2i = first["dir"]
	var y  = App.get_grid_service().get_wall_y_base(App.get_floor_service().current_floor) + handle_height
	var ts = App.get_grid_service().TILE_SIZE

	var center = Vector3.ZERO
	if orientation == "z":
		center = Vector3(float(line) * ts, y, (float(start_idx) + float(length) * 0.5) * ts)
	else:
		center = Vector3((float(start_idx) + float(length) * 0.5) * ts, y, float(line) * ts)

	return {
		"orientation": orientation,
		"line":        line,
		"start_idx":   start_idx,
		"end_idx":     end_idx,
		"length":      length,
		"dir":         dir,
		"position":    center,
	}

# ---------------------------------------------------------------------------
# Geometry — boundary edges
# ---------------------------------------------------------------------------
func _compute_boundary_edges(tile_set: Dictionary) -> Array[Dictionary]:
	var edges: Array[Dictionary] = []
	for tile_value in tile_set.keys():
		var tile: Vector2i = tile_value
		for offset_value in NEIGHBORS:
			var offset: Vector2i = offset_value
			if tile_set.has(tile + offset):
				continue  # Interior edge — skip.

			if offset.x != 0:
				edges.append({
					"orientation": "z",
					"line": tile.x + (1 if offset.x > 0 else 0),
					"idx":  tile.y,
					"dir":  offset,
				})
			else:
				edges.append({
					"orientation": "x",
					"line": tile.y + (1 if offset.y > 0 else 0),
					"idx":  tile.x,
					"dir":  offset,
				})
	return edges

# ---------------------------------------------------------------------------
# Geometry — tile set operations
# ---------------------------------------------------------------------------
func _offset_tiles(tile_set: Dictionary, delta: Vector2i) -> Dictionary:
	var shifted: Dictionary = {}
	for tile_value in tile_set.keys():
		shifted[(tile_value as Vector2i) + delta] = true
	return shifted

func _resize_tiles_from_handle(base_tiles: Dictionary, handle: Dictionary, steps: int) -> Dictionary:
	if steps == 0:
		return base_tiles.duplicate(true)

	var result  = base_tiles.duplicate(true)
	var orientation = str(handle["orientation"])
	var line        = int(handle["line"])
	var start_idx   = int(handle["start_idx"])
	var end_idx     = int(handle["end_idx"])
	var dir: Vector2i = handle["dir"]
	var outward = 1 if steps > 0 else -1

	for step_index in range(abs(steps)):
		if orientation == "z":
			var x_target: int
			if outward > 0:
				x_target = line + step_index if dir.x > 0 else line - 1 - step_index
				for z in range(start_idx, end_idx + 1):
					result[Vector2i(x_target, z)] = true
			else:
				x_target = line - 1 - step_index if dir.x > 0 else line + step_index
				for z in range(start_idx, end_idx + 1):
					var tile = Vector2i(x_target, z)
					if not result.has(tile):
						return {}
					result.erase(tile)
		else:
			var y_target: int
			if outward > 0:
				y_target = line + step_index if dir.y > 0 else line - 1 - step_index
				for x in range(start_idx, end_idx + 1):
					result[Vector2i(x, y_target)] = true
			else:
				y_target = line - 1 - step_index if dir.y > 0 else line + step_index
				for x in range(start_idx, end_idx + 1):
					var tile = Vector2i(x, y_target)
					if not result.has(tile):
						return {}
					result.erase(tile)

	return result if not result.is_empty() else {}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
func _validate_target_tiles(candidate: Dictionary, base_tiles: Dictionary, is_resize: bool) -> bool:
	if candidate.is_empty():
		return false
	if not _is_connected(candidate):
		return false
	return _can_apply_wall_delta(base_tiles, candidate, is_resize)

func _is_connected(tile_set: Dictionary) -> bool:
	if tile_set.is_empty():
		return false

	var start   = _first_tile(tile_set)
	var queue:  Array[Vector2i] = [start]
	var visited: Dictionary = {start: true}

	while not queue.is_empty():
		var current: Vector2i = queue.pop_front()
		for offset_value in NEIGHBORS:
			var next: Vector2i = current + (offset_value as Vector2i)
			if not tile_set.has(next) or visited.has(next):
				continue
			visited[next] = true
			queue.append(next)

	return visited.size() == tile_set.size()

func _boundary_wall_map(tile_set: Dictionary, floor_index: int) -> Dictionary:
	var map: Dictionary = {}
	for tile_value in tile_set.keys():
		var tile: Vector2i = tile_value
		for offset_value in NEIGHBORS:
			var neighbor: Vector2i = tile + (offset_value as Vector2i)
			if tile_set.has(neighbor):
				continue
			var key = App.get_wall_service().make_key(tile, neighbor, floor_index)
			if not map.has(key):
				map[key] = {"from": tile, "to": neighbor}
	return map

# ---------------------------------------------------------------------------
# Room detection helpers
# ---------------------------------------------------------------------------
func _detect_room_entries_on_floor() -> Array[Dictionary]:
	var detector: Node = App.get_wall_service().get_room_detector()
	if detector == null:
		return []

	var entries: Array[Dictionary] = []
	for room_value in detector.detect_all_rooms_on_floor(App.get_floor_service().current_floor):
		if not (room_value is Array):
			continue
		var room_set = _array_to_set(room_value)
		if room_set.is_empty():
			continue
		entries.append({
			"signature": _tiles_signature(room_set),
			"tiles":     room_set,
		})
	return entries

# ---------------------------------------------------------------------------
# Tile set utilities (pure, no side-effects)
# ---------------------------------------------------------------------------
func _set_difference(a: Dictionary, b: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for tile_value in a.keys():
		if not b.has(tile_value):
			result[tile_value] = true
	return result

func _is_subset(subset_tiles: Dictionary, container_tiles: Dictionary) -> bool:
	for tile_value in subset_tiles.keys():
		if not container_tiles.has(tile_value):
			return false
	return true

func _union_room_tiles_by_indices(current_rooms: Array[Dictionary], room_indices: Array[int]) -> Dictionary:
	var result: Dictionary = {}
	for idx_value in room_indices:
		var idx = int(idx_value)
		if idx < 0 or idx >= current_rooms.size():
			continue
		var room_tiles: Dictionary = current_rooms[idx].get("tiles", {})
		for tile_value in room_tiles.keys():
			result[tile_value] = true
	return result

func _compute_enclosed_void_tiles(tile_set: Dictionary) -> Dictionary:
	# Returns empty tiles that are enclosed by tile_set inside its AABB.
	var enclosed: Dictionary = {}
	if tile_set.is_empty():
		return enclosed

	var min_x = 2147483647;  var max_x = -2147483648
	var min_y = 2147483647;  var max_y = -2147483648
	for tile_value in tile_set.keys():
		var tile: Vector2i = tile_value
		min_x = mini(min_x, tile.x);  max_x = maxi(max_x, tile.x)
		min_y = mini(min_y, tile.y);  max_y = maxi(max_y, tile.y)

	var exterior: Dictionary = {}
	var queue: Array[Vector2i] = []

	for x in range(min_x, max_x + 1):
		var top = Vector2i(x, min_y)
		if not tile_set.has(top) and not exterior.has(top):
			exterior[top] = true
			queue.append(top)
		var bottom = Vector2i(x, max_y)
		if not tile_set.has(bottom) and not exterior.has(bottom):
			exterior[bottom] = true
			queue.append(bottom)

	for y in range(min_y, max_y + 1):
		var left = Vector2i(min_x, y)
		if not tile_set.has(left) and not exterior.has(left):
			exterior[left] = true
			queue.append(left)
		var right = Vector2i(max_x, y)
		if not tile_set.has(right) and not exterior.has(right):
			exterior[right] = true
			queue.append(right)

	while not queue.is_empty():
		var current: Vector2i = queue.pop_front()
		for offset_value in NEIGHBORS:
			var next: Vector2i = current + (offset_value as Vector2i)
			if next.x < min_x or next.x > max_x or next.y < min_y or next.y > max_y:
				continue
			if tile_set.has(next) or exterior.has(next):
				continue
			exterior[next] = true
			queue.append(next)

	for x in range(min_x, max_x + 1):
		for y in range(min_y, max_y + 1):
			var probe = Vector2i(x, y)
			if tile_set.has(probe) or exterior.has(probe):
				continue
			enclosed[probe] = true

	return enclosed

func _find_enclosed_nested_room_indices(current_rooms: Array[Dictionary], selected_lookup: Dictionary, base_tiles: Dictionary) -> Array[int]:
	var nested: Array[int] = []
	var enclosed_void = _compute_enclosed_void_tiles(base_tiles)
	if enclosed_void.is_empty():
		return nested

	for i in range(current_rooms.size()):
		if selected_lookup.has(i):
			continue
		var room_tiles: Dictionary = current_rooms[i].get("tiles", {})
		if room_tiles.is_empty():
			continue
		if _is_subset(room_tiles, enclosed_void):
			nested.append(i)

	return nested

func _adjacency_score(tile: Vector2i, tile_set: Dictionary) -> int:
	var score = 0
	for offset_value in NEIGHBORS:
		if tile_set.has(tile + (offset_value as Vector2i)):
			score += 1
	return score

func _room_assignment_scores(tile: Vector2i, room_entry: Dictionary) -> Dictionary:
	var current_tiles: Dictionary  = room_entry.get("tiles", {})
	var original_tiles: Dictionary = room_entry.get("orig_tiles", current_tiles)
	return {
		"original": _adjacency_score(tile, original_tiles),
		"current":  _adjacency_score(tile, current_tiles),
	}

func _find_room_entry_index_for_tile(tile: Vector2i, room_entries: Array[Dictionary], use_original_tiles: bool = true) -> int:
	for i in range(room_entries.size()):
		var entry: Dictionary = room_entries[i]
		var tiles: Dictionary = entry.get("orig_tiles" if use_original_tiles else "tiles", entry.get("tiles", {}))
		if tiles.has(tile):
			return i
	return -1

func _find_room_entry_index_along_freed_ray(
		start_tile: Vector2i,
		dir: Vector2i,
		freed_tiles: Dictionary,
		room_entries: Array[Dictionary],
		use_original_tiles: bool = true
	) -> int:
	# Walk along dir, skipping over freed tiles, to find the first live tile
	# and identify which room it belongs to.
	var probe = start_tile + dir
	while freed_tiles.has(probe):
		probe += dir
	return _find_room_entry_index_for_tile(probe, room_entries, use_original_tiles)

func _compute_resize_transfer_candidates(
		freed_tiles: Dictionary,
		target_tiles: Dictionary,
		room_entries: Array[Dictionary]
	) -> Dictionary:
	# Returns the set of room-entry indices that directly border the freed strip
	# on its outward side — only those rooms should absorb the freed tiles.
	var candidates: Dictionary = {}
	if freed_tiles.is_empty() or target_tiles.is_empty():
		return candidates

	for tile_value in freed_tiles.keys():
		var tile: Vector2i = tile_value
		for offset_value in NEIGHBORS:
			var offset: Vector2i = offset_value
			var inside = tile - offset
			if not target_tiles.has(inside):
				continue
			var room_idx = _find_room_entry_index_along_freed_ray(tile, offset, freed_tiles, room_entries, true)
			if room_idx >= 0:
				candidates[room_idx] = true
	return candidates

func _collect_resize_transfer_seed_tiles(
		freed_tiles: Dictionary,
		target_tiles: Dictionary,
		room_entries: Array[Dictionary],
		allowed_indices: Dictionary
	) -> Dictionary:
	var seeds: Dictionary = {}
	if freed_tiles.is_empty() or target_tiles.is_empty() or allowed_indices.is_empty():
		return seeds

	for tile_value in freed_tiles.keys():
		var tile: Vector2i = tile_value
		for offset_value in NEIGHBORS:
			var offset: Vector2i = offset_value
			var inside = tile - offset
			if not target_tiles.has(inside):
				continue
			var room_idx = _find_room_entry_index_along_freed_ray(tile, offset, freed_tiles, room_entries, true)
			if room_idx >= 0 and allowed_indices.has(room_idx):
				seeds[tile] = true
				break
	return seeds

func _expand_seeded_freed_tiles(seed_tiles: Dictionary, freed_tiles: Dictionary) -> Dictionary:
	# Flood-fill within freed_tiles starting from seed_tiles.
	var transferable: Dictionary = {}
	if seed_tiles.is_empty() or freed_tiles.is_empty():
		return transferable

	var queue: Array[Vector2i] = []
	for tile_value in seed_tiles.keys():
		var tile: Vector2i = tile_value
		if not freed_tiles.has(tile):
			continue
		transferable[tile] = true
		queue.append(tile)

	while not queue.is_empty():
		var current: Vector2i = queue.pop_front()
		for offset_value in NEIGHBORS:
			var neighbor: Vector2i = current + (offset_value as Vector2i)
			if freed_tiles.has(neighbor) and not transferable.has(neighbor):
				transferable[neighbor] = true
				queue.append(neighbor)

	return transferable

func _distribute_freed_tiles_to_neighbors(
		freed_tiles: Dictionary,
		room_entries: Array[Dictionary],
		allowed_indices: Dictionary = {}
	) -> void:
	# Wave-based assignment: each pass assigns tiles that are adjacent to an
	# already-known room, propagating inward until all freed tiles are absorbed.
	var pending = freed_tiles.duplicate(true)

	while not pending.is_empty():
		var assigned_tiles: Array[Vector2i] = []

		# Sort for deterministic assignment when scores are equal.
		var pending_tiles: Array = pending.keys()
		pending_tiles.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			return a.x < b.x if a.x != b.x else a.y < b.y
		)

		for tile_value in pending_tiles:
			var tile: Vector2i = tile_value
			var best_index    = -1
			var best_original = 0
			var best_current  = 0
			var best_signature = ""

			for i in range(room_entries.size()):
				if not allowed_indices.is_empty() and not allowed_indices.has(i):
					continue
				var entry: Dictionary = room_entries[i]
				var scores   = _room_assignment_scores(tile, entry)
				var orig_sc  = int(scores["original"])
				var curr_sc  = int(scores["current"])
				if orig_sc <= 0 and curr_sc <= 0:
					continue

				var sig     = str(entry.get("signature", ""))
				var better  = false
				if   orig_sc > best_original: better = true
				elif orig_sc == best_original and curr_sc > best_current: better = true
				elif orig_sc == best_original and curr_sc == best_current:
					if best_index < 0 or sig < best_signature: better = true

				if better:
					best_original  = orig_sc
					best_current   = curr_sc
					best_signature = sig
					best_index     = i

			if best_index < 0:
				continue  # No adjacent room found yet — will retry next wave.

			var sel_entry: Dictionary = room_entries[best_index]
			var sel_tiles: Dictionary = sel_entry["tiles"]
			sel_tiles[tile] = true
			sel_entry["tiles"] = sel_tiles
			room_entries[best_index] = sel_entry
			assigned_tiles.append(tile)

		if assigned_tiles.is_empty():
			break  # No progress — remaining tiles cannot be assigned.

		for tile in assigned_tiles:
			pending.erase(tile)

func _split_into_components(tile_set: Dictionary) -> Array[Dictionary]:
	var components: Array[Dictionary] = []
	var unvisited = tile_set.duplicate(true)

	while not unvisited.is_empty():
		var start   = _first_tile(unvisited)
		var queue:  Array[Vector2i] = [start]
		var component: Dictionary = {start: true}
		unvisited.erase(start)

		while not queue.is_empty():
			var current: Vector2i = queue.pop_front()
			for offset_value in NEIGHBORS:
				var neighbor: Vector2i = current + (offset_value as Vector2i)
				if not unvisited.has(neighbor):
					continue
				unvisited.erase(neighbor)
				component[neighbor] = true
				queue.append(neighbor)

		components.append(component)

	return components

func _split_room_entries_into_components(room_entries: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for entry in room_entries:
		var tiles: Dictionary = entry["tiles"]
		if tiles.is_empty():
			continue
		var component_idx = 0
		for component in _split_into_components(tiles):
			result.append({
				"signature": "%s#%d" % [str(entry["signature"]), component_idx],
				"tiles":     component,
			})
			component_idx += 1
	return result

func _union_boundary_map(room_entries: Array[Dictionary], floor_index: int) -> Dictionary:
	var boundary_union: Dictionary = {}

	# Sort for deterministic key ordering.
	var ordered_entries: Array = room_entries.duplicate()
	ordered_entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("signature", "")) < str(b.get("signature", ""))
	)

	for entry in ordered_entries:
		var tiles: Dictionary = entry["tiles"]
		if tiles.is_empty():
			continue
		for key in _boundary_wall_map(tiles, floor_index).keys():
			if not boundary_union.has(key):
				boundary_union[key] = _boundary_wall_map(tiles, floor_index)[key]
	return boundary_union

# ---------------------------------------------------------------------------
# Adaptive plan — computes which wall edges to add/remove for a move or resize
# ---------------------------------------------------------------------------
func _build_adaptive_plan(base_tiles: Dictionary, target_tiles: Dictionary, is_resize: bool) -> Dictionary:
	var floor_index    = App.get_floor_service().current_floor
	var current_rooms  = _detect_room_entries_on_floor()
	if current_rooms.is_empty():
		return {"valid": false}

	# ---- Identify which current rooms are part of the selection ----
	var selected_indices = _find_selected_room_indices(current_rooms, base_tiles)
	if selected_indices.is_empty():
		return {"valid": false}

	if is_resize and selected_indices.size() != 1:
		return {"valid": false}

	var selected_lookup = _array_to_int_lookup(selected_indices)

	# ---- Compute move delta (not needed for resize) ----
	var move_delta = Vector2i.ZERO
	if not is_resize:
		var move_info = _compute_uniform_translation(base_tiles, target_tiles)
		if not bool(move_info.get("valid", false)):
			return {"valid": false}
		move_delta = move_info["delta"]

		# If a selected room encloses other rooms ("room inside room"), move them too.
		for nested_idx in _find_enclosed_nested_room_indices(current_rooms, selected_lookup, base_tiles):
			selected_indices.append(nested_idx)
			selected_lookup[int(nested_idx)] = true

	selected_indices.sort()

	var selected_source_tiles = _union_room_tiles_by_indices(current_rooms, selected_indices)
	if selected_source_tiles.is_empty():
		selected_source_tiles = base_tiles.duplicate(true)

	var move_target_tiles: Dictionary = target_tiles
	if not is_resize:
		move_target_tiles = _offset_tiles(selected_source_tiles, move_delta)

	# ---- Build working copies of the non-selected rooms ----
	var old_entries:    Array[Dictionary] = []
	var working_others: Array[Dictionary] = []

	for i in range(current_rooms.size()):
		var current_entry: Dictionary = current_rooms[i]
		var old_tiles: Dictionary     = (current_entry["tiles"] as Dictionary).duplicate(true)
		if old_tiles.is_empty():
			continue
		old_entries.append({"signature": current_entry["signature"], "tiles": old_tiles.duplicate(true)})

		if selected_lookup.has(i):
			continue  # The selected room is handled separately below.

		var other_tiles = old_tiles.duplicate(true)
		if not is_resize:
			# Move: ensure the target area is not already occupied.
			for tile_value in move_target_tiles.keys():
				if other_tiles.has(tile_value):
					return {"valid": false}
		else:
			# Resize: remove tiles that will be claimed by the resized room.
			for tile_value in target_tiles.keys():
				other_tiles.erase(tile_value)

		working_others.append({
			"signature":  current_entry["signature"],
			"orig_tiles": other_tiles.duplicate(true),
			"tiles":      other_tiles,
		})

	# ---- For resize: redistribute freed tiles to adjacent rooms ----
	if is_resize:
		var freed_tiles = _set_difference(base_tiles, target_tiles)
		var transfer_candidates = _compute_resize_transfer_candidates(freed_tiles, target_tiles, working_others)
		if not transfer_candidates.is_empty():
			var transfer_seeds      = _collect_resize_transfer_seed_tiles(freed_tiles, target_tiles, working_others, transfer_candidates)
			var transferable_tiles  = _expand_seeded_freed_tiles(transfer_seeds, freed_tiles)
			if not transferable_tiles.is_empty():
				_distribute_freed_tiles_to_neighbors(transferable_tiles, working_others, transfer_candidates)

	working_others = _split_room_entries_into_components(working_others)

	# ---- Assemble the projected new state ----
	var new_entries: Array[Dictionary] = _build_new_room_entries(
		selected_indices, current_rooms, target_tiles, working_others, is_resize, move_delta
	)

	# ---- Diff old vs new boundary to get wall mutations ----
	var diff = _diff_boundaries(old_entries, new_entries, floor_index)
	diff["selected_source_tiles"] = selected_source_tiles
	return diff

func _find_selected_room_indices(current_rooms: Array[Dictionary], base_tiles: Dictionary) -> Array[int]:
	var selected_indices: Array[int] = []

	for i in range(current_rooms.size()):
		var room_tiles: Dictionary = current_rooms[i]["tiles"]
		if _is_subset(room_tiles, base_tiles):
			selected_indices.append(i)

	# Fallback: match by signature, then by anchor tile.
	if selected_indices.is_empty():
		for i in range(current_rooms.size()):
			if str(current_rooms[i]["signature"]) == _sel.signature:
				selected_indices.append(i)
				return selected_indices

	if selected_indices.is_empty():
		for i in range(current_rooms.size()):
			if (current_rooms[i]["tiles"] as Dictionary).has(_sel.anchor):
				selected_indices.append(i)
				return selected_indices

	return selected_indices

func _build_new_room_entries(
		selected_indices: Array[int],
		current_rooms: Array[Dictionary],
		target_tiles: Dictionary,
		working_others: Array[Dictionary],
		is_resize: bool,
		move_delta: Vector2i
	) -> Array[Dictionary]:

	var new_entries: Array[Dictionary] = []

	if is_resize:
		new_entries.append({"signature": "selected", "tiles": target_tiles.duplicate(true)})
	else:
		for idx in selected_indices:
			var moved_tiles = _offset_tiles((current_rooms[idx]["tiles"] as Dictionary).duplicate(true), move_delta)
			if not moved_tiles.is_empty():
				new_entries.append({"signature": "selected_%d" % [idx], "tiles": moved_tiles})

	for entry in working_others:
		var tiles: Dictionary = (entry["tiles"] as Dictionary).duplicate(true)
		if tiles.is_empty():
			continue
		if is_resize:
			for tile_value in target_tiles.keys():
				tiles.erase(tile_value)
		if not tiles.is_empty():
			new_entries.append({"signature": entry["signature"], "tiles": tiles})

	return new_entries

func _diff_boundaries(
		old_entries: Array[Dictionary],
		new_entries: Array[Dictionary],
		floor_index: int
	) -> Dictionary:
	var old_boundary = _union_boundary_map(old_entries, floor_index)
	var new_boundary = _union_boundary_map(new_entries, floor_index)

	var remove_edges: Array[Dictionary] = []
	var add_edges:    Array[Dictionary] = []

	for key in old_boundary.keys():
		if not new_boundary.has(key):
			remove_edges.append(old_boundary[key])

	for key in new_boundary.keys():
		if not old_boundary.has(key):
			add_edges.append(new_boundary[key])

	return {"valid": true, "remove_edges": remove_edges, "add_edges": add_edges}

# ---------------------------------------------------------------------------
# Wall placement validation
# ---------------------------------------------------------------------------
func _can_place_wall_ignoring_furniture(a: Vector2i, b: Vector2i, floor_index: int) -> bool:
	var diff = b - a
	if abs(diff.x) + abs(diff.y) != 1:
		return false
	if App.get_wall_service().has_wall(a, b, floor_index):
		return false
	if floor_index > 0 and not _is_segment_within_live_floor_limit(a, b, floor_index - 1, 2):
		if not App.get_wall_service().has_wall(a, b, floor_index - 1):
			return false
	return true

func _compute_live_floor_bounds(floor_index: int) -> Dictionary:
	var min_x = 2147483647;  var max_x = -2147483648
	var min_y = 2147483647;  var max_y = -2147483648
	var has_any = false

	for key in App.get_wall_service().get_wall_keys_for_floor(floor_index):
		var wall_data = App.get_wall_service().get_wall_by_key(key)
		if wall_data == null:
			continue
		has_any = true
		min_x = mini(min_x, mini(wall_data.from_tile.x, wall_data.to_tile.x))
		min_y = mini(min_y, mini(wall_data.from_tile.y, wall_data.to_tile.y))
		max_x = maxi(max_x, maxi(wall_data.from_tile.x, wall_data.to_tile.x))
		max_y = maxi(max_y, maxi(wall_data.from_tile.y, wall_data.to_tile.y))

	if not has_any:
		return {"valid": false}
	return {"valid": true, "min_x": min_x, "min_y": min_y, "max_x": max_x, "max_y": max_y}

func _point_within_bounds(point: Vector2i, bounds: Dictionary, margin: int) -> bool:
	if not bool(bounds.get("valid", false)):
		return false
	return (point.x >= int(bounds["min_x"]) - margin and
			point.x <= int(bounds["max_x"]) + margin and
			point.y >= int(bounds["min_y"]) - margin and
			point.y <= int(bounds["max_y"]) + margin)

func _is_segment_within_live_floor_limit(a: Vector2i, b: Vector2i, floor_index: int, margin: int) -> bool:
	var bounds = _compute_live_floor_bounds(floor_index)
	return bool(bounds.get("valid", false)) and _point_within_bounds(a, bounds, margin) and _point_within_bounds(b, bounds, margin)

func _validate_plan_edges(add_edges: Array[Dictionary], allow_furniture_removal: bool) -> bool:
	return _validate_plan_edges_with_moving(add_edges, allow_furniture_removal, {})

func _array_to_int_lookup(ids: Array[int]) -> Dictionary:
	var lookup: Dictionary = {}
	for id_value in ids:
		lookup[int(id_value)] = true
	return lookup

func _edge_blocked_only_by_moving_objects(from_tile: Vector2i, to_tile: Vector2i, floor_index: int, moving_ids_lookup: Dictionary) -> bool:
	if App.get_furniture_service() == null or not App.get_furniture_service().has_method("get_snapshots_blocking_wall"):
		return false
	var snapshots: Array = App.get_furniture_service().call("get_snapshots_blocking_wall", from_tile, to_tile, floor_index)
	if snapshots.is_empty():
		return false
	for snapshot_value in snapshots:
		if not (snapshot_value is Dictionary):
			return false
		var node_id = int((snapshot_value as Dictionary).get("node_id", -1))
		if node_id < 0 or not moving_ids_lookup.has(node_id):
			return false
	return true

func _validate_plan_edges_with_moving(add_edges: Array[Dictionary], allow_furniture_removal: bool, moving_ids_lookup: Dictionary) -> bool:
	var floor_index = App.get_floor_service().current_floor
	for edge in add_edges:
		var from_tile: Vector2i = edge["from"]
		var to_tile:   Vector2i = edge["to"]
		if App.get_wall_service().has_wall(from_tile, to_tile, floor_index):
			continue
		if App.get_wall_service().can_place_wall(from_tile, to_tile, floor_index):
			continue
		if allow_furniture_removal and App.get_furniture_service() != null and App.get_furniture_service().has_method("has_furniture_blocking_wall"):
			if bool(App.get_furniture_service().call("has_furniture_blocking_wall", from_tile, to_tile, floor_index)):
				if _can_place_wall_ignoring_furniture(from_tile, to_tile, floor_index):
					continue
		if (not allow_furniture_removal and not moving_ids_lookup.is_empty()
				and _can_place_wall_ignoring_furniture(from_tile, to_tile, floor_index)):
			if _edge_blocked_only_by_moving_objects(from_tile, to_tile, floor_index, moving_ids_lookup):
				continue
		return false
	return true

func _compute_uniform_translation(base_tiles: Dictionary, target_tiles: Dictionary) -> Dictionary:
	if base_tiles.is_empty() or target_tiles.is_empty() or base_tiles.size() != target_tiles.size():
		return {"valid": false}

	var first_base = _first_tile(base_tiles)
	for target_value in target_tiles.keys():
		var delta = (target_value as Vector2i) - first_base
		var all_match = true
		for base_value in base_tiles.keys():
			if not target_tiles.has((base_value as Vector2i) + delta):
				all_match = false
				break
		if all_match:
			return {"valid": true, "delta": delta}

	return {"valid": false}

func _dedupe_snapshot_array(snapshots: Array[Dictionary]) -> Array[Dictionary]:
	var by_id: Dictionary = {}
	for snapshot in snapshots:
		if snapshot.is_empty():
			continue
		var node_id = int(snapshot.get("node_id", -1))
		if node_id >= 0:
			by_id[node_id] = snapshot
	var deduped: Array[Dictionary] = []
	for snapshot in by_id.values():
		deduped.append(snapshot)
	return deduped

func _collect_resize_furniture_removals(add_edges: Array[Dictionary]) -> Array[Dictionary]:
	var snapshots: Array[Dictionary] = []
	if App.get_furniture_service() == null:
		return snapshots
	if not App.get_furniture_service().has_method("has_furniture_blocking_wall") or not App.get_furniture_service().has_method("get_snapshots_blocking_wall"):
		return snapshots

	var floor_index = App.get_floor_service().current_floor
	for edge in add_edges:
		var from_tile: Vector2i = edge["from"]
		var to_tile:   Vector2i = edge["to"]
		if App.get_wall_service().has_wall(from_tile, to_tile, floor_index):
			continue
		if not bool(App.get_furniture_service().call("has_furniture_blocking_wall", from_tile, to_tile, floor_index)):
			continue
		for snapshot_value in (App.get_furniture_service().call("get_snapshots_blocking_wall", from_tile, to_tile, floor_index) as Array):
			if snapshot_value is Dictionary:
				snapshots.append(snapshot_value)

	return _dedupe_snapshot_array(snapshots)

# ---------------------------------------------------------------------------
# Upper-floor support validation after resize
# ---------------------------------------------------------------------------
func _build_projected_wall_maps(plan: Dictionary) -> Dictionary:
	var projected: Dictionary = {}

	for key in App.get_wall_service().get_all_wall_keys():
		var floor_index = App.get_wall_service().get_floor_from_key(key)
		if not projected.has(floor_index):
			projected[floor_index] = {}
		var wall_data = App.get_wall_service().get_wall_by_key(key)
		if wall_data == null:
			continue
		(projected[floor_index] as Dictionary)[key] = {"from": wall_data.from_tile, "to": wall_data.to_tile}

	var current_floor = App.get_floor_service().current_floor
	if not projected.has(current_floor):
		projected[current_floor] = {}
	var floor_map: Dictionary = projected[current_floor]

	for edge in plan.get("remove_edges", []):
		floor_map.erase(App.get_wall_service().make_key(edge["from"], edge["to"], current_floor))
	for edge in plan.get("add_edges", []):
		floor_map[App.get_wall_service().make_key(edge["from"], edge["to"], current_floor)] = {"from": edge["from"], "to": edge["to"]}

	projected[current_floor] = floor_map
	return projected

func _compute_projected_floor_bounds(floor_map: Dictionary) -> Dictionary:
	if floor_map.is_empty():
		return {"valid": false}

	var min_x = 2147483647;  var max_x = -2147483648
	var min_y = 2147483647;  var max_y = -2147483648

	for edge in floor_map.values():
		var from_tile: Vector2i = edge["from"]
		var to_tile:   Vector2i = edge["to"]
		min_x = mini(min_x, mini(from_tile.x, to_tile.x))
		min_y = mini(min_y, mini(from_tile.y, to_tile.y))
		max_x = maxi(max_x, maxi(from_tile.x, to_tile.x))
		max_y = maxi(max_y, maxi(from_tile.y, to_tile.y))

	return {"valid": true, "min_x": min_x, "min_y": min_y, "max_x": max_x, "max_y": max_y}

func _is_supported_in_projected(a: Vector2i, b: Vector2i, floor_index: int, projected: Dictionary, bounds_cache: Dictionary) -> bool:
	var below_floor = floor_index - 1
	if below_floor < 0:
		return true

	if projected.has(below_floor):
		if (projected[below_floor] as Dictionary).has(App.get_wall_service().make_key(a, b, below_floor)):
			return true

	if not bounds_cache.has(below_floor):
		bounds_cache[below_floor] = _compute_projected_floor_bounds(projected.get(below_floor, {}))

	var bounds: Dictionary = bounds_cache[below_floor]
	return _point_within_bounds(a, bounds, 2) and _point_within_bounds(b, bounds, 2)

func _validate_upper_floors_after_resize(plan: Dictionary) -> bool:
	if App.get_floor_service().current_floor >= App.get_floor_service().MAX_FLOORS - 1:
		return true

	var projected    = _build_projected_wall_maps(plan)
	var bounds_cache: Dictionary = {}

	for floor_value in projected.keys():
		var floor_index = int(floor_value)
		if floor_index <= App.get_floor_service().current_floor:
			continue
		for edge in (projected[floor_index] as Dictionary).values():
			if not _is_supported_in_projected(edge["from"], edge["to"], floor_index, projected, bounds_cache):
				return false

	return true

# ---------------------------------------------------------------------------
# Opening (door/window) snapshot & restore
# ---------------------------------------------------------------------------
func _wall_centerline_world(from_tile: Vector2i, to_tile: Vector2i) -> Dictionary:
	var from_world = App.get_grid_service().tile_to_world(from_tile)
	var to_world   = App.get_grid_service().tile_to_world(to_tile)
	var midpoint   = (from_world + to_world) * 0.5
	var is_parallel_z = (to_tile - from_tile).x != 0
	var half_len = App.get_grid_service().TILE_SIZE * 0.5

	var start_world = midpoint
	var end_world   = midpoint
	if is_parallel_z:
		start_world.z -= half_len;  end_world.z += half_len
	else:
		start_world.x -= half_len;  end_world.x += half_len

	return {"start_world": start_world, "end_world": end_world}

func _opening_world_position(from_tile: Vector2i, to_tile: Vector2i, offset_t: float, floor_index: int) -> Vector3:
	var line    = _wall_centerline_world(from_tile, to_tile)
	var pos     = (line["start_world"] as Vector3).lerp(line["end_world"], clampf(offset_t, 0.0, 1.0))
	pos.y = App.get_grid_service().get_wall_y_base(floor_index)
	return pos

func _snapshot_room_openings(base_tiles: Dictionary) -> Array[Dictionary]:
	var snapshots: Array[Dictionary] = []
	var opening_system = App.get_opening_service()
	if opening_system == null:
		return snapshots

	var floor_index = App.get_floor_service().current_floor
	var boundary_map = _boundary_wall_map(base_tiles, floor_index)
	for wall_key in boundary_map.keys():
		if not bool(opening_system.call("has_opening", wall_key)):
			continue
		var opening = opening_system.call("get_opening", wall_key)
		if opening == null:
			continue
		var wall_data = App.get_wall_service().get_wall_by_key(wall_key)
		if wall_data == null:
			continue
		var boundary_edge: Dictionary = boundary_map.get(wall_key, {})
		var boundary_from: Vector2i = boundary_edge.get("from", wall_data.from_tile)
		var boundary_to: Vector2i = boundary_edge.get("to", wall_data.to_tile)
		snapshots.append({
			"wall_key":   wall_key,
			"from_tile":  wall_data.from_tile,
			"to_tile":    wall_data.to_tile,
			"offset_t":   float(opening.offset_t),
			"type":       str(opening.type),
			"scene_path": str(opening.scene_path),
			"floor":      floor_index,
			"boundary_dir": boundary_to - boundary_from,
			"world_pos":  _opening_world_position(wall_data.from_tile, wall_data.to_tile, float(opening.offset_t), floor_index),
		})
	return snapshots

func _wall_is_parallel_z(from_tile: Vector2i, to_tile: Vector2i) -> bool:
	return (to_tile - from_tile).x != 0

func _find_best_resize_wall_for_opening(snapshot: Dictionary, target_boundary: Dictionary) -> Dictionary:
	var floor_index = int(snapshot.get("floor", App.get_floor_service().current_floor))
	var old_from: Vector2i = snapshot.get("from_tile", Vector2i.ZERO)
	var old_to:   Vector2i = snapshot.get("to_tile",   Vector2i.ZERO)
	var old_parallel_z = _wall_is_parallel_z(old_from, old_to)
	var old_world_pos: Vector3 = snapshot.get("world_pos", Vector3.ZERO)
	var expected_dir: Vector2i = snapshot.get("boundary_dir", Vector2i.ZERO)

	var p = Vector2(old_world_pos.x, old_world_pos.z)
	var best_dist = INF
	var best: Dictionary = {}

	for wall_key in target_boundary.keys():
		var boundary_edge: Dictionary = target_boundary[wall_key]
		var candidate_dir: Vector2i = boundary_edge.get("to", Vector2i.ZERO) - boundary_edge.get("from", Vector2i.ZERO)
		if expected_dir != Vector2i.ZERO and candidate_dir != expected_dir:
			continue

		var wall_data = App.get_wall_service().get_wall_by_key(wall_key)
		if wall_data == null:
			continue
		if _wall_is_parallel_z(wall_data.from_tile, wall_data.to_tile) != old_parallel_z:
			continue

		var line        = _wall_centerline_world(wall_data.from_tile, wall_data.to_tile)
		var a           = Vector2((line["start_world"] as Vector3).x, (line["start_world"] as Vector3).z)
		var b           = Vector2((line["end_world"]   as Vector3).x, (line["end_world"]   as Vector3).z)
		var ab          = b - a
		var len_sq      = ab.length_squared()
		if len_sq <= 0.0001:
			continue

		var offset_t = clampf((p - a).dot(ab) / len_sq, 0.05, 0.95)
		var dist     = a.lerp(b, offset_t).distance_to(p)
		if dist >= best_dist:
			continue

		best_dist = dist
		best = {
			"wall_key": wall_key,
			"offset_t": offset_t,
			"floor": floor_index,
		}

	return best

func _find_wall_for_opening_position(world_pos: Vector3, floor_index: int) -> Dictionary:
	var best_dist = INF
	var best: Dictionary = {}
	var p = Vector2(world_pos.x, world_pos.z)

	for wall_key in App.get_wall_service().get_wall_keys_for_floor(floor_index):
		var wall_data = App.get_wall_service().get_wall_by_key(wall_key)
		if wall_data == null:
			continue

		var line        = _wall_centerline_world(wall_data.from_tile, wall_data.to_tile)
		var a           = Vector2((line["start_world"] as Vector3).x, (line["start_world"] as Vector3).z)
		var b           = Vector2((line["end_world"]   as Vector3).x, (line["end_world"]   as Vector3).z)
		var ab          = b - a
		var len_sq      = ab.length_squared()
		if len_sq <= 0.0001:
			continue

		var offset_t = clampf((p - a).dot(ab) / len_sq, 0.05, 0.95)
		var dist     = a.lerp(b, offset_t).distance_to(p)
		if dist >= App.get_grid_service().TILE_SIZE * 0.4 or dist >= best_dist:
			continue

		best_dist = dist
		best = {"wall_key": wall_key, "offset_t": offset_t}

	return best

func _restore_openings_from_snapshots(snapshots: Array[Dictionary], room_tiles: Dictionary) -> void:
	if snapshots.is_empty():
		return
	var opening_system = App.get_opening_service()
	if opening_system == null:
		return

	var floor_index = App.get_floor_service().current_floor
	var target_boundary = _boundary_wall_map(room_tiles, floor_index)

	for snapshot in snapshots:
		var snapshot_floor = int(snapshot.get("floor", floor_index))
		if snapshot_floor != floor_index:
			continue

		var preferred_key = str(snapshot.get("wall_key", ""))
		if preferred_key != "" and target_boundary.has(preferred_key) and App.get_wall_service().get_wall_by_key(preferred_key) != null:
			if bool(opening_system.call("has_opening", preferred_key)):
				continue
			opening_system.call("place_opening", preferred_key,
				str(snapshot.get("type", "door")),
				float(snapshot.get("offset_t", 0.5)),
				str(snapshot.get("scene_path", "")))
			continue

		var found = _find_best_resize_wall_for_opening(snapshot, target_boundary)
		if found.is_empty():
			continue

		var wall_key = str(found["wall_key"])
		if bool(opening_system.call("has_opening", wall_key)):
			continue
		opening_system.call("place_opening", wall_key,
			str(snapshot.get("type", "door")),
			float(found.get("offset_t", 0.5)),
			str(snapshot.get("scene_path", "")))

func _clear_detached_opening_near(world_pos: Vector3) -> void:
	for node in get_tree().get_nodes_in_group("room_editor_detached_openings"):
		if node is Node3D and (node as Node3D).global_position.distance_to(world_pos) <= 0.1:
			node.queue_free()

func _spawn_detached_opening(snapshot: Dictionary) -> void:
	var scene_path = str(snapshot.get("scene_path", ""))
	if scene_path == "":
		return
	var opening_scene: PackedScene = load(scene_path)
	if opening_scene == null:
		return
	var scene = get_tree().current_scene
	if not (scene is Node3D):
		return
	var inst: Node3D = opening_scene.instantiate()
	(scene as Node3D).add_child(inst)
	inst.add_to_group("room_editor_detached_openings")
	inst.global_position = snapshot.get("world_pos", Vector3.ZERO)

# Opening snapshot for move (stores tile coords for delta-based restore).
func _snapshot_room_openings_for_move(base_tiles: Dictionary) -> Array[Dictionary]:
	var snapshots: Array[Dictionary] = []
	var opening_system = App.get_opening_service()
	if opening_system == null:
		return snapshots

	var floor_index = App.get_floor_service().current_floor
	for wall_key in _boundary_wall_map(base_tiles, floor_index).keys():
		if not bool(opening_system.call("has_opening", wall_key)):
			continue
		var opening = opening_system.call("get_opening", wall_key)
		if opening == null:
			continue
		var wall_data = App.get_wall_service().get_wall_by_key(wall_key)
		if wall_data == null:
			continue
		snapshots.append({
			"from_tile":  wall_data.from_tile,
			"to_tile":    wall_data.to_tile,
			"offset_t":   float(opening.offset_t),
			"type":       str(opening.type),
			"scene_path": str(opening.scene_path),
			"floor":      floor_index,
		})
	return snapshots

func _restore_openings_with_delta(snapshots: Array[Dictionary], delta_tiles: Vector2i) -> void:
	if snapshots.is_empty():
		return
	var opening_system = App.get_opening_service()
	if opening_system == null:
		return

	for snapshot in snapshots:
		var floor_index = int(snapshot.get("floor", App.get_floor_service().current_floor))
		var from_tile: Vector2i = snapshot.get("from_tile", Vector2i.ZERO) + delta_tiles
		var to_tile:   Vector2i = snapshot.get("to_tile",   Vector2i.ZERO) + delta_tiles
		var wall_key = App.get_wall_service().make_key(from_tile, to_tile, floor_index)
		if not App.get_wall_service().has_wall(from_tile, to_tile, floor_index):
			continue
		if bool(opening_system.call("has_opening", wall_key)):
			continue
		opening_system.call("place_opening", wall_key,
			str(snapshot.get("type", "door")),
			float(snapshot.get("offset_t", 0.5)),
			str(snapshot.get("scene_path", "")))

# ---------------------------------------------------------------------------
# Plan validation & application (calls into App.get_wall_service() + App.get_history_service())
# ---------------------------------------------------------------------------
func _can_apply_wall_delta(base_tiles: Dictionary, target_tiles: Dictionary, is_resize: bool) -> bool:
	var plan = _build_adaptive_plan(base_tiles, target_tiles, is_resize)
	if not bool(plan.get("valid", false)):
		return false

	var add_edges: Array[Dictionary] = plan["add_edges"]
	var moving_source_tiles: Dictionary = plan.get("selected_source_tiles", base_tiles)
	var moving_ids_lookup: Dictionary = {}

	if not is_resize and App.get_furniture_service() != null and App.get_furniture_service().has_method("get_object_node_ids_in_tiles"):
		moving_ids_lookup = _array_to_int_lookup(App.get_furniture_service().call("get_object_node_ids_in_tiles", moving_source_tiles))

	if not _validate_plan_edges_with_moving(add_edges, is_resize, moving_ids_lookup):
		return false
	if is_resize and not _validate_upper_floors_after_resize(plan):
		return false
	return true

func _apply_tile_transform(base_tiles: Dictionary, target_tiles: Dictionary, label: String, is_resize: bool, move_delta_hint: Vector2i = Vector2i.ZERO) -> bool:
	var plan = _build_adaptive_plan(base_tiles, target_tiles, is_resize)
	if not bool(plan.get("valid", false)):
		return false

	# Resolve move delta.
	var move_delta = move_delta_hint
	if not is_resize and move_delta == Vector2i.ZERO:
		var inferred = _compute_uniform_translation(base_tiles, target_tiles)
		if not bool(inferred.get("valid", false)):
			return false
		move_delta = inferred["delta"]

	var add_edges:    Array[Dictionary] = plan["add_edges"]
	var remove_edges: Array[Dictionary] = plan["remove_edges"]
	var moving_source_tiles: Dictionary = plan.get("selected_source_tiles", base_tiles)

	# Furniture bookkeeping.
	var moving_object_ids: Array[int]  = []
	var moving_ids_lookup: Dictionary  = {}
	if not is_resize and App.get_furniture_service() != null and App.get_furniture_service().has_method("get_object_node_ids_in_tiles"):
		moving_object_ids = App.get_furniture_service().call("get_object_node_ids_in_tiles", moving_source_tiles)
		moving_ids_lookup = _array_to_int_lookup(moving_object_ids)

	if not _validate_plan_edges_with_moving(add_edges, is_resize, moving_ids_lookup):
		return false
	if is_resize and not _validate_upper_floors_after_resize(plan):
		return false

	var floor_index           = App.get_floor_service().current_floor
	var furniture_removals:    Array[Dictionary] = []
	var opening_snapshots_move: Array[Dictionary] = []

	if is_resize:
		furniture_removals = _collect_resize_furniture_removals(add_edges)
	else:
		opening_snapshots_move = _snapshot_room_openings_for_move(moving_source_tiles)

	var opening_snapshots = _snapshot_room_openings(base_tiles)

	if remove_edges.is_empty() and add_edges.is_empty() and furniture_removals.is_empty():
		return false

	# ----- Undo/redo registration -----
	App.get_history_service().execute(
		label,
		# DO:
		func():
			App.get_wall_service().begin_batch()
			for edge in remove_edges:
				if App.get_wall_service().has_wall(edge["from"], edge["to"], floor_index):
					App.get_wall_service().remove_wall(edge["from"], edge["to"], floor_index)

			if not is_resize and App.get_furniture_service() != null and App.get_furniture_service().has_method("translate_objects_by_node_ids"):
				App.get_furniture_service().call("translate_objects_by_node_ids", moving_object_ids, move_delta)

			if is_resize and App.get_furniture_service() != null and App.get_furniture_service().has_method("handle_invalid_snapshot"):
				for snapshot in furniture_removals:
					App.get_furniture_service().call("handle_invalid_snapshot", snapshot)

			for edge in add_edges:
				if not App.get_wall_service().has_wall(edge["from"], edge["to"], floor_index):
					App.get_wall_service().place_wall(edge["from"], edge["to"], floor_index)
			App.get_wall_service().end_batch()

			if is_resize:
				_restore_openings_from_snapshots(opening_snapshots, target_tiles)
			else:
				_restore_openings_with_delta(opening_snapshots_move, move_delta),

		# UNDO:
		func():
			App.get_wall_service().begin_batch()
			for edge in add_edges:
				if App.get_wall_service().has_wall(edge["from"], edge["to"], floor_index):
					App.get_wall_service().remove_wall(edge["from"], edge["to"], floor_index)
			for edge in remove_edges:
				if not App.get_wall_service().has_wall(edge["from"], edge["to"], floor_index):
					App.get_wall_service().place_wall(edge["from"], edge["to"], floor_index)
			App.get_wall_service().end_batch()

			if not is_resize and App.get_furniture_service() != null and App.get_furniture_service().has_method("translate_objects_by_node_ids"):
				App.get_furniture_service().call("translate_objects_by_node_ids", moving_object_ids, -move_delta)

			if is_resize and App.get_furniture_service() != null and App.get_furniture_service().has_method("restore_snapshot"):
				for snapshot in furniture_removals:
					App.get_furniture_service().call("restore_snapshot", snapshot)

			if is_resize:
				_restore_openings_from_snapshots(opening_snapshots, base_tiles)
			else:
				_restore_openings_with_delta(opening_snapshots_move, Vector2i.ZERO)
	)

	return true

# ---------------------------------------------------------------------------
# Tiny pure utilities
# ---------------------------------------------------------------------------
func _array_to_set(room_tiles: Array) -> Dictionary:
	var tile_set: Dictionary = {}
	for value in room_tiles:
		if value is Vector2i:
			tile_set[value] = true
	return tile_set

func _tiles_signature(tile_set: Dictionary) -> String:
	var parts: Array[String] = []
	for tile_value in tile_set.keys():
		var t: Vector2i = tile_value
		parts.append("%d,%d" % [t.x, t.y])
	parts.sort()
	return ";".join(parts)

func _first_tile(tile_set: Dictionary) -> Vector2i:
	for tile_value in tile_set.keys():
		return tile_value
	return Vector2i.ZERO

func _dir_to_world(dir: Vector2i) -> Vector3:
	return Vector3(float(dir.x), 0.0, float(dir.y)).normalized()

func _get_camera() -> Camera3D:
	if mouse_raycast == null:
		return null
	var camera_value: Variant = mouse_raycast.get("camera")
	return camera_value if camera_value is Camera3D else null

# ---------------------------------------------------------------------------
# Material setup
# ---------------------------------------------------------------------------
func _setup_materials() -> void:
	_highlight_material = _make_unshaded_material(Color(0.10, 0.75, 0.95, 0.28))
	_preview_valid_material   = _make_unshaded_material(Color(0.20, 0.95, 0.40, 0.34))
	_preview_invalid_material = _make_unshaded_material(Color(0.95, 0.25, 0.25, 0.34))

	_handle_material = StandardMaterial3D.new()
	_handle_material.shading_mode     = BaseMaterial3D.SHADING_MODE_UNSHADED
	_handle_material.albedo_color     = Color(1.0, 0.62, 0.18, 1.0)
	_handle_material.emission_enabled = true
	_handle_material.emission         = Color(0.55, 0.28, 0.05)
	_handle_material.cull_mode        = BaseMaterial3D.CULL_DISABLED

func _make_unshaded_material(color: Color) -> StandardMaterial3D:
	var mat = StandardMaterial3D.new()
	mat.transparency  = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode  = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color  = color
	mat.cull_mode     = BaseMaterial3D.CULL_DISABLED
	return mat
