class_name RoomService
extends Node

# Default floor materials — player can override per-tile via FloorPainter
@export var default_floor_material: Material
@export var roof_material: Material

# room_meshes[floor][signature] -> {
#   floor_mesh: MeshInstance3D,
#   roof_mesh: MeshInstance3D,
#   tiles: Array[Vector2i]
# }
var _room_meshes: Dictionary = {}
var _fallback_roof_material: StandardMaterial3D = null
var _shared_floor_texture: NoiseTexture2D = null
var _pending_rebuild_floors: Dictionary = {}
var _rebuild_flush_scheduled: bool = false

# Per-tile material overrides: Dictionary[String -> Material]
# Key: "x,z,floor"
var _tile_materials: Dictionary = {}

const ROOF_Z_FIGHT_OFFSET: float = 0.02
const DEFAULT_FLOOR_COLOR := Color(0.64, 0.56, 0.46, 1.0)

func _ready() -> void:
	App.get_wall_service().wall_placed.connect(_on_wall_changed)
	App.get_wall_service().wall_removed.connect(_on_wall_changed)
	App.get_floor_service().floor_changed.connect(_on_floor_changed)
	if default_floor_material == null:
		default_floor_material = create_tinted_floor_material(DEFAULT_FLOOR_COLOR)
	if roof_material == null:
		_fallback_roof_material = StandardMaterial3D.new()
		_fallback_roof_material.albedo_color = Color(0.78, 0.78, 0.78, 1.0)
		_fallback_roof_material.roughness = 1.0
		_fallback_roof_material.metallic = 0.0

func _ensure_floor_texture() -> NoiseTexture2D:
	if _shared_floor_texture != null:
		return _shared_floor_texture
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.frequency = 2.6
	noise.fractal_octaves = 4
	var noise_texture := NoiseTexture2D.new()
	noise_texture.width = 256
	noise_texture.height = 256
	noise_texture.seamless = true
	noise_texture.noise = noise
	_shared_floor_texture = noise_texture
	return _shared_floor_texture

func create_tinted_floor_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.albedo_texture = _ensure_floor_texture()
	mat.roughness = 0.96
	mat.metallic = 0.0
	mat.uv1_scale = Vector3(1.35, 1.35, 1.35)
	return mat

func _on_wall_changed(_a: Vector2i, _b: Vector2i, _floor: int) -> void:
	_queue_floor_rebuild(_floor)

func _on_floor_changed(_old_floor: int, _new_floor: int) -> void:
	_refresh_visibility()

func _queue_floor_rebuild(floor_index: int) -> void:
	_pending_rebuild_floors[floor_index] = true
	if _rebuild_flush_scheduled:
		return
	_rebuild_flush_scheduled = true
	call_deferred("_flush_queued_floor_rebuilds")

func _flush_queued_floor_rebuilds() -> void:
	_rebuild_flush_scheduled = false
	var floors_to_rebuild: Array = _pending_rebuild_floors.keys()
	_pending_rebuild_floors.clear()
	for floor_value in floors_to_rebuild:
		_rebuild_floor(int(floor_value))

func _rebuild_floor(floor_index: int) -> void:
	# Clear existing meshes for this floor
	if _room_meshes.has(floor_index):
		for sig in _room_meshes[floor_index].keys():
			var entry: Dictionary = _room_meshes[floor_index][sig]
			if is_instance_valid(entry.get("floor_mesh", null)):
				entry["floor_mesh"].queue_free()
			if is_instance_valid(entry.get("roof_mesh", null)):
				entry["roof_mesh"].queue_free()
		_room_meshes.erase(floor_index)

	# Detect rooms on this floor
	var rooms: Array = _detect_rooms_on_floor(floor_index)
	if rooms.is_empty():
		_refresh_visibility()
		return

	_room_meshes[floor_index] = {}
	for room in rooms:
		var sig := _make_signature(room)
		var floor_mesh := _build_floor_mesh(room, floor_index)
		var roof_mesh := _build_roof_mesh(room, floor_index)
		_room_meshes[floor_index][sig] = {
			"floor_mesh": floor_mesh,
			"roof_mesh": roof_mesh,
			"tiles": room,
		}

	_refresh_visibility()

func _detect_rooms_on_floor(floor_index: int) -> Array:
	# Uses the existing RoomDetector logic but filtered to a specific floor
	var detector: Node = App.get_wall_service().get_room_detector()
	if detector == null:
		return []
	return detector.detect_all_rooms_on_floor(floor_index)

# -------------------------------------------------------
# Mesh generation
# -------------------------------------------------------

func _build_floor_mesh(tiles: Array, floor_index: int) -> MeshInstance3D:
	var y : int = App.get_floor_service().get_floor_y_offset(floor_index)
	var ts : int = App.get_grid_service().TILE_SIZE
	var grouped_tiles: Dictionary = {}

	for tile in tiles:
		var t: Vector2i = tile
		var tile_material := _get_tile_material(t, floor_index)
		var mat_key := "null" if tile_material == null else str(tile_material.get_instance_id())
		if not grouped_tiles.has(mat_key):
			grouped_tiles[mat_key] = {
				"material": tile_material,
				"tiles": [],
			}
		(grouped_tiles[mat_key]["tiles"] as Array).append(t)

	var mesh := ArrayMesh.new()

	for key in grouped_tiles.keys():
		var entry: Dictionary = grouped_tiles[key]
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for tile in entry["tiles"]:
			var t: Vector2i = tile

			# Each tile is a quad (two triangles)
			var x0 := t.x * ts
			var x1 := x0 + ts
			var z0 := t.y * ts
			var z1 := z0 + ts

			# UV mapping: one tile = one UV unit
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(0, 0)); st.add_vertex(Vector3(x0, y, z0))
			st.set_uv(Vector2(1, 0)); st.add_vertex(Vector3(x1, y, z0))
			st.set_uv(Vector2(1, 1)); st.add_vertex(Vector3(x1, y, z1))

			st.set_uv(Vector2(0, 0)); st.add_vertex(Vector3(x0, y, z0))
			st.set_uv(Vector2(1, 1)); st.add_vertex(Vector3(x1, y, z1))
			st.set_uv(Vector2(0, 1)); st.add_vertex(Vector3(x0, y, z1))

		var built_mesh: ArrayMesh = st.commit()
		if built_mesh == null or built_mesh.get_surface_count() == 0:
			continue

		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, built_mesh.surface_get_arrays(0))
		var mat: Material = entry["material"]
		if mat == null:
			mat = default_floor_material
		mesh.surface_set_material(mesh.get_surface_count() - 1, mat)

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.visible = floor_index <= App.get_floor_service().current_floor
	get_tree().current_scene.add_child(mi)
	return mi

func _build_roof_mesh(tiles: Array, floor_index: int) -> MeshInstance3D:
	if tiles.is_empty():
		return null

	var ts : int = App.get_grid_service().TILE_SIZE
	var roof_y : int = App.get_floor_service().get_floor_y_offset(floor_index + 1) - ROOF_Z_FIGHT_OFFSET
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	for tile in tiles:
		var t: Vector2i = tile
		var x0 := t.x * ts
		var x1 := x0 + ts
		var z0 := t.y * ts
		var z1 := z0 + ts

		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(0, 0)); st.add_vertex(Vector3(x0, roof_y, z0))
		st.set_uv(Vector2(1, 0)); st.add_vertex(Vector3(x1, roof_y, z0))
		st.set_uv(Vector2(1, 1)); st.add_vertex(Vector3(x1, roof_y, z1))

		st.set_uv(Vector2(0, 0)); st.add_vertex(Vector3(x0, roof_y, z0))
		st.set_uv(Vector2(1, 1)); st.add_vertex(Vector3(x1, roof_y, z1))
		st.set_uv(Vector2(0, 1)); st.add_vertex(Vector3(x0, roof_y, z1))

	var mesh: ArrayMesh = st.commit()
	if mesh == null or mesh.get_surface_count() == 0:
		return null
	mesh.surface_set_material(0, _get_roof_material())

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.visible = floor_index < App.get_floor_service().current_floor
	get_tree().current_scene.add_child(mi)
	return mi

func _get_roof_material() -> Material:
	if roof_material != null:
		return roof_material
	if _fallback_roof_material == null:
		_fallback_roof_material = StandardMaterial3D.new()
		_fallback_roof_material.albedo_color = Color(0.78, 0.78, 0.78, 1.0)
		_fallback_roof_material.roughness = 1.0
		_fallback_roof_material.metallic = 0.0
	return _fallback_roof_material

func get_tile_material(tile: Vector2i, floor_index: int) -> Material:
	var key := "%d,%d,%d" % [tile.x, tile.y, floor_index]
	return _tile_materials.get(key, default_floor_material)

func get_all_floor_tiles(floor_index: int = -1) -> Dictionary:
	var f : int = floor_index if floor_index >= 0 else App.get_floor_service().current_floor
	var tiles: Dictionary = {}
	for room in _detect_rooms_on_floor(f):
		if not (room is Array):
			continue
		for tile in room:
			if tile is Vector2i:
				tiles[tile] = true
	return tiles

func _get_tile_material(tile: Vector2i, floor_index: int) -> Material:
	return get_tile_material(tile, floor_index)

# -------------------------------------------------------
# Per-tile material painting (called by FloorPainter)
# -------------------------------------------------------

func set_tile_material(tile: Vector2i, floor_index: int, mat: Material) -> void:
	var key := "%d,%d,%d" % [tile.x, tile.y, floor_index]
	_tile_materials[key] = mat
	# Rebuild is queued so brush strokes and wall edits can coalesce per frame.
	_queue_floor_rebuild(floor_index)

func set_tile_materials_bulk(tile_materials: Dictionary, floor_index: int) -> void:
	for tile_value in tile_materials.keys():
		if not (tile_value is Vector2i):
			continue
		var tile: Vector2i = tile_value
		var key := "%d,%d,%d" % [tile.x, tile.y, floor_index]
		_tile_materials[key] = tile_materials[tile_value]
	_queue_floor_rebuild(floor_index)

func clear_tile_material(tile: Vector2i, floor_index: int) -> void:
	var key := "%d,%d,%d" % [tile.x, tile.y, floor_index]
	_tile_materials.erase(key)
	_queue_floor_rebuild(floor_index)

func clear_all_tile_materials() -> void:
	_tile_materials.clear()
	var floors_to_rebuild: Dictionary = {}
	for floor_key in _room_meshes.keys():
		floors_to_rebuild[int(floor_key)] = true
	floors_to_rebuild[App.get_floor_service().current_floor] = true
	for floor_value in floors_to_rebuild.keys():
		_queue_floor_rebuild(int(floor_value))

func export_tile_material_overrides() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for key_value in _tile_materials.keys():
		var key := str(key_value)
		var parts := key.split(",")
		if parts.size() != 3:
			continue
		var mat_variant: Variant = _tile_materials[key_value]
		if not (mat_variant is StandardMaterial3D):
			continue
		var mat := mat_variant as StandardMaterial3D
		var c := mat.albedo_color
		result.append({
			"x": int(parts[0]),
			"y": int(parts[1]),
			"floor": int(parts[2]),
			"color": [c.r, c.g, c.b, c.a],
		})
	return result

func apply_tile_material_overrides(entries: Array) -> void:
	var by_floor: Dictionary = {}
	for entry_value in entries:
		if not (entry_value is Dictionary):
			continue
		var entry := entry_value as Dictionary
		if not entry.has("x") or not entry.has("y") or not entry.has("floor"):
			continue
		if not entry.has("color") or not (entry["color"] is Array):
			continue

		var color_arr: Array = entry["color"]
		if color_arr.size() < 3:
			continue

		var floor_index := int(entry["floor"])
		var tile := Vector2i(int(entry["x"]), int(entry["y"]))
		var color := Color(
			float(color_arr[0]),
			float(color_arr[1]),
			float(color_arr[2]),
			float(color_arr[3]) if color_arr.size() > 3 else 1.0
		)
		if not by_floor.has(floor_index):
			by_floor[floor_index] = {}
		(by_floor[floor_index] as Dictionary)[tile] = create_tinted_floor_material(color)

	for floor_value in by_floor.keys():
		set_tile_materials_bulk(by_floor[floor_value], int(floor_value))

func _refresh_visibility() -> void:
	var current_floor : int = App.get_floor_service().current_floor
	for floor_key in _room_meshes.keys():
		var floor_index := int(floor_key)
		for sig in _room_meshes[floor_key].keys():
			var entry: Dictionary = _room_meshes[floor_key][sig]
			var floor_mesh: MeshInstance3D = entry.get("floor_mesh", null)
			if is_instance_valid(floor_mesh):
				floor_mesh.visible = floor_index <= current_floor
			var roof_mesh: MeshInstance3D = entry.get("roof_mesh", null)
			if is_instance_valid(roof_mesh):
				roof_mesh.visible = floor_index < current_floor

func _make_signature(tiles: Array) -> String:
	var parts: Array[String] = []
	for t in tiles:
		parts.append("%d,%d" % [t.x, t.y])
	parts.sort()
	return ";".join(parts)
