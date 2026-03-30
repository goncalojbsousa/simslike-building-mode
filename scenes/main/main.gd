# Main.gd — full replacement
extends Node3D

@onready var wall_placer: Node = get_node_or_null("WallPlacer")
@onready var furniture_placer: Node = get_node_or_null("FurniturePlacer")
@onready var opening_placer: Node = get_node_or_null("OpeningPlacer")
@onready var floor_painter: Node = get_node_or_null("FloorPainter")
@onready var ground_grid: Node3D = get_node_or_null("Ground") as Node3D

const FURNITURE_CATALOG := {
	"desk": { "scene": "res://scenes/furniture/Desk.tscn", "size": Vector2i(1, 2) },
}

func _ready() -> void:
	FloorManager.floor_changed.connect(_on_floor_changed)
	_update_grid_floor_height()
	_activate_wall_mode()

func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	var ke := event as InputEventKey
	if not ke.pressed:
		return

	match ke.keycode:
		KEY_1: _activate_wall_mode()
		KEY_2: _activate_furniture_mode("desk")
		KEY_3: _activate_opening_mode("door")
		KEY_4: _activate_opening_mode("window")
		KEY_5: _activate_floor_paint_mode()
		KEY_Q: FloorManager.go_down()
		KEY_E: FloorManager.go_up()
		KEY_Z:
			if ke.ctrl_pressed or ke.meta_pressed:
				UndoHistory.undo()
		KEY_Y:
			if ke.ctrl_pressed or ke.meta_pressed:
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

func _activate_opening_mode(key: String) -> void:
	_deactivate_all()
	if opening_placer != null and opening_placer.has_method("activate"):
		opening_placer.activate(key)

func _activate_floor_paint_mode() -> void:
	_deactivate_all()
	if floor_painter == null or not floor_painter.has_method("activate"):
		return
	var mat: Material = RoomSystem.default_floor_material
	if mat == null:
		mat = load("res://materials/WallPreview.tres")
	if mat != null:
		floor_painter.activate(mat)

func _deactivate_all() -> void:
	_safe_deactivate(wall_placer)
	_safe_deactivate(furniture_placer)
	_safe_deactivate(opening_placer)
	_safe_deactivate(floor_painter)

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
