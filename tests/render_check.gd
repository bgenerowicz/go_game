extends SceneTree

## Renders a known position and saves a screenshot so the drawing can be checked
## pixel by pixel from outside the engine. Run with:
##   with-display godot --script tests/render_check.gd
## The expected stones are printed so the image analysis can assert against them.

const OUT: String = "/tmp/go_game_render.png"


func _init() -> void:
	_run()


func _run() -> void:
	var scene: PackedScene = load("res://main.tscn")
	if scene == null:
		print("FAIL main.tscn did not load")
		quit(1)
		return
	var root: Control = scene.instantiate()
	get_root().add_child(root)
	await process_frame
	await process_frame

	var flow: RefCounted = root.flow
	flow.start(19, 6.5, "japanese", 0)
	# Four star points, then a real capture of the white stone on D4.
	for gtp in ["Q16", "D16", "Q4", "D4", "C4", "E6", "E4", "E7", "D3", "E8", "D5"]:
		var p: Vector2i = Coords.from_gtp(gtp, 19)
		if not flow.play(p.x, p.y):
			print("FAIL could not play %s" % gtp)
		await process_frame
	root.board_view.show_position(flow.tree, flow.current())
	await process_frame
	await process_frame
	root.board_view.show_position(flow.tree, flow.current())
	await process_frame
	await process_frame

	# A window hidden behind others may stop redrawing; draw this frame now.
	RenderingServer.force_draw(false)
	var image: Image = get_root().get_texture().get_image()
	if image == null or image.get_width() == 0:
		print("FAIL no viewport image")
		quit(1)
		return
	image.save_png(OUT)
	print("screenshot: %s (%d x %d)" % [OUT, image.get_width(), image.get_height()])

	# What the drawing should contain, in grid coordinates (col 0 = left edge,
	# row 0 = top edge), which is how the outside analysis reads the image.
	var expected: Array[String] = [
		"15,3 B", "3,3 W", "15,15 B", "2,15 B", "4,13 W",
		"4,15 B", "4,12 W", "3,14 B", "4,11 W", "3,16 B",
	]
	print("expected stones (col,row colour): %s" % str(expected))
	print("must be empty (captured): 3,15")

	# Machine-readable pixel positions so an outside script can assert on the
	# exact pixels the control drew, instead of guessing the board geometry.
	var view: Control = root.board_view
	# The window stretches the UI (canvas_items mode, HiDPI), so layout units are
	# mapped through the window's final transform into screenshot pixels.
	var to_pixels: Transform2D = get_root().get_final_transform()
	var view_origin: Vector2 = to_pixels * (view.get_global_transform() * view.grid_origin())
	var cell: float = view.cell_size() * to_pixels.get_scale().x
	print("board origin: %.1f,%.1f cell: %.2f" % [view_origin.x, view_origin.y, cell])
	for entry in expected:
		var parts: PackedStringArray = entry.split(" ")
		var xy: PackedStringArray = parts[0].split(",")
		var centre: Vector2 = view_origin + Vector2(float(int(xy[0])), float(int(xy[1]))) * cell
		print("PIXEL %s %s %.1f %.1f" % [parts[0], parts[1], centre.x, centre.y])
	var empty_xy: PackedStringArray = "3,15".split(",")
	var empty_centre: Vector2 = view_origin \
		+ Vector2(float(int(empty_xy[0])), float(int(empty_xy[1]))) * cell
	print("PIXEL 3,15 E %.1f %.1f" % [empty_centre.x, empty_centre.y])
	var board: RefCounted = flow.board()
	print("D4 after the sequence: %d (0 means the capture worked)" % board.get_stone(3, 15))
	print("captures by Black: %d (expect 1)" % int(board.captures[Board.Stone.BLACK]))
	print("stones on board: black %d white %d (expect 6 and 4)"
		% [board.stone_count(Board.Stone.BLACK), board.stone_count(Board.Stone.WHITE)])
	quit(0)
