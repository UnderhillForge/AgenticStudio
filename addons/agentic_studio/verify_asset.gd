extends SceneTree
## Headless: inbox path parsing, stand-in copy, asset page + link. No EditorInterface import.
## Run: godot --headless --path . --script res://addons/agentic_studio/verify_asset.gd

const AssetScript = preload("res://addons/agentic_studio/asset_support.gd")
const PageScript = preload("res://addons/agentic_studio/page.gd")
const StoreScript = preload("res://addons/agentic_studio/page_store.gd")
const ToolsScript = preload("res://addons/agentic_studio/scene_tools.gd")
const ClientScript = preload("res://addons/agentic_studio/model_client.gd")
const ConfigScript = preload("res://addons/agentic_studio/config.gd")


func _initialize() -> void:
	var failures: PackedStringArray = PackedStringArray()
	StoreScript.ensure_dirs()
	AssetScript.ensure_inbox_dir()

	# Inbox path parsing
	var inbox: String = AssetScript.inbox_path_for("goblin_shaman", "stand_in.glb")
	if inbox != "res://inbox/goblin_shaman_stand_in.glb":
		failures.append("inbox_path_for unexpected: %s" % inbox)
	if not inbox.begins_with(AssetScript.INBOX_DIR + "/"):
		failures.append("inbox path not under inbox dir")

	# Stand-in fixture must exist
	var stand_in_abs: String = ProjectSettings.globalize_path(AssetScript.STAND_IN_GLB)
	if not FileAccess.file_exists(stand_in_abs):
		failures.append("stand-in GLB missing at %s" % AssetScript.STAND_IN_GLB)

	var copied: Dictionary = AssetScript.copy_stand_in_to_inbox("Goblin Shaman")
	if not bool(copied.get("ok", false)):
		failures.append("copy_stand_in failed: %s" % str(copied.get("error", "")))
	else:
		var dest: String = str(copied.get("path", ""))
		if dest.find("inbox/") < 0:
			failures.append("copied path not in inbox: %s" % dest)
		if not FileAccess.file_exists(ProjectSettings.globalize_path(dest)):
			failures.append("copied file missing on disk")

	# Decimate skip when Blender empty must not fail
	ConfigScript.ensure_dirs()
	var prev_blender: String = ConfigScript.get_blender_path()
	ConfigScript.set_blender_path("")
	var dec: Dictionary = AssetScript.maybe_decimate(str(copied.get("path", inbox)))
	if not bool(dec.get("ok", false)):
		failures.append("maybe_decimate should ok-skip with empty Blender")
	if not bool(dec.get("skipped", false)):
		failures.append("maybe_decimate should report skipped")
	ConfigScript.set_blender_path(prev_blender)

	# Asset page + link (project data)
	var char_path: String = StoreScript.path_for_title(
		PageScript.KIND_CHARACTER,
		"Verify Asset Character"
	)
	var char_page: Resource = PageScript.new()
	char_page.set("title", "Verify Asset Character")
	char_page.set("kind", PageScript.KIND_CHARACTER)
	char_page.set("notes", "headless character")
	char_page.set("tags", PackedStringArray())
	char_page.set("image_paths", PackedStringArray())
	char_page.set("links", PackedStringArray())
	var char_saved: Dictionary = StoreScript.save_page(char_page, char_path)
	if not bool(char_saved.get("ok", false)):
		failures.append("character page save failed")

	var asset_out: Dictionary = AssetScript.create_asset_page(
		"Verify Asset Character",
		str(copied.get("path", inbox))
	)
	if not bool(asset_out.get("ok", false)):
		failures.append("create_asset_page failed: %s" % str(asset_out.get("error", "")))
	var asset_path: String = str(asset_out.get("path", ""))
	if not asset_path.begins_with("res://studio/assets/"):
		failures.append("asset page not under studio/assets: %s" % asset_path)

	var linked: Dictionary = StoreScript.add_link_static(char_path, asset_path)
	if not bool(linked.get("ok", false)):
		failures.append("link failed: %s" % str(linked.get("error", "")))
	var reloaded: Resource = StoreScript.load_page(char_path)
	var links: PackedStringArray = PackedStringArray(
		reloaded.get("links") if reloaded else PackedStringArray()
	)
	if not links.has(asset_path):
		failures.append("character page missing link to asset")

	# Tool list: create_asset is write, not plan
	if ToolsScript.tool_definitions().size() != 29:
		failures.append(
			"expected 29 tools, got %d" % ToolsScript.tool_definitions().size()
		)
	if not ToolsScript.is_write_tool("create_asset"):
		failures.append("create_asset must be a write tool")
	if ToolsScript.is_plan_tool("create_asset"):
		failures.append("create_asset must not be a plan tool")
	if not ToolsScript.is_allowed_tool("create_asset"):
		failures.append("create_asset must be allowed")

	var plan_body: String = ClientScript.build_plan_body({"model_name": "x"}, "hi")
	if plan_body.find("\"name\":\"create_asset\"") >= 0 \
			or plan_body.find("\"name\": \"create_asset\"") >= 0:
		failures.append("Plan tools must not include create_asset")
	var exec_body: String = ClientScript.build_chat_body(
		{"model_name": "x"},
		ClientScript.initial_execute_messages("make asset"),
		true
	)
	if exec_body.find("\"name\":\"create_asset\"") < 0 \
			and exec_body.find("\"name\": \"create_asset\"") < 0:
		failures.append("execute body missing create_asset tool")

	# Cleanup headless pages (leave fixture + inbox copy)
	for p: String in [char_path, asset_path]:
		var abs_p: String = ProjectSettings.globalize_path(p)
		if FileAccess.file_exists(abs_p):
			DirAccess.remove_absolute(abs_p)

	if failures.is_empty():
		print("AgenticStudio verify_asset: OK")
		quit(0)
	else:
		print("AgenticStudio verify_asset: FAILED")
		for f: String in failures:
			print("  - ", f)
		quit(1)
