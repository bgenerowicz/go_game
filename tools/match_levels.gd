extends SceneTree

## Plays two opponent levels against each other and records the results.
##
## Run with (all arguments optional):
##   godot --headless --path . --script res://tools/match_levels.gd -- \
##       --a=rank_beginner --b=rank_20k --games=100 --size=9 --komi=6.5 \
##       --visits=60 --parallel=4 --out=match.csv
##
## Each game is played the way the app plays its opponent: a KataGo query with
## the level's human profile, then AiPlayer.choose_move(). Colours alternate
## (game 1: A is Black, game 2: B is Black, ...). A game ends by two passes,
## a resignation, or the move limit, and is then scored by the engine without a
## human profile (score lead rounded to 0.5, as the app scores games).
## Results go to a CSV, one row per game, and a summary is printed at the end.

var opts: Dictionary = {
	"a": "rank_beginner", "b": "rank_20k", "games": 100, "size": 9, "komi": 6.5,
	"rules": "japanese", "visits": 60, "score_visits": 400, "parallel": 4,
	"max_moves": 0, "out": "match.csv",
}

var proc: Node = null
var analysis: Node = null
var games: Array = []        # live games, see _new_game()
var next_index: int = 0
var results: Array = []      # finished games
var started_ms: int = 0
var finished: bool = false


func _init() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--") and arg.contains("="):
			var key: String = arg.substr(2).get_slice("=", 0)
			var value: String = arg.get_slice("=", 1)
			if opts.has(key):
				opts[key] = value.to_int() if typeof(opts[key]) == TYPE_INT \
					else (value.to_float() if typeof(opts[key]) == TYPE_FLOAT else value)
	if int(opts["max_moves"]) <= 0:
		opts["max_moves"] = int(opts["size"]) * int(opts["size"]) * 2
	print("=== match: %s vs %s, %d games on %dx%d, komi %s, %d visits/move ===" % [
		opts["a"], opts["b"], opts["games"], opts["size"], opts["size"], opts["komi"], opts["visits"]])
	proc = load("res://scripts/engine/katago_process.gd").new()
	root.add_child(proc)
	if not proc.is_available():
		print("engine files missing: ", proc.missing_files())
		quit(1)
		return
	# Network buffers sized to the board, and more analysis threads so the
	# parallel games are evaluated side by side.
	proc.extra_args = PackedStringArray(["-override-config",
		"maxBoardXSizeForNNBuffer=%d,maxBoardYSizeForNNBuffer=%d,requireMaxBoardSize=true,"
			% [opts["size"], opts["size"]]
		+ "numAnalysisThreads=%d,numSearchThreadsPerAnalysisThread=4,nnMaxBatchSize=32"
			% maxi(2, int(opts["parallel"]))])
	analysis = load("res://scripts/engine/analysis_service.gd").new()
	root.add_child(analysis)
	analysis.use_engine(proc)
	analysis.analysis_updated.connect(_on_analysis)
	proc.engine_ready.connect(_on_ready)
	proc.engine_failed.connect(func(msg: String) -> void:
		print("ENGINE FAILED: ", msg)
		_write_and_quit())
	if not proc.start_engine():
		print("could not start the engine: ", proc.start_error())
		quit(1)


func _on_ready() -> void:
	started_ms = Time.get_ticks_msec()
	for i in mini(int(opts["parallel"]), int(opts["games"])):
		_start_next()


func _start_next() -> void:
	if next_index >= int(opts["games"]):
		if games.is_empty() and not finished:
			_write_and_quit()
		return
	var index: int = next_index
	next_index += 1
	var a_is_black: bool = index % 2 == 0
	var flow: GameFlow = GameFlow.new()
	flow.start(int(opts["size"]), float(opts["komi"]), String(opts["rules"]), 0)
	var game: Dictionary = {
		"index": index + 1, "flow": flow, "a_is_black": a_is_black,
		"black": _player(String(opts["a"] if a_is_black else opts["b"])),
		"white": _player(String(opts["b"] if a_is_black else opts["a"])),
		"phase": "play", "ended": "", "moves": 0,
	}
	games.append(game)
	_ask(game)


func _player(profile: String) -> AiPlayer:
	var player: AiPlayer = AiPlayer.new()
	player.configure(profile, int(opts["visits"]))
	return player


func _ask(game: Dictionary) -> void:
	var flow: GameFlow = game["flow"]
	var player: AiPlayer = game["black"] if flow.turn() == Board.Stone.BLACK else game["white"]
	if player.request_move(analysis, flow.tree, flow.current()) == "":
		print("request failed in game %d" % game["index"])
		_end(game, "error")


func _on_analysis(node: GameNode) -> void:
	for game in games:
		var flow: GameFlow = game["flow"]
		if node != flow.current():
			continue
		if String(game["phase"]) == "score":
			if int((node.analysis as Dictionary).get("visits", 0)) >= int(opts["score_visits"]) * 0.95:
				_record(game, float(node.analysis.get("score_lead", 0.0)))
			return
		_move(game, node)
		return


func _move(game: Dictionary, node: GameNode) -> void:
	var flow: GameFlow = game["flow"]
	var color: int = flow.turn()
	var player: AiPlayer = game["black"] if color == Board.Stone.BLACK else game["white"]
	var choice: Dictionary = player.choose_move(node.analysis, flow.tree.size, color,
		flow.move_number() + 1, not node.is_root() and node.is_pass())
	if bool(choice["resign"]):
		flow.resign(color)
		_end(game, "resign")
		return
	var move: String = String(choice["move"])
	var ok: bool = false
	if move == Coords.PASS:
		ok = flow.pass_move()
	elif move != "":
		var p: Vector2i = Coords.from_gtp(move, flow.tree.size)
		ok = p != Coords.INVALID and flow.play(p.x, p.y)
	if not ok:
		# An illegal offer (rare: local ko rules) is treated as a pass.
		flow.pass_move()
	game["moves"] = flow.move_number()
	if flow.over:
		_end(game, "passes")
	elif flow.move_number() >= int(opts["max_moves"]):
		_end(game, "move limit")
	else:
		_ask(game)


## Resignations are decided; everything else is counted by the engine.
func _end(game: Dictionary, how: String) -> void:
	game["ended"] = how
	var flow: GameFlow = game["flow"]
	if how == "resign":
		var loser_black: bool = flow.tree.result.begins_with("W+")
		_record(game, -1000.0 if loser_black else 1000.0)
		return
	if how == "error":
		_record(game, 0.0)
		return
	game["phase"] = "score"
	analysis.request(flow.current(), int(opts["score_visits"]),
		{"tree": flow.tree, "include_ownership": true})


func _record(game: Dictionary, black_lead: float) -> void:
	games.erase(game)
	var lead: float = Scoring.round_half(black_lead)
	var black_won: bool = lead > 0.0
	var a_won: bool = black_won == bool(game["a_is_black"]) and lead != 0.0
	var result: String = "B+R" if black_lead >= 1000.0 else ("W+R" if black_lead <= -1000.0 \
		else Scoring.result_from_score_lead(lead))
	results.append({
		"game": game["index"], "a_colour": "B" if game["a_is_black"] else "W",
		"winner": "draw" if lead == 0.0 else (String(opts["a"]) if a_won else String(opts["b"])),
		"result": result, "moves": game["moves"], "ended": game["ended"],
		"a_won": a_won, "draw": lead == 0.0, "a_black": bool(game["a_is_black"]),
	})
	var a_wins: int = results.filter(func(r): return bool(r["a_won"])).size()
	print("game %3d: %-14s won (%s, %d moves, %s)   %s %d / %d" % [game["index"],
		results.back()["winner"], result, game["moves"], game["ended"], opts["a"], a_wins, results.size()])
	_start_next()


func _write_and_quit() -> void:
	finished = true
	var out: String = String(opts["out"])
	var file: FileAccess = FileAccess.open(out, FileAccess.WRITE)
	if file != null:
		file.store_line("game,%s_colour,winner,result,moves,ended" % opts["a"])
		results.sort_custom(func(x, y): return int(x["game"]) < int(y["game"]))
		for r in results:
			file.store_line("%d,%s,%s,%s,%d,%s" % [r["game"], r["a_colour"], r["winner"],
				r["result"], r["moves"], r["ended"]])
		file.close()
	var n: int = results.size()
	var a_wins: int = results.filter(func(r): return bool(r["a_won"])).size()
	var draws: int = results.filter(func(r): return bool(r["draw"])).size()
	var a_black: Array = results.filter(func(r): return bool(r["a_black"]))
	var a_white: Array = results.filter(func(r): return not bool(r["a_black"]))
	var black_wins: int = results.filter(func(r):
		return not bool(r["draw"]) and bool(r["a_won"]) == bool(r["a_black"])).size()
	print("")
	print("=== %d games in %.1f min ===" % [n, (Time.get_ticks_msec() - started_ms) / 60000.0])
	print("%s: %d wins (%.0f%%)   %s: %d wins (%.0f%%)   draws: %d" % [opts["a"], a_wins,
		100.0 * a_wins / maxi(1, n), opts["b"], n - a_wins - draws,
		100.0 * (n - a_wins - draws) / maxi(1, n), draws])
	print("%s as Black: %d/%d   as White: %d/%d   Black won %d of %d" % [opts["a"],
		a_black.filter(func(r): return bool(r["a_won"])).size(), a_black.size(),
		a_white.filter(func(r): return bool(r["a_won"])).size(), a_white.size(), black_wins, n])
	print("results written to ", ProjectSettings.globalize_path(out) if out.begins_with("res://") \
		or out.begins_with("user://") else out)
	proc.stop_engine()
	quit(0)
