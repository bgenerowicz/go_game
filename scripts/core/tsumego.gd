class_name Tsumego
extends RefCounted

## Puzzle mode: helps the engine read a local life-and-death problem.
##
## On its own the engine reads the whole board, so in a corner problem it likes
## moves in the big empty spaces as much as the vital point, and it thinks the
## group can escape into open space that the problem only implies is closed.
## Two things fix that, both only in the query sent to the engine (the board on
## screen never changes):
##
## - a tsumego frame: every point outside the problem's area is filled with a
##   solid wall, the attacker's stones next to the problem and the defender's
##   further away, with eye holes so both walls are alive. The outside is then
##   settled and split evenly (komi included), so the only open question, and
##   what decides the win rate, is whether the problem group lives.
## - allowMoves: the engine may only play inside the problem's area (or pass),
##   for both colours, at every depth of its search.
##
## plan() returns {} when the position does not look like a local problem (no
## stones, or stones spread over more than half the board).

## Empty lines kept around the stones before the frame starts.
const MARGIN: int = 2
## A side of the area this close to the board edge is pushed onto the edge, so
## no thin strip of frame is left between a corner problem and the edge.
const SNAP: int = 2
## Above this share of the board the position is not a local problem.
const MAX_AREA_FRACTION: float = 0.5
## Deep enough to cover the whole search.
const UNTIL_DEPTH: int = 1000


## Everything the engine query needs, or {} when puzzle mode does not apply:
## {
##   "region": Rect2i (x, y, w, h) of the problem's area,
##   "attacker": Board.Stone, "defender": Board.Stone,
##   "frame": Array of ["B"/"W", gtp] to add to initialStones,
##   "allow": Array[String] of gtp moves the engine may play, "pass" included,
## }
static func plan(tree: GameTree, node: GameNode) -> Dictionary:
	if tree == null or node == null:
		return {}
	var size: int = tree.size
	var touched: Array[Vector2i] = _touched_points(tree, node)
	if touched.is_empty():
		return {}
	var region: Rect2i = area_around(touched, size)
	if region.get_area() > MAX_AREA_FRACTION * size * size:
		return {}
	var board: Board = tree.board_at(node)
	var sides: Dictionary = pick_sides(board, region)
	if sides.is_empty():
		return {}
	var attacker: int = int(sides["attacker"])
	var defender_area: int = defender_area_estimate(board, region, int(sides["defender"]))
	# Halfway between "the group dies" (the attacker owns the whole area) and
	# "it lives" (the defender keeps its part), the attacker leads the area by
	# this much. The frame gives that back, so the result hinges on the group.
	var area_lead: float = float(region.get_area() - defender_area)
	var colours: Dictionary = frame_colours(region, size, attacker, tree.komi, area_lead)
	var frame: Array = []
	for point in colours:
		var colour: int = int(colours[point])
		if colour == Board.Stone.EMPTY:
			continue
		frame.append(["B" if colour == Board.Stone.BLACK else "W",
			Coords.to_gtp(point.x, point.y, size)])
	var allow: Array[String] = []
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			if board.get_stone(x, y) == Board.Stone.EMPTY:
				allow.append(Coords.to_gtp(x, y, size))
	allow.append(Coords.PASS)
	return {
		"region": region,
		"attacker": attacker,
		"defender": int(sides["defender"]),
		"frame": frame,
		"allow": allow,
	}


## Adds the plan to a KataGo query: frame stones after any setup stones, the
## same allowMoves list for both colours, and area scoring. The frame is
## balanced by counting stones as points; under territory scoring (Japanese)
## stones count nothing and the balance was about 11 points off on a corner
## problem. Life and death does not depend on the scoring rules.
static func apply_to_query(query: Dictionary, p: Dictionary) -> void:
	query["rules"] = "chinese"
	var stones: Array = (query.get("initialStones", []) as Array).duplicate()
	stones.append_array(p["frame"] as Array)
	query["initialStones"] = stones
	var allow: Array = []
	for player in ["B", "W"]:
		allow.append({"player": player, "moves": p["allow"], "untilDepth": UNTIL_DEPTH})
	query["allowMoves"] = allow


## Every point that has held a stone on the way to this node: setup stones and
## every move played, captured ones included. The frame stays clear of all of
## them, so replaying the moves gives the same captures with the frame present.
static func _touched_points(tree: GameTree, node: GameNode) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var nodes: Array[GameNode] = [tree.root]
	nodes.append_array(tree.path_to(node))
	for n in nodes:
		out.append_array(n.setup_black)
		out.append_array(n.setup_white)
		if n.move != null:
			var x: int = int(n.move["x"])
			var y: int = int(n.move["y"])
			if x >= 0 and y >= 0:
				out.append(Vector2i(x, y))
	return out


## The bounding box of the points, MARGIN lines wider on every side, with sides
## near the board edge pushed onto it.
static func area_around(points: Array[Vector2i], size: int) -> Rect2i:
	var x0: int = size
	var y0: int = size
	var x1: int = -1
	var y1: int = -1
	for p in points:
		x0 = mini(x0, p.x)
		y0 = mini(y0, p.y)
		x1 = maxi(x1, p.x)
		y1 = maxi(y1, p.y)
	x0 = maxi(0, x0 - MARGIN)
	y0 = maxi(0, y0 - MARGIN)
	x1 = mini(size - 1, x1 + MARGIN)
	y1 = mini(size - 1, y1 + MARGIN)
	if x0 <= SNAP:
		x0 = 0
	if y0 <= SNAP:
		y0 = 0
	if x1 >= size - 1 - SNAP:
		x1 = size - 1
	if y1 >= size - 1 - SNAP:
		y1 = size - 1
	return Rect2i(x0, y0, x1 - x0 + 1, y1 - y0 + 1)


## Who attacks and who defends. The defender is the side whose stones sit
## deeper inside the area, away from its open sides (the sides not on the board
## edge): in a corner problem the group being killed or saved is in the corner
## and the attacker surrounds it. A tie goes to the side with fewer stones as
## defender. Returns {} when only one colour (or no stone) is in the area.
static func pick_sides(board: Board, region: Rect2i) -> Dictionary:
	var depth: Dictionary = {Board.Stone.BLACK: 0.0, Board.Stone.WHITE: 0.0}
	var count: Dictionary = {Board.Stone.BLACK: 0, Board.Stone.WHITE: 0}
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			var stone: int = board.get_stone(x, y)
			if stone == Board.Stone.EMPTY:
				continue
			count[stone] = int(count[stone]) + 1
			depth[stone] = float(depth[stone]) + _depth_inside(Vector2i(x, y), region, board.size)
	var blacks: int = int(count[Board.Stone.BLACK])
	var whites: int = int(count[Board.Stone.WHITE])
	if blacks == 0 or whites == 0:
		return {}
	var black_depth: float = float(depth[Board.Stone.BLACK]) / blacks
	var white_depth: float = float(depth[Board.Stone.WHITE]) / whites
	var defender: int
	if absf(black_depth - white_depth) > 0.01:
		defender = Board.Stone.BLACK if black_depth > white_depth else Board.Stone.WHITE
	else:
		defender = Board.Stone.BLACK if blacks < whites else Board.Stone.WHITE
	var attacker: int = Board.Stone.WHITE if defender == Board.Stone.BLACK else Board.Stone.BLACK
	return {"attacker": attacker, "defender": defender}


## Roughly the points the defender keeps if its group lives: every point of the
## area whose nearest stone (by distance along the lines) is the defender's,
## half of each tie.
static func defender_area_estimate(board: Board, region: Rect2i, defender: int) -> int:
	var stones: Array[Vector2i] = []
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			if board.get_stone(x, y) != Board.Stone.EMPTY:
				stones.append(Vector2i(x, y))
	var halves: int = 0
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			var best: int = 1 << 20
			var mine: bool = false
			var theirs: bool = false
			for s in stones:
				var d: int = absi(s.x - x) + absi(s.y - y)
				if d < best:
					best = d
					mine = false
					theirs = false
				if d == best:
					if board.get_stone(s.x, s.y) == defender:
						mine = true
					else:
						theirs = true
			if mine:
				halves += 1 if theirs else 2
	return halves / 2


## Distance from a point to the nearest open side of the area.
static func _depth_inside(p: Vector2i, region: Rect2i, size: int) -> float:
	var best: int = size
	if region.position.x > 0:
		best = mini(best, p.x - region.position.x + 1)
	if region.position.y > 0:
		best = mini(best, p.y - region.position.y + 1)
	if region.end.x < size:
		best = mini(best, region.end.x - p.x)
	if region.end.y < size:
		best = mini(best, region.end.y - p.y)
	return float(best)


## The colour of every point outside the area: Board.Stone.BLACK / WHITE for a
## frame stone, EMPTY for an eye. Keyed by Vector2i.
##
## The points nearest the area go to the attacker, the rest to the defender,
## split so that the whole board (komi included) is even when the attacker
## leads the area by area_lead: halfway between the problem's two outcomes. Eyes
## sit on a lattice no two of whose points touch, wherever all neighbours are
## the same colour and the area is not next to them. A frame group left with no
## liberty at all (a small pocket cut off by the area) would make the query
## illegal, so one of its stones is turned into an empty point.
static func frame_colours(region: Rect2i, size: int, attacker: int, komi: float,
		area_lead: float = 0.0) -> Dictionary:
	var outside: Array[Vector2i] = []
	for y in range(size):
		for x in range(size):
			if not region.has_point(Vector2i(x, y)):
				outside.append(Vector2i(x, y))
	outside.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var da: int = _distance_to(a, region)
		var db: int = _distance_to(b, region)
		if da != db:
			return da < db
		return a.y * size + a.x < b.y * size + b.x)
	# Attacker minus defender over the whole board should be komi when Black
	# attacks (-komi when White does): the outside makes up for area_lead.
	var n: int = outside.size()
	var target: float = (komi if attacker == Board.Stone.BLACK else -komi) - area_lead
	var attacker_points: float = (n + target) / 2.0
	var k: int = clampi(roundi(attacker_points), 0, n)
	var defender: int = Board.Stone.WHITE if attacker == Board.Stone.BLACK else Board.Stone.BLACK
	var colours: Dictionary = {}
	for i in range(n):
		colours[outside[i]] = attacker if i < k else defender
	# Eyes.
	var eyes: Array[Vector2i] = []
	for p in outside:
		if posmod(p.x + 2 * p.y, 5) != 0:
			continue
		var own: int = int(colours[p])
		var ok: bool = true
		for q in _neighbours(p, size):
			if region.has_point(q) or int(colours[q]) != own:
				ok = false
				break
		if ok:
			eyes.append(p)
	for p in eyes:
		colours[p] = Board.Stone.EMPTY
	_give_every_group_a_liberty(colours, region, size)
	return colours


## Chebyshev distance from a point outside the area to the area.
static func _distance_to(p: Vector2i, region: Rect2i) -> int:
	var dx: int = maxi(0, maxi(region.position.x - p.x, p.x - (region.end.x - 1)))
	var dy: int = maxi(0, maxi(region.position.y - p.y, p.y - (region.end.y - 1)))
	return maxi(dx, dy)


static func _neighbours(p: Vector2i, size: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var q: Vector2i = p + d
		if q.x >= 0 and q.y >= 0 and q.x < size and q.y < size:
			out.append(q)
	return out


## Points inside the area count as liberties: whatever stands there, the frame
## must not be what makes a group there capturable, and an empty area point is
## a real liberty.
static func _give_every_group_a_liberty(colours: Dictionary, region: Rect2i, size: int) -> void:
	var seen: Dictionary = {}
	for start in colours.keys():
		var colour: int = int(colours[start])
		if colour == Board.Stone.EMPTY or seen.has(start):
			continue
		var group: Array[Vector2i] = []
		var has_liberty: bool = false
		var stack: Array[Vector2i] = [start]
		seen[start] = true
		while not stack.is_empty():
			var p: Vector2i = stack.pop_back()
			group.append(p)
			for q in _neighbours(p, size):
				if region.has_point(q) or int(colours[q]) == Board.Stone.EMPTY:
					has_liberty = true
				elif int(colours[q]) == colour and not seen.has(q):
					seen[q] = true
					stack.append(q)
		if not has_liberty:
			colours[group[group.size() / 2]] = Board.Stone.EMPTY
