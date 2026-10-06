extends SceneTree
## Headless: file tools path rules, plan/write flags, fifth-write refuse. No EditorInterface.
## Run: godot --headless --path . --script res://addons/agentic_studio/verify_files.gd

const ToolsScript = preload("res://addons/agentic_studio/scene_tools.gd")
const FileScript = preload("res://addons/agentic_studio/file_support.gd")
const ClientScript = preload("res://addons/agentic_studio/model_client.gd")


func _initialize() -> void:
	var failures: PackedStringArray = PackedStringArray()

	# Path normalization
	var ok_norm: Dictionary = FileScript.normalize_res_path("scripts/foo.gd")
	if not bool(ok_norm.get("ok", false)) or str(ok_norm.get("path", "")) != "res://scripts/foo.gd":
		failures.append("normalize should prefix res://")
	var user_norm: Dictionary = FileScript.normalize_res_path("user://agentic_studio.cfg")
	if bool(user_norm.get("ok", false)):
		failures.append("user:// must be refused")
	var escape_norm: Dictionary = FileScript.normalize_res_path("res://../outside.gd")
	if bool(escape_norm.get("ok", false)):
		failures.append(".. escape must be refused")

	# list_dir / read_file against project files
	var listed: Dictionary = FileScript.list_dir("res://addons/agentic_studio")
	if not bool(listed.get("ok", false)):
		failures.append("list_dir failed: %s" % str(listed.get("error", "")))
	else:
		var found_tools: bool = false
		for e: Variant in listed.get("entries", []):
			if typeof(e) == TYPE_DICTIONARY and str((e as Dictionary).get("name", "")) == "scene_tools.gd":
				found_tools = true
				break
		if not found_tools:
			failures.append("list_dir missing scene_tools.gd")

	var read_out: Dictionary = FileScript.read_text_file("res://addons/agentic_studio/plugin.cfg")
	if not bool(read_out.get("ok", false)):
		failures.append("read_file plugin.cfg failed")
	elif str(read_out.get("content", "")).find("AgenticStudio") < 0:
		failures.append("read_file content unexpected")

	var bin_read: Dictionary = FileScript.read_text_file("res://addons/agentic_studio/icon.svg")
	# svg is listed as binary extension — refuse
	if bool(bin_read.get("ok", false)):
		failures.append("read_file should refuse svg binary extension")

	# write + delete round-trip under res:// (temp)
	var tmp_path: String = "res://_verify_files_probe.gd"
	var abs_tmp: String = ProjectSettings.globalize_path(tmp_path)
	if FileAccess.file_exists(abs_tmp):
		DirAccess.remove_absolute(abs_tmp)
	var wrote: Dictionary = FileScript.write_text_file(tmp_path, "extends Node\n")
	if not bool(wrote.get("ok", false)):
		failures.append("write_text_file failed: %s" % str(wrote.get("error", "")))
	elif not FileAccess.file_exists(abs_tmp):
		failures.append("write_text_file did not create file")
	elif bool(wrote.get("existed", true)):
		failures.append("new file should report existed=false")

	var rewrite: Dictionary = FileScript.write_text_file(tmp_path, "extends Node\n# v2\n")
	if not bool(rewrite.get("ok", false)):
		failures.append("rewrite failed")
	elif not bool(rewrite.get("existed", false)):
		failures.append("rewrite should report existed=true")
	elif str(rewrite.get("previous", "")).find("extends Node") < 0:
		failures.append("rewrite previous content missing")

	var del_user: Dictionary = FileScript.delete_text_file("user://agentic_studio.cfg")
	if bool(del_user.get("ok", false)):
		failures.append("delete_file must refuse user://")

	var del_logs: Dictionary = FileScript.delete_text_file("user://agentic_studio/logs/studio.log")
	if bool(del_logs.get("ok", false)):
		failures.append("delete_file must refuse user://agentic_studio/logs/")
	if str(del_logs.get("error", "")).find("logs") < 0 \
			and str(del_logs.get("error", "")).find("user://") < 0:
		failures.append("delete_file logs refusal should mention logs or user://")

	var del_png: Dictionary = FileScript.delete_text_file("res://icon.svg")
	if bool(del_png.get("ok", false)):
		failures.append("delete_file must refuse non page/scene/script kinds")

	var deleted: Dictionary = FileScript.delete_text_file(tmp_path)
	if not bool(deleted.get("ok", false)):
		failures.append("delete_text_file failed: %s" % str(deleted.get("error", "")))
	elif FileAccess.file_exists(abs_tmp):
		failures.append("delete_text_file left file on disk")

	# Tool flags (14 = prior 13 + check_page_drift; plan 6 = prior 5 + drift)
	if ToolsScript.tool_definitions().size() != 14:
		failures.append("expected 14 tools, got %d" % ToolsScript.tool_definitions().size())
	if ToolsScript.plan_tool_definitions().size() != 6:
		failures.append("expected 6 plan tools, got %d" % ToolsScript.plan_tool_definitions().size())
	if not ToolsScript.is_always_confirm_tool("delete_file"):
		failures.append("delete_file must always confirm")
	if ToolsScript.is_plan_tool("write_file"):
		failures.append("write_file must not be a plan tool")

	var plan_body: String = ClientScript.build_plan_body({"model_name": "x"}, "hi")
	if plan_body.find("list_dir") < 0 or plan_body.find("read_file") < 0:
		failures.append("Plan body missing file read tools")
	if plan_body.find("\"name\":\"write_file\"") >= 0 \
			or plan_body.find("\"name\": \"write_file\"") >= 0:
		failures.append("Plan body must not include write_file")

	# Fifth write refuse (no EditorInterface — only the cap path before scene ops)
	var tools = ToolsScript.new()
	tools.setup("verify_files_cap")
	tools._write_ops = 4
	var refused: Dictionary = tools.execute("write_file", {
		"path": "res://_should_not_write.gd",
		"content": "extends Node\n",
	})
	if not bool(refused.get("refused", false)):
		failures.append("fifth write should be refused")
	if str(refused.get("log", "")).find("refused fifth write") < 0:
		failures.append("fifth write log missing refuse message")
	if FileAccess.file_exists(ProjectSettings.globalize_path("res://_should_not_write.gd")):
		failures.append("refused write must not create file")
		DirAccess.remove_absolute(ProjectSettings.globalize_path("res://_should_not_write.gd"))

	if failures.is_empty():
		print("AgenticStudio verify_files: OK")
		quit(0)
	else:
		print("AgenticStudio verify_files: FAILED")
		for f: String in failures:
			print("  - ", f)
		quit(1)
