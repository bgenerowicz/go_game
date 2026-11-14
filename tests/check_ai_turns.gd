extends SceneTree

## Human vs engine through the real UI: the human may only play their own
## colour, the engine answers every human move by itself, and an undo while the
## engine is thinking does not let a stale answer land on the new position.
##
## Run with: godot --path . --script tests/check_ai_turns.gd  (needs engine/)

const TIMEOUT_SECONDS: float = 120.0
const SIZE: int = 13

var failures: int = 0
var main_root: Control


func _init() -> void:
	print("=== go_game AI turn check ===")
	_run()


func _check(condition: bool, label: String) -> void:
	print(("  ok   " if condition else "  FAIL ") + label)
	if not condition:
		failures += 1


func _click(gtp: String) -> void:
	main_root.board_view.point_clicked.emit(Coords.from_gtp(gtp, SIZE))


## The first legal point from a fixed list: the engine samples its moves, so
## any particular point may already be taken.
func _free_point() -> String:
	for gtp in ["D4", "K10", "D10", "K4", "G7", "C3", "L11", "C11", "L3", "G10", "G4", "B2"]:
		var p: Vector2i = Coords.from_gtp(gtp, SIZE)
		if main_root.flow.is_legal_at(p.x, p.y):
			return gtp
	return "A1"


## Waits until the engine has replied (it is the human's turn again).
func _wait_for_reply(human: int) -> bool:
	var start: int = Time.get_ticks_msec()
	while main_root.flow.turn() != human or main_root.ai_pending_node != null:
		if Time.get_ticks_msec() - start > TIMEOUT_SECONDS * 1000.0:
			return false
		await process_frame
	return true


func _run() -> void:
	main_root = load("res://main.tscn").instantiate()
	get_root().add_child(main_root)
	await process_frame
	var engine: Node = get_root().get_node_or_null("KataGo")
	if engine == null or not engine.is_available():
		print("engine files missing, skipping")
		quit(1)
		return
	var start: int = Time.get_ticks_msec()
	while not engine.running or engine.version == "":
		if Time.get_ticks_msec() - start > TIMEOUT_SECONDS * 1000.0:
			_check(false, "engine started")
			quit(1)
			return
		await process_frame

	main_root._new_game_with({"size": SIZE, "komi": 6.5, "rules": "japanese",
		"handicap": 0, "profile": "rank_5k", "human_colour": "black"})
	var flow: GameFlow = main_root.flow
	_check(main_root.ai_side == Board.Stone.WHITE, "the engine plays White")

	# Several human moves in a row: each one must get an engine reply, and a
	# click while the engine is to move must be ignored.
	for i in 4:
		var before: int = flow.move_number()
		var gtp: String = _free_point()
		_click(gtp)
		_check(flow.move_number() == before + 1, "human move accepted at %s" % gtp)
		_check(flow.turn() == Board.Stone.WHITE, "then it is the engine's turn")
		var during: int = flow.move_number()
		_click("A1")
		main_root._on_pass()
		_check(flow.move_number() == during, "click and pass ignored on the engine's turn")
		_check(await _wait_for_reply(Board.Stone.BLACK), "the engine replied by itself")
		_check(flow.move_number() == during + 1, "exactly one engine move was played")

	# Undo while the engine is thinking: its answer belongs to a position that
	# no longer exists, so it must not be played; the human moves next.
	_click(_free_point())
	var after_human: int = flow.move_number()
	_check(main_root.ai_pending_node != null, "the engine is thinking")
	main_root._on_undo()
	_check(flow.move_number() == after_human - 1, "undo took back only the human's move")
	_check(flow.turn() == Board.Stone.BLACK, "the human is to move after the undo")
	var settle: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - settle < 5000:
		await process_frame
	_check(flow.move_number() == after_human - 1, "no stale engine move landed")

	# Undo on the human's own turn takes back the engine's reply and the
	# human's move before it, so it is still the human to play.
	_click(_free_point())
	_check(await _wait_for_reply(Board.Stone.BLACK), "the engine replied again")
	var before_undo: int = flow.move_number()
	main_root._on_undo()
	_check(flow.move_number() == before_undo - 2, "undo on the human's turn takes back a pair")
	_check(flow.turn() == Board.Stone.BLACK, "still the human to move")

	print("=== %d failure(s) ===" % failures)
	print("AI_TURN_CHECK_PASSED" if failures == 0 else "FAILED")
	quit(0 if failures == 0 else 1)
