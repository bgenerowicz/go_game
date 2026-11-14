extends SceneTree

## Headless smoke test for the milestone 3 UI: loads the real main scene, drives
## it the way a player would (clicks, keys, menus, save/load) and checks results.
## Run with: godot --headless --script tests/smoke_ui.gd
##
## Separate from run_tests.gd because it needs a running scene tree and a frame
## loop, which the pure-logic runner does not have.

var failures: int = 0
var checks: int = 0
var finished: bool = false

## A script error inside the coroutine below aborts it, which would otherwise
## leave the frame loop (and any engine child process) running forever.
const WATCHDOG_SECONDS: float = 240.0


func _init() -> void:
	print("=== go_game UI smoke test ===")
	_start_watchdog()
	_run()


var _watchdog: Timer = null


func _start_watchdog() -> void:
	# A Timer node under root rather than create_timer(): a SceneTreeTimer that is
	# still pending at exit is reported as a leaked ObjectDB instance, and it
	# cannot be released early because it is a RefCounted (free() is an error).
	# A node is freed together with the tree, and can be stopped here.
	_watchdog = Timer.new()
	_watchdog.name = "SmokeWatchdog"
	_watchdog.wait_time = WATCHDOG_SECONDS
	_watchdog.one_shot = true
	root.add_child(_watchdog)
	_watchdog.timeout.connect(_on_watchdog_timeout)
	_watchdog.start()


func _on_watchdog_timeout() -> void:
	if finished:
		return
	failures += 1
	print("  FAIL smoke test never reached the end within %d seconds" % int(WATCHDOG_SECONDS))
	print("=== %d smoke checks, %d failed ===" % [checks, failures])
	quit(1)


func _run() -> void:
	var scene: PackedScene = load("res://main.tscn")
	if scene == null:
		_fail("main.tscn did not load")
		_bail()
		return
	var root: Control = scene.instantiate()
	get_root().add_child(root)
	await process_frame
	await process_frame

	if root.get("flow") == null:
		_fail("main scene has no flow member")
		_bail()
		return
	var flow: RefCounted = root.flow
	var board_view: Node = root.board_view

	# --- the board view is on screen and sized -------------------------------
	_check(board_view.size.x > 100.0 and board_view.size.y > 100.0,
		"board view has a real size: %s" % str(board_view.size))
	var cell: float = board_view.cell_size()
	_check(cell > 5.0, "cell size is usable: %.1f" % cell)

	# --- clicking plays stones ----------------------------------------------
	# move_number() counts moves played, so it is 0 on an empty board.
	var q16: Vector2i = Coords.from_gtp("Q16", 19)
	var d4: Vector2i = Coords.from_gtp("D4", 19)
	_check(flow.move_number() == 0, "no moves played yet")
	board_view.point_clicked.emit(q16)
	await process_frame
	_check(flow.move_number() == 1, "one stone played after a click")
	board_view.point_clicked.emit(d4)
	await process_frame
	_check(flow.move_number() == 2, "two stones played after two clicks")
	var board: RefCounted = flow.board()
	_check(board.get_stone(q16.x, q16.y) == 1, "Q16 holds a black stone")
	_check(board.get_stone(d4.x, d4.y) == 2, "D4 holds a white stone")

	# --- an illegal click is refused, not applied ----------------------------
	var before: int = flow.move_number()
	board_view.point_clicked.emit(q16)
	await process_frame
	_check(flow.move_number() == before, "clicking an occupied point does nothing")

	# --- keyboard navigation ------------------------------------------------
	_press(KEY_LEFT)
	await process_frame
	_check(flow.move_number() == 1, "Left steps one move back")
	_press(KEY_HOME)
	await process_frame
	_check(flow.move_number() == 0, "Home goes to the start")
	_press(KEY_END)
	await process_frame
	_check(flow.move_number() == 2, "End goes to the main line end")
	_press(KEY_RIGHT)
	await process_frame
	_check(flow.move_number() == 2, "Right at the end stays put")

	# --- pass and undo ------------------------------------------------------
	_press(KEY_P)
	await process_frame
	_press(KEY_P)
	await process_frame
	_check(flow.over, "two passes end the game")
	_check(flow.result_text == "two passes", "result text after two passes")
	_check(flow.move_number() == 4, "the two passes are moves in the tree")
	root._on_undo()
	await process_frame
	_check(not flow.over, "undo reopens the game")
	_check(flow.move_number() == 2, "undo took back the two passes")


	# --- save, reload, compare ----------------------------------------------
	var tmp: String = "/tmp/go_game_smoke.sgf"
	_check(SGF.save_file(tmp, flow.tree), "saved the game to %s" % tmp)
	var text: String = ""
	var f: FileAccess = FileAccess.open(tmp, FileAccess.READ)
	if f != null:
		text = f.get_as_text()
		f.close()
	_check(text.contains("SZ[19]"), "saved file records the board size")
	_check(text.contains("B[pd]"), "saved file records B[pd] for Q16")
	_check(text.contains("W[dp]"), "saved file records W[dp] for D4")

	root._on_open_path(tmp)
	await process_frame
	_check(flow.move_number() == 2, "reloaded game is at the same position")
	var reloaded: RefCounted = flow.board()
	_check(reloaded.get_stone(q16.x, q16.y) == 1, "reloaded board keeps Q16")

	# --- loading a real fixture ---------------------------------------------
	root._on_open_path("res://testdata/messy.sgf")
	await process_frame
	var tree: RefCounted = flow.tree
	_check(tree.size == 9, "messy.sgf loads as 9x9")
	_check(tree.node_count() > 20, "the whole variation tree loaded")
	# PLAN 6.2 info panel: player names come from the SGF PB/PW properties.
	var players: Node = root.get_node_or_null("Column/Body/SideScroller/Side/Players")
	_check(players != null, "the info panel has a player names label")
	if players != null:
		_check(str(players.text).contains("Black"), "player names mention Black")
		_check(str(players.text).contains("White"), "player names mention White")
		_check(str(players.text).contains("(engine)") == false,
			"no engine marker in a two-human game")
	_press(KEY_DOWN)
	await process_frame
	_press(KEY_UP)
	await process_frame

	# --- review mode: clicking a stone jumps to that variation ---------------
	root.mode = "review"
	var root_node: RefCounted = tree.root
	var kids: Array = root_node.children
	_check(kids.size() == 3, "messy.sgf has three variations under the root")
	if kids.size() >= 3:
		# Go back to the start first: a review click follows a child of the
		# *current* node, which is how the interaction works for a real player.
		_press(KEY_HOME)
		await process_frame
		_check(tree.current == root_node, "Home returns to the root")
		# messy.sgf's second root variation is setup-only (AB[] with no move),
		# so it cannot be selected by clicking a point. Use the third, B[ia].
		var target: RefCounted = kids[2]
		_check(target.move != null, "the third variation has a real move")
		var point: Vector2i = target.move_point()
		_check(point == Vector2i(8, 0), "B[ia] on 9x9 is (8,0), got %s" % str(point))
		board_view.point_clicked.emit(point)
		await process_frame
		_check(tree.current == target, "review click followed that variation")
		# Up/down switch between sibling variations.
		_press(KEY_DOWN)
		await process_frame
		_check(tree.current == kids[0], "Down moved to the next variation")
		_press(KEY_UP)
		await process_frame
		_check(tree.current == target, "Up moved back to the previous variation")

	# --- autosave writes a file ---------------------------------------------
	_check(String(root.autosave()) != "", "autosave wrote a file")

	# --- the menu bar is wired up --------------------------------------------
	var menu: Node = root.get_node_or_null("Column/Menu")
	_check(menu != null, "menu bar exists")
	if menu != null:
		_check(menu.get_child_count() == 4, "four top-level menus, got %d" % menu.get_child_count())
		var titles: Array[String] = []
		for child in menu.get_children():
			titles.append(String(child.name))
		_check(titles == ["Game", "File", "View", "Review"],
			"menu titles are Game/File/View/Review, got %s" % str(titles))

	# --- the new game dialog offers a game and starts it ---------------------
	root._open_new_game_dialog()
	await process_frame
	var dialog: Node = root.get_node_or_null("NewGameDialog")
	_check(dialog != null, "new game dialog was created")
	if dialog != null:
		# Ask for a 13x13 chinese-rules game and confirm it.
		dialog.size_box.selected = 1
		dialog.komi_box.text = "7.5"
		dialog.rules_box.selected = 1
		dialog.confirmed.emit()
		dialog.hide()  # pressing OK hides the dialog in the real app
		await process_frame
		_check(int(root.flow.tree.size) == 13, "dialog started a 13x13 game")
		_check(is_equal_approx(float(root.flow.tree.komi), 7.5), "dialog applied komi 7.5")
		_check(String(root.flow.tree.rules) == "chinese", "dialog applied chinese rules")
		_check(root.flow.tree.board_at(root.flow.current()).size == 13,
			"the board view follows the new size")
		# A handicap game places stones and drops komi to 0.5 by default.
		root._open_new_game_dialog()
		await process_frame
		dialog.size_box.selected = 0
		dialog.komi_box.text = "6.5"
		dialog.rules_box.selected = 0
		dialog.handicap_box.value = 5
		dialog.engine_box.button_pressed = false  # two humans, no engine
		dialog.confirmed.emit()
		dialog.hide()  # pressing OK hides the dialog in the real app
		await process_frame
		_check(int(root.flow.tree.handicap) == 5, "handicap recorded as 5")
		var start_board: Board = root.flow.tree.board_at(root.flow.current())
		_check(start_board.stone_count(Board.Stone.BLACK) == 5, "five handicap stones placed")
		_check(is_equal_approx(float(root.flow.tree.komi), 0.5), "handicap komi defaults to 0.5")
		_check(root.ai_side == 0, "no opponent chosen, so two humans")
		# Choosing a strength arms the opponent, and the human colour decides
		# which side it plays.
		root._open_new_game_dialog()
		await process_frame
		dialog.engine_box.button_pressed = true
		dialog.style_box.selected = 0  # "rank" (modern style)
		dialog.rank_box.selected = 4
		dialog.colour_box.selected = 1  # the human plays White
		dialog.confirmed.emit()
		dialog.hide()  # pressing OK hides the dialog in the real app
		await process_frame
		_check(root.ai_side == Board.Stone.BLACK, "the opponent plays the other colour")
		_check(String(root.ai.sl_profile()) == "rank_5k", "the opponent profile is rank_5k")
		# The human playing Black hands the opponent the white stones.
		root._open_new_game_dialog()
		await process_frame
		dialog.engine_box.button_pressed = true
		dialog.style_box.selected = 1  # "preaz" (pre-AI style)
		dialog.rank_box.selected = 2
		dialog.colour_box.selected = 0  # the human plays Black
		dialog.confirmed.emit()
		dialog.hide()
		await process_frame
		_check(root.ai_side == Board.Stone.WHITE, "the opponent takes White")
		_check(String(root.ai.sl_profile()) == "preaz_10k", "the profile carries the style")
		# Back to a plain 9x9 game for the checks that follow.
		root._new_game_with({"size": 9, "komi": 6.5, "rules": "japanese",
			"handicap": 0, "profile": "", "human_colour": "white"})
		await process_frame
		_check(int(root.flow.tree.size) == 9, "back to 9x9")
		_check(root.ai_side == 0, "opponent cleared")

	# --- the status labels say something useful ------------------------------
	_check(String(root.status_label.text).contains("9 x 9"), "status line shows the board size")
	_check(String(root.captures_label.text).contains("Captured by Black"), "captures line present")

	# --- the move tree view (milestone 8) -----------------------------------
	var tree_view: Node = root.get("tree_view")
	_check(tree_view != null, "the main scene has a tree view")
	if tree_view != null:
		_check(root.get_node_or_null("Column/TreeStrip") != null,
			"the tree view sits in a scrollable strip")
		# Play a game with a variation so the layout has something to show.
		root._new_game_with({"size": 9, "komi": 6.5, "rules": "japanese",
			"handicap": 0, "profile": "", "black_is_ai": false})
		await process_frame
		var tv_flow: RefCounted = root.flow
		tv_flow.play(4, 4)
		tv_flow.play(2, 2)
		tv_flow.tree.go_to(tv_flow.current().parent)
		tv_flow.add_variation(6, 6)   # a sibling variation
		tv_flow.tree.go_to_main_line_end()
		await process_frame
		_check(int(tree_view.node_count()) == int(tv_flow.tree.node_count()),
			"the tree view shows every node (%d of %d)"
			% [int(tree_view.node_count()), int(tv_flow.tree.node_count())])
		_check(int(tree_view.lane_count()) >= 2, "the variation opens a second row")
		# The main line runs horizontally: its nodes share one row.
		var line: Array = tv_flow.tree.main_line()
		var first_entry: Dictionary = tree_view.entry_for(line[1])
		var second_entry: Dictionary = tree_view.entry_for(line[2])
		_check(not first_entry.is_empty() and not second_entry.is_empty(),
			"main line nodes have entries")
		if not first_entry.is_empty() and not second_entry.is_empty():
			_check(is_equal_approx(float(first_entry["y"]), float(second_entry["y"])),
				"main line nodes sit on the same row")
			_check(float(second_entry["x"]) > float(first_entry["x"]),
				"the main line grows to the right")
		# Clicking a node in the tree jumps to it.
		var target: RefCounted = line[1]
		var entry: Dictionary = tree_view.entry_for(target)
		var hit: RefCounted = tree_view.node_at_position(
			Vector2(float(entry["x"]), float(entry["y"])))
		_check(hit == target, "a click at the node position finds that node")
		_check(tree_view.node_at_position(Vector2(-50, -50)) == null,
			"a click on empty space finds nothing")
		tv_flow.tree.go_to_main_line_end()
		await process_frame
		tree_view.node_clicked.emit(target)
		await process_frame
		_check(tv_flow.current() == target, "clicking a tree node moved the cursor")
		tree_view.scroll_to_current()
		await process_frame
		_check(true, "scroll_to_current did not crash")

	# --- the comment box writes into the SGF C property ---------------------
	var comment_edit: Node = root.get("comment_edit")
	_check(comment_edit != null, "the side panel has a comment box")
	if comment_edit != null:
		# Put the cursor on a real move first: the root is a legitimate place to
		# comment too, and commenting there would make the next checks vacuous.
		root.flow.tree.go_to_main_line_end()
		await process_frame
		_check(int(root.flow.move_number()) > 0, "the cursor is on a move, not the root")
		comment_edit.text = "a note about this position"
		# Assigning TextEdit.text does not emit text_changed (only a user edit
		# does), so emit it the way the widget would.
		comment_edit.text_changed.emit()
		await process_frame
		_check(String(root.flow.current().comment) == "a note about this position",
			"typing in the box stored the comment on the node")
		var written: String = SGF.serialise(root.flow.tree)
		_check(written.contains("C[a note about this position]"),
			"the comment reaches the serialised SGF")
		# Navigating away and back reloads the text from the tree. Keys are used
		# rather than raw tree calls because they go through the refresh path.
		var direct: InputEventKey = InputEventKey.new()
		direct.keycode = KEY_HOME
		direct.pressed = true
		root._input(direct)
		await process_frame
		_press(KEY_HOME)
		await process_frame
		_check(int(root.flow.move_number()) == 0,
			"the Home key returns to the root (move number %d)" % int(root.flow.move_number()))
		_check(String(comment_edit.text) == "",
			"the box clears at the root (was <%s>)" % String(comment_edit.text))
		_press(KEY_END)
		await process_frame
		_check(int(root.flow.move_number()) > 0,
			"the End key returns to the main line end (move number %d)"
			% int(root.flow.move_number()))
		_check(String(comment_edit.text) == "a note about this position",
			"the box refills when returning to the commented node")
		# While typing, the letter shortcuts must not fire.
		comment_edit.grab_focus()
		await process_frame
		var moves_before_typing: int = int(root.flow.move_number())
		_press(KEY_P)
		await process_frame
		_check(int(root.flow.move_number()) == moves_before_typing,
			"the P shortcut stays off while the comment box has focus")
		comment_edit.release_focus()
		await process_frame

	# --- review mode: click an empty point to add a variation, Delete to undo
	root.mode = "review"
	await process_frame
	var before_nodes: int = int(root.flow.tree.node_count())
	root.board_view.point_clicked.emit(Vector2i(1, 7))
	await process_frame
	_check(int(root.flow.tree.node_count()) == before_nodes + 1,
		"a review-mode click on an empty point added a variation")
	_press(KEY_DELETE)
	await process_frame
	_check(int(root.flow.tree.node_count()) == before_nodes,
		"Delete removed the variation again (%d of %d nodes, current move %d)"
		% [int(root.flow.tree.node_count()), before_nodes, int(root.flow.move_number())])

	# --- the milestone 8 check: add a variation, save, reload, still intact ---
	var roundtrip_path: String = "/tmp/go_game_milestone8.sgf"
	root.flow.add_variation(1, 7)
	var commented: GameNode = root.flow.current()
	var variation_colour: int = int(commented.move["color"])
	root.flow.set_comment("a variation note")
	await process_frame
	var nodes_before_save: int = int(root.flow.tree.node_count())
	var variations_before: int = int(root.flow.current().parent.children.size())
	root._on_save_path(roundtrip_path)
	await process_frame
	_check(FileAccess.file_exists(roundtrip_path), "the review game was saved")
	root._on_open_path(roundtrip_path)
	await process_frame
	_check(int(root.flow.tree.node_count()) == nodes_before_save,
		"reloading kept every node (%d of %d)"
		% [int(root.flow.tree.node_count()), nodes_before_save])
	_check(int(root.flow.current().parent.children.size()) == variations_before,
		"the variation is still there after a save and reload")
	_check(String(root.flow.current().comment) == "a variation note",
		"the comment survived the save and reload")
	_check(root.flow.tree.board_at(root.flow.current()).get_stone(1, 7) == variation_colour,
		"the variation move is on the board after reloading")
	root.mode = "play"
	await process_frame

	# --- the settings dialog: paths, status, restart, stderr tail -----------
	# It is built on first use, so open it through the menu that offers it.
	root._on_review_menu(32)
	await process_frame
	var settings_dialog: Node = root.get("settings_dialog")
	_check(settings_dialog != null, "the Review menu opens a settings dialog")
	if settings_dialog != null:
		for wanted in ["engine_line", "model_line", "human_model_line", "config_line",
				"live_visits_box", "review_visits_box", "profile_box", "status_label",
				"log_box", "detected_label"]:
			_check(settings_dialog.get(wanted) != null, "settings settings_dialog has a %s" % wanted)
		_check(int(settings_dialog.LOG_LINES) == 50,
			"the settings dialog shows the last 50 stderr lines, per PLAN 6.3")
		# Opening it must populate the status without starting anything.
		settings_dialog._refresh_engine_status()
		await process_frame
		var status_text: String = String(settings_dialog.status_label.text)
		_check(not status_text.is_empty(), "engine status is shown: <%s>" % status_text)
		_check(status_text.contains("Engine"), "the status reads as an engine status")
		_check(not String(settings_dialog.detected_label.text).is_empty(),
			"the settings dialog names the engine files or what is missing: <%s>"
			% String(settings_dialog.detected_label.text))
		var shown_engine_path: String = String(settings_dialog.engine_line.text).strip_edges()
		_check(not shown_engine_path.is_empty(), "the engine path box is filled in")
		_check(shown_engine_path == String(root.engine.engine_path)
			or shown_engine_path == String(root.get_node("/root/Settings").engine_path),
			"the engine path box shows the configured or detected path: <%s>" % shown_engine_path)
		_check(FileAccess.file_exists(shown_engine_path),
			"the path in the box is a file that exists")
		# The log must be capped at LOG_LINES even when the engine has more.
		var engine_node: Node = root.engine
		var filler: Node = load("res://scripts/engine/katago_process.gd").new()
		for i in 120:
			filler._log.append("stderr line %d" % i)
		var tail: PackedStringArray = filler.last_log_lines(int(settings_dialog.LOG_LINES))
		_check(tail.size() == 50, "last_log_lines(50) returns 50 lines, got %d" % tail.size())
		_check(String(tail[49]) == "stderr line 119", "the tail is the newest line")
		filler.free()
		_check(not settings_dialog.log_box.editable, "the log box cannot be typed into")
		# A restart button must exist and be wired (PLAN 5.2).
		var found_restart: bool = false
		for child in _all_children(settings_dialog):
			if child is Button and String((child as Button).text).to_lower().contains("restart"):
				found_restart = true
		_check(found_restart, "the settings settings_dialog offers an engine restart button")
		_check(root.restart_button != null, "the side panel also offers a restart button")
		# Close it before the render check: a 760x620 dialog left open on top of
		# the main window hides the board, and the frame check would then measure
		# the dialog instead of the board.
		settings_dialog.hide()
		await process_frame
		_check(not settings_dialog.visible, "the settings dialog is closed before rendering")

	# --- the board actually renders -----------------------------------------
	await process_frame
	# Nothing may be covering the main window, or the frame below measures the
	# wrong thing.
	for child in get_root().get_children():
		if child is Window and child != get_root() and String(child.name) != "Root":
			_check(not (child as Window).visible, "no window covering the board: %s" % String(child.name))
	# A --headless run uses the dummy renderer, which has no viewport texture at
	# all, so ask the DisplayServer which platform we are on first. Run this
	# script under with-display to get a real frame and a screenshot.
	# (RenderingServer.get_rendering_driver_name() would be the direct answer,
	# but it only exists from Godot 4.6 up; DisplayServer.get_name() works on 4.5.)
	var display: String = String(DisplayServer.get_name())
	if display == "headless":
		print("  (headless display server: run under with-display for a frame)")
	else:
		var image: Image = get_root().get_texture().get_image()
		if image != null and image.get_width() > 0:
			image.save_png("/tmp/go_game_smoke.png")
			print("screenshot written: /tmp/go_game_smoke.png (%d x %d)" % [image.get_width(), image.get_height()])
			_check(image.get_width() > 0, "viewport rendered a frame")
			_check(_looks_like_a_board(image), "the frame contains board-sized content")
		else:
			_check(false, "no viewport image although a display is active")

	print("=== %d smoke checks, %d failed ===" % [checks, failures])
	_bail()


func _press(keycode: int) -> void:
	# Input.parse_input_event() is ignored when Godot runs with --script, so the
	# event is pushed through the root viewport instead: that is the same path a
	# real key press takes (focus handling, GUI consumption, then _input).
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


func _check(condition: bool, label: String) -> void:
	checks += 1
	if condition:
		print("  ok   %s" % label)
	else:
		failures += 1
		print("  FAIL %s" % label)


func _bail() -> void:
	finished = true
	if _watchdog != null and is_instance_valid(_watchdog):
		_watchdog.stop()
	quit(0 if failures == 0 else 1)


func _fail(label: String) -> void:
	failures += 1
	print("  FAIL %s" % label)


## Every descendant of a node, depth first. Used to look for a control by text
## without depending on the exact container nesting.
func _all_children(node: Node) -> Array:
	var out: Array = []
	for child in node.get_children():
		out.append(child)
		out.append_array(_all_children(child))
	return out


## Checks that a rendered frame really contains board-sized content rather than a
## blank window: enough pixels of the board's wood colour, spread over a wide area.
func _looks_like_a_board(image: Image) -> bool:
	# board_view.background_color is Color(0.835, 0.682, 0.416).
	var wood := Color(0.835, 0.682, 0.416)
	var matches: int = 0
	var min_x: int = image.get_width()
	var min_y: int = image.get_height()
	var max_x: int = -1
	var max_y: int = -1
	var step: int = 3
	for y in range(0, image.get_height(), step):
		for x in range(0, image.get_width(), step):
			var c: Color = image.get_pixel(x, y)
			if absf(c.r - wood.r) < 0.06 and absf(c.g - wood.g) < 0.06 \
					and absf(c.b - wood.b) < 0.06:
				matches += 1
				min_x = mini(min_x, x)
				min_y = mini(min_y, y)
				max_x = maxi(max_x, x)
				max_y = maxi(max_y, y)
	var sampled: int = int(ceil(float(image.get_width()) / step)) \
		* int(ceil(float(image.get_height()) / step))
	if sampled <= 0 or matches == 0:
		return false
	var coverage: float = float(matches) / float(sampled)
	var span_x: float = float(max_x - min_x) / float(image.get_width())
	var span_y: float = float(max_y - min_y) / float(image.get_height())
	print("    board colour covers %.1f%% of the frame, spanning %.2f x %.2f of it"
		% [coverage * 100.0, span_x, span_y])
	return coverage > 0.05 and span_x > 0.3 and span_y > 0.3

