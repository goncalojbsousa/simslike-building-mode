class_name BuildCatalogService
extends Node

@export_file("*.json") var catalog_path: String = "res://data/build_catalog.json"

var _data: Dictionary = {}


func _ready() -> void:
	reload()


func reload() -> void:
	var raw: Variant = GameDatabase.get_json(catalog_path)
	if raw is Dictionary:
		_data = raw
	else:
		_data = {}


func get_catalog_data() -> Dictionary:
	return _data


func get_default_furniture_item_id() -> String:
	return BuildCatalogQueries.default_furniture_item_id(_data)


func get_furniture_placer_args(item_id: String) -> Dictionary:
	var payload := BuildCatalogQueries.find_furniture_place_payload(_data, item_id)
	if payload.is_empty():
		return {}
	return BuildCatalogQueries.placer_args_from_payload(item_id, payload)
