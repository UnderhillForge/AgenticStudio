extends SceneTree
## Headless: job modes + tool-result parsing. No live model. No EditorInterface.
## Run: godot --headless --path . --script res://addons/agentic_studio/verify_execute.gd

const JobScript = preload("res://addons/agentic_studio/job.gd")
const ClientScript = preload("res://addons/agentic_studio/model_client.gd")
const ToolsScript = preload("res://addons/agentic_studio/scene_tools.gd")
const PlayScript = preload("res://addons/agentic_studio/play_support.gd")


func _initialize() -> void:
	var failures: PackedStringArray = PackedStringArray()

	# Modes
	if JobScript.MODE_PLAN == JobScript.MODE_RUN:
		failures.append("plan/run mode constants collided")
	if JobScript.mode_from_index(2) != JobScript.MODE_AUTO_APPROVE:
		failures.append("auto-approve index mapping wrong")

	# Coder catalog (play_scene is plugin gate, not a model tool). Plan has reads only.
	var tools: Array = ToolsScript.tool_definitions()
	if tools.size() != 31:
		failures.append("expected exactly 31 tools, got %d" % tools.size())
	var names: PackedStringArray = PackedStringArray()
	for t: Variant in tools:
		if t is Dictionary:
			var fn: Variant = (t as Dictionary).get("function", {})
			if fn is Dictionary:
				names.append(str((fn as Dictionary).get("name", "")))
	if names.has("play_scene"):
		failures.append("play_scene must not be a model tool")
	for required: String in [
		"add_node", "set_property",
		"list_pages", "get_page", "link", "create_asset",
		"list_dir", "read_file", "write_file", "delete_file",
		"screenshot", "check_page_drift",
		"scene_hierarchy", "node_properties", "class_get", "signal_list", "resource_find",
		"input_map_list", "log_read", "editor_screenshot",
		"node_duplicate", "node_rename", "node_reparent", "node_move",
		"signal_connect", "resource_assign",
		"script_patch", "script_attach", "input_map_ensure",
	]:
		if not names.has(required):
			failures.append("missing tool %s" % required)
	var plan_tools: Array = ToolsScript.plan_tool_definitions()
	if plan_tools.size() != 14:
		failures.append("expected 14 plan tools, got %d" % plan_tools.size())
	if not ToolsScript.is_plan_tool("class_get"):
		failures.append("class_get must be a plan tool")

	var plan_body: String = ClientScript.build_plan_body({
		"model_name": "x",
	}, "hi")
	if plan_body.find("list_pages") < 0 or plan_body.find("get_page") < 0:
		failures.append("Plan request must include list_pages and get_page")
	if plan_body.find("list_dir") < 0 or plan_body.find("read_file") < 0:
		failures.append("Plan request must include list_dir and read_file")
	if plan_body.find("screenshot") < 0:
		failures.append("Plan request must include screenshot")
	# Tool JSON names only (system prompt may mention banned ops by name).
	for banned_tool: String in ["add_node", "play_scene", "node_reparent", "script_patch"]:
		var marker: String = "\"name\":\"%s\"" % banned_tool
		var marker_sp: String = "\"name\": \"%s\"" % banned_tool
		if plan_body.find(marker) >= 0 or plan_body.find(marker_sp) >= 0:
			failures.append("Plan request must not include tool %s" % banned_tool)
	if plan_body.find("\"name\":\"create_asset\"") >= 0 \
			or plan_body.find("\"name\": \"create_asset\"") >= 0:
		failures.append("Plan request must not include create_asset tool")
	if plan_body.find("\"name\":\"link\"") >= 0 or plan_body.find("\"name\": \"link\"") >= 0:
		failures.append("Plan request must not include link tool")
	if plan_body.find("\"name\":\"write_file\"") >= 0 \
			or plan_body.find("\"name\": \"write_file\"") >= 0:
		failures.append("Plan request must not include write_file tool")
	if plan_body.find("\"name\":\"delete_file\"") >= 0 \
			or plan_body.find("\"name\": \"delete_file\"") >= 0:
		failures.append("Plan request must not include delete_file tool")

	var exec_messages: Array = ClientScript.initial_execute_messages("add a node")
	var exec_body: String = ClientScript.build_chat_body({
		"model_name": "x",
	}, exec_messages, true)
	if exec_body.find("\"name\":\"class_get\"") < 0 and exec_body.find("\"name\": \"class_get\"") < 0:
		failures.append("execute chat body missing class_get tool")
	if exec_body.find("\"name\":\"play_scene\"") >= 0 or exec_body.find("\"name\": \"play_scene\"") >= 0:
		failures.append("execute chat body must not expose play_scene as a model tool")
	if exec_body.find("list_pages") < 0 or exec_body.find("link") < 0:
		failures.append("execute chat body missing page tools")
	if exec_body.find("\"name\":\"create_asset\"") < 0 \
			and exec_body.find("\"name\": \"create_asset\"") < 0:
		failures.append("execute chat body missing create_asset tool")
	if exec_body.find("write_file") < 0 or exec_body.find("delete_file") < 0:
		failures.append("execute chat body missing file tools")
	if exec_body.find("plugin gate") < 0 and exec_body.to_lower().find("plugin gate") < 0:
		failures.append("execute system prompt missing from body")

	# Parse tool calls from a synthetic OpenAI response
	var sample: String = """
	{"choices":[{"message":{"role":"assistant","content":"",
	"tool_calls":[{"id":"call_1","type":"function",
	"function":{"name":"add_node","arguments":"{\\"type\\":\\"Node3D\\",\\"name\\":\\"AgentProbe\\"}"}}]}}]}
	"""
	var message: Dictionary = ClientScript.parse_assistant_message(sample)
	var calls: Array = message.get("tool_calls", [])
	if calls.size() != 1:
		failures.append("expected 1 tool call, got %d" % calls.size())
	else:
		var call: Dictionary = calls[0]
		var fn: Dictionary = call.get("function", {})
		if str(fn.get("name", "")) != "add_node":
			failures.append("parsed tool name wrong")
		var args: Dictionary = ClientScript.parse_tool_arguments(str(fn.get("arguments", "{}")))
		if str(args.get("name", "")) != "AgentProbe":
			failures.append("parsed add_node name wrong")

	# Content-emitted tool JSON (Ollama/qwen style)
	var content_sample: String = (
		'{"choices":[{"message":{"role":"assistant","content":'
		+ '"{\\"name\\":\\"add_node\\",\\"arguments\\":{\\"type\\":\\"Node3D\\",\\"name\\":\\"AgentProbe\\"}}"'
		+ "}}]}"
	)
	var content_msg: Dictionary = ClientScript.parse_assistant_message(content_sample)
	var content_calls: Array = content_msg.get("tool_calls", [])
	if content_calls.size() != 1:
		failures.append("content tool JSON should yield 1 tool call")
	elif not bool(content_msg.get("from_content_tools", false)):
		failures.append("content tool JSON should set from_content_tools")
	else:
		var cfn: Dictionary = content_calls[0].get("function", {})
		var cargs: Dictionary = ClientScript.parse_tool_arguments(str(cfn.get("arguments", "{}")))
		if str(cargs.get("name", "")) != "AgentProbe":
			failures.append("content tool JSON name parse failed")

	# Bare identifier in content JSON: {"name": add_node, ...}
	var bare_sample: String = (
		'{"choices":[{"message":{"role":"assistant","content":'
		+ '"{\\"name\\": add_node, \\"arguments\\": {\\"type\\": \\"Node3D\\", \\"name\\": \\"AgentProbe\\"}}"'
		+ "}}]}"
	)
	var bare_msg: Dictionary = ClientScript.parse_assistant_message(bare_sample)
	var bare_calls: Array = bare_msg.get("tool_calls", [])
	if bare_calls.size() != 1:
		failures.append("bare-identifier tool JSON should yield 1 tool call")
	else:
		var bfn: Dictionary = bare_calls[0].get("function", {})
		if str(bfn.get("name", "")) != "add_node":
			failures.append("bare-identifier tool name parse failed")

	# Concatenated content tool JSONs (two objects, no array wrapper).
	var multi_sample: String = (
		'{"choices":[{"message":{"role":"assistant","content":'
		+ '"{\\"name\\":\\"write_file\\",\\"arguments\\":{\\"path\\":\\"res://a.gd\\",\\"content\\":\\"x\\"}}\\n'
		+ '{\\"name\\":\\"set_property\\",\\"arguments\\":{\\"path\\":\\"AgentProbe\\",\\"property\\":\\"script\\",\\"value\\":\\"res://a.gd\\"}}"'
		+ "}}]}"
	)
	var multi_msg: Dictionary = ClientScript.parse_assistant_message(multi_sample)
	var multi_calls: Array = multi_msg.get("tool_calls", [])
	if multi_calls.size() != 2:
		failures.append("concatenated content tools should yield 2 calls, got %d" % multi_calls.size())
	elif str(multi_calls[0].get("function", {}).get("name", "")) != "write_file":
		failures.append("concatenated tools first name wrong")
	elif str(multi_calls[1].get("function", {}).get("name", "")) != "set_property":
		failures.append("concatenated tools second name wrong")


	# Blocked tools
	if not ToolsScript.is_blocked_tool("delete"):
		failures.append("delete should be blocked")
	if not ToolsScript.is_blocked_tool("project_settings"):
		failures.append("project_settings should be blocked")
	if ToolsScript.is_allowed_tool("delete"):
		failures.append("delete must not be allowed")
	if not ToolsScript.is_allowed_tool("delete_file"):
		failures.append("delete_file must be allowed")
	if not ToolsScript.is_write_tool("add_node"):
		failures.append("add_node is a write tool")
	if ToolsScript.is_write_tool("read_scene"):
		failures.append("read_scene is not a write tool")
	if ToolsScript.is_write_tool("play_scene"):
		failures.append("play_scene is not a write tool")
	if not ToolsScript.is_allowed_tool("play_scene"):
		failures.append("play_scene must be allowed")
	if not ToolsScript.is_write_tool("write_file") or not ToolsScript.is_write_tool("delete_file"):
		failures.append("write_file/delete_file must be write tools")
	if ToolsScript.is_write_tool("list_dir") or ToolsScript.is_write_tool("read_file"):
		failures.append("list_dir/read_file must not be write tools")
	if not ToolsScript.is_plan_tool("list_dir") or not ToolsScript.is_plan_tool("read_file"):
		failures.append("list_dir/read_file must be plan tools")
	if not ToolsScript.is_plan_tool("screenshot"):
		failures.append("screenshot must be a plan tool")
	if ToolsScript.is_write_tool("screenshot"):
		failures.append("screenshot must not be a write tool")
	if ToolsScript.is_plan_tool("write_file") or ToolsScript.is_plan_tool("delete_file"):
		failures.append("write_file/delete_file must not be plan tools")
	if not ToolsScript.is_always_confirm_tool("delete_file"):
		failures.append("delete_file must always confirm")
	if not ToolsScript.is_always_confirm_tool("write_file", {"path": "res://x.gd"}):
		failures.append("write_file .gd must always-confirm (policy)")
	if ToolsScript.is_always_confirm_tool("add_node", {}):
		failures.append("add_node must not always-confirm")
	if ToolsScript.is_always_confirm_tool("screenshot"):
		failures.append("screenshot must not ask")
	if not ToolsScript.is_plan_tool("check_page_drift"):
		failures.append("check_page_drift must be a plan tool")

	# Play result parsing (no live editor / no EditorInterface play)
	var ok_log: String = PlayScript.format_play_log({
		"ok": true,
		"phase": "play",
		"errors": [],
		"frame": "",
	})
	if ok_log.find("play_scene ok") < 0:
		failures.append("format_play_log ok line wrong: %s" % ok_log)
	var fail_errs: Array = [
		{"file": "res://broken.gd", "line": 2, "message": "Parse Error"},
		{"file": "", "line": 0, "message": "SCRIPT ERROR: Invalid syntax"},
	]
	var fail_log: String = PlayScript.format_play_log({
		"ok": false,
		"phase": "play",
		"errors": fail_errs,
	})
	if fail_log.find("play_scene failed") < 0 or fail_log.find("2 error") < 0:
		failures.append("format_play_log fail header missing: %s" % fail_log)
	if fail_log.find("Parse Error") < 0 or fail_log.find("SCRIPT ERROR") < 0:
		failures.append("format_play_log missing error lines")

	# DebuggerMarshalls::OutputError layout indices 4..9 → structured dict
	var output_error: Array = [
		0, 0, 0, 0,
		"res://broken.gd",
		"_ready",
		2,
		"Parse Error",
		"Expected indented block after function declaration",
		false,
		false,
	]
	var formatted_err: Dictionary = PlayScript.format_output_error_data(output_error)
	var err_msg: String = str(formatted_err.get("message", ""))
	if err_msg.find("error:") < 0:
		failures.append("format_output_error_data missing kind")
	if str(formatted_err.get("file", "")) != "res://broken.gd":
		failures.append("format_output_error_data missing file")
	if int(formatted_err.get("line", 0)) != 2:
		failures.append("format_output_error_data missing line")
	if err_msg.find("Expected indented block") < 0 and err_msg.find("Parse Error") < 0:
		failures.append("format_output_error_data missing message")

	var warn_error: Array = [
		0, 0, 0, 0,
		"res://x.gd",
		"",
		0,
		"Unused",
		"parameter 'x' is never used",
		true,
		false,
	]
	var formatted_warn: Dictionary = PlayScript.format_output_error_data(warn_error)
	if str(formatted_warn.get("message", "")).find("warning:") < 0:
		failures.append("format_output_error_data warning kind wrong")

	var out_msgs: Array = PlayScript.collect_output_message_errors([
		PackedStringArray(["info line", "SCRIPT ERROR: boom", "ok"]),
		PackedInt32Array([0, 1, 0]),
	])
	if out_msgs.size() != 1:
		failures.append("collect_output_message_errors should keep ERROR type only")
	elif str((out_msgs[0] as Dictionary).get("message", "")).find("SCRIPT ERROR") < 0:
		failures.append("collect_output_message_errors missing SCRIPT ERROR")

	# Tool result message shape
	var tr: Dictionary = ClientScript.tool_result_message(
		"call_1",
		{"ok": true, "name": "AgentProbe"}
	)
	if str(tr.get("role", "")) != "tool" or str(tr.get("tool_call_id", "")) != "call_1":
		failures.append("tool result message shape wrong")

	# Max rounds constant
	if ClientScript.MAX_TOOL_ROUNDS != 4:
		failures.append("MAX_TOOL_ROUNDS should be 4")

	# Do not touch EditorInterface — this script never references it.
	# Job stage transitions used by execute
	var job = JobScript.new("verify_execute_job")
	job.mode = JobScript.MODE_AUTO_APPROVE
	job.stage = JobScript.STAGE_RUNNING
	job.append_log(ToolsScript.BLOCKED_MESSAGE)
	job.stage = JobScript.STAGE_DONE
	if job.log_lines.is_empty() or str(job.log_lines[0]) != ToolsScript.BLOCKED_MESSAGE:
		failures.append("blocked message not recorded on job")

	if failures.is_empty():
		print("AgenticStudio verify_execute: OK")
		quit(0)
	else:
		print("AgenticStudio verify_execute: FAILED")
		for f: String in failures:
			print("  - ", f)
		quit(1)
