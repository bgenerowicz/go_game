extends RefCounted

## Review / mistake-classification tests, using hand-made analysis dictionaries
## so no engine is involved. The runner instantiates this and calls run(a).
var a: Assertions


func run() -> void:
	_test_loss_formula()
	_test_bands()
	_test_turns_and_mistakes()
	_test_lines_and_progress()
	_test_thresholds_are_configurable()
	_test_ownership_score()


## Fills a node with a fake analysis result.
func _analyse(node: GameNode, winrate: float, score_lead: float, visits: int = 100) -> void:
	node.analysis = {"visits": visits, "winrate": winrate, "score_lead": score_lead, "moves": []}


func _test_loss_formula() -> void:
	a.section("review: loss formula")
	# Black's score lead falling is a loss for Black.
	a.check_eq(Review.loss_for_move(5.0, 1.0, Board.Stone.BLACK), 4.0, "black gave away 4 points")
	a.check_eq(Review.loss_for_move(1.0, 5.0, Board.Stone.BLACK), -4.0, "black gained 4 points")
	# White's perspective is the mirror image.
	a.check_eq(Review.loss_for_move(1.0, 5.0, Board.Stone.WHITE), 4.0, "white gave away 4 points")
	a.check_eq(Review.loss_for_move(5.0, 1.0, Board.Stone.WHITE), -4.0, "white gained 4 points")
	a.check_eq(Review.loss_for_move(2.0, 2.0, Board.Stone.BLACK), 0.0, "no change, no loss")


func _test_bands() -> void:
	a.section("review: severity bands")
	var r: Review = Review.new()
	a.check_eq(r.classify_loss(0.0), Review.KIND_NONE, "0 is not a mistake")
	a.check_eq(r.classify_loss(1.9), Review.KIND_NONE, "1.9 stays under the threshold")
	a.check_eq(r.classify_loss(2.0), Review.KIND_INACCURACY, "2 is an inaccuracy")
	a.check_eq(r.classify_loss(4.9), Review.KIND_INACCURACY, "4.9 is still an inaccuracy")
	a.check_eq(r.classify_loss(5.0), Review.KIND_MISTAKE, "5 is a mistake")
	a.check_eq(r.classify_loss(9.9), Review.KIND_MISTAKE, "9.9 is still a mistake")
	a.check_eq(r.classify_loss(10.0), Review.KIND_BLUNDER, "10 is a blunder")
	a.check_eq(r.classify_loss(40.0), Review.KIND_BLUNDER, "40 is a blunder")
	a.check_eq(r.classify_loss(-3.0), Review.KIND_NONE, "a gain is never a mistake")
	# Thresholds come from settings.
	r.inaccuracy_at = 1.0
	r.mistake_at = 3.0
	r.blunder_at = 6.0
	a.check_eq(r.classify_loss(1.5), Review.KIND_INACCURACY, "custom inaccuracy band")
	a.check_eq(r.classify_loss(3.5), Review.KIND_MISTAKE, "custom mistake band")
	a.check_eq(r.classify_loss(6.5), Review.KIND_BLUNDER, "custom blunder band")
	a.check_eq(Review.severity_rank(Review.KIND_BLUNDER) > Review.severity_rank(
		Review.KIND_INACCURACY), true, "blunder outranks inaccuracy")


func _test_turns_and_mistakes() -> void:
	a.section("review: turns and mistakes")
	var t: GameTree = GameTree.new(19, 7.5)
	# Scores are Black-perspective. A rise is good for Black, a fall is good for
	# White, so the mover's loss depends on who moved.
	_analyse(t.root, 0.5, 0.0)
	var n1: GameNode = t.play_move(Board.Stone.BLACK, 3, 3)
	_analyse(n1, 0.55, 2.0)          # Black up 2 -> a good move
	var n2: GameNode = t.play_move(Board.Stone.WHITE, 15, 15)
	_analyse(n2, 0.75, 12.0)         # Black up 10 more -> White gave away 10
	var n3: GameNode = t.play_move(Board.Stone.BLACK, 9, 9)
	_analyse(n3, 0.3, 4.0)           # Black back down 8 -> Black gave away 8
	var r: Review = Review.new(t)
	var entries: Array = r.turns()
	a.check_eq(entries.size(), 3, "one entry per analysed turn")
	a.check_eq(int(entries[0]["turn"]), 1, "first entry is turn 1")
	a.check_eq(int(entries[0]["color"]), Board.Stone.BLACK, "turn 1 was played by black")
	a.check_eq(float(entries[0]["loss"]), -2.0, "turn 1 gained points")
	a.check_eq(String(entries[0]["kind"]), Review.KIND_NONE, "turn 1 is not a mistake")
	a.check_eq(String(entries[0]["move"]), "D16", "the entry names the move in GTP")
	a.check_eq(float(entries[1]["loss"]), 10.0, "turn 2: white lost 10 points")
	a.check_eq(int(entries[1]["color"]), Board.Stone.WHITE, "turn 2 was played by white")
	a.check_eq(String(entries[1]["kind"]), Review.KIND_BLUNDER, "10 points is a blunder")
	a.check_eq(float(entries[2]["loss"]), 8.0, "turn 3: black lost 8 points")
	a.check_eq(String(entries[2]["kind"]), Review.KIND_MISTAKE, "8 points is a mistake")
	var found: Array = r.mistakes()
	a.check_eq(found.size(), 2, "two mistakes listed")
	a.check_eq(int(found[0]["turn"]), 2, "listed worst first")
	a.check_eq(int(found[1]["turn"]), 3, "then the smaller one")
	a.check_eq(r.mistakes_for(Board.Stone.WHITE).size(), 1, "one white mistake")
	a.check_eq(r.mistakes_for(Board.Stone.BLACK).size(), 1, "one black mistake")
	a.check_eq(r.mistakes_for(Board.Stone.WHITE)[0]["kind"], Review.KIND_BLUNDER,
		"white's mistake is the blunder")
	a.check_eq(r.worst_loss(), 10.0, "worst loss is 10")


func _test_lines_and_progress() -> void:
	a.section("review: graph lines and progress")
	var t: GameTree = GameTree.new(9, 6.0)
	var r: Review = Review.new(t)
	a.check_eq(r.main_line_turns(), 0, "an empty tree has no turns")
	a.check_eq(r.analysed_turns(), 0, "and no analysis")
	a.check_eq(r.is_complete(), false, "so it is not complete")
	var n1: GameNode = t.play_move(Board.Stone.BLACK, 2, 2)
	var n2: GameNode = t.play_move(Board.Stone.WHITE, 6, 6)
	a.check_eq(r.main_line_turns(), 2, "two turns after two moves")
	a.check_eq(r.analysed_turns(), 0, "still nothing analysed")
	_analyse(n1, 0.6, 1.5)
	var rates: Array = r.winrate_line()
	var leads: Array = r.score_lead_line()
	a.check_eq(rates.size(), 3, "root plus two turns")
	a.check_eq(rates[0] == null, true, "the unanalysed root is a gap")
	a.check_eq(rates[1], 0.6, "the analysed turn carries its win rate")
	a.check_eq(leads[1], 1.5, "and its score lead")
	a.check_eq(r.analysed_turns(), 1, "one turn analysed")
	a.check_eq(r.is_complete(), false, "not complete yet")
	_analyse(t.root, 0.5, 0.0)
	_analyse(n2, 0.4, -2.0)
	a.check_eq(r.analysed_turns(), 2, "both turns analysed")
	a.check_eq(r.is_complete(), true, "the review is complete")
	a.check_eq(r.turns().size(), 2, "both turns classified")
	# A side variation is not part of the main-line graph.
	t.go_to(n1)
	t.play_move(Board.Stone.WHITE, 5, 5)
	a.check_eq(r.main_line_turns(), 2, "the variation does not extend the main line")
	a.check_eq(r.turns().size(), 2, "and adds no graph entry")


func _test_thresholds_are_configurable() -> void:
	a.section("review: thresholds are settings")
	var r: Review = Review.new()
	a.check_eq(r.classify_loss(1.9), Review.KIND_NONE, "below the inaccuracy band")
	a.check_eq(r.classify_loss(2.0), Review.KIND_INACCURACY, "inaccuracy at 2")
	a.check_eq(r.classify_loss(5.0), Review.KIND_MISTAKE, "mistake at 5")
	a.check_eq(r.classify_loss(10.0), Review.KIND_BLUNDER, "blunder at 10")
	# A user who wants a stricter review lowers the thresholds; the same loss is
	# then reported in a higher band.
	r.inaccuracy_at = 1.0
	r.mistake_at = 1.5
	r.blunder_at = 2.0
	a.check_eq(r.classify_loss(1.2), Review.KIND_INACCURACY, "lowered inaccuracy band")
	a.check_eq(r.classify_loss(1.6), Review.KIND_MISTAKE, "lowered mistake band")
	a.check_eq(r.classify_loss(2.0), Review.KIND_BLUNDER, "lowered blunder band")
	# A laxer review hides small losses entirely: raise every band together.
	r.inaccuracy_at = 20.0
	r.mistake_at = 30.0
	r.blunder_at = 40.0
	a.check_eq(r.classify_loss(12.0), Review.KIND_NONE, "a lax threshold reports nothing")


func _test_ownership_score() -> void:
	a.section("review: ownership score estimate")
	# 19 points fully Black, 15 fully White, the rest neutral: Black is +4.
	var ownership: Array = []
	for i in 19:
		ownership.append(1.0)
	for i in 15:
		ownership.append(-1.0)
	for i in 11:
		ownership.append(0.0)
	a.check_eq(Review.ownership_score(ownership), 4.0, "the sum is the estimate")
	a.check_eq(Review.ownership_text(ownership), "Black +4.0", "reported as Black +x.x")
	# Partial ownership counts partially, which is what makes the estimate useful.
	var partial: Array = [0.5, 0.5, -0.25]
	a.check_eq(Review.ownership_score(partial), 0.75, "fractional ownership sums")
	a.check_eq(Review.ownership_text(partial), "Black +0.8", "rounded to one decimal")
	var white: Array = [-1.0, -1.0, -1.0]
	a.check_eq(Review.ownership_text(white), "White +3.0", "a negative sum names White")
	a.check_eq(Review.ownership_text([]), "", "no ownership, no text")
	# A stray pass entry or out-of-range value must not skew the count.
	var with_pass_entry: Array = ownership.duplicate()
	with_pass_entry.append(0.0)
	a.check_eq(Review.ownership_score(with_pass_entry), 4.0, "an extra entry is harmless")
