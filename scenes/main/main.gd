# Main.gd — full replacement
extends Node3D

@onready var wall_placer: Node = get_node_or_null("WallPlacer")
@onready var wall_painter: Node = get_node_or_null("WallPainter")
@onready var furniture_placer: Node = get_node_or_null("FurniturePlacer")
@onready var opening_placer: Node = get_node_or_null("OpeningPlacer")
@onready var floor_painter: Node = get_node_or_null("FloorPainter")
@onready var room_editor: Node = get_node_or_null("RoomEditor")
@onready var ground_grid: Node3D = get_node_or_null("Ground") as Node3D
@onready var build_mode_ui: Control = get_node_or_null("CanvasLayer/BuildModeUi") as Control

const FURNITURE_CATALOG := {
	"desk": { "scene": "res://scenes/furniture/Desk.tscn", "size": Vector2i(1, 2) },
}

func _ready() -> void:
	FloorManager.floor_changed.connect(_on_floor_changed)
	_update_grid_floor_height()
	_bind_ui_signals()
	if build_mode_ui != null and build_mode_ui.has_method("initialize_selection"):
		build_mode_ui.call("initialize_selection")
	else:
		_activate_wall_mode()

func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	var ke := event as InputEventKey
	if not ke.pressed:
		return

	match ke.keycode:
		KEY_Q: FloorManager.go_down()
		KEY_E: FloorManager.go_up()
		KEY_Z:
			if ke.ctrl_pressed or ke.meta_pressed:
				UndoHistory.undo()
		KEY_Y:
			if ke.ctrl_pressed or ke.meta_pressed:
				UndoHistory.redo()
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

func _on_ui_mode_requested(mode: String, payload: Dictionary) -> void:
	match mode:
		"wall":
			_activate_wall_mode()
		"furniture":
			_activate_furniture_from_payload(payload)
		"opening":
			_activate_opening_from_payload(payload)
		"wall_paint":
			_activate_wall_paint_from_payload(payload)
		"floor_paint":
			_activate_floor_paint_from_payload(payload)
		"room_edit":
			_activate_room_edit_mode()

func _on_ui_floor_up_requested() -> void:
	FloorManager.go_up()

func _on_ui_floor_down_requested() -> void:
	FloorManager.go_down()

func _on_ui_undo_requested() -> void:
	UndoHistory.undo()

func _on_ui_redo_requested() -> void:
	UndoHistory.redo()

func _activate_wall_mode() -> void:
	_deactivate_all()
	if wall_placer != null and wall_placer.has_method("activate"):
		wall_placer.activate()

func _activate_furniture_mode(key: String) -> void:
	_deactivate_all()
	var item: Dictionary = FURNITURE_CATALOG.get(key, {})
	if item.is_empty() or furniture_placer == null:
		return
	if furniture_placer.has_method("activate"):
		furniture_placer.activate(item["scene"], item["size"])

func _activate_furniture_from_payload(payload: Dictionary) -> void:
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
	var mat: Material = RoomSystem.default_floor_material
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
		mat = RoomSystem.default_floor_material

	if mat == null and payload.has("material") and payload["material"] is Material:
		mat = payload["material"]

	if mat == null and payload.has("color") and payload["color"] is Array:
		var color_arr: Array = payload["color"]
		if color_arr.size() >= 3 and RoomSystem != null and RoomSystem.has_method("create_tinted_floor_material"):
			var color := Color(
				float(color_arr[0]),
				float(color_arr[1]),
				float(color_arr[2]),
				float(color_arr[3]) if color_arr.size() > 3 else 1.0
			)
			mat = RoomSystem.create_tinted_floor_material(color)

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

	var color := WallSystem.get_default_wall_color()
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
	p.y = FloorManager.get_current_y_offset() + 0.01
	ground_grid.position = p
