# Main.gd — full replacement
extends Node3D

@onready var wall_placer: Node = get_node_or_null("WallPlacer")
@onready var wall_painter: Node = get_node_or_null("WallPainter")
@onready var furniture_placer: Node = get_node_or_null("FurniturePlacer")
@onready var opening_placer: Node = get_node_or_null("OpeningPlacer")
@onready var floor_painter: Node = get_node_or_null("FloorPainter")
@onready var room_editor: Node = get_node_or_null("RoomEditor")
@onready var mouse_raycast: Node = get_node_or_null("MouseRaycast")
@onready var ground_grid: Node3D = get_node_or_null("Ground") as Node3D
@onready var build_mode_ui: Control = get_node_or_null("CanvasLayer/BuildModeUi") as Control

const FURNITURE_CATALOG := {
	"desk": { "scene": "res://scenes/furniture/Desk.tscn", "size": Vector2i(1, 2) },
}

var _unsaved_confirm_dialog: ConfirmationDialog = null
var _pending_destructive_action: Dictionary = {}

func _ready() -> void:
	App.get_floor_service().floor_changed.connect(_on_floor_changed)
	_update_grid_floor_height()
	_bind_ui_signals()
	_bind_save_system_signals()
	_setup_unsaved_confirm_dialog()
	if build_mode_ui != null and build_mode_ui.has_method("initialize_selection"):
		build_mode_ui.call("initialize_selection")
	else:
		_activate_wall_mode()

func _bind_save_system_signals() -> void:
	var save_system := get_node_or_null("/root/SaveSystem")
	if save_system == null:
		return
	if save_system.has_signal("save_completed") and not save_system.save_completed.is_connected(_on_save_completed):
		save_system.save_completed.connect(_on_save_completed)
	if save_system.has_signal("load_completed") and not save_system.load_completed.is_connected(_on_load_completed):
		save_system.load_completed.connect(_on_load_completed)

func _setup_unsaved_confirm_dialog() -> void:
	var canvas_layer := get_node_or_null("CanvasLayer")
	if canvas_layer == null:
		return
	_unsaved_confirm_dialog = ConfirmationDialog.new()
	_unsaved_confirm_dialog.title = "Unsaved Changes"
	_unsaved_confirm_dialog.dialog_text = "You have unsaved changes. Continue?"
	_unsaved_confirm_dialog.confirmed.connect(_on_unsaved_confirmed)
	(canvas_layer as Node).add_child(_unsaved_confirm_dialog)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_clear_catalog_option_selection()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_apply_auto_context_from_click()
			return

	if not event is InputEventKey:
		return
	var ke := event as InputEventKey
	if not ke.pressed:
		return
	if ke.keycode == KEY_ESCAPE:
		_clear_catalog_option_selection()
		return

	match ke.keycode:
		KEY_Q: App.get_floor_service().go_down()
		KEY_E: App.get_floor_service().go_up()
		KEY_Z:
			if ke.ctrl_pressed or ke.meta_pressed:
				App.get_history_service().undo()
		KEY_Y:
			if ke.ctrl_pressed or ke.meta_pressed:
				App.get_history_service().redo()
		KEY_F11:
			var window := get_window()
			if window:
				window.mode = Window.MODE_FULLSCREEN if window.mode != Window.MODE_FULLSCREEN else Window.MODE_WINDOWED

func _bind_ui_signals() -> void:
	if build_mode_ui == null:
		return
	if build_mode_ui.has_signal("mode_requested") and not build_mode_ui.mode_requested.is_connected(_on_ui_mode_requested):
		build_mode_ui.mode_requested.connect(_on_ui_mode_requested)
	if build_mode_ui.has_signal("floor_up_requested") and not build_mode_ui.floor_up_requested.is_connected(_on_ui_floor_up_requested):
		build_mode_ui.floor_up_requested.connect(_on_ui_floor_up_requested)
	if build_mode_ui.has_signal("floor_down_requested") and not build_mode_ui.floor_down_requested.is_connected(_on_ui_floor_down_requested):
		build_mode_ui.floor_down_requested.connect(_on_ui_floor_down_requested)
	if build_mode_ui.has_signal("undo_requested") and not build_mode_ui.undo_requested.is_connected(_on_ui_undo_requested):
		build_mode_ui.undo_requested.connect(_on_ui_undo_requested)
	if build_mode_ui.has_signal("redo_requested") and not build_mode_ui.redo_requested.is_connected(_on_ui_redo_requested):
		build_mode_ui.redo_requested.connect(_on_ui_redo_requested)
	if build_mode_ui.has_signal("new_requested") and not build_mode_ui.new_requested.is_connected(_on_ui_new_requested):
		build_mode_ui.new_requested.connect(_on_ui_new_requested)
	if build_mode_ui.has_signal("save_requested") and not build_mode_ui.save_requested.is_connected(_on_ui_save_requested):
		build_mode_ui.save_requested.connect(_on_ui_save_requested)
	if build_mode_ui.has_signal("load_requested") and not build_mode_ui.load_requested.is_connected(_on_ui_load_requested):
		build_mode_ui.load_requested.connect(_on_ui_load_requested)

func _on_ui_mode_requested(mode: String, payload: Dictionary) -> void:
	if str(payload.get("action", "")) == "default_select_move":
		_activate_default_select_move()
		return

	match mode:
		"structure":
			_activate_structure_from_payload(payload)
		"wall":
			_activate_wall_from_payload(payload)
		"furniture":
			_activate_furniture_from_payload(payload)
		"furniture_delete":
			_activate_furniture_delete_mode()
		"opening":
			_activate_opening_from_payload(payload)
		"wall_paint":
			_activate_wall_paint_from_payload(payload)
		"floor_paint":
			_activate_floor_paint_from_payload(payload)
		"room_edit":
			_activate_room_edit_from_payload(payload)

func _activate_structure_from_payload(payload: Dictionary) -> void:
	var action := str(payload.get("action", "room_select"))
	match action:
		"default_select_move":
			_activate_default_select_move()
		"room_select":
			_activate_room_edit_mode()
		"room_delete_selected":
			_activate_room_edit_from_payload({"action": "delete_selected"})
		"wall_select":
			_activate_wall_mode("select")
		"wall_rectangle":
			_activate_wall_mode("room")
		"wall_delete":
			_activate_wall_mode("delete")
		_:
			_activate_wall_mode("")

func _apply_auto_context_from_click() -> void:
	if build_mode_ui == null or mouse_raycast == null:
		return
	if _is_auto_context_locked_by_current_tool():
		return

	if _focus_furniture_context_from_click():
		return
	if _focus_wall_context_from_click():
		return
	if _focus_room_context_from_click():
		return

	if build_mode_ui.has_method("set_selection_context"):
		build_mode_ui.call("set_selection_context", "none")

func _is_auto_context_locked_by_current_tool() -> bool:
	if build_mode_ui == null:
		return false
	if not build_mode_ui.has_method("get_active_category_id") or not build_mode_ui.has_method("get_active_item_id"):
		return false

	var category_id := str(build_mode_ui.call("get_active_category_id"))
	var item_id := str(build_mode_ui.call("get_active_item_id"))
	if item_id == "":
		return false

	if category_id == "structure":
		return item_id == "structure_wall_draw" or item_id == "structure_wall_rectangle" or item_id == "structure_wall_delete"

	if category_id == "furniture":
		return item_id != "furniture_select_move"

	return false

func _focus_furniture_context_from_click() -> bool:
	var floor_index: int = int(App.get_floor_service().current_floor)
	var world_pos: Vector3 = mouse_raycast.get_world_position_under_mouse()
	var snapshot: Dictionary = App.get_furniture_service().get_snapshot_at_world(world_pos, floor_index)
	if snapshot.is_empty():
		return false

	if build_mode_ui.has_method("select_context_item"):
		build_mode_ui.call("select_context_item", "furniture", "furniture_select_move", true)
	if build_mode_ui.has_method("set_selection_context"):
		build_mode_ui.call("set_selection_context", "furniture")
	return true

func _focus_room_context_from_click() -> bool:
	var tile: Vector2i = mouse_raycast.get_tile_under_mouse()
	var floor_index: int = int(App.get_floor_service().current_floor)
	if App.get_wall_service().get_room_id_for_tile(tile, floor_index) == -1:
		return false

	if build_mode_ui.has_method("select_context_item"):
		build_mode_ui.call("select_context_item", "structure", "structure_room_select", true)
	if build_mode_ui.has_method("set_selection_context"):
		build_mode_ui.call("set_selection_context", "room")
	return true

func _focus_wall_context_from_click() -> bool:
	var tile: Vector2i = mouse_raycast.get_tile_under_mouse()
	var floor_index: int = int(App.get_floor_service().current_floor)
	var offsets := [
		Vector2i(1, 0),
		Vector2i(-1, 0),
		Vector2i(0, 1),
		Vector2i(0, -1),
	]

	for offset in offsets:
		if App.get_wall_service().has_wall(tile, tile + offset, floor_index):
			if build_mode_ui.has_method("select_context_item"):
				build_mode_ui.call("select_context_item", "structure", "structure_wall_select", true)
			if build_mode_ui.has_method("set_selection_context"):
				build_mode_ui.call("set_selection_context", "wall")
			return true

	return false

func _on_ui_floor_up_requested() -> void:
	App.get_floor_service().go_up()

func _on_ui_floor_down_requested() -> void:
	App.get_floor_service().go_down()

func _on_ui_undo_requested() -> void:
	App.get_history_service().undo()

func _on_ui_redo_requested() -> void:
	App.get_history_service().redo()

func _on_ui_new_requested() -> void:
	_request_destructive_action("new", "")

func _on_ui_save_requested(slot_name: String) -> void:
	var save_system := get_node_or_null("/root/SaveSystem")
	if save_system != null and save_system.has_method("save_to_slot"):
		save_system.call("save_to_slot", slot_name)

func _on_ui_load_requested(slot_name: String) -> void:
	_request_destructive_action("load", slot_name)

func _request_destructive_action(action: String, slot_name: String) -> void:
	var save_system := get_node_or_null("/root/SaveSystem")
	if save_system != null and save_system.has_method("has_unsaved_changes"):
		if bool(save_system.call("has_unsaved_changes")):
			_pending_destructive_action = {
				"action": action,
				"slot_name": slot_name,
			}
			if _unsaved_confirm_dialog != null:
				var target := "start a new build" if action == "new" else "load '%s'" % slot_name
				_unsaved_confirm_dialog.dialog_text = "You have unsaved changes. Continue and %s?" % target
				_unsaved_confirm_dialog.popup_centered()
				return
	_execute_destructive_action(action, slot_name)

func _on_unsaved_confirmed() -> void:
	var action := str(_pending_destructive_action.get("action", ""))
	var slot_name := str(_pending_destructive_action.get("slot_name", ""))
	_pending_destructive_action.clear()
	if action == "":
		return
	_execute_destructive_action(action, slot_name)

func _execute_destructive_action(action: String, slot_name: String) -> void:
	var save_system := get_node_or_null("/root/SaveSystem")
	if save_system == null:
		return
	if action == "new" and save_system.has_method("new_build"):
		save_system.call("new_build")
		_show_ui_status("Started new build.")
	elif action == "load" and save_system.has_method("load_from_slot"):
		save_system.call("load_from_slot", slot_name)

func _on_save_completed(path: String, success: bool) -> void:
	if success:
		_show_ui_status("Saved to %s" % path)
	else:
		_show_ui_status("Save failed for %s" % path, true)
	_refresh_ui_slots()

func _on_load_completed(path: String, success: bool) -> void:
	if success:
		_show_ui_status("Loaded %s" % path)
	else:
		_show_ui_status("Load failed for %s" % path, true)
	_refresh_ui_slots()

func _refresh_ui_slots() -> void:
	if build_mode_ui != null and build_mode_ui.has_method("refresh_slot_picker"):
		build_mode_ui.call("refresh_slot_picker")

func _show_ui_status(message: String, is_error: bool = false) -> void:
	if build_mode_ui != null and build_mode_ui.has_method("show_status"):
		build_mode_ui.call("show_status", message, is_error)

func _activate_wall_from_payload(payload: Dictionary) -> void:
	var action := str(payload.get("action", "draw"))
	if action == "rectangle":
		_activate_wall_mode("room")
		return
	if action == "delete":
		_activate_wall_mode("delete")
		return
	_activate_wall_mode("")

func _activate_wall_mode(action: String = "") -> void:
	_deactivate_all()
	if wall_placer != null and wall_placer.has_method("activate"):
		wall_placer.activate(action)

func _activate_furniture_mode(key: String) -> void:
	_deactivate_all()
	var item: Dictionary = FURNITURE_CATALOG.get(key, {})
	if item.is_empty() or furniture_placer == null:
		return
	if furniture_placer.has_method("activate"):
		furniture_placer.activate(item["scene"], item["size"])

func _activate_furniture_from_payload(payload: Dictionary) -> void:
	var action := str(payload.get("action", "place"))
	if action == "default_select_move":
		_activate_default_select_move()
		return
	if action == "delete":
		_activate_furniture_delete_mode()
		return
	if action == "edit":
		_activate_furniture_edit_mode()
		return

	var scene_path := str(payload.get("scene_path", ""))
	var size : Variant = payload.get("size", Vector2i(1, 1))
	if scene_path == "":
		_activate_furniture_mode("desk")
		return
	if not (size is Vector2i):
		size = Vector2i(1, 1)
	_deactivate_all()
	if furniture_placer != null and furniture_placer.has_method("activate"):
		furniture_placer.activate(scene_path, size)

func _activate_furniture_edit_mode() -> void:
	_deactivate_all()
	if furniture_placer != null and furniture_placer.has_method("activate_edit_mode"):
		furniture_placer.activate_edit_mode()

func _activate_furniture_delete_mode() -> void:
	_deactivate_all()
	if furniture_placer != null and furniture_placer.has_method("activate_delete_mode"):
		furniture_placer.activate_delete_mode()

func _activate_opening_mode(key: String) -> void:
	_deactivate_all()
	if opening_placer != null and opening_placer.has_method("activate"):
		opening_placer.activate(key)

func _activate_opening_from_payload(payload: Dictionary) -> void:
	var opening_key := str(payload.get("opening_key", "door"))
	_activate_opening_mode(opening_key)

func _activate_floor_paint_mode() -> void:
	_deactivate_all()
	if floor_painter == null or not floor_painter.has_method("activate"):
		return
	var mat: Material = App.get_room_service().default_floor_material
	if mat == null:
		mat = load("res://materials/WallPreview.tres")
	if mat != null:
		floor_painter.activate(mat)

func _activate_floor_paint_from_payload(payload: Dictionary) -> void:
	_deactivate_all()
	if floor_painter == null or not floor_painter.has_method("activate"):
		return

	var mat: Material = null
	if bool(payload.get("use_room_default", true)):
		mat = App.get_room_service().default_floor_material

	if mat == null and payload.has("material") and payload["material"] is Material:
		mat = payload["material"]

	if mat == null and payload.has("color") and payload["color"] is Array:
		var color_arr: Array = payload["color"]
		if color_arr.size() >= 3 and App.get_room_service() != null and App.get_room_service().has_method("create_tinted_floor_material"):
			var color := Color(
				float(color_arr[0]),
				float(color_arr[1]),
				float(color_arr[2]),
				float(color_arr[3]) if color_arr.size() > 3 else 1.0
			)
			mat = App.get_room_service().create_tinted_floor_material(color)

	if mat == null and payload.has("material_path"):
		var loaded := load(str(payload.get("material_path", "")))
		if loaded is Material:
			mat = loaded

	if mat == null:
		mat = load("res://materials/WallPreview.tres")

	if mat != null:
		floor_painter.activate(mat)

func _activate_wall_paint_from_payload(payload: Dictionary) -> void:
	_deactivate_all()
	if wall_painter == null or not wall_painter.has_method("activate"):
		return

	var color : Color = App.get_wall_service().get_default_wall_color()
	if payload.has("color") and payload["color"] is Array:
		var color_arr: Array = payload["color"]
		if color_arr.size() >= 3:
			color = Color(
				float(color_arr[0]),
				float(color_arr[1]),
				float(color_arr[2]),
				float(color_arr[3]) if color_arr.size() > 3 else 1.0
			)

	wall_painter.activate(color)

func _activate_room_edit_mode() -> void:
	_deactivate_all()
	if room_editor != null and room_editor.has_method("activate"):
		room_editor.activate()

func _activate_default_select_move() -> void:
	_deactivate_all()
	if room_editor != null and room_editor.has_method("activate"):
		room_editor.activate()
	if build_mode_ui != null and build_mode_ui.has_method("set_selection_context"):
		build_mode_ui.call("set_selection_context", "none")

func _clear_catalog_option_selection() -> void:
	if build_mode_ui == null:
		return
	if build_mode_ui.has_method("clear_active_item_selection"):
		build_mode_ui.call("clear_active_item_selection", true)

func _activate_room_edit_from_payload(payload: Dictionary) -> void:
	_activate_room_edit_mode()
	var action := str(payload.get("action", "select"))
	if action != "delete_selected":
		return
	if room_editor != null and room_editor.has_method("delete_selected_rooms"):
		var deleted := bool(room_editor.call("delete_selected_rooms"))
		if not deleted:
			_show_ui_status("No selected room to delete.", true)

func _deactivate_all() -> void:
	_safe_deactivate(wall_placer)
	_safe_deactivate(wall_painter)
	_safe_deactivate(furniture_placer)
	_safe_deactivate(opening_placer)
	_safe_deactivate(floor_painter)
	_safe_deactivate(room_editor)

func _safe_deactivate(node: Node) -> void:
	if node != null and node.has_method("deactivate"):
		node.deactivate()

func _on_floor_changed(_old_floor: int, _new_floor: int) -> void:
	_update_grid_floor_height()

func _update_grid_floor_height() -> void:
	if ground_grid == null:
		return
	# Keep the grid slightly above the active build floor to avoid z-fighting.
	var p := ground_grid.position
	p.y = App.get_floor_service().get_current_y_offset() + 0.01
	ground_grid.position = p
