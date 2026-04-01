extends Node

@export var mouse_raycast: Node
@export var active: bool = false
@export var preview_alpha: float = 0.58

var current_color: Color = Color(0.88, 0.86, 0.82, 1.0)

const PICK_MAX_DISTANCE: float = 0.55
const PREVIEW_SURFACE_THICKNESS: float = 0.024
const PREVIEW_SURFACE_EPSILON: float = 0.005

var _preview_nodes: Array[MeshInstance3D] = []
var _preview_signature: String = ""
var _preview_texture: NoiseTexture2D = null

func activate(color: Color) -> void:
	current_color = color
	active = true
	_preview_signature = ""

func deactivate() -> void:
	active = false
	_clear_preview()

func _process(_delta: float) -> void:
	if not active:
		if not _preview_nodes.is_empty():
			_clear_preview()
		return
	_update_hover_preview()

func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return

	if event is InputEventKey:
		var ke := event as InputEventKey
		if ke.pressed and ke.keycode == KEY_ESCAPE:
			deactivate()
			return

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			deactivate()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_paint_under_mouse()

func _paint_under_mouse() -> void:
	var picked := _pick_wall_under_mouse()
	if picked.is_empty():
		return

	var targets := _collect_targets_from_pick(picked, Input.is_key_pressed(KEY_SHIFT))
	if targets.is_empty():
		return

	if targets.size() == 1:
		_paint_single_side(targets[0])
		return

	_paint_multiple_sides(targets, "paint room wall sides")

func _paint_single_side(target: Dictionary) -> void:
	var wall_key := str(target.get("wall_key", ""))
	var side := str(target.get("side", ""))
	if wall_key == "" or (side != "front" and side != "back"):
		return

	var old_color := WallSystem.get_wall_side_color_by_key(wall_key, side)
	if old_color == current_color:
		return

	UndoHistory.execute(
		"paint wall side",
		func(): WallSystem.set_wall_side_color_by_key(wall_key, side, current_color),
		func(): WallSystem.set_wall_side_color_by_key(wall_key, side, old_color)
	)

func _paint_multiple_sides(targets: Array[Dictionary], label: String) -> void:
	var snapshot: Array[Dictionary] = []
	for target in targets:
		var key := str(target.get("wall_key", ""))
		var side := str(target.get("side", ""))
		snapshot.append({
			"wall_key": key,
			"side": side,
			"old_color": WallSystem.get_wall_side_color_by_key(key, side),
		})

	UndoHistory.execute(
		label,
		func():
			for target in targets:
				var key := str(target.get("wall_key", ""))
				var side := str(target.get("side", ""))
				WallSystem.set_wall_side_color_by_key(key, side, current_color),
		func():
			for saved in snapshot:
				var key := str(saved.get("wall_key", ""))
				var side := str(saved.get("side", ""))
				var old_color: Color = saved.get("old_color", WallSystem.get_default_wall_color())
				WallSystem.set_wall_side_color_by_key(key, side, old_color)
	)

func _collect_targets_from_pick(picked: Dictionary, shift_pressed: bool) -> Array[Dictionary]:
	var targets: Array[Dictionary] = []
	if not shift_pressed:
		targets.append({
			"wall_key": str(picked.get("wall_key", "")),
			"side": str(picked.get("side", "")),
		})
		return _dedupe_targets(targets)

	var floor_index := FloorManager.current_floor
	var target_room_id := int(picked.get("room_id", -1))

	for identity in WallSystem.get_wall_identities_for_floor(floor_index):
		var identity_dict := identity as Dictionary
		var key := str(identity_dict.get("key", ""))
		if key == "":
			continue
		var front_side: Dictionary = identity_dict.get("front_side", {})
		var back_side: Dictionary = identity_dict.get("back_side", {})
		if int(front_side.get("room_id", -1)) == target_room_id:
			targets.append({"wall_key": key, "side": "front"})
		if int(back_side.get("room_id", -1)) == target_room_id:
			targets.append({"wall_key": key, "side": "back"})

	return _dedupe_targets(targets)

func _dedupe_targets(targets: Array[Dictionary]) -> Array[Dictionary]:
	var unique: Dictionary = {}
	for target in targets:
		var key := str(target.get("wall_key", ""))
		var side := str(target.get("side", ""))
		if key == "" or (side != "front" and side != "back"):
			continue
		unique["%s::%s" % [key, side]] = {"wall_key": key, "side": side}
	var result: Array[Dictionary] = []
	for signature in unique.keys():
		result.append(unique[signature])
	return result

func _pick_wall_under_mouse() -> Dictionary:
	var direct_pick := _pick_wall_surface_with_physics()
	if not direct_pick.is_empty():
		return direct_pick

	# Fallback keeps wall painting functional even if collision setup is unavailable.
	return _pick_wall_surface_with_grid()

func _pick_wall_surface_with_physics() -> Dictionary:
	if mouse_raycast == null:
		return {}
	var camera: Camera3D = mouse_raycast.get("camera")
	if camera == null:
		return {}

	var viewport := get_viewport()
	if viewport == null:
		return {}
	var mouse_pos := viewport.get_mouse_position()
	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir := camera.project_ray_normal(mouse_pos)
	var ray_length := float(mouse_raycast.get("raycast_length"))
	if ray_length <= 0.0:
		ray_length = 1000.0

	var query := PhysicsRayQueryParameters3D.create(ray_origin, ray_origin + ray_dir * ray_length)
	query.collide_with_bodies = true
	query.collide_with_areas = false

	var world_3d := viewport.get_world_3d()
	if world_3d == null:
		return {}
	var hit := world_3d.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return {}

	var collider_obj: Object = hit.get("collider", null)
	if collider_obj == null or not (collider_obj is Node):
		return {}
	var collider := collider_obj as Node
	if not collider.has_meta("wall_key") or not collider.has_meta("wall_side"):
		return {}

	var wall_key := str(collider.get_meta("wall_key", ""))
	var side := str(collider.get_meta("wall_side", ""))
	if wall_key == "" or (side != "front" and side != "back"):
		return {}

	var identity := WallSystem.get_wall_identity_by_key(wall_key)
	if identity.is_empty():
		return {}
	var side_info: Dictionary = identity.get("%s_side" % side, {})
	return {
		"wall_key": wall_key,
		"side": side,
		"room_id": int(side_info.get("room_id", -1)),
	}

func _pick_wall_surface_with_grid() -> Dictionary:
	var world: Vector3 = mouse_raycast.get_world_position_under_mouse()
	var floor_index := FloorManager.current_floor
	var tile_size: float = GridManager.TILE_SIZE

	var lx := world.x / tile_size
	var lz := world.z / tile_size
	var ix := floori(lx)
	var iz := floori(lz)
	var x_line := roundi(lx)
	var z_line := roundi(lz)

	var candidates: Array[Dictionary] = [
		{
			"a": Vector2i(x_line - 1, iz),
			"b": Vector2i(x_line, iz),
			"distance": abs(lx - float(x_line)) * tile_size,
		},
		{
			"a": Vector2i(ix, z_line - 1),
			"b": Vector2i(ix, z_line),
			"distance": abs(lz - float(z_line)) * tile_size,
		},
	]

	candidates.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return float(left.get("distance", 99999.0)) < float(right.get("distance", 99999.0))
	)

	for candidate in candidates:
		var a: Vector2i = candidate.get("a", Vector2i.ZERO)
		var b: Vector2i = candidate.get("b", Vector2i.ZERO)
		var distance := float(candidate.get("distance", 99999.0))
		if distance > PICK_MAX_DISTANCE:
			continue
		var wall_key := _make_wall_key(a, b, floor_index)
		if WallSystem.get_wall_by_key(wall_key) == null:
			continue

		var identity := WallSystem.get_wall_identity_by_key(wall_key)
		if identity.is_empty():
			continue
		var side := _resolve_clicked_side(identity, world)
		var side_info: Dictionary = identity.get("%s_side" % side, {})
		return {
			"wall_key": wall_key,
			"side": side,
			"room_id": int(side_info.get("room_id", -1)),
		}

	return {}

func _update_hover_preview() -> void:
	var picked := _pick_wall_under_mouse()
	if picked.is_empty():
		_clear_preview()
		return

	var targets := _collect_targets_from_pick(picked, Input.is_key_pressed(KEY_SHIFT))
	if targets.is_empty():
		_clear_preview()
		return

	var signature := _targets_signature(targets)
	if signature == _preview_signature:
		return

	_rebuild_preview(targets)
	_preview_signature = signature

func _targets_signature(targets: Array[Dictionary]) -> String:
	var parts: Array[String] = []
	for target in targets:
		parts.append("%s::%s" % [str(target.get("wall_key", "")), str(target.get("side", ""))])
	parts.sort()
	return "|".join(parts)

func _rebuild_preview(targets: Array[Dictionary]) -> void:
	_clear_preview_nodes()
	for target in targets:
		var node := _create_preview_for_target(target)
		if node == null:
			continue
		_preview_nodes.append(node)

func _create_preview_for_target(target: Dictionary) -> MeshInstance3D:
	var wall_key := str(target.get("wall_key", ""))
	var side := str(target.get("side", ""))
	if wall_key == "" or (side != "front" and side != "back"):
		return null

	var wall_data = WallSystem.get_wall_by_key(wall_key)
	if wall_data == null:
		return null

	var from_tile: Vector2i = wall_data.from_tile
	var to_tile: Vector2i = wall_data.to_tile
	var floor_index := int(WallSystem.get_floor_from_key(wall_key))
	var floor_y := GridManager.get_wall_y_base(floor_index)
	var height := FloorManager.FLOOR_HEIGHT

	var from_world := GridManager.tile_to_world(from_tile)
	var to_world := GridManager.tile_to_world(to_tile)
	var midpoint := (from_world + to_world) * 0.5
	var diff := to_tile - from_tile
	var is_parallel_z := diff.x != 0
	var length := GridManager.TILE_SIZE

	var preview := MeshInstance3D.new()
	var box := BoxMesh.new()
	if is_parallel_z:
		box.size = Vector3(PREVIEW_SURFACE_THICKNESS, height, length)
	else:
		box.size = Vector3(length, height, PREVIEW_SURFACE_THICKNESS)
	preview.mesh = box
	preview.material_override = _get_preview_material()
	preview.position = Vector3(midpoint.x, floor_y + height * 0.5, midpoint.z)

	var side_sign := -1.0 if side == "front" else 1.0
	var side_offset := ((0.15 + PREVIEW_SURFACE_THICKNESS) * 0.5) + PREVIEW_SURFACE_EPSILON
	if is_parallel_z:
		preview.position.x += side_sign * side_offset
	else:
		preview.position.z += side_sign * side_offset

	var host := get_tree().current_scene
	if host != null:
		host.add_child(preview)
	else:
		add_child(preview)
	return preview

func _ensure_preview_texture() -> NoiseTexture2D:
	if _preview_texture != null:
		return _preview_texture
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = 4.0
	noise.fractal_octaves = 3
	var texture := NoiseTexture2D.new()
	texture.width = 128
	texture.height = 128
	texture.seamless = true
	texture.noise = noise
	_preview_texture = texture
	return _preview_texture

func _get_preview_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var c := current_color
	c.a = preview_alpha
	mat.albedo_color = c
	mat.albedo_texture = _ensure_preview_texture()
	mat.roughness = 0.82
	mat.metallic = 0.0
	mat.uv1_scale = Vector3(3.2, 1.4, 3.2)
	return mat

func _clear_preview() -> void:
	_preview_signature = ""
	_clear_preview_nodes()

func _clear_preview_nodes() -> void:
	for node in _preview_nodes:
		if is_instance_valid(node):
			node.queue_free()
	_preview_nodes.clear()

func _resolve_clicked_side(identity: Dictionary, world: Vector3) -> String:
	var orientation := str(identity.get("orientation", ""))
	var from_tile: Vector2i = identity.get("from_tile", Vector2i.ZERO)
	var to_tile: Vector2i = identity.get("to_tile", Vector2i.ZERO)
	var tile_size: float = GridManager.TILE_SIZE

	if orientation == "vertical":
		var min_x := mini(from_tile.x, to_tile.x)
		var wall_x := float(min_x + 1) * tile_size
		return "front" if world.x < wall_x else "back"

	var min_y := mini(from_tile.y, to_tile.y)
	var wall_z := float(min_y + 1) * tile_size
	return "front" if world.z < wall_z else "back"

func _make_wall_key(a: Vector2i, b: Vector2i, floor_index: int) -> String:
	if a.x < b.x or (a.x == b.x and a.y < b.y):
		if floor_index == 0:
			return "%d,%d|%d,%d" % [a.x, a.y, b.x, b.y]
		return "%d,%d,%d|%d,%d,%d" % [a.x, a.y, floor_index, b.x, b.y, floor_index]
	if floor_index == 0:
		return "%d,%d|%d,%d" % [b.x, b.y, a.x, a.y]
	return "%d,%d,%d|%d,%d,%d" % [b.x, b.y, floor_index, a.x, a.y, floor_index]
