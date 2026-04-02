class_name BuildHistoryService
extends Node

const MAX_HISTORY := 50

# Each entry is a Dictionary: {do: Callable, undo: Callable, label: String}
var _history: Array[Dictionary] = []
var _redo_stack: Array[Dictionary] = []

signal history_changed(can_undo: bool, can_redo: bool)

func _action_succeeded(result: Variant) -> bool:
	if typeof(result) == TYPE_BOOL:
		return bool(result)
	return true

func execute(label: String, do_action: Callable, undo_action: Callable) -> void:
	if not do_action.is_valid() or not undo_action.is_valid():
		push_error("App.get_history_service(): invalid action callable for '%s'." % label)
		return

	var result: Variant = do_action.call()
	if not _action_succeeded(result):
		push_warning("App.get_history_service(): action '%s' reported failure and was not recorded." % label)
		return

	_history.append({"do": do_action, "undo": undo_action, "label": label})
	_redo_stack.clear()   # new action clears redo branch
	if _history.size() > MAX_HISTORY:
		_history.pop_front()
	_emit_changed()

func undo() -> void:
	if _history.is_empty():
		return
	var entry: Dictionary = _history.pop_back()
	if not entry.has("undo") or not (entry["undo"] is Callable):
		push_error("App.get_history_service(): undo entry is missing a valid callable.")
		_history.append(entry)
		return

	var undo_action: Callable = entry["undo"]
	var result: Variant = undo_action.call()
	if not _action_succeeded(result):
		push_warning("App.get_history_service(): undo action failed and was reverted to history.")
		_history.append(entry)
		return

	_redo_stack.append(entry)
	_emit_changed()

func redo() -> void:
	if _redo_stack.is_empty():
		return
	var entry: Dictionary = _redo_stack.pop_back()
	if not entry.has("do") or not (entry["do"] is Callable):
		push_error("App.get_history_service(): redo entry is missing a valid callable.")
		_redo_stack.append(entry)
		return

	var do_action: Callable = entry["do"]
	var result: Variant = do_action.call()
	if not _action_succeeded(result):
		push_warning("App.get_history_service(): redo action failed and remains in redo stack.")
		_redo_stack.append(entry)
		return

	_history.append(entry)
	_emit_changed()

func can_undo() -> bool:
	return not _history.is_empty()

func can_redo() -> bool:
	return not _redo_stack.is_empty()

func clear() -> void:
	_history.clear()
	_redo_stack.clear()
	_emit_changed()

func _emit_changed() -> void:
	history_changed.emit(can_undo(), can_redo())
