extends Node

const FLOOR_SERVICE_SCRIPT := preload("res://services/FloorService.gd")
const GRID_SERVICE_SCRIPT := preload("res://services/GridService.gd")
const HISTORY_SERVICE_SCRIPT := preload("res://services/BuildHistoryService.gd")
const OPENING_SERVICE_SCRIPT := preload("res://services/OpeningService.gd")
const WALL_SERVICE_SCRIPT := preload("res://services/WallService.gd")
const FURNITURE_SERVICE_SCRIPT := preload("res://services/FurnitureService.gd")
const ROOM_SERVICE_SCRIPT := preload("res://services/RoomService.gd")
const BUILD_PERSISTENCE_SERVICE_SCRIPT := preload("res://services/BuildPersistenceService.gd")

var build_mode_state: RefCounted = null
var floor_state: RefCounted = null
var grid_state: RefCounted = null
var wall_state: RefCounted = null
var opening_state: RefCounted = null
var furniture_state: RefCounted = null
var build_history_state: RefCounted = null

var floor_service: Node = null
var grid_service: Node = null
var history_service: Node = null
var opening_service: Node = null
var wall_service: Node = null
var furniture_service: Node = null
var room_service: Node = null
var build_persistence_service: Node = null

func _enter_tree() -> void:
	_ensure_states()
	_ensure_services()

func _ensure_states() -> void:
	if build_mode_state == null:
		build_mode_state = _new_state_if_exists("res://state/BuildModeState.gd")
	if floor_state == null:
		floor_state = _new_state_if_exists("res://state/FloorState.gd")
	if grid_state == null:
		grid_state = _new_state_if_exists("res://state/GridState.gd")
	if wall_state == null:
		wall_state = _new_state_if_exists("res://state/WallState.gd")
	if opening_state == null:
		opening_state = _new_state_if_exists("res://state/OpeningState.gd")
	if furniture_state == null:
		furniture_state = _new_state_if_exists("res://state/FurnitureState.gd")
	if build_history_state == null:
		build_history_state = _new_state_if_exists("res://state/BuildHistoryState.gd")

func _ensure_services() -> void:
	if floor_service == null:
		floor_service = _spawn_service(FLOOR_SERVICE_SCRIPT, "FloorService")
	if grid_service == null:
		grid_service = _spawn_service(GRID_SERVICE_SCRIPT, "GridService")
	if history_service == null:
		history_service = _spawn_service(HISTORY_SERVICE_SCRIPT, "BuildHistoryService")
	if opening_service == null:
		opening_service = _spawn_service(OPENING_SERVICE_SCRIPT, "OpeningService")
	if wall_service == null:
		wall_service = _spawn_service(WALL_SERVICE_SCRIPT, "WallService")
	if furniture_service == null:
		furniture_service = _spawn_service(FURNITURE_SERVICE_SCRIPT, "FurnitureService")
	if room_service == null:
		room_service = _spawn_service(ROOM_SERVICE_SCRIPT, "RoomService")
	if build_persistence_service == null:
		build_persistence_service = _spawn_service(BUILD_PERSISTENCE_SERVICE_SCRIPT, "BuildPersistenceService")

func _spawn_service(script_ref: Script, service_name: String) -> Node:
	var service: Node = script_ref.new()
	service.name = service_name
	add_child(service)
	return service

func _new_state_if_exists(path: String) -> RefCounted:
	if not ResourceLoader.exists(path):
		return null
	var script_resource := load(path)
	if not (script_resource is Script):
		return null
	var instance: Variant = (script_resource as Script).new()
	if instance is RefCounted:
		return instance as RefCounted
	return null

func build_save_payload() -> Dictionary:
	if build_persistence_service == null:
		return {}
	if not build_persistence_service.has_method("build_payload"):
		return {}
	return build_persistence_service.call("build_payload")

func apply_save_payload(payload: Dictionary) -> void:
	if build_persistence_service == null:
		return
	if not build_persistence_service.has_method("apply_payload"):
		return
	build_persistence_service.call("apply_payload", payload)

func reset_build_state() -> void:
	if build_persistence_service == null:
		return
	if not build_persistence_service.has_method("new_build"):
		return
	build_persistence_service.call("new_build")
