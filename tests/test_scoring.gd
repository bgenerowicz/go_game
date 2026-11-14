extends RefCounted

## Scoring tests: result strings, half-point rounding, the engine-less area
## count and the candidate filter.
var a: Assertions


func run() -> void:
	_test_rounding()
	_test_result_strings()
	_test_area_count()
	_test_significant_moves()


func _test_rounding() -> void:
	a.section("scoring: rounding")
	a.check_eq(Scoring.round_half(3.5), 3.5, "3.5 stays 3.5")
	a.check_eq(Scoring.round_half(3.74), 3.5, "3.74 rounds to 3.5")
	a.check_eq(Scoring.round_half(3.75), 4.0, "3.75 rounds to 4.0")
	a.check_eq(Scoring.round_half(-0.2), 0.0, "-0.2 rounds to 0")
	a.check_eq(Scoring.round_half(-2.3), -2.5, "-2.3 rounds to -2.5")


func _test_result_strings() -> void:
	a.section("scoring: result strings")
	a.check_eq(Scoring.result_from_score_lead(3.5), "B+3.5", "black ahead by 3.5")
	a.check_eq(Scoring.result_from_score_lead(-2.0), "W+2.0", "white ahead by 2")
	a.check_eq(Scoring.result_from_score_lead(0.0), "Draw", "level is a draw")
	a.check_eq(Scoring.result_from_score_lead(0.2), "Draw", "a rounding-level lead is a draw")
	a.check_eq(Scoring.result_from_score_lead(0.3), "B+0.5", "0.3 rounds to half a point")
	a.check_eq(Scoring.engine_result(3.5), "B+3.5 (engine estimate)", "engine results are labelled")


func _test_area_count() -> void:
	a.section("scoring: area count without an engine")
	var board: Board = Board.new(9)
	# A wall splits the board: black claims the left, white the right.
	for y in 9:
		board.set_stone(4, y, Board.Stone.BLACK)
	for y in 9:
		board.set_stone(5, y, Board.Stone.WHITE)
	var counted: Dictionary = Scoring.area_count(board, 6.5)
	# Black: 9 stones plus the 4x9 left field (x = 0..3) = 45.
	# White: 9 stones plus the 3x9 right field (x = 6..8) = 36, plus komi.
	a.check_eq(float(counted["black"]), 45.0, "black stones plus its territory")
	a.check_eq(float(counted["white"]), 42.5, "white stones, territory and komi")
	a.check_eq(String(counted["result"]), "B+2.5", "result from the count")
	# A neutral region bordered by both colours belongs to nobody.
	var open_board: Board = Board.new(9)
	open_board.set_stone(0, 0, Board.Stone.BLACK)
	open_board.set_stone(8, 8, Board.Stone.WHITE)
	var open_count: Dictionary = Scoring.area_count(open_board, 0.0)
	a.check_eq(float(open_count["black"]), 1.0, "one stone, no territory")
	a.check_eq(float(open_count["white"]), 1.0, "one stone, no territory")
	a.check_eq(String(open_count["result"]), "Draw", "all dame is neutral")
	# The owner map marks claimed points; stone points and dame stay neutral.
	var owner: PackedByteArray = counted["owner"] as PackedByteArray
	a.check_eq(int(owner[0]), Board.Stone.BLACK, "left field marked black")
	a.check_eq(int(owner[80]), Board.Stone.WHITE, "right field marked white")
	a.check_eq(int(owner[4 * 9 + 4]), Scoring.NEUTRAL, "a black stone point is not claimed territory")
	a.check_eq(int(owner[5 * 9 + 4]), Scoring.NEUTRAL, "a white stone point is not claimed territory")


func _test_significant_moves() -> void:
	a.section("scoring: candidate filter")
	var analysis: Dictionary = {
		"visits": 100,
		"moves": [
			{"move": "Q16", "visits": 60},
			{"move": "D4", "visits": 30},
			{"move": "C3", "visits": 2},
			{"move": "A1", "visits": 1},
			{"move": "T17", "visits": 0},
		],
	}
	var kept: Array = Scoring.significant_moves(analysis, 0.01)
	a.check_eq(kept.size(), 4, "1% of 100 visits keeps everything above one visit")
	var strict: Array = Scoring.significant_moves(analysis, 0.1)
	a.check_eq(strict.size(), 2, "a 10% cut keeps only the two main candidates")
	a.check_eq(String((strict[0] as Dictionary)["move"]), "Q16", "order is preserved")
	a.check_eq(Scoring.significant_moves({"visits": 0, "moves": [{"move": "Q16", "visits": 5}]}, 0.01).size(),
		0, "no root visits means no candidates")
