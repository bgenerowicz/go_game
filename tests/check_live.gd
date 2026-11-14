extends SceneTree

## Milestone 7 check (PLAN section 7): candidate circles, hover variations,
## ownership overlay and live analysis.
##
##   Check: changing position cancels the old live query (confirm by logging ids)
##   and overlays update without stutter.
##
## Run with:  godot --headless --script tests/check_live.gd
## Exits 0 on success, non-zero on failure. Skips (exit 0) when the gitignored
## engine files are absent, saying so loudly.

const SGF_PATH: String = "res://testdata/cornermoves.sgf"
const VISITS: int = 300
const TIMEOUT_SECONDS: float = 420.0

var proc: Node = null
var analysis: Node = null
var tree: GameTree = null
var board: BoardView = null

var elapsed: float = 0.0
var engine_ready: bool = false
var finished: bool = false
var failures: PackedStringArray = PackedStringArray()

## Everything the engine was asked to do, in order, for the id log.
var sent: Array = []
## Live query bookkeeping.
var live_ids: Array[String] = []
var live_updates: int = 0
var visits_seen: Array = []
var phase: int = 0
var first_live_id: String = ""
var second_live_id: String = ""
var best_point: Vector2i = Board.INVALID
## Latest time to wait for the second position to produce candidates.
var _probe_deadline: float = 0.0


func _init() -> void:
	print("=== milestone 7 check: candidates, hover pv, ownership, live analysis ===")
	var parsed: Dictionary = SGF.parse_file(SGF_PATH)
	if not bool(parsed["ok"]):
		print("FAIL: the fixture does not parse: ", str(parsed["error"]))
		quit(1)
		return
	tree = parsed["tree"]
	print("  ok   loaded %d moves, %dx%d" % [tree.main_line_length(), tree.size, tree.size])

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

	board = BoardView.new()
	board.size = Vector2(600, 600)
	root.add_child(board)

	proc.engine_ready.connect(func() -> void: engine_ready = true)
	proc.engine_failed.connect(func(message: String) -> void:
		print("  !!   engine failed: ", message)
		for line in proc.last_log_lines(20):
			print("       stderr: ", line))
	proc.request_sent.connect(_on_sent)
	analysis.live_updated.connect(_on_live_update)

	if not proc.start_engine():
		_fail("start_engine() returned false: " + proc.start_error())
		_finish()


func _on_sent(request: Dictionary) -> void:
	sent.append(request)
	var action: String = String(request.get("action", "analyze"))
	print("  send %-9s id=%s" % [action, String(request.get("id", ""))])


func _on_live_update(node: GameNode) -> void:
	live_updates += 1
	# Mirror what main.gd does: only the position on screen gets the overlays.
	if node == board.node:
		board.set_analysis(node.analysis)
	var visits: int = int(node.analysis.get("visits", 0))
	visits_seen.append({"node": node, "visits": visits})
	print("  live #%d node move %d: %d visits, %d candidates, ownership %d"
		% [live_updates, tree.move_count_to(node), visits,
			board.candidate_list.size(), (node.analysis.get("ownership", []) as Array).size()])
	if phase == 1:
		# Leave the first query running a little so partial results show up.
		if live_updates >= 2:
			_navigate()


func _process(delta: float) -> bool:
	if finished:
		return true
	elapsed += delta
	if elapsed > TIMEOUT_SECONDS:
		_fail("timed out after %d seconds" % int(TIMEOUT_SECONDS))
		_finish()
		return true
	if engine_ready and phase == 0:
		phase = 1
		var node: GameNode = tree.find_by_move_index(2)
		board.show_position(tree, node)
		first_live_id = analysis.request_live(tree, node, VISITS)
		if first_live_id == "":
			_fail("request_live() returned no id")
			_finish()
		else:
			live_ids.append(first_live_id)
			print("  ...  live query %s on the position after move 2, %d visits"
				% [first_live_id, VISITS])
	elif phase == 3 and (not board.candidate_list.is_empty() or elapsed > _probe_deadline):
		_probe_hover()
	return false


## Hovering a candidate must select it and expose its pv; hovering empty space
## must clear the selection so the variation disappears.
func _probe_hover() -> void:
	phase = 4
	if board.candidate_list.is_empty():
		_fail("no candidate circles were built")
		_finish()
		return
	var best: Dictionary = board.candidate_list[0] as Dictionary
	best_point = best["point"] as Vector2i
	var center: Vector2 = board.point_center(best_point.x, best_point.y)
	var index: int = board.candidate_at(center)
	if index != 0:
		_fail("hovering the best candidate returned %d, expected 0" % index)
	else:
		print("  ok   hovering the best candidate at ", best_point, " selects it")
	board.hovered_candidate = index
	var pv: Array = best.get("pv", []) as Array
	if pv.is_empty():
		_fail("the best candidate carries no pv to draw")
	else:
		print("  ok   its pv has %d moves: %s" % [pv.size(), str(pv.slice(0, 4))])
	var far: int = board.candidate_at(Vector2(2.0, 2.0))
	if far != -1:
		_fail("hovering outside every circle still selects a candidate")
	else:
		print("  ok   hovering empty space clears the variation")
	# The move actually played should be ringed when it is among the candidates.
	var ringed: int = 0
	for entry in board.candidate_list:
		if bool((entry as Dictionary)["played"]):
			ringed += 1
	print("  ...  %d candidate(s) ringed as the move actually played" % ringed)
	_check_overlays()
	_finish()


func _check_overlays() -> void:
	var node: GameNode = tree.find_by_move_index(3)
	if node.analysis.is_empty():
		_fail("the second live query produced no analysis")
		return
	var ownership: Array = node.analysis.get("ownership", []) as Array
	if ownership.size() != tree.size * tree.size:
		_fail("ownership has %d entries, expected %d" % [ownership.size(), tree.size * tree.size])
	else:
		print("  ok   ownership covers all %d points" % ownership.size())
	# Candidates: capped, ordered best first, losses measured against the best.
	if board.candidate_list.size() > BoardView.MAX_CANDIDATES:
		_fail("%d candidates drawn, the cap is %d"
			% [board.candidate_list.size(), BoardView.MAX_CANDIDATES])
	var root_visits: int = int(node.analysis.get("visits", 0))
	var weak: int = 0
	for entry in board.candidate_list:
		var info: Dictionary = entry as Dictionary
		if int(info["visits"]) < int(float(root_visits) * BoardView.MIN_VISIT_FRACTION):
			weak += 1
	if weak > 0:
		_fail("%d candidate(s) below the 1%% visit floor were drawn" % weak)
	else:
		print("  ok   every candidate clears the 1%% visit floor (%d shown)"
			% board.candidate_list.size())
	if not bool((board.candidate_list[0] as Dictionary)["is_best"]):
		_fail("the first candidate is not marked best")
	if absf(float((board.candidate_list[0] as Dictionary)["loss"])) > 0.001:
		_fail("the best candidate should have zero loss")
	# Overlays must not stutter: within one position, visits only ever increase,
	# and one query per position change rather than one per mouse move.
	var decreasing: int = 0
	var previous_node: GameNode = null
	var previous_visits: int = 0
	for update in visits_seen:
		var node_of_update: GameNode = update["node"] as GameNode
		var visits_of_update: int = int(update["visits"])
		if previous_node == node_of_update and visits_of_update < previous_visits:
			decreasing += 1
		previous_node = node_of_update
		previous_visits = visits_of_update
	if decreasing > 0:
		_fail("%d live update(s) lowered the visit count" % decreasing)
	else:
		var visit_log: String = ""
		for update in visits_seen:
			visit_log += str(int(update["visits"])) + " "
		print("  ok   %d live updates, visits never went backwards (%s)"
			% [visits_seen.size(), visit_log.strip_edges()])
	var analyze_count: int = 0
	for request in sent:
		if not (request as Dictionary).has("action"):
			analyze_count += 1
	if analyze_count != live_ids.size():
		_fail("%d analyze queries sent for %d positions" % [analyze_count, live_ids.size()])
	else:
		print("  ok   exactly one analyze query per position (%d), no per-mouse-move spam"
			% analyze_count)
	print("  ...  live query ids: ", ", ".join(live_ids))


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
			print("  ok   engine stopped, pid ", was_pid, " is gone")
	print("=== %d failure(s) ===" % failures.size())
	if failures.is_empty():
		print("LIVE_CHECK_PASSED")
		quit(0)
	else:
		print("LIVE_CHECK_FAILED")
		quit(1)


## Moving to another position must terminate the query it replaces, first.
func _navigate() -> void:
	phase = 2
	var node: GameNode = tree.find_by_move_index(3)
	var before: int = sent.size()
	board.show_position(tree, node)
	var id: String = analysis.request_live(tree, node, VISITS)
	second_live_id = id
	live_ids.append(id)
	var terminates: Array = []
	for i in range(before, sent.size()):
		var request: Dictionary = sent[i] as Dictionary
		if String(request.get("action", "")) == "terminate":
			terminates.append(String(request.get("terminateId", "")))
			print("  ok   terminate sent for superseded live query ",
				String(request.get("terminateId", "")))
		else:
			print("  ...  new query ", String(request.get("id", "")), " sent after the terminate")
	if terminates.size() != 1:
		_fail("expected exactly one terminate when the position changed, got %d" % terminates.size())
	elif String(terminates[0]) != first_live_id:
		_fail("terminate targeted %s but the live query was %s" % [str(terminates[0]), first_live_id])
	if id == first_live_id:
		_fail("the new position reused the old query id")
	# The terminate must come before the replacement query.
	var terminate_index: int = -1
	var query_index: int = -1
	for i in range(before, sent.size()):
		var request: Dictionary = sent[i] as Dictionary
		if String(request.get("action", "")) == "terminate" and terminate_index == -1:
			terminate_index = i
		elif not request.has("action") and query_index == -1:
			query_index = i
	if terminate_index == -1 or query_index == -1 or terminate_index > query_index:
		_fail("the terminate was not sent before the replacement query")
	# Asking again for the same position must not pile up queries.
	var again: String = analysis.request_live(tree, node, VISITS)
	if again != id:
		_fail("re-requesting the same position started a second query (%s vs %s)" % [again, id])
	else:
		print("  ok   re-requesting the same position reuses query ", id)
	phase = 3
	# Give the second position time to reach a visit count where the 1% floor
	# keeps candidates; CPU-only KataGo is slow.
	_probe_deadline = elapsed + 180.0
