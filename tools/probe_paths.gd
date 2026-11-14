extends SceneTree

func _init() -> void:
	print("exe: ", OS.get_executable_path())
	print("exe dir: ", OS.get_executable_path().get_base_dir())
	print("globalized: ", ProjectSettings.globalize_path("res://"))
	var p: String = "/home/llmdev/worktrees/go_game/runtime/katago/katago"
	print("absolute file_exists: ", FileAccess.file_exists(p))
	print("res:// file_exists: ", FileAccess.file_exists("res://../runtime/katago/katago"))
	print("cwd: ", DirAccess.open(".").get_current_dir() if DirAccess.open(".") != null else "n/a")
	var node: Node = Node.new()
	node.name = "Probe"
	root.add_child(node)
	print("root is null: ", root == null)
	print("node in tree: ", node.is_node_ready())
	quit(0)
