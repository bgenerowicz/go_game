extends SceneTree

## Milestone 9 check (PLAN section 7): a fresh user:// folder gives a working
## first run, or a clear message saying which path to set.
##
## Run with: godot --headless --script tests/check_first_run.gd
## Exits non-zero on failure. Any existing settings file is moved aside for the
## duration and restored afterwards, so running this does not lose the user's
## settings. No engine process is started, so nothing can be orphaned.

var failures: int = 0
var checks: int = 0

const SETTINGS_SCRIPT: String = "res://scripts/settings.gd"
const PROCESS_SCRIPT: String = "res://scripts/engine/katago_process.gd"
const BACKUP_NAME: String = "settings.json.first_run_backup"

var _backed_up: bool = false


func _init() -> void:
	print("=== go_game first-run check (fresh user://) ===")
	_run()
	_restore()
	if failures == 0:
		print("=== %d checks, 0 failed ===" % checks)
		quit(0)
	else:
		print("=== %d checks, %d failed ===" % [checks, failures])
		print("FAILED")
		quit(1)


func _run() -> void:
	if not _move_settings_aside():
		return
	_test_defaults_on_a_fresh_folder()
	_test_settings_survive_a_restart()
	_test_dialog_starts_in_a_real_folder()
	_test_engine_is_found_or_reported()
	_test_missing_engine_message()


## Settings ------------------------------------------------------------

func _ok(condition: bool, label: String, detail: String = "") -> void:
	checks += 1
	if condition:
		print("  ok   %s%s" % [label, (" : " + detail) if detail != "" else ""])
	else:
		failures += 1
		print("  FAIL %s%s" % [label, (" : " + detail) if detail != "" else ""])


func _move_settings_aside() -> bool:
	var dir: DirAccess = DirAccess.open("user://")
	if dir == null:
		# A completely missing user:// folder is exactly the fresh case; make it.
		DirAccess.make_dir_recursive_absolute("user://")
		dir = DirAccess.open("user://")
	if dir == null:
		print("  FAIL cannot open user:// - cannot run this check")
		failures += 1
		return false
	if not dir.file_exists("settings.json"):
		_ok(true, "user:// starts with no settings.json")
		return true
	if dir.rename("settings.json", BACKUP_NAME) != OK:
		print("  FAIL could not move the existing settings.json aside")
		failures += 1
		return false
	_backed_up = true
	_ok(true, "existing settings.json moved aside for the check")
	return true


func _restore() -> void:
	if not _backed_up:
		return
	var dir: DirAccess = DirAccess.open("user://")
	if dir == null:
		return
	if dir.file_exists("settings.json"):
		dir.remove("settings.json")
	dir.rename(BACKUP_NAME, "settings.json")
	print("  ok   the user's settings.json restored")


## A Settings node reading a folder that has never been used.
func _fresh_settings() -> Node:
	var settings: Node = load(SETTINGS_SCRIPT).new()
	settings.name = "FreshSettings"
	settings.load_settings()
	return settings


func _test_defaults_on_a_fresh_folder() -> void:
	var s: Node = _fresh_settings()
	_ok(String(s.load_error).is_empty(), "no load error without a settings file",
		String(s.load_error))
	_ok(int(s.board_size) == 19, "board size defaults to 19", str(s.board_size))
	_ok(is_equal_approx(float(s.komi), 6.5), "komi defaults to 6.5", str(s.komi))
	_ok(String(s.rules) == "japanese", "rules default to japanese", String(s.rules))
	_ok(int(s.handicap) == 0, "no handicap by default", str(s.handicap))
	_ok(int(s.live_visits) == 2000 and int(s.review_visits) == 200,
		"visit budgets default to 2000 live / 200 review")
	_ok(String(s.engine_path).is_empty() and String(s.model_path).is_empty(),
		"engine paths start empty, meaning auto-detect")
	_ok(int(s.board_size) in [9, 13, 19] and s.is_valid_board_size(int(s.board_size)),
		"the default board size is one the app supports")
	s.free()


func _test_settings_survive_a_restart() -> void:
	var s: Node = _fresh_settings()
	s.board_size = 13
	s.komi = 7.5
	s.human_profile = "rank_10k"
	s.save_settings()
	_ok(FileAccess.file_exists("user://settings.json"), "saving writes user://settings.json")
	var again: Node = load(SETTINGS_SCRIPT).new()
	again.name = "ReloadedSettings"
	again.load_settings()
	_ok(int(again.board_size) == 13, "board size comes back after a restart", str(again.board_size))
	_ok(is_equal_approx(float(again.komi), 7.5), "komi comes back", str(again.komi))
	_ok(String(again.human_profile) == "rank_10k", "profile comes back", String(again.human_profile))
	_ok(String(again.load_error).is_empty(), "no load error for the written file",
		String(again.load_error))
	s.free()
	again.free()


func _test_dialog_starts_in_a_real_folder() -> void:
	var s: Node = _fresh_settings()
	var dir: String = String(s.default_sgf_dir())
	_ok(not dir.is_empty(), "the SGF dialog has a starting folder", dir)
	_ok(DirAccess.dir_exists_absolute(dir), "that folder exists", dir)
	s.last_dir = "/no/such/folder"
	var fallback: String = String(s.default_sgf_dir())
	_ok(DirAccess.dir_exists_absolute(fallback),
		"a remembered folder that vanished falls back to one that exists", fallback)
	s.free()


## Engine ----------------------------------------------------------------

## Either the engine is found, or every missing piece is named with a hint about
## where to set it. Both are acceptable first-run outcomes; silence is not.
func _test_engine_is_found_or_reported() -> void:
	var s: Node = _fresh_settings()
	var engine: Node = load(PROCESS_SCRIPT).new()
	engine.name = "FreshEngine"
	engine.settings_node = s
	engine.rescan_paths()
	var available: bool = bool(engine.is_available())
	var missing: PackedStringArray = engine.missing_files()
	if available:
		_ok(missing.is_empty(), "found engine reports nothing missing", ", ".join(missing))
		_ok(String(engine.engine_path).ends_with("katago"),
			"the binary path looks sane", String(engine.engine_path))
		_ok(String(engine.model_path).ends_with(".bin.gz"),
			"the network path looks sane", String(engine.model_path))
		_ok(String(engine.config_path).ends_with(".cfg"),
			"the config path looks sane", String(engine.config_path))
	else:
		_ok(not missing.is_empty(), "a missing engine says what is missing")
		for item in missing:
			_ok(String(item).contains("Settings") or String(item).contains("settings"),
				"the message says where to set it: %s" % String(item))
	s.free()
	engine.free()


## The clear-message half of the milestone check: point every path at something
## that does not exist and confirm the app explains itself precisely.
func _test_missing_engine_message() -> void:
	var s: Node = _fresh_settings()
	s.set_value("engine_path", "/opt/go_game/katago")
	s.set_value("model_path", "/opt/go_game/models/main.bin.gz")
	s.set_value("config_path", "/opt/go_game/analysis.cfg")
	var engine: Node = load(PROCESS_SCRIPT).new()
	engine.name = "MissingEngine"
	engine.settings_node = s
	engine.rescan_paths()
	_ok(not bool(engine.is_available()), "nothing is claimed to be available")
	var missing: PackedStringArray = engine.missing_files()
	_ok(missing.size() >= 3, "all three problems are listed", "%d lines" % missing.size())
	var joined: String = " | ".join(missing)
	for wanted in ["/opt/go_game/katago", "/opt/go_game/models/main.bin.gz",
			"/opt/go_game/analysis.cfg"]:
		_ok(joined.contains(wanted), "the message names %s" % wanted)
	var binary_line: String = ""
	for item in missing:
		if String(item).begins_with("KataGo binary"):
			binary_line = String(item)
	_ok(not binary_line.is_empty(), "the binary line is labelled", binary_line)
	_ok(binary_line.contains("Settings"), "it points at the Settings dialog", binary_line)
	# Starting must fail with an explanation rather than hang or crash.
	_ok(not bool(engine.start_engine()), "start_engine() says no")
	var reason: String = String(engine.start_error())
	_ok(not reason.is_empty(), "start_error() is not empty", reason)
	_ok(reason.contains("KataGo binary"), "start_error() names the piece", reason)
	_ok(bool(engine.is_alive()) == false, "no process is claimed to be running")
	s.free()
	engine.free()
