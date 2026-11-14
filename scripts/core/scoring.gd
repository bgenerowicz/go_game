class_name Scoring
extends RefCounted

## End-of-game result reporting (PLAN 6.1).
##
## The primary path is the engine estimate: after two passes we ask for an
## analysis with ownership and report rootInfo.scoreLead, rounded to the nearest
## 0.5. scoreLead is from Black's point of view because the config sets
## reportAnalysisWinratesAs = BLACK.
##
## When no engine is available (a two-human game with the engine switched off)
## area_count() gives a rough stone-plus-dame count so the game still ends with
## a number. It is labelled as an estimate by the caller.

const ENGINE_SUFFIX: String = " (engine estimate)"

## Sentinel in the owner map returned by area_count(). The map is a
## PackedByteArray, so it cannot hold -1; 0 (= Stone.EMPTY) means "claimed by
## nobody", which covers dame and the stone points themselves. Callers that need
## to tell those apart read board.grid.
const NEUTRAL: int = 0


## Rounds to the nearest half point, which is what SGF results use.
static func round_half(value: float) -> float:
	return round(value * 2.0) / 2.0


## "B+3.5" / "W+2.0" / "Draw" from a Black-perspective score lead.
static func result_from_score_lead(score_lead: float) -> String:
	var rounded: float = round_half(score_lead)
	if is_zero_approx(rounded):
		return "Draw"
	if rounded > 0.0:
		return "B+%.1f" % rounded
	return "W+%.1f" % absf(rounded)


## The result string with the engine-estimate note, as shown to the player.
static func engine_result(score_lead: float) -> String:
	var text: String = result_from_score_lead(score_lead)
	if text == "Draw":
		return text + ENGINE_SUFFIX
	return text + ENGINE_SUFFIX


## A candidate move list from moveInfos, keeping only entries with at least
## `min_fraction` of the root visits (PLAN 6.2 candidate rules).
static func significant_moves(analysis: Dictionary, min_fraction: float = 0.01) -> Array:
	var visits: int = int(analysis.get("visits", 0))
	var out: Array = []
	if visits <= 0:
		return out
	for info in (analysis.get("moves", []) as Array):
		var entry: Dictionary = info as Dictionary
		if int(entry.get("visits", 0)) >= int(ceil(float(visits) * min_fraction)):
			out.append(entry)
	return out


## Rough area count for engine-less games: stones on the board plus empty points
## reached only by one colour. Territory under a neutral reading (dame counts
## for nobody), so it is close to Chinese rules without the komi subtleties.
static func area_count(board: Board, komi: float) -> Dictionary:
	var size: int = board.size
	var owner: PackedByteArray = PackedByteArray()
	owner.resize(size * size)
	owner.fill(NEUTRAL)
	# Flood each empty region; it belongs to a colour only when every bordering
	# stone is that colour.
	var visited: PackedByteArray = PackedByteArray()
	visited.resize(size * size)
	var black: int = board.stone_count(Board.Stone.BLACK)
	var white: int = board.stone_count(Board.Stone.WHITE)
	for start in range(size * size):
		if board.grid[start] != Board.Stone.EMPTY or visited[start] != 0:
			continue
		var region: Array[int] = [start]
		var seen: Array[int] = [start]
		visited[start] = 1
		var touches_black: bool = false
		var touches_white: bool = false
		var index: int = 0
		while index < seen.size():
			var cell: int = seen[index]
			index += 1
			var cx: int = cell % size
			var cy: int = cell / size
			for n in board.neighbors(cx, cy):
				var ni: int = n.y * size + n.x
				var stone: int = board.grid[ni]
				if stone == Board.Stone.EMPTY:
					if visited[ni] == 0:
						visited[ni] = 1
						seen.append(ni)
						region.append(ni)
				elif stone == Board.Stone.BLACK:
					touches_black = true
				else:
					touches_white = true
		var claim: int = NEUTRAL
		if touches_black and not touches_white:
			claim = Board.Stone.BLACK
			black += region.size()
		elif touches_white and not touches_black:
			claim = Board.Stone.WHITE
			white += region.size()
		for cell in region:
			owner[cell] = claim
	var black_total: float = float(black)
	var white_total: float = float(white) + komi
	return {
		"black": black_total,
		"white": white_total,
		"score_lead": black_total - white_total,
		"owner": owner,
		"result": result_from_score_lead(black_total - white_total),
	}
