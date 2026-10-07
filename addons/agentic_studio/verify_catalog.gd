extends SceneTree
## Headless: harness tool catalog — planner/coder lists, class_get, policy, session jsonl.
## Run: godot --headless --path . --script res://addons/agentic_studio/verify_catalog.gd

const PolicyScript = preload("res://addons/agentic_studio/policy.gd")
const ToolsScript = preload("res://addons/agentic_studio/scene_tools.gd")
const EditorOpsScript = preload("res://addons/agentic_studio/editor_ops.gd")
const SessionLogScript = preload("res://addons/agentic_studio/session_log.gd")
const ClientScript = preload("res://addons/agentic_studio/model_client.gd")
const ConfigScript = preload("res://addons/agentic_studio/config.gd")


func _initialize() -> void:
	var failures: PackedStringArray = PackedStringArray()

	# --- Planner tool list has reads including class_get, not writes ---
	var plan_tools: Array = ToolsScript.plan_tool_definitions()
	var plan_names: PackedStringArray = PackedStringArray()
	for t: Variant in plan_tools:
		if typeof(t) != TYPE_DICTIONARY:
			continue
		var fn: Variant = (t as Dictionary).get("function", {})
		if typeof(fn) == TYPE_DICTIONARY:
			plan_names.append(str((fn as Dictionary).get("name", "")))
	for need: String in [
		"list_pages", "get_page", "check_page_drift", "scene_hierarchy", "node_properties",
		"class_get", "signal_list", "resource_find", "input_map_list", "list_dir", "read_file",
		"log_read", "editor_screenshot", "screenshot",
	]:
		if not plan_names.has(need):
			failures.append("planner missing %s" % need)
	for banned: String in [
		"add_node", "set_property", "node_reparent", "signal_connect", "script_patch",
		"input_map_ensure", "write_file", "delete_file", "play_scene", "create_asset", "link",
	]:
		if plan_names.has(banned):
			failures.append("planner must not have %s" % banned)
	if plan_tools.size() != 14:
		failures.append("planner tool count %d want 14" % plan_tools.size())

	# Write-shaped planner reply discarded (does not hit apply)
	if not ClientScript.planner_response_has_write(
		"", [{"function": {"name": "add_node", "arguments": "{}"}}]
	):
		failures.append("planner write reply must be detected")
	if ClientScript.PLAN_SYSTEM_PROMPT.find("class_get") < 0:
		failures.append("planner prompt must name class_get")
	if ClientScript.PLAN_SYSTEM_PROMPT.find("apply API") < 0 \
			and ClientScript.PLAN_SYSTEM_PROMPT.find("never receive the apply") < 0:
		failures.append("planner prompt must say no apply API")
	if ClientScript.EXECUTE_SYSTEM_PROMPT.find("play_scene is the plugin gate") < 0:
		failures.append("coder prompt must say play_scene is plugin gate")

	# --- class_get MeshInstance3D short list; second class rejected ---
	var ops = EditorOpsScript.new()
	var cg: Dictionary = ops.class_get({"class": "MeshInstance3D"})
	if not bool(cg.get("ok", false)):
		failures.append("class_get MeshInstance3D failed: %s" % str(cg.get("error", "")))
	else:
		var props: Array = cg.get("result", {}).get("properties", [])
		if props.is_empty():
			failures.append("class_get MeshInstance3D empty properties")
		if props.size() > 64:
			failures.append("class_get property list too long: %d" % props.size())
	var multi: Dictionary = ops.class_get({"class": "MeshInstance3D,Node3D"})
	if bool(multi.get("ok", false)):
		failures.append("class_get must reject second class in one call")
	var multi2: Dictionary = ops.class_get({"classes": ["MeshInstance3D", "Node3D"]})
	if bool(multi2.get("ok", false)):
		failures.append("class_get must reject classes array")

	# --- Coder tool list has full catalog; no play_scene ---
	var coder_tools: Array = ToolsScript.tool_definitions()
	var coder_names: PackedStringArray = PackedStringArray()
	for t2: Variant in coder_tools:
		if typeof(t2) != TYPE_DICTIONARY:
			continue
		var fn2: Variant = (t2 as Dictionary).get("function", {})
		if typeof(fn2) == TYPE_DICTIONARY:
			coder_names.append(str((fn2 as Dictionary).get("name", "")))
	if coder_names.has("play_scene"):
		failures.append("coder model tools must not include play_scene")
	for need2: String in [
		"class_get", "add_node", "set_property", "node_reparent", "signal_connect",
		"resource_assign", "script_patch", "input_map_ensure", "create_asset", "link",
	]:
		if not coder_names.has(need2):
			failures.append("coder missing %s" % need2)
	if coder_tools.size() != 29:
		failures.append("coder tool count %d want 29" % coder_tools.size())

	# --- set_property absent from snapshot rejected (helper) ---
	if not ToolsScript.new().has_method("_node_snapshot_has_property"):
		# Method exists on instance after setup — probe via a fake Node
		pass
	var probe := Node3D.new()
	var tools = ToolsScript.new()
	tools.setup("verify_catalog")
	# Without EditorInterface edited scene, set_property fails on no open scene —
	# still assert the helper rejects a nonsense property name on a live node.
	if tools._node_snapshot_has_property(probe, "this_property_does_not_exist_xyz"):
		failures.append("snapshot must not claim unknown property")
	if not tools._node_snapshot_has_property(probe, "position"):
		failures.append("snapshot should include position on Node3D")
	probe.free()

	# --- signal_connect missing method / script_patch / input_map / page_id (policy) ---
	if PolicyScript.is_allowed_unattended("input_map_ensure", {"action": "x"}):
		failures.append("input_map_ensure must not auto-approve")
	if not PolicyScript.needs_confirm("script_patch", {"path": "res://a.gd"}):
		failures.append("script_patch must needs_confirm")
	if PolicyScript.classify("class_get", {}) != PolicyScript.DECISION_ALLOW:
		failures.append("class_get policy allow")

	var missing: Dictionary = tools.execute(
		"node_rename", {"path": "A", "name": "B", "page_id": ""}
	)
	var err: String = str(missing.get("error", ""))
	if err.find("page_id") < 0 and str(missing.get("log", "")).find("page_id") < 0:
		if err.find("no open scene") < 0:
			failures.append("missing page_id must be rejected: %s" % err)

	# --- Session jsonl: op name, role, page id; never key; never class_get dump ---
	SessionLogScript.ensure_dirs()
	tools._record_op("class_get", {"class": "MeshInstance3D"})
	var last_op: Dictionary = {}
	if not tools.ops_log.is_empty():
		last_op = tools.ops_log[tools.ops_log.size() - 1]
	if str(last_op.get("tool", "")) != "class_get":
		failures.append("ops_log missing class_get")
	if last_op.has("properties") or last_op.has("methods") or last_op.has("signals"):
		failures.append("ops_log must not dump class_get members")
	SessionLogScript.append_plan_or_run(
		"model_catalog",
		"plan",
		PackedStringArray(["goblin_shaman"]),
		[last_op, {"tool": "get_page", "page_id": "goblin_shaman"}],
		null,
		{
			"id": "model_catalog",
			"display_name": "Catalog",
			"role": "planner",
			"api_key": "SECRET_KEY_XYZ",
			"base_url": "http://127.0.0.1:9/v1",
		}
	)
	var text: String = FileAccess.get_file_as_string(SessionLogScript.path_for_day())
	if text.find("class_get") < 0:
		failures.append("session jsonl missing class_get op name")
	if text.find("goblin_shaman") < 0:
		failures.append("session jsonl missing page id")
	if text.find("planner") < 0 and text.find("\"role\":\"planner\"") < 0:
		# role field from model_log_fields
		if text.find("\"role\"") < 0:
			failures.append("session jsonl missing role")
	if text.find("SECRET_KEY_XYZ") >= 0:
		failures.append("session jsonl leaked api key")
	if text.find("mesh") >= 0 and text.find("\"properties\"") >= 0:
		# Avoid false positive on unrelated mesh words; check for dumped property arrays
		if text.find("\"properties\":[") >= 0:
			failures.append("session jsonl must not contain class_get dump")

	# editor_screenshot path distinct constant
	if EditorOpsScript.PLAY_FRAME_PATH != "user://agentic/last_frame.png":
		failures.append("play frame path drifted")

	# Prompts must not embed a class index URL / dump
	for prompt: String in [ClientScript.PLAN_SYSTEM_PROMPT, ClientScript.EXECUTE_SYSTEM_PROMPT]:
		if prompt.find("docs.godotengine.org") >= 0:
			failures.append("prompt must not load godot docs class index")
		if prompt.find("classes/index.html") >= 0:
			failures.append("prompt must not reference class index html")

	if failures.is_empty():
		print("AgenticStudio verify_catalog: OK")
		quit(0)
		return
	print("AgenticStudio verify_catalog: FAILED")
	for f: String in failures:
		print("  - ", f)
	quit(1)
