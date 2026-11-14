extends SceneTree

## Milestone 9 check: the layout must stay usable when the window is small
## (PLAN section 7: "window layout at small sizes").
##
## Run with: godot --headless --script tests/check_window_layout.gd
## Instantiates the real main scene, resizes the root window through a range of
## sizes and measures the controls. Exits non-zero on failure.

var failures: int = 0
var checks: int = 0

## Sizes worth testing: the project default, common laptop sizes, and the
## smallest size the app promises to support (main.gd sets Window.min_size).
const SIZES: Array[Vector2i] = [
	Vector2i(1280, 800),
	Vector2i(1152, 720),
	Vector2i(1024, 640),
	Vector2i(900, 560),
]

var main_root: Control


func _init() -> void:
	print("=== go_game window layout check ===")
	_run()


func _run() -> void:
	var scene: PackedScene = load("res://main.tscn")
	if scene == null:
		_fail("main.tscn did not load")
		quit(1)
		return
	main_root = scene.instantiate()
	get_root().add_child(main_root)
	await process_frame
	for size in SIZES:
		await _check_size(size)
	await _check_minimum_setting()
	if failures == 0:
		print("=== %d checks, 0 failed ===" % checks)
		quit(0)
	else:
		print("=== %d checks, %d failed ===" % [checks, failures])
		print("FAILED")
		quit(1)


func _fail(label: String, detail: String = "") -> void:
	failures += 1
	print("  FAIL %s%s" % [label, (" : " + detail) if detail != "" else ""])


func _check(condition: bool, label: String, detail: String = "") -> void:
	checks += 1
	if condition:
		print("  ok   %s%s" % [label, (" : " + detail) if detail != "" else ""])
	else:
		_fail(label, detail)


func _check_size(size: Vector2i) -> void:
	print("--- window %dx%d" % [size.x, size.y])
	get_root().size = size
	await process_frame
	await process_frame
	var label: String = "%dx%d" % [size.x, size.y]

	_check(main_root.size.x > 0 and main_root.size.y > 0, "%s: root has a size" % label, str(main_root.size))
	_check(main_root.board_view != null and main_root.board_view.size.x > 0 and main_root.board_view.size.y > 0,
		"%s: board view still visible" % label, str(main_root.board_view.size))
	var cell: float = main_root.board_view.cell_size()
	_check(cell >= 10.0, "%s: cells stay clickable (%.1f px)" % [label, cell])
	_check(main_root.board_view.size.x <= float(size.x) + 0.5
		and main_root.board_view.size.y <= float(size.y) + 0.5,
		"%s: board view fits the window" % label, str(main_root.board_view.size))

	# The side panel must not be squeezed out of existence: it is inside a
	# ScrollContainer, so it may be taller than the window but must be scrollable.
	var side: Node = main_root.side_scroller
	_check(side != null and side.size.x > 0, "%s: side panel visible" % label,
		str(side.size) if side != null else "missing")
	var menu: Node = main_root.get_node_or_null("Column/Menu")
	_check(menu != null and (menu as Control).size.y > 0, "%s: menu bar visible" % label)

	# Nothing may end up with a negative size, which is how layout bugs show up.
	var worst: String = _scan_negative_sizes(main_root)
	_check(worst == "", "%s: no control has a negative size" % label, worst)

	# The board must still be playable at this size: a click maps to a point.
	var before: int = main_root.flow.move_number()
	main_root.board_view.point_clicked.emit(Coords.from_gtp("Q16", 19))
	await process_frame
	_check(main_root.flow.move_number() == before + 1, "%s: clicking still plays" % label)
	main_root.flow.undo_pair()
	await process_frame


## Walks the tree looking for negative control sizes. Returns "" when clean.
func _scan_negative_sizes(node: Node, depth: int = 0) -> String:
	if depth > 12:
		return ""
	if node is Control:
		var c: Control = node as Control
		if c.size.x < -0.01 or c.size.y < -0.01:
			return "%s has size %s" % [c.name, str(c.size)]
	for child in node.get_children():
		var found: String = _scan_negative_sizes(child, depth + 1)
		if found != "":
			return found
	return ""


## The app must refuse to shrink below the smallest size its layout supports,
## and that size must itself be usable.
func _check_minimum_setting() -> void:
	print("--- minimum window size")
	var window: Window = get_root().get_window()
	var min_size: Vector2i = window.min_size
	_check(min_size.x > 0 and min_size.y > 0,
		"the app declares a minimum window size", "%dx%d" % [min_size.x, min_size.y])
	_check(min_size.x <= 900 and min_size.y <= 560,
		"the minimum is small enough for a laptop window", "%dx%d" % [min_size.x, min_size.y])
	await _check_size(min_size)
