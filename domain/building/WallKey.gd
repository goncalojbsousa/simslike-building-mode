extends RefCounted

static func make_key(a: Vector2i, b: Vector2i, floor_index: int) -> String:
	if a.x < b.x or (a.x == b.x and a.y < b.y):
		if floor_index == 0:
			return "%d,%d|%d,%d" % [a.x, a.y, b.x, b.y]
		return "%d,%d,%d|%d,%d,%d" % [a.x, a.y, floor_index, b.x, b.y, floor_index]
	if floor_index == 0:
		return "%d,%d|%d,%d" % [b.x, b.y, a.x, a.y]
	return "%d,%d,%d|%d,%d,%d" % [b.x, b.y, floor_index, a.x, a.y, floor_index]

static func floor_from_key(key: String) -> int:
	var parts := key.split("|")
	if parts.size() != 2:
		return 0
	var coords := parts[0].split(",")
	if coords.size() == 2:
		return 0
	if coords.size() == 3:
		return int(coords[2])
	return 0
