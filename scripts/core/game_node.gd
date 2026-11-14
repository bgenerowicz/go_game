class_name GameNode
extends RefCounted

## One position in the game tree: the move that led here plus its children.

## The parent link is weak on purpose: children already hold strong references to
## their children, so a strong link back would be a cycle RefCounted never frees.
var _parent_ref: WeakRef = null

var parent: GameNode:
	get:
		if _parent_ref == null:
			return null
		return _parent_ref.get_ref() as GameNode
	set(value):
		_parent_ref = weakref(value) if value != null else null
var children: Array[GameNode] = []
## Move that produced this node: {"color": Stone.BLACK/WHITE, "x": int, "y": int}
## with x = y = -1 for a pass, or null for the root.
var move: Variant = null
## Setup stones carried by this node (AB / AW properties).
var setup_black: Array[Vector2i] = []
var setup_white: Array[Vector2i] = []
var comment: String = ""
## Properties attached to this node that the app does not model (setup, territory,
## unknown tags). Kept verbatim so they survive a parse -> write -> parse round trip.
var extra_properties: Dictionary = {}
## Cached engine analysis for this position, filled by AnalysisService (PLAN 5.3).
var analysis: Dictionary = {}
## Board for this position, built lazily by GameTree.board_at().
var board: Board = null
## Depth from the root (root = 0), i.e. the number of moves played to reach here.
var depth: int = 0


func is_root() -> bool:
	return parent == null


func is_pass() -> bool:
	if move == null:
		return false
	return int(move["x"]) < 0


func move_color() -> int:
	if move == null:
		return Board.Stone.EMPTY
	return int(move["color"])


func move_point() -> Vector2i:
	if move == null:
		return Board.INVALID
	return Vector2i(int(move["x"]), int(move["y"]))


func gtp_move(p_size: int) -> String:
	if move == null:
		return ""
	if is_pass():
		return Coords.PASS
	return Coords.to_gtp(int(move["x"]), int(move["y"]), p_size)


func add_child(child: GameNode) -> void:
	child.parent = self
	child.depth = depth + 1
	children.append(child)


func find_child(move: Variant) -> GameNode:
	for child in children:
		if _same_move(child.move, move):
			return child
	return null


## Drops a child (and its whole sub-tree) from this node.
func remove_child(child: GameNode) -> bool:
	var index: int = children.find(child)
	if index == -1:
		return false
	children.remove_at(index)
	child._parent_ref = null
	child.board = null
	return true


func is_main_line() -> bool:
	if parent == null:
		return true
	return parent.children.size() <= 1 or parent.children[0] == self


func main_line_index() -> int:
	if parent == null:
		return 0
	return parent.children.find(self)


static func _same_move(a: Variant, b: Variant) -> bool:
	if a == null or b == null:
		return a == null and b == null
	return int(a["color"]) == int(b["color"]) \
		and int(a["x"]) == int(b["x"]) and int(a["y"]) == int(b["y"])
