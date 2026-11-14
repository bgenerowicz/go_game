extends RefCounted

## SGF reader / writer tests. The runner instantiates this and calls run(a).
var a: Assertions

const FIXTURES: Array[String] = [
	"res://testdata/cornermoves.sgf",
	"res://testdata/foxlike.sgf",
	"res://testdata/humanslbigdiff.sgf",
	"res://testdata/messy.sgf",
	"res://testdata/sampletest9x9.sgf",
]


func run() -> void:
	_test_fixture_round_trips()
	_test_cornermoves()
	_test_handicap_and_unicode()
	_test_variations_and_pass()
	_test_setup_stones_on_board()
	_test_escaped_comments()
	_test_unknown_properties()
	_test_pass_forms()
	_test_bad_input()
	_test_new_game_header()


## Structural comparison: returns "" when identical, otherwise the reason.
func diff_tree(x: GameTree, y: GameTree) -> String:
	if x.size != y.size:
		return "size %d vs %d" % [x.size, y.size]
	if not is_equal_approx(x.komi, y.komi):
		return "komi %s vs %s" % [str(x.komi), str(y.komi)]
	if x.rules != y.rules:
		return "rules %s vs %s" % [x.rules, y.rules]
	if x.handicap != y.handicap:
		return "handicap %d vs %d" % [x.handicap, y.handicap]
	if x.black_name != y.black_name or x.white_name != y.white_name:
		return "player names differ"
	if x.result != y.result:
		return "result %s vs %s" % [x.result, y.result]
	if str(x.extra_properties) != str(y.extra_properties):
		return "root extra properties %s vs %s" % [str(x.extra_properties), str(y.extra_properties)]
	return diff_node(x.root, y.root, "root")


func diff_node(x: GameNode, y: GameNode, where: String) -> String:
	if (x.move == null) != (y.move == null):
		return "%s: one node has a move and the other does not" % where
	if x.move != null:
		if int(x.move["color"]) != int(y.move["color"]):
			return "%s: move colour differs" % where
		if x.move_point() != y.move_point():
			return "%s: move point %s vs %s" % [where, str(x.move_point()), str(y.move_point())]
	if x.comment != y.comment:
		return "%s: comment <%s> vs <%s>" % [where, x.comment, y.comment]
	if str(x.setup_black) != str(y.setup_black) or str(x.setup_white) != str(y.setup_white):
		return "%s: setup stones differ" % where
	if str(x.extra_properties) != str(y.extra_properties):
		return "%s: extra properties %s vs %s" % [where, str(x.extra_properties), str(y.extra_properties)]
	if x.children.size() != y.children.size():
		return "%s: %d children vs %d children" % [where, x.children.size(), y.children.size()]
	for i in x.children.size():
		var reason: String = diff_node(x.children[i], y.children[i], "%s/%d" % [where, i])
		if reason != "":
			return reason
	return ""


func _test_fixture_round_trips() -> void:
	a.section("sgf: every fixture round-trips")
	for path in FIXTURES:
		var first: Dictionary = SGF.parse_file(path)
		a.check(bool(first["ok"]), "%s parses: %s" % [path, str(first["error"])])
		if not bool(first["ok"]):
			continue
		var text: String = SGF.serialise(first["tree"])
		var second: Dictionary = SGF.parse_text(text)
		a.check(bool(second["ok"]), "%s re-parses: %s" % [path, str(second["error"])])
		if not bool(second["ok"]):
			continue
		var reason: String = diff_tree(first["tree"], second["tree"])
		a.check(reason == "", "%s round-trip identical%s" % [path, "" if reason == "" else " (" + reason + ")"])
		# Serialising twice must be stable.
		var third: Dictionary = SGF.parse_text(SGF.serialise(second["tree"]))
		a.check(bool(third["ok"]) and diff_tree(first["tree"], third["tree"]) == "",
			"%s second round-trip identical" % path)


func _test_cornermoves() -> void:
	a.section("sgf: simple game")
	var parsed: Dictionary = SGF.parse_file("res://testdata/cornermoves.sgf")
	a.check(bool(parsed["ok"]), "parses")
	var t: GameTree = parsed["tree"]
	a.check_eq(t.size, 19, "board size")
	a.check_eq(t.komi, 6.5, "komi 6.50 reads as 6.5")
	a.check_eq(t.rules, "Japanese", "rules")
	a.check_eq(t.black_name, "Black", "black player name")
	a.check_eq(t.white_name, "White", "white player name")
	a.check_eq(t.main_line_length(), 4, "four moves on the main line")
	t.go_to_main_line_end()
	a.check_eq(t.current.move_point(), Vector2i(3, 4), "last move W[de] is (3,4)")
	a.check_eq(t.moves_to(t.current)[0], "Q16", "B[pd] is Q16 in GTP")
	a.check(t.extra_properties.has("CA"), "unknown property CA kept")
	a.check(t.extra_properties.has("AP"), "unknown property AP kept")
	a.check(t.extra_properties.has("ST"), "unknown property ST kept")
	a.check_eq(String(t.extra_properties["CA"][0]), "UTF-8", "CA value kept verbatim")


func _test_handicap_and_unicode() -> void:
	a.section("sgf: handicap, setup on a child node, unicode")
	var parsed: Dictionary = SGF.parse_file("res://testdata/foxlike.sgf")
	a.check(bool(parsed["ok"]), "parses: %s" % str(parsed["error"]))
	var t: GameTree = parsed["tree"]
	a.check_eq(t.size, 19, "board size")
	a.check_eq(t.komi, 325.0, "integer komi")
	a.check_eq(t.handicap, 2, "handicap 2")
	a.check_eq(t.rules, "Chinese", "rules")
	a.check_eq(t.result, "draw", "result")
	a.check_eq(t.black_name, "testname1", "black name")
	# AB[] sits on the first child here, not on the root.
	a.check_eq(t.root.children.size(), 1, "one child of the root")
	var setup_node: GameNode = t.root.children[0]
	a.check_eq(setup_node.setup_black.size(), 2, "two handicap stones on that node")
	a.check_eq(setup_node.setup_black[0], Vector2i(15, 3), "first handicap stone pd")
	a.check_eq(setup_node.setup_black[1], Vector2i(3, 15), "second handicap stone dp")
	t.go_to_main_line_end()
	var board: Board = t.board_at(t.current)
	a.check_eq(board.stone_count(Board.Stone.BLACK), 3, "two setup stones plus one black move")
	a.check_eq(board.stone_count(Board.Stone.WHITE), 1, "one white move")
	a.check_eq(board.get_stone(15, 3), Board.Stone.BLACK, "handicap stone on the board")
	a.check_eq(board.get_stone(3, 2), Board.Stone.WHITE, "W[dc] on the board")
	a.check_eq(String(t.extra_properties["BR"][0]), "3段", "unicode rank kept")
	a.check(t.extra_properties.has("GN"), "empty GN[] kept")
	a.check_eq(String(t.extra_properties["GN"][0]), "", "empty value stays empty")
	a.check_eq(t.main_line_length(), 4, "including the empty trailing node")


func _test_variations_and_pass() -> void:
	a.section("sgf: variations, passes, mid-node setup")
	var parsed: Dictionary = SGF.parse_file("res://testdata/messy.sgf")
	a.check(bool(parsed["ok"]), "parses: %s" % str(parsed["error"]))
	var t: GameTree = parsed["tree"]
	a.check_eq(t.size, 9, "9x9")
	a.check_eq(t.komi, 6.0, "komi 6.00")
	a.check_eq(t.root.children.size(), 3, "three variations under the root")
	a.check(t.node_count() > 20, "the whole tree is parsed (%d nodes)" % t.node_count())
	# B[] is a pass.
	a.check_eq(_count_passes(t.root), 1, "one pass node found")
	# A comment that spans two lines survives.
	var multiline: GameNode = _find_node(t.root, "comment_with", "too few stones")
	a.check(multiline != null, "node with the two-line comment found")
	if multiline != null:
		a.check(multiline.comment.contains("\n"), "the newline inside the comment is kept")
	# Mid-node setup stones and an unmodelled PL[] property.
	var setup_node: GameNode = _find_node(t.root, "setup_count", "4")
	a.check(setup_node != null, "node with four setup stones found")
	if setup_node != null:
		a.check_eq(setup_node.setup_black[0], Vector2i(2, 2), "AB[cc] reads as (2,2)")
	var pl_node: GameNode = _find_node(t.root, "has_extra", "PL")
	a.check(pl_node != null, "PL[] kept as an unknown property")
	if pl_node != null:
		a.check_eq(String(pl_node.extra_properties["PL"][0]), "W", "PL value kept verbatim")
	# AE[] is kept verbatim but deliberately not applied to the board.
	var with_ae: GameNode = _find_node(t.root, "has_extra", "AE")
	a.check(with_ae != null, "node with AE[] found")
	if with_ae != null:
		a.check_eq(String(with_ae.extra_properties["AE"][0]), "df", "AE value kept verbatim")
		var board: Board = t.board_at(with_ae)
		a.check_eq(board.get_stone(3, 5), Board.Stone.WHITE,
			"AE[] is preserved but not applied, so W[df] still stands")


func _count_passes(node: GameNode) -> int:
	var total: int = 0
	if node.is_pass():
		total += 1
	for child in node.children:
		total += _count_passes(child)
	return total


## Search helpers so the tests do not depend on exact child ordering.
func _find_node(node: GameNode, kind: String, wanted: String) -> GameNode:
	if kind == "comment_with" and node.comment.contains(wanted):
		return node
	if kind == "setup_count" and str(node.setup_black.size()) == wanted:
		return node
	if kind == "has_extra" and node.extra_properties.has(wanted):
		return node
	for child in node.children:
		var found: GameNode = _find_node(child, kind, wanted)
		if found != null:
			return found
	return null


func _test_setup_stones_on_board() -> void:
	a.section("sgf: setup stones reach the board")
	var parsed: Dictionary = SGF.parse_file("res://testdata/sampletest9x9.sgf")
	a.check(bool(parsed["ok"]), "parses: %s" % str(parsed["error"]))
	var t: GameTree = parsed["tree"]
	a.check_eq(t.size, 9, "9x9")
	a.check_eq(t.komi, 6.0, "integer komi")
	a.check_eq(t.root.setup_black.size(), 5, "five black setup stones")
	a.check_eq(t.root.setup_white.size(), 5, "five white setup stones")
	var board: Board = t.board_at(t.root)
	a.check_eq(board.stone_count(Board.Stone.BLACK), 5, "setup stones on the root board")
	a.check_eq(board.get_stone(3, 4), Board.Stone.WHITE, "AW[de] placed")
	a.check_eq(board.get_stone(3, 2), Board.Stone.BLACK, "AB[dc] placed")
	t.go_to_main_line_end()
	a.check(t.main_line_length() > 0, "the game has moves after the setup")


func _test_escaped_comments() -> void:
	a.section("sgf: escapes in values")
	var text: String = "(;GM[4]FF[4]SZ[19]C[a \\] bracket and a \\\\ backslash];B[pd])"
	var parsed: Dictionary = SGF.parse_text(text)
	a.check(bool(parsed["ok"]), "escaped comment parses: %s" % str(parsed["error"]))
	var t: GameTree = parsed["tree"]
	a.check_eq(t.root.comment, "a ] bracket and a \\ backslash", "escapes decoded")
	var again: Dictionary = SGF.parse_text(SGF.serialise(t))
	a.check(bool(again["ok"]), "re-serialised escapes re-parse")
	if bool(again["ok"]):
		a.check_eq(diff_tree(t, again["tree"]), "", "escapes round-trip identical")
	# A backslash-newline is a soft line break, not a newline in the value.
	var soft: String = "(;GM[4]FF[4]SZ[19]C[line one \\\nline two];B[pd])"
	var soft_parsed: Dictionary = SGF.parse_text(soft)
	a.check(bool(soft_parsed["ok"]), "soft line break parses")
	a.check_eq(soft_parsed["tree"].root.comment, "line one line two", "soft break joins the lines")


func _test_unknown_properties() -> void:
	a.section("sgf: unknown properties survive")
	var text: String = "(;GM[3]FF[3]SZ[13]XYZ[hello][world]TE[good];B[hh]LB[hh:A]TR[hh]CR[gg])"
	var parsed: Dictionary = SGF.parse_text(text)
	a.check(bool(parsed["ok"]), "parses: %s" % str(parsed["error"]))
	var t: GameTree = parsed["tree"]
	a.check_eq(t.size, 13, "13x13")
	a.check_eq(t.extra_properties.size(), 4, "GM FF XYZ TE kept as extras")
	a.check_eq((t.extra_properties["XYZ"] as Array).size(), 2, "multi-value property kept")
	a.check_eq(String(t.extra_properties["XYZ"][1]), "world", "second value kept")
	var node: GameNode = t.root.children[0]
	a.check_eq(node.extra_properties.size(), 3, "three unknown node properties")
	a.check_eq(String(node.extra_properties["LB"][0]), "hh:A", "LB value kept verbatim")
	var written: String = SGF.serialise(t)
	a.check(written.contains("GM[3]"), "original GM value written back")
	a.check(written.contains("FF[3]"), "original FF value written back")
	a.check(written.contains("XYZ[hello][world]"), "multi-value property written back")
	a.check(written.contains("LB[hh:A]"), "LB written back unchanged")
	a.check(written.contains("CR[gg]"), "CR written back unchanged")
	var again: Dictionary = SGF.parse_text(written)
	a.check(bool(again["ok"]), "re-parses")
	if bool(again["ok"]):
		a.check_eq(diff_tree(t, again["tree"]), "", "unknown properties round-trip identical")


func _test_pass_forms() -> void:
	a.section("sgf: pass forms")
	for form in ["B[]", "B[tt]", "W[]", "W[tt]"]:
		var parsed: Dictionary = SGF.parse_text("(;GM[4]FF[4]SZ[19];" + form + ")")
		a.check(bool(parsed["ok"]), "%s parses" % form)
		if not bool(parsed["ok"]):
			continue
		var node: GameNode = parsed["tree"].root.children[0]
		a.check(node.is_pass(), "%s is a pass" % form)
		a.check_eq(node.move_point(), Vector2i(-1, -1), "%s has no point" % form)
	var written: String = SGF.serialise(SGF.parse_text("(;GM[4]FF[4]SZ[19];B[])")["tree"])
	a.check(written.contains("B[tt]"), "a pass is written as B[tt]")


func _test_bad_input() -> void:
	a.section("sgf: bad input is rejected with a message")
	var cases: Array = [
		["", "empty input"],
		["GM[1]SZ[19]", "no opening parenthesis"],
		["(;GM[1]SZ[19]", "no closing parenthesis"],
		["(;GM[1]SZ[7];B[pp])", "unsupported board size"],
		["(;GM[1]SZ[19];B[1z])", "bad coordinate"],
		["(;GM[1]SZ[19];B[pd]C[open)", "unterminated value"],
		["(;GM[1]SZ[19];B[pd]W[qp])", "two moves in one node"],
		["(;GM[1]SZ[19];B[pd]nope)", "junk after a property"],
		["(;GM[1]SZ[19])junk", "trailing text"],
	]
	for case in cases:
		var parsed: Dictionary = SGF.parse_text(String(case[0]))
		a.check(not bool(parsed["ok"]), "rejects %s" % String(case[1]))
		a.check(parsed["tree"] == null, "no tree returned for %s" % String(case[1]))
		a.check(not String(parsed["error"]).is_empty(), "error message for %s" % String(case[1]))
	var missing: Dictionary = SGF.parse_file("res://testdata/does_not_exist.sgf")
	a.check(not bool(missing["ok"]), "missing file reported")
	a.check(missing["tree"] == null, "missing file returns no tree")


func _test_new_game_header() -> void:
	a.section("sgf: header for app-created games")
	var t: GameTree = GameTree.new(19, 7.0)
	t.play_move(Board.Stone.BLACK, 15, 3)
	SGF.apply_standard_header(t)
	var written: String = SGF.serialise(t)
	a.check(written.contains("GM[4]"), "new game gets GM[4]")
	a.check(written.contains("FF[4]"), "new game gets FF[4]")
	a.check(written.contains("CA[UTF-8]"), "new game gets CA[UTF-8]")
	a.check(written.contains("SZ[19]"), "board size written")
	a.check(written.contains("KM[7]"), "komi written without a trailing .0")
	var parsed: Dictionary = SGF.parse_text(written)
	a.check(bool(parsed["ok"]), "new game SGF re-parses")
	if bool(parsed["ok"]):
		a.check_eq(diff_tree(t, parsed["tree"]), "", "new game round-trips identical")
	# A parsed file keeps its own headers instead of gaining defaults.
	var original: Dictionary = SGF.parse_file("res://testdata/humanslbigdiff.sgf")
	a.check(bool(original["ok"]), "fixture without GM/FF parses")
	var rewritten: String = SGF.serialise(original["tree"])
	a.check(not rewritten.contains("GM["), "no GM invented for a file that had none")
	a.check(not rewritten.contains("FF["), "no FF invented for a file that had none")
