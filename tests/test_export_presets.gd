extends RefCounted

## Export preset validation (milestone 9). The presets themselves cannot be
## built in this environment - Godot export templates are not installed and
## cannot be downloaded - but the file is plain text, so its structure, the
## platform names, the option keys and the resource filters are all checkable.
## A real export still has to be run on a machine with the templates.
var a: Assertions

const PRESET_FILE: String = "res://export_presets.cfg"


func run() -> void:
	_test_presets_load()


func _test_presets_load() -> void:
	a.section("export presets")
	if not FileAccess.file_exists(PRESET_FILE):
		a.check(false, "%s is missing" % PRESET_FILE)
		return
	var cfg: ConfigFile = ConfigFile.new()
	var err: int = cfg.load(PRESET_FILE)
	a.check_eq(err, OK, "the preset file parses as a ConfigFile")
	if err != OK:
		return

	var expected: Array = [
		{"name": "Windows Desktop", "platform": "Windows Desktop", "path": "build/windows/"},
		{"name": "macOS", "platform": "macOS", "path": "build/macos/"},
	]
	for index in expected.size():
		var section: String = "preset.%d" % index
		a.check(cfg.has_section(section), "%s exists" % section)
		if not cfg.has_section(section):
			continue
		var want: Dictionary = expected[index]
		a.check_eq(String(cfg.get_value(section, "name", "")), String(want["name"]),
			"preset %d name" % index)
		a.check_eq(String(cfg.get_value(section, "platform", "")), String(want["platform"]),
			"preset %d platform" % index)
		a.check(bool(cfg.get_value(section, "runnable", false)),
			"preset %d is runnable" % index)
		a.check_eq(String(cfg.get_value(section, "export_filter", "")), "all_resources",
			"preset %d exports all resources" % index)
		a.check(String(cfg.get_value(section, "export_path", "")).begins_with(String(want["path"])),
			"preset %d exports under build/" % index)

		# KataGo is a separate process and cannot read anything inside the .pck,
		# so the engine must NOT be packed in; it is copied next to the exported
		# executable instead (see the header of export_presets.cfg). The huge
		# offline folders still have to be excluded.
		var include: String = String(cfg.get_value(section, "include_filter", ""))
		a.check(not include.contains("engine/"),
			"preset %d does not pack the engine into the .pck" % index)
		var exclude: String = String(cfg.get_value(section, "exclude_filter", ""))
		for junk in ["docs/", "runtime/", "local-assets/", "tests/"]:
			a.check(exclude.contains(junk), "preset %d excludes %s" % [index, junk])

	# The folders a fresh clone needs for the copy step must exist, with a
	# .gitkeep so they survive even before the binaries are dropped in.
	for folder in ["engine", "engine/models", "engine/win", "engine/macos"]:
		a.check(DirAccess.dir_exists_absolute("res://" + folder),
			"%s exists for the packaging step" % folder)

	# PLAN section 8: a sandboxed macOS app cannot exec the KataGo binary.
	var macos: String = "preset.1"
	if cfg.has_section(macos + ".options"):
		var sandbox: Variant = cfg.get_value(macos + ".options",
			"codesign/entitlements/app_sandbox/enabled", true)
		a.check(not bool(sandbox), "the macOS app sandbox is off (KataGo must be executable)")
		a.check_eq(String(cfg.get_value(macos + ".options", "application/bundle_identifier", "")),
			"org.gogame.go-game", "the macOS bundle has an identifier")
		a.check_eq(String(cfg.get_value(macos + ".options", "binary_format/architecture", "")),
			"universal", "the macOS build is universal")
	else:
		a.check(false, "the macOS preset has no options section")
