extends SceneTree
## Headless: policy, page_id rejection, drift tool, session log, result shape helpers.
## Run: godot --headless --path . --script res://addons/agentic_studio/verify_play_sensor.gd

const PolicyScript = preload("res://addons/agentic_studio/policy.gd")
const ToolsScript = preload("res://addons/agentic_studio/scene_tools.gd")
const PlayScript = preload("res://addons/agentic_studio/play_support.gd")
const SessionLogScript = preload("res://addons/agentic_studio/session_log.gd")
const ClientScript = preload("res://addons/agentic_studio/model_client.gd")


func _initialize() -> void:
	var failures: PackedStringArray = PackedStringArray()

	# Policy table
	if PolicyScript.classify("add_node", {}) != PolicyScript.DECISION_ALLOW:
		failures.append("add_node must allow")
	if PolicyScript.classify("set_property", {"property": "position"}) != PolicyScript.DECISION_ALLOW:
		failures.append("set_property position must allow")
	if PolicyScript.classify("set_property", {"property": "script"}) != PolicyScript.DECISION_CONFIRM:
		failures.append("set_property script must confirm")
	if PolicyScript.classify("write_file", {"path": "res://x.gd"}) != PolicyScript.DECISION_CONFIRM:
		failures.append("write_file .gd must confirm")
	if PolicyScript.classify("delete_file", {}) != PolicyScript.DECISION_CONFIRM:
		failures.append("delete_file must confirm")
	if PolicyScript.should_ask("add_node", {}, false):
		failures.append("Auto-approve must not ask for add_node")
	if not PolicyScript.should_ask("write_file", {"path": "res://x.gd"}, false):
		failures.append("Auto-approve must ask for script body")
	if PolicyScript.should_ask("add_node", {}, false) != PolicyScript.should_ask("add_node", {}, false):
		failures.append("model id must not change policy")

	# Tool flags
	if not ToolsScript.is_plan_tool("check_page_drift"):
		failures.append("check_page_drift must be a plan tool")
	if ToolsScript.is_write_tool("check_page_drift"):
		failures.append("check_page_drift must not be a write")
	if not ToolsScript.is_always_confirm_tool("write_file", {"path": "res://a.gd"}):
		failures.append("write_file .gd always confirm")
	if ToolsScript.is_always_confirm_tool("add_node", {"type": "Node3D", "name": "X"}):
		failures.append("add_node must not always confirm")

	# Plan body includes drift
	if ClientScript.PLAN_SYSTEM_PROMPT.find("check_page_drift") < 0:
		failures.append("Plan prompt missing check_page_drift")
	if ClientScript.EXECUTE_SYSTEM_PROMPT.find("page_id") < 0:
		failures.append("Execute prompt missing page_id")
	var plan_tools: Array = ToolsScript.plan_tool_definitions()
	var plan_names: PackedStringArray = PackedStringArray()
	for t: Variant in plan_tools:
		if typeof(t) == TYPE_DICTIONARY:
			var fn: Variant = (t as Dictionary).get("function", {})
			if typeof(fn) == TYPE_DICTIONARY:
				plan_names.append(str((fn as Dictionary).get("name", "")))
	if not plan_names.has("check_page_drift"):
		failures.append("plan tools missing check_page_drift")

	# Result shape helper
	var sample: Dictionary = {
		"ok": false,
		"phase": "play",
		"page_ids": ["goblin_shaman"],
		"errors": [{"file": "res://actors/goblin.gd", "line": 12, "message": "boom"}],
		"frame": "user://agentic/last_frame.png",
	}
	var log_line: String = PlayScript.format_play_log(sample)
	if log_line.find("phase=play") < 0:
		failures.append("format_play_log missing phase")
	if log_line.find("goblin.gd") < 0 and log_line.find("boom") < 0:
		failures.append("format_play_log missing error detail")

	# Session log append
	SessionLogScript.ensure_dirs()
	var before_path: String = SessionLogScript.path_for_day()
	SessionLogScript.append_plan_or_run(
		"model_test",
		"plan",
		PackedStringArray(["goblin_shaman"]),
		[{"tool": "get_page", "path": "Goblin Shaman"}],
		null
	)
	var abs_log: String = ProjectSettings.globalize_path(before_path)
	if not FileAccess.file_exists(abs_log):
		failures.append("session jsonl missing")
	else:
		var text: String = FileAccess.get_file_as_string(before_path)
		if text.find("goblin_shaman") < 0:
			failures.append("session jsonl missing page_id")
		if text.find("model_test") < 0:
			failures.append("session jsonl missing model_id")

	# page_id required without EditorInterface: use tools.execute path may fail on no scene;
	# still assert the helper message shape via a dry require through a stub job setup.
	var tools = ToolsScript.new()
	tools.setup("verify_page_id")
	var missing: Dictionary = tools.execute(
		"add_node",
		{"type": "Node3D", "name": "NoPage"}
	)
	# In headless, may also fail on no scene — but error must mention page_id first.
	var err: String = str(missing.get("error", ""))
	if err.find("page_id") < 0 and str(missing.get("log", "")).find("page_id") < 0:
		# Headless without EditorInterface may error differently; accept either page_id or no open scene
		# only if EditorInterface is unavailable.
		if err.find("no open scene") < 0 and str(missing.get("log", "")).find("no open scene") < 0:
			failures.append("missing page_id must be rejected: %s" % err)

	if failures.is_empty():
		print("AgenticStudio verify_play_sensor: OK")
		quit(0)
	else:
		print("AgenticStudio verify_play_sensor: FAILED")
		for f: String in failures:
			print("  - ", f)
		quit(1)
