extends SceneTree

## Milestone 5 check: play 30 moves of engine-vs-engine at
## rank_10k, with every move checked for legality against Board before it is
## played, then exit cleanly with no orphaned katago process.
##
## Run with:  godot --headless --script tests/check_ai_game.gd
## Exits 0 on success, non-zero on failure. Skips (exit 0) when the gitignored
## engine files are absent, saying so loudly.

const MOVES_TO_PLAY: int = 30
const VISITS: int = 30
const PROFILE: String = "rank_10k"
const BOARD_SIZE: int = 19
const TIMEOUT_SECONDS: float = 900.0

var proc: Node = null
var analysis: Node = null
var ai: AiPlayer = null
var flow: GameFlow = GameFlow.new()

var elapsed: float = 0.0
var engine_ready: bool = false
var awaiting_move: bool = false
var played: int = 0
var finished: bool = false
var failures: PackedStringArray = PackedStringArray()


func _init() -> void:
	print("=== milestone 5 check: human-like opponent, %d moves at %s ===" \
		% [MOVES_TO_PLAY, PROFILE])
	proc = load("res://scripts/engine/katago_process.gd").new()
	root.add_child(proc)
	if not proc.is_available():
		print("SKIP: engine files are not present (they are gitignored):")
		for missing in proc.missing_files():
			print("  missing: ", missing)
		print("Copy the KataGo binary into runtime/katago/ and the networks into " \
			+ "engine/models/, then re-run.")
		quit(0)
		return
	if proc.human_model_path.is_empty():
		print("SKIP: engine/models/human.bin.gz is missing, so no human-like " \
			+ "profile can run. A strong-play opponent would still work.")
		quit(0)
		return
	analysis = load("res://scripts/engine/analysis_service.gd").new()
	root.add_child(analysis)
	analysis.use_engine(proc)
	ai = AiPlayer.new(PROFILE, "modern")
	ai.visits = VISITS
	flow.start(BOARD_SIZE, 7.5, "chinese", 0)
	proc.engine_ready.connect(_on_engine_ready)
	proc.engine_failed.connect(_on_engine_failed)
	proc.log_line.connect(_on_log_line)
	analysis.analysis_updated.connect(_on_analysis)
	if not proc.start_engine():
		_fail("start_engine() returned false: " + proc.start_error())
		_finish()


func _process(delta: float) -> bool:
	if finished:
		return true
	elapsed += delta
	if elapsed > TIMEOUT_SECONDS:
		_fail("timed out after %d seconds, having played %d moves" % [int(TIMEOUT_SECONDS), played])
		_finish()
		return true
	if engine_ready and not awaiting_move and not flow.over:
		if played >= MOVES_TO_PLAY:
			_finish()
			return true
		_ask_for_move()
	return false


func _on_engine_ready() -> void:
	engine_ready = true
	print("  ok   engine up (%s) after %.1fs" % [proc.version, elapsed])
	print("  ...  human model: %s" % proc.human_model_path.get_file())


func _ask_for_move() -> void:
	var node: GameNode = flow.current()
	var id: String = ai.request_move(analysis, flow.tree, node)
	if id == "":
		_fail("analysis request failed before move %d" % (played + 1))
		_finish()
		return
	awaiting_move = true
	print("  ...  move %d: %s to play (query %s, %d visits)" \
		% [played + 1, _color_name(flow.turn()), id, ai.visits])


func _on_analysis(node: GameNode) -> void:
	if not awaiting_move or finished or node != flow.current():
		return
	if node.analysis.is_empty():
		return
	awaiting_move = false
	var color: int = flow.turn()
	var previous_was_pass: bool = node.is_pass()
	var choice: Dictionary = ai.choose_move(node.analysis, flow.tree.size, color,
		played + 1, previous_was_pass)
	var move: String = String(choice["move"])

	if bool(choice["resign"]):
		print("  ok   %s resigns at move %d: %s" \
			% [_color_name(color), played + 1, String(choice["reason"])])
		flow.resign(color)
		_finish()
		return
	if move.is_empty():
		_fail("no move offered before move %d: %s" % [played + 1, String(choice["reason"])])
		_finish()
		return

	# The milestone check: every move must be legal according to Board.
	var board: Board = flow.board()
	if move == Coords.PASS:
		if not flow.pass_move():
			_fail("Board refused a pass at move %d: %s" % [played + 1, flow.last_error])
			_finish()
			return
	else:
		var point: Vector2i = Coords.from_gtp(move, flow.tree.size)
		if point == Coords.INVALID:
			_fail("engine returned an unparseable move '%s' at move %d" % [move, played + 1])
			_finish()
			return
		if not board.is_legal(point.x, point.y, color):
			_fail("engine offered an illegal move %s at move %d" % [move, played + 1])
			_finish()
			return
		if not flow.play(point.x, point.y):
			_fail("Board refused the engine's move %s at move %d: %s" \
				% [move, played + 1, flow.last_error])
			_finish()
			return
	played += 1
	print("  ok   move %d: %s %s  (%s)" % [played, _color_name(color), move, String(choice["reason"])])


func _color_name(color: int) -> String:
	return "B" if color == Board.Stone.BLACK else "W"


func _on_engine_failed(message: String) -> void:
	print("  !!   engine failed: ", message)
	for line in proc.last_log_lines(20):
		print("       stderr: ", line)


func _on_log_line(line: String) -> void:
	print("       [katago] ", line)


func _fail(message: String) -> void:
	failures.append(message)


func _finish() -> void:
	if finished:
		return
	finished = true
	print("  ...  played %d of %d requested moves" % [played, MOVES_TO_PLAY])
	if proc != null:
		var was_pid: int = proc.last_pid if proc.last_pid != -1 else proc.pid
		proc.stop_engine()
		if proc.is_alive():
			_fail("the engine process is still running after stop_engine()")
		else:
			print("  ok   no orphaned engine process (pid ", was_pid, " is gone)")
	if flow.over:
		print("  ok   the game ended on the board's own terms: ", flow.result_text)
	print("=== %d failure(s) ===" % failures.size())
	if failures.is_empty() and played >= MOVES_TO_PLAY:
		print("AI_GAME_CHECK_PASSED")
		quit(0)
	else:
		print("AI_GAME_CHECK_FAILED")
		quit(1)
