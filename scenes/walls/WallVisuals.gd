extends Node3D

var wall_height: float      = 3.0
const WALL_THICKNESS: float = 0.15
const WALL_LAYER_THICKNESS: float = 0.018
const WALL_SURFACE_EPSILON: float = 0.002
const WALL_TEXTURE_TINT := Color(0.82, 0.80, 0.76, 1.0)

# Opening gap constants
const DOOR_HEIGHT: float  = 2.2
const DOOR_WIDTH: float   = 0.9
const WINDOW_HEIGHT: float = 1.0
const WINDOW_BOTTOM: float = 0.9   # height from floor to window bottom
const WINDOW_WIDTH: float  = 0.8

var _wall_nodes: Dictionary = {}   # wall_key -> Array[MeshInstance3D]
var _opening_nodes: Dictionary = {}  # wall_key -> Node3D
var _wall_texture: NoiseTexture2D = null
var _wall_core_material: StandardMaterial3D = null
var _wall_surface_material_cache: Dictionary = {}

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
	WallSystem.wall_side_color_changed.connect(_on_wall_side_color_changed)
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

func _on_wall_side_color_changed(wall_key: String) -> void:
	_rebuild_wall_from_key(wall_key)

func _rebuild_wall_from_key(wall_key: String) -> void:
	var wall_data = WallSystem.get_wall_by_key(wall_key)
	if wall_data == null:
		_clear_wall_meshes(wall_key)
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

func _ensure_wall_texture() -> NoiseTexture2D:
	if _wall_texture != null:
		return _wall_texture
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 4.0
	noise.fractal_octaves = 3
	var texture := NoiseTexture2D.new()
	texture.width = 256
	texture.height = 256
	texture.seamless = true
	texture.noise = noise
	_wall_texture = texture
	return _wall_texture

func _get_wall_core_material() -> StandardMaterial3D:
	if _wall_core_material != null:
		return _wall_core_material
	var mat := StandardMaterial3D.new()
	mat.albedo_color = WALL_TEXTURE_TINT
	mat.albedo_texture = _ensure_wall_texture()
	mat.roughness = 0.95
	mat.metallic = 0.0
	mat.uv1_scale = Vector3(2.6, 1.6, 2.6)
	_wall_core_material = mat
	return _wall_core_material

func _get_wall_surface_material(color: Color) -> StandardMaterial3D:
	var cache_key := "%d,%d,%d,%d" % [
		roundi(color.r * 255.0),
		roundi(color.g * 255.0),
		roundi(color.b * 255.0),
		roundi(color.a * 255.0),
	]
	if _wall_surface_material_cache.has(cache_key):
		return _wall_surface_material_cache[cache_key]

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.albedo_texture = _ensure_wall_texture()
	mat.roughness = 0.88
	mat.metallic = 0.0
	mat.uv1_scale = Vector3(3.2, 1.4, 3.2)
	_wall_surface_material_cache[cache_key] = mat
	return mat

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
	var wall_colors: Dictionary = WallSystem.get_wall_colors_by_key(key)
	var front_color: Color = wall_colors.get("front", WallSystem.get_default_wall_color())
	var back_color: Color = wall_colors.get("back", WallSystem.get_default_wall_color())
 
	var opening_system := _opening_system()
	var opening = null
	if opening_system != null:
		opening = opening_system.call("get_opening", key)

	var meshes: Array[MeshInstance3D] = []

	if opening == null:
		# Simple full wall
		meshes.append(_make_wall_segment(
			midpoint, floor_y, wall_height,
			is_parallel_z, GridManager.TILE_SIZE, front_color, back_color, key
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
			meshes.append(_make_wall_segment(seg_center, floor_y, wall_height, is_parallel_z, seg_len, front_color, back_color, key))

		# Right segment (gap_end → wall_len)
		if gap_end < wall_len - 0.05:
			var seg_len: float = wall_len - gap_end
			var seg_center_t := (gap_end + seg_len * 0.5) / wall_len
			var seg_center := start_world.lerp(end_world, seg_center_t)
			meshes.append(_make_wall_segment(seg_center, floor_y, wall_height, is_parallel_z, seg_len, front_color, back_color, key))

		# Top fill above opening (for windows and doors that don't reach ceiling)
		if gap_top < wall_height - 0.05:
			var top_h := wall_height - gap_top
			meshes.append(_make_wall_segment(opening_center, floor_y + gap_top, top_h, is_parallel_z, gap_width, front_color, back_color, key))

		# Bottom fill below opening (windows only)
		if gap_bottom > 0.05:
			meshes.append(_make_wall_segment(opening_center, floor_y, gap_bottom, is_parallel_z, gap_width, front_color, back_color, key))

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
		length: float,
		front_color: Color,
		back_color: Color,
		wall_key: String
) -> MeshInstance3D:
	var mi  := MeshInstance3D.new()
	var box := BoxMesh.new()
	if is_parallel_z:
		box.size = Vector3(WALL_THICKNESS, height, length)
	else:
		box.size = Vector3(length, height, WALL_THICKNESS)
	mi.mesh = box
	mi.material_override = _get_wall_core_material()
	mi.position = Vector3(center.x, floor_y + height * 0.5, center.z)

	var front_layer := _make_paint_layer(height, is_parallel_z, length, front_color, wall_key, "front")
	var back_layer := _make_paint_layer(height, is_parallel_z, length, back_color, wall_key, "back")
	var surface_offset := ((WALL_THICKNESS + WALL_LAYER_THICKNESS) * 0.5) + WALL_SURFACE_EPSILON
	if is_parallel_z:
		front_layer.position.x = -surface_offset
		back_layer.position.x = surface_offset
	else:
		front_layer.position.z = -surface_offset
		back_layer.position.z = surface_offset

	mi.add_child(front_layer)
	mi.add_child(back_layer)
	add_child(mi)
	return mi

func _make_paint_layer(height: float, is_parallel_z: bool, length: float, color: Color, wall_key: String, side: String) -> MeshInstance3D:
	var layer := MeshInstance3D.new()
	var layer_mesh := BoxMesh.new()
	var shape_size := Vector3.ZERO
	if is_parallel_z:
		shape_size = Vector3(WALL_LAYER_THICKNESS, height, length)
	else:
		shape_size = Vector3(length, height, WALL_LAYER_THICKNESS)
	layer_mesh.size = shape_size
	layer.mesh = layer_mesh
	layer.material_override = _get_wall_surface_material(color)

	var body := StaticBody3D.new()
	body.set_meta("wall_key", wall_key)
	body.set_meta("wall_side", side)
	var collision := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = shape_size
	collision.shape = box_shape
	body.add_child(collision)
	layer.add_child(body)
	return layer

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
