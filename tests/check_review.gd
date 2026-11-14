extends SceneTree

## Milestone 6 check (PLAN section 7): loading a test SGF produces a result for
## every turn of the main line, the graph data is complete, and clicking the
## graph navigates.
##
## Run with:  godot --headless --script tests/check_review.gd
## Exits 0 on success, non-zero on failure. Skips (exit 0) when the gitignored
## engine files are absent, saying so loudly.

const SGF_PATH: String = "res://testdata/cornermoves.sgf"
const VISITS: int = 40
const TIMEOUT_SECONDS: float = 600.0

var proc: Node = null
var analysis: Node = null
var review: Review = null
var tree: GameTree = null
var graph: GraphView = null

var elapsed: float = 0.0
var engine_ready: bool = false
var review_started: bool = false
var finished: bool = false
var failures: PackedStringArray = PackedStringArray()


func _init() -> void:
	print("=== milestone 6 check: full-game review of %s ===" % SGF_PATH.get_file())
	var parsed: Dictionary = SGF.parse_file(SGF_PATH)
	if not bool(parsed["ok"]):
		print("FAIL: the fixture does not parse: ", str(parsed["error"]))
		quit(1)
		return
	tree = parsed["tree"]
	print("  ok   loaded %d moves, %dx%d, komi %s"
		% [tree.main_line_length(), tree.size, tree.size, str(tree.komi)])

	proc = load("res://scripts/engine/katago_process.gd").new()
	root.add_child(proc)
	if not proc.is_available():
		print("SKIP: engine files are not present (they are gitignored):")
		for missing in proc.missing_files():
			print("  missing: ", missing)
		quit(0)
		return
	analysis = load("res://scripts/engine/analysis_service.gd").new()
	root.add_child(analysis)
	analysis.use_engine(proc)
	review = Review.new(tree)

	# The graph is a real Control so the click mapping is exercised for real.
	graph = GraphView.new()
	graph.size = Vector2(600, 160)
	root.add_child(graph)
	graph.turn_clicked.connect(_on_graph_click)

	proc.engine_ready.connect(func() -> void: engine_ready = true)
	proc.log_line.connect(func(line: String) -> void:
		# KataGo startup chatter is normal; only problems are interesting here.
		if line.contains("rror") or line.contains("arning"):
			print("  << engine: ", line))
	proc.engine_failed.connect(func(message: String) -> void:
		print("  !!   engine failed: ", message)
		for line in proc.last_log_lines(20):
			print("       stderr: ", line))
	analysis.review_progress.connect(func(done: int, total: int) -> void:
		print("  ...  analysed %d / %d turns" % [done, total]))
	analysis.review_finished.connect(_on_review_finished)
	analysis.review_failed.connect(func(message: String) -> void:
		_fail("review failed: " + message)
		_finish())

	if not proc.start_engine():
		_fail("start_engine() returned false: " + proc.start_error())
		_finish()


func _process(delta: float) -> bool:
	if finished:
		return true
	elapsed += delta
	if elapsed > TIMEOUT_SECONDS:
		_fail("timed out after %d seconds" % int(TIMEOUT_SECONDS))
		_finish()
		return true
	if engine_ready and not review_started:
		review_started = true
		var id: String = analysis.request_review(tree, VISITS)
		if id == "":
			_fail("request_review() returned no id")
			_finish()
		else:
			print("  ...  review query ", id, " at ", VISITS, " visits")
	return false


func _on_review_finished() -> void:
	print("  ok   review finished after %.1fs" % elapsed)
	_check_every_turn_has_a_result()
	_check_graph_data()
	_check_mistakes_list()
	_check_graph_navigation()
	_finish()


var navigated_to: int = -1


func _on_graph_click(turn: int) -> void:
	navigated_to = turn
	var line: Array[GameNode] = tree.main_line()
	if turn >= 0 and turn < line.size():
		tree.go_to(line[turn])


func _check_every_turn_has_a_result() -> void:
	var line: Array[GameNode] = tree.main_line()
	var missing: int = 0
	for i in range(1, line.size()):
		if not review.has_analysis(line[i]):
			_fail("turn %d (%s) has no analysis result" % [i, line[i].gtp_move(tree.size)])
			missing += 1
	if missing == 0:
		print("  ok   every one of the %d main-line turns has a result" % (line.size() - 1))
	for i in range(1, line.size()):
		var moves: Array = line[i].analysis["moves"] as Array
		if moves.is_empty():
			_fail("turn %d has no candidate moves" % i)
	var visits: int = int(line[line.size() - 1].analysis["visits"])
	if visits <= 0:
		_fail("the last turn reports %d visits" % visits)
	else:
		print("  ok   last turn analysed at %d visits, winrate %.3f, score lead %+.1f"
			% [visits, float(line[line.size() - 1].analysis["winrate"]),
				float(line[line.size() - 1].analysis["score_lead"])])


func _check_graph_data() -> void:
	var line: Array[GameNode] = tree.main_line()
	var rates: Array = review.winrate_line()
	var leads: Array = review.score_lead_line()
	if rates.size() != line.size():
		_fail("win-rate line has %d points, expected %d" % [rates.size(), line.size()])
	if leads.size() != line.size():
		_fail("score-lead line has %d points, expected %d" % [leads.size(), line.size()])
	var gaps: int = 0
	for i in rates.size():
		if rates[i] == null:
			gaps += 1
			continue
		var value: float = float(rates[i])
		if value < 0.0 or value > 1.0:
			_fail("win rate at turn %d is %s, outside 0..1" % [i, str(value)])
	if gaps > 0:
		_fail("%d turns have a gap in the win-rate line" % gaps)
	else:
		print("  ok   graph lines complete: %d points, no gaps" % rates.size())
	graph.show_position(tree, review, tree.move_count_to(tree.current))
	graph.refresh_data()
	print("  ok   graph refreshed without error (%d mistake dots)" % graph._mistake_by_turn.size())


func _check_mistakes_list() -> void:
	var entries: Array = review.turns()
	if entries.size() != tree.main_line_length():
		_fail("classified %d turns, expected %d" % [entries.size(), tree.main_line_length()])
	var known: Array = [Review.KIND_NONE, Review.KIND_INACCURACY,
		Review.KIND_MISTAKE, Review.KIND_BLUNDER]
	for entry in entries:
		if not known.has(String(entry["kind"])):
			_fail("turn %d has an unknown kind '%s'" % [int(entry["turn"]), String(entry["kind"])])
	var found: Array = review.mistakes()
	print("  ok   %d classified turns, %d at or above the inaccuracy threshold " \
		% [entries.size(), found.size()])
	for entry in found.slice(0, 5):
		print("       %s move %d (%s): %.1f points - %s" % [
			Review.color_name(int(entry["color"])), int(entry["turn"]),
			String(entry["move"]), float(entry["loss"]), String(entry["kind"])])
	for entry in review.mistakes_for(Board.Stone.BLACK, 3):
		if int(entry["color"]) != Board.Stone.BLACK:
			_fail("mistakes_for(black) returned a white move")
			break


func _check_graph_navigation() -> void:
	var turns: int = tree.main_line_length()
	# The ends and the middle of the plot must map back to the right turns.
	var checks: Array = [0, int(round(turns / 4.0)), int(round(turns / 2.0)), turns]
	for wanted in checks:
		var fraction: float = float(wanted) / float(turns)
		var x: float = GraphView.MARGIN_LEFT \
			+ fraction * (graph.size.x - GraphView.MARGIN_LEFT - GraphView.MARGIN_RIGHT)
		var got: int = graph.turn_at_position(Vector2(x, graph.size.y * 0.5))
		if got != int(wanted):
			_fail("a click at x=%.1f mapped to turn %d, expected %d" % [x, got, int(wanted)])
	# A click outside the plot is ignored.
	if graph.turn_at_position(Vector2(4.0, graph.size.y * 0.5)) != -1:
		_fail("a click in the left margin should be ignored")
	# And the signal must actually move the current node.
	navigated_to = -1
	graph.turn_clicked.emit(int(round(turns / 2.0)))
	if navigated_to != int(round(turns / 2.0)):
		_fail("the graph click did not reach the handler")
	elif tree.move_count_to(tree.current) != int(round(turns / 2.0)):
		_fail("the click navigated to move %d, expected %d"
			% [tree.move_count_to(tree.current), int(round(turns / 2.0))])
	else:
		print("  ok   clicking the graph navigates (turn %d)" % navigated_to)


func _fail(message: String) -> void:
	failures.append(message)
	print("  FAIL ", message)


func _finish() -> void:
	if finished:
		return
	finished = true
	if proc != null:
		var was_pid: int = proc.last_pid if proc.last_pid != -1 else proc.pid
		proc.stop_engine()
		if proc.is_alive():
			_fail("the engine process is still running after stop_engine()")
		else:
			print("  ok   no orphaned engine process (pid ", was_pid, " is gone)")
	print("=== %d failure(s) ===" % failures.size())
	if failures.is_empty():
		print("REVIEW_CHECK_PASSED")
		quit(0)
	else:
		print("REVIEW_CHECK_FAILED")
		quit(1)

