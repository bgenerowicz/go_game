extends Node

## User settings, stored as JSON in user://settings.json (PLAN 5 architecture).
## Registered as the autoload "Settings".
##
## Every value has a working default, so a fresh user:// folder gives a usable
## first run: paths left empty mean "auto-detect next to the project".

const FILE_NAME: String = "settings.json"

## The file actually read and written. Scripted runs (the tests) switch this to
## a file of their own so they never write test values into the user's
## settings.
var file_name: String = FILE_NAME

signal settings_changed

var engine_path: String = ""
var model_path: String = ""
var human_model_path: String = ""
var config_path: String = ""

## Visit budgets (PLAN 5.3).
var live_visits: int = 2000
var review_visits: int = 200
var ai_visits: int = 60

## Human-like opponent (PLAN 4.7 / 5.4).
var use_human_model: bool = true
var human_profile: String = "rank_5k"

## Board defaults for a new game: the choices made in the New game dialog the
## last time, so the next game starts from them.
var board_size: int = 19
var komi: float = 6.5
var rules: String = "japanese"
var handicap: int = 0
## True when that komi was typed by hand; otherwise the dialog fills in the
## standard komi for the rules (see NewGameDialog.standard_komi).
var komi_custom: bool = false
## The opponent chosen last time ("rank_5k", "preaz_10k", "rank_beginner", ...),
## or "" for a game between two people.
var new_game_profile: String = "rank_5k"

## Overlays.
var show_coordinates: bool = true
var show_move_numbers: bool = false
var show_last_move: bool = true
var show_candidates: bool = true
var show_ownership: bool = false
## PLAN 6.1: no analysis output during a game unless the user ticks "show hints".
var show_hints: bool = false

## Mistake thresholds in points (PLAN 6.2: "Thresholds are settings").
var inaccuracy_at: float = 2.0
var mistake_at: float = 5.0
var blunder_at: float = 10.0

## Board colours (PLAN 6.3), stored as "#rrggbb" so they survive JSON.
var board_color: String = "#d5ae6a"
var line_color: String = "#261c0f"

## File dialogs remember where the user last looked.
var last_dir: String = ""

var loaded: bool = false
var load_error: String = ""

## Keys this app knows about. Unknown keys in the file are preserved so a newer
## build's settings survive a round trip through an older one.
var _extra: Dictionary = {}


func _ready() -> void:
	load_settings()


func defaults() -> Dictionary:
	return {
		"engine_path": engine_path,
		"model_path": model_path,
		"human_model_path": human_model_path,
		"config_path": config_path,
		"live_visits": live_visits,
		"review_visits": review_visits,
		"ai_visits": ai_visits,
		"use_human_model": use_human_model,
		"human_profile": human_profile,
		"board_size": board_size,
		"komi": komi,
		"rules": rules,
		"handicap": handicap,
		"komi_custom": komi_custom,
		"new_game_profile": new_game_profile,
		"show_coordinates": show_coordinates,
		"show_move_numbers": show_move_numbers,
		"show_last_move": show_last_move,
		"show_candidates": show_candidates,
		"show_ownership": show_ownership,
		"show_hints": show_hints,
		"inaccuracy_at": inaccuracy_at,
		"mistake_at": mistake_at,
		"blunder_at": blunder_at,
		"board_color": board_color,
		"line_color": line_color,
		"last_dir": last_dir,
	}


func load_settings() -> void:
	loaded = false
	load_error = ""
	var path: String = "user://" + file_name
	if not FileAccess.file_exists(path):
		# A missing file is the normal first-run state, not an error.
		loaded = true
		return
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		load_error = "could not open %s (%s)" % [path, error_string(FileAccess.get_open_error())]
		return
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		load_error = "%s is not a JSON object; keeping the defaults" % path
		push_warning("Settings: " + load_error)
		return
	var data: Dictionary = parsed
	_extra = data.duplicate(true)
	engine_path = String(data.get("engine_path", engine_path))
	model_path = String(data.get("model_path", model_path))
	human_model_path = String(data.get("human_model_path", human_model_path))
	config_path = String(data.get("config_path", config_path))
	live_visits = int(data.get("live_visits", live_visits))
	review_visits = int(data.get("review_visits", review_visits))
	ai_visits = int(data.get("ai_visits", ai_visits))
	use_human_model = bool(data.get("use_human_model", use_human_model))
	human_profile = String(data.get("human_profile", human_profile))
	board_size = int(data.get("board_size", board_size))
	komi = float(data.get("komi", komi))
	rules = String(data.get("rules", rules))
	handicap = int(data.get("handicap", handicap))
	komi_custom = bool(data.get("komi_custom", komi_custom))
	new_game_profile = String(data.get("new_game_profile", new_game_profile))
	show_coordinates = bool(data.get("show_coordinates", show_coordinates))
	show_move_numbers = bool(data.get("show_move_numbers", show_move_numbers))
	show_last_move = bool(data.get("show_last_move", show_last_move))
	show_candidates = bool(data.get("show_candidates", show_candidates))
	show_ownership = bool(data.get("show_ownership", show_ownership))
	show_hints = bool(data.get("show_hints", show_hints))
	inaccuracy_at = float(data.get("inaccuracy_at", inaccuracy_at))
	mistake_at = float(data.get("mistake_at", mistake_at))
	blunder_at = float(data.get("blunder_at", blunder_at))
	board_color = String(data.get("board_color", board_color))
	line_color = String(data.get("line_color", line_color))
	last_dir = String(data.get("last_dir", last_dir))
	loaded = true
	settings_changed.emit()


func save_settings() -> void:
	var data: Dictionary = _extra.duplicate(true)
	data.merge(defaults(), true)
	var file: FileAccess = FileAccess.open("user://" + file_name, FileAccess.WRITE)
	if file == null:
		load_error = "could not write user://%s (%s)" \
			% [file_name, error_string(FileAccess.get_open_error())]
		push_warning("Settings: " + load_error)
		return
	# One line is enough; no indent, so the file stays easy to diff by hand.
	file.store_string(JSON.stringify(data))
	file.close()
	settings_changed.emit()


## Applies values and saves. Callers that only preview should set fields and
## emit settings_changed themselves.
func apply_and_save(values: Dictionary) -> void:
	for key in values.keys():
		set_value(key, values[key])
	save_settings()


func set_value(key: String, value: Variant) -> void:
	match key:
		"engine_path", "model_path", "human_model_path", "config_path", \
		"human_profile", "rules", "last_dir", "board_color", "line_color", \
		"new_game_profile":
			set(key, String(value))
		"live_visits", "review_visits", "ai_visits", "board_size", "handicap":
			set(key, int(value))
		"komi", "inaccuracy_at", "mistake_at", "blunder_at":
			set(key, float(value))
		"use_human_model", "show_coordinates", "show_move_numbers", \
		"show_last_move", "show_candidates", "show_ownership", "show_hints", \
		"komi_custom":
			set(key, bool(value))
		_:
			push_warning("Settings: unknown key %s" % key)


## The board sizes the app supports (PLAN section 2).
func is_valid_board_size(value: int) -> bool:
	return value == 9 or value == 13 or value == 19


## Colours are stored as "#rrggbb" strings so they survive JSON; this reads one
## back, falling back to a default when the stored text is not a colour.
func get_color(key: String, fallback: Color = Color.MAGENTA) -> Color:
	var text: String = String(get(key))
	if not Color.html_is_valid(text):
		return fallback
	return Color.from_string(text, fallback)


func set_color(key: String, value: Color) -> void:
	set_value(key, value.to_html(false))


## A sensible folder for the SGF dialogs on this OS (PLAN milestone 9): the last
## place the user looked if it still exists, otherwise Documents, then Desktop,
## then the project folder. Never returns "" so a fresh user:// first run still
## opens a usable dialog.
func default_sgf_dir() -> String:
	if not last_dir.is_empty() and DirAccess.dir_exists_absolute(last_dir):
		return last_dir
	for dir in [OS.SYSTEM_DIR_DOCUMENTS, OS.SYSTEM_DIR_DESKTOP]:
		var path: String = OS.get_system_dir(dir)
		if not path.is_empty() and DirAccess.dir_exists_absolute(path):
			return path
	return ProjectSettings.globalize_path("res://")
