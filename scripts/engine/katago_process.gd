extends Node

## Runs KataGo's analysis engine as a child process and speaks its JSON line
## protocol (PLAN 4 and 5.2). Registered as the autoload "KataGo".
##
## Nothing starts until start_engine() is called, so the test suite and the
## editor stay fast and never need the (gitignored) engine binary.
##
## Threading: two worker threads do the blocking reads (stdout and stderr) so
## the main thread never stalls and the child never blocks on a full pipe.
## Results reach the main thread through a Mutex-guarded array that _process()
## drains.

signal engine_ready
signal engine_failed(message: String)
signal response_received(response: Dictionary)
signal log_line(line: String)
## Emitted for every JSON line written to the engine, so the UI and the tests can
## confirm which queries were superseded by a terminate action.
signal request_sent(request: Dictionary)

const MAX_LOG_LINES: int = 400

var engine_path: String = ""
var model_path: String = ""
var human_model_path: String = ""
var config_path: String = ""
var extra_args: PackedStringArray = PackedStringArray()

## Optional Settings node. In the running game this is the "Settings" autoload,
## looked up at /root/Settings. Tests (and any embedding code) can assign a node
## here directly, because absolute node lookups only work inside the active
## scene tree, which a --script run does not have.
var settings_node: Node = null

var pid: int = -1
## The pid of the most recent engine, kept after shutdown so the UI can report
## (and re-check) the process it was talking to.
var last_pid: int = -1
var running: bool = false
var version: String = ""

var _stdio: FileAccess = null
var _stderr_file: FileAccess = null
var _read_thread: Thread = null
var _stderr_thread: Thread = null
var _mutex: Mutex = null
var _pending: Array[String] = []
var _pending_logs: Array[String] = []
var _log: PackedStringArray = PackedStringArray()
var _stop_requested: bool = false
## Set once stop_engine() has killed and waited for the child, so is_alive()
## stops asking the OS about a pid that has already been reaped.
var _reaped: bool = false
## Set once an OS check confirms the engine process is gone. Godot's
## is_process_running() reaps the child itself, and polling a pid it has already
## reaped makes it print "Thread <pid> exited with errno: 10" (ECHILD). Observed
## with a killed engine: exactly one such line, from the first poll that finds it
## gone. Remembering the answer means we never poll again, so the answer stays
## stable and the log gets no further noise.
var _process_gone: bool = false
## Set by the stdout reader when the pipe reaches EOF. A child process that dies
## closes its end of the pipe, so EOF is the earliest and quietest sign of a
## crash: it needs no OS call, whereas is_process_running() reaps the child and
## prints an error for the pid it reaped.
var _pipe_eof: bool = false
## Seconds between OS pid checks. The stdout reader notices a dead child within
## about 10 ms, so the backstop only needs to run very occasionally; polling the
## pid every frame makes Godot reap the child and print an error for it.
const PID_POLL_INTERVAL: float = 2.0
var _pid_poll_countdown: float = PID_POLL_INTERVAL

var _start_error: String = ""
var _paths_resolved: bool = false
var _mutex_ready: bool = false
## For each of engine/model/human_model/config: why nothing was found, phrased
## for a first-time user. Empty when the file was located.
var _search_notes: Dictionary = {}


## Forgets the resolved paths so the next is_available()/start_engine() picks up
## paths the user has just edited in the settings dialog.
func rescan_paths() -> void:
	_paths_resolved = false
	engine_path = ""
	model_path = ""
	human_model_path = ""
	config_path = ""
	_ensure_paths()


func _ready() -> void:
	_ensure_mutex()
	_ensure_paths()


func _ensure_mutex() -> void:
	if not _mutex_ready:
		_mutex = Mutex.new()
		_mutex_ready = true


## Paths are resolved lazily as well as in _ready(): a caller that instantiates
## this script directly (a headless spike, a test) may inspect it before the
## node has entered the tree, and _ready() has not run at that point.
func _ensure_paths() -> void:
	if not _paths_resolved:
		_resolve_paths()


func _process(_delta: float) -> void:
	# Log lines are emitted here, never from the worker thread that read them.
	var logs: Array[String] = []
	_mutex.lock()
	logs.append_array(_pending_logs)
	_pending_logs.clear()
	_mutex.unlock()
	for line in logs:
		log_line.emit(line)
	if not running:
		return
	var lines: Array[String] = []
	_mutex.lock()
	lines.append_array(_pending)
	_pending.clear()
	_mutex.unlock()
	for line in lines:
		var parsed: Variant = JSON.parse_string(line)
		if parsed is Dictionary:
			var response: Dictionary = parsed
			if response.has("version"):
				version = String(response["version"])
				engine_ready.emit()
			response_received.emit(response)
		else:
			push_warning("KataGo: unparseable stdout line: %s" % line.left(200))
	# A child that died mid-game must be reported, not silently ignored. The pipe
	# reaching EOF is the primary sign; the pid check is a rare backstop for the
	# case where the pipe is somehow still open.
	if running and _engine_gone(_delta):
		fail("the engine process exited")


## True when the engine is no longer there: the stdout pipe hit EOF, or the OS
## says the pid is gone (checked at most once every PID_POLL_INTERVAL seconds).
func _engine_gone(delta: float = 0.0) -> bool:
	_ensure_mutex()
	_mutex.lock()
	var eof: bool = _pipe_eof
	_mutex.unlock()
	if eof:
		return true
	_pid_poll_countdown -= delta
	if _pid_poll_countdown > 0.0:
		return false
	_pid_poll_countdown = PID_POLL_INTERVAL
	return not _pid_running(pid if pid != -1 else last_pid)


## One OS poll per pid: after the first "not running" answer we stop asking,
## because Godot reaps the child on that first answer and prints an error for
## every poll afterwards.
func _pid_running(watched: int) -> bool:
	if _reaped or _process_gone or _pipe_eof or watched == -1:
		return false
	if OS.is_process_running(watched):
		return true
	_process_gone = true
	return false


## True while the current (or most recently stopped) engine process is alive.
## Once stop_engine() has killed and reaped the child we report false without
## asking the OS: polling a pid we already waited on makes Godot print a
## spurious "Thread exited with errno" error.
func is_alive() -> bool:
	return _pid_running(pid if pid != -1 else last_pid)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE or what == NOTIFICATION_WM_CLOSE_REQUEST:
		stop_engine()


## Paths ------------------------------------------------------------

## Finds the engine binary and model for the current platform. Everything found
## here is gitignored third-party content, so a missing file is a normal state
## rather than an error: callers check is_available() first.
##
## Order: an explicit path from the settings dialog wins; otherwise the usual
## project folders are searched. Whatever happened is recorded in _search_notes
## so missing_files() can tell the user exactly what to fix.
func _resolve_paths() -> void:
	_paths_resolved = true
	_search_notes = {}
	var bases: Array[String] = base_dirs()
	var engine_candidates: Array[String] = binary_candidates(bases)
	_pick("engine", "engine_path", engine_candidates)
	_pick("model", "model_path", _per_base(bases, "/engine/models/main.bin.gz"))
	_pick("human_model", "human_model_path", _per_base(bases, "/engine/models/human.bin.gz"))
	_pick("config", "config_path", _per_base(bases, "/engine/analysis.cfg"))


func _per_base(bases: Array[String], suffix: String) -> Array[String]:
	var out: Array[String] = []
	for base in bases:
		out.append(base + suffix)
	return out


## Folders the engine files are looked for in. Both must be real filesystem
## paths: KataGo is a separate process and cannot see anything packed inside the
## exported .pck, so an exported build needs the engine next to its executable.
func base_dirs(os_name: String = "") -> Array[String]:
	var platform: String = os_name if not os_name.is_empty() else OS.get_name()
	var out: Array[String] = []
	var exe_dir: String = OS.get_executable_path().get_base_dir()
	var project_dir: String = ProjectSettings.globalize_path("res://")
	# globalize_path keeps a trailing slash; trimming keeps the messages readable.
	while project_dir.ends_with("/") or project_dir.ends_with("\\"):
		project_dir = project_dir.substr(0, project_dir.length() - 1)
	out.append(exe_dir)
	if platform == "macOS":
		# A .app bundle keeps loose files in Contents/Resources, one level above
		# the executable in Contents/MacOS.
		out.append(exe_dir.get_base_dir().path_join("Resources"))
	out.append(project_dir)
	return out


## The engine binary names tried for the current platform, in order.
## os_name overrides the running platform so the other branches stay testable.
func binary_candidates(bases: Array[String], os_name: String = "") -> Array[String]:
	var platform: String = os_name if not os_name.is_empty() else OS.get_name()
	var out: Array[String] = []
	if platform == "Windows":
		for base in bases:
			out.append(base + "/engine/win/katago.exe")
			out.append(base + "/runtime/katago/katago.exe")
	elif platform == "macOS":
		# Homebrew install, plus a copy inside the project as a fallback.
		out.append("/opt/homebrew/bin/katago")
		out.append("/usr/local/bin/katago")
		for base in bases:
			out.append(base + "/engine/macos/katago")
			out.append(base + "/runtime/katago/katago")
	else:
		for base in bases:
			out.append(base + "/runtime/katago/katago")
			out.append(base + "/engine/linux/katago")
	return out


## A path the user typed in the settings dialog, or "" when none was given.
func _configured(key: String) -> String:
	var settings: Node = _settings()
	if settings == null:
		return ""
	return String(settings.get(key)).strip_edges()


## The Settings autoload, or the node assigned to settings_node.
func _settings() -> Node:
	if settings_node != null and is_instance_valid(settings_node):
		return settings_node
	if not is_inside_tree():
		return null
	return get_node_or_null("/root/Settings")


## An explicit path from Settings is authoritative: if it does not exist that is
## reported rather than quietly replaced by a different file, because the user
## chose it on purpose. With nothing configured the usual folders are searched.
## Either way the reason is recorded in _search_notes for missing_files().
func _pick(key: String, settings_key: String, search: Array[String]) -> void:
	var configured: String = _configured(settings_key)
	if not configured.is_empty():
		if FileAccess.file_exists(configured):
			_set_path(key, configured)
		else:
			_search_notes[key] = "(the path in Settings does not exist: %s)" % configured
		return
	for candidate in search:
		if FileAccess.file_exists(candidate):
			_set_path(key, candidate)
			return
	_search_notes[key] = "(looked in: %s)" % ", ".join(search)


func _set_path(key: String, path: String) -> void:
	match key:
		"engine":
			engine_path = path
		"model":
			model_path = path
		"human_model":
			human_model_path = path
		"config":
			config_path = path


func is_available() -> bool:
	_ensure_paths()
	return _have(engine_path) and _have(model_path) and _have(config_path)


static func _have(path: String) -> bool:
	return not path.is_empty() and FileAccess.file_exists(path)


## What is missing, phrased so a first-time user knows what to fix (milestone 9):
## either the folders that were searched, or the configured path that does not
## exist. Point the user at the settings dialog with these strings.
func missing_files() -> PackedStringArray:
	_ensure_paths()
	var missing: PackedStringArray = PackedStringArray()
	if not _have(engine_path):
		missing.append("KataGo binary " + String(_search_notes.get("engine", "")))
	if not _have(model_path):
		missing.append("main network " + String(_search_notes.get("model", "")))
	if not _have(human_model_path) and wants_human_model():
		missing.append("human network " + String(_search_notes.get("human_model", "")))
	if not _have(config_path):
		missing.append("analysis config " + String(_search_notes.get("config", "")))
	return missing


## The human model is optional: without it the engine still plays, only the
## human-like profiles stop working. Only report it when it is switched on.
func wants_human_model() -> bool:
	var settings: Node = _settings()
	if settings == null:
		return true
	return bool(settings.get("use_human_model"))


## Lifecycle ------------------------------------------------------------

func start_engine() -> bool:
	if running:
		return true
	_ensure_mutex()
	_ensure_paths()
	_start_error = ""
	if not is_available():
		_start_error = "missing files: " + ", ".join(missing_files())
		engine_failed.emit(_start_error)
		return false
	var args: PackedStringArray = PackedStringArray(
		["analysis", "-config", config_path, "-model", model_path])
	if not human_model_path.is_empty():
		args.append("-human-model")
		args.append(human_model_path)
	args.append_array(extra_args)

	_stop_requested = false
	_reaped = false
	_process_gone = false
	_pipe_eof = false
	_pid_poll_countdown = PID_POLL_INTERVAL
	var pipe: Dictionary = OS.execute_with_pipe(engine_path, args, false)
	if pipe.is_empty():
		_start_error = "could not start %s" % engine_path
		engine_failed.emit(_start_error)
		return false
	_stdio = pipe["stdio"]
	_stderr_file = pipe["stderr"]
	pid = int(pipe["pid"])
	last_pid = pid
	running = true

	# Non-blocking pipes plus a short sleep keep shutdown clean: the threads
	# notice _stop_requested and return, so wait_to_finish() cannot hang.
	_read_thread = Thread.new()
	_read_thread.start(_read_stdout, Thread.PRIORITY_HIGH)
	_stderr_thread = Thread.new()
	_stderr_thread.start(_read_stderr, Thread.PRIORITY_NORMAL)

	# The version reply is the proof that the engine has loaded its network and
	# is listening, which takes several seconds on a CPU-only machine.
	send({"id": STARTUP_ID, "action": "query_version"})
	return true


const STARTUP_ID: String = "katago_startup_query_version"


func stop_engine() -> void:
	# Note the guard on `running` only covers the polite shutdown message. The
	# cleanup below must run even when the engine already died (fail() clears
	# `running`), otherwise the reader threads are replaced without being joined
	# and the dead pid is never reaped.
	if running:
		send({"id": "katago_shutdown_terminate_all", "action": "terminate_all"})
	_stop_requested = true
	running = false
	if _read_thread != null:
		_read_thread.wait_to_finish()
		_read_thread = null
	if _stderr_thread != null:
		_stderr_thread.wait_to_finish()
		_stderr_thread = null
	if _stdio != null:
		_stdio.flush()
		_stdio.close()
		_stdio = null
	_stderr_file = null
	if _pid_running(pid):
		OS.kill(pid)
	pid = -1
	_reaped = true


func restart_engine() -> bool:
	stop_engine()
	return start_engine()


func fail(message: String) -> void:
	if _start_error.is_empty():
		_start_error = message
	running = false
	engine_failed.emit(message)


## I/O ------------------------------------------------------------

func send(request: Dictionary) -> bool:
	if _stdio == null:
		return false
	# One JSON object per line, always: multi-line JSON breaks the protocol.
	if not _stdio.store_line(JSON.stringify(request)):
		push_warning("KataGo: failed to write a request line")
		return false
	_stdio.flush()
	# Lets the UI and the tests see exactly what went out, in particular the
	# terminate actions that cancel a superseded live query.
	request_sent.emit(request)
	return true


func last_log_lines(count: int = 40) -> PackedStringArray:
	_ensure_mutex()
	_mutex.lock()
	var out: PackedStringArray = PackedStringArray()
	var start: int = maxi(0, _log.size() - count)
	for i in range(start, _log.size()):
		out.append(_log[i])
	_mutex.unlock()
	return out


func start_error() -> String:
	return _start_error


## Worker threads ------------------------------------------------------------

func _read_stdout() -> void:
	while not _stop_requested:
		var line: String = ""
		if _stdio != null:
			line = _stdio.get_line()
		if line.is_empty():
			if _stdio != null and _stdio.get_error() == ERR_FILE_EOF:
				# The child closed its end of the pipe: it has exited or is about
				# to. _process() turns this into engine_failed() on the main thread.
				_mutex.lock()
				_pipe_eof = true
				_mutex.unlock()
				break
			OS.delay_msec(10)
			continue
		_mutex.lock()
		_pending.append(line)
		_mutex.unlock()


func _read_stderr() -> void:
	while not _stop_requested:
		var line: String = ""
		if _stderr_file != null:
			line = _stderr_file.get_line()
		if line.is_empty():
			if _stderr_file != null and _stderr_file.get_error() == ERR_FILE_EOF:
				break
			OS.delay_msec(20)
			continue
		# Only the buffer is touched here. Emitting a signal from a worker thread
		# is refused by Godot (and would be unsafe anyway), so the log lines are
		# queued and emitted from _process on the main thread.
		_mutex.lock()
		_log.append(line)
		if _log.size() > MAX_LOG_LINES:
			_log.remove_at(0)
		_pending_logs.append(line)
		_mutex.unlock()

