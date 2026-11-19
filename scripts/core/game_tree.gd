class_name GameTree
extends RefCounted

## The move tree plus the game metadata that comes with it. The root is the empty
## position, or the handicap position via the root's setup stones.

var root: GameNode = GameNode.new()
var current: GameNode = root
var size: int = 19
var komi: float = 7.0
var rules: String = ""
var handicap: int = 0
var black_name: String = ""
var white_name: String = ""
var result: String = ""
## Root properties the app does not model, preserved for round-tripping.
var extra_properties: Dictionary = {}


func _init(p_size: int = 19, p_komi: float = 7.0) -> void:
	size = p_size
	komi = p_komi
	root = GameNode.new()
	current = root


func reset(p_size: int = 19, p_komi: float = 7.0) -> void:
	size = p_size
	komi = p_komi
	handicap = 0
	black_name = ""
	white_name = ""
	result = ""
	rules = ""
	extra_properties = {}
	root = GameNode.new()
	current = root


## Moves ------------------------------------------------------------

## Plays in the current position, or follows the existing identical child, so
## replaying a recorded game rebuilds the same tree instead of duplicating it.
func play_move(color: int, x: int, y: int) -> GameNode:
	var move: Dictionary = {"color": color, "x": x, "y": y}
	var existing: GameNode = current.find_child(move)
	if existing != null:
		current = existing
		return current
	var node: GameNode = GameNode.new()
	node.move = move
	current.add_child(node)
	current = node
	return current


func play_pass(color: int) -> GameNode:
	return play_move(color, -1, -1)


func go_to(node: GameNode) -> void:
	current = node


func go_to_root() -> void:
	current = root


func go_back() -> bool:
	if current.parent == null:
		return false
	current = current.parent
	return true


func go_forward() -> bool:
	if current.children.is_empty():
		return false
	current = current.children[0]
	return true


## Jumps to the end of the game's main line, i.e. the first child of every node
## from the root. This is what the End key means: the position is independent of
## where you are now, so a side variation does not trap you.
func go_to_main_line_end() -> void:
	current = _line_end(root)


## Jumps to the end of the line continuing from the current node, following the
## first child at each step. Used for "end of this variation".
func go_to_line_end() -> void:
	current = _line_end(current)


func _line_end(node: GameNode) -> GameNode:
	while not node.children.is_empty():
		node = node.children[0]
	return node


## The main line is the first child at every step.
func main_line() -> Array[GameNode]:
	var line: Array[GameNode] = [root]
	var node: GameNode = root
	while not node.children.is_empty():
		node = node.children[0]
		line.append(node)
	return line


func main_line_length() -> int:
	return main_line().size() - 1


func node_count() -> int:
	return _count(root)


## Colour to play at this position, assuming Black plays first after handicap.
## Whose turn it is at a node.
##
## SGF decides this with the PL[] property ("player to play"), which may appear on
## any node, so the nearest one on the path wins. Otherwise the root decides:
## a handicap game (HA) starts with White, a plain setup position starts with
## Black, and an empty board starts with Black. Descendants then alternate.
func turn_at(node: GameNode) -> int:
	var anchor: GameNode = node
	var steps: int = 0
	var color: int = Board.Stone.EMPTY
	while true:
		var forced: int = _pl_of(anchor)
		if forced != Board.Stone.EMPTY:
			color = forced
			break
		if anchor == root:
			# The SGF reader keeps root properties on the tree, not the root
			# node, so a puzzle's PL[W] lives here. Missing it made every
			# "White to play" problem start with Black.
			var root_pl: int = _pl_from(extra_properties)
			if root_pl != Board.Stone.EMPTY:
				color = root_pl
			else:
				color = Board.Stone.WHITE if handicap > 0 else Board.Stone.BLACK
			break
		anchor = anchor.parent
		if anchor == null:
			# Defensive: a detached node still alternates from Black.
			color = Board.Stone.BLACK if steps % 2 == 0 else Board.Stone.WHITE
			break
		steps += 1
	for i in steps:
		color = Board.opposite(color)
	return color


## The colour named by a PL[] property on a node, or EMPTY when there is none.
static func _pl_of(node: GameNode) -> int:
	return _pl_from(node.extra_properties)


static func _pl_from(properties: Dictionary) -> int:
	if not properties.has("PL"):
		return Board.Stone.EMPTY
	var values: Array = properties["PL"] as Array
	if values.is_empty():
		return Board.Stone.EMPTY
	match String(values[0]).strip_edges().to_upper():
		"B":
			return Board.Stone.BLACK
		"W":
			return Board.Stone.WHITE
		_:
			return Board.Stone.EMPTY


## Move list for the engine: GTP strings from the root to `node`. Setup stones
## are sent separately as AB/AW, so they must not appear here.
func moves_to(node: GameNode) -> Array[String]:
	var out: Array[String] = []
	for n in path_to(node):
		if n.move == null:
			continue  # setup-only node: it changes the board but is not a move
		out.append(n.gtp_move(size))
	return out


## Path of nodes from the root (exclusive) to `node`. Nodes without a move
## (setup-only nodes from SGF) are included, since they still change the board.
func path_to(node: GameNode) -> Array[GameNode]:
	var path: Array[GameNode] = []
	var it: GameNode = node
	while it != null and it != root:
		path.push_front(it)
		it = it.parent
	return path


## Board ------------------------------------------------------------

## The move list in GTP form with colours, for KataGo's "moves" array:
## [["B","Q16"], ["W","D4"], ...]. Setup stones are NOT included; they belong in
## "initialStones" (see setup_stones_with_colors), because counting them as moves
## would shift every analyzeTurns index and fake a move history.
func moves_with_colors(node: GameNode) -> Array:
	var out: Array = []
	for n in path_to(node):
		var letter: String = "B" if n.move_color() == Board.Stone.BLACK else "W"
		out.append([letter, n.gtp_move(size)])
	return out


## Setup stones (AB/AW) on any node along the path, for KataGo's "initialStones".
func setup_stones_with_colors(node: GameNode) -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	var nodes: Array[GameNode] = [root]
	nodes.append_array(path_to(node))
	for n in nodes:
		for p in n.setup_black:
			var key_b: String = "B" + str(p.x) + "," + str(p.y)
			if not seen.has(key_b):
				seen[key_b] = true
				out.append(["B", Coords.to_gtp(p.x, p.y, size)])
		for p in n.setup_white:
			var key_w: String = "W" + str(p.x) + "," + str(p.y)
			if not seen.has(key_w):
				seen[key_w] = true
				out.append(["W", Coords.to_gtp(p.x, p.y, size)])
	return out


## Number of moves from the root to a node, i.e. the 0-based turn index used by
## analyzeTurns (turn 0 is the position after setup stones, before any move).
func move_count_to(node: GameNode) -> int:
	return path_to(node).size()


func find_by_move_index(index: int) -> GameNode:
	var line: Array[GameNode] = main_line()
	if index < 0 or index >= line.size():
		return null
	return line[index]


## Rebuilds (and caches) the Board for a node by replaying its move path.
## Setup stones are applied at the node that carries them (SGF allows AB/AW on
## any node, not just the root). Note: AE[] (stone removal) is preserved in the
## SGF but not applied to the board, as the app never produces it itself.
func board_at(node: GameNode) -> Board:
	if node.board != null and node.board.size == size:
		return node.board
	var board: Board = Board.new(size)
	_apply_setup(board, root.setup_black, root.setup_white)
	for n in path_to(node):
		_apply_setup(board, n.setup_black, n.setup_white)
		if n.move == null:
			continue
		if n.is_pass():
			board.play_pass(n.move_color())
		else:
			board.play(n.move_point().x, n.move_point().y, n.move_color())
	node.board = board
	return board


func _apply_setup(board: Board, black: Array[Vector2i], white: Array[Vector2i]) -> void:
	for p in black:
		board.set_stone(p.x, p.y, Board.Stone.BLACK)
	for p in white:
		board.set_stone(p.x, p.y, Board.Stone.WHITE)


func current_board() -> Board:
	return board_at(current)


func invalidate_boards() -> void:
	_invalidate(root)


## Helpers ------------------------------------------------------------

func _count(node: GameNode) -> int:
	var total: int = 1
	for child in node.children:
		total += _count(child)
	return total


func _invalidate(node: GameNode) -> void:
	node.board = null
	for child in node.children:
		_invalidate(child)
