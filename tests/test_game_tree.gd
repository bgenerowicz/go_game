extends RefCounted

## GameTree / GameNode tests. The runner instantiates this and calls run(a).
var a: Assertions


func run() -> void:
	_test_play_and_follow()
	_test_variations()
	_test_main_line()
	_test_go_to_main_line_end()
	_test_moves_to()
	_test_board_at_replays()
	_test_turn_at()
	_test_passes()
	_test_engine_move_lists()
	_test_engine_setup_stones()


func _test_engine_move_lists() -> void:
	a.section("game tree: engine move lists")
	var t: GameTree = GameTree.new(19, 6.5)
	t.play_move(Board.Stone.BLACK, 15, 3)   # Q16
	t.play_move(Board.Stone.WHITE, 3, 15)   # D4
	t.play_move(Board.Stone.BLACK, -1, -1)  # pass
	var moves: Array = t.moves_with_colors(t.current)
	a.check_eq(moves.size(), 3, "three moves for the engine")
	a.check_eq(str(moves[0]), "[\"B\", \"Q16\"]", "first move is B Q16")
	a.check_eq(str(moves[1]), "[\"W\", \"D4\"]", "second move is W D4")
	a.check_eq(str(moves[2]), "[\"B\", \"pass\"]", "pass is sent as pass")
	a.check_eq(t.moves_with_colors(t.root).size(), 0, "the root has no moves")
	a.check_eq(t.move_count_to(t.current), 3, "turn index counts the moves")
	a.check_eq(t.move_count_to(t.root), 0, "turn 0 is the root")


func _test_engine_setup_stones() -> void:
	a.section("game tree: engine setup stones")
	# Setup stones must go to initialStones, not into the move list: adding them
	# to moves would shift every analyzeTurns index.
	var t: GameTree = GameTree.new(19, 7.0)
	t.root.setup_black = [Vector2i(3, 3), Vector2i(15, 15)]
	t.play_move(Board.Stone.WHITE, 9, 9)
	var moves: Array = t.moves_with_colors(t.current)
	a.check_eq(moves.size(), 1, "setup stones are not counted as moves")
	var setup: Array = t.setup_stones_with_colors(t.current)
	a.check_eq(setup.size(), 2, "two initial stones reported")
	a.check_eq(str(setup[0]), "[\"B\", \"D16\"]", "first initial stone")
	a.check_eq(str(setup[1]), "[\"B\", \"Q4\"]", "second initial stone")
	a.check_eq(t.setup_stones_with_colors(t.root).size(), 2, "root setup is included")
	# Setup stones on a deeper node are collected too, without duplicates.
	var t2: GameTree = GameTree.new(9, 6.0)
	t2.root.setup_white = [Vector2i(4, 4)]
	t2.play_move(Board.Stone.BLACK, 3, 3)
	var deeper: GameNode = t2.play_move(Board.Stone.WHITE, 5, 5)
	deeper.setup_black = [Vector2i(1, 1), Vector2i(4, 4)]
	var setup2: Array = t2.setup_stones_with_colors(deeper)
	a.check_eq(setup2.size(), 3, "setup stones from both nodes, no duplicate")
	a.check_eq(t2.moves_with_colors(deeper).size(), 2, "only real moves")



func _test_play_and_follow() -> void:
	a.section("game tree: play and follow")
	var t: GameTree = GameTree.new(9, 7.0)
	var n1: GameNode = t.play_move(Board.Stone.BLACK, 2, 2)
	a.check_eq(t.node_count(), 2, "root plus one move")
	a.check_eq(t.current, n1, "current follows the new move")
	a.check_eq(n1.depth, 1, "child depth is 1")
	a.check_eq(n1.move_color(), Board.Stone.BLACK, "child move colour")
	a.check_eq(n1.move_point(), Vector2i(2, 2), "child move point")
	# Replaying the same move from the same position must follow the existing
	# child instead of duplicating it.
	t.go_to(t.root)
	var n2: GameNode = t.play_move(Board.Stone.BLACK, 2, 2)
	a.check_eq(n2, n1, "identical move returns the same node")
	a.check_eq(t.node_count(), 2, "no duplicate node created")
	# A different move from the root creates a sibling.
	t.go_to(t.root)
	var n3: GameNode = t.play_move(Board.Stone.BLACK, 6, 6)
	a.check(n3 != n1, "a different move makes a different node")
	a.check_eq(t.root.children.size(), 2, "root has two children")
	a.check_eq(t.node_count(), 3, "three nodes in total")
	a.check_eq(n1.parent, t.root, "parent link set")
	a.check(t.root.is_root(), "root has no parent")


func _test_variations() -> void:
	a.section("game tree: variations")
	var t: GameTree = GameTree.new(19, 7.5)
	t.play_move(Board.Stone.BLACK, 3, 3)
	t.play_move(Board.Stone.WHITE, 15, 15)
	a.check(t.go_back(), "go_back moves to the parent")
	a.check_eq(t.current.depth, 1, "current is one move deep")
	t.play_move(Board.Stone.WHITE, 15, 3)
	a.check_eq(t.root.children[0].children.size(), 2, "a variation was added")
	a.check_eq(t.node_count(), 4, "root + 3 moves")
	t.go_back()
	a.check(t.go_forward(), "go_forward returns to a child")
	a.check_eq(t.current.move_point(), Vector2i(15, 15), "forward picks the first child")
	t.go_to_main_line_end()
	a.check_eq(t.current.depth, 2, "main line end is two moves deep")
	a.check_eq(t.current.main_line_index(), 0, "first child is the main line")
	a.check(t.current.is_main_line(), "first child is on the main line")
	a.check(not t.root.children[0].children[1].is_main_line(), "second child is not")


func _test_main_line() -> void:
	a.section("game tree: main line")
	var t: GameTree = GameTree.new(13, 6.5)
	for i in 5:
		t.play_move(Board.Stone.BLACK, i, i)
	# Branch off at move 3 with a longer variation.
	t.go_to(t.main_line()[3])
	for i in 5:
		t.play_move(Board.Stone.WHITE, 12 - i, i)
	var line: Array[GameNode] = t.main_line()
	a.check_eq(line.size(), 6, "main line is root plus the first five moves")
	a.check_eq(line[0], t.root, "main line starts at the root")
	a.check_eq(line[5].move_point(), Vector2i(4, 4), "main line ends at the first branch")
	a.check_eq(t.main_line_length(), 5, "main line length counts moves")
	a.check_eq(t.node_count(), 11, "both lines are in the tree")


func _test_go_to_main_line_end() -> void:
	a.section("game tree: go_to_main_line_end")
	var t: GameTree = GameTree.new(19, 7.0)
	t.play_move(Board.Stone.BLACK, 3, 3)
	t.play_move(Board.Stone.WHITE, 15, 15)
	# A side variation, and the cursor sits at its end.
	t.go_to_root()
	t.play_move(Board.Stone.BLACK, 15, 3)
	a.check_eq(t.current.move_point(), Vector2i(15, 3), "cursor is in the side variation")
	# End must mean the end of the game's main line, not of this variation.
	t.go_to_main_line_end()
	a.check_eq(t.current.move_point(), Vector2i(15, 15), "End follows the main line from the root")
	# The variation-local form stays where it is when there is nothing to follow.
	t.go_to_root()
	t.go_to(t.root.children[1])
	t.go_to_line_end()
	a.check_eq(t.current.move_point(), Vector2i(15, 3), "go_to_line_end stays in this variation")
	# ... and follows the first child when there is one.
	t.play_move(Board.Stone.WHITE, 2, 2)
	t.go_to_root()
	t.go_to(t.root.children[1])
	t.go_to_line_end()
	a.check_eq(t.current.move_point(), Vector2i(2, 2), "go_to_line_end follows the first child")


func _test_moves_to() -> void:
	a.section("game tree: moves_to")
	var t: GameTree = GameTree.new(19, 7.0)
	t.play_move(Board.Stone.BLACK, 15, 3)  # Q16
	t.play_move(Board.Stone.WHITE, 3, 15)  # D4
	t.play_move(Board.Stone.BLACK, -1, -1)  # pass
	var moves: Array[String] = t.moves_to(t.current)
	a.check_eq(moves.size(), 3, "three moves to the current node")
	a.check_eq(moves[0], "Q16", "first move in GTP form")
	a.check_eq(moves[1], "D4", "second move in GTP form")
	a.check_eq(moves[2], "pass", "pass is sent as pass")
	a.check_eq(t.moves_to(t.root).size(), 0, "the root has no moves")
	a.check_eq(t.path_to(t.current).size(), 3, "path_to lists the moves")

func _test_board_at_replays() -> void:
	a.section("game tree: board_at")
	var t: GameTree = GameTree.new(9, 7.0)
	t.root.setup_black = [Vector2i(2, 2), Vector2i(6, 6)]
	t.play_move(Board.Stone.WHITE, 4, 4)
	t.play_move(Board.Stone.BLACK, 4, 5)
	var board: Board = t.board_at(t.current)
	a.check_eq(board.size, 9, "board size from the tree")
	a.check_eq(board.get_stone(2, 2), Board.Stone.BLACK, "root setup stones applied")
	a.check_eq(board.get_stone(6, 6), Board.Stone.BLACK, "second setup stone")
	a.check_eq(board.get_stone(4, 4), Board.Stone.WHITE, "white move replayed")
	a.check_eq(board.get_stone(4, 5), Board.Stone.BLACK, "black move replayed")
	a.check_eq(t.board_at(t.current), board, "board is cached per node")
	a.check_eq(t.board_at(t.root).stone_count(Board.Stone.WHITE), 0, "root board has no white")
	# A capture deep in the tree is reflected in the rebuilt board.
	var t2: GameTree = GameTree.new(9, 7.0)
	t2.root.setup_white = [Vector2i(4, 4)]
	t2.root.setup_black = [Vector2i(3, 4), Vector2i(5, 4), Vector2i(4, 3)]
	t2.play_move(Board.Stone.BLACK, 4, 5)
	a.check_eq(t2.board_at(t2.current).get_stone(4, 4), Board.Stone.EMPTY, "capture replayed")
	a.check_eq(int(t2.board_at(t2.current).captures[Board.Stone.BLACK]), 1, "capture counted")
	t2.invalidate_boards()
	a.check(t2.board_at(t2.current) != null, "boards rebuild after invalidation")


func _test_turn_at() -> void:
	a.section("game tree: turn_at")
	var t: GameTree = GameTree.new(19, 7.0)
	a.check_eq(t.turn_at(t.root), Board.Stone.BLACK, "black plays first")
	t.play_move(Board.Stone.BLACK, 3, 3)
	a.check_eq(t.turn_at(t.current), Board.Stone.WHITE, "white plays second")
	t.play_move(Board.Stone.WHITE, 15, 15)
	a.check_eq(t.turn_at(t.current), Board.Stone.BLACK, "black plays third")
	var h: GameTree = GameTree.new(19, 7.0)
	h.handicap = 3
	h.root.setup_black = [Vector2i(3, 3), Vector2i(15, 15), Vector2i(3, 15)]
	a.check_eq(h.turn_at(h.root), Board.Stone.WHITE, "white plays first after handicap")
	h.play_move(Board.Stone.WHITE, 9, 9)
	a.check_eq(h.turn_at(h.current), Board.Stone.BLACK, "black answers the handicap")
	# A plain setup position with no HA starts with Black.
	var s: GameTree = GameTree.new(9, 7.0)
	s.root.setup_black = [Vector2i(2, 2), Vector2i(6, 6), Vector2i(4, 4)]
	s.root.setup_white = [Vector2i(3, 3), Vector2i(5, 5)]
	a.check_eq(s.turn_at(s.root), Board.Stone.BLACK, "setup position: black plays first")
	s.play_move(Board.Stone.BLACK, 1, 1)
	a.check_eq(s.turn_at(s.current), Board.Stone.WHITE, "then white")
	# PL[] on any node overrides the alternation.
	var p: GameTree = GameTree.new(9, 7.0)
	p.root.extra_properties["PL"] = ["W"]
	a.check_eq(p.turn_at(p.root), Board.Stone.WHITE, "PL[W] on the root")
	p.play_move(Board.Stone.WHITE, 2, 2)
	a.check_eq(p.turn_at(p.current), Board.Stone.BLACK, "descendants alternate from PL")
	var q: GameTree = GameTree.new(9, 7.0)
	q.play_move(Board.Stone.BLACK, 2, 2)
	q.play_move(Board.Stone.WHITE, 6, 6)
	q.current.extra_properties["PL"] = ["B"]
	a.check_eq(q.turn_at(q.current), Board.Stone.BLACK, "PL[B] mid-game restarts the count")
	q.play_move(Board.Stone.BLACK, 4, 4)
	a.check_eq(q.turn_at(q.current), Board.Stone.WHITE, "and alternates afterwards")


func _test_passes() -> void:
	a.section("game tree: passes")
	var t: GameTree = GameTree.new(9, 7.0)
	t.play_pass(Board.Stone.BLACK)
	t.play_pass(Board.Stone.WHITE)
	a.check(t.current.is_pass(), "the node records a pass")
	a.check_eq(t.current.move_point(), Vector2i(-1, -1), "pass has no point")
	a.check_eq(t.current.gtp_move(9), "pass", "pass renders as pass")
	a.check_eq(t.node_count(), 3, "two passes are two nodes")
	var board: Board = t.board_at(t.current)
	a.check_eq(board.consecutive_passes, 2, "the board sees two passes in a row")
