extends AcceptDialog

## New-game dialog (PLAN 6.1): board size, human colour, opponent rank and style,
## handicap, komi and rules. Built in code so it needs no scene file.
## The caller reads params() after confirmed fires.

## Rule names KataGo 1.18.1 actually accepts (checked against the bundled
## binary); anything else makes the whole analysis query fail, so the list is
## deliberately closed. Japanese is first because the PLAN makes it the default.
const RULES: Array[String] = [
	"japanese", "chinese", "korean", "aga", "new-zealand", "ing", "tromp-taylor",
]

const SIZES: Array[int] = [9, 13, 19]

## Width the explanatory note wraps at (see _build).
const NOTE_WIDTH: float = 460.0

## PLAN 6.1 "style (modern/pre-AI)": the two humanSLProfile families, without the
## rank suffix, which the rank box supplies.
const STYLES: Array[String] = ["rank", "preaz"]
const STYLE_LABELS: Array[String] = ["Modern (post-AlphaGo)", "Pre-AI style"]

## Ranks offered to both styles. KataGo spells them the same way in both
## families, so the profile name is simply "<style>_<rank>".
## "beginner" is below KataGo's lowest rank; see AiPlayer.BEGINNER.
const RANKS: Array[String] = [
	"beginner", "20k", "15k", "10k", "8k", "5k", "2k", "1k", "1d", "2d", "5d", "8d", "9d",
]

## PLAN 6.1 "human colour (black/white/random)".
const COLOURS: Array[String] = ["black", "white", "random"]
const COLOUR_LABELS: Array[String] = ["You play Black", "You play White", "Random"]

var size_box: OptionButton
var komi_box: LineEdit
var rules_box: OptionButton
var handicap_box: SpinBox
var engine_box: CheckBox
var style_box: OptionButton
var rank_box: OptionButton
var colour_box: OptionButton
var note_label: Label

## Set once the user types a komi of their own, so turning on a handicap does not
## overwrite a deliberate choice.
var _komi_touched: bool = false


func _ready() -> void:
	title = "New game"
	ok_button_text = "Start game"
	_build()
	get_ok_button().pressed.connect(_on_start)


func _build() -> void:
	var column: VBoxContainer = VBoxContainer.new()
	column.name = "Column"
	column.add_theme_constant_override("separation", 10)
	add_child(column)

	var grid: GridContainer = GridContainer.new()
	grid.name = "Grid"
	grid.columns = 2
	column.add_child(grid)

	grid.add_child(_label("Board size"))
	size_box = OptionButton.new()
	size_box.name = "Size"
	for size in SIZES:
		size_box.add_item(str(size))
	size_box.item_selected.connect(func(_i: int) -> void: _apply_standard_komi())
	grid.add_child(size_box)

	grid.add_child(_label("Komi"))
	komi_box = LineEdit.new()
	komi_box.name = "Komi"
	komi_box.text = "6.5"
	komi_box.text_changed.connect(func(_t: String) -> void: _komi_touched = true)
	grid.add_child(komi_box)

	grid.add_child(_label("Rules"))
	rules_box = OptionButton.new()
	rules_box.name = "Rules"
	for rules in RULES:
		rules_box.add_item(rules.capitalize())
	rules_box.item_selected.connect(func(_i: int) -> void: _apply_standard_komi())
	grid.add_child(rules_box)

	grid.add_child(_label("Handicap (Black stones)"))
	handicap_box = SpinBox.new()
	handicap_box.name = "Handicap"
	handicap_box.min_value = 0
	handicap_box.max_value = 9
	handicap_box.step = 1
	# PLAN 6.1: komi drops to 0.5 for handicap games unless set by hand.
	handicap_box.value_changed.connect(_on_handicap)
	grid.add_child(handicap_box)
	grid.add_child(_label("Engine opponent"))
	engine_box = CheckBox.new()
	engine_box.name = "EngineOpponent"
	engine_box.text = "Play against the engine"
	engine_box.toggled.connect(func(_on: bool) -> void: _update_note())
	grid.add_child(engine_box)

	grid.add_child(_label("Opponent style"))
	style_box = OptionButton.new()
	style_box.name = "Style"
	for label in STYLE_LABELS:
		style_box.add_item(label)
	style_box.item_selected.connect(func(_i: int) -> void: _update_note())
	grid.add_child(style_box)

	grid.add_child(_label("Opponent rank"))
	rank_box = OptionButton.new()
	rank_box.name = "Rank"
	for rank in RANKS:
		rank_box.add_item("Beginner (below 20k)" if rank == "beginner" else rank)
	rank_box.selected = RANKS.find("10k")
	grid.add_child(rank_box)

	grid.add_child(_label("Your colour"))
	colour_box = OptionButton.new()
	colour_box.name = "HumanColour"
	for label in COLOUR_LABELS:
		colour_box.add_item(label)
	grid.add_child(colour_box)

	note_label = Label.new()
	note_label.name = "Note"
	note_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# A wrapping label with no width yet wraps one word per line, so on the very
	# first popup its minimum height (and the dialog's) came out about 2000 px
	# tall and pushed "Start game" off the screen. A fixed width makes the first
	# layout the same as every later one.
	note_label.custom_minimum_size = Vector2(NOTE_WIDTH, 0)
	column.add_child(note_label)


func _label(text: String) -> Label:
	var label: Label = Label.new()
	label.name = text
	label.text = text
	return label


## Pre-fills the dialog from the current game so "New game" starts from sensible
## defaults, and from the saved settings for the opponent.
func open_with(p_size: int, p_komi: float, p_rules: String, p_handicap: int,
		p_profile: String, p_human_colour: String) -> void:
	size_box.selected = maxi(0, SIZES.find(p_size))
	var rules_index: int = RULES.find(p_rules)
	rules_box.selected = rules_index if rules_index >= 0 else 0
	handicap_box.set_value_no_signal(clampi(p_handicap, 0, 9))
	# Start from the standard komi for these settings, not the last game's: a
	# komi typed once (say 7.5 on 9x9) used to stick to every later game.
	# p_komi is kept in the signature for callers but no longer copied.
	_komi_touched = false
	_apply_standard_komi()
	# A profile name such as "preaz_5k" splits into style plus rank.
	engine_box.button_pressed = p_profile != ""
	var style: String = "rank"
	var rank: String = "10k"
	if p_profile.contains("_"):
		style = p_profile.get_slice("_", 0)
		rank = p_profile.get_slice("_", 1)
	var style_index: int = STYLES.find(style)
	style_box.selected = style_index if style_index >= 0 else 0
	var rank_index: int = RANKS.find(rank)
	rank_box.selected = rank_index if rank_index >= 0 else 0
	var colour_index: int = COLOURS.find(p_human_colour)
	colour_box.selected = colour_index if colour_index >= 0 else COLOURS.find("random")
	_update_note()
	# Fit the dialog to its content each time: the note changes length with the
	# options, and a size left over from a longer note would leave a gap.
	reset_size()
	popup_centered(Vector2i(520, 0))


func _on_start() -> void:
	_update_note()


func _on_handicap(_value: float) -> void:
	_apply_standard_komi()


## Standard komi for a board size, rule set and handicap:
## - handicap games: 0.5 (the handicap stones replace komi)
## - territory scoring (Japanese, Korean): 6.5
## - area scoring (Chinese, AGA, New Zealand, Tromp-Taylor, Ing): 7.5
## The same on 9x9, 13x13 and 19x19: KataGo's fair komi is about 7 area points
## on all three, and these are the values servers use. The size is a parameter
## so a size-specific value has one place to go.
static func standard_komi(_size: int, rules: String, handicap: int) -> float:
	if handicap > 0:
		return 0.5
	match rules:
		"japanese", "korean":
			return 6.5
		_:
			return 7.5


## Fills in the standard komi for the chosen size, rules and handicap, unless
## the user has typed a komi of their own in this dialog.
func _apply_standard_komi() -> void:
	if not _komi_touched:
		var rules: String = RULES[rules_box.selected] if rules_box.selected >= 0 else RULES[0]
		var size: int = SIZES[size_box.selected] if size_box.selected >= 0 else 19
		komi_box.text = str(standard_komi(size, rules, int(handicap_box.value)))
	_update_note()


## The komi field is free text, so validate it here rather than deep in the flow.
func komi_value() -> float:
	var text: String = komi_box.text.strip_edges()
	if not text.is_valid_float():
		return 6.5
	return text.to_float()


## The chosen profile name, or "" when the user wants two humans.
func profile() -> String:
	if not engine_box.button_pressed:
		return ""
	var style: String = STYLES[style_box.selected] if style_box.selected >= 0 else STYLES[0]
	var rank: String = RANKS[rank_box.selected] if rank_box.selected >= 0 else RANKS[0]
	return "%s_%s" % [style, rank]


func params() -> Dictionary:
	return {
		"size": SIZES[size_box.selected] if size_box.selected >= 0 else 19,
		"komi": komi_value(),
		"rules": RULES[rules_box.selected] if rules_box.selected >= 0 else "japanese",
		"handicap": int(handicap_box.value),
		"profile": profile(),
		"human_colour": COLOURS[colour_box.selected] if colour_box.selected >= 0 else "random",
	}

## The notes the PLAN asks for: the 9/13 accuracy caveat, the handicap komi and
## the reminder that an engine opponent has to be started.
func _update_note() -> void:
	if note_label == null:
		return
	var p: Dictionary = params()
	var komi: float = float(p["komi"])
	var handicap: int = int(p["handicap"])
	var size: int = int(p["size"])
	var lines: Array[String] = []
	if size != 19:
		lines.append("On %dx%d the opponent's rank is approximate (the human-like "
			% [size, size] + "model is calibrated on 19x19); adjust it if games feel too easy or hard.")
	if not _komi_touched:
		lines.append("Komi is set to the standard for these rules: 6.5 for Japanese "
			+ "or Korean scoring, 7.5 for area scoring, 0.5 with handicap stones.")
	note_label.text = "\n".join(lines)

