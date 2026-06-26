class_name GridMath
extends RefCounted

## Pure grid/tile math (world XZ plane). No autoloads — safe for unit tests.

const TILE_SIZE := 2.0


static func world_to_tile(world_pos: Vector3) -> Vector2i:
	return Vector2i(
		floori(world_pos.x / TILE_SIZE),
		floori(world_pos.z / TILE_SIZE)
	)


static func tile_to_world(tile: Vector2i) -> Vector3:
	return Vector3(
		(tile.x + 0.5) * TILE_SIZE,
		0.0,
		(tile.y + 0.5) * TILE_SIZE
	)


static func snap_to_tile_center(world_pos: Vector3) -> Vector3:
	return tile_to_world(world_to_tile(world_pos))
