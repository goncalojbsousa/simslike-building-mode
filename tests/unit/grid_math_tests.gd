class_name GridMathTests
extends RefCounted


static func run() -> int:
	var failed := 0
	if GridMath.world_to_tile(Vector3(0.0, 0.0, 0.0)) != Vector2i(0, 0):
		push_error("GridMathTests: world_to_tile origin")
		failed += 1
	if GridMath.world_to_tile(Vector3(2.5, 0.0, 4.9)) != Vector2i(1, 2):
		push_error("GridMathTests: world_to_tile positive")
		failed += 1
	var t := Vector2i(3, -1)
	var w := GridMath.tile_to_world(t)
	if not is_equal_approx(w.x, 7.0) or not is_equal_approx(w.z, -1.0):
		push_error("GridMathTests: tile_to_world center")
		failed += 1
	var snapped := GridMath.snap_to_tile_center(Vector3(0.9, 0.0, 1.1))
	if GridMath.world_to_tile(snapped) != Vector2i(0, 0):
		push_error("GridMathTests: snap round-trip")
		failed += 1
	if not is_equal_approx(GridMath.TILE_SIZE, 2.0):
		push_error("GridMathTests: TILE_SIZE")
		failed += 1
	return failed
