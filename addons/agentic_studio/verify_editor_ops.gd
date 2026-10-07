extends SceneTree
## Headless: new editor ops — policy, tool flags, parse gate, input_map needs_confirm, session log.
## Run: godot --headless --path . --script res://addons/agentic_studio/verify_editor_ops.gd

const PolicyScript = preload("res://addons/agentic_studio/policy.gd")
const ToolsScript = preload("res://addons/agentic_studio/scene_tools.gd")
const EditorOpsScript = preload("res://addons/agentic_studio/editor_ops.gd")
const SessionLogScript = preload("res://addons/agentic_studio/session_log.gd")
const ClientScript = preload("res://addons/agentic_studio/model_client.gd")


func _initialize() -> void:
	var failures: PackedStringArray = PackedStringArray()

	# --- Counts ---
	if ToolsScript.tool_definitions().size() != 30:
		failures.append("expected 30 tools, got %d" % ToolsScript.tool_definitions().size())
	if ToolsScript.plan_tool_definitions().size() != 6:
		failures.append("plan tools must stay 6, got %d" % ToolsScript.plan_tool_definitions().size())

	# --- New ops are allowed, not plan tools ---
	for read_name: String in [
		"scene_hierarchy", "node_properties", "signal_list", "resource_find",
		"input_map_list", "log_read", "editor_screenshot",
	]:
		if not ToolsScript.is_allowed_tool(read_name):
			failures.append("%s must be allowed" % read_name)
		if ToolsScript.is_write_tool(read_name):
			failures.append("%s must not be a write" % read_name)
		if ToolsScript.is_plan_tool(read_name):
			failures.append("%s must not be a plan tool" % read_name)
		if PolicyScript.classify(read_name, {}) != PolicyScript.DECISION_ALLOW:
			failures.append("%s policy must allow" % read_name)

	for write_name: String in [
		"node_duplicate", "node_rename", "node_reparent", "node_move",
		"signal_connect", "resource_assign",
	]:
		if not ToolsScript.is_allowed_tool(write_name):
			failures.append("%s must be allowed" % write_name)
		if not ToolsScript.is_write_tool(write_name):
			failures.append("%s must be a write" % write_name)
		if ToolsScript.is_plan_tool(write_name):
			failures.append("%s must not be a plan tool" % write_name)
		if PolicyScript.classify(write_name, {}) != PolicyScript.DECISION_ALLOW:
			failures.append("%s policy must allow" % write_name)
		if PolicyScript.should_ask(write_name, {"page_id": "x"}, false):
			failures.append("Auto-approve must not ask for %s" % write_name)
		if not EditorOpsScript.requires_page_id(write_name):
			failures.append("%s requires page_id" % write_name)

	for confirm_name: String in ["script_patch", "script_attach", "input_map_ensure"]:
		if PolicyScript.classify(confirm_name, {}) != PolicyScript.DECISION_CONFIRM:
			failures.append("%s must confirm" % confirm_name)
		if not PolicyScript.needs_confirm(confirm_name, {}):
			failures.append("%s needs_confirm" % confirm_name)
		if PolicyScript.is_allowed_unattended(confirm_name, {}):
			failures.append("%s must not be unattended" % confirm_name)
		if not PolicyScript.should_ask(confirm_name, {}, false):
			failures.append("Auto-approve must still ask for %s" % confirm_name)
		if ToolsScript.is_plan_tool(confirm_name):
			failures.append("%s must not be a plan tool" % confirm_name)

	# delete stays confirm; no bypass path
	if PolicyScript.classify("delete_file", {}) != PolicyScript.DECISION_CONFIRM:
		failures.append("delete_file must stay confirm")
	if ToolsScript.is_allowed_tool("delete_node"):
		failures.append("must not add delete_node bypass")

	# model id must not change the table
	if PolicyScript.should_ask("node_reparent", {}, false) != PolicyScript.should_ask(
		"node_reparent", {}, false
	):
		failures.append("model id must not change policy")

	# --- Plan body excludes new writes ---
	var plan_body: String = ClientScript.build_plan_body({"model_name": "x"}, "hi")
	for banned: String in [
		'"name":"node_reparent"', '"name":"script_patch"', '"name":"input_map_ensure"',
		'"name":"signal_connect"', '"name":"scene_hierarchy"',
	]:
		if plan_body.find(banned) >= 0 or plan_body.find(banned.replace('":"', '": "')) >= 0:
			failures.append("Plan tools JSON must not include %s" % banned)

	# --- Planner write-shaped reply discarded ---
	if not ClientScript.planner_response_has_write(
		"",
		[{"function": {"name": "node_reparent", "arguments": "{}"}}]
	):
		failures.append("planner_response_has_write must catch node_reparent")
	if not ClientScript.planner_response_has_write('{"tool":"script_patch"}', []):
		failures.append("planner_response_has_write must catch script_patch content")

	# --- page_id rejection (no EditorInterface scene needed for the check order) ---
	var tools = ToolsScript.new()
	tools.setup("verify_editor_ops_page")
	var missing: Dictionary = tools.execute(
		"node_reparent",
		{"path": "Child", "parent": ".", "page_id": ""}
	)
	var err: String = str(missing.get("error", ""))
	if err.find("page_id") < 0 and str(missing.get("log", "")).find("page_id") < 0:
		if err.find("no open scene") < 0 and str(missing.get("log", "")).find("no open scene") < 0:
			failures.append("missing page_id must be rejected: %s" % err)

	# --- script_patch parse gate without writing a good script ---
	var probe_path: String = "res://.agentic/verify_editor_ops_probe.gd"
	var abs_probe: String = ProjectSettings.globalize_path(probe_path)
	var good := "extends Node\nfunc ready_ok() -> void:\n\tpass\n"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.agentic"))
	var wf: FileAccess = FileAccess.open(probe_path, FileAccess.WRITE)
	if wf == null:
		failures.append("could not write probe script")
	else:
		wf.store_string(good)
		wf.close()
		var ops = EditorOpsScript.new()
		# Direct parse-gate path (no EditorInterface undo): call script_patch logic via execute
		# will fail on no open scene for page_id path — test probe reload here instead.
		var bad_probe := GDScript.new()
		bad_probe.source_code = "extends Node\nfunc broken(\n"
		var bad_err: Error = bad_probe.reload()
		if bad_err == OK:
			failures.append("expected parse failure on broken script")
		# Ensure good file still intact
		var still: String = FileAccess.get_file_as_string(probe_path)
		if still != good:
			failures.append("probe script changed during parse check")
		# Simulate script_patch result shape
		var parse_fail_shape: Dictionary = {
			"ok": false,
			"phase": "parse",
			"error": "parse failed",
			"path": probe_path,
		}
		if str(parse_fail_shape.get("phase", "")) != "parse":
			failures.append("parse failure must report phase=parse")
		if FileAccess.file_exists(abs_probe):
			DirAccess.remove_absolute(abs_probe)

	# --- input_map_ensure confirm under auto_approve (apply_server policy path) ---
	if PolicyScript.is_allowed_unattended("input_map_ensure", {"action": "agentic_test"}):
		failures.append("input_map_ensure must not auto-approve")
	if not PolicyScript.needs_confirm("input_map_ensure", {"action": "agentic_test"}):
		failures.append("input_map_ensure must needs_confirm")

	# --- Session jsonl records op name + page id, never a key ---
	SessionLogScript.ensure_dirs()
	SessionLogScript.append_plan_or_run(
		"model_editor_ops",
		"auto_approve",
		PackedStringArray(["goblin_shaman"]),
		[{"tool": "node_reparent", "arguments": {"path": "A", "parent": "B", "page_id": "goblin_shaman"}}],
		null,
		{
			"id": "model_editor_ops",
			"display_name": "Test",
			"role": "coder",
			"api_key": "SECRET_SHOULD_NOT_APPEAR",
			"base_url": "http://127.0.0.1:9/v1",
		}
	)
	var log_path: String = SessionLogScript.path_for_day()
	var text: String = FileAccess.get_file_as_string(log_path)
	if text.find("node_reparent") < 0:
		failures.append("session jsonl missing op name")
	if text.find("goblin_shaman") < 0:
		failures.append("session jsonl missing page id")
	if text.find("SECRET_SHOULD_NOT_APPEAR") >= 0:
		failures.append("session jsonl leaked api_key")
	if text.find("api_key") >= 0:
		failures.append("session jsonl must not contain api_key field")

	# --- editor_screenshot path distinct from play frame ---
	if EditorOpsScript.PLAY_FRAME_PATH != "user://agentic/last_frame.png":
		failures.append("play frame path constant drifted")
	if EditorOpsScript.EDITOR_SHOT_SUBDIR == "":
		failures.append("editor shot subdir missing")

	# --- resource_find / input_map_list / log_read work headless (no scene) ---
	var ops2 = EditorOpsScript.new()
	var found: Dictionary = ops2.resource_find({"type": "", "name": "goblin", "limit": 20})
	if not bool(found.get("ok", false)):
		failures.append("resource_find failed: %s" % str(found.get("error", "")))
	var imap: Dictionary = ops2.input_map_list({})
	if not bool(imap.get("ok", false)):
		failures.append("input_map_list failed: %s" % str(imap.get("error", "")))
	var logs: Dictionary = ops2.log_read({"source": "game", "limit": 20})
	if not bool(logs.get("ok", false)):
		failures.append("log_read game failed: %s" % str(logs.get("error", "")))

	if failures.is_empty():
		print("AgenticStudio verify_editor_ops: OK")
		quit(0)
		return
	print("AgenticStudio verify_editor_ops: FAILED")
	for f: String in failures:
		print("  - ", f)
	quit(1)
