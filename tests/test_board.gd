extends RefCounted

## One test module. The runner instantiates this and calls run(a).
var a: Assertions


func run() -> void:
	_test_group_liberties()
	_test_capture_single()
	_test_capture_multi()
	_test_suicide()
	_test_capture_not_suicide()
	_test_ko()
	_test_undo_and_history()
	_test_illegal_leaves_board_untouched()


## Builds a 9x9 board with the given points set up directly (setup stones).
func _board_with(size: int, black: Array, white: Array) -> Board:
	var b: Board = Board.new(size)
	for p in black:
		b.set_stone(p.x, p.y, Board.Stone.BLACK)
	for p in white:
		b.set_stone(p.x, p.y, Board.Stone.WHITE)
	return b


func _grid_snapshot(b: Board) -> String:
	var out := ""
	for y in b.size:
		for x in b.size:
			match b.get_stone(x, y):
				Board.Stone.BLACK:
					out += "B"
				Board.Stone.WHITE:
					out += "W"
				_:
					out += "."
	return out


## Board: groups and liberties ---------------------------------------------

func _test_group_liberties() -> void:
	a.section("board: groups and liberties")
	# Black domino in the middle of a 9x9: 4 stones, 8 liberties.
	var b := _board_with(9, [Vector2i(4, 4), Vector2i(5, 4), Vector2i(4, 5), Vector2i(3, 4)], [])
	var g: Dictionary = b.group(4, 4)
	a.check_eq((g["stones"] as Array).size(), 4, "connected group has 4 stones")
	a.check_eq((g["liberties"] as Array).size(), 8, "that group has 8 liberties")
	a.check_eq(b.group(0, 0)["stones"].size(), 0, "empty point has no group")
	# Corner group has fewer neighbours.
	var corner := _board_with(9, [Vector2i(0, 0)], [])
	a.check_eq((corner.group(0, 0)["liberties"] as Array).size(), 2, "corner stone has 2 liberties")
	a.check_eq(b.neighbors(0, 0).size(), 2, "corner has 2 neighbours")
	a.check_eq(b.neighbors(4, 4).size(), 4, "centre has 4 neighbours")
	a.check_eq(Board.opposite(Board.Stone.BLACK), Board.Stone.WHITE, "black's opposite is white")


## Board: single stone capture ----------------------------------------------

func _test_capture_single() -> void:
	a.section("board: single stone capture")
	var b := _board_with(
		9,
		[Vector2i(3, 4), Vector2i(5, 4), Vector2i(4, 3)],
		[Vector2i(4, 4)]
	)
	a.check(b.is_legal(4, 5, Board.Stone.BLACK), "the capturing move is legal")
	a.check(b.play(4, 5, Board.Stone.BLACK), "black plays the capture")
	a.check_eq(b.get_stone(4, 4), Board.Stone.EMPTY, "the white stone is removed")
	a.check_eq(b.get_stone(4, 5), Board.Stone.BLACK, "the played stone stays")
	a.check_eq(int(b.captures[Board.Stone.BLACK]), 1, "black captured exactly 1 stone")
	a.check_eq(b.stone_count(Board.Stone.WHITE), 0, "no white stones left")
	a.check_eq(b.ko_point, Board.INVALID, "no ko: the capturing group is not a single stone")


## Board: multi stone capture -----------------------------------------------

func _test_capture_multi() -> void:
	a.section("board: multi stone capture")
	# Two white stones on the bottom edge of a 9x9 (y = 8), reduced to one
	# liberty and then captured together.
	var b := _board_with(
		9,
		[Vector2i(0, 7)],
		[Vector2i(0, 8), Vector2i(1, 8)]
	)
	a.check_eq((b.group(0, 8)["liberties"] as Array).size(), 2, "white pair has 2 liberties")
	a.check(b.play(1, 7, Board.Stone.BLACK), "black fills one liberty")
	a.check_eq((b.group(0, 8)["liberties"] as Array).size(), 1, "white pair now has 1 liberty")
	a.check(b.play(2, 8, Board.Stone.BLACK), "black fills the last liberty")
	a.check_eq(b.get_stone(0, 8), Board.Stone.EMPTY, "first white stone captured")
	a.check_eq(b.get_stone(1, 8), Board.Stone.EMPTY, "second white stone captured")
	a.check_eq(int(b.captures[Board.Stone.BLACK]), 2, "black captured 2 stones")
	a.check_eq(b.ko_point, Board.INVALID, "no ko after a two stone capture")


## Board: suicide -------------------------------------------------------------

func _test_suicide() -> void:
	a.section("board: suicide rejected")
	# A single point surrounded by four white stones that each have their own
	# liberties elsewhere, so nothing is captured.
	var b := _board_with(
		9,
		[],
		[Vector2i(3, 4), Vector2i(5, 4), Vector2i(4, 3), Vector2i(4, 5)]
	)
	a.check(not b.is_legal(4, 4, Board.Stone.BLACK), "filling your own eye is suicide")
	a.check(not b.play(4, 4, Board.Stone.BLACK), "black may not play the suicide point")
	a.check_eq(b.get_stone(4, 4), Board.Stone.EMPTY, "suicide leaves the point empty")
	a.check_eq(b.move_count(), 0, "suicide is not recorded as a move")
	# Same thing on the edge: (1,0) is ringed by three white stones that each
	# keep a liberty elsewhere, so nothing is captured and the move is suicide.
	var edge := _board_with(
		9,
		[],
		[Vector2i(0, 0), Vector2i(2, 0), Vector2i(1, 1)]
	)
	a.check(not edge.is_legal(1, 0, Board.Stone.BLACK), "edge suicide is illegal")
	a.check(not edge.play(1, 0, Board.Stone.BLACK), "the edge suicide is refused")
	a.check_eq(edge.get_stone(1, 0), Board.Stone.EMPTY, "edge point still empty")
	# A stone that is captured rather than suicided is a different case again:
	# see _test_capture_not_suicide below.


## Board: capture that is not suicide -----------------------------------------

func _test_capture_not_suicide() -> void:
	a.section("board: capture that is not suicide")
	# Black (2,0) would have no liberties of its own, but it removes white's
	# last liberty, so the move is legal.
	var b := _board_with(
		9,
		[Vector2i(1, 1), Vector2i(0, 2)],
		[Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(3, 0), Vector2i(2, 1)]
	)
	var white_group: Dictionary = b.group(1, 0)
	a.check_eq((white_group["stones"] as Array).size(), 3, "white group is 3 stones")
	a.check_eq((white_group["liberties"] as Array).size(), 1, "white group has 1 liberty")
	a.check(b.is_legal(2, 0, Board.Stone.BLACK), "the capture is legal although it looks like suicide")
	a.check(b.play(2, 0, Board.Stone.BLACK), "black plays it")
	a.check_eq(b.get_stone(0, 0), Board.Stone.EMPTY, "white stone (0,0) captured")
	a.check_eq(b.get_stone(1, 0), Board.Stone.EMPTY, "white stone (1,0) captured")
	a.check_eq(b.get_stone(0, 1), Board.Stone.EMPTY, "white stone (0,1) captured")
	a.check_eq(b.get_stone(2, 0), Board.Stone.BLACK, "the black stone survives")
	a.check_eq(int(b.captures[Board.Stone.BLACK]), 3, "black captured 3 stones")
	a.check_eq(b.ko_point, Board.INVALID, "no ko from a three stone capture")


## Board: ko ------------------------------------------------------------------

func _ko_board() -> Board:
	# The classic ko shape on a 9x9. The contested point is (4,3).
	#   x:      2  3  4  5
	# y=2   .  B  W  .
	# y=3   .  B  .  W      (with the white stone at (3,3) inside)
	# y=4   .  B  W  .
	return _board_with(
		9,
		[Vector2i(3, 2), Vector2i(2, 3), Vector2i(3, 4)],
		[Vector2i(4, 2), Vector2i(3, 3), Vector2i(4, 4), Vector2i(5, 3)]
	)


func _test_ko() -> void:
	a.section("board: ko")
	var b := _ko_board()
	a.check_eq((b.group(3, 3)["liberties"] as Array).size(), 1, "the white stone sits in atari")
	a.check(b.play(4, 3, Board.Stone.BLACK), "black captures one stone")
	a.check_eq(b.get_stone(3, 3), Board.Stone.EMPTY, "the white stone is gone")
	a.check_eq(b.ko_point, Vector2i(3, 3), "the ko point is recorded")
	# Immediate recapture is refused.
	a.check(not b.is_legal(3, 3, Board.Stone.WHITE), "white may not retake the ko at once")
	a.check(not b.play(3, 3, Board.Stone.WHITE), "the recapture is refused")
	a.check_eq(b.get_stone(4, 3), Board.Stone.BLACK, "black's capturing stone is still there")
	a.check_eq(int(b.captures[Board.Stone.WHITE]), 0, "white has captured nothing")
	# A move elsewhere releases the ko.
	a.check(b.play(0, 0, Board.Stone.WHITE), "white plays elsewhere (tenuki)")
	a.check_eq(b.ko_point, Board.INVALID, "the ko point is cleared by a move elsewhere")
	a.check(b.is_legal(3, 3, Board.Stone.WHITE), "white may now play at the old ko point")
	a.check(b.play(3, 3, Board.Stone.WHITE), "white recaptures")
	a.check_eq(b.get_stone(4, 3), Board.Stone.EMPTY, "black's stone is now captured")
	a.check_eq(int(b.captures[Board.Stone.WHITE]), 1, "white has captured 1 stone")
	a.check_eq(b.ko_point, Vector2i(4, 3), "the ko has flipped sides")
	# A pass also releases the ko.
	var c := _ko_board()
	c.play(4, 3, Board.Stone.BLACK)
	a.check_eq(c.ko_point, Vector2i(3, 3), "ko set up again")
	c.play_pass(Board.Stone.WHITE)
	a.check_eq(c.ko_point, Board.INVALID, "a pass clears the ko")
	a.check_eq(c.consecutive_passes, 1, "one pass recorded")
	c.play_pass(Board.Stone.BLACK)
	a.check_eq(c.consecutive_passes, 2, "two consecutive passes recorded")


## Board: undo, history, replay -----------------------------------------------

func _test_undo_and_history() -> void:
	a.section("board: undo and history")
	var b := _ko_board()
	var before := _grid_snapshot(b)
	b.play(4, 3, Board.Stone.BLACK)
	a.check(b.undo(), "undo of a capture succeeds")
	a.check_eq(_grid_snapshot(b), before, "undo restores the whole board")
	a.check_eq(int(b.captures[Board.Stone.BLACK]), 0, "undo restores the capture counter")
	a.check_eq(b.ko_point, Board.INVALID, "undo restores the ko point")
	a.check_eq(b.move_count(), 0, "undo removes the move from history")
	a.check(not b.undo(), "undo on an empty history fails cleanly")
	# Undo of a pass.
	b.play_pass(Board.Stone.WHITE)
	a.check_eq(b.consecutive_passes, 1, "pass counted")
	a.check(b.undo(), "undo of a pass succeeds")
	a.check_eq(b.consecutive_passes, 0, "pass count restored")
	a.check_eq(b.move_count(), 0, "pass removed from history")
	# GTP move list round-trip.
	var g := Board.new(19)
	g.play(15, 3, Board.Stone.BLACK)
	g.play(3, 15, Board.Stone.WHITE)
	g.play_pass(Board.Stone.BLACK)
	a.check_eq(";".join(g.moves_as_gtp()), "Q16;D4;pass", "moves_as_gtp matches the engine form")
	var replay := Board.new(19)
	for mv in g.moves_as_gtp():
		var color: int = Board.Stone.BLACK if replay.move_count() % 2 == 0 else Board.Stone.WHITE
		a.check(replay.play_gtp(mv, color), "replays <%s>" % mv)
	a.check_eq(_grid_snapshot(replay), _grid_snapshot(g), "replay reproduces the position")
	# clone() is independent of the original.
	var copy := g.clone()
	copy.play(2, 2, Board.Stone.WHITE)
	a.check_eq(g.get_stone(2, 2), Board.Stone.EMPTY, "clone does not write through to the original")


## Board: illegal moves never mutate ------------------------------------------

func _test_illegal_leaves_board_untouched() -> void:
	a.section("board: illegal moves are inert")
	var b := _ko_board()
	b.play(4, 3, Board.Stone.BLACK)
	var snapshot := _grid_snapshot(b)
	var captures_snapshot: Dictionary = b.captures.duplicate(true)
	var moves: int = b.move_count()
	var ko_snapshot: Vector2i = b.ko_point
	# Occupied point, off board, ko point, suicide.
	a.check(not b.play(4, 3, Board.Stone.WHITE), "occupied point refused")
	a.check(not b.play(-1, 0, Board.Stone.WHITE), "negative x refused")
	a.check(not b.play(9, 9, Board.Stone.WHITE), "x == size refused")
	a.check(not b.play(0, 9, Board.Stone.WHITE), "y == size refused")
	a.check(not b.play(3, 3, Board.Stone.WHITE), "ko point refused")
	a.check(not b.play(8, 8, Board.Stone.EMPTY), "empty colour refused")
	a.check(not b.play_gtp("I19", Board.Stone.WHITE), "malformed gtp refused")
	a.check_eq(_grid_snapshot(b), snapshot, "no illegal move changed the board")
	a.check_eq(b.captures, captures_snapshot, "no illegal move changed the capture counters")
	a.check_eq(b.move_count(), moves, "no illegal move was added to history")
	a.check_eq(b.ko_point, ko_snapshot, "no illegal move changed the ko point")
