extends Control

## Root of the app: layout, menus, mode switching, engine wiring.
##
## The engine nodes are reached through /root/ rather than the autoload names: a
## script that mentions an autoload identifier cannot even be parsed by a
## `--script` run, and the headless checks load this scene.

const SAVE_DIR: String = "user://games"

var flow: GameFlow = GameFlow.new()
var board_view: BoardView
var status_label: Label
var captures_label: Label
var result_label: Label
## The move number and side to play, shown large in the Game card.
var turn_label: Label
## The engine's read-out for the shown position (best move, win rate).
var analysis_label: Label
## Small second line under the turn: review-mode help.
var mode_label: Label
## Engine view: shows/hides the suggestion circles on the board.
var candidates_toggle: CheckButton
var _circles_help: Label
## Side-panel parts that change with the mode (see _update_panel_mode).
var _actions: GridContainer
var _review_card: Control
var _mistake_scroll: ScrollContainer
var engine_label: Label
var restart_button: Button
var graph_view: GraphView
var tree_view: TreeView
var side_scroller: ScrollContainer
var tree_scroller: ScrollContainer
var comment_edit: TextEdit
## Guards the comment box against writing its own text back into the tree.
var _setting_comment: bool = false
var review_label: Label
## Win-rate bar and the per-player mistake list in the info panel (PLAN 6.2).
var winrate_bar: WinRateBar
var mistake_title: Label
var mistake_box: VBoxContainer
var players_label: Label
var ownership_label: Label
var open_dialog: FileDialog
var save_dialog: FileDialog
var mode: String = "play"  # "play" or "review"
var view_menu: PopupMenu
## Mistake classification for the shown game, feeding the graph and the list.
var review: Review = null
## The settings dialog and the new-game dialog, both built on demand.
var settings_dialog: Window = null
var new_game_dialog: Window = null
## Used only for the "random" human colour choice in the new-game dialog.
var _random: RandomNumberGenerator = RandomNumberGenerator.new()

## Engine nodes, resolved from the autoloads when they exist.
var engine: Node = null
var analysis: Node = null
## The opponent, when there is one. ai_side is Board.Stone.WHITE or BLACK, or 0
## for no opponent (two humans).
var ai: AiPlayer = null
var ai_side: int = 0
var ai_request_id: String = ""
var ai_pending_node: GameNode = null
## Live analysis of the shown position, when the engine is up.
var live_enabled: bool = true
var live_request_id: String = ""


func _ready() -> void:
	if get_tree().current_scene != self:
		save_dir = TEST_SAVE_DIR
	var settings: Node = get_node_or_null("/root/Settings")
	if settings != null:
		flow.start(int(settings.board_size), float(settings.komi),
			String(settings.rules), int(settings.handicap))
	ai = AiPlayer.new()
	if settings != null:
		ai.configure(String(settings.human_profile), int(settings.ai_visits))
		# Settings changes apply live: colours, thresholds, hint gating.
		if settings.has_signal("settings_changed"):
			settings.settings_changed.connect(_apply_settings)
	_build_ui()
	_apply_appearance()
	DisplayServer.set_system_theme_change_callback(_apply_appearance)
	_apply_settings()
	# Views follow the flow itself, so anything that moves the position (a click,
	# a key, the AI, a test driving GameFlow directly) repaints the whole UI.
	flow.position_changed.connect(_on_position_changed)
	flow.game_state_changed.connect(_on_game_state_changed)
	# Dropping an .sgf onto the window opens it (PLAN 6.2).
	var window: Window = get_window()
	if window != null:
		if window.has_signal("files_dropped"):
			window.files_dropped.connect(_on_files_dropped)
		# Milestone 9: below this the board, the side panel and the move tree
		# cannot all be shown, so the window refuses to shrink further.
		_fit_window_to_screen(window)
	_engine_setup()
	_refresh()
	print("go_game: main scene loaded")


## Window sizes are in physical pixels, so on a HiDPI (Retina) screen the
## project's 1280x800 opens as a quarter-size window. Scale it (and the minimum
## size) by the screen's scale factor, keep it within the usable screen area,
## and centre it. The canvas_items stretch mode then scales the UI to match.
## Skipped for embedded/headless runs, where there is no real screen.
##
## Also skipped when the game runs inside the Godot editor's Game tab: there the
## editor owns the window's size and position, and resizing it from here left
## the picture drawn shifted inside the editor panel while the editor kept
## mapping the mouse as if it filled the panel, so the stone under the cursor
## landed rows below it.
func _fit_window_to_screen(window: Window) -> void:
	var min_logical: Vector2i = Vector2i(760, 560)
	if Engine.is_embedded_in_editor():
		return
	if DisplayServer.get_name() == "headless" or window != get_tree().root:
		window.min_size = min_logical
		return
	var screen: int = window.current_screen
	var scale: float = maxf(1.0, DisplayServer.screen_get_scale(screen))
	var usable: Rect2i = DisplayServer.screen_get_usable_rect(screen)
	var wanted: Vector2 = Vector2(1280, 800) * scale
	var limit: Vector2 = Vector2(usable.size) * 0.9
	var fit: float = minf(1.0, minf(limit.x / wanted.x, limit.y / wanted.y))
	var size: Vector2i = Vector2i(wanted * fit)
	window.min_size = Vector2i(Vector2(min_logical) * scale).min(size)
	if window.mode == Window.MODE_WINDOWED:
		window.size = size
		window.position = usable.position + (usable.size - size) / 2


func _on_position_changed(_node: GameNode) -> void:
	_refresh()
	# Whatever moved the position (the human's click, a pass, an undo), the
	# opponent gets asked for a reply when it is now its turn.
	_offer_ai_move()


func _on_game_state_changed() -> void:
	# Only a game that ended by two passes needs a count; a resignation already
	# has its result.
	if flow.over and flow.ended_by_passes:
		_schedule_scoring()
	# A finished game is auto-saved (PLAN 6.1). The result text is written once
	# the count lands, so _finish_scoring saves again after that.
	if flow.over:
		autosave()


## PLAN 6.1: after two passes, ask the engine for ownership at 500 visits, show
## the overlay and report the result as the engine's scoreLead rounded to the
## nearest 0.5, written to RE. With no engine available, fall back to a plain
## area count so a two-human game still ends with a number.
const SCORE_VISITS: int = 500
var scoring_node: GameNode = null


func _schedule_scoring() -> void:
	scoring_node = null
	if analysis == null or engine == null or not engine.is_alive():
		_apply_area_count_score()
		return
	scoring_node = flow.current()
	analysis.request(scoring_node, SCORE_VISITS, {"include_ownership": true})


func _finish_scoring(node: GameNode) -> void:
	scoring_node = null
	var score_lead: float = float((node.analysis as Dictionary).get("score_lead", 0.0))
	var text: String = Scoring.engine_result(score_lead)
	flow.result_text = text
	flow.tree.result = text
	if board_view != null:
		board_view.show_ownership = true
		if view_menu != null:
			view_menu.set_item_checked(view_menu.get_item_index(24), true)
	_refresh()


func _apply_area_count_score() -> void:
	var count: Dictionary = Scoring.area_count(flow.board(), flow.tree.komi)
	var text: String = String(count["result"]) + " (area count)"
	flow.result_text = text
	flow.tree.result = text
	_refresh()


func _build_ui() -> void:
	var column: VBoxContainer = VBoxContainer.new()
	column.name = "Column"
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	column.add_theme_constant_override("separation", 0)
	add_child(column)

	column.add_child(_build_menu())

	var body: HBoxContainer = HBoxContainer.new()
	body.name = "Body"
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(body)

	board_view = BoardView.new()
	board_view.name = "Board"
	board_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	board_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	board_view.point_clicked.connect(_on_board_clicked)
	board_view.point_hovered.connect(_on_board_hovered)
	board_view.navigate_requested.connect(_on_navigate)
	body.add_child(board_view)
	board_view.show_position(flow.tree, flow.current())

	# The side panel scrolls: at small window heights its contents (graph,
	# comment box, buttons) would otherwise be squeezed to nothing.
	side_scroller = ScrollContainer.new()
	side_scroller.name = "SideScroller"
	side_scroller.custom_minimum_size = Vector2(SIDE_WIDTH + 8, 0)
	side_scroller.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	side_scroller.add_child(_build_side_panel())
	body.add_child(side_scroller)

	# The win-rate graph runs the full width under the board, where a whole
	# game has room to be read at a glance. It appears once a review exists;
	# during play it would only take space away from the board.
	graph_view = GraphView.new()
	graph_view.name = "Graph"
	graph_view.custom_minimum_size = Vector2(0, GRAPH_HEIGHT)
	graph_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	graph_view.turn_clicked.connect(_on_graph_clicked)
	graph_view.visible = false
	column.add_child(graph_view)

	# The move tree runs along the bottom, where a long main line has room to
	# stretch sideways. One row of move circles plus the scroll bar.
	var strip: ScrollContainer = ScrollContainer.new()
	strip.name = "TreeStrip"
	strip.custom_minimum_size = Vector2(0, 64)
	strip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(strip)
	tree_scroller = strip
	tree_view = TreeView.new()
	tree_view.name = "Tree"
	# Fill the whole strip, so its background spans the window rather than
	# stopping where the last move is drawn.
	tree_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tree_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree_view.node_clicked.connect(_on_tree_clicked)
	strip.add_child(tree_view)

	_build_dialogs()


## MenuBar builds one top-level menu per PopupMenu child, titled by its name.
func _build_menu() -> MenuBar:
	var menu: MenuBar = MenuBar.new()
	menu.name = "Menu"

	var game_menu: PopupMenu = PopupMenu.new()
	game_menu.name = "Game"
	game_menu.add_item("New game", 1)
	game_menu.add_separator()
	game_menu.add_item("Pass", 2)
	game_menu.add_item("Undo move pair", 3)
	game_menu.add_item("Resign", 4)
	game_menu.id_pressed.connect(_on_game_menu)
	menu.add_child(game_menu)

	var file_menu: PopupMenu = PopupMenu.new()
	file_menu.name = "File"
	file_menu.add_item("Open SGF...", 10)
	file_menu.add_item("Save SGF...", 11)
	file_menu.add_item("Save to auto-save folder", 12)
	file_menu.add_separator()
	file_menu.add_item("Open a saved game...", 14)
	file_menu.add_item("Show saved games in Finder", 15)
	file_menu.add_separator()
	file_menu.add_item("Quit", 13)
	file_menu.id_pressed.connect(_on_file_menu)
	menu.add_child(file_menu)

	view_menu = PopupMenu.new()
	view_menu.name = "View"
	view_menu.add_check_item("Coordinates", 20)
	view_menu.add_check_item("Move numbers", 21)
	view_menu.add_check_item("Review mode", 22)
	view_menu.add_check_item("Suggested moves on the board (C)", 23)
	view_menu.add_check_item("Ownership heatmap", 24)
	view_menu.add_check_item("Live analysis", 25)
	# PLAN 6.1: analysis output is hidden during a game unless this is ticked.
	view_menu.add_check_item("Show hints during a game", 26)
	view_menu.set_item_checked(view_menu.get_item_index(20), true)
	view_menu.set_item_checked(view_menu.get_item_index(23), true)
	view_menu.set_item_checked(view_menu.get_item_index(25), true)
	view_menu.id_pressed.connect(_on_view_menu)
	menu.add_child(view_menu)

	var review_menu: PopupMenu = PopupMenu.new()
	review_menu.name = "Review"
	review_menu.add_item("Review this game", 30)
	review_menu.add_item("Cancel review", 31)
	review_menu.add_separator()
	review_menu.add_item("Settings...", 32)
	review_menu.id_pressed.connect(_on_review_menu)
	menu.add_child(review_menu)
	return menu


const SIDE_WIDTH: float = 320.0
const GRAPH_HEIGHT: float = 180.0


func _build_side_panel() -> VBoxContainer:
	var panel: VBoxContainer = VBoxContainer.new()
	panel.name = "Side"
	panel.custom_minimum_size = Vector2(SIDE_WIDTH, 0)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_constant_override("separation", 10)

	# --- Game: what is being played, by whom, and whose move it is ----------
	var game: VBoxContainer = _section(panel, "GameCard", "Game")
	status_label = _text_label("Status", FONT_SMALL, COLOR_MUTED)
	game.add_child(status_label)
	turn_label = _text_label("Turn", FONT_LARGE, COLOR_TEXT)
	game.add_child(turn_label)
	mode_label = _text_label("Mode", FONT_SMALL, COLOR_ACCENT)
	mode_label.text = "Review mode: click the board to try variations"
	mode_label.visible = false
	game.add_child(mode_label)
	players_label = _text_label("Players", FONT_BODY, COLOR_TEXT)
	game.add_child(players_label)
	captures_label = _text_label("Captures", FONT_SMALL, COLOR_MUTED)
	game.add_child(captures_label)
	result_label = _text_label("Result", FONT_BODY, COLOR_ACCENT)
	game.add_child(result_label)
	var actions: GridContainer = GridContainer.new()
	_actions = actions
	actions.name = "Actions"
	actions.columns = 2
	actions.add_theme_constant_override("h_separation", 6)
	actions.add_theme_constant_override("v_separation", 6)
	for entry in [["Pass", _on_pass], ["Undo", _on_undo], ["Resign", _on_resign],
			["New game", _on_new_game]]:
		var button: Button = _button(String(entry[0]), entry[1] as Callable)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		actions.add_child(button)
	game.add_child(actions)

	# --- Engine view of the shown position ----------------------------------
	var view: VBoxContainer = _section(panel, "AnalysisCard", "Engine view")
	winrate_bar = WinRateBar.new()
	winrate_bar.name = "WinRateBar"
	winrate_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view.add_child(winrate_bar)
	analysis_label = _text_label("Analysis", FONT_SMALL, COLOR_TEXT)
	view.add_child(analysis_label)
	# PLAN 6.2 ownership overlay: "Show 'Black +x.x' score estimate".
	ownership_label = _text_label("OwnershipEstimate", FONT_SMALL, COLOR_MUTED)
	view.add_child(ownership_label)
	candidates_toggle = CheckButton.new()
	candidates_toggle.name = "ShowCandidates"
	candidates_toggle.text = "Suggested moves on the board (C)"
	candidates_toggle.focus_mode = Control.FOCUS_NONE
	candidates_toggle.add_theme_font_size_override("font_size", FONT_SMALL)
	candidates_toggle.toggled.connect(func(on: bool) -> void:
		_set_view_setting("show_candidates", on))
	view.add_child(candidates_toggle)
	var circles_help: Label = _text_label("CandidatesHelp", FONT_SMALL, COLOR_MUTED)
	_circles_help = circles_help
	circles_help.text = "Top: win chance %  ·  bottom: points lost vs the best " \
		+ "move (blue)  ·  red ring: move played  ·  hover for the line"
	view.add_child(circles_help)

	# --- Review: progress, then the clickable mistake list ------------------
	var review_box: VBoxContainer = _section(panel, "ReviewCard", "Review")
	review_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_review_card = review_box.get_parent()
	var review_row: HBoxContainer = HBoxContainer.new()
	review_row.add_theme_constant_override("separation", 8)
	review_label = _text_label("ReviewStatus", FONT_SMALL, COLOR_MUTED)
	review_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	review_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	review_row.add_child(review_label)
	var review_button: Button = _button("Review game", _run_review)
	review_row.add_child(review_button)
	review_box.add_child(review_row)
	# PLAN 6.2: "Side panel lists the top mistakes per player; clicking one jumps
	# to it." Buttons rather than a text block so each entry is clickable.
	mistake_title = _text_label("MistakeTitle", FONT_SMALL, COLOR_MUTED)
	mistake_title.text = "Biggest mistakes (click to jump)"
	review_box.add_child(mistake_title)
	var mistake_scroll: ScrollContainer = ScrollContainer.new()
	_mistake_scroll = mistake_scroll
	mistake_scroll.name = "MistakeScroll"
	mistake_scroll.custom_minimum_size = Vector2(0, 180)
	mistake_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mistake_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	mistake_box = VBoxContainer.new()
	mistake_box.name = "MistakeList"
	mistake_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mistake_box.add_theme_constant_override("separation", 2)
	mistake_scroll.add_child(mistake_box)
	review_box.add_child(mistake_scroll)

	# --- Comment on the shown position (SGF C property, PLAN 6.2) -----------
	var notes: VBoxContainer = _section(panel, "CommentCard", "Comment")
	comment_edit = TextEdit.new()
	comment_edit.name = "Comment"
	comment_edit.custom_minimum_size = Vector2(0, 64)
	comment_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	comment_edit.placeholder_text = "Notes on this position (saved in the SGF)"
	comment_edit.text_changed.connect(_on_comment_changed)
	notes.add_child(comment_edit)

	# --- Footer: engine status and keyboard help, kept quiet ---------------
	var footer: HBoxContainer = HBoxContainer.new()
	footer.name = "Footer"
	footer.add_theme_constant_override("separation", 8)
	engine_label = _text_label("EngineStatus", FONT_SMALL, COLOR_MUTED)
	engine_label.text = "Engine: not started"
	engine_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	engine_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	footer.add_child(engine_label)
	# PLAN 5.2: a dead engine must be restartable from the UI.
	restart_button = _button("Restart engine", _restart_engine)
	restart_button.name = "RestartEngine"
	restart_button.add_theme_font_size_override("font_size", FONT_SMALL)
	footer.add_child(restart_button)
	panel.add_child(footer)
	var hint: Label = _text_label("Keys", FONT_SMALL, COLOR_MUTED)
	hint.text = "← → move   ↑ ↓ variation   Home/End   P pass   U undo   C suggestions   " \
		+ "Ctrl+O open   Ctrl+S save"
	panel.add_child(hint)
	return panel


## Side panel styling ------------------------------------------------------------

const FONT_SMALL: int = 13
const FONT_BODY: int = 15
const FONT_LARGE: int = 18
const COLOR_TEXT: Color = Color(0.9, 0.9, 0.9)
const COLOR_MUTED: Color = Color(0.62, 0.63, 0.66)
const COLOR_ACCENT: Color = Color(0.98, 0.78, 0.45)
const COLOR_CARD: Color = Color(0.2, 0.205, 0.22)


## A titled card in the side panel; returns the box its contents go in.
func _section(parent: Control, node_name: String, title: String) -> VBoxContainer:
	var card: PanelContainer = PanelContainer.new()
	card.name = node_name
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = COLOR_CARD
	style.set_corner_radius_all(6)
	style.set_content_margin_all(10)
	card.add_theme_stylebox_override("panel", style)
	parent.add_child(card)
	var box: VBoxContainer = VBoxContainer.new()
	box.name = "Body"
	box.add_theme_constant_override("separation", 6)
	card.add_child(box)
	var heading: Label = Label.new()
	heading.name = "Title"
	heading.text = title.to_upper()
	heading.add_theme_font_size_override("font_size", 11)
	heading.add_theme_color_override("font_color", COLOR_MUTED)
	box.add_child(heading)
	return box


func _text_label(node_name: String, font_size: int, color: Color) -> Label:
	var label: Label = Label.new()
	label.name = node_name
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _button(text: String, handler: Callable) -> Button:
	var button: Button = Button.new()
	button.name = text
	button.text = text
	# Buttons must not take GUI focus: a focused control swallows the arrow keys
	# that review-mode navigation needs (they arrive as ui_left/ui_right/...).
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(handler)
	return button


func _build_dialogs() -> void:
	open_dialog = FileDialog.new()
	open_dialog.name = "OpenDialog"
	open_dialog.access = FileDialog.ACCESS_FILESYSTEM
	open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	open_dialog.filters = PackedStringArray(["*.sgf ; SGF go games"])
	open_dialog.file_selected.connect(_on_open_path)
	add_child(open_dialog)

	save_dialog = FileDialog.new()
	save_dialog.name = "SaveDialog"
	save_dialog.access = FileDialog.ACCESS_FILESYSTEM
	save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	save_dialog.filters = PackedStringArray(["*.sgf ; SGF go games"])
	save_dialog.file_selected.connect(_on_save_path)
	add_child(save_dialog)


## Engine wiring ------------------------------------------------------------

## Finds the KataGo / Analysis autoloads when they are present and starts the
## engine. Everything degrades quietly when they are not: the app stays usable
## for two-human play and SGF review, which is what a machine without the
## gitignored engine files gets.
func _engine_setup() -> void:
	engine = get_node_or_null("/root/KataGo")
	analysis = get_node_or_null("/root/Analysis")
	if engine == null or analysis == null:
		_set_engine_status("engine not loaded")
		return
	analysis.use_engine(engine)
	engine.engine_ready.connect(_on_engine_ready)
	engine.engine_failed.connect(_on_engine_failed)
	analysis.analysis_updated.connect(_on_analysis_updated)
	analysis.live_updated.connect(_on_analysis_updated)
	analysis.review_progress.connect(_on_review_progress)
	analysis.review_turn_analysed.connect(_on_review_turn_analysed)
	analysis.review_finished.connect(_on_review_finished)
	analysis.review_failed.connect(_on_review_failed)
	if not engine.is_available():
		var missing: PackedStringArray = engine.missing_files()
		_set_engine_status("engine files missing: " + ", ".join(missing))
		return
	_set_engine_status("starting engine")
	engine.nn_board_size = flow.tree.size
	if not engine.start_engine():
		_set_engine_status("engine failed to start: " + String(engine.start_error()))


func _on_engine_ready() -> void:
	_set_engine_status("engine ready (pid %d)" % int(engine.pid))
	_request_live_analysis()
	_offer_ai_move()


func _on_engine_failed(message: String) -> void:
	_set_engine_status("engine stopped: " + message)
	ai_request_id = ""
	ai_pending_node = null
	live_request_id = ""


func _set_engine_status(text: String) -> void:
	if engine_label != null:
		engine_label.text = "Engine: " + text
	# Also put it on the console: a first run with no engine files must say
	# plainly which path to set (PLAN milestone 9).
	print("engine status: " + text)


## PLAN 5.2: when the engine dies (crash, killed process, bad config) the user
## gets a message naming the reason and a way to bring it back without quitting.
func _restart_engine() -> void:
	if engine == null:
		_set_engine_status("engine scripts not loaded; check the install")
		return
	if engine.is_available():
		_set_engine_status("restarting engine")
		engine.stop_engine()
		if not engine.start_engine():
			_set_engine_status("engine failed to start: " + String(engine.start_error()))
			return
	else:
		_set_engine_status("still missing: " + ", ".join(engine.missing_files()))
		# The settings dialog is where the paths get fixed.
		_open_settings()


## Review of the whole game (PLAN 5.3): one query listing every turn of the main
## line. Results land in node.analysis, which the graph and mistake list read.
func _run_review() -> void:
	if analysis == null or engine == null or not engine.running:
		_set_review_status("Review needs the engine running")
		return
	if analysis.is_reviewing():
		return
	review = Review.new(flow.tree)
	var settings: Node = get_node_or_null("/root/Settings")
	var visits: int = int(settings.review_visits) if settings != null else 200
	# Reviewing means reading the game, not playing on: switch to review mode
	# so the board shows the engine's view and clicks explore variations.
	_set_mode("review")
	# The review owns the engine until it is done; a 2000-visit live search at
	# higher priority would only slow it down.
	analysis.cancel_live()
	live_request_id = ""
	# The board follows the review from the first move, so the position on
	# screen is the one the engine has just evaluated.
	flow.tree.go_to_root()
	_review_follow = flow.current()
	_set_review_status("Starting: %d positions at %d visits each"
		% [flow.tree.main_line_length(), visits])
	analysis.request_review(flow.tree, visits)
	_refresh()


## While a review runs, the board shows each position as the engine finishes it.
## It only moves forward (two positions are analysed at once, so answers can
## arrive slightly out of order), and it stops following as soon as the user
## navigates somewhere else themself.
var _review_follow: GameNode = null


func _on_review_turn_analysed(node: GameNode) -> void:
	if _review_follow == null or node == null:
		return
	if flow.current() != _review_follow:
		_review_follow = null  # the user moved; leave the board where they put it
		return
	if flow.tree.move_count_to(node) <= flow.tree.move_count_to(_review_follow):
		return
	flow.tree.go_to(node)
	_review_follow = node
	_refresh()


func _on_review_progress(done: int, total: int) -> void:
	var status: String = "Reviewing… %d of %d positions" % [done, total]
	if _review_follow != null:
		status += " (showing move %d)" % flow.tree.move_count_to(_review_follow)
	_set_review_status(status)
	if graph_view != null:
		graph_view.refresh_data()
	# The mistake list fills in as the review goes, not only at the end; it is
	# rebuilt at most every few answers to keep the UI cheap.
	if done % 8 == 0:
		_show_mistakes(false)


func _on_review_finished() -> void:
	_review_follow = null
	_show_mistakes()
	if graph_view != null:
		graph_view.refresh_data()
	_request_live_analysis()


func _on_review_failed(message: String) -> void:
	_set_review_status("Review failed: " + message)


func _set_review_status(text: String) -> void:
	if review_label != null:
		review_label.text = text


## The mistake list in the side panel (PLAN 6.2): "Side panel lists the top
## mistakes per player; clicking one jumps to it."
const MISTAKES_PER_PLAYER: int = 6


func _show_mistakes(update_status: bool = true) -> void:
	if mistake_box == null:
		return
	for child in mistake_box.get_children():
		child.queue_free()
	if mistake_title != null:
		mistake_title.visible = review != null
	if review == null:
		if review_label != null:
			review_label.text = "Not reviewed yet"
		return
	var found: Array = review.mistakes()
	if review_label != null and update_status:
		review_label.text = "%d positions analysed, %d mistake(s)" \
			% [review.analysed_turns(), found.size()]
	if found.is_empty():
		var none: Label = _text_label("NoMistakes", FONT_SMALL, COLOR_MUTED)
		none.text = "No mistakes above the threshold."
		mistake_box.add_child(none)
		return
	for colour in [Board.Stone.BLACK, Board.Stone.WHITE]:
		var entries: Array = review.mistakes_for(colour, MISTAKES_PER_PLAYER)
		if entries.is_empty():
			continue
		var header: Label = _text_label(
			"Mistakes%s" % ("Black" if colour == Board.Stone.BLACK else "White"),
			FONT_SMALL, COLOR_MUTED)
		header.text = "●  Black" if colour == Board.Stone.BLACK else "○  White"
		mistake_box.add_child(header)
		for entry in entries:
			mistake_box.add_child(_mistake_button(entry as Dictionary))


## Colour per severity, so the worst moves stand out in the list.
const KIND_COLORS: Dictionary = {
	"blunder": Color(0.95, 0.42, 0.38),
	"mistake": Color(0.98, 0.66, 0.35),
	"inaccuracy": Color(0.92, 0.84, 0.45),
}


## One clickable row: "Move 35  A6   mistake  -7.3   best E2". Clicking jumps
## to the move.
func _mistake_button(info: Dictionary) -> Button:
	var node: GameNode = info["node"] as GameNode
	var colour: String = "B" if int(info["color"]) == Board.Stone.BLACK else "W"
	var best: String = _best_move_before(node)
	var kind: String = String(info["kind"])
	var button: Button = Button.new()
	button.name = "Mistake_%s_%s" % [colour, String(info["move"])]
	var number: int = flow.tree.move_count_to(node) if node != null else 0
	button.text = "Move %d   %s   %s %+.1f   (best %s)" % [
		number, String(info["move"]), kind, -float(info["loss"]), best]
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.focus_mode = Control.FOCUS_NONE
	button.flat = true
	button.add_theme_font_size_override("font_size", FONT_SMALL)
	var tint: Color = KIND_COLORS.get(kind, COLOR_TEXT)
	button.add_theme_color_override("font_color", tint)
	button.add_theme_color_override("font_hover_color", tint.lightened(0.3))
	if node != null:
		button.pressed.connect(func() -> void:
			_goto(node))
	return button


## The engine's preferred move at the position just before this one was played.
func _best_move_before(node: GameNode) -> String:
	if node == null or node.parent == null:
		return "?"
	var before: Dictionary = node.parent.analysis as Dictionary
	var moves: Array = before.get("moves", []) as Array
	if moves.is_empty():
		return "?"
	return String((moves[0] as Dictionary).get("move", "?"))


## Clicking the graph jumps to that turn.
func _on_graph_clicked(turn_number: int) -> void:
	var node: GameNode = flow.tree.find_by_move_index(turn_number)
	if node == null:
		return
	_goto(node)


func _goto(node: GameNode) -> void:
	flow.tree.go_to(node)
	_refresh()
	_request_live_analysis()


## Live analysis of the shown position (PLAN 5.3). Analysis.request_live already
## terminates the query it replaces, so navigating cancels the old search.
func _request_live_analysis() -> void:
	if analysis == null or not live_enabled:
		return
	# A finished game is still analysed in review mode: that is when the user
	# tries variations and wants the engine's view of them.
	if flow.over and mode != "review":
		return
	# PLAN 6.1: during a game the engine is not asked for hints unless the user
	# ticked "show hints". The opponent's own move request is separate.
	if not _hints_visible():
		return
	if engine == null or not engine.running:
		return
	if analysis.is_reviewing():
		return  # the review answers every main-line position anyway
	var settings: Node = get_node_or_null("/root/Settings")
	var visits: int = int(settings.live_visits) if settings != null else 2000
	live_request_id = analysis.request_live(flow.tree, flow.current(), visits)


func _on_analysis_updated(node: GameNode) -> void:
	if node == null:
		return
	if node == scoring_node:
		_finish_scoring(node)
	if node == flow.current() and _hints_visible():
		board_view.set_analysis(node.analysis)
		_show_analysis(node)
	if node == ai_pending_node and ai_side != 0:
		_play_ai_move(node)


## A short read-out of the cached result for the shown position, plus the win
## rate bar and the ownership estimate in the info panel (PLAN 6.2).
##
## The engine config sets reportAnalysisWinratesAs = BLACK, so "winrate" and
## "score_lead" are already Black-perspective: the bar needs no conversion, but
## the sentence quotes the figure for whoever is to move.
func _show_analysis(node: GameNode) -> void:
	var result: Dictionary = node.analysis
	if result.is_empty():
		_clear_analysis_readout()
		return
	var best: Array = result.get("moves", []) as Array
	if best.is_empty():
		_clear_analysis_readout()
		return
	var top: Dictionary = best[0] as Dictionary
	var turn: int = flow.tree.turn_at(node)
	# 0..1 from Black's point of view.
	var black_rate: float = clampf(float(result.get("winrate", 0.0)), 0.0, 1.0)
	var score_lead: float = float(result.get("score_lead", 0.0))
	var visits: int = int(result.get("visits", 0))
	var to_move_rate: float = black_rate * 100.0 \
		if turn == Board.Stone.BLACK else (1.0 - black_rate) * 100.0
	var best_move: String = String(top.get("move", "?"))
	if best_move.to_lower() == "pass":
		best_move = "pass"
	analysis_label.text = "Best move for %s: %s  (%.0f%% to win)" \
		% ["Black" if turn == Board.Stone.BLACK else "White", best_move, to_move_rate]
	if winrate_bar != null:
		winrate_bar.visible = true
		winrate_bar.set_values(black_rate, score_lead, visits)
	if ownership_label != null:
		var estimate: String = Review.ownership_text(result.get("ownership", []) as Array)
		ownership_label.text = "Territory estimate: " + estimate if estimate != "" else ""


## Clears the analysis read-out, which is what the user sees when hints are off
## during a game or no result has arrived yet.
func _clear_analysis_readout() -> void:
	if winrate_bar != null:
		winrate_bar.clear_values()
		winrate_bar.visible = _hints_visible()
	if analysis_label != null:
		analysis_label.text = "" if _hints_visible() \
			else "Hints are off during play (View › Show hints during a game)"
	if ownership_label != null:
		ownership_label.text = ""


## Opponent moves (PLAN 5.4). The engine is asked for one position with the human
## policy included, then AiPlayer samples from it.
func _offer_ai_move() -> void:
	if ai_side == 0 or ai == null or analysis == null or flow.over:
		return
	if mode != "play":
		return
	if engine == null or not engine.running:
		return
	if flow.turn() != ai_side:
		return
	var node: GameNode = flow.current()
	if node == ai_pending_node:
		return  # a request for this position is already out
	ai_pending_node = node
	ai_request_id = ai.request_move(analysis, flow.tree, node)
	if ai_request_id == "":
		ai_pending_node = null
		_set_engine_status("engine busy, no opponent move yet")


func _play_ai_move(node: GameNode) -> void:
	ai_pending_node = null
	ai_request_id = ""
	# The answer is for the position it was asked about. If the human undid
	# or the game moved on meanwhile, playing it here would put a stale move
	# on a different board, so drop it and ask again for the current one.
	if node != flow.current() or flow.turn() != ai_side or flow.over or mode != "play":
		_offer_ai_move()
		return
	var previous_was_pass: bool = not node.is_root() and node.is_pass()
	var choice: Dictionary = ai.choose_move(node.analysis, flow.tree.size, ai_side,
		flow.move_number(), previous_was_pass)
	if bool(choice["resign"]):
		flow.resign(ai_side)
		_refresh()
		return
	var gtp: String = String(choice["move"])
	if gtp == "":
		_set_engine_status("no opponent move: " + String(choice["reason"]))
		return
	if Coords.is_pass(gtp):
		flow.pass_move()
	else:
		var point: Vector2i = Coords.from_gtp(gtp, flow.tree.size)
		if point == Coords.INVALID or not flow.play(point.x, point.y):
			# The engine offered something the local rules refuse; pass rather
			# than stall the game, and say so.
			_set_engine_status("engine move %s was illegal locally, passing" % gtp)
			flow.pass_move()
	_refresh()


## Interaction ------------------------------------------------------------

func _on_board_clicked(point: Vector2i) -> void:
	if mode == "review":
		_select_variation(point)
		return
	if _is_ai_turn():
		return  # the opponent's stone, not the human's
	var ok: bool = flow.play(point.x, point.y)
	if not ok:
		push_warning("Illegal move at %s: %s" % [Coords.to_gtp(point.x, point.y, flow.tree.size), flow.last_error])
	else:
		# Save as the game goes so a crash or an abandoned window still keeps it.
		autosave()
	_refresh()


## In review mode a click on an existing stone follows that variation, and a
## click on an empty point adds a new variation move (PLAN 6.2).
func _select_variation(point: Vector2i) -> void:
	for child in flow.current().children:
		if child.move != null and child.move_point() == point:
			flow.tree.go_to(child)
			_refresh()
			return
	var added: GameNode = flow.add_variation(point.x, point.y)
	if added == null:
		push_warning("Could not add a variation at %s: %s" \
			% [Coords.to_gtp(point.x, point.y, flow.tree.size), flow.last_error])
		_refresh()
		return
	_refresh()


func _on_tree_clicked(node: GameNode) -> void:
	flow.tree.go_to(node)
	_refresh()


func _on_comment_changed() -> void:
	if _setting_comment or comment_edit == null:
		return
	flow.set_comment(comment_edit.text)


func _on_board_hovered(_point: Vector2i) -> void:
	pass


## Mouse wheel over the board steps through the game.
func _on_navigate(direction: String) -> void:
	if direction == "back":
		flow.undo_step()
	elif direction == "forward":
		flow.redo_step()
	_refresh()


func _on_pass() -> void:
	if mode == "play" and not _is_ai_turn():
		flow.pass_move()
	_refresh()


## Shows what matters for the current mode. In review the game buttons give way
## to the mistake list; before any review the Review card stays compact
## instead of stretching into an empty box.
func _update_panel_mode() -> void:
	if mode_label != null:
		mode_label.visible = mode == "review"
	# The circle toggle and its explanation only matter when the engine's view
	# is on screen; during play with hints off the card stays a single line.
	var hints: bool = _hints_visible()
	if candidates_toggle != null:
		candidates_toggle.visible = hints
	if _circles_help != null:
		_circles_help.visible = hints and board_view != null and board_view.show_candidates
	if _actions != null:
		_actions.visible = mode == "play"
	var reviewed: bool = review != null
	if _review_card != null:
		_review_card.size_flags_vertical = Control.SIZE_EXPAND_FILL if reviewed \
			else Control.SIZE_SHRINK_BEGIN
	if _mistake_scroll != null:
		_mistake_scroll.visible = reviewed


## The move strip and the review graph follow the system light/dark setting
## (the side panel is dark either way). Re-applied when the setting changes.
func _apply_appearance() -> void:
	var dark: bool = _system_dark_mode()
	if dark != _last_dark:
		_last_dark = dark
		print("go_game: appearance %s" % ("dark" if dark else "light"))
	if graph_view != null:
		graph_view.set_dark(dark)
	if tree_view != null:
		tree_view.set_dark(dark)


var _last_dark: Variant = null


## Whether the system is in dark mode. A game running inside the Godot editor's
## Game tab gets an embedded display server that cannot answer this (it reports
## "not supported", so everything looked light there), so on macOS the setting
## is read from the system defaults instead in that case.
func _system_dark_mode() -> bool:
	if DisplayServer.is_dark_mode_supported() and not Engine.is_embedded_in_editor():
		return DisplayServer.is_dark_mode()
	if OS.get_name() == "macOS":
		var output: Array = []
		OS.execute("defaults", ["read", "-g", "AppleInterfaceStyle"], output)
		return output.size() > 0 and String(output[0]).strip_edges() == "Dark"
	if DisplayServer.is_dark_mode_supported():
		return DisplayServer.is_dark_mode()
	return false


## Switches between play and review mode and keeps the View menu tick in step.
func _set_mode(new_mode: String) -> void:
	mode = new_mode
	if view_menu != null:
		view_menu.set_item_checked(view_menu.get_item_index(22), mode == "review")


## A fresh game or a newly opened file has no review yet: forget the old one
## (it belongs to a different tree) and hide the graph until the next review.
func _forget_review() -> void:
	if analysis != null:
		analysis.cancel_review()
	review = null
	_review_follow = null
	_set_mode("play")
	_show_mistakes()


## KataGo runs with its network buffers sized to the board (see nn_board_size in
## katago_process.gd), so a game on a different size needs a restarted engine.
func _sync_engine_board_size() -> void:
	if engine == null:
		return
	engine.nn_board_size = flow.tree.size
	if engine.running and int(engine.running_board_size) != flow.tree.size:
		ai_pending_node = null
		ai_request_id = ""
		live_request_id = ""
		_restart_engine()


## True during a game against the engine while it is the engine's move: the
## human may not place (or pass with) the opponent's colour.
func _is_ai_turn() -> bool:
	return mode == "play" and ai_side != 0 and not flow.over and flow.turn() == ai_side


func _on_undo() -> void:
	# Against the engine, undo returns to the human's previous turn: while the
	# engine is still thinking that is just the human's own last move.
	flow.undo_pair(1 if _is_ai_turn() else 2)
	_refresh()


func _on_resign() -> void:
	flow.resign(flow.tree.turn_at(flow.current()))
	_refresh()


func _on_new_game() -> void:
	_new_game_with({
		"size": flow.tree.size,
		"komi": flow.tree.komi,
		"rules": flow.tree.rules,
		"handicap": 0,
		"profile": ai.profile if ai != null else "",
		"black_is_ai": ai_side == Board.Stone.BLACK,
	})


## Opens the dialog; the actual restart happens in _start_game once confirmed.
func _open_new_game_dialog() -> void:
	if new_game_dialog == null:
		var dialog: AcceptDialog = AcceptDialog.new()
		dialog.name = "NewGameDialog"
		var script: GDScript = load("res://scripts/ui/new_game_dialog.gd")
		if script == null:
			_set_review_status("new game dialog script missing")
			return
		dialog.set_script(script)
		dialog.confirmed.connect(_on_new_game_confirmed)
		add_child(dialog)
		new_game_dialog = dialog
	var profile: String = ai.profile if ai != null else ""
	# The dialog asks which colour the human plays, so tell it what the current
	# game has: the human holds the colour the AI does not.
	var human_colour: String = "white"
	if ai_side == Board.Stone.WHITE:
		human_colour = "black"
	elif ai_side == Board.Stone.BLACK:
		human_colour = "white"
	new_game_dialog.open_with(flow.tree.size, flow.tree.komi, flow.tree.rules,
		flow.tree.handicap, profile, human_colour)


func _on_new_game_confirmed() -> void:
	_new_game_with(new_game_dialog.params())


func _new_game_with(p: Dictionary) -> void:
	# A fresh game invalidates every cached analysis and any in-flight request.
	if analysis != null:
		analysis.cancel_live()
		analysis.cancel_review()
	ai_pending_node = null
	ai_request_id = ""
	live_request_id = ""
	_forget_review()
	flow.start(int(p["size"]), float(p["komi"]), String(p["rules"]), int(p["handicap"]))
	_sync_engine_board_size()
	ai_side = 0
	if String(p["profile"]) != "":
		ai.configure(String(p["profile"]))
		# The dialog asks which colour the human plays; the opponent takes the
		# other one. "random" is decided here, once, and stays for the game.
		var human_colour: String = String(p.get("human_colour", "white"))
		var human_black: bool = human_colour == "black"
		if human_colour == "random":
			human_black = _random.next_bool()
		ai_side = Board.Stone.WHITE if human_black else Board.Stone.BLACK
		# Named in the SGF (PB/PW), so a saved game says who played whom.
		flow.tree.black_name = _opponent_name() if ai_side == Board.Stone.BLACK else "You"
		flow.tree.white_name = _opponent_name() if ai_side == Board.Stone.WHITE else "You"
	# Every new game gets its own file; without this a second game in the same
	# session overwrote the first one's save.
	_game_from_file = false
	reset_autosave()
	_refresh()
	_offer_ai_move()


func _on_game_menu(id: int) -> void:
	match id:
		1:
			_open_new_game_dialog()
		2:
			_on_pass()
		3:
			_on_undo()
		4:
			_on_resign()


## Opens the SGF dialogs at the folder this OS suggests (milestone 9), and
## remembers the folder afterwards.
func _popup_open() -> void:
	open_dialog.current_dir = _sgf_start_dir()
	open_dialog.popup_centered(Vector2i(900, 600))


func _popup_save() -> void:
	save_dialog.current_dir = _sgf_start_dir()
	save_dialog.current_file = "game.sgf"
	save_dialog.popup_centered(Vector2i(900, 600))


func _sgf_start_dir() -> String:
	var settings: Node = get_node_or_null("/root/Settings")
	if settings != null and settings.has_method("default_sgf_dir"):
		return String(settings.default_sgf_dir())
	return ProjectSettings.globalize_path("res://")


func _on_file_menu(id: int) -> void:
	match id:
		10:
			_popup_open()
		11:
			_popup_save()
		12:
			autosave(true)
		13:
			if mode == "play":
				_save_if_played()
			get_tree().quit()
		14:
			# Played games live in a hidden Library folder; open the dialog there.
			DirAccess.make_dir_recursive_absolute(save_dir)
			open_dialog.current_dir = ProjectSettings.globalize_path(save_dir)
			open_dialog.popup_centered(Vector2i(900, 600))
		15:
			DirAccess.make_dir_recursive_absolute(save_dir)
			OS.shell_open(ProjectSettings.globalize_path(save_dir))


func _on_view_menu(id: int) -> void:
	match id:
		22:
			_set_mode("review" if mode == "play" else "play")
			_refresh()
		25:
			live_enabled = not live_enabled
			view_menu.set_item_checked(view_menu.get_item_index(25), live_enabled)
			if not live_enabled and analysis != null:
				analysis.cancel_live()
			else:
				_request_live_analysis()
		20, 21, 23, 24, 26:
			# Overlay toggles live in Settings so they persist and the settings
			# dialog cannot drift out of step with this menu (PLAN 6.2 toggles).
			var key: String = _view_key(id)
			var settings: Node = get_node_or_null("/root/Settings")
			if settings == null:
				return
			_set_view_setting(key, not bool(settings.get(key)))


## Sets one overlay toggle. It lives in Settings so it persists, and the save
## emits settings_changed, which brings the board, the View menu and the side
## panel checkbox into step (_apply_settings).
func _set_view_setting(key: String, value: bool) -> void:
	var settings: Node = get_node_or_null("/root/Settings")
	if settings == null or bool(settings.get(key)) == value:
		return
	settings.set_value(key, value)
	settings.save_settings()


## The Settings key behind each View-menu overlay toggle.
func _view_key(id: int) -> String:
	match id:
		20:
			return "show_coordinates"
		21:
			return "show_move_numbers"
		23:
			return "show_candidates"
		24:
			return "show_ownership"
		26:
			return "show_hints"
		_:
			return ""


func _on_review_menu(id: int) -> void:
	match id:
		30:
			_run_review()
		31:
			if analysis != null:
				analysis.cancel_review()
			_review_follow = null
			_set_review_status("Review cancelled")
		32:
			_open_settings()


## The settings dialog is built once, on first use, so the app starts fast and a
## broken dialog cannot stop the board from loading.
func _open_settings() -> void:
	if settings_dialog == null:
		var dialog: AcceptDialog = AcceptDialog.new()
		dialog.name = "SettingsDialog"
		dialog.title = "Settings"
		var script: GDScript = load("res://scripts/ui/settings_dialog.gd")
		if script == null:
			_set_review_status("settings dialog script missing")
			return
		dialog.set_script(script)
		add_child(dialog)
		settings_dialog = dialog
	settings_dialog.open_fitted(get_viewport().get_visible_rect().size.y)


## Keyboard navigation ------------------------------------------------------------

## Keyboard navigation. This runs in _input rather than _unhandled_input on
## purpose: with nothing focused, Godot uses the arrow keys to move UI focus,
## which drops focus into the comment box and then every later key press is
## swallowed by the text edit. Handling them here keeps Left/Right/Up/Down,
## Home/End, P, U and Delete working as game navigation. Keys that would be
## text input are left alone while a text field has focus, so typing a comment
## still works normally.
func _input(event: InputEvent) -> void:
	if event is not InputEventKey or not event.pressed or event.echo:
		return
	var key: InputEventKey = event as InputEventKey
	if key.ctrl_pressed:
		if key.keycode == KEY_O:
			_popup_open()
			accept_event()
		elif key.keycode == KEY_S:
			_popup_save()
			accept_event()
		return
	if _typing_in_text_field():
		return
	match key.keycode:
		KEY_LEFT:
			flow.undo_step()
			_refresh()
			accept_event()
		KEY_RIGHT:
			flow.redo_step()
			_refresh()
			accept_event()
		KEY_UP:
			flow.previous_variation()
			_refresh()
			accept_event()
		KEY_DOWN:
			flow.next_variation()
			_refresh()
			accept_event()
		KEY_HOME:
			flow.tree.go_to_root()
			_refresh()
			accept_event()
		KEY_END:
			flow.tree.go_to_main_line_end()
			_refresh()
			accept_event()
		KEY_C:
			var settings_node: Node = get_node_or_null("/root/Settings")
			if settings_node != null:
				_set_view_setting("show_candidates", not bool(settings_node.show_candidates))
			accept_event()
		KEY_P:
			if mode == "review":
				var added: GameNode = flow.add_pass_variation()
				if added == null:
					push_warning("Could not add a pass variation: " + flow.last_error)
				_refresh()
			else:
				_on_pass()
			accept_event()
		KEY_U:
			_on_undo()
			accept_event()
		KEY_DELETE, KEY_BACKSPACE:
			# Only review mode deletes nodes; in play mode undo is the way back.
			if mode == "review":
				if not flow.remove_current():
					push_warning("Could not delete: " + flow.last_error)
				_refresh()
			accept_event()


## True when the user is typing, so single-letter shortcuts must not fire.
func _typing_in_text_field() -> bool:
	var focused: Control = get_viewport().gui_get_focus_owner()
	return focused is TextEdit or focused is LineEdit


## SGF I/O ------------------------------------------------------------

func _on_open_path(path: String) -> void:
	var parsed: Dictionary = SGF.parse_file(path)
	if not bool(parsed["ok"]):
		push_warning("Could not read %s: %s" % [path, str(parsed["error"])])
		_refresh()
		return
	_forget_review()
	# An opened game is for reading, not for the engine to play on.
	ai_side = 0
	# Set before adopt_tree: adopting a finished game reports "game over",
	# which would otherwise auto-save a duplicate of the file just opened.
	_game_from_file = true
	reset_autosave()
	flow.adopt_tree(parsed["tree"])
	_sync_engine_board_size()
	_refresh()
	_request_live_analysis()


## Files dragged onto the window. Only SGF files are opened; the first one wins
## so a multi-file drop does not silently replace the game that was just loaded.
func _on_files_dropped(files: PackedStringArray) -> void:
	for path in files:
		if path.to_lower().ends_with(".sgf"):
			_on_open_path(path)
			return
	if files.is_empty():
		return
	push_warning("Only .sgf files can be opened; ignored %s" % str(files[0]))


func _on_save_path(path: String) -> void:
	if not path.ends_with(".sgf"):
		path += ".sgf"
	var text: String = SGF.serialise(flow.tree)
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("Could not write %s: %s" % [path, str(FileAccess.get_open_error())])
		return
	file.store_string(text)
	file.close()
	print("Saved %s" % path)


## Writes to user://games with a timestamped name, so nothing is ever lost.
## PLAN 6.1: "Auto-save every finished or abandoned game to
## user://games/YYYY-MM-DD_HHMM.sgf". One file per game: the name is stamped the
## first time this game is written and reused afterwards, so playing a game does
## not leave a trail of files. A stamp that is already taken (two games in the
## same minute) gets a numeric suffix rather than overwriting the earlier one.
var _autosave_path: String = ""


## Where played games are saved. The real app uses user://games; a scripted
## run (the tests, which instantiate main.tscn themselves rather than running it
## as the main scene) gets its own folder so it never mixes test games in with
## the user's.
var save_dir: String = SAVE_DIR
const TEST_SAVE_DIR: String = "user://test_games"
## True while the shown game was opened from a file rather than played here.
## Such a game is not auto-saved: it already has a file, and saving it again
## would only make a duplicate every time a finished game is opened.
var _game_from_file: bool = false


## Call when a game is replaced or loaded so the next save starts a new file.
func reset_autosave() -> void:
	_autosave_path = ""


## A file name a person can scan in Finder: date, time, board size and the
## opponent, e.g. "2026-11-14 13-32 13x13 vs KataGo 5k". No colons: Finder
## shows them as slashes.
func _autosave_stem() -> String:
	var t: Dictionary = Time.get_datetime_dict_from_system()
	var stem: String = "%04d-%02d-%02d %02d-%02d %dx%d" % [int(t["year"]), int(t["month"]),
		int(t["day"]), int(t["hour"]), int(t["minute"]), flow.tree.size, flow.tree.size]
	if ai_side != 0:
		stem += " vs " + _opponent_name()
	return stem


## "KataGo 5k" for the human-like profile rank_5k, "KataGo" otherwise.
func _opponent_name() -> String:
	var profile: String = ai.profile if ai != null else ""
	if profile.begins_with("rank_"):
		return "KataGo " + profile.substr(5)
	if profile.begins_with("preaz_"):
		return "KataGo %s (pre-AI)" % profile.substr(6)
	return "KataGo"


func autosave(force: bool = false) -> String:
	if _game_from_file and not force:
		return ""  # an opened game already has its file; Save writes it explicitly
	if _autosave_path == "":
		DirAccess.make_dir_recursive_absolute(save_dir)
		var stem: String = _autosave_stem()
		_autosave_path = save_dir.path_join("%s.sgf" % stem)
		if FileAccess.file_exists(_autosave_path):
			var n: int = 2
			while FileAccess.file_exists(save_dir.path_join("%s-%d.sgf" % [stem, n])):
				n += 1
			_autosave_path = save_dir.path_join("%s-%d.sgf" % [stem, n])
	var file: FileAccess = FileAccess.open(_autosave_path, FileAccess.WRITE)
	if file == null:
		push_warning("Could not write %s" % _autosave_path)
		return ""
	file.store_string(SGF.serialise(flow.tree))
	file.close()
	print("Auto-saved %s" % _autosave_path)
	return _autosave_path


## Quitting mid-game is the "abandoned game" case (PLAN 6.1). The tree only needs
## saving when something was actually played.
func _save_if_played() -> void:
	if flow.tree.node_count() > 1 or not flow.tree.result.is_empty():
		autosave()


func _notification(what: int) -> void:
	# Only the window-close notification; the tree is already gone by the time
	# nodes are predeleted, so saving there would be unsafe. File > Quit calls
	# _save_if_played() directly instead.
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if flow != null and mode == "play":
			_save_if_played()
	# Inside the editor the system's appearance-change callback never arrives,
	# so the appearance is re-checked whenever the app comes back into focus.
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN and is_node_ready():
		_apply_appearance()


## Settings ------------------------------------------------------------

## Pushes the current settings into the views. Called once at start-up and again
## whenever the settings dialog saves (PLAN 6.3 board colours, 6.2 thresholds).
func _apply_settings() -> void:
	var settings: Node = get_node_or_null("/root/Settings")
	if settings == null:
		return
	if board_view != null:
		if settings.has_method("get_color"):
			board_view.background_color = settings.get_color("board_color")
			board_view.line_color = settings.get_color("line_color")
		board_view.queue_redraw()
	if review != null:
		review.inaccuracy_at = float(settings.inaccuracy_at)
		review.mistake_at = float(settings.mistake_at)
		review.blunder_at = float(settings.blunder_at)
		if graph_view != null:
			graph_view.refresh_data()
		_show_mistakes()
	if board_view != null:
		board_view.show_candidates = bool(settings.show_candidates)
		board_view.show_ownership = bool(settings.show_ownership)
		board_view.show_coordinates = bool(settings.show_coordinates)
		board_view.show_move_numbers = bool(settings.show_move_numbers)
		_sync_view_checks()
		_update_panel_mode()
		_refresh()


## Keeps the View menu ticks in step with the settings after a dialog save.
func _sync_view_checks() -> void:
	if view_menu == null:
		return
	var settings: Node = get_node_or_null("/root/Settings")
	if settings == null:
		return
	if candidates_toggle != null:
		candidates_toggle.set_pressed_no_signal(bool(settings.show_candidates))
	for pair in [[20, "show_coordinates"], [21, "show_move_numbers"],
			[23, "show_candidates"], [24, "show_ownership"], [26, "show_hints"]]:
		var id: int = int(pair[0])
		var index: int = view_menu.get_item_index(id)
		if index < 0:
			continue
		view_menu.set_item_checked(index, bool(settings.get(String(pair[1]))))


## Analysis output may only appear during a game when the user asked for it
## (PLAN 6.1: "No analysis output is visible during a game unless the user ticks
## show hints"). Review mode always shows it, and a finished game shows the
## engine estimate the two-pass rule asks for.
func _hints_visible() -> bool:
	if mode == "review" or flow.over:
		return true
	var settings: Node = get_node_or_null("/root/Settings")
	if settings == null:
		return false
	return bool(settings.show_hints)



## Status line ------------------------------------------------------------
func _refresh() -> void:
	if board_view == null:
		return
	board_view.show_position(flow.tree, flow.current())
	var node: GameNode = flow.current()
	# PLAN 6.1: during a game the overlays and the read-out stay hidden unless
	# the user ticked "show hints". show_position() loads whatever analysis the
	# node happens to hold (the opponent's own move request fills it), so the
	# gating has to happen here too, not only when a result arrives.
	if not _hints_visible():
		board_view.set_analysis({})
		_clear_analysis_readout()
	var turn: int = flow.tree.turn_at(node)
	status_label.text = "%d x %d board  ·  komi %s  ·  %s rules" % [flow.tree.size,
		flow.tree.size, str(flow.tree.komi), flow.tree.rules.capitalize()]
	# move_number() counts moves already played; the label shows the number of
	# the move about to be played, which is what a player expects to see.
	if flow.over and node == flow.tree.main_line().back():
		turn_label.text = "Game over after %d moves" % flow.move_number()
	else:
		turn_label.text = "Move %d  ·  %s to play" % [flow.move_number() + 1,
			"Black" if turn == Board.Stone.BLACK else "White"]
	_update_panel_mode()
	# The engine's read-out follows the shown position (or says why it is off).
	if _hints_visible():
		_show_analysis(node)
	else:
		_clear_analysis_readout()

	var board: Board = flow.tree.board_at(node)
	captures_label.text = "Captured by Black: %d   ·   by White: %d" \
		% [int(board.captures[Board.Stone.BLACK]), int(board.captures[Board.Stone.WHITE])]
	# PLAN 6.2 info panel: player names. SGF PB/PW are optional, so fall back to
	# the colour, and mark the side the engine plays when there is an opponent.
	if players_label != null:
		var black_name: String = flow.tree.black_name
		var white_name: String = flow.tree.white_name
		if black_name == "":
			black_name = "Black"
		if white_name == "":
			white_name = "White"
		if ai_side == Board.Stone.BLACK:
			black_name += " (engine)"
		elif ai_side == Board.Stone.WHITE:
			white_name += " (engine)"
		players_label.text = "●  Black: %s\n○  White: %s" % [black_name, white_name]
	result_label.text = "Result: " + flow.result_text if flow.result_text != "" else ""
	result_label.visible = result_label.text != ""

	# The move tree and the comment box follow the shown position.
	if tree_view != null:
		tree_view.show_position(flow.tree, node)
		tree_view.scroll_to_current()
	if graph_view != null:
		graph_view.visible = review != null
		if review != null:
			graph_view.show_position(flow.tree, review, flow.tree.move_count_to(node))
	if comment_edit != null:
		_setting_comment = true
		comment_edit.text = node.comment
		_setting_comment = false
