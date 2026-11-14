extends SceneTree

## Milestone 8 check: "add a variation in review, save, reload, and the
## variation is intact."
##
## Drives the real main scene the way a reviewer would: open a test SGF, switch
## to review mode, click an empty point to add a variation, follow an existing
## variation, write a comment, save to disk, then reload from disk and compare.
## Run with: godot --headless --script tests/check_variations.gd

const SAVE_PATH: String = "user://check_variations.sgf"

var failures: int = 0
var checks: int = 0


func _init() -> void:
	print("=== milestone 8 check: variations survive save/reload ===")
	_run()


func _run() -> void:
	var scene: PackedScene = load("res://main.tscn")
	if scene == null:
		_fail("main.tscn did not load")
		quit(1)
		return
	var root: Control = scene.instantiate()
	get_root().add_child(root)
	await process_frame
	await process_frame

	# --- open a real SGF through the app's own open handler -----------------
	var source: String = ProjectSettings.globalize_path("res://testdata/cornermoves.sgf")
	root._on_open_path(source)
	await process_frame
	var flow: RefCounted = root.flow
	_check(int(flow.move_number()) > 0, "the SGF loaded (%d moves)" % int(flow.move_number()))
	var original_nodes: int = int(flow.tree.node_count())
	_check(original_nodes > 1, "the tree has nodes")

	# --- switch to review mode ---------------------------------------------
	root._on_view_menu(22)
	await process_frame
	_check(String(root.mode) == "review", "review mode is on")

	# Step back so the variation branches off a mid-game position.
	for i in int(flow.move_number()) - 1:
		_press(KEY_LEFT)
		await process_frame
	_check(int(flow.move_number()) == 1, "stepped back to the first move")

	# --- click an empty point: that must add a variation, not play a move ---
	var branch_point: RefCounted = flow.current()
	var empty: Vector2i = Coords.from_gtp("Q4", int(flow.tree.size))
	_check(int(flow.board().get_stone(empty.x, empty.y)) == 0, "the clicked point is empty")
	var before: int = int(flow.tree.node_count())
	root.board_view.point_clicked.emit(empty)
	await process_frame
	_check(int(flow.tree.node_count()) == before + 1, "the click added exactly one node")
	_check(flow.current().parent == branch_point, "the new node branches off the shown position")
	_check(flow.current().move_point() == empty, "the new node holds the clicked move")
	_check(int(flow.current().move_color()) == int(flow.tree.turn_at(branch_point)),
		"the variation move has the colour the position calls for")
	_check(int(branch_point.children.size()) == 2, "the position now has two variations")

	# --- a second click on an existing stone follows it, no new node --------
	# Go back to the branching position first: from the new variation, the
	# main-line stone is not a child of the current node, so a click there would
	# correctly open yet another variation instead.
	_press(KEY_LEFT)
	await process_frame
	_check(flow.current() == branch_point, "back at the branching position")
	var main_child: RefCounted = branch_point.children[0]
	root.board_view.point_clicked.emit(main_child.move_point())
	await process_frame
	_check(flow.current() == main_child, "clicking an existing variation follows it")
	_check(int(flow.tree.node_count()) == before + 1, "no extra node was created")

	# --- a comment on the new variation ------------------------------------
	var added: RefCounted = branch_point.children[1]
	root.tree_view.node_clicked.emit(added)
	await process_frame
	_check(flow.current() == added, "clicking the tree node selects the variation")
	var comment: String = "variation idea, saved and reloaded"
	root.comment_edit.text = comment
	root.comment_edit.text_changed.emit()
	await process_frame
	_check(String(flow.current().comment) == comment, "the comment is on the node")

	# --- the tree view shows both lanes ------------------------------------
	var tree_view: Node = root.tree_view
	_check(int(tree_view.node_count()) == int(flow.tree.node_count()),
		"the tree view shows all %d nodes" % int(flow.tree.node_count()))
	_check(int(tree_view.lane_count()) >= 2, "the variation opens a second lane")

	await _finish(root, flow, original_nodes, empty, comment)


func _finish(root: Control, flow: RefCounted, original_nodes: int,
		empty: Vector2i, comment: String) -> void:
	# --- save, then reload from disk ---------------------------------------
	root._on_save_path(SAVE_PATH)
	await process_frame
	var absolute: String = ProjectSettings.globalize_path(SAVE_PATH)
	_check(FileAccess.file_exists(absolute), "the file was written")
	if not FileAccess.file_exists(absolute):
		_report()
		quit(1)
		return

	# Wipe the app back to a fresh game so the reload cannot reuse the tree.
	root._new_game_with({"size": 19, "komi": 6.5, "rules": "japanese",
		"handicap": 0, "profile": "", "black_is_ai": false})
	await process_frame
	_check(int(flow.tree.node_count()) == 1, "the tree is empty before the reload")

	root._on_open_path(absolute)
	await process_frame
	_check(int(flow.tree.node_count()) == original_nodes + 1,
		"the reloaded tree has the added variation (%d nodes)" % int(flow.tree.node_count()))

	# The variation must still be there, in the right place, with its comment.
	var kept: RefCounted = _find_commented(flow.tree.root, comment)
	_check(kept != null, "the commented variation survived the round trip")
	if kept != null:
		_check(kept.move_point() == empty, "the variation move is unchanged")
		_check(int(kept.move_color()) == int(flow.tree.turn_at(kept.parent)),
			"the variation colour is unchanged")
		_check(int(kept.parent.children.size()) == 2, "both variations survived side by side")
	_check(int(flow.tree.size) == 19, "board size survived")
	_check(is_equal_approx(float(flow.tree.komi), 6.5), "komi survived")

	_check_round_trip(absolute)
	await _check_tricky_comment(root, absolute)

	DirAccess.remove_absolute(absolute)
	_report()
	quit(1 if failures > 0 else 0)


## The saved file must parse, re-serialise and re-parse to an identical tree.
func _check_round_trip(absolute: String) -> void:
	var first: Dictionary = SGF.parse_file(absolute)
	_check(bool(first["ok"]), "the saved file parses")
	if not bool(first["ok"]):
		return
	var again: Dictionary = SGF.parse_text(SGF.serialise(first["tree"]))
	_check(bool(again["ok"]), "and re-parses")
	if not bool(again["ok"]):
		return
	var differ: String = _diff(first["tree"].root, again["tree"].root)
	_check(differ == "", "save then re-parse is identical%s"
		% ("" if differ == "" else ": " + differ))


## Comments containing SGF's own metacharacters must survive too.
func _check_tricky_comment(root: Control, absolute: String) -> void:
	var tricky: String = "a ] bracket, a \\ backslash and\na newline"
	root.comment_edit.text = tricky
	root.comment_edit.text_changed.emit()
	await process_frame
	root._on_save_path(absolute)
	await process_frame
	var parsed: Dictionary = SGF.parse_file(absolute)
	_check(bool(parsed["ok"]), "the tricky comment re-parses")
	if not bool(parsed["ok"]):
		print("    error: " + str(parsed["error"]))
		return
	var found: RefCounted = _find_commented(parsed["tree"].root, "a ] bracket")
	_check(found != null, "the tricky comment survived")
	if found != null:
		_check(String(found.comment) == tricky, "the tricky comment is byte-for-byte intact")


func _find_commented(node: RefCounted, wanted: String) -> RefCounted:
	if String(node.comment).contains(wanted):
		return node
	for child in node.children:
		var found: RefCounted = _find_commented(child, wanted)
		if found != null:
			return found
	return null


func _diff(x: RefCounted, y: RefCounted) -> String:
	if (x.move == null) != (y.move == null):
		return "one node has a move, the other does not"
	if x.move != null and (int(x.move["color"]) != int(y.move["color"])
			or x.move_point() != y.move_point()):
		return "move differs"
	if String(x.comment) != String(y.comment):
		return "comment differs"
	if int(x.children.size()) != int(y.children.size()):
		return "%d children vs %d children" % [x.children.size(), y.children.size()]
	for i in int(x.children.size()):
		var reason: String = _diff(x.children[i], y.children[i])
		if reason != "":
			return reason
	return ""


## Key presses go through the root viewport, the same path a real press takes.
## Input.parse_input_event() is ignored when Godot runs with --script.
func _press(keycode: int) -> void:
	var down: InputEventKey = InputEventKey.new()
	down.physical_keycode = keycode
	down.keycode = keycode
	down.pressed = true
	get_root().push_input(down)
	var up: InputEventKey = InputEventKey.new()
	up.physical_keycode = keycode
	up.keycode = keycode
	up.pressed = false
	get_root().push_input(up)


func _check(passed: bool, label: String) -> void:
	checks += 1
	if passed:
		print("  ok   " + label)
	else:
		failures += 1
		print("  FAIL " + label)


func _fail(label: String) -> void:
	checks += 1
	failures += 1
	print("  FAIL " + label)


func _report() -> void:
	print("=== %d checks, %d failed ===" % [checks, failures])
	if failures > 0:
		print("FAILED")

