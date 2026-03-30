extends Node3D

var wall_height: float      = 3.0
const WALL_THICKNESS: float = 0.15

# Opening gap constants
const DOOR_HEIGHT: float  = 2.2
const DOOR_WIDTH: float   = 0.9
const WINDOW_HEIGHT: float = 1.0
const WINDOW_BOTTOM: float = 0.9   # height from floor to window bottom
const WINDOW_WIDTH: float  = 0.8

var _wall_nodes: Dictionary = {}   # wall_key -> Array[MeshInstance3D]
var _opening_nodes: Dictionary = {}  # wall_key -> Node3D

func _opening_system() -> Node:
	return get_node_or_null("/root/OpeningSystem")

func _make_wall_key(a: Vector2i, b: Vector2i, floor_index: int) -> String:
	if a.x < b.x or (a.x == b.x and a.y < b.y):
		if floor_index == 0:
			return "%d,%d|%d,%d" % [a.x, a.y, b.x, b.y]
		return "%d,%d,%d|%d,%d,%d" % [a.x, a.y, floor_index, b.x, b.y, floor_index]
	if floor_index == 0:
		return "%d,%d|%d,%d" % [b.x, b.y, a.x, a.y]
	return "%d,%d,%d|%d,%d,%d" % [b.x, b.y, floor_index, a.x, a.y, floor_index]

func _ready() -> void:
	wall_height = FloorManager.FLOOR_HEIGHT
	WallSystem.wall_placed.connect(_on_wall_placed)
	WallSystem.wall_removed.connect(_on_wall_removed)
	var opening_system := _opening_system()
	if opening_system != null:
		opening_system.connect("opening_added", _on_opening_changed)
		opening_system.connect("opening_removed", _on_opening_changed)
	FloorManager.floor_changed.connect(_on_floor_changed)

	for key in WallSystem.get_all_wall_keys():
		var wall_data = WallSystem.get_wall_by_key(key)
		if wall_data == null:
			continue
		_build_wall_meshes(key, wall_data.from_tile, wall_data.to_tile, WallSystem.get_floor_from_key(key))

	_refresh_all_visibility()

# -------------------------------------------------------
# Wall placed/removed
# -------------------------------------------------------

func _on_wall_placed(from_tile: Vector2i, to_tile: Vector2i, floor_index: int) -> void:
	var key := _make_wall_key(from_tile, to_tile, floor_index)
	if _wall_nodes.has(key):
		return
	_build_wall_meshes(key, from_tile, to_tile, floor_index)

func _on_wall_removed(from_tile: Vector2i, to_tile: Vector2i, floor_index: int) -> void:
	var key := _make_wall_key(from_tile, to_tile, floor_index)
	_clear_wall_meshes(key)

func _on_opening_changed(wall_key: String) -> void:
	# Rebuild only the affected wall.
	var wall_data = WallSystem.get_wall_by_key(wall_key)
	if wall_data == null:
		return
	var floor_index := int(WallSystem.get_floor_from_key(wall_key))
	_clear_wall_meshes(wall_key)
	_build_wall_meshes(wall_key, wall_data.from_tile, wall_data.to_tile, floor_index)

func _on_floor_changed(_old: int, _new: int) -> void:
	_refresh_all_visibility()

func _get_wall_centerline_world(from_tile: Vector2i, to_tile: Vector2i) -> Dictionary:
	var from_world := GridManager.tile_to_world(from_tile)
	var to_world := GridManager.tile_to_world(to_tile)
	var midpoint := (from_world + to_world) * 0.5
	var diff := to_tile - from_tile
	var is_parallel_z := diff.x != 0
	var half_len := GridManager.TILE_SIZE * 0.5

	var start_world := midpoint
	var end_world := midpoint
	if is_parallel_z:
		start_world.z -= half_len
		end_world.z += half_len
	else:
		start_world.x -= half_len
		end_world.x += half_len

	return {
		"midpoint": midpoint,
		"start_world": start_world,
		"end_world": end_world,
		"is_parallel_z": is_parallel_z,
	}

# -------------------------------------------------------
# Build meshes for one wall (may be split by opening)
# -------------------------------------------------------

func _build_wall_meshes(key: String, from_tile: Vector2i, to_tile: Vector2i, floor_index: int) -> void:
	var floor_y: float = GridManager.get_wall_y_base(floor_index)
	var line_data := _get_wall_centerline_world(from_tile, to_tile)
	var midpoint: Vector3 = line_data["midpoint"]
	var start_world: Vector3 = line_data["start_world"]
	var end_world: Vector3 = line_data["end_world"]
	var is_parallel_z: bool = line_data["is_parallel_z"]
 
	var opening_system := _opening_system()
	var opening = null
	if opening_system != null:
		opening = opening_system.call("get_opening", key)

	var meshes: Array[MeshInstance3D] = []

	if opening == null:
		# Simple full wall
		meshes.append(_make_wall_segment(
			midpoint, floor_y, wall_height,
			is_parallel_z, GridManager.TILE_SIZE
		))
	else:
		# Split wall around the opening gap
		var opening_type: String = opening.type
		var opening_t: float = float(opening.offset_t)
		var gap_width: float = DOOR_WIDTH if opening_type == "door" else WINDOW_WIDTH
		var gap_bottom: float = 0.0 if opening_type == "door" else WINDOW_BOTTOM
		var gap_top: float = DOOR_HEIGHT if opening_type == "door" else WINDOW_BOTTOM + WINDOW_HEIGHT

		# t is 0..1 along the wall centerline.
		var wall_len: float = GridManager.TILE_SIZE
		var gap_start: float = opening_t * wall_len - gap_width * 0.5
		var gap_end: float = opening_t * wall_len + gap_width * 0.5
		var opening_center := start_world.lerp(end_world, opening_t)

		# Left segment (0 → gap_start)
		if gap_start > 0.05:
			var seg_len: float = gap_start
			var seg_center_t := (gap_start * 0.5) / wall_len
			var seg_center := start_world.lerp(end_world, seg_center_t)
			meshes.append(_make_wall_segment(seg_center, floor_y, wall_height, is_parallel_z, seg_len))

		# Right segment (gap_end → wall_len)
		if gap_end < wall_len - 0.05:
			var seg_len: float = wall_len - gap_end
			var seg_center_t := (gap_end + seg_len * 0.5) / wall_len
			var seg_center := start_world.lerp(end_world, seg_center_t)
			meshes.append(_make_wall_segment(seg_center, floor_y, wall_height, is_parallel_z, seg_len))

		# Top fill above opening (for windows and doors that don't reach ceiling)
		if gap_top < wall_height - 0.05:
			var top_h := wall_height - gap_top
			meshes.append(_make_wall_segment(opening_center, floor_y + gap_top, top_h, is_parallel_z, gap_width))

		# Bottom fill below opening (windows only)
		if gap_bottom > 0.05:
			meshes.append(_make_wall_segment(opening_center, floor_y, gap_bottom, is_parallel_z, gap_width))

		# Spawn the door/window mesh at the opening center
		if opening.scene_path != "":
			var scene: PackedScene = load(opening.scene_path)
			if scene != null:
				var inst: Node3D = scene.instantiate()
				add_child(inst)
				var center := opening_center
				center.y = floor_y
				inst.global_position = center
				# Rotate to align with wall segment.
				if is_parallel_z:
					inst.rotation_degrees.y = 90.0
				else:
					inst.rotation_degrees.y = 0.0
				_opening_nodes[key] = inst

	_wall_nodes[key] = meshes
	_apply_floor_visibility_to(meshes, floor_index)
	_apply_opening_visibility(key, floor_index)

func _make_wall_segment(
		center: Vector3,
		floor_y: float,
		height: float,
		is_parallel_z: bool,
		length: float
) -> MeshInstance3D:
	var mi  := MeshInstance3D.new()
	var box := BoxMesh.new()
	if is_parallel_z:
		box.size = Vector3(WALL_THICKNESS, height, length)
	else:
		box.size = Vector3(length, height, WALL_THICKNESS)
	mi.mesh = box
	mi.position = Vector3(center.x, floor_y + height * 0.5, center.z)
	add_child(mi)
	return mi

func _clear_wall_meshes(key: String) -> void:
	if not _wall_nodes.has(key):
		return
	_clear_opening_node(key)
	for mi in _wall_nodes[key]:
		if is_instance_valid(mi):
			mi.queue_free()
	_wall_nodes.erase(key)

func _clear_opening_node(key: String) -> void:
	if not _opening_nodes.has(key):
		return
	var node: Node3D = _opening_nodes[key]
	if is_instance_valid(node):
		node.queue_free()
	_opening_nodes.erase(key)

# -------------------------------------------------------
# Floor visibility
# -------------------------------------------------------

func _refresh_all_visibility() -> void:
	for key in _wall_nodes.keys():
		var floor_index := int(WallSystem.get_floor_from_key(key))
		_apply_floor_visibility_to(_wall_nodes[key], floor_index)
		_apply_opening_visibility(key, floor_index)

func _apply_floor_visibility_to(meshes: Array[MeshInstance3D], floor_index: int) -> void:
	var floor_visible := floor_index <= FloorManager.current_floor
	for mi in meshes:
		if is_instance_valid(mi):
			mi.visible = floor_visible

func _apply_opening_visibility(key: String, floor_index: int) -> void:
	if not _opening_nodes.has(key):
		return
	var node: Node3D = _opening_nodes[key]
	if is_instance_valid(node):
		node.visible = floor_index <= FloorManager.current_floor
