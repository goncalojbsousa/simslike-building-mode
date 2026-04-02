extends Node

signal session_changed(old_session: Node, new_session: Node)

const GAME_SESSION_SCRIPT := preload("res://session/GameSession.gd")

var current_session: Node = null

func _ready() -> void:
	start_new_session()

func start_new_session() -> Node:
	var old_session := current_session
	if is_instance_valid(old_session):
		remove_child(old_session)
		old_session.queue_free()

	current_session = GAME_SESSION_SCRIPT.new()
	current_session.name = "GameSession"
	add_child(current_session)
	session_changed.emit(old_session, current_session)
	return current_session

func get_current_session() -> Node:
	return current_session

func get_floor_service() -> Node:
	if current_session == null:
		return null
	return current_session.get("floor_service")

func get_grid_service() -> Node:
	if current_session == null:
		return null
	return current_session.get("grid_service")

func get_history_service() -> Node:
	if current_session == null:
		return null
	return current_session.get("history_service")

func get_opening_service() -> Node:
	if current_session == null:
		return null
	return current_session.get("opening_service")

func get_wall_service() -> Node:
	if current_session == null:
		return null
	return current_session.get("wall_service")

func get_furniture_service() -> Node:
	if current_session == null:
		return null
	return current_session.get("furniture_service")

func get_room_service() -> Node:
	if current_session == null:
		return null
	return current_session.get("room_service")

func get_build_persistence_service() -> Node:
	if current_session == null:
		return null
	return current_session.get("build_persistence_service")
