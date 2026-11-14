extends SceneTree

## Renders the win-rate graph with known analysis and saves a screenshot, then
## prints the pixel positions the documented mapping predicts. tools/pixel_assert.py
## reads those lines and inspects the PNG, so "the graph renders" is checked from
## outside the engine: the expected x/y come from the spec (turn -> x, win-rate ->
## height), not from the drawing code, so a wrong mapping fails the check.
##
## Run with:
##   with-display godot --path . --script tests/render_graph.gd > /tmp/graph.txt 2>&1
##   python3 tools/pixel_assert.py /tmp/graph.txt /tmp/go_game_graph.png

const OUT: String = "/tmp/go_game_graph.png"
const GRAPH_SIZE: Vector2 = Vector2(600.0, 160.0)

## Win-rate per turn (turn 0 = root), chosen to land on distinctive heights:
## bottom, middle, top, middle, quarter, three-quarters, middle, bottom, top.
const WINRATES: Array = [0.0, 0.5, 1.0, 0.5, 0.25, 0.75, 0.5, 0.0, 1.0]
const SCORE_LEADS: Array = [-10.0, -5.0, 0.0, 5.0, 10.0, 5.0, 0.0, -5.0, -10.0]

var graph: GraphView


func _init() -> void:
	_run()


func _run() -> void:
	var tree: GameTree = GameTree.new(19, 6.5)
	var line: Array[GameNode] = [tree.root]
	var color: int = Board.Stone.BLACK
	for i in 8:
		line.append(tree.play_move(color, i + 2, i + 2))
		color = Board.opposite(color)
	# Give every node on the main line analysis, so the lines are complete.
	for i in line.size():
		line[i].analysis = {
			"visits": 100,
			"winrate": float(WINRATES[i]),
			"score_lead": float(SCORE_LEADS[i]),
			"moves": [],
		}
	var review: Review = Review.new(tree)

	graph = GraphView.new()
	graph.name = "Graph"
	graph.position = Vector2.ZERO
	graph.size = GRAPH_SIZE
	graph.show_score = false  # one line only, so the colour test is unambiguous
	graph.show_position(tree, review, 4)
	graph.refresh_data()
	root.add_child(graph)
	await process_frame
	await process_frame

	var image: Image = get_root().get_texture().get_image()
	if image == null or image.get_width() == 0:
		print("FAIL no viewport image")
		quit(1)
		return
	image.save_png(OUT)
	print("screenshot: %s (%d x %d)" % [OUT, image.get_width(), image.get_height()])

	var turns: int = tree.main_line().size() - 1
	var plot_left: float = GraphView.MARGIN_LEFT
	var plot_right: float = GRAPH_SIZE.x - GraphView.MARGIN_RIGHT
	var plot_top: float = GraphView.MARGIN_TOP
	var plot_bottom: float = GRAPH_SIZE.y - GraphView.MARGIN_BOTTOM
	print("GRAPH size %.0f %.0f turns %d" % [GRAPH_SIZE.x, GRAPH_SIZE.y, turns])

	# The predicted point for every analysed turn: x from the turn number, y from
	# the win-rate fraction measured up from the bottom of the plot. Turns that also
	# get a mistake dot are reported only as dots, since the dot covers the line.
	var kinds: Dictionary = {}
	for entry in review.turns():
		kinds[int(entry["turn"])] = String(entry["kind"])
	for turn in turns + 1:
		var x: float = plot_left + (float(turn) / float(turns)) * (plot_right - plot_left)
		var y: float = plot_bottom - float(WINRATES[turn]) * (plot_bottom - plot_top)
		if kinds.get(turn, Review.KIND_NONE) == Review.KIND_NONE:
			print("GRAPHPOINT %d %.3f %.1f %.1f" % [turn, float(WINRATES[turn]), x, y])

	# The 50 percent grid line must sit exactly halfway up the plot.
	print("GRAPHMID %.1f %.1f" % [plot_left, plot_top + 0.5 * (plot_bottom - plot_top)])
	# The cursor for the current turn (4) is a dark vertical line.
	print("GRAPHCURSOR %.1f %.1f" % [
		plot_left + (4.0 / float(turns)) * (plot_right - plot_left),
		plot_top + 0.5 * (plot_bottom - plot_top),
	])
	print("GRAPH kinds: %s" % str(kinds))
	for turn in kinds:
		if String(kinds[turn]) == Review.KIND_NONE:
			continue
		var x2: float = plot_left + (float(turn) / float(turns)) * (plot_right - plot_left)
		var y2: float = plot_bottom - float(WINRATES[turn]) * (plot_bottom - plot_top)
		print("GRAPHDOT %d %s %.1f %.1f" % [turn, String(kinds[turn]), x2, y2])
	quit(0)
