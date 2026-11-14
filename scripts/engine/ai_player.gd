class_name AiPlayer
extends RefCounted

## Picks the opponent's move from one KataGo analysis (PLAN 5.4).
##
## The interesting part, choose_move(), is pure: it takes an analysis Dictionary
## in the shape Analysis stores on a node and returns a move. That keeps the
## sampling testable without an engine.

const REQUEST_VISITS: int = 40
const REQUEST_PRIORITY: int = 20
## Entries below this fraction of the largest human-policy value are dropped.
const MIN_POLICY_FRACTION: float = 0.02
## Do not let the opponent move faster than this, so it does not feel instant.
const MIN_THINK_SECONDS: float = 0.5
## Resign thresholds (PLAN 5.4 step 4).
const RESIGN_WINRATE: float = 0.03
const RESIGN_SCORE_BEHIND: float = 25.0
const RESIGN_AFTER_MOVE: int = 100
## The level below 20k. KataGo's human network stops at 20k, so "beginner" plays
## its 20k profile but samples from that network's whole move distribution
## (every legal point), where the ranked levels only choose among moves the
## search already considered. That lets it make the slow, loose and
## overlooked moves real beginners make.
const BEGINNER: String = "beginner"
const BEGINNER_PROFILE_RANK: String = "20k"
## Beginner ignores points under this fraction of its most likely move, so it
## plays loosely without picking moves no human would.
const BEGINNER_MIN_FRACTION: float = 0.005

var profile: String = "rank_5k"
var style: String = "modern"  # "modern" or "preai"
var allow_resign: bool = true
## Visits per move. Defaults to REQUEST_VISITS; the caller may raise it from
## Settings (ai_visits) without touching the request code.
var visits: int = REQUEST_VISITS
var rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _init(p_profile: String = "rank_5k", p_style: String = "modern") -> void:
	profile = p_profile
	style = p_style
	rng.randomize()


## Applies a profile chosen in the new-game or settings dialog. A preaz_* or
## proyear_* name sets the style itself, so both fields stay consistent. The
## profile is stored exactly as given (a full KataGo name), because sl_profile()
## can only rewrite names that still carry their "rank_" prefix.
func configure(p_profile: String, p_visits: int = -1) -> void:
	if p_profile.begins_with("preaz_"):
		profile = p_profile
		style = "preai"
	elif p_profile.begins_with("proyear_"):
		profile = p_profile
		style = "modern"
	else:
		profile = p_profile
		style = "modern"
	if p_visits > 0:
		visits = p_visits


## The profile name KataGo expects for this rank and style.
func sl_profile() -> String:
	var name: String = profile
	if is_beginner():
		# Same family, KataGo's lowest rank: rank_beginner -> rank_20k.
		name = profile.trim_suffix(BEGINNER) + BEGINNER_PROFILE_RANK
	if style == "preai" and name.begins_with("rank_"):
		return "preaz_" + name.substr("rank_".length())
	return name


## True for the Beginner level (rank_beginner / preaz_beginner).
func is_beginner() -> bool:
	return profile.ends_with("_" + BEGINNER)


## opts for Analysis.request() to get what the opponent needs.
func request_opts(tree: GameTree) -> Dictionary:
	return {
		"tree": tree,
		"include_policy": true,
		"include_ownership": false,
		"priority": REQUEST_PRIORITY,
		"human_profile": sl_profile(),
		"pv_len": 8,
	}


## Requests the position and returns the query id ("" when unavailable).
func request_move(analysis_service: Node, tree: GameTree, node: GameNode) -> String:
	return analysis_service.request(node, visits, request_opts(tree))


## Chooses a move from a stored analysis result.
## Returns { "move": gtp or "", "resign": bool, "reason": String }.
## `color` is the engine side to move, `previous_was_pass` the move before this.
func choose_move(analysis: Dictionary, size: int, color: int,
		move_number: int, previous_was_pass: bool) -> Dictionary:
	if analysis.is_empty():
		return {"move": "", "resign": false, "reason": "no analysis available"}
	if should_resign(analysis, color, move_number):
		return {"move": "", "resign": true, "reason": "resign: losing badly"}

	var moves: Array = analysis.get("moves", []) as Array
	if moves.is_empty():
		return {"move": "", "resign": false, "reason": "engine offered no moves"}

	# Pass handling (PLAN 5.4 step 2).
	var best: Dictionary = moves[0] as Dictionary
	if String(best["move"]) == Coords.PASS:
		if previous_was_pass or move_number > int(size * size / 2.0):
			return {"move": Coords.PASS, "resign": false, "reason": "engine best is pass"}

	# Sample from the human policy, not from the search result (step 3). The
	# ranked levels pick among the searched candidates; Beginner picks from the
	# whole board.
	var weighted: Array = _full_policy_candidates(analysis, size) if is_beginner() \
		else _weighted_candidates(analysis, size)
	if weighted.is_empty():
		# No usable human policy: fall back to the engine's best move rather
		# than passing out of a live position.
		return {"move": String(best["move"]), "resign": false,
			"reason": "no human policy, using engine best"}
	var picked: Dictionary = _sample(weighted)
	var picked_index: int = weighted.find(picked)
	return {"move": String(picked["move"]), "resign": false,
		"reason": "sampled candidate %d of %d after human-policy filtering"
			% [picked_index + 1, weighted.size()]}


## Candidates carrying a usable humanPolicy value, as
## [{move, weight, rank}], pass and illegal entries removed, entries under 2% of
## the largest removed, weights renormalised to sum to 1.
func _weighted_candidates(analysis: Dictionary, size: int) -> Array:
	var policy: Array = analysis.get("human_policy", []) as Array
	var out: Array = []
	if policy.size() < size * size + 1:
		return out
	var largest: float = 0.0
	for info in (analysis.get("moves", []) as Array):
		var entry: Dictionary = info as Dictionary
		var gtp: String = String(entry["move"])
		if gtp == Coords.PASS:
			continue
		var point: Vector2i = Coords.from_gtp(gtp, size)
		if point == Coords.INVALID:
			continue
		var value: float = float(policy[point.y * size + point.x])
		if value < 0.0:  # KataGo marks illegal points with -1
			continue
		if value > largest:
			largest = value
	if largest <= 0.0:
		return out
	var cutoff: float = largest * MIN_POLICY_FRACTION
	var total: float = 0.0
	for rank in (analysis.get("moves", []) as Array).size():
		var entry: Dictionary = (analysis["moves"] as Array)[rank] as Dictionary
		var gtp: String = String(entry["move"])
		if gtp == Coords.PASS:
			continue
		var point: Vector2i = Coords.from_gtp(gtp, size)
		if point == Coords.INVALID:
			continue
		var value: float = float(policy[point.y * size + point.x])
		if value < 0.0 or value < cutoff:
			continue
		out.append({"move": gtp, "weight": value, "rank": rank})
		total += value
	if total <= 0.0:
		return []
	for candidate in out:
		candidate["weight"] = float(candidate["weight"]) / total
	return out


## Every legal board point the human policy gives at least
## BEGINNER_MIN_FRACTION of its largest value, as [{move, weight, rank}] with
## weights summing to 1. Pass is left to the pass rules in choose_move().
func _full_policy_candidates(analysis: Dictionary, size: int) -> Array:
	var policy: Array = analysis.get("human_policy", []) as Array
	var out: Array = []
	if policy.size() < size * size:
		return out
	var largest: float = 0.0
	for i in size * size:
		largest = maxf(largest, float(policy[i]))
	if largest <= 0.0:
		return out
	var cutoff: float = largest * BEGINNER_MIN_FRACTION
	var total: float = 0.0
	for i in size * size:
		var value: float = float(policy[i])
		if value < 0.0 or value < cutoff:  # -1 marks an illegal point
			continue
		out.append({"move": Coords.to_gtp(i % size, i / size, size), "weight": value, "rank": -1})
		total += value
	if total <= 0.0:
		return []
	for candidate in out:
		candidate["weight"] = float(candidate["weight"]) / total
	return out


## Weighted random pick. Deterministic when rng is seeded, which is what the
## tests rely on.
func _sample(weighted: Array) -> Dictionary:
	var roll: float = rng.randf()
	var acc: float = 0.0
	for candidate in weighted:
		acc += float(candidate["weight"])
		if roll <= acc:
			return candidate
	return weighted[weighted.size() - 1] as Dictionary


## PLAN 5.4 step 4: give up when the engine side is clearly lost. Win rate and
## score lead are from Black's point of view (reportAnalysisWinratesAs = BLACK).
func should_resign(analysis: Dictionary, color: int, move_number: int) -> bool:
	if not allow_resign:
		return false
	if move_number < RESIGN_AFTER_MOVE:
		return false
	var winrate: float = float(analysis.get("winrate", 0.5))
	var score_lead: float = float(analysis.get("score_lead", 0.0))
	if color == Board.Stone.WHITE:
		winrate = 1.0 - winrate
		score_lead = -score_lead
	return winrate < RESIGN_WINRATE and score_lead <= -RESIGN_SCORE_BEHIND
