class_name TreeView
extends Control

## Move tree (PLAN 6.2): the main line runs horizontally, variations branch
## below it, the current node is highlighted and clicking a node jumps to it.
## It lives inside a ScrollContainer, so long games scroll in both directions.

signal node_clicked(node: GameNode)

const STEP_X: float = 34.0
const ROW_H: float = 34.0
const NODE_R: float = 11.0
const PAD: float = 12.0

var tree: GameTree = null
var current: GameNode = null

var _entries: Array = []
var _by_id: Dictionary = {}
var _lanes: int = 1
var _depths: int = 1

var _background: Color = Color(0.98, 0.96, 0.92)
var _line_color: Color = Color(0.45, 0.4, 0.32)
var _text_color: Color = Color(0.2, 0.2, 0.2)
var _light_text: Color = Color(0.9, 0.9, 0.9)
var _cursor_color: Color = Color(0.85, 0.45, 0.1)
var _comment_color: Color = Color(0.2, 0.45, 0.85)


func show_position(p_tree: GameTree, p_node: GameNode) -> void:
	tree = p_tree
	current = p_node
	_layout()
	queue_redraw()


## Layout --------------------------------------------------------------

func _layout() -> void:
	_entries = []
	_by_id = {}
	_lanes = 1
	_depths = 1
	if tree != null:
		_place(tree.root, 0, 0)
	# The ScrollContainer reads this to size its scrollbars.
	custom_minimum_size = Vector2(
		PAD * 2.0 + float(_depths) * STEP_X,
		PAD * 2.0 + float(_lanes) * ROW_H)
	queue_redraw()


## Places one node. The first child continues its parent's row (that is what
## makes the main line horizontal); later children open a new row underneath.
func _place(node: GameNode, depth: int, lane: int) -> void:
	var entry: Dictionary = {
		"node": node,
		"x": PAD + float(depth) * STEP_X,
		"y": PAD + float(lane) * ROW_H,
	}
	_entries.append(entry)
	_by_id[node.get_instance_id()] = entry
	_depths = maxi(_depths, depth + 1)
	_lanes = maxi(_lanes, lane + 1)
	var first: bool = true
	for child in node.children:
		var child_lane: int = lane
		if not first:
			child_lane = _lanes
			_lanes += 1
		_place(child, depth + 1, child_lane)
		first = false


func entry_for(node: GameNode) -> Dictionary:
	return _by_id.get(node.get_instance_id(), {})


func node_at_position(click: Vector2) -> GameNode:
	# Reverse order so a node drawn on top wins when boxes overlap.
	for i in range(_entries.size() - 1, -1, -1):
		var entry: Dictionary = _entries[i]
		var box: Rect2 = Rect2(Vector2(float(entry["x"]) - NODE_R - 4.0,
			float(entry["y"]) - NODE_R - 4.0), Vector2(NODE_R * 2.0 + 8.0, NODE_R * 2.0 + 8.0))
		if box.has_point(click):
			return entry["node"]
	return null


func node_count() -> int:
	return _entries.size()


func lane_count() -> int:
	return _lanes


## Scrolls the enclosing ScrollContainer so the current node is on screen.
func scroll_to_current() -> void:
	if current == null:
		return
	var entry: Dictionary = entry_for(current)
	if entry.is_empty():
		return
	var scroller: ScrollContainer = get_parent() as ScrollContainer
	if scroller == null:
		return
	var horizontal: HScrollBar = scroller.get_h_scroll_bar()
	var vertical: VScrollBar = scroller.get_v_scroll_bar()
	var visible_w: float = scroller.size.x - vertical.custom_minimum_size.x
	var visible_h: float = scroller.size.y - horizontal.custom_minimum_size.y
	horizontal.value = clampf(float(entry["x"]) - visible_w * 0.5, 0.0, maxf(0.0, horizontal.max_value))
	vertical.value = clampf(float(entry["y"]) - visible_h * 0.5, 0.0, maxf(0.0, vertical.max_value))


## Drawing ------------------------------------------------------------

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), _background)
	if tree == null:
		return
	var font: Font = get_theme_default_font()
	var font_size: int = 10
	for entry in _entries:
		var node: GameNode = entry["node"]
		if node.is_root():
			continue
		var parent_entry: Dictionary = entry_for(node.parent)
		if parent_entry.is_empty():
			continue
		var from := Vector2(float(parent_entry["x"]) + NODE_R, float(parent_entry["y"]))
		var to := Vector2(float(entry["x"]) - NODE_R, float(entry["y"]))
		var mid_x: float = from.x + (to.x - from.x) * 0.5
		draw_line(from, Vector2(mid_x, from.y), _line_color, 1.0)
		draw_line(Vector2(mid_x, from.y), Vector2(mid_x, to.y), _line_color, 1.0)
		draw_line(Vector2(mid_x, to.y), to, _line_color, 1.0)
	for entry in _entries:
		_draw_node(entry, font, font_size)


func _draw_node(entry: Dictionary, font: Font, font_size: int) -> void:
	var node: GameNode = entry["node"]
	var center := Vector2(float(entry["x"]), float(entry["y"]))
	if node == current:
		draw_rect(Rect2(center - Vector2(NODE_R + 5.0, NODE_R + 5.0),
			Vector2(NODE_R * 2.0 + 10.0, NODE_R * 2.0 + 10.0)), _cursor_color, false, 2.0)
	if node.is_root():
		draw_rect(Rect2(center - Vector2(NODE_R * 0.7, NODE_R * 0.7),
			Vector2(NODE_R * 1.4, NODE_R * 1.4)), _line_color, true)
		return
	if node.is_pass():
		draw_circle(center, NODE_R, Color(0.75, 0.72, 0.66))
		_label(font, font_size, center, "P", _text_color)
		return
	var is_black: bool = node.move_color() == Board.Stone.BLACK
	draw_circle(center, NODE_R, Color(0.1, 0.1, 0.1) if is_black else Color(0.97, 0.96, 0.93))
	draw_circle(center, NODE_R, _line_color, false, 1.0)
	_label(font, font_size, center, str(node.depth), _light_text if is_black else _text_color)
	if node.comment != "":
		draw_circle(center + Vector2(NODE_R * 0.75, -NODE_R * 0.75), 3.0, _comment_color)


func _label(font: Font, font_size: int, center: Vector2, text: String, color: Color) -> void:
	var width: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string(font, center - Vector2(width * 0.5, -font_size * 0.35), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		var node: GameNode = node_at_position(event.position)
		if node != null:
			accept_event()
			node_clicked.emit(node)
