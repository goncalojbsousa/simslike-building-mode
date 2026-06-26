class_name BuildCatalogQueries
extends RefCounted

## Pure queries on catalog JSON (Dictionary). No I/O.


static func find_furniture_place_payload(catalog_data: Dictionary, item_id: String) -> Dictionary:
	for cat in catalog_data.get("categories", []):
		if not (cat is Dictionary):
			continue
		if str(cat.get("mode", "")) != "furniture":
			continue
		for item in cat.get("items", []):
			if not (item is Dictionary):
				continue
			if str(item.get("id", "")) != item_id:
				continue
			var payload: Variant = item.get("payload", {})
			if payload is Dictionary and str(payload.get("action", "")) == "place":
				return payload
	return {}


static func coerced_vector2i(size_variant: Variant) -> Vector2i:
	if size_variant is Vector2i:
		return size_variant
	if size_variant is Vector2:
		var v := size_variant as Vector2
		return Vector2i(int(v.x), int(v.y))
	if size_variant is Array:
		var arr := size_variant as Array
		var w := 1
		var h := 1
		if arr.size() >= 1:
			w = int(float(arr[0]))
		if arr.size() >= 2:
			h = int(float(arr[1]))
		return Vector2i(w, h)
	return Vector2i(1, 1)


static func placer_args_from_payload(item_id: String, payload: Dictionary) -> Dictionary:
	var scene_path := str(payload.get("scene_path", ""))
	var size := coerced_vector2i(payload.get("size", Vector2i(1, 1)))
	var slots: Variant = payload.get("attachment_slots", [])
	var slot_arr: Array = slots if slots is Array else []
	return {
		"scene_path": scene_path,
		"size": size,
		"item_id": item_id,
		"attachment_slots": slot_arr.duplicate(true),
	}


static func default_furniture_item_id(catalog_data: Dictionary) -> String:
	for cat in catalog_data.get("categories", []):
		if not (cat is Dictionary):
			continue
		if str(cat.get("mode", "")) != "furniture":
			continue
		var def := str(cat.get("default_item_id", ""))
		if def != "":
			return def
	return ""
