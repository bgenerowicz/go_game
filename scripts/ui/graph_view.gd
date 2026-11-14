class_name GraphView
extends Control

## Win-rate / score-lead graph (PLAN 6.2). x = move number, the win-rate line is
## Black's percentage on the left scale (0..100, 50% midline), the score lead is
## drawn on its own scale. A vertical cursor marks the current move, dots mark
## mistakes, and progress is shown while a review is still running.

signal turn_clicked(turn: int)

const MARGIN_LEFT: float = 52.0  # room for "W 100%"
const MARGIN_RIGHT: float = 34.0
const MARGIN_TOP: float = 28.0  # room for the legend and progress note
const MARGIN_BOTTOM: float = 18.0

var tree: GameTree = null
var review: Review = null
var current_turn: int = 0
var show_score: bool = true

var _winrate_line: Array = []
var _score_line: Array = []
var _mistake_by_turn: Dictionary = {}

var _line_color: Color = Color(0.15, 0.45, 0.85)
var _score_color: Color = Color(0.75, 0.45, 0.15)
var _grid_color: Color = Color(0.55, 0.5, 0.42)
var _cursor_color: Color = Color(0.15, 0.15, 0.15)
var _text_color: Color = Color(0.2, 0.2, 0.2)
var _background: Color = Color(0.98, 0.96, 0.92)


## Follows the system light/dark appearance.
func set_dark(dark: bool) -> void:
	if dark:
		_background = Color(0.155, 0.16, 0.175)
		_grid_color = Color(0.34, 0.35, 0.38)
		_text_color = Color(0.72, 0.73, 0.76)
		_cursor_color = Color(0.9, 0.9, 0.92)
		_line_color = Color(0.4, 0.66, 1.0)
		_score_color = Color(0.95, 0.62, 0.3)
	else:
		_background = Color(0.98, 0.96, 0.92)
		_grid_color = Color(0.55, 0.5, 0.42)
		_text_color = Color(0.2, 0.2, 0.2)
		_cursor_color = Color(0.15, 0.15, 0.15)
		_line_color = Color(0.15, 0.45, 0.85)
		_score_color = Color(0.75, 0.45, 0.15)
	queue_redraw()


func show_position(p_tree: GameTree, p_review: Review, p_turn: int) -> void:
	tree = p_tree
	review = p_review
	current_turn = p_turn
	refresh_data()


## Call after analysis arrives: the lines and mistake dots change.
func refresh_data() -> void:
	_winrate_line = []
	_score_line = []
	_mistake_by_turn = {}
	if tree != null and review != null:
		_winrate_line = review.winrate_line()
		_score_line = review.score_lead_line()
		for entry in review.turns():
			if String(entry["kind"]) != Review.KIND_NONE:
				_mistake_by_turn[int(entry["turn"])] = entry
	queue_redraw()


func _draw() -> void:
	var area: Rect2 = Rect2(Vector2.ZERO, size)
	draw_rect(area, _background)
	var plot: Rect2 = Rect2(
		Vector2(MARGIN_LEFT, MARGIN_TOP),
		Vector2(maxf(10.0, size.x - MARGIN_LEFT - MARGIN_RIGHT),
			maxf(10.0, size.y - MARGIN_TOP - MARGIN_BOTTOM))
	)
	var turns: int = _turn_count()
	if turns <= 0:
		_draw_note("no game loaded", plot)
		return

	# Horizontal grid: 0 / 25 / 50 / 75 / 100 percent.
	for i in 5:
		var fraction: float = i / 4.0
		var y: float = plot.end.y - fraction * plot.size.y
		var midline: bool = i == 2
		draw_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y),
			_grid_color, 1.5 if midline else 0.5)
		draw_string(_font(), Vector2(4.0, y + 4.0), _winrate_label(fraction),
			HORIZONTAL_ALIGNMENT_LEFT, 0, 10, _line_color)

	# Vertical grid, plus a label for the last move.
	var step: int = maxi(1, int(ceil(turns / 12.0)))
	var move: int = 0
	while move <= turns:
		var x: float = _x_for(move, plot, turns)
		draw_line(Vector2(x, plot.position.y), Vector2(x, plot.end.y), _grid_color, 0.5)
		move += step
	draw_string(_font(), Vector2(plot.end.x - 24.0, plot.end.y + 14.0), str(turns),
		HORIZONTAL_ALIGNMENT_LEFT, 0, 10, _text_color)

	_draw_series(_winrate_line, plot, turns, 0.0, 1.0, _line_color, 2.0)
	if show_score:
		var bounds: Vector2 = _score_bounds()
		_draw_series(_score_line, plot, turns, bounds.x, bounds.y, _score_color, 1.2)
		_draw_score_axis(plot, bounds)
	_draw_legend(plot)

	# Mistake dots, sized and coloured by severity.
	for turn_number in _mistake_by_turn:
		var entry: Dictionary = _mistake_by_turn[turn_number]
		var point: Vector2 = _point_for(int(turn_number), _winrate_line, plot, turns)
		if point == Vector2.INF:
			continue
		var kind: String = String(entry["kind"])
		var radius: float = 3.0
		if kind == Review.KIND_MISTAKE:
			radius = 4.5
		elif kind == Review.KIND_BLUNDER:
			radius = 6.0
		draw_circle(point, radius + 1.0, _background)
		draw_circle(point, radius, _mistake_color(kind))

	# Cursor at the current move.
	if current_turn >= 0 and current_turn <= turns:
		var cx: float = _x_for(current_turn, plot, turns)
		draw_line(Vector2(cx, plot.position.y), Vector2(cx, plot.end.y), _cursor_color, 1.2)
		var top: Vector2 = _point_for(current_turn, _winrate_line, plot, turns)
		if top != Vector2.INF:
			draw_circle(top, 3.5, _cursor_color)

	# Progress while a review is running.
	var done: int = review.analysed_turns() if review != null else 0
	var total: int = review.main_line_turns() if review != null else 0
	if total > 0 and done < total:
		_draw_note("analysing %d / %d turns" % [done, total], plot)
	elif total > 0:
		_draw_note("%d turns analysed" % done, plot)


func _draw_series(values: Array, plot: Rect2, turns: int,
		low: float, high: float, color: Color, width: float) -> void:
	if high - low <= 0.0:
		high = low + 1.0
	var previous: Vector2 = Vector2.INF
	for turn_number in range(0, turns + 1):
		var value: Variant = values[turn_number] if turn_number < values.size() else null
		if value == null:
			previous = Vector2.INF
			continue
		var fraction: float = (float(value) - low) / (high - low)
		fraction = clampf(fraction, 0.0, 1.0)
		var point := Vector2(_x_for(turn_number, plot, turns),
			plot.end.y - fraction * plot.size.y)
		if previous != Vector2.INF:
			draw_line(previous, point, color, width)
		previous = point


## The point of a win-rate value, or Vector2.INF when that turn is unanalysed.
func _point_for(turn_number: int, values: Array, plot: Rect2, turns: int) -> Vector2:
	var value: Variant = values[turn_number] if turn_number < values.size() else null
	if value == null:
		return Vector2.INF
	var fraction: float = clampf(float(value), 0.0, 1.0)
	return Vector2(_x_for(turn_number, plot, turns), plot.end.y - fraction * plot.size.y)


func _x_for(turn_number: int, plot: Rect2, turns: int) -> float:
	if turns <= 0:
		return plot.position.x
	return plot.position.x + (float(turn_number) / float(turns)) * plot.size.x


func _turn_count() -> int:
	if tree == null:
		return 0
	return maxi(0, tree.main_line().size() - 1)


## The win-rate axis read from both players' sides, so the middle line is an
## even game on this axis as it is 0 on the score axis: "B 100%" at the top,
## "even" in the middle, "W 100%" at the bottom.
static func _winrate_label(black_fraction: float) -> String:
	if is_equal_approx(black_fraction, 0.5):
		return "even"
	if black_fraction > 0.5:
		return "B %d%%" % int(round(black_fraction * 100.0))
	return "W %d%%" % int(round((1.0 - black_fraction) * 100.0))


## The score-lead scale, symmetric around 0 so that 0 (an even game) sits on
## the same middle line as 50 % on the win-rate axis. The half-range is the
## largest lead in the game with a little headroom, rounded up to a tidy
## number (2, 5, 10, 20, 50 ...).
func _score_bounds() -> Vector2:
	var largest: float = 0.0
	for value in _score_line:
		if value == null:
			continue
		largest = maxf(largest, absf(float(value)))
	var limit: float = _nice_ceiling(maxf(2.0, largest * 1.1))
	return Vector2(-limit, limit)


## The smallest of 1, 2, 5 x 10^n that is at least value.
static func _nice_ceiling(value: float) -> float:
	var magnitude: float = pow(10.0, floor(log(value) / log(10.0)))
	for step in [1.0, 2.0, 5.0, 10.0]:
		if step * magnitude >= value - 0.0001:
			return step * magnitude
	return 10.0 * magnitude


## Score-lead labels on the right edge, in the orange of the score line: the
## top and bottom of its scale, and 0 (an even game) when it is in range.
func _draw_score_axis(plot: Rect2, bounds: Vector2) -> void:
	var span: float = bounds.y - bounds.x
	if span <= 0.0:
		return
	# Same five heights as the win-rate grid lines, so each label sits on one.
	var ticks: Array = []
	for i in 5:
		ticks.append(bounds.x + span * float(i) / 4.0)
	for value in ticks:
		var y: float = plot.end.y - (float(value) - bounds.x) / span * plot.size.y
		var text: String = "0"
		if absf(value) >= 0.05:
			text = "%+.0f" % value if absf(value - round(value)) < 0.01 else "%+.1f" % value
		draw_string(_font(), Vector2(plot.end.x + 4.0, y + 4.0), text,
			HORIZONTAL_ALIGNMENT_LEFT, 0, 10, _score_color)


## What the two lines mean, plus the mistake dot colours, in the top-right
## corner of the plot.
func _draw_legend(plot: Rect2) -> void:
	var entries: Array = [
		[_line_color, "line", "Win chance (left axis)"],
	]
	if show_score:
		entries.append([_score_color, "line", "Score lead in points (right axis)"])
	entries.append([_mistake_color(Review.KIND_INACCURACY), "dot", "inaccuracy"])
	entries.append([_mistake_color(Review.KIND_MISTAKE), "dot", "mistake"])
	entries.append([_mistake_color(Review.KIND_BLUNDER), "dot", "blunder"])
	var font: Font = _font()
	var size_px: int = 11
	var swatch: float = 16.0
	var gap: float = 14.0
	var width: float = 0.0
	for entry in entries:
		width += swatch + 4.0 + font.get_string_size(String(entry[2]),
			HORIZONTAL_ALIGNMENT_LEFT, -1, size_px).x + gap
	var x: float = plot.end.x - width
	var y: float = 4.0  # in the top margin, above the plot
	for entry in entries:
		var color: Color = entry[0]
		var mid_y: float = y + 7.0
		if String(entry[1]) == "line":
			draw_line(Vector2(x, mid_y), Vector2(x + swatch, mid_y), color, 2.5)
		else:
			draw_circle(Vector2(x + swatch * 0.5, mid_y), 4.0, color)
		x += swatch + 4.0
		draw_string(font, Vector2(x, mid_y + 4.0), String(entry[2]),
			HORIZONTAL_ALIGNMENT_LEFT, -1, size_px, _text_color)
		x += font.get_string_size(String(entry[2]), HORIZONTAL_ALIGNMENT_LEFT, -1, size_px).x + gap


func _mistake_color(kind: String) -> Color:
	match kind:
		Review.KIND_BLUNDER:
			return Color(0.85, 0.15, 0.12)
		Review.KIND_MISTAKE:
			return Color(0.92, 0.5, 0.1)
		_:
			return Color(0.9, 0.8, 0.2)


func _draw_note(text: String, plot: Rect2) -> void:
	draw_string(_font(), Vector2(plot.position.x, 15.0), text,
		HORIZONTAL_ALIGNMENT_LEFT, 0, 11, _text_color)


func _font() -> Font:
	return ThemeDB.fallback_font


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		var turn_number: int = turn_at_position(event.position)
		if turn_number >= 0:
			accept_event()
			turn_clicked.emit(turn_number)


## Maps a click to the nearest turn, or -1 when outside the plot.
func turn_at_position(click: Vector2) -> int:
	var turns: int = _turn_count()
	if turns <= 0:
		return -1
	var plot_width: float = size.x - MARGIN_LEFT - MARGIN_RIGHT
	if plot_width <= 0.0:
		return -1
	if click.x < MARGIN_LEFT - 6.0 or click.x > size.x - MARGIN_RIGHT + 6.0:
		return -1
	var fraction: float = (click.x - MARGIN_LEFT) / plot_width
	return clampi(int(round(fraction * turns)), 0, turns)

