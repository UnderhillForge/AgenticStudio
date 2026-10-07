extends SceneTree
## Headless: save/load a character page with one image path. No EditorInterface.
## Run: godot --headless --path . --script res://addons/agentic_studio/verify_pages.gd

const PageScript = preload("res://addons/agentic_studio/page.gd")
const StoreScript = preload("res://addons/agentic_studio/page_store.gd")
const ToolsScript = preload("res://addons/agentic_studio/scene_tools.gd")
const ClientScript = preload("res://addons/agentic_studio/model_client.gd")


func _initialize() -> void:
	var failures: PackedStringArray = PackedStringArray()
	StoreScript.ensure_dirs()

	if not DirAccess.dir_exists_absolute(
		ProjectSettings.globalize_path(StoreScript.CHARACTERS_DIR)
	):
		failures.append("characters dir missing after ensure_dirs")
	if not DirAccess.dir_exists_absolute(
		ProjectSettings.globalize_path(StoreScript.ASSETS_DIR)
	):
		failures.append("assets dir missing after ensure_dirs")

	var page: Resource = PageScript.new()
	page.set("title", "Verify Goblin")
	page.set("kind", PageScript.KIND_CHARACTER)
	page.set("notes", "Headless note for verify goblin")
	page.set("tags", PackedStringArray(["goblin", "verify"]))
	page.set("image_paths", PackedStringArray(["res://studio/characters/verify_goblin_images/thumb.png"]))
	page.set("links", PackedStringArray())

	var save_path: String = StoreScript.path_for_title(
		PageScript.KIND_CHARACTER,
		"Verify Goblin"
	)
	var saved: Dictionary = StoreScript.save_page(page, save_path)
	if not bool(saved.get("ok", false)):
		failures.append("save_page failed: %s" % str(saved.get("error", "")))
	if str(saved.get("path", "")) != save_path:
		failures.append("save path mismatch")

	var loaded: Resource = StoreScript.load_page(save_path)
	if loaded == null:
		failures.append("load_page returned null")
	else:
		if str(loaded.get("title")) != "Verify Goblin":
			failures.append("loaded title wrong")
		if str(loaded.get("notes")) != "Headless note for verify goblin":
			failures.append("loaded notes wrong")
		var images: PackedStringArray = PackedStringArray(loaded.get("image_paths"))
		if images.size() != 1 or images[0].find("thumb.png") < 0:
			failures.append("loaded image_paths wrong: %s" % str(images))

	var listed: Array = StoreScript.list_pages()
	var found: bool = false
	for item: Variant in listed:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		if str((item as Dictionary).get("path", "")) == save_path:
			found = true
			if str((item as Dictionary).get("kind", "")) != PageScript.KIND_CHARACTER:
				failures.append("list_pages kind wrong")
	if not found:
		failures.append("list_pages missing saved page")

	# Tool definitions: Plan gets read page tools only; execute includes link.
	var plan_tools: Array = ToolsScript.plan_tool_definitions()
	if plan_tools.size() != 6:
		failures.append("plan tools expected 6, got %d" % plan_tools.size())
	var plan_names: PackedStringArray = PackedStringArray()
	for t: Variant in plan_tools:
		if t is Dictionary:
			var fn: Variant = (t as Dictionary).get("function", {})
			if fn is Dictionary:
				plan_names.append(str((fn as Dictionary).get("name", "")))
	if not plan_names.has("list_pages") or not plan_names.has("get_page"):
		failures.append("plan tools missing list_pages/get_page")
	if not plan_names.has("list_dir") or not plan_names.has("read_file"):
		failures.append("plan tools missing list_dir/read_file")
	if plan_names.has("link"):
		failures.append("plan tools must not include link")

	var all_tools: Array = ToolsScript.tool_definitions()
	if all_tools.size() != 30:
		failures.append("expected 30 execute tools, got %d" % all_tools.size())
	if not plan_names.has("check_page_drift"):
		failures.append("plan tools missing check_page_drift")
	if not ToolsScript.is_write_tool("link"):
		failures.append("link must be a write tool")
	if not ToolsScript.is_write_tool("create_asset"):
		failures.append("create_asset must be a write tool")
	if ToolsScript.is_write_tool("list_pages") or ToolsScript.is_write_tool("get_page"):
		failures.append("list_pages/get_page must not be write tools")
	if not ToolsScript.is_plan_tool("list_pages"):
		failures.append("list_pages should be a plan tool")
	if ToolsScript.is_plan_tool("link") or ToolsScript.is_plan_tool("create_asset"):
		failures.append("link/create_asset must not be plan tools")

	var plan_body: String = ClientScript.build_plan_body({"model_name": "x"}, "hi")
	if plan_body.find("list_pages") < 0:
		failures.append("Plan body should include list_pages")
	if plan_body.find("\"link\"") >= 0 or plan_body.find("link") >= 0 and plan_body.find("get_page") < 0:
		# Allow the word only if it's not the link tool — check tools array carefully.
		pass
	# System prompt may mention banned ops by name; check tool JSON only.
	if plan_body.find("\"name\":\"add_node\"") >= 0 or plan_body.find("\"name\": \"add_node\"") >= 0:
		failures.append("Plan body must not include add_node tool")
	# Explicit: link tool name as JSON function name should be absent.
	if plan_body.find("\"name\":\"link\"") >= 0 or plan_body.find("\"name\": \"link\"") >= 0:
		failures.append("Plan body must not include link tool")

	# get_page / list_pages via tools without EditorInterface
	var tools = ToolsScript.new()
	tools.setup("verify_pages_job")
	var list_out: Dictionary = tools.execute("list_pages", {})
	if not bool(list_out.get("ok", false)):
		failures.append("list_pages tool failed")
	var get_out: Dictionary = tools.execute("get_page", {"path": "Verify Goblin"})
	if not bool(get_out.get("ok", false)):
		failures.append("get_page tool failed")
	else:
		var result: Dictionary = get_out.get("result", {})
		if str(result.get("notes", "")).find("Headless note") < 0:
			failures.append("get_page notes missing")

	# delete_page strips links and removes the .tres
	var other_path: String = StoreScript.path_for_title(
		PageScript.KIND_ASSET,
		"Verify Link Target"
	)
	var other: Resource = PageScript.new()
	other.set("title", "Verify Link Target")
	other.set("kind", PageScript.KIND_ASSET)
	other.set("notes", "link target")
	other.set("tags", PackedStringArray())
	other.set("image_paths", PackedStringArray())
	other.set("links", PackedStringArray([save_path]))
	var other_saved: Dictionary = StoreScript.save_page(other, other_path)
	if not bool(other_saved.get("ok", false)):
		failures.append("could not save link-target page")
	var deleted: Dictionary = StoreScript.delete_page(save_path)
	if not bool(deleted.get("ok", false)):
		failures.append("delete_page failed: %s" % str(deleted.get("error", "")))
	if FileAccess.file_exists(ProjectSettings.globalize_path(save_path)):
		failures.append("page file still exists after delete_page")
	var other_reloaded: Resource = StoreScript.load_page(other_path)
	if other_reloaded != null:
		var other_links: PackedStringArray = PackedStringArray(other_reloaded.get("links"))
		if other_links.has(save_path):
			failures.append("delete_page left inbound link")
		var other_abs: String = ProjectSettings.globalize_path(other_path)
		if FileAccess.file_exists(other_abs):
			DirAccess.remove_absolute(other_abs)

	if failures.is_empty():
		print("AgenticStudio verify_pages: OK")
		quit(0)
	else:
		print("AgenticStudio verify_pages: FAILED")
		for f: String in failures:
			print("  - ", f)
		quit(1)
