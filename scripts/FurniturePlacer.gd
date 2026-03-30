# FurniturePlacer.gd
extends Node

@export var mouse_raycast: Node
@export var furniture_container: Node3D
@export var active: bool = false
@export var free_collision_padding: float = 0.03

# Set these when player selects a furniture item from the UI
var current_scene_path: String = ""
var current_size: Vector2i = Vector2i(1, 1)   # in tiles

# Internal state
var _rotation_index: int = 0        # 0=0°, 1=90°, 2=180°, 3=270°
var _free_mode: bool = false         # Alt held
var _preview_instance: Node3D = null
var _preview_valid: bool = false

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

func activate(scene_path: String, size: Vector2i) -> void:
	current_scene_path = scene_path
	current_size = size
	active = true
	_rotation_index = 0
	_resolve_furniture_container()
	_spawn_preview()

func deactivate() -> void:
	active = false
	_destroy_preview()

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

		# R rotates 90°
		if ke.pressed and ke.keycode == KEY_R:
			_rotation_index = (_rotation_index + 1) % 4
			if is_instance_valid(_preview_instance):
				_preview_instance.rotation_degrees.y = _rotation_index * 90.0

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton

		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			deactivate()
			return

		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			if _preview_valid:
				_place_furniture()

func _process(_delta: float) -> void:
	if not active or current_scene_path == "":
		return

	_free_mode = Input.is_key_pressed(KEY_ALT)
	_update_preview_position()

# -------------------------------------------------------
# Position logic
# -------------------------------------------------------

func _get_snapped_world_pos() -> Vector3:
	var tile : Vector2i = mouse_raycast.get_tile_under_mouse()
	return FurnitureSystem.get_snapped_world_position(tile, current_size, _rotation_index)

func _get_free_world_pos() -> Vector3:
	return mouse_raycast.get_world_position_under_mouse()

func _current_world_pos() -> Vector3:
	if _free_mode:
		return _get_free_world_pos()
	else:
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
	# Disable any collision on the preview so it doesn't interfere
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

func _update_preview_position() -> void:
	if not is_instance_valid(_preview_instance):
		_spawn_preview()
		return

	var world_pos := _current_world_pos()
	_preview_instance.global_position = world_pos
	_preview_instance.rotation_degrees.y = _rotation_index * 90.0

	# Check validity
	if _free_mode:
		_preview_valid = _check_free_placement_valid(world_pos)
	else:
		var tile : Vector2i = mouse_raycast.get_tile_under_mouse()
		_preview_valid = FurnitureSystem.can_place(tile, current_size, _rotation_index)

	_apply_preview_tint(_preview_instance, _preview_valid)

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

	var tile : Vector2i = mouse_raycast.get_tile_under_mouse()
	if not FurnitureSystem.can_place(tile, current_size, _rotation_index):
		return

	var world_pos := FurnitureSystem.get_snapped_world_position(tile, current_size, _rotation_index)
	var rot := _rotation_index
	var path := current_scene_path
	var size := current_size

	UndoHistory.execute(
		"place furniture",
		func():
			FurnitureSystem.place_furniture_at(tile, world_pos, rot, path, size, target_container),
		func():
			FurnitureSystem.remove_furniture_at_tile(tile)
	)

func _place_free() -> void:
	var target_container := _resolve_furniture_container()
	if target_container == null:
		push_error("FurniturePlacer: no valid furniture container.")
		return

	var world_pos := _preview_instance.global_position
	if not _check_free_placement_valid(world_pos):
		return

	var path := current_scene_path
	var rot  := _rotation_index
	# In free mode we use the nearest tile just for storage/undo keying
	var tile := GridManager.world_to_tile(world_pos)

	UndoHistory.execute(
		"place furniture (free)",
		func():
			FurnitureSystem.place_furniture_at(tile, world_pos, rot, path, current_size, target_container, false),
		func():
			FurnitureSystem.remove_furniture_at_world(world_pos)
	)

# -------------------------------------------------------
# Free-placement collision check using ShapeCast3D
# -------------------------------------------------------

var _shape_cast: ShapeCast3D = null

func _check_free_placement_valid(world_pos: Vector3) -> bool:
	var half_extents := _get_preview_half_extents_xz()
	if half_extents != Vector2.ZERO:
		half_extents.x = maxf(0.01, half_extents.x - free_collision_padding)
		half_extents.y = maxf(0.01, half_extents.y - free_collision_padding)
	return FurnitureSystem.can_place_free_world(world_pos, current_size, _rotation_index)

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
		current_size.x * GridManager.TILE_SIZE * 0.9,
		1.8,
		current_size.y * GridManager.TILE_SIZE * 0.9
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
