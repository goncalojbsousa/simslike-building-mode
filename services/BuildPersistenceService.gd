class_name BuildPersistenceService
extends Node

const SAVE_VERSION := 1

func build_payload() -> Dictionary:
	return {
		"version": SAVE_VERSION,
		"current_floor": App.get_floor_service().current_floor,
		"walls": _serialize_walls(),
		"openings": _serialize_openings(),
		"furniture": _serialize_furniture(),
		"floor_materials": _serialize_floor_materials(),
	}

func apply_payload(payload: Dictionary) -> void:
	clear_world_state()

	var walls: Array = payload.get("walls", [])
	var openings: Array = payload.get("openings", [])
	var furniture: Array = payload.get("furniture", [])
	var floor_materials: Array = payload.get("floor_materials", [])

	_restore_walls(walls)
	_restore_openings(openings)
	_restore_furniture(furniture)
	_restore_floor_materials(floor_materials)

	var target_floor := int(payload.get("current_floor", 0))
	_set_floor(target_floor)

func new_build() -> void:
	clear_world_state()
	_set_floor(0)

func clear_world_state() -> void:
	if App.get_furniture_service() != null and App.get_furniture_service().has_method("clear_all"):
		App.get_furniture_service().clear_all()

	if App.get_opening_service() != null and App.get_opening_service().has_method("get_all_keys"):
		for key_value in App.get_opening_service().get_all_keys():
			App.get_opening_service().remove_opening(str(key_value))

	if App.get_wall_service() != null and App.get_wall_service().has_method("get_all_wall_keys"):
		var keys: Array = App.get_wall_service().get_all_wall_keys()
		App.get_wall_service().begin_batch()
		for key in keys:
			var wall_data = App.get_wall_service().get_wall_by_key(key)
			if wall_data == null:
				continue
			var floor_index := int(App.get_wall_service().get_floor_from_key(key))
			App.get_wall_service().remove_wall(wall_data.from_tile, wall_data.to_tile, floor_index)
		App.get_wall_service().end_batch()

	if App.get_room_service() != null and App.get_room_service().has_method("clear_all_tile_materials"):
		App.get_room_service().clear_all_tile_materials()

	if App.get_history_service() != null and App.get_history_service().has_method("clear"):
		App.get_history_service().clear()

func _serialize_walls() -> Array:
	var result: Array = []
	for key in App.get_wall_service().get_all_wall_keys():
		var wall_data = App.get_wall_service().get_wall_by_key(key)
		if wall_data == null:
			continue
		var floor_index := int(App.get_wall_service().get_floor_from_key(key))
		var colors: Dictionary = App.get_wall_service().get_wall_colors_by_key(key)
		var front_color: Color = colors.get("front", App.get_wall_service().get_default_wall_color())
		var back_color: Color = colors.get("back", App.get_wall_service().get_default_wall_color())
		result.append({
			"from": [wall_data.from_tile.x, wall_data.from_tile.y],
			"to": [wall_data.to_tile.x, wall_data.to_tile.y],
			"floor": floor_index,
			"front_color": _color_to_array(front_color),
			"back_color": _color_to_array(back_color),
		})
	return result

func _serialize_openings() -> Array:
	var result: Array = []
	if App.get_opening_service() == null:
		return result
	for key_value in App.get_opening_service().get_all_keys():
		var wall_key := str(key_value)
		var opening = App.get_opening_service().get_opening(wall_key)
		if opening == null:
			continue
		result.append({
			"wall_key": wall_key,
			"type": str(opening.type),
			"offset_t": float(opening.offset_t),
			"scene_path": str(opening.scene_path),
		})
	return result

func _serialize_furniture() -> Array:
	var result: Array = []
	if App.get_furniture_service() == null or not App.get_furniture_service().has_method("get_all_snapshots"):
		return result

	for snapshot_value in App.get_furniture_service().get_all_snapshots():
		if not (snapshot_value is Dictionary):
			continue
		var snapshot := snapshot_value as Dictionary
		var tile: Vector2i = snapshot.get("tile", Vector2i.ZERO)
		var world_pos: Vector3 = snapshot.get("world_pos", Vector3.ZERO)
		result.append({
			"tile": [tile.x, tile.y],
			"floor_index": int(snapshot.get("floor_index", 0)),
			"scene_path": str(snapshot.get("scene_path", "")),
			"rotation_index": int(snapshot.get("rotation_index", 0)),
			"size": [int((snapshot.get("size", Vector2i.ONE) as Vector2i).x), int((snapshot.get("size", Vector2i.ONE) as Vector2i).y)],
			"uses_grid_occupancy": bool(snapshot.get("uses_grid_occupancy", true)),
			"world_pos": [world_pos.x, world_pos.y, world_pos.z],
		})
	return result

func _serialize_floor_materials() -> Array:
	if App.get_room_service() == null or not App.get_room_service().has_method("export_tile_material_overrides"):
		return []
	return App.get_room_service().export_tile_material_overrides()

func _restore_walls(walls: Array) -> void:
	if App.get_wall_service() == null:
		return

	App.get_wall_service().begin_batch()
	for wall_value in walls:
		if not (wall_value is Dictionary):
			continue
		var wall := wall_value as Dictionary
		if not wall.has("from") or not wall.has("to"):
			continue
		var from_tile := _vec2i_from_variant(wall["from"], Vector2i.ZERO)
		var to_tile := _vec2i_from_variant(wall["to"], Vector2i.ZERO)
		var floor_index := int(wall.get("floor", 0))
		App.get_wall_service().place_wall(from_tile, to_tile, floor_index)
	App.get_wall_service().end_batch()

	for wall_value in walls:
		if not (wall_value is Dictionary):
			continue
		var wall := wall_value as Dictionary
		if not wall.has("from") or not wall.has("to"):
			continue
		var from_tile := _vec2i_from_variant(wall["from"], Vector2i.ZERO)
		var to_tile := _vec2i_from_variant(wall["to"], Vector2i.ZERO)
		var floor_index := int(wall.get("floor", 0))
		var wall_key: String = App.get_wall_service().make_key(from_tile, to_tile, floor_index)
		var front_color := _color_from_variant(wall.get("front_color", []), App.get_wall_service().get_default_wall_color())
		var back_color := _color_from_variant(wall.get("back_color", []), App.get_wall_service().get_default_wall_color())
		App.get_wall_service().set_wall_colors_by_key(wall_key, front_color, back_color)

func _restore_openings(openings: Array) -> void:
	if App.get_opening_service() == null:
		return

	for opening_value in openings:
		if not (opening_value is Dictionary):
			continue
		var opening := opening_value as Dictionary
		var wall_key := str(opening.get("wall_key", ""))
		if wall_key == "":
			continue
		App.get_opening_service().place_opening(
			wall_key,
			str(opening.get("type", "door")),
			float(opening.get("offset_t", 0.5)),
			str(opening.get("scene_path", ""))
		)

func _restore_furniture(items: Array) -> void:
	if App.get_furniture_service() == null:
		return

	for item_value in items:
		if not (item_value is Dictionary):
			continue
		var item := item_value as Dictionary
		var tile := _vec2i_from_variant(item.get("tile", []), Vector2i.ZERO)
		var size := _vec2i_from_variant(item.get("size", []), Vector2i.ONE)
		var world_pos := _vec3_from_variant(item.get("world_pos", []), Vector3.ZERO)
		var snapshot := {
			"tile": tile,
			"floor_index": int(item.get("floor_index", 0)),
			"scene_path": str(item.get("scene_path", "")),
			"rotation_index": int(item.get("rotation_index", 0)),
			"size": size,
			"uses_grid_occupancy": bool(item.get("uses_grid_occupancy", true)),
			"world_pos": world_pos,
		}
		App.get_furniture_service().restore_snapshot(snapshot)

func _restore_floor_materials(entries: Array) -> void:
	if App.get_room_service() == null or not App.get_room_service().has_method("apply_tile_material_overrides"):
		return
	App.get_room_service().apply_tile_material_overrides(entries)

func _set_floor(floor_index: int) -> void:
	var clamped := clampi(floor_index, 0, App.get_floor_service().MAX_FLOORS - 1)
	var old_floor: int = int(App.get_floor_service().current_floor)
	if old_floor == clamped:
		return
	App.get_floor_service().current_floor = clamped
	App.get_floor_service().floor_changed.emit(old_floor, clamped)

func _vec2i_from_variant(value: Variant, fallback: Vector2i) -> Vector2i:
	if value is Array:
		var arr: Array = value
		if arr.size() >= 2:
			return Vector2i(int(arr[0]), int(arr[1]))
	if value is Vector2i:
		return value as Vector2i
	return fallback

func _vec3_from_variant(value: Variant, fallback: Vector3) -> Vector3:
	if value is Array:
		var arr: Array = value
		if arr.size() >= 3:
			return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
	if value is Vector3:
		return value as Vector3
	return fallback

func _color_to_array(c: Color) -> Array:
	return [c.r, c.g, c.b, c.a]

func _color_from_variant(value: Variant, fallback: Color) -> Color:
	if value is Array:
		var arr: Array = value
		if arr.size() >= 3:
			return Color(
				float(arr[0]),
				float(arr[1]),
				float(arr[2]),
				float(arr[3]) if arr.size() > 3 else 1.0
			)
	if value is Color:
		return value as Color
	return fallback
