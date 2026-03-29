extends Node3D


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass
	
	
func _unhandled_input(event: InputEvent) -> void:
	if _is_history_shortcut_pressed(event, "undo", "ui_undo"):
		UndoHistory.undo()
	elif _is_history_shortcut_pressed(event, "redo", "ui_redo"):
		UndoHistory.redo()

func _is_history_shortcut_pressed(event: InputEvent, primary: StringName, fallback: StringName) -> bool:
	if InputMap.has_action(primary) and event.is_action_pressed(primary):
		return true

	if InputMap.has_action(fallback) and event.is_action_pressed(fallback):
		return true

	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo:
			var ctrl_or_cmd := key_event.ctrl_pressed or key_event.meta_pressed
			if ctrl_or_cmd and primary == "undo" and key_event.keycode == KEY_Z:
				return true
			if ctrl_or_cmd and primary == "redo":
				if key_event.keycode == KEY_Y:
					return true
				if key_event.shift_pressed and key_event.keycode == KEY_Z:
					return true

	return false
