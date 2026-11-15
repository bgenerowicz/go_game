extends SceneTree

## Smoke check for scripts/engine/katago_process.gd: start the engine, wait for
## the version reply, run one analysis query, then shut down cleanly.
##
##   godot --headless --script tools/spike_process.gd
##
## Not part of the test suite: it needs the gitignored engine binary and model.

const SCRIPT: String = "res://scripts/engine/katago_process.gd"
const DEADLINE_MS: int = 300000


func _init() -> void:
	var node_script: GDScript = load(SCRIPT)
	if node_script == null:
		print("FAIL: could not load ", SCRIPT)
		quit(1)
		return
	var engine: Node = node_script.new()
	engine.name = "KataGo"
	root.add_child(engine)

	var state: Dictionary = {"ready": false, "turns": [], "finals": [], "errors": [], "log": 0}
	engine.engine_ready.connect(func() -> void:
		state["ready"] = true
		print("engine_ready, version=", engine.version))
	engine.engine_failed.connect(func(message: String) -> void:
		state["errors"].append(message)
		print("engine_failed: ", message))
	engine.log_line.connect(func(_line: String) -> void:
		state["log"] += 1)
	engine.response_received.connect(func(response: Dictionary) -> void:
		if response.has("error"):
			print("engine error response: ", response)
			state["errors"].append(String(response["error"]))
		elif response.has("moveInfos"):
			state["turns"].append(response)
			if not bool(response.get("isDuringSearch", false)):
				state["finals"].append(response)
			print("turn ", response.get("turnNumber"), " during ",
				bool(response.get("isDuringSearch", false)), " visits ",
				response.get("rootInfo", {}).get("visits"),
				" best ", (response["moveInfos"] as Array)[0].get("move"),
				" pv ", ((response["moveInfos"] as Array)[0].get("pv") as Array).size(),
				" ownership ", (response.get("ownership", []) as Array).size()))

	print("available: ", engine.is_available())
	if not engine.is_available():
		print("missing: ", engine.missing_files())
		quit(1)
		return
	var started: int = Time.get_ticks_msec()
	if not engine.start_engine():
		print("FAIL: start_engine returned false: ", engine.start_error())
		quit(1)
		return
	print("pid ", engine.pid, " started, waiting for the network to load ...")

	var deadline: int = started + DEADLINE_MS
	while not state["ready"] and Time.get_ticks_msec() < deadline:
		await process_frame
	if not state["ready"]:
		print("FAIL: no version reply before the deadline")
		print("stderr tail: ", engine.last_log_lines(10))
		engine.stop_engine()
		quit(1)
		return
	print("engine up in ", (Time.get_ticks_msec() - started) / 1000.0, "s")

	# Milestone 4's check: analyse an empty 19x19 board at 50 visits and print
	# the best move.
	engine.send({
		"id": "q1",
		"moves": [],
		"rules": "japanese",
		"komi": 6.5,
		"boardXSize": 19,
		"boardYSize": 19,
		"analyzeTurns": [0],
		"maxVisits": 50,
		"includeOwnership": true,
		"includePolicy": true,
		"analysisPVLen": 15,
	})
	while (state["turns"] as Array).size() < 1 and Time.get_ticks_msec() < deadline:
		await process_frame
	if (state["turns"] as Array).size() >= 1:
		var best: Dictionary = (state["turns"][0] as Dictionary)["moveInfos"][0]
		print("BEST MOVE: ", best["move"], "  visits ", best["visits"],
			"  winrate ", best["winrate"], "  pv ", best["pv"])
	else:
		print("FAIL: no analysis response")

	# A terminated query must still send a final response.
	engine.send({"id": "q2", "moves": [], "rules": "chinese", "komi": 7.5,
		"boardXSize": 9, "boardYSize": 9, "maxVisits": 100000,
		"reportDuringSearchEvery": 0.3})
	var before: int = (state["finals"] as Array).size()
	await create_timer(2.0).timeout
	engine.send({"id": "t1", "action": "terminate", "terminateId": "q2"})
	var waited: int = Time.get_ticks_msec()
	while (state["finals"] as Array).size() == before and Time.get_ticks_msec() - waited < 15000:
		await process_frame
	var terminated: bool = (state["finals"] as Array).size() > before
	print("terminate produced a final response: ", terminated)
	if terminated:
		var last: Dictionary = (state["finals"] as Array)[-1]
		print("  id ", last.get("id"), " noResults ", last.get("noResults"),
			" during ", last.get("isDuringSearch"))

	engine.stop_engine()
	await create_timer(0.5).timeout
	print("alive after stop: ", OS.is_process_running(engine.pid))
	print("stderr lines captured: ", state["log"])
	print("errors: ", state["errors"])
	var ok: bool = state["ready"] and (state["finals"] as Array).size() >= 2 \
		and terminated and not OS.is_process_running(engine.pid) \
		and (state["errors"] as Array).is_empty()
	print("RESULT: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
