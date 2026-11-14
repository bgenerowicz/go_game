extends RefCounted

## Engine path resolution (milestone 9 first-run experience). The runner
## instantiates this and calls run(a).
var a: Assertions

const PROCESS_SCRIPT: String = "res://scripts/engine/katago_process.gd"
const SETTINGS_SCRIPT: String = "res://scripts/settings.gd"


func run() -> void:
	_test_bundled_files_are_found()
	_test_settings_path_wins()
	_test_binary_message_names_the_search()
	_test_human_model_is_optional()
	_test_per_os_candidates()


## Builds a throwaway Settings node plus a KataGo node and wires the first into
## the second: autoloads do not exist when the tests run through --script, and
## absolute /root/ lookups need the active scene tree, which that mode lacks.
func _make_pair() -> Array:
	var settings: Node = load(SETTINGS_SCRIPT).new()
	settings.name = "Settings"
	var engine: Node = load(PROCESS_SCRIPT).new()
	engine.name = "KataGoProbe"
	engine.settings_node = settings
	return [settings, engine]


## Frees both again so the next test starts from a clean Settings.
func _free_pair(pair: Array) -> void:
	for node in pair:
		if node != null and is_instance_valid(node):
			node.free()


func _test_bundled_files_are_found() -> void:
	a.section("engine paths: bundled files")
	var pair: Array = _make_pair()
	var engine: Node = pair[1]
	a.check(bool(engine.is_available()),
		"the runtime engine files are found: %s" % ", ".join(engine.missing_files()))
	a.check(not String(engine.engine_path).is_empty(), "binary path resolved")
	a.check(not String(engine.model_path).is_empty(), "main network resolved")
	a.check(not String(engine.config_path).is_empty(), "config resolved")
	a.check(engine.missing_files().is_empty(), "nothing reported missing")
	a.check(String(engine.engine_path).ends_with("katago"), "binary looks like the katago binary")
	_free_pair(pair)


func _test_settings_path_wins() -> void:
	a.section("engine paths: Settings overrides the search")
	var pair: Array = _make_pair()
	var settings: Node = pair[0]
	var engine: Node = pair[1]
	engine.rescan_paths()
	var found: String = String(engine.config_path)
	a.check(not found.is_empty(), "config found by the search first")
	# Point Settings at an existing file; the engine must use it.
	settings.set_value("config_path", found)
	engine.rescan_paths()
	a.check_eq(String(engine.config_path), found, "the Settings path is used")
	# A Settings path that does not exist must be reported, not silently ignored.
	settings.set_value("config_path", "/no/such/analysis.cfg")
	engine.rescan_paths()
	a.check(not bool(engine.is_available()), "a bad Settings path makes the engine unavailable")
	var missing: PackedStringArray = engine.missing_files()
	a.check_eq(missing.size(), 1, "exactly one thing missing")
	a.check(String(missing[0]).contains("/no/such/analysis.cfg"),
		"the message names the bad path: %s" % String(missing[0]))
	a.check(String(missing[0]).contains("Settings"), "the message points at Settings")
	# Clearing it returns to the automatic search.
	settings.set_value("config_path", "")
	engine.rescan_paths()
	a.check(bool(engine.is_available()), "clearing the path restores the search")
	_free_pair(pair)


func _test_binary_message_names_the_search() -> void:
	a.section("engine paths: missing binary message")
	var pair: Array = _make_pair()
	var settings: Node = pair[0]
	var engine: Node = pair[1]
	settings.set_value("engine_path", "/definitely/not/here/katago")
	engine.rescan_paths()
	var text: String = ""
	for item in engine.missing_files():
		if String(item).begins_with("KataGo binary"):
			text = String(item)
	a.check(not text.is_empty(), "a KataGo binary line is present")
	a.check(text.contains("/definitely/not/here/katago"), "it names the configured path")
	settings.set_value("engine_path", "")
	engine.rescan_paths()
	a.check(bool(engine.is_available()), "the search finds the bundled binary again")
	_free_pair(pair)


func _test_human_model_is_optional() -> void:
	a.section("engine paths: human network is optional")
	var pair: Array = _make_pair()
	var settings: Node = pair[0]
	var engine: Node = pair[1]
	settings.set_value("use_human_model", false)
	settings.set_value("human_model_path", "/no/such/human.bin.gz")
	engine.rescan_paths()
	a.check(bool(engine.is_available()), "the engine is available without the human network")
	var mentioned: bool = false
	for item in engine.missing_files():
		if String(item).begins_with("human network"):
			mentioned = true
	a.check(not mentioned, "it is not reported while switched off")
	settings.set_value("use_human_model", true)
	engine.rescan_paths()
	mentioned = false
	for item in engine.missing_files():
		if String(item).begins_with("human network"):
			mentioned = true
	a.check(mentioned, "it is reported once the human profiles are switched on")
	settings.set_value("human_model_path", "")
	settings.set_value("use_human_model", true)
	engine.rescan_paths()
	a.check(bool(engine.is_available()), "clearing it restores availability")
	_free_pair(pair)


## Per-OS default paths (milestone 9). The other platforms cannot be run here,
## but base_dirs()/binary_candidates() take an os_name override, so their
## candidate lists are still checkable.
func _test_per_os_candidates() -> void:
	a.section("engine paths: per-OS defaults")
	var pair: Array = _make_pair()
	var engine: Node = pair[1]
	var bases: Array[String] = engine.base_dirs("Linux")
	a.check(bases.size() >= 2,
		"the executable folder and the project folder are both searched: %s" % ", ".join(bases))
	for base in bases:
		a.check(base.begins_with("/"), "search folder is a real filesystem path: %s" % base)

	var windows_bases: Array[String] = ["/app"]
	var windows: Array = engine.binary_candidates(windows_bases, "Windows")
	a.check(windows.size() > 0, "Windows has candidates")
	var any_exe: bool = false
	for candidate in windows:
		if String(candidate).ends_with(".exe"):
			any_exe = true
		a.check(not String(candidate).contains("homebrew"),
			"Windows does not look in Homebrew: %s" % String(candidate))
	a.check(any_exe, "Windows looks for katago.exe")
	a.check(not String(windows[0]).ends_with("katago"), "Windows name is not the bare unix name")

	var mac_bases_for_binary: Array[String] = ["/App.app/Contents/MacOS"]
	var macos: Array = engine.binary_candidates(mac_bases_for_binary, "macOS")
	var has_brew: bool = false
	var has_bundle_copy: bool = false
	for candidate in macos:
		if String(candidate) == "/opt/homebrew/bin/katago":
			has_brew = true
		if String(candidate).contains("engine/macos/katago"):
			has_bundle_copy = true
	a.check(has_brew, "macOS tries the Homebrew install first")
	a.check(has_bundle_copy, "macOS falls back to a copy inside the bundle")

	var linux_bases: Array[String] = ["/app"]
	var linux: Array = engine.binary_candidates(linux_bases, "Linux")
	var has_runtime: bool = false
	for candidate in linux:
		a.check(not String(candidate).contains(".exe"),
			"Linux does not look for a .exe: %s" % String(candidate))
		if String(candidate).contains("runtime/katago/katago"):
			has_runtime = true
	a.check(has_runtime, "Linux finds the development runtime folder")

	# A .app bundle keeps loose files in Contents/Resources, one level above the
	# executable folder, so that sibling folder must be searched on macOS.
	# OS.get_executable_path() cannot be faked here, so the expectation is
	# computed from the same inputs the code uses.
	var mac_bases: Array[String] = engine.base_dirs("macOS")
	var exe_dir: String = OS.get_executable_path().get_base_dir()
	var expected: String = exe_dir.get_base_dir().path_join("Resources")
	var has_resources: bool = false
	for base in mac_bases:
		if String(base) == expected:
			has_resources = true
	a.check(has_resources,
		"macOS searches the folder beside the executable folder (%s): %s"
		% [expected, ", ".join(mac_bases)])
	a.check(mac_bases.size() > 2,
		"macOS searches one folder more than the plain case: %d" % mac_bases.size())
	a.check(mac_bases[0] == exe_dir, "the executable folder is searched first")
	_free_pair(pair)
