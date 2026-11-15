extends RefCounted

## AiPlayer move-selection tests. Pure logic: no engine needed, the
## analysis Dictionary is built by hand in the shape Analysis stores on a node.
var a: Assertions


func run() -> void:
	_test_profiles()
	_test_request_options()
	_test_sampling_follows_human_policy()
	_test_filters()
	_test_pass_rules()
	_test_resign_rules()
	_test_no_analysis()
	_test_beginner()


## Builds a fake analysis result. `policy` maps GTP move -> humanPolicy value;
## points not mentioned get 0.0.
func make_analysis(size: int, moves: Array, policy: Dictionary,
		winrate: float = 0.5, score_lead: float = 0.0, visits: int = 40) -> Dictionary:
	var flat: Array = []
	for i in range(size * size + 1):
		flat.append(0.0)
	var entries: Array = []
	for move in moves:
		var gtp: String = String(move)
		var entry: Dictionary = {"move": gtp, "visits": 5, "winrate": 0.5,
			"score_lead": 0.0, "prior": 0.1, "pv": [gtp]}
		entries.append(entry)
		if gtp != Coords.PASS:
			var point: Vector2i = Coords.from_gtp(gtp, size)
			if point != Coords.INVALID:
				flat[point.y * size + point.x] = float(policy.get(gtp, 0.0))
	return {
		"visits": visits,
		"winrate": winrate,
		"score_lead": score_lead,
		"moves": entries,
		"human_policy": flat,
	}


func _test_profiles() -> void:
	a.section("ai player: profiles")
	var modern: AiPlayer = AiPlayer.new("rank_5k", "modern")
	a.check_eq(modern.sl_profile(), "rank_5k", "modern style keeps the rank profile")
	var preai: AiPlayer = AiPlayer.new("rank_5k", "preai")
	a.check_eq(preai.sl_profile(), "preaz_5k", "pre-AI style maps rank_ to preaz_")
	var proyear: AiPlayer = AiPlayer.new("proyear_1990", "preai")
	a.check_eq(proyear.sl_profile(), "proyear_1990", "non-rank profiles pass through")
	# configure() is the path the dialogs use, and it must survive a round trip:
	# a preaz name has to come back out as a full KataGo profile, not a bare rank.
	var configured: AiPlayer = AiPlayer.new()
	configured.configure("preaz_10k")
	a.check_eq(configured.sl_profile(), "preaz_10k", "configure keeps a preaz profile intact")
	a.check_eq(configured.style, "preai", "a preaz name sets the style")
	configured.configure("rank_5k")
	a.check_eq(configured.sl_profile(), "rank_5k", "configure keeps a rank profile intact")
	a.check_eq(configured.style, "modern", "a rank name means modern style")
	configured.configure("proyear_2020")
	a.check_eq(configured.sl_profile(), "proyear_2020", "proyear profiles round-trip too")
	# The visits argument is what lets Settings drive the opponent's strength.
	configured.configure("rank_1d", 200)
	a.check_eq(configured.visits, 200, "configure can set the visit budget")
	a.check_eq(configured.sl_profile(), "rank_1d", "the profile still round-trips")


func _test_request_options() -> void:
	a.section("ai player: request options")
	var player: AiPlayer = AiPlayer.new("rank_10k", "modern")
	var tree: GameTree = GameTree.new(19, 6.5)
	var opts: Dictionary = player.request_opts(tree)
	a.check_eq(int(opts["priority"]), 20, "priority 20 so it jumps the queue")
	a.check(bool(opts["include_policy"]), "includePolicy is requested")
	a.check_eq(String(opts["human_profile"]), "rank_10k", "the chosen profile is passed on")
	a.check_eq(AiPlayer.REQUEST_VISITS, 40, "40 visits")


func _test_sampling_follows_human_policy() -> void:
	a.section("ai player: sampling")
	var size: int = 19
	var moves: Array = ["Q16", "D4", "C3", "D16"]
	var policy: Dictionary = {"Q16": 0.6, "D4": 0.3, "C3": 0.08, "D16": 0.02}
	var analysis: Dictionary = make_analysis(size, moves, policy)
	var player: AiPlayer = AiPlayer.new()
	player.rng.seed = 12345
	var counts: Dictionary = {}
	var all_non_empty: bool = true
	for i in 4000:
		var result: Dictionary = player.choose_move(analysis, size, Board.Stone.BLACK, 1, false)
		if String(result["move"]).is_empty():
			all_non_empty = false
		counts[result["move"]] = int(counts.get(result["move"], 0)) + 1
	a.check(all_non_empty, "a move is always returned")
	# The human policy, not the search order, drives the choice: Q16 most often,
	# D16 (the smallest legal weight) least often.
	a.check(int(counts.get("Q16", 0)) > int(counts.get("D4", 0)), "the largest policy entry wins most often")
	a.check(int(counts.get("D4", 0)) > int(counts.get("C3", 0)), "second entry beats the third")
	a.check(int(counts.get("C3", 0)) >= int(counts.get("D16", 0)), "third beats the fourth")
	a.check(int(counts.get("D16", 0)) > 0, "even a small candidate is sometimes played")
	a.check_eq(counts.keys().size(), 4, "every candidate is sampled at least once")
	# Roughly proportional: Q16 should land near 60% of 0.9 of the mass.
	var share: float = float(counts["Q16"]) / 4000.0
	a.check(share > 0.55 and share < 0.75, "sampling share %.3f is near the policy share" % share)
	# Same seed, same sequence.
	var again: AiPlayer = AiPlayer.new()
	again.rng.seed = 12345
	var first_again: String = String(again.choose_move(analysis, size, Board.Stone.BLACK, 1, false)["move"])
	var player2: AiPlayer = AiPlayer.new()
	player2.rng.seed = 12345
	var first_once: String = String(player2.choose_move(analysis, size, Board.Stone.BLACK, 1, false)["move"])
	a.check_eq(first_again, first_once, "a seeded rng reproduces the choice")

func _test_filters() -> void:
	a.section("ai player: candidate filters")
	var size: int = 9
	# One illegal entry (-1 in the policy) and one far below 2% of the largest.
	var moves: Array = ["E5", "C5", "G5", "A1"]
	var policy: Dictionary = {"E5": 0.5, "C5": 0.4, "G5": 0.001, "A1": -1.0}
	var analysis: Dictionary = make_analysis(size, moves, policy)
	var player: AiPlayer = AiPlayer.new()
	player.rng.seed = 7
	var counts: Dictionary = {}
	for i in 2000:
		var result: Dictionary = player.choose_move(analysis, size, Board.Stone.BLACK, 1, false)
		counts[result["move"]] = int(counts.get(result["move"], 0)) + 1
	a.check(not counts.has("A1"), "illegal (-1) candidates are never played")
	a.check(not counts.has("G5"), "candidates under 2%% of the largest are dropped")
	a.check_eq(counts.keys().size(), 2, "only the two usable candidates remain")
	# A pass entry in the list is not sampled as a normal move.
	var with_pass: Dictionary = make_analysis(size, ["E5", "C5", Coords.PASS],
		{"E5": 0.5, "C5": 0.5})
	var pass_counts: Dictionary = {}
	for i in 500:
		var result: Dictionary = player.choose_move(with_pass, size, Board.Stone.BLACK, 1, false)
		pass_counts[result["move"]] = int(pass_counts.get(result["move"], 0)) + 1
	a.check(not pass_counts.has(Coords.PASS), "the pass entry is dropped from sampling")
	# No usable policy at all: fall back to the engine's best move.
	var empty_policy: Dictionary = make_analysis(size, ["E5", "C5"], {})
	var fallback: Dictionary = player.choose_move(empty_policy, size, Board.Stone.BLACK, 1, false)
	a.check_eq(String(fallback["move"]), "E5", "falls back to the engine best without a human policy")
	a.check(fallback["reason"].contains("engine best"), "the fallback is reported in the reason")


func _test_pass_rules() -> void:
	a.section("ai player: pass rules")
	var size: int = 9
	var pass_first: Dictionary = make_analysis(size, [Coords.PASS, "E5"], {"E5": 0.9})
	var player: AiPlayer = AiPlayer.new()
	# Best move is pass and the opponent just passed: pass, ending the game.
	var result: Dictionary = player.choose_move(pass_first, size, Board.Stone.BLACK, 40, true)
	a.check_eq(String(result["move"]), Coords.PASS, "passes after the opponent passed")
	# Best is pass but we are early and the opponent did not pass: keep playing.
	var keep: Dictionary = player.choose_move(pass_first, size, Board.Stone.BLACK, 5, false)
	a.check_eq(String(keep["move"]), "E5", "does not pass early in the game")
	# Best is pass and we are well past half the board with no pass yet: pass.
	var late: Dictionary = player.choose_move(pass_first, size, Board.Stone.BLACK, 120, false)
	a.check_eq(String(late["move"]), Coords.PASS, "passes late enough to end the game")


func _test_resign_rules() -> void:
	a.section("ai player: resign rules")
	var size: int = 19
	var moves: Array = ["Q16"]
	var losing: Dictionary = make_analysis(size, moves, {"Q16": 1.0}, 0.01, -40.0)
	var player: AiPlayer = AiPlayer.new()
	# Black is the engine side: 1% win rate, 40 points behind, past move 100.
	var result: Dictionary = player.choose_move(losing, size, Board.Stone.BLACK, 150, false)
	a.check(bool(result["resign"]), "resigns when far behind late")
	a.check_eq(String(result["move"]), "", "a resignation offers no move")
	# Before move 100 the same position keeps playing.
	var early: Dictionary = player.choose_move(losing, size, Board.Stone.BLACK, 99, false)
	a.check(not bool(early["resign"]), "does not resign before move 100")
	# White's point of view is the mirror image.
	var white_losing: Dictionary = make_analysis(size, moves, {"Q16": 1.0}, 0.99, 40.0)
	var white_result: Dictionary = player.choose_move(white_losing, size, Board.Stone.WHITE, 150, false)
	a.check(bool(white_result["resign"]), "resigns as White when Black is far ahead")
	# Winning is never a resignation.
	var winning: Dictionary = make_analysis(size, moves, {"Q16": 1.0}, 0.99, 40.0)
	var black_winning: Dictionary = player.choose_move(winning, size, Board.Stone.BLACK, 150, false)
	a.check(not bool(black_winning["resign"]), "does not resign while winning")
	# Only one threshold met is not enough.
	var close_score: Dictionary = make_analysis(size, moves, {"Q16": 1.0}, 0.01, -10.0)
	a.check(not bool(player.choose_move(close_score, size, Board.Stone.BLACK, 150, false)["resign"]),
		"does not resign when only the win rate is low")
	var close_rate: Dictionary = make_analysis(size, moves, {"Q16": 1.0}, 0.10, -40.0)
	a.check(not bool(player.choose_move(close_rate, size, Board.Stone.BLACK, 150, false)["resign"]),
		"does not resign when only the score is bad")
	# The setting disables it entirely.
	player.allow_resign = false
	a.check(not bool(player.choose_move(losing, size, Board.Stone.BLACK, 150, false)["resign"]),
		"allow_resign = false disables resigning")


func _test_no_analysis() -> void:
	a.section("ai player: missing analysis")
	var player: AiPlayer = AiPlayer.new()
	var result: Dictionary = player.choose_move({}, 19, Board.Stone.BLACK, 1, false)
	a.check_eq(String(result["move"]), "", "no analysis means no move")
	a.check(not bool(result["resign"]), "and not a resignation")
	a.check(result["reason"].contains("no analysis"), "the reason says so")
	var no_moves: Dictionary = {"visits": 0, "winrate": 0.5, "score_lead": 0.0,
		"moves": [], "human_policy": []}
	var empty: Dictionary = player.choose_move(no_moves, 19, Board.Stone.BLACK, 1, false)
	a.check_eq(String(empty["move"]), "", "an empty candidate list yields no move")


func _test_beginner() -> void:
	a.section("ai player: beginner level")
	var beginner: AiPlayer = AiPlayer.new()
	beginner.configure("rank_beginner")
	a.check(beginner.is_beginner(), "rank_beginner is the beginner level")
	a.check_eq(beginner.sl_profile(), "rank_20k", "beginner asks KataGo for its lowest rank")
	beginner.configure("preaz_beginner")
	a.check_eq(beginner.sl_profile(), "preaz_20k", "pre-AI beginner keeps its family")
	a.check(not AiPlayer.new("rank_20k").is_beginner(), "20k is not the beginner level")
	# The search only offered D5, but the human policy also likes E5 and A1.
	# Beginner may pick any of them; the ranked levels only pick D5.
	var size: int = 9
	var analysis: Dictionary = make_analysis(size, ["D5"], {"D5": 0.5})
	var flat: Array = analysis["human_policy"]
	flat[Coords.from_gtp("E5", size).y * size + Coords.from_gtp("E5", size).x] = 0.3
	flat[Coords.from_gtp("A1", size).y * size + Coords.from_gtp("A1", size).x] = 0.2
	flat[Coords.from_gtp("J9", size).y * size + Coords.from_gtp("J9", size).x] = -1.0
	beginner.configure("rank_beginner")
	beginner.rng.seed = 7
	var seen: Dictionary = {}
	for i in 600:
		var move: String = String(beginner.choose_move(analysis, size, Board.Stone.BLACK, 1, false)["move"])
		seen[move] = int(seen.get(move, 0)) + 1
	a.check(seen.has("E5") and seen.has("A1"), "beginner plays moves the search did not offer: %s" % str(seen))
	a.check(not seen.has("J9"), "beginner never plays an illegal point")
	a.check(int(seen.get("D5", 0)) > int(seen.get("A1", 0)), "it still prefers the likelier move")
	var ranked: AiPlayer = AiPlayer.new("rank_20k")
	ranked.rng.seed = 7
	var ranked_seen: Dictionary = {}
	for i in 200:
		ranked_seen[String(ranked.choose_move(analysis, size, Board.Stone.BLACK, 1, false)["move"])] = true
	a.check_eq(ranked_seen.keys(), ["D5"], "20k still picks only from the search's moves")

