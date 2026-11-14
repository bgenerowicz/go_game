extends SceneTree

## Headless test runner: godot --headless --script tests/run_tests.gd
## Discovers every tests/test_*.gd, runs its run(a) method, exits non-zero on failure.

const TEST_DIR: String = "res://tests"


func _init() -> void:
	var version: Dictionary = Engine.get_version_info()
	print("=== go_game tests (Godot %s) ===" % str(version.get("string", "?")))
	var a: Assertions = Assertions.new()
	a.tree = self
	for path in _module_paths():
		print("--- module %s" % path.get_file())
		var script: GDScript = load(path)
		if script == null or not script.can_instantiate():
			a.check(false, "could not load %s" % path)
			continue
		var module: RefCounted = script.new()
		module.a = a
		module.run()
	print("=== %d checks, %d passed, %d failed ===" % [a.checks, a.passed, a.failed])
	if a.failed > 0:
		print("FAILED")
	quit(0 if a.failed == 0 else 1)


func _module_paths() -> Array[String]:
	var out: Array[String] = []
	var dir: DirAccess = DirAccess.open(TEST_DIR)
	if dir == null:
		print("cannot open %s" % TEST_DIR)
		return out
	var listing: Array = Array(dir.get_files())
	listing.sort()
	for name in listing:
		var file_name: String = String(name)
		if not file_name.begins_with("test_") or not file_name.ends_with(".gd"):
			continue
		out.append(TEST_DIR + "/" + file_name)
	return out
