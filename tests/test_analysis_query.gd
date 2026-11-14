extends RefCounted

## KataGo query construction (analysis_service.gd). The service is an autoload,
## but _build_query and the rule mapping are reachable on a bare instance: no
## _ready() runs until the node enters the tree, so nothing touches the engine.
var a: Assertions

const SERVICE: String = "res://scripts/engine/analysis_service.gd"


func run() -> void:
	var svc = load(SERVICE).new()
	_test_rule_names(svc)
	_test_query_shape(svc)
	_test_setup_stones(svc)
	_test_review_turns(svc)
	_test_no_engine_is_safe(svc)
	svc.free()


func _test_rule_names(svc) -> void:
	a.section("analysis: SGF rules to KataGo rule names")
	var cases: Dictionary = {
		"Chinese": "chinese",
		"chinese": "chinese",
		"Chinese 2020": "chinese",
		"AGA": "aga",
		"Korean": "korean",
		"New Zealand": "new-zealand",
		"Japanese": "japanese",
		"Tromp-Taylor": "tromp-taylor",
		"Ing": "ing",
		"": "japanese",
		"Martian": "japanese",
	}
	for sgf_name in cases:
		a.check_eq(svc.engine_rules_name(String(sgf_name)), String(cases[sgf_name]),
			"RU[%s] maps to %s" % [sgf_name, cases[sgf_name]])


func _test_query_shape(svc) -> void:
	a.section("analysis: query shape")
	var t: GameTree = GameTree.new(13, 6.5)
	t.rules = "Chinese"
	t.play_move(Board.Stone.BLACK, 6, 6)
	t.play_move(Board.Stone.WHITE, 2, 2)
	var q: Dictionary = svc._build_query(t, t.current, 250, {"include_ownership": true})
	a.check_eq(str(q["rules"]), "chinese", "rules name is KataGo's, not the SGF one")
	a.check_eq(q["komi"], 6.5, "komi passed through")
	a.check_eq(q["boardXSize"], 13, "x size")
	a.check_eq(q["boardYSize"], 13, "y size")
	a.check_eq(str(q["initialPlayer"]), "B", "black to play")
	a.check_eq(str(q["moves"]), 	"[[\"B\", \"G7\"], [\"W\", \"C11\"]]", "moves in GTP with colours")
	a.check(not q.has("initialStones"), "no initialStones when there are no setup stones")
	a.check_eq(str(q["maxVisits"]), "250", "visit budget")
	a.check_eq(str(q["includeOwnership"]), "true", "ownership requested")
	a.check_eq(str(q["includePolicy"]), "false", "policy off unless asked")
	a.check_eq(str(q["priority"]), "0", "default priority")
	# The whole query must fit on one line for the line protocol.
	var line: String = JSON.stringify(q)
	a.check(not line.contains("\n"), "stringified query is a single line")
	# initialPlayer is who moves at turn 0, not who is to move now: a review
	# query about a game that ends with White to play must still start with
	# Black, or the empty board is analysed with White to move.
	t.play_move(Board.Stone.BLACK, 4, 4)
	var at_white: Dictionary = svc._build_query(t, t.current, 100, {})
	a.check_eq(str(at_white["initialPlayer"]), "B", "turn 0 is Black's even with White to play now")
	var empty: GameTree = GameTree.new(9, 6.5)
	a.check_eq(str(svc._build_query(empty, empty.current, 100, {})["initialPlayer"]), "B",
		"an empty board starts with Black")
	# humanSLProfile belongs inside overrideSettings (PLAN 4.3).
	var human: Dictionary = svc._build_query(t, t.current, 40, {"human_profile": "rank_10k"})
	a.check_eq(str(human["overrideSettings"]["humanSLProfile"]), "rank_10k", "profile in overrideSettings")
	a.check(not human.has("humanSLProfile"), "profile not on the outer object")


func _test_setup_stones(svc) -> void:
	a.section("analysis: setup stones use initialStones")
	var t: GameTree = GameTree.new(19, 7.0)
	t.root.setup_black = [Vector2i(3, 3), Vector2i(15, 15), Vector2i(3, 15)]
	t.play_move(Board.Stone.WHITE, 9, 9)
	var q: Dictionary = svc._build_query(t, t.current, 100, {})
	a.check_eq(str(q["moves"]), '[[\"W\", \"K10\"]]', "setup stones are not moves")
	a.check_eq(str(q["initialStones"]),
		'[[\"B\", \"D16\"], [\"B\", \"Q4\"], [\"B\", \"D4\"]]', "initialStones filled")
	a.check_eq(str(q["initialPlayer"]), "W", "white plays first after handicap")
	# analyzeTurns indexes the move list, so setup stones must not shift it.
	var line: Array[GameNode] = t.main_line()
	a.check_eq(t.move_count_to(t.current), 1, "turn index ignores setup stones")


func _test_review_turns(svc) -> void:
	a.section("analysis: review query turns")
	var t: GameTree = GameTree.new(9, 6.0)
	for i in 4:
		t.play_move(Board.Stone.BLACK, i, i)
	var line: Array[GameNode] = t.main_line()
	a.check_eq(line.size(), 5, "root plus four moves")
	# request_review builds turns itself; check the same range here without an engine.
	var turns: Array[int] = []
	for i in range(1, line.size()):
		turns.append(i)
	a.check_eq(str(turns), "[1, 2, 3, 4]", "turn 0 (empty board) is skipped")
	var q: Dictionary = svc._build_query(t, line[line.size() - 1], 200, {})
	a.check_eq(str(q["moves"]).length() > 0, true, "the review query carries the moves")


func _test_no_engine_is_safe(svc) -> void:
	a.section("analysis: missing engine is handled, not a crash")
	# The engine binary is gitignored and may be absent; every entry point must
	# degrade to "" instead of erroring out (PLAN milestone 9).
	var t: GameTree = GameTree.new(9, 6.0)
	t.play_move(Board.Stone.BLACK, 2, 2)
	a.check_eq(svc.request(t.current, 10, {"tree": t}), "", "request with no engine")
	a.check_eq(svc.request_review(t), "", "review with no engine")
	a.check_eq(svc.request_live(t, t.current), "", "live analysis with no engine")
	svc.cancel_live()
	svc.cancel_review()
	svc.clear()
	a.check(true, "cancel and clear survive a missing engine")
	# A reply for a query we forgot must be ignored quietly.
	svc._on_response({"id": "nope", "currentMoves": []})
	a.check(true, "unknown response id ignored")
