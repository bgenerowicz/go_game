extends RefCounted

## GameFlow tests: the rules-level flow behind local two-human play.
## The runner instantiates this and calls run(a).
var a: Assertions


func run() -> void:
	_test_turns_alternate()
	_test_illegal_reasons()
	_test_two_passes_end_the_game()
	_test_resign()
	_test_undo_pair()
	_test_step_navigation()
	_test_variation_navigation()
	_test_adopt_tree()
	_test_handicap()
	_test_review_editing()


func _test_turns_alternate() -> void:
	a.section("flow: turns alternate")
	var f: GameFlow = GameFlow.new()
	f.start(9, 6.5, "japanese", 0)
	a.check_eq(f.turn(), Board.Stone.BLACK, "black plays first")
	a.check(f.play(2, 2), "black plays")
	a.check_eq(f.turn(), Board.Stone.WHITE, "white is next")
	a.check(f.play(6, 6), "white plays")
	a.check_eq(f.turn(), Board.Stone.BLACK, "black is next again")
	a.check_eq(f.move_number(), 2, "two moves played")
	a.check_eq(f.tree.node_count(), 3, "root plus two moves")
	a.check(not f.over, "the game is still running")


func _test_illegal_reasons() -> void:
	a.section("flow: illegal moves are refused with a reason")
	var f: GameFlow = GameFlow.new()
	f.start(9, 6.5, "japanese", 0)
	f.play(4, 4)
	a.check(not f.play(4, 4), "cannot play on an occupied point")
	a.check_eq(f.last_error, "that point is already occupied", "occupied reason")
	# Suicide in the corner: black holds (1,0) and (0,1), so White cannot fill (0,0).
	var s: GameFlow = GameFlow.new()
	s.start(9, 6.5, "japanese", 0)
	s.play(1, 0)
	s.play(6, 6)
	s.play(0, 1)
	a.check_eq(s.turn(), Board.Stone.WHITE, "white to play")
	a.check(not s.play(0, 0), "corner suicide refused")
	a.check_eq(s.last_error, "that move would be suicide", "suicide reason")
	a.check_eq(s.tree.board_at(s.current()).get_stone(0, 0), Board.Stone.EMPTY,
		"the refused move left the board alone")
	# A real ko: white's single stone at (2,2) has one liberty at (3,2).
	var k: GameFlow = GameFlow.new()
	k.start(9, 6.5, "japanese", 0)
	k.tree.root.setup_black = [Vector2i(1, 2), Vector2i(2, 1), Vector2i(2, 3)]
	k.tree.root.setup_white = [Vector2i(2, 2), Vector2i(4, 2), Vector2i(3, 1), Vector2i(3, 3)]
	k.tree.invalidate_boards()
	a.check_eq(k.turn(), Board.Stone.BLACK, "black is to play on this shape")
	a.check(k.play(3, 2), "black captures the lone white stone")
	var board: Board = k.tree.board_at(k.current())
	a.check_eq(board.get_stone(2, 2), Board.Stone.EMPTY, "the white stone was captured")
	a.check_eq(board.ko_point, Vector2i(2, 2), "the ko point is recorded")
	a.check(not k.play(2, 2), "immediate recapture is refused")
	a.check_eq(k.last_error, "that would repeat the ko", "ko reason")


func _test_two_passes_end_the_game() -> void:
	a.section("flow: two passes end the game")
	var f: GameFlow = GameFlow.new()
	f.start(9, 6.5, "japanese", 0)
	a.check(f.pass_move(), "black passes")
	a.check(not f.over, "one pass is not the end")
	a.check(f.pass_move(), "white passes")
	a.check(f.over, "two passes end the game")
	a.check(f.ended_by_passes, "flagged as ending by passes")
	a.check_eq(f.result_text, "two passes", "result text")
	a.check(not f.play(2, 2), "no moves after the game is over")
	a.check_eq(f.last_error, "the game is over", "over reason")
	a.check(not f.pass_move(), "no more passes either")


func _test_resign() -> void:
	a.section("flow: resignation")
	var f: GameFlow = GameFlow.new()
	f.start(19, 6.5, "japanese", 0)
	f.play(3, 3)
	f.resign(Board.Stone.BLACK)
	a.check(f.over, "resignation ends the game")
	a.check_eq(f.result_text, "W+Resign", "white wins by resignation")
	a.check_eq(f.tree.result, "W+Resign", "result reaches the tree for saving")
	f.resign(Board.Stone.WHITE)
	a.check_eq(f.result_text, "W+Resign", "a second resignation is ignored")


func _test_undo_pair() -> void:
	a.section("flow: undo takes back a pair")
	var f: GameFlow = GameFlow.new()
	f.start(9, 6.5, "japanese", 0)
	f.play(2, 2)
	f.play(6, 6)
	f.play(4, 4)
	a.check_eq(f.undo_pair(), 2, "two plies taken back")
	a.check_eq(f.move_number(), 1, "one move remains")
	a.check_eq(f.turn(), Board.Stone.WHITE, "white to play again")
	a.check_eq(f.tree.node_count(), 2, "the taken-back nodes are gone")
	a.check_eq(f.tree.board_at(f.current()).get_stone(4, 4), Board.Stone.EMPTY,
		"the undone move is off the board")
	# Replaying the same moves must not leave dead branches behind.
	f.play(6, 6)
	f.play(4, 4)
	a.check_eq(f.tree.node_count(), 4, "replay reuses the path")
	a.check_eq(f.undo_pair(), 2, "undo again")
	a.check_eq(f.undo_pair(), 1, "only one ply left to take")
	a.check_eq(f.undo_pair(), 0, "nothing left at the root")
	a.check_eq(f.move_number(), 0, "back to an empty board")
	# Undo after a resign clears the result that resign created.
	f.play(2, 2)
	f.resign(Board.Stone.BLACK)
	a.check(f.over, "resigned")
	f.undo_pair()
	a.check(not f.over, "undo resumes the game")
	a.check_eq(f.result_text, "", "the resignation result is cleared")
	a.check_eq(f.tree.result, "", "and the tree no longer carries it")


func _test_step_navigation() -> void:
	a.section("flow: step navigation keeps the nodes")
	var f: GameFlow = GameFlow.new()
	f.start(9, 6.5, "japanese", 0)
	f.play(2, 2)
	f.play(6, 6)
	a.check(f.undo_step(), "step back")
	a.check_eq(f.move_number(), 1, "one move from the root")
	a.check_eq(f.tree.node_count(), 3, "stepping back deletes nothing")
	a.check(f.undo_step(), "step back again")
	a.check_eq(f.move_number(), 0, "at the root")
	a.check(not f.undo_step(), "cannot step before the root")
	a.check(f.redo_step(), "step forward")
	a.check_eq(f.turn(), Board.Stone.WHITE, "the right side is to play")
	a.check(f.redo_step(), "step forward again")
	a.check(not f.redo_step(), "no more main-line moves")


func _test_variation_navigation() -> void:
	a.section("flow: variation navigation")
	var f: GameFlow = GameFlow.new()
	f.start(9, 6.5, "japanese", 0)
	f.play(2, 2)
	f.play(6, 6)
	f.undo_step()
	f.play(6, 2)  # a different white reply, so the parent has two children
	a.check_eq(f.tree.root.children[0].children.size(), 2, "two white replies exist")
	a.check(f.next_variation(), "next variation")
	a.check_eq(f.current().move_point(), Vector2i(6, 6), "moved to the other reply")
	a.check(f.previous_variation(), "previous variation")
	a.check_eq(f.current().move_point(), Vector2i(6, 2), "moved back")
	a.check(f.next_variation(), "variations cycle")
	a.check_eq(f.current().move_point(), Vector2i(6, 6), "cycled to the other reply")
	f.tree.go_to_root()
	a.check(not f.next_variation(), "no variation to switch at the root")
	a.check(not f.previous_variation(), "nor backwards from the root")


func _test_adopt_tree() -> void:
	a.section("flow: adopting a loaded tree")
	var parsed: Dictionary = SGF.parse_file("res://testdata/cornermoves.sgf")
	a.check(bool(parsed["ok"]), "fixture parses")
	var f: GameFlow = GameFlow.new()
	f.adopt_tree(parsed["tree"])
	a.check_eq(f.move_number(), 4, "positioned at the end of the main line")
	a.check_eq(f.turn(), Board.Stone.BLACK, "the side to play after four moves")
	var board: Board = f.board()
	a.check_eq(board.stone_count(Board.Stone.BLACK), 2, "two black stones on the board")
	a.check_eq(board.stone_count(Board.Stone.WHITE), 2, "two white stones on the board")
	a.check(f.play(9, 9), "play continues from the loaded position")
	# A result read from the file survives undo.
	var with_result: Dictionary = SGF.parse_file("res://testdata/foxlike.sgf")
	a.check(bool(with_result["ok"]), "fixture with a result parses")
	var g: GameFlow = GameFlow.new()
	g.adopt_tree(with_result["tree"])
	a.check_eq(g.result_text, "draw", "loaded result is shown")
	g.undo_pair()
	a.check_eq(g.result_text, "draw", "undo keeps a result that came from the file")


func _test_handicap() -> void:
	a.section("flow: handicap setup")
	var f: GameFlow = GameFlow.new()
	f.start(19, 6.5, "japanese", 9)
	a.check_eq(f.tree.komi, 0.5, "handicap games get komi 0.5")
	a.check_eq(f.tree.root.setup_black.size(), 9, "nine handicap stones")
	a.check_eq(f.turn(), Board.Stone.WHITE, "white plays first under handicap")
	var board: Board = f.board()
	a.check_eq(board.stone_count(Board.Stone.BLACK), 9, "stones are on the board")
	a.check_eq(board.get_stone(3, 3), Board.Stone.BLACK, "a star point is occupied")
	var nine: GameFlow = GameFlow.new()
	nine.start(9, 0.5, "japanese", 4)
	a.check_eq(nine.tree.root.setup_black.size(), 4, "four stones on 9x9")
	a.check_eq(nine.tree.komi, 0.5, "an explicit komi is kept")
	var too_many: GameFlow = GameFlow.new()
	too_many.start(9, 0.5, "japanese", 99)
	a.check_eq(too_many.tree.root.setup_black.size(), 5, "handicap clamped to the star points")


func _test_review_editing() -> void:
	a.section("game flow: review-mode variation editing")
	var f: GameFlow = GameFlow.new()
	f.start(9, 6.0, "japanese", 0)
	f.play(4, 4)   # black
	f.play(2, 2)   # white
	var before: int = f.tree.node_count()
	# A click on an empty point in review mode adds a variation for the side to play.
	var added: GameNode = f.add_variation(6, 6)
	a.check(added != null, "a variation move is added")
	if added != null:
		a.check_eq(added.move_color(), Board.Stone.BLACK, "the variation is for the side to play")
		a.check_eq(added.move_point(), Vector2i(6, 6), "at the clicked point")
		a.check_eq(f.current(), added, "the new variation becomes the shown position")
	a.check_eq(f.tree.node_count(), before + 1, "one node added")
	# Going back one move and clicking elsewhere makes a sibling variation, so
	# the original line is kept beside it.
	f.tree.go_to(f.current().parent)
	var sibling: GameNode = f.add_variation(1, 7)
	a.check(sibling != null, "a second variation from the same position")
	if sibling != null:
		a.check_eq(sibling.parent.children.size(), 2, "both variations are children")
		a.check_eq(sibling.main_line_index(), 1, "the new one is not the main line")
		a.check_eq(f.tree.node_count(), before + 2, "two nodes added in total")
	# Occupied points are refused with a reason.
	var occupied: GameNode = f.add_variation(4, 4)
	a.check(occupied == null, "an occupied point is refused")
	a.check(f.last_error.contains("occupied"), "the reason mentions occupancy")
	# A point with no liberties of its own is refused as suicide.
	var sf: GameFlow = GameFlow.new()
	sf.start(9, 6.0, "japanese", 0)
	sf.tree.root.setup_white = [Vector2i(1, 0), Vector2i(0, 1)]
	sf.tree.invalidate_boards()
	var suicide: GameNode = sf.add_variation(0, 0)
	a.check(suicide == null, "a suicide point is refused")
	a.check(sf.last_error.contains("suicide"), "the reason mentions suicide")
	a.check_eq(sf.tree.node_count(), 1, "the refused move added nothing")
	# A ko point is refused, and only until a move elsewhere has been played.
	var kf: GameFlow = GameFlow.new()
	kf.start(9, 6.0, "japanese", 0)
	kf.tree.root.setup_black = [Vector2i(2, 0), Vector2i(1, 1), Vector2i(2, 2)]
	kf.tree.root.setup_white = [Vector2i(2, 1), Vector2i(4, 1), Vector2i(3, 0), Vector2i(3, 2)]
	kf.tree.invalidate_boards()
	var capture: GameNode = kf.add_variation(3, 1)
	a.check(capture != null, "the capturing variation move is allowed")
	if capture != null:
		a.check_eq(kf.board().get_stone(2, 1), Board.Stone.EMPTY, "the stone was captured")
		var retake: GameNode = kf.add_variation(2, 1)
		a.check(retake == null, "immediate recapture is refused")
		a.check(kf.last_error.contains("ko"), "the reason mentions the ko")
	# A pass variation is allowed, and editing never ends the game.
	var passed: GameNode = f.add_pass_variation()
	a.check(passed != null and passed.is_pass(), "a pass variation is added")
	a.check(not f.over, "two passes in a variation do not end the game")
	# Deleting the current node removes it and its whole sub-tree.
	var deep: GameFlow = GameFlow.new()
	deep.start(9, 6.0, "japanese", 0)
	deep.play(4, 4)
	deep.play(2, 2)
	var branch: GameNode = deep.add_variation(6, 6)
	deep.add_variation(6, 5)
	a.check_eq(deep.tree.node_count(), 5, "branch plus its child")
	a.check(deep.remove_current(), "the current node is deleted")
	a.check_eq(deep.current(), branch, "the cursor moves to the parent")
	a.check_eq(deep.tree.node_count(), 4, "the deleted node is gone")
	a.check_eq(branch.children.size(), 0, "no child left behind")
	# Deleting a node that still has descendants removes the whole sub-tree.
	var sub: GameNode = deep.add_variation(6, 5)
	deep.add_variation(5, 5)
	a.check(sub != null and sub.children.size() == 1, "a two-move sub-tree exists")
	deep.tree.go_to(sub)
	a.check(deep.remove_current(), "a node with descendants is deleted")
	a.check_eq(deep.tree.node_count(), 4, "the whole sub-tree went with it")
	a.check_eq(branch.children.size(), 0, "nothing hangs below the deleted node")
	# The root can never be deleted.
	deep.tree.go_to_root()
	a.check(not deep.remove_current(), "the root cannot be deleted")
	a.check(deep.last_error.contains("root"), "the reason mentions the root")
	# Comments are stored on the node so they reach the SGF.
	f.set_comment("my note")
	a.check_eq(f.current().comment, "my note", "comment stored on the node")
	f.set_comment("")
	a.check_eq(f.current().comment, "", "an empty comment clears it")

