class_name SGF
extends RefCounted

## SGF reader / writer. Supports the properties the app models
## (GM FF SZ KM RU HA AB AW PB PW BR WR RE DT C B W) and nested variations.
## Anything else is kept verbatim in extra_properties and written back unchanged.

## Properties the reader maps onto the tree/node model. Everything else round-trips
## verbatim through extra_properties, including GM/FF/DT/BR/WR which the app does
## not need to interpret itself.
const MODELLED_ROOT: Array[String] = ["SZ", "KM", "RU", "HA", "PB", "PW", "RE", "C", "AB", "AW"]
const MODELLED_NODE: Array[String] = ["B", "W", "C", "AB", "AW"]


static func parse_text(text: String) -> Dictionary:
	var sgf: SGF = SGF.new()
	return sgf.read(text)


static func parse_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "tree": null, "error": "file not found: " + path}
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "tree": null, "error": "cannot open " + path}
	var text: String = file.get_as_text()
	file.close()
	var result: Dictionary = parse_text(text)
	if result["ok"]:
		result["path"] = path
	return result


## ---------------------------------------------------------------- reader

var source: String = ""
var pos: int = 0
var error: String = ""


func read(text: String) -> Dictionary:
	source = text
	pos = 0
	error = ""
	var tree: GameTree = GameTree.new()
	_skip_space()
	if _peek() != "(":
		return _fail_result("SGF must start with '('")
	_parse_game_tree(tree, null)
	if failed():
		return {"ok": false, "tree": null, "error": error}
	_skip_space()
	if pos < source.length():
		return _fail_result("unexpected trailing text at offset %d" % pos)
	return {"ok": true, "tree": tree, "error": ""}


func _parse_game_tree(tree: GameTree, parent: GameNode) -> void:
	if failed():
		return
	if _peek() != "(":
		_fail("expected '(' at offset %d" % pos)
		return
	pos += 1
	_parse_sequence(tree, parent)
	if failed():
		return
	_skip_space()
	if _peek() != ")":
		_fail("expected ')' at offset %d" % pos)
		return
	pos += 1


func _parse_sequence(tree: GameTree, parent: GameNode) -> void:
	if failed():
		return
	_skip_space()
	if _peek() != ";":
		_fail("expected a node starting with ';' at offset %d" % pos)
		return
	pos += 1
	var props: Dictionary = _parse_properties()
	if failed():
		return
	_skip_space()
	var node: GameNode
	if parent == null:
		node = tree.root
		_apply_root_properties(tree, props)
	else:
		node = GameNode.new()
		node.move = _move_of(props, tree.size)
		if failed():
			return
		_apply_node_properties(node, props, tree.size)
		parent.add_child(node)
	# Variations attached to this node.
	while _peek() == "(":
		_parse_game_tree(tree, node)
		if failed():
			return
		_skip_space()
	# Some files keep the main line going with another ';' instead of nesting.
	if _peek() == ";":
		_parse_sequence(tree, node)


func _parse_properties() -> Dictionary:
	var props: Dictionary = {}
	while true:
		_skip_space()
		var c: String = _peek()
		if c < "A" or c > "Z":
			break
		var id: String = _read_property_id()
		_skip_space()
		if _peek() != "[":
			_fail("property %s needs a value at offset %d" % [id, pos])
			return props
		var values: Array = []
		while _peek() == "[":
			pos += 1
			values.append(_read_value())
			if failed():
				return props
			_skip_space()
		props[id] = values
	return props


func _read_property_id() -> String:
	var id: String = ""
	while pos < source.length():
		var c: String = source[pos]
		if (c >= "A" and c <= "Z") or (c >= "0" and c <= "9"):
			id += c
			pos += 1
		else:
			break
	return id


## Reads one bracketed value, unescaping \] and \\ and dropping soft line breaks.
func _read_value() -> String:
	var out: String = ""
	while pos < source.length():
		var c: String = source[pos]
		if c == "]":
			pos += 1
			return out
		if c == "\\":
			pos += 1
			if pos >= source.length():
				break
			var next: String = source[pos]
			if next == "\n":
				pos += 1  # soft line break: the newline is not part of the value
			else:
				out += next
				pos += 1
			continue
		out += c
		pos += 1
	_fail("unterminated value at offset %d" % pos)
	return ""


func _apply_root_properties(tree: GameTree, props: Dictionary) -> void:
	# SZ first: every later conversion depends on the board size.
	if props.has("SZ"):
		var parsed_size: int = int(String(props["SZ"][0]).strip_edges())
		if not Coords.is_valid_size(parsed_size):
			_fail("unsupported board size %d (need 9, 13 or 19)" % parsed_size)
			return
		tree.size = parsed_size
	if props.has("KM"):
		tree.komi = float(String(props["KM"][0]).strip_edges())
	if props.has("RU"):
		tree.rules = String(props["RU"][0]).strip_edges()
	if props.has("HA"):
		tree.handicap = int(String(props["HA"][0]).strip_edges())
	if props.has("PB"):
		tree.black_name = String(props["PB"][0])
	if props.has("PW"):
		tree.white_name = String(props["PW"][0])
	if props.has("RE"):
		tree.result = String(props["RE"][0])
	tree.root.setup_black = _points(props.get("AB", []), tree.size)
	tree.root.setup_white = _points(props.get("AW", []), tree.size)
	if props.has("C"):
		tree.root.comment = String(props["C"][0])
	for id in props:
		var key: String = String(id)
		if MODELLED_ROOT.has(key):
			continue
		tree.extra_properties[key] = props[id]


func _apply_node_properties(node: GameNode, props: Dictionary, p_size: int) -> void:
	if props.has("C"):
		node.comment = String(props["C"][0])
	node.setup_black = _points(props.get("AB", []), p_size)
	node.setup_white = _points(props.get("AW", []), p_size)
	for id in props:
		var key: String = String(id)
		if MODELLED_NODE.has(key):
			continue
		node.extra_properties[key] = props[id]


func _move_of(props: Dictionary, _p_size: int) -> Variant:
	var has_black: bool = props.has("B")
	var has_white: bool = props.has("W")
	if has_black and has_white:
		_fail("a node has both B[] and W[] at offset %d" % pos)
		return null
	if not has_black and not has_white:
		return null
	var color: int = Board.Stone.BLACK if has_black else Board.Stone.WHITE
	var raw: String = String((props["B"] if has_black else props["W"])[0])
	if Coords.is_sgf_pass(raw):
		return {"color": color, "x": -1, "y": -1}
	var point: Vector2i = Coords.from_sgf(raw)
	if point == Coords.INVALID:
		_fail("bad SGF coordinate '%s' at offset %d" % [raw, pos])
		return null
	return {"color": color, "x": point.x, "y": point.y}


func _points(values: Array, _p_size: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for raw in values:
		var point: Vector2i = Coords.from_sgf(String(raw))
		if point == Coords.INVALID:
			continue
		out.append(point)
	return out


func _skip_space() -> void:
	while pos < source.length():
		var c: String = source[pos]
		if c == " " or c == "\t" or c == "\n" or c == "\r":
			pos += 1
		else:
			return


func _peek() -> String:
	if pos >= source.length():
		return ""
	return source[pos]


func failed() -> bool:
	return error != ""


func _fail(message: String) -> void:
	if error == "":
		error = message


func _fail_result(message: String) -> Dictionary:
	_fail(message)
	return {"ok": false, "tree": null, "error": message}


## ---------------------------------------------------------------- writer

static func serialise(tree: GameTree) -> String:
	var out: String = "(\n"
	out += _write_sequence(tree, tree.root)
	out += ")\n"
	return out


static func save_file(path: String, tree: GameTree) -> bool:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("cannot write %s (error %d)" % [path, FileAccess.get_open_error()])
		return false
	file.store_string(serialise(tree))
	file.close()
	return true


## A single child continues the sequence inline; two or more children each get
## their own parentheses so they stay siblings of this node.
static func _write_sequence(tree: GameTree, node: GameNode) -> String:
	var out: String = ";"
	if node.is_root():
		out += _root_properties(tree)
	else:
		out += _node_properties(node, tree.size)
	out += "\n"
	if node.children.size() == 1:
		out += _write_sequence(tree, node.children[0])
	else:
		for child in node.children:
			out += "(\n" + _write_sequence(tree, child) + ")\n"
	return out


## Gives a tree built by the app the SGF headers a reader expects. Parsed files
## keep whatever they had, so this is only for new games.
static func apply_standard_header(tree: GameTree) -> void:
	if not tree.extra_properties.has("GM"):
		tree.extra_properties["GM"] = ["4"]
	if not tree.extra_properties.has("FF"):
		tree.extra_properties["FF"] = ["4"]
	if not tree.extra_properties.has("CA"):
		tree.extra_properties["CA"] = ["UTF-8"]


static func _root_properties(tree: GameTree) -> String:
	var out: String = ""
	var extras: Dictionary = tree.extra_properties
	# GM/FF are written only when the source had them, so a file that omits them
	# round-trips unchanged. New games get them via apply_standard_header().
	if extras.has("GM"):
		out += _write_values("GM", extras["GM"])
	if extras.has("FF"):
		out += _write_values("FF", extras["FF"])
	out += "SZ[%d]" % tree.size
	out += "KM[%s]" % _number(tree.komi)
	if tree.rules != "":
		out += "RU[%s]" % _escape(tree.rules)
	if tree.handicap > 0:
		out += "HA[%d]" % tree.handicap
	if not tree.root.setup_black.is_empty():
		out += _write_points("AB", tree.root.setup_black, tree.size)
	if not tree.root.setup_white.is_empty():
		out += _write_points("AW", tree.root.setup_white, tree.size)
	if tree.black_name != "":
		out += "PB[%s]" % _escape(tree.black_name)
	if tree.white_name != "":
		out += "PW[%s]" % _escape(tree.white_name)
	if tree.result != "":
		out += "RE[%s]" % _escape(tree.result)
	if tree.root.comment != "":
		out += "C[%s]" % _escape(tree.root.comment)
	for id in extras:
		var key: String = String(id)
		if MODELLED_ROOT.has(key) or key == "GM" or key == "FF":
			continue  # GM/FF are written explicitly above
		out += _write_values(key, extras[id])
	return out


static func _node_properties(node: GameNode, p_size: int) -> String:
	var out: String = ""
	if node.move != null:
		var id: String = "B" if int(node.move["color"]) == Board.Stone.BLACK else "W"
		var point: Vector2i = node.move_point()
		out += "%s[%s]" % [id, Coords.to_sgf(point.x, point.y)]
	if node.comment != "":
		out += "C[%s]" % _escape(node.comment)
	if not node.setup_black.is_empty():
		out += _write_points("AB", node.setup_black, p_size)
	if not node.setup_white.is_empty():
		out += _write_points("AW", node.setup_white, p_size)
	for id in node.extra_properties:
		out += _write_values(String(id), node.extra_properties[String(id)])
	return out


static func _write_values(id: String, values: Array) -> String:
	var out: String = id
	for value in values:
		out += "[%s]" % _escape(String(value))
	return out


## SGF point letters are size independent, so the size is only kept for symmetry.
static func _write_points(id: String, points: Array[Vector2i], _p_size: int) -> String:
	var out: String = id
	for p in points:
		out += "[%s]" % Coords.to_sgf(p.x, p.y)
	return out


static func _escape(value: String) -> String:
	return value.replace("\\", "\\\\").replace("]", "\\]")


static func _number(value: float) -> String:
	if is_equal_approx(value, floor(value)):
		return "%d" % int(value)
	return String.num(value, 2)

