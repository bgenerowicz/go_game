extends SceneTree

## Makes docs/screenshot.png for the README: opens a sample game in the real
## app, runs a full review, jumps to a mid-game position, lets live analysis
## run briefly and saves the window. Needs a display and the engine files.
##
##   godot --path . --script res://tools/screenshot.gd

const SGF_PATH: String = "res://testdata/humanslbigdiff.sgf"
const OUT: String = "res://docs/screenshot.png"
const SHOW_MOVE: int = 58
const LIVE_SECONDS: float = 6.0
const TIMEOUT_SECONDS: float = 600.0

var main: Control = null
var phase: int = 0
var elapsed: float = 0.0
var phase_start: float = 0.0


func _init() -> void:
	var scene: PackedScene = load("res://main.tscn")
	main = scene.instantiate()
	get_root().add_child(main)


func _process(delta: float) -> bool:
	elapsed += delta
	if elapsed > TIMEOUT_SECONDS:
		print("FAIL timed out in phase %d" % phase)
		quit(1)
		return true
	var analysis: Node = get_root().get_node_or_null("Analysis")
	match phase:
		0:
			if main.engine != null and main.engine.running:
				main._on_open_path(ProjectSettings.globalize_path(SGF_PATH))
				main._run_review()
				analysis.review_finished.connect(func() -> void: phase = 2)
				phase = 1
		2:
			main._goto(main.flow.tree.find_by_move_index(SHOW_MOVE))
			phase_start = elapsed
			phase = 3
		3:
			if elapsed - phase_start > LIVE_SECONDS:
				_save()
				return true
	return false


func _save() -> void:
	RenderingServer.force_draw(false)
	var image: Image = get_root().get_texture().get_image()
	image.save_png(ProjectSettings.globalize_path(OUT))
	print("screenshot: %s (%d x %d)" % [OUT, image.get_width(), image.get_height()])
	quit(0)
