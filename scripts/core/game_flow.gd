class_name GameFlow
extends RefCounted

## The rules-level flow of a game: whose turn it is, passes, undo, end detection.
## Kept free of Node/UI references so it can be driven from a headless test.
## main.gd owns one of these and renders it.

var tree: GameTree = GameTree.new()
var over: bool = false
var result_text: String = ""
## The most recent reason a move was refused, for the UI to report.
var last_error: String = ""
## Set when the game ends by two consecutive passes rather than resignation.
var ended_by_passes: bool = false
## True when result_text came from this flow (resign / two passes) rather than
## from a loaded SGF header, so undo may clear it again.
var result_set_locally: bool = false

## Emitted whenever the shown position or the tree shape changes, so views stay
## correct no matter who drives the flow (a UI handler, a test, the AI).
signal position_changed(node: GameNode)
## Emitted when the game ends or a result is cleared.
signal game_state_changed()


func _announce() -> void:
	position_changed.emit(tree.current)


func start(p_size: int = 19, p_komi: float = 6.5, p_rules: String = "japanese",
		p_handicap: int = 0) -> void:
	tree = GameTree.new(p_size, p_komi)
	tree.rules = p_rules
	tree.handicap = p_handicap
	if p_handicap > 0:
		tree.root.setup_black = handicap_points(p_size, p_handicap)
		if p_komi == 6.5:
			tree.komi = 0.5
	SGF.apply_standard_header(tree)
	over = false
	result_text = ""
	ended_by_passes = false
	result_set_locally = false
	_announce()


## Standard star-point handicap placement for the sizes we support.
static func handicap_points(p_size: int, count: int) -> Array[Vector2i]:
	var stars: Array[Vector2i] = []
	match p_size:
		9:
			stars = [Vector2i(2, 2), Vector2i(6, 6), Vector2i(2, 6), Vector2i(6, 2), Vector2i(4, 4)]
		13:
			stars = [Vector2i(3, 3), Vector2i(9, 9), Vector2i(3, 9), Vector2i(9, 3), Vector2i(6, 6)]
		19:
			stars = [
				Vector2i(3, 3), Vector2i(15, 15), Vector2i(3, 15), Vector2i(15, 3),
				Vector2i(9, 9), Vector2i(3, 9), Vector2i(15, 9), Vector2i(9, 3), Vector2i(9, 15),
			]
	var out: Array[Vector2i] = []
	var take: int = clampi(count, 0, stars.size())
	for i in take:
		out.append(stars[i])
	return out


func current() -> GameNode:
	return tree.current


func board() -> Board:
	return tree.board_at(tree.current)


func turn() -> int:
	return tree.turn_at(tree.current)


func turn_number() -> int:
	return tree.path_to(tree.current).size()


## Plays for the side to move. Returns false when the move is illegal or the
## game is already over, leaving the tree untouched.
func play(x: int, y: int) -> bool:
	if not is_legal_at(x, y):
		return false
	_make_main_line(tree.play_move(turn(), x, y))
	_announce()
	return true


## A move played in the game (not a review-mode variation) is the game: it
## becomes the first child, so analysis sidelines tried at this point while
## the game was running stay sidelines and the main line is what was played.
func _make_main_line(node: GameNode) -> void:
	var parent: GameNode = node.parent if node != null else null
	if parent == null or parent.children.is_empty() or parent.children[0] == node:
		return
	parent.children.erase(node)
	parent.children.insert(0, node)
## Review-mode editing ("clicking the board in review mode adds a
## variation move"). Works after the game is over and never ends it, because a
## variation is a hypothesis, not a played game.
func add_variation(x: int, y: int) -> GameNode:
	last_error = ""
	var color: int = turn()
	var b: Board = board()
	if b.get_stone(x, y) != Board.Stone.EMPTY:
		last_error = "that point is already occupied"
		return null
	if x == b.ko_point.x and y == b.ko_point.y:
		last_error = "that would repeat the ko"
		return null
	if not b.is_legal(x, y, color):
		last_error = "that move would be suicide"
		return null
	var node: GameNode = tree.play_move(color, x, y)
	_announce()
	return node


func add_pass_variation() -> GameNode:
	var node: GameNode = tree.play_pass(turn())
	_announce()
	return node


## Drops the current node and everything below it, which is how a wrong
## variation is removed. The root can never be deleted.
func remove_current() -> bool:
	var node: GameNode = tree.current
	if node == tree.root:
		last_error = "the root of the game cannot be deleted"
		return false
	var parent: GameNode = node.parent
	if parent == null:
		return false
	parent.remove_child(node)
	tree.go_to(parent)
	_announce()
	return true


## Writes the comment box into the SGF C property of the current node.
func set_comment(text: String) -> void:
	tree.current.comment = text
	_announce()




func pass_move() -> bool:
	if over:
		return false
	_make_main_line(tree.play_pass(turn()))
	if board().consecutive_passes >= 2:
		over = true
		ended_by_passes = true
		result_text = "two passes"
		result_set_locally = true
	_announce()
	if ended_by_passes:
		game_state_changed.emit()
	return true


func resign(loser_color: int) -> void:
	if over:
		return
	over = true
	var winner: String = "B" if loser_color == Board.Stone.WHITE else "W"
	result_text = winner + "+Resign"
	tree.result = result_text
	result_set_locally = true
	game_state_changed.emit()
	_announce()


## Takes back a full move pair (two plies), or one ply when only one was played,
## and removes those nodes so a replayed game does not accumulate dead branches.
## plies overrides the count, e.g. 1 to take back only the human's move while
## the engine is still thinking about its reply.
func undo_pair(plies: int = 2) -> int:
	if tree.current == tree.root:
		return 0
	var undone: int = 0
	while undone < plies and tree.current != tree.root:
		var victim: GameNode = tree.current
		var parent: GameNode = victim.parent
		if parent == null:
			break
		parent.remove_child(victim)
		tree.go_to(parent)
		undone += 1
	over = false
	ended_by_passes = false
	if result_set_locally:
		# The result came from a resign or the two passes we just took back.
		tree.result = ""
	result_set_locally = false
	result_text = tree.result
	_announce()
	return undone


func is_legal_at(x: int, y: int) -> bool:
	last_error = ""
	if over:
		last_error = "the game is over"
		return false
	var point: Vector2i = Vector2i(x, y)
	var b: Board = board()
	if b.get_stone(x, y) != Board.Stone.EMPTY:
		last_error = "that point is already occupied"
		return false
	if x == b.ko_point.x and y == b.ko_point.y:
		last_error = "that would repeat the ko"
		return false
	if not b.is_legal(x, y, turn()):
		last_error = "that move would be suicide"
		return false
	return true


## Takes one ply back without deleting it, so you can step through the game.
func undo_step() -> bool:
	if not tree.go_back():
		return false
	_announce()
	return true


## Steps one ply forward along the main-line child.
func redo_step() -> bool:
	if not tree.go_forward():
		return false
	_announce()
	return true


func next_variation() -> bool:
	var node: GameNode = tree.current
	var parent: GameNode = node.parent
	if parent == null or parent.children.size() < 2:
		return false
	var index: int = parent.children.find(node)
	tree.go_to(parent.children[(index + 1) % parent.children.size()])
	_announce()
	return true


func previous_variation() -> bool:
	var node: GameNode = tree.current
	var parent: GameNode = node.parent
	if parent == null or parent.children.size() < 2:
		return false
	var index: int = parent.children.find(node)
	tree.go_to(parent.children[(index - 1 + parent.children.size()) % parent.children.size()])
	_announce()
	return true


## Adopts a tree loaded from a file as the game being played.
func adopt_tree(loaded: GameTree) -> void:
	tree = loaded
	tree.go_to_main_line_end()
	over = false
	result_text = tree.result
	ended_by_passes = false
	# A result read from the file stays put; undo must not silently drop it.
	result_set_locally = false
	_announce()


func move_number() -> int:
	return turn_number()

