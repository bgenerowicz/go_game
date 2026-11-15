extends RefCounted

## Settings defaults and coercion (mistake thresholds, board colours,
## show-hints). The runner instantiates this and calls run(a).
##
## Deliberately does not call save_settings()/load_settings(): those touch the
## real user://settings.json, and a test must not clobber a user's settings.
var a: Assertions

const SETTINGS_SCRIPT: String = "res://scripts/settings.gd"


func run() -> void:
	_test_defaults_cover_every_spec_key()
	_test_set_value_coercion()
	_test_colour_helpers()


func _make_settings() -> Node:
	var settings: Node = load(SETTINGS_SCRIPT).new()
	settings.name = "SettingsProbe"
	return settings


func _test_defaults_cover_every_spec_key() -> void:
	a.section("settings: defaults")
	var s: Node = _make_settings()
	var defaults: Dictionary = s.defaults()
	# Every key the app reads must appear in defaults(), or a saved file would
	# silently drop it on the next save.
	for key in ["engine_path", "model_path", "human_model_path", "config_path",
			"live_visits", "review_visits", "ai_visits", "use_human_model",
			"human_profile", "board_size", "komi", "rules", "handicap",
			"show_coordinates", "show_move_numbers", "show_last_move",
			"show_candidates", "show_ownership", "show_hints",
			"inaccuracy_at", "mistake_at", "blunder_at",
			"board_color", "line_color", "last_dir"]:
		a.check(defaults.has(key), "defaults() has %s" % key)
	# Classification bands: 2..5 inaccuracy, 5..10 mistake, 10+ blunder.
	a.check_eq(s.inaccuracy_at, 2.0, "inaccuracy threshold")
	a.check_eq(s.mistake_at, 5.0, "mistake threshold")
	a.check_eq(s.blunder_at, 10.0, "blunder threshold")
	a.check(s.inaccuracy_at < s.mistake_at and s.mistake_at < s.blunder_at,
		"thresholds ascend")
	# No analysis during a game unless the user asks for it.
	a.check_eq(s.show_hints, false, "hints are off by default")
	# Colours must be valid HTML so they survive the JSON round trip.
	for key in ["board_color", "line_color"]:
		var text: String = String(defaults[key])
		a.check(Color.html_is_valid(text), "%s default %s is a valid colour" % [key, text])
	a.check_eq(s.board_size, 19, "default board size")
	a.check_eq(s.komi, 6.5, "default komi")
	a.check(s.is_valid_board_size(s.board_size), "default size is supported")
	s.free()


func _test_set_value_coercion() -> void:
	a.section("settings: set_value coercion")
	var s: Node = _make_settings()
	s.set_value("inaccuracy_at", 3)
	a.check_eq(s.inaccuracy_at, 3.0, "int threshold becomes float")
	s.set_value("mistake_at", "7.5")
	a.check_eq(s.mistake_at, 7.5, "numeric string becomes float")
	s.set_value("show_hints", true)
	a.check_eq(s.show_hints, true, "bool flag set")
	s.set_value("show_hints", 0)
	a.check_eq(s.show_hints, false, "int coerced to bool")
	s.set_value("board_color", "#123456")
	a.check_eq(s.board_color, "#123456", "colour stored as text")
	s.set_value("board_size", 13)
	a.check_eq(s.board_size, 13, "int size")
	# An unknown key must not create a stray property.
	s.set_value("definitely_not_a_setting", 1)
	a.check(not (s as Object).get_property_list().any(
		func(p: Dictionary) -> bool: return String(p["name"]) == "definitely_not_a_setting"),
		"unknown key does not add a property")
	s.free()


func _test_colour_helpers() -> void:
	a.section("settings: colour helpers")
	var s: Node = _make_settings()
	s.set_color("board_color", Color(0.8, 0.6, 0.3))
	var back: Color = s.get_color("board_color")
	# Colours are stored as 8-bit hex, so a round trip is exact only to 1/255.
	a.check(_close(back.r, 0.8) and _close(back.g, 0.6) and _close(back.b, 0.3),
		"colour round-trips through text")
	s.board_color = "not a colour"
	a.check_eq(s.get_color("board_color", Color(1, 0, 0)), Color(1, 0, 0),
		"a broken colour falls back")
	s.board_color = "#abc"
	a.check_eq(s.get_color("board_color"), Color.from_string("#aabbcc", Color.BLACK),
		"a short html colour is accepted")
	s.free()


## Colours survive JSON as 8-bit hex, so components may move by up to half a
## step (1/510) on the way round.
func _close(a_value: float, b_value: float) -> bool:
	return absf(a_value - b_value) < 1.0 / 255.0
