extends SceneTree

## Throwaway spike required by PLAN 5.2: prove OS.execute_with_pipe can drive
## KataGo's analysis engine before anything is built on top of it.
##
## Run from the project root:
##   godot --headless --script tools/spike_katago.gd
##
## Not part of the test suite: it needs the (gitignored) engine binary and model.

const ROOT: String = "/home/llmdev/worktrees/go_game"
const KATAGO: String = ROOT + "/runtime/katago/katago"
const CONFIG: String = ROOT + "/engine/analysis.cfg"
const MODEL: String = ROOT + "/engine/models/main.bin.gz"

const WAIT_MS: int = 240000


func _init() -> void:
	print("spike: starting KataGo analysis engine")
	var started: int = Time.get_ticks_msec()
	var pipe: Dictionary = OS.execute_with_pipe(
		KATAGO,
		PackedStringArray(["analysis", "-config", CONFIG, "-model", MODEL]),
		false,
	)
	if pipe.is_empty():
		print("FAIL: execute_with_pipe returned an empty Dictionary")
		quit(1)
		return
	print("pipe keys: ", pipe.keys())
	print("pid: ", pipe["pid"], "  running: ", OS.is_process_running(int(pipe["pid"])))

	var stdio: FileAccess = pipe["stdio"]
	var stderr_file: FileAccess = pipe["stderr"]

	var request: Dictionary = {
		"id": "v1",
		"action": "query_version",
	}
	var write_ok: bool = stdio.store_line(JSON.stringify(request))
	print("store_line -> ", write_ok)
	stdio.flush()

	var replies: Array[String] = []
	var err_lines: int = 0
	var deadline: int = started + WAIT_MS
	while replies.is_empty() and Time.get_ticks_msec() < deadline:
		var err_line: String = stderr_file.get_line()
		if err_line != "" and stderr_file.get_error() == OK:
			err_lines += 1
			if err_lines <= 12:
				print("stderr: ", err_line)
		var line: String = stdio.get_line()
		if line == "":
			OS.delay_msec(50)
			continue
		replies.append(line)
		print("stdout: ", line)

	print("replies: ", replies.size(), "  stderr lines seen: ", err_lines)
	print("elapsed: ", (Time.get_ticks_msec() - started) / 1000.0, "s")

	# A second request proves the pipe keeps working in both directions.
	if not replies.is_empty():
		var query: Dictionary = {
			"id": "q1",
			"moves": [["B", "Q16"], ["W", "D4"]],
			"rules": "japanese",
			"komi": 6.5,
			"boardXSize": 19,
			"boardYSize": 19,
			"analyzeTurns": [2],
			"maxVisits": 40,
			"includeOwnership": true,
			"includePolicy": true,
			"analysisPVLen": 15,
		}
		stdio.store_line(JSON.stringify(query))
		stdio.flush()
		var got_answer: bool = _await_answer(stdio, started + WAIT_MS)
		print("second request answered: ", got_answer)

	print("alive before kill: ", OS.is_process_running(int(pipe["pid"])))
	stdio.store_line(JSON.stringify({"id": "t1", "action": "terminate_all"}))
	stdio.flush()
	OS.delay_msec(300)
	OS.kill(int(pipe["pid"]))
	OS.delay_msec(200)
	print("alive after kill: ", OS.is_process_running(int(pipe["pid"])))
	quit(0 if not replies.is_empty() else 1)


func _await_answer(stdio: FileAccess, deadline: int) -> bool:
	while Time.get_ticks_msec() < deadline:
		var line: String = stdio.get_line()
		if line == "":
			OS.delay_msec(50)
			continue
		print("stdout: ", line.left(400))
		return true
	return false
