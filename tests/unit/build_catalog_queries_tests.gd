class_name BuildCatalogQueriesTests
extends RefCounted


static func run() -> int:
	var failed := 0

	if BuildCatalogQueries.coerced_vector2i(Vector2i(2, 3)) != Vector2i(2, 3):
		push_error("BuildCatalogQueriesTests: coerced Vector2i passthrough")
		failed += 1
	if BuildCatalogQueries.coerced_vector2i([1.0, 2.0]) != Vector2i(1, 2):
		push_error("BuildCatalogQueriesTests: coerced array floats")
		failed += 1

	var catalog := {
		"categories": [
			{
				"id": "furniture",
				"mode": "furniture",
				"default_item_id": "chair",
				"items": [
					{
						"id": "chair",
						"payload": {"action": "place", "scene_path": "res://x.tscn", "size": [2.0, 1.0]},
					},
				],
			},
		],
	}

	var payload := BuildCatalogQueries.find_furniture_place_payload(catalog, "chair")
	if str(payload.get("scene_path", "")) != "res://x.tscn":
		push_error("BuildCatalogQueriesTests: find payload scene_path")
		failed += 1

	if BuildCatalogQueries.default_furniture_item_id(catalog) != "chair":
		push_error("BuildCatalogQueriesTests: default item id")
		failed += 1

	var args := BuildCatalogQueries.placer_args_from_payload("chair", payload)
	if args.get("size", Vector2i.ZERO) != Vector2i(2, 1):
		push_error("BuildCatalogQueriesTests: placer args size")
		failed += 1
	if str(args.get("item_id", "")) != "chair":
		push_error("BuildCatalogQueriesTests: placer item_id")
		failed += 1

	if not BuildCatalogQueries.find_furniture_place_payload(catalog, "missing").is_empty():
		push_error("BuildCatalogQueriesTests: missing item should be empty")
		failed += 1

	return failed
