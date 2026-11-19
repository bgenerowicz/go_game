extends RefCounted

## Puzzle mode (scripts/core/tsumego.gd): the problem's area, who attacks, the
## tsumego frame and the allowMoves list. Pure logic, no engine needed.
var a: Assertions

## A straight three in the top-left corner: White A18-D18 and D19 around the
## eye space A19-C19, Black around them on row 17 and the E file.
const CORNER: String = "(;GM[1]FF[4]SZ[19]KM[6.5]PL[B]" \
	+ "AW[ab][bb][cb][db][da]AB[ac][bc][cc][dc][ec][eb][ea])"


func run() -> void:
	_test_corner_area()
	_test_sides()
	_test_frame()
	_test_allow_moves()
	_test_moves_played()
	_test_not_a_puzzle()
	_test_centre_problem()
	_test_query()
	_test_white_to_play()


func _corner() -> GameTree:
	var parsed: Dictionary = SGF.parse_text(CORNER)
	return parsed["tree"] as GameTree


func _test_corner_area() -> void:
	a.section("tsumego: the problem's area")
	var tree: GameTree = _corner()
	var p: Dictionary = Tsumego.plan(tree, tree.root)
	a.check(not p.is_empty(), "a corner problem gets a plan")
	var region: Rect2i = p.get("region", Rect2i()) as Rect2i
	# Stones span x 0..4, y 0..2; two empty lines around them make x 0..6, y 0..4.
	a.check_eq(region, Rect2i(0, 0, 7, 5), "the area is the stones plus two lines")
	var near_edge: Rect2i = Tsumego.area_around([Vector2i(3, 3), Vector2i(5, 5)] as Array[Vector2i], 19)
	a.check_eq(near_edge.position, Vector2i(0, 0),
		"a side within two lines of the edge is pushed onto it")


func _test_sides() -> void:
	a.section("tsumego: attacker and defender")
	var tree: GameTree = _corner()
	var p: Dictionary = Tsumego.plan(tree, tree.root)
	a.check_eq(int(p["defender"]), Board.Stone.WHITE, "the group in the corner defends")
	a.check_eq(int(p["attacker"]), Board.Stone.BLACK, "the surrounding side attacks")
	# Swap the colours: the answer follows the stones, not the colour.
	var swapped: GameTree = SGF.parse_text(CORNER.replace("AW", "XX").replace("AB", "AW")
		.replace("XX", "AB"))["tree"]
	var q: Dictionary = Tsumego.plan(swapped, swapped.root)
	a.check_eq(int(q["defender"]), Board.Stone.BLACK, "swapped colours: Black defends")


func _test_frame() -> void:
	a.section("tsumego: the frame")
	var tree: GameTree = _corner()
	var p: Dictionary = Tsumego.plan(tree, tree.root)
	var region: Rect2i = p["region"]
	var board: Board = tree.board_at(tree.root)
	var black: int = 0
	var white: int = 0
	var in_area: int = 0
	for entry in (p["frame"] as Array):
		var colour: String = String((entry as Array)[0])
		var point: Vector2i = Coords.from_gtp(String((entry as Array)[1]), 19)
		if region.has_point(point):
			in_area += 1
		board.set_stone(point.x, point.y,
			Board.Stone.BLACK if colour == "B" else Board.Stone.WHITE)
		if colour == "B":
			black += 1
		else:
			white += 1
	a.check_eq(in_area, 0, "no frame stone inside the area")
	a.check(black > 50 and white > 50, "both sides get a wall (%d black, %d white)" % [black, white])
	# The wall next to the area belongs to the attacker.
	a.check_eq(board.get_stone(7, 0), Board.Stone.BLACK, "the attacker's wall touches the area")
	a.check_eq(board.get_stone(18, 18), Board.Stone.WHITE, "the defender's wall is far away")
	# Every frame group must have a liberty, or the query is not a legal position.
	var dead: int = 0
	var eyes_black: int = 0
	var eyes_white: int = 0
	for y in range(19):
		for x in range(19):
			if region.has_point(Vector2i(x, y)):
				continue
			if board.get_stone(x, y) == Board.Stone.EMPTY:
				# An eye: owned by the colour around it.
				var owner: int = board.get_stone(x + 1 if x < 18 else x - 1, y)
				if owner == Board.Stone.BLACK:
					eyes_black += 1
				else:
					eyes_white += 1
				continue
			if (board.group(x, y)["liberties"] as Array).is_empty():
				dead += 1
	a.check_eq(dead, 0, "every frame stone's group has a liberty")
	a.check(eyes_black >= 2 and eyes_white >= 2,
		"both walls have at least two eyes (%d black, %d white)" % [eyes_black, eyes_white])
	# Outside the area, Black minus White (stones and eyes) makes the board even
	# halfway between the group living and dying: komi, minus the attacker's
	# lead in the area at that midpoint (the area less the defender's part).
	var kept: int = Tsumego.defender_area_estimate(tree.board_at(tree.root), region,
		Board.Stone.WHITE)
	a.check(kept >= 6 and kept <= 14, "White's living group keeps about 8 points (%d)" % kept)
	var expected: float = tree.komi - float(region.get_area() - kept)
	var diff: float = float(black + eyes_black - white - eyes_white)
	a.check(absf(diff - expected) <= 3.0,
		"the outside centres the result (Black - White = %.1f, expected %.1f)" % [diff, expected])


func _test_allow_moves() -> void:
	a.section("tsumego: allowed moves")
	var tree: GameTree = _corner()
	var p: Dictionary = Tsumego.plan(tree, tree.root)
	var allow: Array = p["allow"]
	a.check(allow.has("B19"), "the vital point is allowed")
	a.check(allow.has("pass"), "passing is allowed")
	a.check(not allow.has("A18"), "occupied points are not listed")
	a.check(not allow.has("K10"), "far-away points are not allowed")
	# 7 x 5 area minus 12 stones, plus pass.
	a.check_eq(allow.size(), 7 * 5 - 12 + 1, "every empty point of the area, plus pass")


func _test_moves_played() -> void:
	a.section("tsumego: moves already played")
	var tree: GameTree = _corner()
	# A move far outside the corner grows the area to include it.
	var node: GameNode = tree.play_move(Board.Stone.BLACK, 9, 1)
	var p: Dictionary = Tsumego.plan(tree, node)
	var region: Rect2i = p["region"]
	a.check(region.has_point(Vector2i(9, 1)), "the area covers a move played outside it")
	for entry in (p["frame"] as Array):
		if String((entry as Array)[1]) == Coords.to_gtp(9, 1, 19):
			a.check(false, "a frame stone sits on a played move")


func _test_not_a_puzzle() -> void:
	a.section("tsumego: positions that are not a local problem")
	var empty: GameTree = GameTree.new(19, 6.5)
	a.check(Tsumego.plan(empty, empty.root).is_empty(), "an empty board has no plan")
	var spread: GameTree = SGF.parse_text("(;GM[1]SZ[19]AB[dd][pp]AW[dp][pd])")["tree"]
	a.check(Tsumego.plan(spread, spread.root).is_empty(),
		"stones in all four corners are not a local problem")
	var one_colour: GameTree = SGF.parse_text("(;GM[1]SZ[19]AB[aa][ba][ca])")["tree"]
	a.check(Tsumego.plan(one_colour, one_colour.root).is_empty(),
		"stones of one colour only: nothing to attack")


func _test_centre_problem() -> void:
	a.section("tsumego: a problem away from the edges")
	# White in the middle, Black around it.
	var tree: GameTree = SGF.parse_text(
		"(;GM[1]SZ[19]AW[jj][kj][jk]AB[ii][ji][ki][li][ij][lj][ik][lk][jl][kl])")["tree"]
	var p: Dictionary = Tsumego.plan(tree, tree.root)
	a.check(not p.is_empty(), "a centre problem gets a plan")
	a.check_eq(int(p["defender"]), Board.Stone.WHITE, "the inside group defends")
	var board: Board = tree.board_at(tree.root)
	for entry in (p["frame"] as Array):
		var point: Vector2i = Coords.from_gtp(String((entry as Array)[1]), 19)
		board.set_stone(point.x, point.y,
			Board.Stone.BLACK if String((entry as Array)[0]) == "B" else Board.Stone.WHITE)
	var dead: int = 0
	for y in range(19):
		for x in range(19):
			if board.get_stone(x, y) != Board.Stone.EMPTY \
					and (board.group(x, y)["liberties"] as Array).is_empty():
				dead += 1
	a.check_eq(dead, 0, "no group without a liberty around a centre problem")


func _test_query() -> void:
	a.section("tsumego: added to an engine query")
	var tree: GameTree = _corner()
	var p: Dictionary = Tsumego.plan(tree, tree.root)
	var query: Dictionary = {"initialStones": [["B", "A17"]]}
	Tsumego.apply_to_query(query, p)
	a.check_eq((query["initialStones"] as Array)[0], ["B", "A17"], "setup stones stay first")
	a.check_eq((query["initialStones"] as Array).size(), 1 + (p["frame"] as Array).size(),
		"the frame is added after them")
	var allow: Array = query["allowMoves"]
	a.check_eq(allow.size(), 2, "one allowMoves entry per colour")
	a.check_eq(String((allow[0] as Dictionary)["player"]), "B", "Black's entry")
	a.check_eq(String((allow[1] as Dictionary)["player"]), "W", "White's entry")
	a.check(int((allow[0] as Dictionary)["untilDepth"]) >= 100, "the limit holds deep in the search")
	a.check_eq(String(query["rules"]), "chinese", "area scoring, which the frame's balance counts in")


func _test_white_to_play() -> void:
	a.section("tsumego: a White-to-play problem")
	# PL on the root is stored on the tree by the SGF reader; it must still
	# decide who moves first, or the engine reads the problem for the wrong side.
	var tree: GameTree = SGF.parse_text(CORNER.replace("PL[B]", "PL[W]"))["tree"]
	a.check_eq(tree.turn_at(tree.root), Board.Stone.WHITE, "root PL[W]: White to play")
	var black_first: GameTree = _corner()
	a.check_eq(black_first.turn_at(black_first.root), Board.Stone.BLACK, "root PL[B]: Black to play")
