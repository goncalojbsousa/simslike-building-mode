class_name WallKeyTests
extends RefCounted


static func run() -> int:
	var failed := 0
	var a := Vector2i(0, 0)
	var b := Vector2i(1, 0)
	var k0 := WallKey.make_key(a, b, 0)
	if k0 != "0,0|1,0":
		push_error("WallKeyTests: floor 0 key format")
		failed += 1

	var k1 := WallKey.make_key(b, a, 0)
	if k1 != k0:
		push_error("WallKeyTests: key should be canonical for reversed tiles")
		failed += 1

	var kf := WallKey.make_key(a, b, 2)
	if kf != "0,0,2|1,0,2":
		push_error("WallKeyTests: non-zero floor key")
		failed += 1

	if WallKey.floor_from_key("0,0|1,0") != 0:
		push_error("WallKeyTests: floor_from_key ground")
		failed += 1
	if WallKey.floor_from_key("0,0,3|1,0,3") != 3:
		push_error("WallKeyTests: floor_from_key elevated")
		failed += 1

	return failed
