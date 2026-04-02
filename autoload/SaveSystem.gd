extends Node

const SAVE_DIR := "user://saves"
const DEFAULT_SLOT := "quicksave"

signal save_completed(path: String, success: bool)
signal load_completed(path: String, success: bool)

var _baseline_state_hash: int = 0
var _has_baseline_state: bool = false

func _ready() -> void:
	_refresh_baseline_from_current_state()

func has_unsaved_changes() -> bool:
	if not _has_baseline_state:
		return false
	return _compute_payload_hash(_build_payload()) != _baseline_state_hash

func list_slots() -> Array[String]:
	_ensure_save_dir()
	var slots: Array[String] = []
	var dir := DirAccess.open(SAVE_DIR)
	if dir == null:
		return slots
	for file_name in dir.get_files():
		if not file_name.ends_with(".json"):
			continue
		slots.append(file_name.trim_suffix(".json"))
	slots.sort()
	return slots

func slot_exists(slot_name: String) -> bool:
	var safe_slot := _sanitize_slot_name(slot_name)
	if safe_slot == "":
		safe_slot = DEFAULT_SLOT
	return FileAccess.file_exists("%s/%s.json" % [SAVE_DIR, safe_slot])

func save_to_slot(slot_name: String = DEFAULT_SLOT) -> bool:
	_ensure_save_dir()
	var save_path := _slot_path(slot_name)
	var payload := _build_payload()
	var json_text := JSON.stringify(payload, "\t")
	var file := FileAccess.open(save_path, FileAccess.WRITE)
	if file == null:
		push_error("SaveSystem: could not open save file for writing: %s" % save_path)
		save_completed.emit(save_path, false)
		return false
	file.store_string(json_text)
	file.close()
	_refresh_baseline_from_payload(payload)
	save_completed.emit(save_path, true)
	return true

func load_from_slot(slot_name: String = DEFAULT_SLOT) -> bool:
	var save_path := _slot_path(slot_name)
	if not FileAccess.file_exists(save_path):
		push_warning("SaveSystem: save file not found: %s" % save_path)
		load_completed.emit(save_path, false)
		return false

	var raw_text := FileAccess.get_file_as_string(save_path)
	var parser := JSON.new()
	var parse_err := parser.parse(raw_text)
	if parse_err != OK:
		push_error("SaveSystem: invalid JSON in save file: %s" % save_path)
		load_completed.emit(save_path, false)
		return false

	if not (parser.data is Dictionary):
		push_error("SaveSystem: save payload root must be a Dictionary")
		load_completed.emit(save_path, false)
		return false

	_apply_payload(parser.data as Dictionary)
	_refresh_baseline_from_current_state()
	load_completed.emit(save_path, true)
	return true

func new_build() -> void:
	var session := _session()
	if session != null and session.has_method("reset_build_state"):
		session.call("reset_build_state")
	_refresh_baseline_from_current_state()

func _ensure_save_dir() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SAVE_DIR))

func _slot_path(slot_name: String) -> String:
	var safe_slot := _sanitize_slot_name(slot_name)
	if safe_slot == "":
		safe_slot = DEFAULT_SLOT
	return "%s/%s.json" % [SAVE_DIR, safe_slot]

func _sanitize_slot_name(slot_name: String) -> String:
	var safe_slot := slot_name.strip_edges().to_lower()
	if safe_slot == "":
		return ""
	var blocked := ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
	for token in blocked:
		safe_slot = safe_slot.replace(token, "_")
	return safe_slot

func _compute_payload_hash(payload: Dictionary) -> int:
	return JSON.stringify(payload).hash()

func _refresh_baseline_from_payload(payload: Dictionary) -> void:
	_baseline_state_hash = _compute_payload_hash(payload)
	_has_baseline_state = true

func _refresh_baseline_from_current_state() -> void:
	_refresh_baseline_from_payload(_build_payload())

func _build_payload() -> Dictionary:
	var session := _session()
	if session == null or not session.has_method("build_save_payload"):
		return {}
	var payload_value: Variant = session.call("build_save_payload")
	if payload_value is Dictionary:
		return payload_value as Dictionary
	return {}

func _apply_payload(payload: Dictionary) -> void:
	var session := _session()
	if session == null or not session.has_method("apply_save_payload"):
		return
	session.call("apply_save_payload", payload)

func _session() -> Node:
	var app := get_node_or_null("/root/App")
	if app == null or not app.has_method("get_current_session"):
		return null
	return app.call("get_current_session")
