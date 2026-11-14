class_name WinRateBar
extends Control

## A horizontal win-rate bar for the info panel (PLAN 6.2): Black's share from
## the left, White's from the right, a midline at 50 %, each side's percentage
## printed inside its own segment, and the score lead plus visits underneath.

const BAR_HEIGHT: float = 22.0
const FONT_SIZE: int = 13

var winrate_black: float = -1.0  # 0..1, negative means "no data"
var score_lead: float = 0.0
var visits: int = 0
var bar_color_black: Color = Color(0.1, 0.1, 0.11)
var bar_color_white: Color = Color(0.93, 0.92, 0.89)
var midline_color: Color = Color(0.85, 0.45, 0.18)
var text_color: Color = Color(0.86, 0.86, 0.86)
var muted_color: Color = Color(0.6, 0.6, 0.62)


func _init() -> void:
	custom_minimum_size = Vector2(0, BAR_HEIGHT + 24.0)


func set_values(p_winrate_black: float, p_score_lead: float, p_visits: int) -> void:
	winrate_black = p_winrate_black
	score_lead = p_score_lead
	visits = p_visits
	queue_redraw()


func clear_values() -> void:
	set_values(-1.0, 0.0, 0)


func _draw() -> void:
	var width: float = size.x
	if width <= 4.0:
		return
	var bar: Rect2 = Rect2(0, 0, width, BAR_HEIGHT)
	var below_y: float = BAR_HEIGHT + 17.0
	if winrate_black < 0.0:
		draw_rect(bar, Color(0.32, 0.32, 0.34), true)
		_text("No analysis for this position yet", Vector2(0, below_y), muted_color)
		return
	var rate: float = clampf(winrate_black, 0.0, 1.0)
	var black_width: float = width * rate
	draw_rect(Rect2(0, 0, black_width, BAR_HEIGHT), bar_color_black, true)
	draw_rect(Rect2(black_width, 0, width - black_width, BAR_HEIGHT), bar_color_white, true)
	# An outline keeps a near-100 % black bar visible on the dark side panel.
	draw_rect(bar, Color(0.5, 0.5, 0.53), false, 1.0)
	draw_line(Vector2(width * 0.5, -2), Vector2(width * 0.5, BAR_HEIGHT + 2), midline_color, 2.0)
	# Each percentage sits inside its own segment when there is room for it.
	var text_y: float = BAR_HEIGHT * 0.5 + FONT_SIZE * 0.36
	var black_text: String = "B %.0f%%" % (rate * 100.0)
	var white_text: String = "W %.0f%%" % ((1.0 - rate) * 100.0)
	if black_width > _width_of(black_text) + 10.0:
		_text(black_text, Vector2(6, text_y), bar_color_white)
	var white_w: float = _width_of(white_text)
	if width - black_width > white_w + 10.0:
		_text(white_text, Vector2(width - white_w - 6, text_y), bar_color_black)
	var lead: String
	if absf(score_lead) < 0.05:
		lead = "Even game"
	elif score_lead > 0.0:
		lead = "Black leads by %.1f" % score_lead
	else:
		lead = "White leads by %.1f" % -score_lead
	_text(lead, Vector2(0, below_y), text_color)
	var visits_text: String = "%d visits" % visits
	_text(visits_text, Vector2(width - _width_of(visits_text), below_y), muted_color)


func _width_of(text: String) -> float:
	var font: Font = ThemeDB.fallback_font
	if font == null:
		return 0.0
	return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x


func _text(text: String, at: Vector2, color: Color) -> void:
	var font: Font = ThemeDB.fallback_font
	if font == null:
		return
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, color)
