extends Node3D

# Wall mesh dimensions (in world units)
const WALL_HEIGHT: float  = 3.0
const WALL_THICKNESS: float = 0.15

var _wall_nodes: Dictionary = {}   # wall key -> MeshInstance3D

func _ready() -> void:
	WallSystem.wall_placed.connect(_on_wall_placed)
	WallSystem.wall_removed.connect(_on_wall_removed)

func _on_wall_placed(from_tile: Vector2i, to_tile: Vector2i) -> void:
	var key := WallSystem.make_key(from_tile, to_tile)
	if _wall_nodes.has(key):
		return   # already visualised

	var mesh_instance := MeshInstance3D.new()
	add_child(mesh_instance)

	var box := BoxMesh.new()
	mesh_instance.mesh = box

	# Determine orientation and position
	var from_world : Vector3 = GridManager.tile_to_world(from_tile)
	var to_world   : Vector3 = GridManager.tile_to_world(to_tile)
	var midpoint   : Vector3 = (from_world + to_world) * 0.5
	midpoint.y = WALL_HEIGHT * 0.5

	var diff := to_tile - from_tile

	if diff.x != 0:
		# Neighbor changed in X, so shared edge is parallel to Z.
		box.size = Vector3(WALL_THICKNESS, WALL_HEIGHT, GridManager.TILE_SIZE)
		mesh_instance.rotation_degrees.y = 0.0
	else:
		# Neighbor changed in Y, so shared edge is parallel to X.
		box.size = Vector3(GridManager.TILE_SIZE, WALL_HEIGHT, WALL_THICKNESS)
		mesh_instance.rotation_degrees.y = 0.0

	mesh_instance.position = midpoint
	_wall_nodes[key] = mesh_instance

func _on_wall_removed(from_tile: Vector2i, to_tile: Vector2i) -> void:
	var key := WallSystem.make_key(from_tile, to_tile)
	if _wall_nodes.has(key):
		_wall_nodes[key].queue_free()
		_wall_nodes.erase(key)
