class_name BoardView
extends Control

## Draws the board, stones and overlays, and turns clicks into board points.
## All geometry is derived from `size` inside _draw, so resizing just works.

signal point_clicked(point: Vector2i)
signal point_hovered(point: Vector2i)
## Mouse wheel navigation, forwarded to the game layer.
signal navigate_requested(direction: String)

var tree: GameTree = null
var node: GameNode = null

var show_coordinates: bool = true
var show_move_numbers: bool = false
var show_ghost: bool = true

## Hover state, drawn as a translucent ghost stone.
var ghost_point: Vector2i = Board.INVALID
var ghost_color: int = Board.Stone.EMPTY
## Optional overlays, filled in by later milestones.
var ownership: Array = []
## Candidate circles, built from node.analysis by set_analysis(). Each entry:
## {point: Vector2i, move: String, winrate: float, loss: float, visits: int,
##  is_best: bool, played: bool, pv: Array}
var candidate_list: Array = []
var hovered_candidate: int = -1
var last_move_marker: bool = true

var show_ownership: bool = false
var show_candidates: bool = true
## The side to play at the shown position: candidate win rates are for this player.
var mover_color: int = Board.Stone.BLACK

## Loss (in points) at which a candidate circle goes fully red.
const LOSS_COLOR_SPAN: float = 10.0
## At most 8 candidates, each with at least 1% of the root visits.
const MAX_CANDIDATES: int = 8
const MIN_VISIT_FRACTION: float = 0.01

var background_color: Color = Color(0.835, 0.682, 0.416)
var line_color: Color = Color(0.15, 0.11, 0.06)
var star_color: Color = Color(0.12, 0.09, 0.05)
var coordinate_color: Color = Color(0.2, 0.16, 0.1)

const EDGE_FRACTION: float = 0.75  # half-cell border, as a fraction of a cell
## Distance from the outer grid line to the centre of a coordinate label.
const LABEL_GAP: float = 0.95


func _init() -> void:
	# Without a minimum the board collapses to zero width when the side panel
	# claims the space, which makes it invisible at small window sizes.
	custom_minimum_size = Vector2(320, 320)
	# The board takes keyboard navigation itself; it must not be a focus target
	# that steals arrow keys from _unhandled_input.
	focus_mode = Control.FOCUS_NONE


func show_position(p_tree: GameTree, p_node: GameNode) -> void:
	tree = p_tree
	node = p_node
	mover_color = tree.turn_at(node) if tree != null else Board.Stone.BLACK
	clear_ghost()
	hovered_candidate = -1
	set_analysis(p_node.analysis if p_node != null else {})
	queue_redraw()


## Fills the ownership and candidate overlays from a cached engine result.
## Candidates are the engine's own order (best first), filtered to at least 1% of
## the root visits and capped at 8, each with the points it gives up against the
## best. Win rates are converted to the player to move.
func set_analysis(analysis: Dictionary) -> void:
	if analysis == null or analysis.is_empty():
		ownership = []
		candidate_list = []
		hovered_candidate = -1
		queue_redraw()
		return
	ownership = analysis.get("ownership", []) as Array
	var moves: Array = analysis.get("moves", []) as Array
	var root_visits: int = int(analysis.get("visits", 0))
	var best_lead: float = float((moves[0] as Dictionary).get("score_lead", 0.0)) \
		if not moves.is_empty() else 0.0
	var black_to_move: bool = mover_color == Board.Stone.BLACK
	var played_move: String = ""
	if node != null and not node.is_root():
		played_move = node.gtp_move(board_size())
	candidate_list = []
	for entry in moves:
		var info: Dictionary = entry as Dictionary
		var visits: int = int(info.get("visits", 0))
		if root_visits > 0 and float(visits) < float(root_visits) * MIN_VISIT_FRACTION:
			continue
		var gtp: String = String(info.get("move", ""))
		var point: Vector2i = Coords.from_gtp(gtp, board_size())
		if point == Coords.INVALID and not Coords.is_pass(gtp):
			continue
		# The engine reports win rates from Black's side (0..1); for White the
		# chance is the complement, not the negative (which showed as "-100").
		var rate: float = float(info.get("winrate", 0.0))
		if not black_to_move:
			rate = 1.0 - rate
		candidate_list.append({
			"point": point,
			"move": gtp,
			"visits": visits,
			"winrate": rate,
			"loss": absf(float(info.get("score_lead", 0.0)) - best_lead),
			"is_best": candidate_list.is_empty(),
			"played": played_move != "" and gtp == played_move,
			"pv": info.get("pv", []) as Array,
		})
		if candidate_list.size() >= MAX_CANDIDATES:
			break
	hovered_candidate = -1
	queue_redraw()


## Which candidate circle contains a pixel position, or -1. Used for hover.
func candidate_at(pos: Vector2) -> int:
	var cell: float = cell_size()
	if cell <= 0.0 or candidate_list.is_empty():
		return -1
	var radius: float = cell * 0.5
	for index in candidate_list.size():
		var point: Vector2i = (candidate_list[index] as Dictionary)["point"] as Vector2i
		if point == Coords.INVALID:
			continue  # a pass has no place on the board
		if (pos - point_center(point.x, point.y)).length() <= radius:
			return index
	return -1


## Input ------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if tree == null:
		return
	if event is InputEventMouseMotion:
		var hovered: Vector2i = point_at(event.position)
		set_ghost(hovered, ghost_color_for(hovered))
		var over_candidate: int = candidate_at(event.position)
		if over_candidate != hovered_candidate:
			hovered_candidate = over_candidate
			queue_redraw()
		if hovered != Board.INVALID:
			point_hovered.emit(hovered)
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			var clicked: Vector2i = point_at(event.position)
			if clicked != Board.INVALID:
				point_clicked.emit(clicked)
				accept_event()
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			navigate_requested.emit("back")
			accept_event()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			navigate_requested.emit("forward")
			accept_event()


## The colour a ghost stone should show for a point: the side to play, unless the
## point is occupied or illegal, in which case there is no ghost.
func ghost_color_for(point: Vector2i) -> int:
	if point == Board.INVALID or node == null:
		return Board.Stone.EMPTY
	var board: Board = tree.board_at(node)
	if board.get_stone(point.x, point.y) != Board.Stone.EMPTY:
		return Board.Stone.EMPTY
	return tree.turn_at(node)


func set_ghost(point: Vector2i, color: int) -> void:
	if point == ghost_point and color == ghost_color:
		return
	ghost_point = point
	ghost_color = color
	queue_redraw()


func clear_ghost() -> void:
	set_ghost(Board.INVALID, Board.Stone.EMPTY)


func board_size() -> int:
	return tree.size if tree != null else 19


## Geometry ------------------------------------------------------------

func cell_size() -> float:
	var n: int = board_size()
	var available: float = min(size.x, size.y)
	return available / float(n + 2.0 * EDGE_FRACTION)


func grid_origin() -> Vector2:
	var cell: float = cell_size()
	var span: float = cell * float(board_size() - 1)
	return Vector2((size.x - span) * 0.5, (size.y - span) * 0.5)


func point_center(x: int, y: int) -> Vector2:
	return grid_origin() + Vector2(float(x), float(y)) * cell_size()


## The nearest intersection to a pixel position, or INVALID when it is too far
## from the grid, so clicks in the margin are ignored.
func point_at(pos: Vector2) -> Vector2i:
	var cell: float = cell_size()
	var origin: Vector2 = grid_origin()
	var offset: Vector2 = pos - origin
	var x: int = int(round(offset.x / cell))
	var y: int = int(round(offset.y / cell))
	if x < 0 or x >= board_size() or y < 0 or y >= board_size():
		return Board.INVALID
	if (pos - point_center(x, y)).length() > cell * 0.55:
		return Board.INVALID
	return Vector2i(x, y)


static func star_points(p_size: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	match p_size:
		9:
			for x in [2, 6]:
				for y in [2, 6]:
					out.append(Vector2i(x, y))
			out.append(Vector2i(4, 4))
		13:
			# Standard 13x13 marks: the four 4-4 points and tengen.
			for x in [3, 9]:
				for y in [3, 9]:
					out.append(Vector2i(x, y))
			out.append(Vector2i(6, 6))
		19:
			for x in [3, 9, 15]:
				for y in [3, 9, 15]:
					out.append(Vector2i(x, y))
	return out


## Drawing ------------------------------------------------------------

func _draw() -> void:
	var n: int = board_size()
	var cell: float = cell_size()
	if cell <= 0.0:
		return
	draw_rect(Rect2(Vector2.ZERO, size), background_color)
	var origin: Vector2 = grid_origin()
	var far: Vector2 = origin + Vector2(cell * float(n - 1), cell * float(n - 1))
	for i in n:
		var offset: float = cell * float(i)
		draw_line(origin + Vector2(offset, 0), Vector2(origin.x + offset, far.y), line_color, 1.0)
		draw_line(Vector2(origin.x, origin.y + offset), Vector2(far.x, origin.y + offset), line_color, 1.0)
	draw_rect(Rect2(origin, Vector2(cell * float(n - 1), cell * float(n - 1))), line_color, false, 1.6)
	for s in star_points(n):
		draw_circle(point_center(s.x, s.y), max(2.0, cell * 0.11), star_color)
	_draw_stones(n, cell)
	_draw_overlays(n, cell)
	if show_coordinates:
		_draw_coordinates(n, cell)


## Stones come from the position at the current node, not from the move list, so
## captured stones disappear. Move numbers come from the move list: the index of
## the move that last placed a stone on each point.
func _draw_stones(n: int, cell: float) -> void:
	if tree == null or node == null:
		return
	var board: Board = tree.board_at(node)
	var radius: float = cell * 0.47
	var numbers: Dictionary = {}
	var move_index: int = 0
	for entry in path_with_moves():
		move_index += 1
		if bool(entry["pass"]):
			continue
		numbers_store(numbers, int(entry["x"]), int(entry["y"]), n, move_index)
	for y in n:
		for x in n:
			var stone: int = board.get_stone(x, y)
			if stone == Board.Stone.EMPTY:
				continue
			var center: Vector2 = point_center(x, y)
			var black: bool = stone == Board.Stone.BLACK
			var fill: Color = Color(0.08, 0.08, 0.09) if black else Color(0.96, 0.95, 0.92)
			draw_circle(center, radius, fill)
			draw_circle(center, radius, line_color, false, 1.0)
			if show_move_numbers:
				var key: int = Coords.to_index(x, y, n)
				if not numbers.has(key):
					continue
				var text_color: Color = Color(0.9, 0.9, 0.9) if black else Color(0.1, 0.1, 0.1)
				_draw_centered(str(int(numbers[key])), center, cell * 0.42, text_color)
	if last_move_marker and node != null and node.move != null and not node.is_pass():
		var p: Vector2i = node.move_point()
		if board.get_stone(p.x, p.y) != Board.Stone.EMPTY:
			var marker: Color = Color(0.9, 0.2, 0.2) if node.move_color() == Board.Stone.BLACK else Color(0.15, 0.15, 0.15)
			draw_circle(point_center(p.x, p.y), cell * 0.14, marker)
	if show_ghost and ghost_point != Board.INVALID and ghost_color != Board.Stone.EMPTY:
		var ghost_center: Vector2 = point_center(ghost_point.x, ghost_point.y)
		var ghost_fill: Color = Color(0.08, 0.08, 0.09, 0.45) \
			if ghost_color == Board.Stone.BLACK else Color(0.96, 0.95, 0.92, 0.45)
		draw_circle(ghost_center, radius, ghost_fill)


static func numbers_store(numbers: Dictionary, x: int, y: int, n: int, move_index: int) -> void:
	numbers[Coords.to_index(x, y, n)] = move_index


## The moves leading to the current node, so stones can be numbered in order.
func path_with_moves() -> Array:
	var out: Array = []
	if tree == null or node == null:
		return out
	for gnode in tree.path_to(node):
		if gnode.move == null:
			continue
		if gnode.is_pass():
			out.append({"pass": true, "x": -1, "y": -1, "color": gnode.move_color()})
		else:
			out.append({
				"pass": false,
				"x": gnode.move_point().x,
				"y": gnode.move_point().y,
				"color": gnode.move_color(),
			})
	return out


func _draw_overlays(n: int, cell: float) -> void:
	if show_ownership and not ownership.is_empty():
		_draw_ownership(n, cell)
	if show_candidates and not candidate_list.is_empty():
		_draw_candidates(cell)
	if hovered_candidate >= 0 and hovered_candidate < candidate_list.size():
		_draw_candidate_pv(candidate_list[hovered_candidate] as Dictionary, n, cell)


func _draw_ownership(n: int, cell: float) -> void:
	for y in n:
		for x in n:
			var value: float = float(ownership[Coords.to_index(x, y, n)])
			if absf(value) < 0.05:
				continue
			var tint: Color = Color(0, 0, 0, absf(value) * 0.65) \
				if value > 0.0 else Color(1, 1, 1, absf(value) * 0.65)
			var half: float = cell * 0.22
			var center: Vector2 = point_center(x, y)
			draw_rect(Rect2(center - Vector2(half, half), Vector2(half * 2.0, half * 2.0)), tint)


## Candidate circles: the best move is blue, the rest are shaded from
## green to red by the points they give up against the best. Inside each circle:
## the win rate for the player to move, and the points lost. The move actually
## played in the game gets an extra ring.
func _draw_candidates(cell: float) -> void:
	var radius: float = cell * 0.42
	for index in candidate_list.size():
		var entry: Dictionary = candidate_list[index] as Dictionary
		var point: Vector2i = entry["point"] as Vector2i
		# A pass candidate stays in the list (it can be the best move, and the
		# side panel says so) but has no intersection: drawing it at the
		# invalid point put a stray circle outside the board's top-left corner.
		if point == Coords.INVALID:
			continue
		var center: Vector2 = point_center(point.x, point.y)
		var color: Color = Color(0.15, 0.4, 0.9) \
			if bool(entry["is_best"]) else _loss_color(float(entry["loss"]))
		var hovered: bool = index == hovered_candidate
		draw_circle(center, radius, Color(color.r, color.g, color.b, 0.28 if hovered else 0.16))
		draw_circle(center, radius, color, false, 2.6 if bool(entry["is_best"]) else 1.8)
		if bool(entry["played"]):
			draw_circle(center, radius + cell * 0.07, Color(0.9, 0.2, 0.2), false, 2.0)
		var rate: int = int(round(float(entry["winrate"]) * 100.0))
		_draw_centered(str(rate), center - Vector2(0, cell * 0.10), cell * 0.34, color)
		var loss: float = float(entry["loss"])
		var label: String = "" if bool(entry["is_best"]) else "-%.1f" % loss
		if not label.is_empty():
			_draw_centered(label, center + Vector2(0, cell * 0.24), cell * 0.26, color)


## Green (small loss) to red (large loss), scaled over LOSS_COLOR_SPAN points.
func _loss_color(loss: float) -> Color:
	var t: float = clampf(loss / LOSS_COLOR_SPAN, 0.0, 1.0)
	return Color(0.15 + 0.7 * t, 0.6 - 0.45 * t, 0.15)


## Hovering a candidate draws its pv as numbered semi-transparent stones.
## The variation is drawn on top of the current position, not
## committed to it, and cleared when the pointer leaves.
func _draw_candidate_pv(entry: Dictionary, n: int, cell: float) -> void:
	var pv: Array = entry.get("pv", []) as Array
	if pv.is_empty():
		return
	var color: int = mover_color
	for step in pv.size():
		var gtp: String = String(pv[step])
		if gtp == Coords.PASS:
			break
		var point: Vector2i = Coords.from_gtp(gtp, n)
		if point == Coords.INVALID:
			break
		var center: Vector2 = point_center(point.x, point.y)
		var radius: float = cell * 0.44
		var black: bool = color == Board.Stone.BLACK
		var fill: Color = Color(0.08, 0.08, 0.09, 0.42) if black else Color(0.96, 0.95, 0.92, 0.5)
		draw_circle(center, radius, fill)
		var text_color: Color = Color(0.9, 0.9, 0.9, 0.85) if black else Color(0.1, 0.1, 0.1, 0.9)
		_draw_centered(str(step + 1), center, cell * 0.38, text_color)
		color = Board.opposite(color)


func _draw_coordinates(n: int, cell: float) -> void:
	var font: Font = ThemeDB.fallback_font
	if font == null:
		return
	# Labels are centred LABEL_GAP cells outside the outer lines. A stone on an
	# edge line reaches 0.47 cells out and a label is about 0.2 cells tall, so
	# 0.95 keeps them clear of each other inside the 1.25-cell border.
	var font_size: float = max(9.0, cell * 0.36)
	var origin: Vector2 = grid_origin()
	var far: float = cell * float(n - 1)
	for i in n:
		var x: float = origin.x + cell * float(i)
		var letter: String = Coords.LETTERS[i]
		_draw_centered(letter, Vector2(x, origin.y - cell * LABEL_GAP), font_size, coordinate_color)
		_draw_centered(letter, Vector2(x, origin.y + far + cell * LABEL_GAP), font_size, coordinate_color)
	for i in n:
		var number: String = str(n - i)
		var y: float = origin.y + cell * float(i)
		_draw_centered(number, Vector2(origin.x - cell * LABEL_GAP, y), font_size, coordinate_color)
		_draw_centered(number, Vector2(origin.x + far + cell * LABEL_GAP, y), font_size, coordinate_color)


func _draw_centered(text: String, center: Vector2, font_size: float, color: Color) -> void:
	var font: Font = ThemeDB.fallback_font
	if font == null:
		return
	var px: int = int(max(8.0, font_size))
	var tw: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x
	draw_string(font, center - Vector2(tw * 0.5, -px * 0.35), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, px, color)
