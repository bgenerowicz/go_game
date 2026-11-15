extends SceneTree

## Milestone 9 check: an engine that is missing or that dies mid-game must be
## reported clearly and be restartable without quitting the app.
##
## Run with: godot --headless --script tests/check_engine_crash.gd
## Exits non-zero on failure. Leaves no orphaned katago process behind.

var failures: int = 0
var checks: int = 0

var engine: Node = null
var settings: Node = null
var _failed_message: String = ""
var _ready_count: int = 0


func _init() -> void:
	print("=== go_game engine failure check ===")
	_run()


func _run() -> void:
	settings = load("res://scripts/settings.gd").new()
	settings.name = "Settings"
	get_root().add_child(settings)
	engine = load("res://scripts/engine/katago_process.gd").new()
	engine.name = "KataGo"
	engine.settings_node = settings
	get_root().add_child(engine)  # in the tree so _process() runs
	engine.engine_failed.connect(_on_failed)
	engine.engine_ready.connect(_on_ready)

	if not bool(engine.is_available()):
		_fail("engine files are not available: %s" % ", ".join(engine.missing_files()))
		_finish()
		return

	# --- start it ----------------------------------------------------------
	if not bool(engine.start_engine()):
		_fail("engine did not start: %s" % String(engine.start_error()))
		_finish()
		return
	var ready: bool = await _wait_until(func() -> bool: return _ready_count > 0, 60.0)
	_check(ready, "engine_ready received before the crash")
	_check(bool(engine.is_alive()), "is_alive() is true while the engine runs")
	var pid: int = int(engine.pid)
	_check(pid > 0, "engine has a pid: %d" % pid)

	# --- kill it from the outside, as a crash would ------------------------
	OS.kill(pid)
	var noticed: bool = await _wait_until(func() -> bool: return not _failed_message.is_empty(), 20.0)
	_check(noticed, "the dead engine is noticed without user action")
	_check(_failed_message.contains("exited"), "the message says the process exited: <%s>" % _failed_message)
	_check(not bool(engine.is_alive()), "is_alive() is false after the crash")
	_check(not bool(engine.running), "running is false after the crash")

	# --- bring it back without quitting ------------------------------------
	_failed_message = ""
	_ready_count = 0
	var restarted: bool = false
	if engine.has_method("restart_engine"):
		restarted = bool(engine.restart_engine())
	else:
		engine.stop_engine()
		restarted = bool(engine.start_engine())
	_check(restarted, "the engine restarts from inside the app")
	ready = await _wait_until(func() -> bool: return _ready_count > 0, 60.0)
	_check(ready, "engine_ready received again after the restart")
	_check(bool(engine.is_alive()), "the restarted engine is alive")
	_check(int(engine.pid) != pid, "the restarted engine has a new pid")

	# --- a missing engine says which path to set ---------------------------
	# Stop first: start_engine() on a live engine is a no-op that returns true.
	engine.stop_engine()
	settings.set_value("engine_path", "/no/such/katago")
	engine.rescan_paths()
	var missing: PackedStringArray = engine.missing_files()
	var binary_line: String = ""
	for item in missing:
		if String(item).begins_with("KataGo binary"):
			binary_line = String(item)
	_check(not binary_line.is_empty(), "a missing-binary line is reported")
	_check(binary_line.contains("/no/such/katago"), "it names the bad path: <%s>" % binary_line)
	_check(binary_line.contains("Settings"), "it points at the settings dialog: <%s>" % binary_line)
	_check(not bool(engine.start_engine()), "start_engine() refuses to start a missing binary")
	_check(not String(engine.start_error()).is_empty(), "start_error() explains why")
	settings.set_value("engine_path", "")
	engine.rescan_paths()
	_check(bool(engine.is_available()), "clearing the bad path restores availability")

	_finish()


func _on_failed(message: String) -> void:
	_failed_message = message


func _on_ready() -> void:
	_ready_count += 1


## Polls a condition once per frame, giving up after timeout seconds.
func _wait_until(condition: Callable, timeout: float) -> bool:
	var limit: int = int(timeout * 60.0)
	for i in limit:
		if bool(condition.call()):
			return true
		await process_frame
	return false


func _finish() -> void:
	if engine != null and is_instance_valid(engine):
		engine.stop_engine()
	await process_frame
	# No orphaned katago process may survive the run.
	var out: Array = []
	OS.execute("pgrep", PackedStringArray(["-c", "katago"]), out)
	var left: String = ""
	for line in out:
		left += String(line)
	left = left.strip_edges()
	_check(left == "" or left == "0", "no orphaned katago process left (pgrep -c says %s)" % left)
	print("=== %d checks, %d failed ===" % [checks, failures])
	quit(0 if failures == 0 else 1)


func _check(ok: bool, label: String) -> void:
	checks += 1
	if ok:
		print("  ok   %s" % label)
	else:
		failures += 1
		print("  FAIL %s" % label)


func _fail(label: String) -> void:
	checks += 1
	failures += 1
	print("  FAIL %s" % label)
