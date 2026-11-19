extends SceneTree

## Puzzle mode against the real engine: corner life-and-death problems with a
## known answer, each asked once as an ordinary whole-board query and once in
## puzzle mode. Puzzle mode must find the vital point every time; the ordinary
## answer is printed for comparison.
##
## Run with:  godot --headless --path . --script tests/check_puzzle.gd
## Exits 0 on success, non-zero on failure. Skips (exit 0) when the gitignored
## engine files are absent.

const VISITS: int = 400
const TIMEOUT_SECONDS: float = 300.0

## Straight three on the edge (eye space A19-C19): the middle point B19 decides.
const STRAIGHT_THREE: String = "AW[ab][bb][cb][db][da]AB[ac][bc][cc][dc][ec][eb][ea]"
## Bent three in the corner (A19, B19, A18): the corner point A19 decides.
const BENT_THREE: String = "AW[ca][cb][bb][bc][ac]AB[da][db][dc][cc][cd][bd][ad]"

## [name, setup, player to move, the one right answer]
const CASES: Array = [
	["straight three, Black kills", STRAIGHT_THREE, "B", "B19"],
	["straight three, White lives", STRAIGHT_THREE, "W", "B19"],
	["bent three, Black kills", BENT_THREE, "B", "A19"],
	["bent three, White lives", BENT_THREE, "W", "A19"],
]

var proc: Node = null
var analysis: Node = null
var elapsed: float = 0.0
var ready_to_go: bool = false
var finished: bool = false
var failures: PackedStringArray = PackedStringArray()

var case_index: int = 0
var puzzle: bool = false
var tree: GameTree = null
var waiting_id: String = ""


func _init() -> void:
	print("=== puzzle mode check: life and death against the engine ===")
	proc = load("res://scripts/engine/katago_process.gd").new()
	root.add_child(proc)
	if not proc.is_available():
		print("SKIP: engine files are not present (they are gitignored)")
		quit(0)
		return
	analysis = load("res://scripts/engine/analysis_service.gd").new()
	root.add_child(analysis)
	analysis.use_engine(proc)
	analysis.analysis_updated.connect(_on_result)
	proc.engine_ready.connect(func() -> void: ready_to_go = true)
	if not proc.start_engine():
		_fail("start_engine() returned false: " + proc.start_error())
		_finish()


func _process(delta: float) -> bool:
	if finished:
		return true
	elapsed += delta
	if elapsed > TIMEOUT_SECONDS:
		_fail("timed out")
		_finish()
		return true
	if ready_to_go and waiting_id == "":
		_ask()
	return false


func _ask() -> void:
	if case_index >= CASES.size():
		_finish()
		return
	var c: Array = CASES[case_index]
	var parsed: Dictionary = SGF.parse_text("(;GM[1]FF[4]SZ[19]KM[6.5]RU[Japanese]PL[%s]%s)"
		% [String(c[2]), String(c[1])])
	tree = parsed["tree"]
	waiting_id = analysis.request(tree.root, VISITS, {"tree": tree, "puzzle": puzzle})
	if waiting_id == "":
		_fail("could not send the query for %s" % String(c[0]))
		_finish()


func _on_result(node: GameNode) -> void:
	if tree == null or node != tree.root:
		return
	var result: Dictionary = node.analysis
	if int(result.get("visits", 0)) < VISITS * 0.9:
		return  # a partial answer; wait for the final one
	var c: Array = CASES[case_index]
	var moves: Array = result.get("moves", []) as Array
	var top: Array[String] = []
	for i in range(mini(3, moves.size())):
		var m: Dictionary = moves[i] as Dictionary
		top.append("%s %.0f%% (%+.1f)" % [String(m["move"]), 100.0 * float(m["winrate"]),
			float(m["score_lead"])])
	var best: String = String((moves[0] as Dictionary)["move"]) if not moves.is_empty() else "?"
	var label: String = "puzzle " if puzzle else "normal "
	var mark: String = "  ok  " if best == String(c[3]) else "  --  "
	if puzzle and best != String(c[3]):
		mark = "  FAIL"
		_fail("%s: puzzle mode chose %s, the answer is %s" % [String(c[0]), best, String(c[3])])
	print("%s %s %-30s best %-4s (answer %s)   top: %s" % [mark, label, String(c[0]), best,
		String(c[3]), ", ".join(top)])
	if puzzle:
		var frame_in: bool = bool(result.get("puzzle", false))
		if not frame_in:
			_fail("%s: the result is not marked as a puzzle-mode result" % String(c[0]))
		# The frame centres the result on the problem: the right move wins for
		# the side to move, and some wrong move loses. Win rates are Black's.
		var black_moves: bool = String(c[2]) == "B"
		var best_rate: float = float((moves[0] as Dictionary)["winrate"])
		var mover_best: float = best_rate if black_moves else 1.0 - best_rate
		var mover_worst: float = 1.0
		for m in moves:
			var rate: float = float((m as Dictionary)["winrate"])
			mover_worst = minf(mover_worst, rate if black_moves else 1.0 - rate)
		if mover_best < 0.9:
			_fail("%s: the right move only wins %.0f%%" % [String(c[0]), 100.0 * mover_best])
		if mover_worst > 0.1:
			_fail("%s: no wrong move loses (worst %.0f%%), the frame is not centred"
				% [String(c[0]), 100.0 * mover_worst])
		case_index += 1
	puzzle = not puzzle
	waiting_id = ""


func _fail(message: String) -> void:
	failures.append(message)
	print("  !!   ", message)


func _finish() -> void:
	if finished:
		return
	finished = true
	if proc != null:
		proc.stop_engine()
	print("=== %d failure(s) ===" % failures.size())
	print("PUZZLE_CHECK_PASSED" if failures.is_empty() else "PUZZLE_CHECK_FAILED")
	quit(0 if failures.is_empty() else 1)
