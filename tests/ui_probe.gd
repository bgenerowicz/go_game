extends SceneTree

## Visual capture for milestone 3 and later: runs the real main scene on a display, drives it
## with real mouse and keyboard events at pixel coordinates (so the geometry
## mapping is exercised, not just the signals), and saves screenshots.
##
## Run with: with-display runtime/godot-4.7.2/Godot_v4.7.2-stable_linux.x86_64 \
##             --script tests/ui_probe.gd
##
## Not part of the headless suite (it needs a display); used for measured checks.

var steps: int = 0
var scene: Control
var board_view: Control
var saved: Array[String] = []


func _init() -> void:
	DirAccess.make_dir_absolute("/tmp/shots")
	get_root().size = Vector2i(1280, 800)
	scene = load("res://main.tscn").instantiate() as Control
	get_root().add_child(scene)


func _process(_delta: float) -> bool:
	steps += 1
	if steps == 5:
		board_view = scene.get_node("Column/Body/Board")
		print("PROBE window=", get_root().get_visible_rect().size,
			" board=", board_view.size, " cell=%.1f" % board_view.cell_size())
		_shot("empty")
	elif steps == 10:
		_click_point(Vector2i(3, 3))
	elif steps == 14:
		_click_point(Vector2i(15, 15))
	elif steps == 18:
		_click_point(Vector2i(3, 15))
	elif steps == 22:
		_shot("three moves")
	elif steps == 26:
		# A real click on an occupied point must be refused, not crash.
		_click_point(Vector2i(3, 3))
	elif steps == 30:
		_key(KEY_LEFT)
	elif steps == 34:
		_key(KEY_RIGHT)
	elif steps == 38:
		_key(KEY_P)
	elif steps == 42:
		_hover(Vector2i(9, 9))
	elif steps == 46:
		_shot("after keys and a pass")
	elif steps == 50:
		_report()
		return true
	return false


## A real mouse click on the pixel centre of a board intersection.
func _click_point(point: Vector2i) -> void:
	var at: Vector2 = board_view.point_center(point.x, point.y) + board_view.global_position
	var press: InputEventMouseButton = InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = at
	press.global_position = at
	Input.parse_input_event(press)
	var release: InputEventMouseButton = InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = at
	release.global_position = at
	Input.parse_input_event(release)


func _hover(point: Vector2i) -> void:
	var at: Vector2 = board_view.point_center(point.x, point.y) + board_view.global_position
	var motion: InputEventMouseMotion = InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	Input.parse_input_event(motion)


func _key(keycode: int) -> void:
	var press: InputEventKey = InputEventKey.new()
	press.keycode = keycode
	press.physical_keycode = keycode
	press.pressed = true
	Input.parse_input_event(press)
	var release: InputEventKey = InputEventKey.new()
	release.keycode = keycode
	release.physical_keycode = keycode
	release.pressed = false
	Input.parse_input_event(release)


func _shot(label: String) -> void:
	var image: Image = get_root().get_viewport().get_texture().get_image()
	var path: String = "/tmp/shots/probe-%s.png" % label
	image.save_png(path)
	saved.append(path)
	print("shot %s -> %s (%d x %d)" % [label, path, image.get_width(), image.get_height()])


func _report() -> void:
	var flow = scene.flow
	var board = flow.board()
	print("PROBE move_number=%d turn=%s over=%s nodes=%d stones_b=%d stones_w=%d" % [
		flow.move_number(),
		"B" if flow.turn() == Board.Stone.BLACK else "W",
		str(flow.over),
		flow.tree.node_count(),
		board.stone_count(Board.Stone.BLACK),
		board.stone_count(Board.Stone.WHITE),
	])
	print("PROBE status=%s" % scene.status_label.text.replace("\n", " | "))
	print("PROBE shots=%s" % str(saved))
	quit(0)
