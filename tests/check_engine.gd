extends SceneTree

## Milestone 4 check: start KataGo headless, get a query_version
## reply, analyse an empty 19x19 board at 50 visits, print the best move and exit
## cleanly with no orphaned katago process.
##
## Run with:  godot --headless --script tests/check_engine.gd
## Exits 0 on success, non-zero on failure. Skips (exit 0) when the gitignored
## engine files are absent, saying so loudly.

const TIMEOUT_SECONDS: float = 420.0
const QUERY_ID: String = "check_empty_19"

var proc: Node = null
var elapsed: float = 0.0
var got_version: bool = false
var got_result: bool = false
var failures: PackedStringArray = PackedStringArray()
var finished: bool = false


func _init() -> void:
	print("=== milestone 4 check: KataGo engine process ===")
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
	proc.engine_ready.connect(_on_engine_ready)
	proc.response_received.connect(_on_response)
	proc.engine_failed.connect(_on_engine_failed)
	proc.log_line.connect(_on_log_line)
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
	return false


func _on_engine_ready() -> void:
	got_version = true
	print("  ok   query_version answered, KataGo version ", proc.version)
	print("  ok   engine up after %.1fs" % elapsed)
	var query: Dictionary = {
		"id": QUERY_ID,
		"moves": [],
		"rules": "japanese",
		"komi": 6.5,
		"boardXSize": 19,
		"boardYSize": 19,
		"analyzeTurns": [0],
		"maxVisits": 50,
		"includeOwnership": true,
		"analysisPVLen": 15,
		"priority": 10,
	}
	print("sending a 50-visit analysis of an empty 19x19 board ...")
	if not proc.send(query):
		_fail("send() reported a write failure")
		_finish()


func _on_response(response: Dictionary) -> void:
	if String(response.get("id", "")) != QUERY_ID:
		return
	if response.has("error"):
		_fail("engine error: %s (field %s)" % [str(response["error"]), str(response.get("field", ""))])
		_finish()
		return
	if bool(response.get("isDuringSearch", false)):
		return
	got_result = true
	var root_info: Dictionary = response.get("rootInfo", {})
	var infos: Array = response.get("moveInfos", [])
	print("  ok   final answer after %.1fs" % elapsed)
	print("     turnNumber ", int(response.get("turnNumber", -1)), \
		" currentPlayer ", String(root_info.get("currentPlayer", "?")))
	print("     root visits ", int(root_info.get("visits", 0)), \
		" winrate %.3f" % float(root_info.get("winrate", 0.0)), \
		" scoreLead %.2f" % float(root_info.get("scoreLead", 0.0)))
	if infos.is_empty():
		_fail("moveInfos was empty")
		_finish()
		return
	var best: Dictionary = infos[0]
	var best_move: String = String(best["move"])
	print("     candidates: ", infos.size(), ", best move ", best_move, \
		" visits ", int(best.get("visits", 0)), \
		" winrate %.3f" % float(best.get("winrate", 0.0)))
	var pv: Array = best.get("pv", [])
	var pv_text: String = ""
	for v in pv:
		if not pv_text.is_empty():
			pv_text += ", "
		pv_text += str(v)
	print("     pv: ", pv_text)
	var ownership: Array = response.get("ownership", [])
	print("     ownership entries: ", ownership.size())

	_check(int(root_info.get("visits", 0)) >= 1, "root visits are reported")
	_check(infos.size() >= 2, "at least two candidate moves")
	_check(int(best.get("order", -1)) == 0, "the first candidate is order 0")
	_check(ownership.size() == 19 * 19, "ownership has one value per point")
	for value in ownership:
		if float(value) < -1.0 or float(value) > 1.0:
			_fail("ownership value out of range: %s" % str(value))
			break
	_check(not best_move.is_empty(), "the best move is a string")

	# The printed move must be a legal GTP coordinate and playable on our Board.
	if Coords.is_pass(best_move) or Coords.from_gtp(best_move, 19) != Coords.INVALID:
		print("  ok   best move is a valid GTP coordinate for 19x19")
		var board: Board = Board.new(19)
		if board.play_gtp(best_move, Board.Stone.BLACK):
			var point: Vector2i = Coords.from_gtp(best_move, 19)
			print("  ok   best move is legal on our own Board at x=", point.x, " y=", point.y)
		else:
			_fail("our Board rejected the engine's move " + best_move)
	else:
		_fail("best move is not a valid GTP coordinate: " + best_move)

	_finish()


func _on_engine_failed(message: String) -> void:
	_fail("engine_failed: " + message)
	_finish()


func _on_log_line(line: String) -> void:
	print("  stderr: ", line)


func _check(condition: bool, label: String) -> void:
	if condition:
		print("  ok   ", label)
	else:
		_fail(label)


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
		print("engine stopped, is_alive() = ", proc.is_alive())
		if proc.is_alive():
			_fail("the engine process is still running after stop_engine()")
		else:
			print("  ok   no orphaned engine process (pid ", was_pid, " is gone)")
	print("=== %d failure(s) ===" % failures.size())
	if failures.is_empty() and got_version and got_result:
		print("ENGINE_CHECK_PASSED")
		quit(0)
	else:
		print("ENGINE_CHECK_FAILED")
		quit(1)
