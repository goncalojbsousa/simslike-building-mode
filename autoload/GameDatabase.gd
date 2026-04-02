extends Node

var _cache: Dictionary = {}

func get_json(path: String) -> Variant:
	if _cache.has(path):
		return _cache[path]
	if not FileAccess.file_exists(path):
		return null
	var raw := FileAccess.get_file_as_string(path)
	var parser := JSON.new()
	if parser.parse(raw) != OK:
		return null
	_cache[path] = parser.data
	return parser.data

func clear_cache() -> void:
	_cache.clear()
