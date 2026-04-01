extends Node

@export var mouse_raycast: Node
@export var active: bool = false
@export var preview_y_offset: float = 0.035

var current_material: Material = null
var _preview_mesh: MeshInstance3D = null
var _preview_signature: String = ""
var _preview_material_source_id: int = -1

func activate(mat: Material) -> void:
	current_material = mat
	active = true
	_preview_signature = ""
	_preview_material_source_id = -1

func deactivate() -> void:
	active = false
	_clear_preview()

func _process(_delta: float) -> void:
	if not active:
		if is_instance_valid(_preview_mesh):
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
			_paint_tile()

func _paint_tile() -> void:
	var tile  : Vector2i = mouse_raycast.get_tile_under_mouse()
	var floor_index := FloorManager.current_floor
	var mat   := current_material
	var target_tiles := _collect_target_tiles(tile, floor_index, Input.is_key_pressed(KEY_SHIFT))
	if target_tiles.is_empty():
		return

	var snapshot: Dictionary = {}
	for tile_key in target_tiles.keys():
		snapshot[tile_key] = RoomSystem.get_tile_material(tile_key, floor_index)

	var label := "paint floor tile"
	if target_tiles.size() > 1:
		label = "paint room floor"

	UndoHistory.execute(
		label,
		func():
			var next_materials: Dictionary = {}
			for tile_key in target_tiles.keys():
				next_materials[tile_key] = mat
			RoomSystem.set_tile_materials_bulk(next_materials, floor_index),
		func():
			RoomSystem.set_tile_materials_bulk(snapshot, floor_index)
	)

func _collect_target_tiles(origin_tile: Vector2i, floor_index: int, shift_pressed: bool) -> Dictionary:
	if not shift_pressed:
		return {origin_tile: true}

	var room_id := WallSystem.get_room_id_for_tile(origin_tile, floor_index)
	if room_id != -1:
		return WallSystem.get_room_tiles_by_id(room_id, floor_index)

	return RoomSystem.get_all_floor_tiles(floor_index)

func _update_hover_preview() -> void:
	var floor_index := FloorManager.current_floor
	var tile: Vector2i = mouse_raycast.get_tile_under_mouse()
	var target_tiles := _collect_target_tiles(tile, floor_index, Input.is_key_pressed(KEY_SHIFT))
	if target_tiles.is_empty():
		_clear_preview()
		return

	var signature := _make_preview_signature(target_tiles)
	var material_id := _get_material_signature_id(current_material)
	if signature == _preview_signature and material_id == _preview_material_source_id:
		return

	_rebuild_preview_mesh(target_tiles, floor_index)
	_preview_signature = signature
	_preview_material_source_id = material_id

func _make_preview_signature(tiles: Dictionary) -> String:
	var parts: Array[String] = []
	for tile in tiles.keys():
		parts.append("%d,%d" % [tile.x, tile.y])
	parts.sort()
	return ";".join(parts)

func _get_material_signature_id(mat: Material) -> int:
	if mat == null:
		return -1
	return mat.get_instance_id()

func _rebuild_preview_mesh(tiles: Dictionary, floor_index: int) -> void:
	_ensure_preview_mesh()
	if _preview_mesh == null:
		return

	var y := FloorManager.get_floor_y_offset(floor_index) + preview_y_offset
	var ts := GridManager.TILE_SIZE
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	for tile in tiles.keys():
		var t: Vector2i = tile
		var x0 := t.x * ts
		var x1 := x0 + ts
		var z0 := t.y * ts
		var z1 := z0 + ts

		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(0, 0)); st.add_vertex(Vector3(x0, y, z0))
		st.set_uv(Vector2(1, 0)); st.add_vertex(Vector3(x1, y, z0))
		st.set_uv(Vector2(1, 1)); st.add_vertex(Vector3(x1, y, z1))

		st.set_uv(Vector2(0, 0)); st.add_vertex(Vector3(x0, y, z0))
		st.set_uv(Vector2(1, 1)); st.add_vertex(Vector3(x1, y, z1))
		st.set_uv(Vector2(0, 1)); st.add_vertex(Vector3(x0, y, z1))

	var preview_mesh := st.commit()
	if preview_mesh == null or preview_mesh.get_surface_count() == 0:
		_clear_preview()
		return

	preview_mesh.surface_set_material(0, _build_preview_material())
	_preview_mesh.mesh = preview_mesh

func _build_preview_material() -> Material:
	if current_material is StandardMaterial3D:
		var mat := (current_material as StandardMaterial3D).duplicate(true) as StandardMaterial3D
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		var c := mat.albedo_color
		c.a = minf(c.a, 0.62)
		mat.albedo_color = c
		return mat

	var fallback := StandardMaterial3D.new()
	fallback.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fallback.albedo_color = Color(0.95, 0.9, 0.75, 0.58)
	fallback.roughness = 1.0
	fallback.metallic = 0.0
	return fallback

func _ensure_preview_mesh() -> void:
	if is_instance_valid(_preview_mesh):
		return
	_preview_mesh = MeshInstance3D.new()
	_preview_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var host := get_tree().current_scene
	if host != null:
		host.add_child(_preview_mesh)
	else:
		add_child(_preview_mesh)

func _clear_preview() -> void:
	_preview_signature = ""
	_preview_material_source_id = -1
	if is_instance_valid(_preview_mesh):
		_preview_mesh.queue_free()
	_preview_mesh = null
