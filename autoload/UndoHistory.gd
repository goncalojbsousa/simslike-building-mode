extends Node

const MAX_HISTORY := 50

# Each entry is a Dictionary: {do: Callable, undo: Callable, label: String}
var _history: Array[Dictionary] = []
var _redo_stack: Array[Dictionary] = []

signal history_changed(can_undo: bool, can_redo: bool)

func execute(label: String, do_action: Callable, undo_action: Callable) -> void:
	do_action.call()
	_history.append({"do": do_action, "undo": undo_action, "label": label})
	_redo_stack.clear()   # new action clears redo branch
	if _history.size() > MAX_HISTORY:
		_history.pop_front()
	_emit_changed()

func undo() -> void:
	if _history.is_empty():
		return
	var entry: Dictionary = _history.pop_back()
	entry["undo"].call()
	_redo_stack.append(entry)
	_emit_changed()

func redo() -> void:
	if _redo_stack.is_empty():
		return
	var entry: Dictionary = _redo_stack.pop_back()
	entry["do"].call()
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
