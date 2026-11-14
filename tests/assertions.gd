class_name Assertions
extends RefCounted

## Shared assertion / counting helper handed to every test module.

var checks: int = 0
var passed: int = 0
var failed: int = 0
var current: String = "general"
var failures: Array[String] = []
## The SceneTree the runner is executing in. Autoloads are not created when a
## project is started with --script, so tests that need nodes under /root use
## this instead of Engine.get_main_loop(), which is still null inside _init().
var tree: SceneTree = null


func section(name: String) -> void:
	current = name
	print("--- %s" % name)


func check(condition: bool, what: String) -> void:
	checks += 1
	if condition:
		passed += 1
	else:
		failed += 1
		var message: String = "  FAIL [%s] %s" % [current, what]
		failures.append(message)
		print(message)


func check_eq(actual: Variant, expected: Variant, what: String) -> void:
	checks += 1
	if actual == expected:
		passed += 1
	else:
		failed += 1
		var message: String = "  FAIL [%s] %s: expected <%s>, got <%s>" % [
			current, what, str(expected), str(actual),
		]
		failures.append(message)
		print(message)
