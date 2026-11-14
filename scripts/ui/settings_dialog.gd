extends AcceptDialog

## Settings dialog (PLAN 5.2): engine paths, visit budgets, human profile,
## overlay toggles, engine status and the last stderr lines for troubleshooting.
## Built in code so it needs no scene file.

var engine_line: LineEdit
var model_line: LineEdit
var human_model_line: LineEdit
var config_line: LineEdit
var live_visits_box: SpinBox
var review_visits_box: SpinBox
var ai_visits_box: SpinBox
var use_human_box: CheckBox
var profile_box: OptionButton
var coordinates_box: CheckBox
var numbers_box: CheckBox
var last_move_box: CheckBox
var candidates_box: CheckBox
var ownership_box: CheckBox
var hints_box: CheckBox
var inaccuracy_box: SpinBox
var mistake_box: SpinBox
var blunder_box: SpinBox
var board_color_button: ColorPickerButton
var line_color_button: ColorPickerButton
var status_label: Label
var log_box: TextEdit
var detected_label: Label

## PLAN section 6.3: the settings dialog shows the last 50 stderr lines.
const LOG_LINES: int = 50

const PROFILES: Array[String] = [
	"rank_20k", "rank_15k", "rank_10k", "rank_8k", "rank_5k", "rank_2k", "rank_1k",
	"rank_1d", "rank_2d", "rank_5d", "rank_8d", "rank_9d",
	"preaz_20k", "preaz_10k", "preaz_5k", "preaz_1d", "preaz_5d", "preaz_9d",
	"proyear_1800", "proyear_1900", "proyear_1990", "proyear_2023",
]


func _ready() -> void:
	title = "Settings"
	ok_button_text = "Save"
	_build()
	# The engine may already be running when the dialog opens; keep the log live.
	var engine: Node = get_node_or_null("/root/KataGo")
	if engine != null:
		engine.log_line.connect(_append_log)
	get_ok_button().pressed.connect(_on_save)
	_load_values()


func _build() -> void:
	var column: VBoxContainer = VBoxContainer.new()
	column.name = "Column"
	column.add_theme_constant_override("separation", 10)
	add_child(column)

	column.add_child(_section("Engine"))
	var engine_grid: GridContainer = GridContainer.new()
	engine_grid.name = "EngineGrid"
	engine_grid.columns = 3
	column.add_child(engine_grid)
	engine_line = _path_row(engine_grid, "engine_path", "KataGo binary")
	model_line = _path_row(engine_grid, "model_path", "Main network")
	human_model_line = _path_row(engine_grid, "human_model_path", "Human network")
	config_line = _path_row(engine_grid, "config_path", "Config file")

	detected_label = Label.new()
	detected_label.name = "Detected"
	detected_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(detected_label)

	var start_button: Button = Button.new()
	start_button.name = "StartEngine"
	start_button.text = "Start / restart engine"
	start_button.pressed.connect(_on_restart_engine)
	column.add_child(start_button)

	status_label = Label.new()
	status_label.name = "EngineStatus"
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(status_label)

	column.add_child(_section("Analysis"))
	var visit_grid: GridContainer = GridContainer.new()
	visit_grid.name = "VisitGrid"
	visit_grid.columns = 2
	column.add_child(visit_grid)
	visit_grid.add_child(_label("Live analysis visits"))
	live_visits_box = _spin("live_visits", 10, 20000, 2000)
	visit_grid.add_child(live_visits_box)
	visit_grid.add_child(_label("Full review visits per turn"))
	review_visits_box = _spin("review_visits", 5, 5000, 200)
	visit_grid.add_child(review_visits_box)
	visit_grid.add_child(_label("Opponent move visits"))
	ai_visits_box = _spin("ai_visits", 1, 2000, 60)
	visit_grid.add_child(ai_visits_box)

	var human_row: HBoxContainer = HBoxContainer.new()
	human_row.name = "HumanRow"
	use_human_box = CheckBox.new()
	use_human_box.name = "UseHuman"
	use_human_box.text = "Human-like network for the opponent"
	human_row.add_child(use_human_box)
	human_row.add_child(_label("Style"))
	profile_box = OptionButton.new()
	profile_box.name = "Profile"
	for profile in PROFILES:
		profile_box.add_item(profile)
	human_row.add_child(profile_box)
	column.add_child(human_row)

	column.add_child(_section("Board overlays"))
	coordinates_box = _check("Coordinates")
	numbers_box = _check("Move numbers")
	last_move_box = _check("Mark the last move")
	candidates_box = _check("Candidate move overlays")
	ownership_box = _check("Territory ownership")
	# PLAN 6.1: analysis output stays hidden during a game unless this is ticked.
	hints_box = _check("Show hints during a game")
	for box in [coordinates_box, numbers_box, last_move_box, candidates_box,
			ownership_box, hints_box]:
		column.add_child(box)

	# PLAN 6.2: "Thresholds are settings". Loss in points of win-rate/score lead.
	column.add_child(_section("Mistake thresholds (points lost)"))
	var threshold_grid: GridContainer = GridContainer.new()
	threshold_grid.name = "ThresholdGrid"
	threshold_grid.columns = 2
	column.add_child(threshold_grid)
	threshold_grid.add_child(_label("Inaccuracy from"))
	inaccuracy_box = _float_spin("inaccuracy_at", 0.5, 50.0)
	threshold_grid.add_child(inaccuracy_box)
	threshold_grid.add_child(_label("Mistake from"))
	mistake_box = _float_spin("mistake_at", 0.5, 100.0)
	threshold_grid.add_child(mistake_box)
	threshold_grid.add_child(_label("Blunder from"))
	blunder_box = _float_spin("blunder_at", 0.5, 200.0)
	threshold_grid.add_child(blunder_box)

	# PLAN 6.3: board colours.
	column.add_child(_section("Board colours"))
	var color_grid: GridContainer = GridContainer.new()
	color_grid.name = "ColorGrid"
	color_grid.columns = 2
	column.add_child(color_grid)
	color_grid.add_child(_label("Board"))
	board_color_button = ColorPickerButton.new()
	board_color_button.name = "board_color"
	board_color_button.custom_minimum_size = Vector2(120, 26)
	color_grid.add_child(board_color_button)
	color_grid.add_child(_label("Lines"))
	line_color_button = ColorPickerButton.new()
	line_color_button.name = "line_color"
	line_color_button.custom_minimum_size = Vector2(120, 26)
	color_grid.add_child(line_color_button)

	column.add_child(_section("Engine log (last %d stderr lines)" % LOG_LINES))
	log_box = TextEdit.new()
	log_box.name = "Log"
	log_box.editable = false
	log_box.selecting_enabled = true
	log_box.shortcut_keys_enabled = false
	log_box.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	log_box.custom_minimum_size = Vector2(420, 160)
	log_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_box.text = "(nothing yet)"
	column.add_child(log_box)


func _section(text: String) -> Label:
	var label: Label = Label.new()
	label.name = text
	label.text = text
	label.add_theme_font_size_override("font_size", 15)
	return label


func _label(text: String) -> Label:
	var label: Label = Label.new()
	label.name = text
	label.text = text
	return label


func _check(text: String) -> CheckBox:
	var box: CheckBox = CheckBox.new()
	box.name = text
	box.text = text
	return box


func _spin(setting_key: String, low: int, high: int, page: int) -> SpinBox:
	var box: SpinBox = SpinBox.new()
	box.name = setting_key
	box.min_value = low
	box.max_value = high
	box.step = 1
	box.page = page
	return box


## Same as _spin but allows halves, which is what the mistake thresholds need.
func _float_spin(setting_key: String, low: float, high: float) -> SpinBox:
	var box: SpinBox = SpinBox.new()
	box.name = setting_key
	box.min_value = low
	box.max_value = high
	box.step = 0.5
	box.page = 1
	box.custom_minimum_size = Vector2(120, 0)
	return box


## A label, a path field and a browse button, all in one grid row.
func _path_row(grid: GridContainer, setting_key: String, caption: String) -> LineEdit:
	grid.add_child(_label(caption))
	var line: LineEdit = LineEdit.new()
	line.name = setting_key
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.placeholder_text = "(auto-detect)"
	grid.add_child(line)
	var browse: Button = Button.new()
	browse.name = setting_key + "_browse"
	browse.text = "Browse"
	browse.pressed.connect(_on_browse.bind(line))
	grid.add_child(browse)
	return line


func _on_browse(line: LineEdit) -> void:
	var picker: FileDialog = FileDialog.new()
	picker.name = "Picker"
	picker.access = FileDialog.ACCESS_FILESYSTEM
	picker.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	picker.title = "Choose a file"
	var settings: Node = get_node_or_null("/root/Settings")
	if settings != null and String(settings.last_dir) != "":
		picker.current_dir = String(settings.last_dir)
	picker.file_selected.connect(func(path: String) -> void:
		line.text = path
		picker.queue_free()
	)
	picker.confirmed.connect(func() -> void:
		# cancelled or closed without a selection: just drop the picker
		picker.queue_free()
	)
	picker.close_requested.connect(func() -> void:
		picker.queue_free()
	)
	add_child(picker)
	picker.popup_centered(Vector2i(900, 600))


func _settings() -> Node:
	return get_node_or_null("/root/Settings")


func _engine() -> Node:
	return get_node_or_null("/root/KataGo")


## The path a box should show: the user's own setting when they set one,
## otherwise whatever the engine node auto-detected. Both use the same key names.
func _effective(key: String) -> String:
	var settings: Node = _settings()
	var configured: String = ""
	if settings != null:
		configured = String(settings.get(key))
	if configured.strip_edges() != "":
		return configured
	var engine: Node = _engine()
	if engine != null:
		return String(engine.get(key))
	return ""


func _load_values() -> void:
	var settings: Node = _settings()
	if settings == null:
		return
	# A blank setting means "auto-detect", so show what the engine actually found
	# rather than an empty box; the user can still clear it to go back to probing.
	engine_line.text = _effective("engine_path")
	model_line.text = _effective("model_path")
	human_model_line.text = _effective("human_model_path")
	config_line.text = _effective("config_path")
	live_visits_box.value = int(settings.live_visits)
	review_visits_box.value = int(settings.review_visits)
	ai_visits_box.value = int(settings.ai_visits)
	use_human_box.button_pressed = bool(settings.use_human_model)
	profile_box.select(maxi(0, PROFILES.find(String(settings.human_profile))))
	coordinates_box.button_pressed = bool(settings.show_coordinates)
	numbers_box.button_pressed = bool(settings.show_move_numbers)
	last_move_box.button_pressed = bool(settings.show_last_move)
	candidates_box.button_pressed = bool(settings.show_candidates)
	ownership_box.button_pressed = bool(settings.show_ownership)
	hints_box.button_pressed = bool(settings.show_hints)
	inaccuracy_box.value = float(settings.inaccuracy_at)
	mistake_box.value = float(settings.mistake_at)
	blunder_box.value = float(settings.blunder_at)
	if settings.has_method("get_color"):
		board_color_button.color = settings.get_color("board_color", Color(0.84, 0.68, 0.42))
		line_color_button.color = settings.get_color("line_color", Color(0.15, 0.11, 0.06))
	_refresh_engine_status()


func _refresh_engine_status() -> void:
	var engine: Node = _engine()
	if engine == null:
		status_label.text = "Engine node is missing."
		detected_label.text = ""
		return
	if bool(engine.running):
		status_label.text = "Engine running, pid %d, version %s." \
			% [int(engine.pid), String(engine.version)]
	elif engine.is_alive():
		status_label.text = "Engine process %d is alive but not responding." % int(engine.last_pid)
	else:
		var reason: String = String(engine.start_error())
		status_label.text = "Engine not running." + (" " + reason if reason != "" else "")
	var missing: PackedStringArray = engine.missing_files()
	if missing.is_empty():
		detected_label.text = "Engine files look present: %s" % String(engine.engine_path)
	else:
		detected_label.text = "Missing: " + ", ".join(missing)
	_refresh_log()


func _on_restart_engine() -> void:
	var settings: Node = _settings()
	var engine: Node = _engine()
	if settings == null or engine == null:
		return
	# Save first so the engine starts with what is on screen.
	_save_values()
	engine.stop_engine()
	if not bool(engine.start_engine()):
		_refresh_engine_status()
		return
	_refresh_engine_status()


func _save_values() -> void:
	var settings: Node = _settings()
	if settings == null:
		return
	settings.apply_and_save({
		"engine_path": engine_line.text.strip_edges(),
		"model_path": model_line.text.strip_edges(),
		"human_model_path": human_model_line.text.strip_edges(),
		"config_path": config_line.text.strip_edges(),
		"live_visits": int(live_visits_box.value),
		"review_visits": int(review_visits_box.value),
		"ai_visits": int(ai_visits_box.value),
		"use_human_model": use_human_box.button_pressed,
		"human_profile": PROFILES[maxi(0, profile_box.selected)],
		"show_coordinates": coordinates_box.button_pressed,
		"show_move_numbers": numbers_box.button_pressed,
		"show_last_move": last_move_box.button_pressed,
		"show_candidates": candidates_box.button_pressed,
		"show_ownership": ownership_box.button_pressed,
		"show_hints": hints_box.button_pressed,
		"inaccuracy_at": float(inaccuracy_box.value),
		"mistake_at": float(mistake_box.value),
		"blunder_at": float(blunder_box.value),
		"board_color": board_color_button.color.to_html(),
		"line_color": line_color_button.color.to_html(),
	})
	# The engine resolves its own paths, so it must be told to look again after
	# the user edits them; otherwise saving the dialog changes nothing.
	var engine: Node = _engine()
	if engine != null and engine.has_method("rescan_paths"):
		engine.rescan_paths()

func _on_save() -> void:
	_save_values()
	_refresh_engine_status()


## The engine node keeps the whole stderr tail; the dialog just re-reads the last
## LOG_LINES of it, so opening the dialog after a crash still shows why.
func _refresh_log() -> void:
	var engine: Node = _engine()
	if engine == null:
		log_box.text = "(no engine node)"
		return
	var lines: PackedStringArray = engine.last_log_lines(LOG_LINES)
	if lines.is_empty():
		log_box.text = "(nothing yet)"
		return
	log_box.text = "\n".join(lines)
	log_box.scroll_vertical = 100000


func _append_log(_line: String) -> void:
	_refresh_log()
