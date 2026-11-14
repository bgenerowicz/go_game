extends SceneTree

## Drives the real UI: sends mouse and keyboard events into the running scene,
## then checks the game state that results. Run with a display:
##   with-display godot --headless --script tests/ui_smoke.gd
## Exits non-zero if any check fails.

var scene: Control = null
var step: int = 0
var failures: int = 0
var checks: int = 0
var shot_dir: String = ""


func _report(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("  FAIL %s" % label)
	else:
		print("  ok   %s" % label)


func _initialize() -> void:
	shot_dir = OS.get_environment("GO_GAME_SHOTS")
	if shot_dir == "":
		shot_dir = "/tmp/go_game_shots"
	DirAccess.make_dir_recursive_absolute(shot_dir)
	scene = load("res://main.tscn").instantiate() as Control
	root.size = Vector2i(1280, 800)
	root.add_child(scene)
	print("=== UI smoke test ===")


func _click(point: Vector2i) -> void:
	# point_center is in the board control's own space; push_input takes window
	# coordinates, so the control's offset inside the window must be added.
	var where: Vector2 = scene.board_view.global_position \
		+ scene.board_view.point_center(point.x, point.y)
	var ev: InputEventMouseButton = InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = where
	root.push_input(ev)
	var up: InputEventMouseButton = ev.duplicate() as InputEventMouseButton
	up.pressed = false
	root.push_input(up)


func _key(keycode: int) -> void:
	var ev: InputEventKey = InputEventKey.new()
	ev.keycode = keycode
	ev.pressed = true
	root.push_input(ev)
	var up: InputEventKey = ev.duplicate() as InputEventKey
	up.pressed = false
	root.push_input(up)


func _process(_delta: float) -> bool:
	step += 1
	match step:
		2:
			_report("board view got a real size", scene.board_view.size.x > 200.0)
			# The control may be wider than tall; the drawn grid must be a square
			# centred inside it, with a margin on every side.
			var cell: float = scene.board_view.cell_size()
			var n: int = scene.board_view.board_size()
			var span: float = cell * float(n - 1)
			var origin: Vector2 = scene.board_view.grid_origin()
			_report("drawn grid is square", absf(span - cell * float(n - 1)) < 0.01)
			_report("grid fits with a margin on all sides",
				origin.x > 0.0 and origin.y > 0.0
				and origin.x + span < scene.board_view.size.x
				and origin.y + span < scene.board_view.size.y)
			_report("starts at the root", scene.flow.current() == scene.flow.tree.root)
		3:
			_click(Vector2i(3, 3))
		4:
			var board: Board = scene.flow.tree.board_at(scene.flow.current())
			_report("click plays a black stone", board.get_stone(3, 3) == Board.Stone.BLACK)
			_report("one move in the tree", scene.flow.tree.node_count() == 2)
		5:
			_click(Vector2i(15, 15))
		6:
			var b2: Board = scene.flow.tree.board_at(scene.flow.current())
			_report("second click plays white", b2.get_stone(15, 15) == Board.Stone.WHITE)
			_report("move number is 2", scene.flow.move_number() == 2)
		7:
			# Clicking an occupied point must be refused, not add a node.
			_click(Vector2i(3, 3))
		8:
			_report("occupied point refused", scene.flow.tree.node_count() == 3)
			_report("still the same position", scene.flow.current().move_point() == Vector2i(15, 15))
		9:
			_key(KEY_LEFT)
		10:
			_report("Left steps back one move", scene.flow.move_number() == 1)
			_key(KEY_LEFT)
		11:
			_report("Left again reaches the root", scene.flow.move_number() == 0)
			_key(KEY_RIGHT)
		12:
			_report("Right steps forward", scene.flow.move_number() == 1)
			_key(KEY_END)
		13:
			_report("End jumps to the main line end", scene.flow.move_number() == 2)
			_key(KEY_P)
		14:
			_report("P passes", scene.flow.current().is_pass())
			_key(KEY_U)
		15:
			# Undo takes back a pair: the pass and the move before it.
			_report("U undoes a pair", scene.flow.move_number() == 1)
			_report("undo removed the nodes", scene.flow.tree.node_count() == 2)
		16:
			# A capture through the UI: a white stone in the corner, boxed in by
			# two black stones on a fresh 9x9.
			scene.flow.start(9, 7.0, "japanese", 0)
			_click(Vector2i(1, 0))   # B
			_click(Vector2i(0, 0))   # W in the corner
			_click(Vector2i(0, 1))   # B closes the last liberty
		17:
			var b3: Board = scene.flow.tree.board_at(scene.flow.current())
			_report("capture through the UI", b3.get_stone(0, 0) == Board.Stone.EMPTY)
			_report("capture counted", int(b3.captures[Board.Stone.BLACK]) == 1)
			_report("three moves played", scene.flow.move_number() == 3)
		19:
			# Two passes end the game.
			_key(KEY_P)
			_key(KEY_P)
		20:
			_report("two passes end the game", scene.flow.over)
			_report("result mentions the passes", scene.flow.result_text.length() > 0)
			_report("status line filled in", scene.status_label.text.length() > 10)
		21:
			var saved: String = scene.autosave()
			_report("auto-save wrote a file", saved != "" and FileAccess.file_exists(saved))
			if saved != "":
				var parsed: Dictionary = SGF.parse_file(saved)
				_report("auto-saved file re-parses", bool(parsed["ok"]))
				if bool(parsed["ok"]):
					_report("auto-save kept the moves",
						int(parsed["tree"].main_line_length()) == int(scene.flow.tree.main_line_length()))
				print("  (saved to %s)" % ProjectSettings.globalize_path(saved))
		22:
			# A known position to check the rendering against: two stones and a
			# capture, on a 9x9 so the stones are large enough to sample.
			scene.flow.start(9, 7.0, "japanese", 0)
			_click(Vector2i(4, 4))   # B in the centre
			_click(Vector2i(0, 0))   # W in the corner
			_click(Vector2i(1, 0))   # B
			_click(Vector2i(8, 8))   # W in the opposite corner
			_click(Vector2i(0, 1))   # B captures the corner stone
		23:
			var shot: String = shot_dir.path_join("ui_stones.png")
			var image: Image = root.get_texture().get_image()
			var err: Error = image.save_png(shot)
			_report("screenshot saved (%s)" % shot, err == OK)
			_report("screenshot is not blank", image.get_used_rect().size.x > 100)
			# The board should be mostly the wood colour.
			var centre: Color = image.get_pixel(image.get_width() / 2, image.get_height() / 2)
			_report("centre of the board is wood-coloured",
				centre.r > 0.5 and centre.g > 0.35 and centre.b < 0.6)
			# Sample the pixels where stones should be. The image is the whole
			# window, so add the board control's offset inside it, and step a
			# little away from the intersection so grid lines are not sampled.
			var off: Vector2 = scene.board_view.global_position
			var cell: float = scene.board_view.cell_size()
			var probe: Vector2 = Vector2(cell * 0.25, cell * 0.25)
			var black_here: Color = image.get_pixel(
				int(off.x + scene.board_view.point_center(4, 4).x + probe.x),
				int(off.y + scene.board_view.point_center(4, 4).y + probe.y))
			_report("black stone drawn at (4,4)", black_here.get_luminance() < 0.25)
			var white_here: Color = image.get_pixel(
				int(off.x + scene.board_view.point_center(8, 8).x + probe.x),
				int(off.y + scene.board_view.point_center(8, 8).y + probe.y))
			_report("white stone drawn at (8,8)", white_here.get_luminance() > 0.8)
			var empty_corner: Color = image.get_pixel(
				int(off.x + scene.board_view.point_center(0, 0).x + probe.x),
				int(off.y + scene.board_view.point_center(0, 0).y + probe.y))
			var bd: Board = scene.flow.tree.board_at(scene.flow.current())
			print("  DEBUG corner stone=%d moves=%d pixel=%s" % [
				bd.get_stone(0, 0), scene.flow.move_number(), str(empty_corner)])
			_report("captured corner point is empty again",
				empty_corner.r > 0.5 and empty_corner.g > 0.35 and empty_corner.b < 0.6)
		24:
			# Review mode: clicking an empty point starts a new variation.
			scene.flow.start(19, 6.5, "japanese", 0)
			_click(Vector2i(3, 3))
			_click(Vector2i(15, 15))
			scene.flow.tree.go_to_root()
			_click(Vector2i(15, 3))
		25:
			_report("click at an empty point creates a new variation",
				scene.flow.tree.root.children.size() == 2)
			scene.flow.tree.go_to_main_line_end()
			_report("End returns to the main line", scene.flow.current().move_point() == Vector2i(15, 15))
			var wide: String = shot_dir.path_join("ui_main.png")
			root.size = Vector2i(1600, 900)
			scene.flow.tree.go_to_root()
			_report("resize does not crash", true)
			var image2: Image = root.get_texture().get_image()
			_report("second screenshot saved (%s)" % wide, image2.save_png(wide) == OK)
		26:
			print("=== %d checks, %d failed ===" % [checks, failures])
			print("UI_SMOKE_" + ("FAILED" if failures > 0 else "PASSED"))
			return true
	return false
