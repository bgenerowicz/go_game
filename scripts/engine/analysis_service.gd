extends Node

## Builds KataGo analysis queries, routes the answers back to the node they
## belong to, and caches results on that node. Autoload name: "Analysis".

signal analysis_updated(node: GameNode)
signal review_progress(done: int, total: int)
## One main-line position of a running review has its final answer.
signal review_turn_analysed(node: GameNode)
signal review_finished
signal review_failed(message: String)
signal live_updated(node: GameNode)

const DEFAULT_REVIEW_VISITS: int = 200
const DEFAULT_LIVE_VISITS: int = 2000
const LIVE_REPORT_EVERY: float = 0.3

var _id_to_node: Dictionary = {}     # query id -> GameNode
var _id_to_tree: Dictionary = {}     # query id -> GameTree
var _id_to_turns: Dictionary = {}    # query id -> Array[int] turns analysed
var _live_id: String = ""
var _live_node: GameNode = null
var _counter: int = 0
var _review_id: String = ""
var _review_total: int = 0
var _review_done: int = 0

## The engine process. In the running game this is the "KataGo" autoload, found
## by name at _ready. A headless script (tests, the milestone checks) creates its
## own process node and assigns it here before use, which is why the engine is
## reached through this variable rather than the autoload identifier: a script
## that names an autoload cannot even be loaded by --script runs.
var engine: Node = null


func _ready() -> void:
	if engine == null:
		engine = get_node_or_null("/root/KataGo")
	if engine != null and not engine.response_received.is_connected(_on_response):
		engine.response_received.connect(_on_response)


## Wires an engine process node in explicitly. Headless scripts and tests build
## their own process instead of relying on the autoload, and _ready() has already
## run by then, so the signal has to be connected here.
func use_engine(p_engine: Node) -> void:
	if engine != null and engine != p_engine and engine.response_received.is_connected(_on_response):
		engine.response_received.disconnect(_on_response)
	engine = p_engine
	if engine != null and not engine.response_received.is_connected(_on_response):
		engine.response_received.connect(_on_response)


func _next_id(prefix: String) -> String:
	_counter += 1
	return "%s%d" % [prefix, _counter]


## Requests analysis of one node. opts: include_ownership, include_policy,
## priority, human_profile. Returns "" when the engine is not usable.
func request(node: GameNode, visits: int, opts: Dictionary = {}) -> String:
	if node == null or engine == null or not engine.running:
		return ""
	var tree: GameTree = opts.get("tree") as GameTree
	if tree == null:
		return ""
	var query: Dictionary = _build_query(tree, node, visits, opts)
	if query.is_empty():
		return ""
	var id: String = _next_id("a")
	_id_to_node[id] = node
	_id_to_tree[id] = tree
	_id_to_turns[id] = [tree.move_count_to(node)]
	query["id"] = id
	if not engine.send(query):
		_id_to_node.erase(id)
		return ""
	return id


## One query covering every turn of the main line (PLAN 5.3).
func request_review(tree: GameTree, visits: int = DEFAULT_REVIEW_VISITS) -> String:
	if tree == null or engine == null or not engine.running:
		return ""
	var line: Array[GameNode] = tree.main_line()
	var turns: Array[int] = []
	# Turn 0 is the position before the first move. It is included so the graph
	# has no hole at the start and every main-line node gets a result.
	for i in range(0, line.size()):
		turns.append(i)
	if turns.is_empty():
		return ""
	var query: Dictionary = _build_query(tree, line[line.size() - 1], visits, {
		"include_ownership": true,
		"priority": 0,
	})
	if query.is_empty():
		return ""
	# analyzeTurns is 0-based over the whole move list, turn 0 being the empty
	# board. Skip it: the empty position is not worth reviewing.
	query["analyzeTurns"] = turns
	var id: String = _next_id("r")
	_id_to_node[id] = line[line.size() - 1]
	_id_to_turns[id] = turns
	# Without this the reply is dropped in _on_response, which needs the tree to
	# map a turn number back to a node.
	_id_to_tree[id] = tree
	_review_id = id
	_review_total = turns.size()
	# A second review in the same session must count from zero, or it would
	# report "finished" after its first answer.
	_review_done = 0
	query["id"] = id
	if not engine.send(query):
		_id_to_node.erase(id)
		_review_id = ""
		return ""
	return id


## Live analysis of the current position, replacing any previous live query.
func request_live(tree: GameTree, node: GameNode, visits: int = DEFAULT_LIVE_VISITS) -> String:
	if node == null or engine == null or not engine.running:
		return ""
	if _live_id != "" and _live_node == node:
		return _live_id
	cancel_live()
	var id: String = request(node, visits, {
		"tree": tree,
		"include_ownership": true,
		"priority": 10,
		"report_during_search_every": LIVE_REPORT_EVERY,
	})
	if id != "":
		_live_id = id
		_live_node = node
	return id


func cancel_live() -> void:
	if _live_id == "":
		return
	if engine != null and engine.running:
		engine.send({"id": _next_id("x"), "action": "terminate", "terminateId": _live_id})
	_live_id = ""
	_live_node = null


## The position the current live search is about, or null.
func live_node() -> GameNode:
	return _live_node if _live_id != "" else null


## True while a full-game review query is still being answered.
func is_reviewing() -> bool:
	return _review_id != ""


func cancel_review() -> void:
	if _review_id == "" or engine == null or not engine.running:
		return
	engine.send({"id": _next_id("x"), "action": "terminate", "terminateId": _review_id})
	_review_id = ""


func clear() -> void:
	cancel_live()
	cancel_review()
	_id_to_node.clear()
	_id_to_turns.clear()


func _build_query(tree: GameTree, node: GameNode, visits: int, opts: Dictionary) -> Dictionary:
	var query: Dictionary = {
		"rules": engine_rules_name(tree.rules),
		"komi": tree.komi,
		"boardXSize": tree.size,
		"boardYSize": tree.size,
		"maxVisits": visits,
		"analysisPVLen": int(opts.get("pv_len", 15)),
		"includeOwnership": bool(opts.get("include_ownership", false)),
		"includePolicy": bool(opts.get("include_policy", false)),
		"priority": int(opts.get("priority", 0)),
	}
	if opts.has("report_during_search_every"):
		query["reportDuringSearchEvery"] = float(opts["report_during_search_every"])
	var profile: String = String(opts.get("human_profile", ""))
	if profile != "":
		# PLAN 4.3: humanSLProfile must be inside overrideSettings; on the outer
		# object KataGo silently ignores it.
		query["overrideSettings"] = {"humanSLProfile": profile}
	var setup: Array = tree.setup_stones_with_colors(node)
	if not setup.is_empty():
		query["initialStones"] = setup
	# Setup stones are replayed as placements: the engine never reads the SGF.
	var moves: Array = tree.moves_with_colors(node)
	query["moves"] = moves
	# initialPlayer is who moves at turn 0, the position before any move: the
	# colour of the first move, or (with no moves yet) whoever is to play now.
	# It used to be the player to move at `node`, which for a full-game review
	# is the end of the game: when White had the last turn, turn 0 was analysed
	# as an empty board with White to play (komi plus the first move), and the
	# graph started at about "White 100%".
	if not moves.is_empty():
		query["initialPlayer"] = String((moves[0] as Array)[0])
	else:
		query["initialPlayer"] = "B" if tree.turn_at(node) == Board.Stone.BLACK else "W"
	return query


## SGF RU[] values are not KataGo rule names. The accepted set was verified
## against the bundled KataGo v1.18.1: only "chinese", "aga", "korean",
## "japanese", "new-zealand", "ing" and "tromp-taylor" parse. Anything else,
## including "chinese-1", "chinese-2020", "north-american", "ing-asi", "area",
## "stone" and "zalgler", fails the whole query with "Could not parse rules".
## So every SGF spelling collapses onto one of those seven names, and anything
## unknown falls back to Japanese, which is the app default anyway.
static func engine_rules_name(rules: String) -> String:
	var key: String = rules.strip_edges().to_lower().replace(" ", "-")
	match key:
		"chinese", "chinese-1", "chinese-2020", "area", "zalgler", "isa":
			return "chinese"
		"aga":
			return "aga"
		"korean":
			return "korean"
		"new-zealand", "nz":
			return "new-zealand"
		"japanese", "nippon", "bga":
			return "japanese"
		"tromp-taylor", "tromp_taylor", "tromp":
			return "tromp-taylor"
		"ing", "ing-asi", "ing-2020":
			return "ing"
		_:
			return "japanese"


## Responses ----------------------------------------------------------

func _on_response(response: Dictionary) -> void:
	if response.has("error"):
		push_warning("KataGo error: %s" % String(response["error"]))
		return
	if response.has("warning"):
		push_warning("KataGo warning (%s): %s" % [String(response.get("field", "")), String(response["warning"])])
	var id: String = String(response.get("id", ""))
	if id == "" or not _id_to_node.has(id):
		return  # a reply to something we already forgot
	if bool(response.get("noResults", false)):
		return
	var node: GameNode = _id_to_node[id] as GameNode
	var tree: GameTree = _id_to_tree.get(id) as GameTree
	if node == null or tree == null:
		_id_to_node.erase(id)
		return
	var target: GameNode = _node_for_turn(tree, node, id, int(response.get("turnNumber", -1)))
	if target == null:
		return
	var stored: bool = _store(target, response)
	if id == _live_id:
		live_updated.emit(target)
	elif stored:
		analysis_updated.emit(target)
	if id == _review_id:
		# Only final per-turn answers count; a partial (isDuringSearch) answer
		# would otherwise make the review finish early.
		if not bool(response.get("isDuringSearch", false)):
			_review_done += 1
			review_turn_analysed.emit(target)
			review_progress.emit(_review_done, _review_total)
			if _review_done >= _review_total:
				_review_id = ""
				review_finished.emit()


## A multi-turn (review) query answers for every turn of the main line, so the
## turn number picks the node. A single-node query answers only for that node,
## which may be off the main line, so use the stored node directly.
func _node_for_turn(tree: GameTree, node: GameNode, id: String, turn_number: int) -> GameNode:
	var turns: Array = _id_to_turns.get(id, []) as Array
	if turns.size() <= 1:
		return node
	return tree.find_by_move_index(turn_number)


## Caches a result on the node. Keeps the result with the most visits and never
## overwrites it with a weaker one (PLAN 5.3). Returns false when discarded.
func _store(node: GameNode, response: Dictionary) -> bool:
	var root_info: Dictionary = response.get("rootInfo", {}) as Dictionary
	var visits: int = int(root_info.get("visits", 0))
	var existing: Dictionary = node.analysis
	if not existing.is_empty() and int(existing.get("visits", -1)) >= visits:
		return false
	var moves: Array = []
	for info in (response.get("moveInfos", []) as Array):
		var entry: Dictionary = info as Dictionary
		moves.append({
			"move": String(entry.get("move", "")),
			"visits": int(entry.get("visits", 0)),
			"winrate": float(entry.get("winrate", 0.0)),
			"score_lead": float(entry.get("scoreLead", 0.0)),
			"prior": float(entry.get("prior", 0.0)),
			"human_prior": float(entry.get("humanPrior", 0.0)),
			"pv": (entry.get("pv", []) as Array),
		})
	node.analysis = {
		"visits": visits,
		"winrate": float(root_info.get("winrate", 0.0)),
		"score_lead": float(root_info.get("scoreLead", 0.0)),
		"current_player": String(root_info.get("currentPlayer", "")),
		"moves": moves,
		"ownership": (response.get("ownership", []) as Array),
		"human_policy": (response.get("humanPolicy", []) as Array),
		"policy": (response.get("policy", []) as Array),
		"turn_number": int(response.get("turnNumber", -1)),
	}
	return true

