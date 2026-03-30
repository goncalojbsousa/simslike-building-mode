extends Node

@export var mouse_raycast: Node
@export var active: bool = false

var current_material: Material = null

func activate(mat: Material) -> void:
	current_material = mat
	active = true

func deactivate() -> void:
	active = false

func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return
	if event is InputEventKey:
		var ke := event as InputEventKey
		if ke.pressed and ke.keycode == KEY_ESCAPE:
			deactivate()
			return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			deactivate()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_paint_tile()

func _paint_tile() -> void:
	var tile  : Vector2i = mouse_raycast.get_tile_under_mouse()
	var floor_index := FloorManager.current_floor
	var mat   := current_material
	var old_mat := RoomSystem.get_tile_material(tile, floor_index)

	UndoHistory.execute(
		"paint floor tile",
		func(): RoomSystem.set_tile_material(tile, floor_index, mat),
		func(): RoomSystem.set_tile_material(tile, floor_index, old_mat)
	)
