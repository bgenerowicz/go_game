class_name WinRateBar
extends Control

## A horizontal win-rate bar for the info panel (PLAN 6.2): black's share from
## the left, white's from the right, a midline at 50 %, and the score lead as
## text. Hidden when there is no analysis to show.

var winrate_black: float = -1.0  # 0..1, negative means "no data"
var score_lead: float = 0.0
var visits: int = 0
var bar_color_black: Color = Color(0.12, 0.12, 0.12)
var bar_color_white: Color = Color(0.92, 0.92, 0.92)
var midline_color: Color = Color(0.75, 0.35, 0.15)
var text_color: Color = Color(0.85, 0.85, 0.85)


func set_values(p_winrate_black: float, p_score_lead: float, p_visits: int) -> void:
	winrate_black = p_winrate_black
	score_lead = p_score_lead
	visits = p_visits
	queue_redraw()


func clear_values() -> void:
	set_values(-1.0, 0.0, 0)


func _draw() -> void:
	var width: float = size.x
	var height: float = size.y
	if width <= 4.0 or height <= 12.0:
		return
	var bar_height: float = maxf(10.0, height * 0.45)
	var bar_top: float = (height - bar_height) * 0.5
	if winrate_black < 0.0:
		draw_rect(Rect2(0, bar_top, width, bar_height), Color(0.3, 0.3, 0.3), true)
		_label("no analysis for this position", 0, height - 12)
		return
	var black_width: float = width * clampf(winrate_black, 0.0, 1.0)
	draw_rect(Rect2(0, bar_top, black_width, bar_height), bar_color_black, true)
	draw_rect(Rect2(black_width, bar_top, width - black_width, bar_height), bar_color_white, true)
	draw_line(Vector2(width * 0.5, bar_top - 3), Vector2(width * 0.5, bar_top + bar_height + 3),
		midline_color, 2.0)
	var lead: String = "Black %+.1f" % score_lead if score_lead >= 0.0 else "White +%.1f" % -score_lead
	_label("Black %.1f%%   %s   %d visits" % [winrate_black * 100.0, lead, visits], 0, 0)


func _label(text: String, x: float, y: float) -> void:
	var font: Font = ThemeDB.fallback_font
	if font == null:
		return
	draw_string(font, Vector2(x, y + 10), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, text_color)
