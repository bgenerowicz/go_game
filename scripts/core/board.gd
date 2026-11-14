class_name Board
extends RefCounted

## Go board rules, free of any Node/scene dependency so it runs headless in tests.
##
## Enforces: bounds, occupancy, capture, suicide rejection and simple ko.
## It deliberately does NOT enforce whose turn it is; the game layer decides.

enum Stone { EMPTY = 0, BLACK = 1, WHITE = 2 }

const INVALID: Vector2i = Vector2i(-1, -1)

var size: int = 19
## Flat grid, index = y * size + x, y counted from the TOP (the same row order as
## the engine's ownership arrays). Values are Stone enum values.
var grid: PackedByteArray = PackedByteArray()
## The single point that may not be played immediately (simple ko).
var ko_point: Vector2i = INVALID
## Stones captured BY each colour: {Stone.BLACK: int, Stone.WHITE: int}.
var captures: Dictionary = {}
## One entry per move (including passes), used for undo and for replay.
var history: Array = []
var consecutive_passes: int = 0


func _init(p_size: int = 19) -> void:
	assert(Coords.is_valid_size(p_size), "board size must be 9, 13 or 19")
	size = p_size
	clear()


func clear() -> void:
	grid = PackedByteArray()
	grid.resize(size * size)
	grid.fill(Stone.EMPTY)
	ko_point = INVALID
	captures = {Stone.BLACK: 0, Stone.WHITE: 0}
	history = []
	consecutive_passes = 0


static func idx(x: int, y: int, p_size: int) -> int:
	return y * p_size + x


## Queries ------------------------------------------------------------

func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < size and y >= 0 and y < size


func get_stone(x: int, y: int) -> int:
	if not in_bounds(x, y):
		return Stone.EMPTY
	return grid[idx(x, y, size)]


## Direct placement, for handicap / setup positions and test fixtures.
## Does not apply captures, ko or suicide rules.
func set_stone(x: int, y: int, value: int) -> bool:
	if not in_bounds(x, y):
		return false
	grid[idx(x, y, size)] = value
	return true


func stone_count(color: int) -> int:
	var total: int = 0
	for i in grid.size():
		if grid[i] == color:
			total += 1
	return total


func neighbors(x: int, y: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if x > 0:
		out.append(Vector2i(x - 1, y))
	if x < size - 1:
		out.append(Vector2i(x + 1, y))
	if y > 0:
		out.append(Vector2i(x, y - 1))
	if y < size - 1:
		out.append(Vector2i(x, y + 1))
	return out


static func opposite(color: int) -> int:
	match color:
		Stone.BLACK:
			return Stone.WHITE
		Stone.WHITE:
			return Stone.BLACK
		_:
			return Stone.EMPTY


## The connected group containing (x, y) and its liberty list.
## Both arrays are empty when the point is empty or off the board.
func group(x: int, y: int) -> Dictionary:
	return _group_on(grid, x, y)


## Rules ------------------------------------------------------------

func is_legal(x: int, y: int, color: int) -> bool:
	if not _playable(x, y, color):
		return false
	return bool(_apply(grid.duplicate(), x, y, color)["ok"])


## Plays a move. Returns false and leaves the board untouched when illegal.
func play(x: int, y: int, color: int) -> bool:
	if not _playable(x, y, color):
		return false
	var result: Dictionary = _apply(grid, x, y, color)
	if not bool(result["ok"]):
		return false
	var entry: Dictionary = {
		"pass": false,
		"x": x,
		"y": y,
		"color": color,
		"ko_before": ko_point,
		"passes_before": consecutive_passes,
		"captured": [],
	}
	for c in (result["captured"] as Array):
		entry["captured"].append({"x": c.x, "y": c.y, "color": opposite(color)})
		captures[color] = int(captures.get(color, 0)) + 1
	ko_point = result["ko"]
	consecutive_passes = 0
	history.append(entry)
	return true


func play_pass(color: int) -> bool:
	if color != Stone.BLACK and color != Stone.WHITE:
		return false
	history.append({
		"pass": true,
		"x": -1,
		"y": -1,
		"color": color,
		"ko_before": ko_point,
		"passes_before": consecutive_passes,
		"captured": [],
	})
	ko_point = INVALID
	consecutive_passes += 1
	return true


## Convenience wrapper used by the engine layer, which speaks GTP.
func play_gtp(gtp: String, color: int) -> bool:
	if Coords.is_pass(gtp):
		return play_pass(color)
	var p: Vector2i = Coords.from_gtp(gtp, size)
	if p == Coords.INVALID:
		return false
	return play(p.x, p.y, color)


## Takes back the last move or pass, restoring captures and the ko point.
func undo() -> bool:
	if history.is_empty():
		return false
	var entry: Dictionary = history.pop_back()
	ko_point = entry["ko_before"]
	consecutive_passes = int(entry["passes_before"])
	if bool(entry["pass"]):
		return true
	var x: int = int(entry["x"])
	var y: int = int(entry["y"])
	if get_stone(x, y) == int(entry["color"]):
		grid[idx(x, y, size)] = Stone.EMPTY
	for c in (entry["captured"] as Array):
		grid[idx(int(c["x"]), int(c["y"]), size)] = int(c["color"])
		captures[int(entry["color"])] = int(captures.get(int(entry["color"]), 0)) - 1
	return true


func move_count() -> int:
	return history.size()


## The move list in GTP form, for KataGo's "moves" array.
func moves_as_gtp() -> Array[String]:
	var out: Array[String] = []
	for entry in (history as Array):
		if bool(entry["pass"]):
			out.append(Coords.PASS)
		else:
			out.append(Coords.to_gtp(int(entry["x"]), int(entry["y"]), size))
	return out


func clone() -> Board:
	return duplicate_board()


func duplicate_board() -> Board:
	var other: Board = Board.new(size)
	other.grid = grid.duplicate()
	other.ko_point = ko_point
	other.captures = captures.duplicate(true)
	other.history = history.duplicate(true)
	other.consecutive_passes = consecutive_passes
	return other


## Internals ------------------------------------------------------------

func _playable(x: int, y: int, color: int) -> bool:
	if not in_bounds(x, y):
		return false
	if color != Stone.BLACK and color != Stone.WHITE:
		return false
	if get_stone(x, y) != Stone.EMPTY:
		return false
	if x == ko_point.x and y == ko_point.y:
		return false
	return true


## Applies a move to g in place. Returns a Dictionary with:
##   ok        false when the move would be suicide (g is restored)
##   captured  Array[Vector2i] of removed opponent stones
##   ko        the new ko point, or INVALID
func _apply(g: PackedByteArray, x: int, y: int, color: int) -> Dictionary:
	var opponent: int = opposite(color)
	var played := idx(x, y, size)
	g[played] = color
	var captured: Array[Vector2i] = []
	for n in neighbors(x, y):
		if int(g[idx(n.x, n.y, size)]) == opponent:
			var victim: Dictionary = _group_on(g, n.x, n.y)
			if (victim["liberties"] as Array).is_empty():
				for st in (victim["stones"] as Array):
					if not _has_point(captured, st):
						captured.append(st)
	for c in captured:
		g[idx(c.x, c.y, size)] = Stone.EMPTY
	var own: Dictionary = _group_on(g, x, y)
	var own_liberties: Array = own["liberties"] as Array
	var own_stones: Array = own["stones"] as Array
	if own_liberties.is_empty():
		# Suicide: put everything back and refuse the move.
		g[played] = Stone.EMPTY
		for c in captured:
			g[idx(c.x, c.y, size)] = opponent
		return {"ok": false, "captured": [], "ko": INVALID, "group_size": 0}
	var ko: Vector2i = INVALID
	if captured.size() == 1 and own_stones.size() == 1 and own_liberties.size() == 1:
		ko = captured[0]
	return {
		"ok": true,
		"captured": captured,
		"ko": ko,
		"group_size": own_stones.size(),
	}


func _group_on(g: PackedByteArray, x: int, y: int) -> Dictionary:
	var stones: Array[Vector2i] = []
	var liberties: Array[Vector2i] = []
	if not in_bounds(x, y) or int(g[idx(x, y, size)]) == Stone.EMPTY:
		return {"stones": stones, "liberties": liberties}
	var color: int = int(g[idx(x, y, size)])
	var start := Vector2i(x, y)
	var seen: Dictionary = {start: true}
	var stack: Array[Vector2i] = [start]
	while not stack.is_empty():
		var p: Vector2i = stack.pop_back()
		stones.append(p)
		for n in neighbors(p.x, p.y) as Array[Vector2i]:
			var value: int = int(g[idx(n.x, n.y, size)])
			if value == Stone.EMPTY:
				if not _has_point(liberties, n):
					liberties.append(n)
			elif value == color and not seen.has(n):
				seen[n] = true
				stack.append(n)
	return {"stones": stones, "liberties": liberties}


static func _has_point(points: Array, p: Vector2i) -> bool:
	for q in points:
		if q == p:
			return true
	return false


