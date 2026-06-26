class_name BuildContext
extends RefCounted

## Application-layer façade: catalog, undo/redo, and **recorded build intents** (history execute).
## Presentation should route reversible edits through `execute` (or `App.execute_build_command`) instead of calling `BuildHistoryService` directly.

var _session: Node


func _init(session: Node) -> void:
	_session = session


func get_furniture_service() -> Node:
	if _session == null:
		return null
	return _session.get("furniture_service") as Node


func get_history_service() -> Node:
	if _session == null:
		return null
	return _session.get("history_service") as Node


func get_build_catalog_service() -> Node:
	if _session == null:
		return null
	return _session.get("build_catalog_service") as Node


func undo() -> void:
	var h := get_history_service()
	if h != null and h.has_method("undo"):
		h.undo()


func redo() -> void:
	var h := get_history_service()
	if h != null and h.has_method("redo"):
		h.redo()


func can_undo() -> bool:
	var h := get_history_service()
	if h != null and h.has_method("can_undo"):
		return bool(h.call("can_undo"))
	return false


func can_redo() -> bool:
	var h := get_history_service()
	if h != null and h.has_method("can_redo"):
		return bool(h.call("can_redo"))
	return false


## Single entry for undoable mutations (command-style do/undo callables).
func execute(label: String, do_action: Callable, undo_action: Callable) -> void:
	var h := get_history_service()
	if h != null and h.has_method("execute"):
		h.execute(label, do_action, undo_action)


func clear_history() -> void:
	var h := get_history_service()
	if h != null and h.has_method("clear"):
		h.clear()


## Normalized keys: scene_path, size (Vector2i), item_id, attachment_slots (Array).
func furniture_placer_activation(item_id: String) -> Dictionary:
	var catalog: Node = get_build_catalog_service()
	if catalog == null or not catalog.has_method("get_furniture_placer_args"):
		return {}
	return catalog.call("get_furniture_placer_args", item_id)


func default_furniture_item_id() -> String:
	var catalog: Node = get_build_catalog_service()
	if catalog == null or not catalog.has_method("get_default_furniture_item_id"):
		return "desk"
	var id := str(catalog.call("get_default_furniture_item_id"))
	return id if id != "" else "desk"
