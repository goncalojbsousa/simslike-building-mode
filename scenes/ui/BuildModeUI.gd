extends Control

signal mode_requested(mode: String, payload: Dictionary)
signal item_requested(category_id: String, item_id: String, item_data: Dictionary)
signal floor_up_requested
signal floor_down_requested
signal undo_requested
signal redo_requested

@export_file("*.json") var catalog_path: String = "res://data/build_catalog.json"

@onready var category_tabs: HBoxContainer = $FooterPanel/RootMargin/RootVBox/TopBar/CategoryTabs
@onready var floor_down_button: Button = $FooterPanel/RootMargin/RootVBox/TopBar/FloorDownButton
@onready var floor_label: Label = $FooterPanel/RootMargin/RootVBox/TopBar/FloorLabel
@onready var floor_up_button: Button = $FooterPanel/RootMargin/RootVBox/TopBar/FloorUpButton
@onready var undo_button: Button = $FooterPanel/RootMargin/RootVBox/TopBar/UndoButton
@onready var redo_button: Button = $FooterPanel/RootMargin/RootVBox/TopBar/RedoButton
@onready var mode_label: Label = $FooterPanel/RootMargin/RootVBox/CatalogPanel/CatalogMargin/CatalogVBox/ModeLabel
@onready var items_grid: GridContainer = $FooterPanel/RootMargin/RootVBox/CatalogPanel/CatalogMargin/CatalogVBox/ItemsScroll/ItemsGrid
@onready var item_detail_label: Label = $FooterPanel/RootMargin/RootVBox/CatalogPanel/CatalogMargin/CatalogVBox/ItemDetailLabel

var _categories: Array[Dictionary] = []
var _category_buttons: Dictionary = {}
var _item_buttons: Dictionary = {}
var _active_category_id: String = ""
var _active_item_id: String = ""

func _ready() -> void:
	_bind_top_bar_signals()
	_bind_runtime_signals()
	_load_catalog()
	if FloorManager != null:
		_refresh_floor_label(FloorManager.current_floor)
	if UndoHistory != null:
		_refresh_undo_redo_buttons(UndoHistory.can_undo(), UndoHistory.can_redo())

func initialize_selection() -> void:
	if _categories.is_empty():
		return
	var first_id := str(_categories[0].get("id", ""))
	if first_id == "":
		return
	_select_category(first_id, true)

func _bind_top_bar_signals() -> void:
	floor_down_button.pressed.connect(func(): floor_down_requested.emit())
	floor_up_button.pressed.connect(func(): floor_up_requested.emit())
	undo_button.pressed.connect(func(): undo_requested.emit())
	redo_button.pressed.connect(func(): redo_requested.emit())

func _bind_runtime_signals() -> void:
	if FloorManager != null and not FloorManager.floor_changed.is_connected(_on_floor_changed):
		FloorManager.floor_changed.connect(_on_floor_changed)
	if UndoHistory != null and not UndoHistory.history_changed.is_connected(_on_history_changed):
		UndoHistory.history_changed.connect(_on_history_changed)

func _load_catalog() -> void:
	_categories.clear()
	_category_buttons.clear()
	_clear_item_grid()

	if not FileAccess.file_exists(catalog_path):
		push_error("BuildModeUI: catalog file not found: %s" % catalog_path)
		return

	var raw_text := FileAccess.get_file_as_string(catalog_path)
	var parser := JSON.new()
	var parse_err := parser.parse(raw_text)
	if parse_err != OK:
		push_error("BuildModeUI: invalid JSON in %s" % catalog_path)
		return

	var root : Variant = parser.data
	if not (root is Dictionary):
		push_error("BuildModeUI: root JSON must be a Dictionary")
		return

	var categories_value = (root as Dictionary).get("categories", [])
	if not (categories_value is Array):
		push_error("BuildModeUI: categories must be an Array")
		return

	for category_value in categories_value:
		if category_value is Dictionary:
			_categories.append(category_value)

	_build_category_tabs()

func _build_category_tabs() -> void:
	for child in category_tabs.get_children():
		child.queue_free()

	for category in _categories:
		var category_id := str(category.get("id", ""))
		if category_id == "":
			continue
		var label := str(category.get("label", category_id.capitalize()))
		var button := Button.new()
		button.text = label
		button.toggle_mode = true
		button.custom_minimum_size = Vector2(120, 36)
		button.clip_text = true
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(func(): _select_category(category_id, true))
		category_tabs.add_child(button)
		_category_buttons[category_id] = button

func _select_category(category_id: String, emit_mode: bool) -> void:
	var category := _find_category(category_id)
	if category.is_empty():
		return

	_active_category_id = category_id
	_active_item_id = ""
	_update_category_button_state()

	var category_label := str(category.get("label", category_id.capitalize()))
	mode_label.text = "Mode: %s" % category_label
	item_detail_label.text = str(category.get("description", "Select an option."))

	_populate_items(category)

	var items: Array = category.get("items", [])
	if items.is_empty():
		if emit_mode:
			mode_requested.emit(str(category.get("mode", "")), {})
		return

	var default_item_id := str(category.get("default_item_id", ""))
	if default_item_id == "":
		default_item_id = str((items[0] as Dictionary).get("id", ""))
	if default_item_id == "":
		return
	_select_item(category, default_item_id, emit_mode)

func _populate_items(category: Dictionary) -> void:
	_clear_item_grid()
	var items: Array = category.get("items", [])
	for item_value in items:
		if not (item_value is Dictionary):
			continue
		var item := item_value as Dictionary
		var item_id := str(item.get("id", ""))
		if item_id == "":
			continue
		var button := Button.new()
		button.text = str(item.get("label", item_id.capitalize()))
		button.toggle_mode = true
		button.custom_minimum_size = Vector2(150, 56)
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(func(): _select_item(category, item_id, true))
		items_grid.add_child(button)
		_item_buttons[item_id] = button

func _select_item(category: Dictionary, item_id: String, emit_mode: bool) -> void:
	var item := _find_item(category, item_id)
	if item.is_empty():
		return

	_active_item_id = item_id
	_update_item_button_state()

	var description := str(item.get("description", ""))
	if description == "":
		description = str(item.get("label", item_id))
	item_detail_label.text = description

	if not emit_mode:
		return

	var payload := _build_payload(item)
	var mode := str(category.get("mode", ""))
	item_requested.emit(_active_category_id, item_id, item)
	mode_requested.emit(mode, payload)

func _build_payload(item: Dictionary) -> Dictionary:
	var payload: Dictionary = {}
	var raw_payload = item.get("payload", {})
	if raw_payload is Dictionary:
		payload = (raw_payload as Dictionary).duplicate(true)

	if payload.has("size") and payload["size"] is Array:
		var size_array: Array = payload["size"]
		if size_array.size() >= 2:
			payload["size"] = Vector2i(int(size_array[0]), int(size_array[1]))

	if payload.has("material_path"):
		var material_res := load(str(payload["material_path"]))
		if material_res is Material:
			payload["material"] = material_res

	payload["item_id"] = str(item.get("id", ""))
	return payload

func _find_category(category_id: String) -> Dictionary:
	for category in _categories:
		if str(category.get("id", "")) == category_id:
			return category
	return {}

func _find_item(category: Dictionary, item_id: String) -> Dictionary:
	var items: Array = category.get("items", [])
	for item_value in items:
		if item_value is Dictionary and str((item_value as Dictionary).get("id", "")) == item_id:
			return item_value
	return {}

func _update_category_button_state() -> void:
	for category_id in _category_buttons.keys():
		var button: Button = _category_buttons[category_id]
		button.button_pressed = (str(category_id) == _active_category_id)

func _update_item_button_state() -> void:
	for item_id in _item_buttons.keys():
		var button: Button = _item_buttons[item_id]
		button.button_pressed = (str(item_id) == _active_item_id)

func _clear_item_grid() -> void:
	for child in items_grid.get_children():
		child.queue_free()
	_item_buttons.clear()

func _on_floor_changed(_old_floor: int, new_floor: int) -> void:
	_refresh_floor_label(new_floor)

func _on_history_changed(can_undo: bool, can_redo: bool) -> void:
	_refresh_undo_redo_buttons(can_undo, can_redo)

func _refresh_floor_label(floor_index: int) -> void:
	floor_label.text = "Floor %d" % floor_index

func _refresh_undo_redo_buttons(can_undo: bool, can_redo: bool) -> void:
	undo_button.disabled = not can_undo
	redo_button.disabled = not can_redo
