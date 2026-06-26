extends SceneTree

## Headless: godot --path . -s res://tests/run_all.gd

func _initialize() -> void:
	var failures := GridMathTests.run()
	failures += BuildCatalogQueriesTests.run()
	failures += WallKeyTests.run()
	if failures > 0:
		push_error("Tests failed: %d assertion group(s)." % failures)
	quit(0 if failures == 0 else 1)
