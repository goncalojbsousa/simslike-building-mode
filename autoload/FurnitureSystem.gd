extends Node

# --- Configuration ---
const TILE_SIZE: float = 2.0   # world units per tile (2m × 2m tiles)

# --- Storage ---
# All dictionaries use Vector2i as keys (tile coordinates)
var _tiles: Dictionary = {}       # Vector2i -> TileData
var _occupied: Dictionary = {}    # Vector2i -> bool (quick lookup)

# --- TileData inner class ---
class TileDataClass:
	var tile_pos: Vector2i
	var occupied: bool = false
	var furniture_id: int = -1    # -1 means empty

	func _init(pos: Vector2i) -> void:
		tile_pos = pos

# -------------------------------------------------------
# Coordinate conversion
# -------------------------------------------------------

func world_to_tile(world_pos: Vector3) -> Vector2i:
	return Vector2i(
		floori(world_pos.x / TILE_SIZE),
		floori(world_pos.z / TILE_SIZE)
	)

func tile_to_world(tile: Vector2i) -> Vector3:
	# Returns the CENTER of the tile in world space
	return Vector3(
		(float(tile.x) + 0.5) * TILE_SIZE,
		0.0,
		(float(tile.y) + 0.5) * TILE_SIZE
	)

func snap_to_tile_center(world_pos: Vector3) -> Vector3:
	return tile_to_world(world_to_tile(world_pos))

# -------------------------------------------------------
# Tile state queries
# -------------------------------------------------------

func is_tile_occupied(tile: Vector2i) -> bool:
	return _occupied.get(tile, false)

func get_tile_data(tile: Vector2i) -> TileDataClass:
	if not _tiles.has(tile):
		_tiles[tile] = TileDataClass.new(tile)
	return _tiles[tile]

func set_tile_occupied(tile: Vector2i, occupied: bool) -> void:
	_occupied[tile] = occupied
	get_tile_data(tile).occupied = occupied

# -------------------------------------------------------
# Utility: get all tiles in a rectangular area
# -------------------------------------------------------

func get_tiles_in_rect(from_tile: Vector2i, to_tile: Vector2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var min_x := mini(from_tile.x, to_tile.x)
	var max_x := maxi(from_tile.x, to_tile.x)
	var min_y := mini(from_tile.y, to_tile.y)
	var max_y := maxi(from_tile.y, to_tile.y)
	for x in range(min_x, max_x + 1):
		for y in range(min_y, max_y + 1):
			result.append(Vector2i(x, y))
	return result
