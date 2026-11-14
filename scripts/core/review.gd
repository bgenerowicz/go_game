class_name Review
extends RefCounted

## Mistake classification over an analysed game tree (PLAN 6.2).
##
## All scores are Black-perspective (the engine is configured with
## reportAnalysisWinratesAs = BLACK). For the move that leads from turn t to
## turn t+1:
##     loss = (score[t] - score[t+1]) * (1 if the mover is Black else -1)
## so a positive loss always means the player who moved gave points away.

const KIND_NONE: String = "none"
const KIND_INACCURACY: String = "inaccuracy"
const KIND_MISTAKE: String = "mistake"
const KIND_BLUNDER: String = "blunder"

## Point thresholds. Settings may override them.
var inaccuracy_at: float = 2.0
var mistake_at: float = 5.0
var blunder_at: float = 10.0

var tree: GameTree = null
var _mistakes: Array = []
var _mistakes_for_turns: int = -1


func _init(p_tree: GameTree = null) -> void:
	tree = p_tree


static func loss_for_move(score_before: float, score_after: float, mover: int) -> float:
	if mover == Board.Stone.BLACK:
		return score_before - score_after
	return score_after - score_before


## The first band the loss reaches, or "none" below the inaccuracy threshold.
func classify_loss(loss: float) -> String:
	if loss >= blunder_at:
		return KIND_BLUNDER
	if loss >= mistake_at:
		return KIND_MISTAKE
	if loss >= inaccuracy_at:
		return KIND_INACCURACY
	return KIND_NONE


static func severity_rank(kind: String) -> int:
	match kind:
		KIND_BLUNDER:
			return 3
		KIND_MISTAKE:
			return 2
		KIND_INACCURACY:
			return 1
		_:
			return 0


static func color_name(color: int) -> String:
	return "Black" if color == Board.Stone.BLACK else "White"


func has_analysis(node: GameNode) -> bool:
	return node != null and not node.analysis.is_empty() \
		and int(node.analysis.get("visits", 0)) > 0


## How many main-line turns (excluding turn 0) carry analysis.
func analysed_turns() -> int:
	if tree == null:
		return 0
	var done: int = 0
	for node in tree.main_line().slice(1):
		if has_analysis(node):
			done += 1
	return done


func main_line_turns() -> int:
	if tree == null:
		return 0
	return maxi(0, tree.main_line().size() - 1)


func is_complete() -> bool:
	return main_line_turns() > 0 and analysed_turns() == main_line_turns()


## One entry per analysed turn, in turn order, whether or not it is a mistake:
##   turn, node, color, score_before, score_after, loss, kind, winrate
## Cached until the tree's analysis changes (checked by counting analysed turns).
func turns() -> Array:
	if tree == null:
		return []
	var total: int = main_line_turns()
	if _mistakes_for_turns == analysed_turns() and _mistakes.size() == total:
		return _mistakes
	_mistakes = []
	var line: Array[GameNode] = tree.main_line()
	for i in range(1, line.size()):
		var before: GameNode = line[i - 1]
		var after: GameNode = line[i]
		if not has_analysis(before) or not has_analysis(after):
			continue
		var mover: int = after.move_color()
		var score_before: float = float(before.analysis["score_lead"])
		var score_after: float = float(after.analysis["score_lead"])
		var loss: float = loss_for_move(score_before, score_after, mover)
		_mistakes.append({
			"turn": i,
			"node": after,
			"color": mover,
			"score_before": score_before,
			"score_after": score_after,
			"loss": loss,
			"kind": classify_loss(loss),
			"winrate": float(after.analysis["winrate"]),
			"move": after.gtp_move(tree.size),
		})
	_mistakes_for_turns = analysed_turns()
	return _mistakes


## Only the entries that fall into a band, worst first.
func mistakes() -> Array:
	var found: Array = []
	for entry in turns():
		if String(entry["kind"]) != KIND_NONE:
			found.append(entry)
	found.sort_custom(_by_loss_descending)
	return found


func mistakes_for(color: int, limit: int = 10) -> Array:
	var out: Array = []
	for entry in mistakes():
		if int(entry["color"]) == color:
			out.append(entry)
			if out.size() >= limit:
				break
	return out


func worst_loss() -> float:
	var worst: float = 0.0
	for entry in turns():
		worst = maxf(worst, float(entry["loss"]))
	return worst


## The Black win rate (0..1) for each main-line turn, for the graph. Missing
## analysis gives null so the graph can show a gap instead of a wrong line.
func winrate_line() -> Array:
	return _value_line("winrate")


func score_lead_line() -> Array:
	return _value_line("score_lead")


func _value_line(key: String) -> Array:
	var out: Array = []
	if tree == null:
		return out
	for node in tree.main_line():
		if has_analysis(node):
			out.append(float(node.analysis[key]))
		else:
			out.append(null)
	return out


static func _by_loss_descending(a: Dictionary, b: Dictionary) -> bool:
	return float(a["loss"]) > float(b["loss"])


## The territory estimate implied by an ownership array (PLAN 6.2: "Show
## 'Black +x.x' score estimate"). KataGo sends size*size values, row-major from
## the top-left, each -1..1 with +1 meaning Black owns the point; a trailing
## entry for pass is ignored. The sum is the estimated margin in Black's favour.
static func ownership_score(ownership: Array) -> float:
	var total: float = 0.0
	for value in ownership:
		var v: float = float(value)
		# A pass entry (or a stray out-of-range value) is not a point on the board.
		if v > 1.0 or v < -1.0:
			continue
		total += v
	return total


## Same number, formatted the way the PLAN asks: "Black +3.5" / "White +12.0".
static func ownership_text(ownership: Array) -> String:
	if ownership.is_empty():
		return ""
	var total: float = ownership_score(ownership)
	if total >= 0.0:
		return "Black +%.1f" % total
	return "White +%.1f" % -total
