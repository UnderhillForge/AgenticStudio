extends SceneTree
## Headless: image_generate / mesh_from_image settings, spawn gate, page attach, mesh miss.
## Run: godot --headless --path . --script res://addons/agentic_studio/verify_generate.gd

const ConfigScript = preload("res://addons/agentic_studio/config.gd")
const GenerateScript = preload("res://addons/agentic_studio/generate_support.gd")
const PageScript = preload("res://addons/agentic_studio/page.gd")
const StoreScript = preload("res://addons/agentic_studio/page_store.gd")
const ToolsScript = preload("res://addons/agentic_studio/scene_tools.gd")
const PolicyScript = preload("res://addons/agentic_studio/policy.gd")
const ClientScript = preload("res://addons/agentic_studio/model_client.gd")
const SessionLogScript = preload("res://addons/agentic_studio/session_log.gd")


func _initialize() -> void:
	var failures: PackedStringArray = PackedStringArray()
	ConfigScript.ensure_dirs()
	StoreScript.ensure_dirs()

	var prev_cli: String = ConfigScript.get_drawthings_cli()
	var prev_models: String = ConfigScript.get_drawthings_models_dir()
	var prev_model: String = ConfigScript.get_drawthings_model()
	var prev_blender: String = ConfigScript.get_blender_path()

	# --- Missing CLI path fails before spawn ---
	ConfigScript.set_drawthings_cli("")
	ConfigScript.set_drawthings_models_dir("/tmp")
	ConfigScript.set_drawthings_model("dummy.ckpt")
	var missing_cli: Dictionary = GenerateScript.validate_drawthings_settings()
	if bool(missing_cli.get("ok", false)):
		failures.append("empty drawthings_cli must fail validation")
	elif str(missing_cli.get("error", "")).find("drawthings_cli") < 0:
		failures.append("missing CLI error must name drawthings_cli: %s" % str(missing_cli.get("error", "")))
	var spawned: Dictionary = GenerateScript.run_image_generate("should not spawn", "goblin_shaman")
	if bool(spawned.get("ok", false)):
		failures.append("run_image_generate must not succeed with empty CLI")
	elif str(spawned.get("error", "")).find("drawthings_cli") < 0:
		failures.append("pre-spawn failure must name drawthings_cli")

	# --- Fake CLI writes PNG and attaches to page; no hardcoded checkpoint ---
	var fake_cli: String = ProjectSettings.globalize_path("res://fixtures/fake_drawthings_cli.sh")
	if not FileAccess.file_exists(fake_cli):
		failures.append("fixtures/fake_drawthings_cli.sh missing")
	var models_dir: String = ProjectSettings.globalize_path("res://fixtures")
	ConfigScript.set_drawthings_cli(fake_cli)
	ConfigScript.set_drawthings_models_dir(models_dir)
	# Deliberately not the real ERNIE filename — settings must drive this.
	ConfigScript.set_drawthings_model("verify_fake_model.ckpt")

	var page_path: String = StoreScript.path_for_title(PageScript.KIND_CHARACTER, "Verify Generate Char")
	var page: Resource = PageScript.new()
	page.set("title", "Verify Generate Char")
	page.set("kind", PageScript.KIND_CHARACTER)
	page.set("notes", "generate verify")
	page.set("tags", PackedStringArray())
	page.set("image_paths", PackedStringArray())
	page.set("links", PackedStringArray())
	var saved: Dictionary = StoreScript.save_page(page, page_path)
	if not bool(saved.get("ok", false)):
		failures.append("page save failed")

	var gen: Dictionary = GenerateScript.run_image_generate(
		"a verify cube", "verify_generate_char"
	)
	if not bool(gen.get("ok", false)):
		failures.append("fake CLI generate failed: %s" % str(gen.get("error", "")))
	else:
		var png: String = str(gen.get("path", ""))
		if not png.begins_with("res://studio/generated/"):
			failures.append("PNG not under studio/generated: %s" % png)
		if not png.ends_with(".png"):
			failures.append("output not png: %s" % png)
		if not FileAccess.file_exists(ProjectSettings.globalize_path(png)):
			failures.append("PNG missing on disk: %s" % png)
		var attached: Dictionary = GenerateScript.attach_image_to_page(page_path, png)
		if not bool(attached.get("ok", false)):
			failures.append("attach_image_to_page failed: %s" % str(attached.get("error", "")))
		var reloaded: Resource = StoreScript.load_page(page_path)
		var images: PackedStringArray = PackedStringArray(
			reloaded.get("image_paths") if reloaded else PackedStringArray()
		)
		if not images.has(png):
			failures.append("page images missing generated PNG")
		# image_generate must not require / create a scene node — support path has no add_child.
		if GenerateScript.new().has_method("import_and_instance"):
			failures.append("generate_support must not instance scene nodes")

	# --- mesh_from_image without a mesh file fails named and does not write a .glb ---
	var page2: Resource = StoreScript.load_page(page_path)
	# Ensure an image is on the page (from above) but no mesh.
	var mesh_find: Dictionary = GenerateScript.find_mesh_on_page(page2)
	if bool(mesh_find.get("ok", false)):
		failures.append("page should not already have a mesh for this check")
	else:
		var err_m: String = str(mesh_find.get("error", ""))
		if err_m.find("no mesh on page yet") < 0 and err_m.find("image-to-mesh") < 0:
			failures.append("missing-mesh error must be named: %s" % err_m)
	var before_glbs: PackedStringArray = _list_generated_glbs("verify_generate_char")
	ConfigScript.set_blender_path("")  # would also fail blender; mesh miss should win first in tool
	# Direct find path (tool checks image-on-page then mesh).
	if page2 != null and not GenerateScript.page_has_image(page2, str(gen.get("path", ""))):
		# If gen failed earlier, skip attach-dependent checks.
		pass
	else:
		var dec: Dictionary = GenerateScript.decimate_export_mesh("", "verify_generate_char")
		if bool(dec.get("ok", false)):
			failures.append("decimate_export_mesh with empty source must fail")
		elif str(dec.get("error", "")).find("no mesh") < 0 \
				and str(dec.get("error", "")).find("image-to-mesh") < 0 \
				and str(dec.get("error", "")).find("blender_path") < 0:
			# Empty source → no mesh named error.
			failures.append("empty mesh export error unexpected: %s" % str(dec.get("error", "")))
	var after_glbs: PackedStringArray = _list_generated_glbs("verify_generate_char")
	if after_glbs.size() > before_glbs.size():
		failures.append("mesh miss must not write a new .glb")

	# blender_path missing fails mesh tool settings
	ConfigScript.set_blender_path("")
	var bl: Dictionary = GenerateScript.validate_blender_path()
	if bool(bl.get("ok", false)) or str(bl.get("error", "")).find("blender_path") < 0:
		failures.append("empty blender_path must fail named for mesh step")

	# --- Policy / planner / coder catalog ---
	if PolicyScript.classify("image_generate", {"page_id": "x"}) != PolicyScript.DECISION_ALLOW:
		failures.append("image_generate must be allow")
	if PolicyScript.classify("mesh_from_image", {"page_id": "x"}) != PolicyScript.DECISION_CONFIRM:
		failures.append("mesh_from_image must be confirm")
	if PolicyScript.is_allowed_unattended("mesh_from_image", {"page_id": "x"}):
		failures.append("mesh_from_image must not auto-approve")
	if ToolsScript.is_plan_tool("image_generate") or ToolsScript.is_plan_tool("mesh_from_image"):
		failures.append("planner must not include image/mesh generate")
	if not ToolsScript.is_write_tool("image_generate") or not ToolsScript.is_write_tool("mesh_from_image"):
		failures.append("image/mesh tools must be write tools")
	if ClientScript.planner_response_has_write(
		"", [{"function": {"name": "image_generate", "arguments": "{}"}}]
	) == false:
		failures.append("planner image_generate reply must be detected as write")
	if ClientScript.PLAN_SYSTEM_PROMPT.find("image_generate") < 0:
		failures.append("planner prompt must mention not calling image_generate")
	if ClientScript.EXECUTE_SYSTEM_PROMPT.find("image_generate") < 0:
		failures.append("coder prompt must name image_generate")
	if ClientScript.EXECUTE_SYSTEM_PROMPT.find("mesh_from_image") < 0:
		failures.append("coder prompt must name mesh_from_image")

	var coder_n: int = ToolsScript.tool_definitions().size()
	if coder_n != 31:
		failures.append("coder tool count %d want 31" % coder_n)
	var plan_n: int = ToolsScript.plan_tool_definitions().size()
	if plan_n != 14:
		failures.append("planner tool count %d want 14" % plan_n)

	# --- resource_assign still requires page_id (policy/tool contract) ---
	var tools = ToolsScript.new()
	tools.setup("verify_generate")
	var ra: Dictionary = tools.execute(
		"resource_assign",
		{"path": "Mesh", "property": "mesh", "resource": "res://x.glb", "page_id": ""}
	)
	var ra_err: String = str(ra.get("error", "")) + str(ra.get("log", ""))
	if ra_err.find("page_id") < 0 and ra_err.find("no open scene") < 0:
		failures.append("resource_assign without page_id must reject: %s" % ra_err)

	# --- Session jsonl records op, page id, output path, never a key ---
	var out_path: String = str(gen.get("path", "res://studio/generated/verify_generate_char/gen_0.png"))
	SessionLogScript.append_plan_or_run(
		"verify_generate_model",
		"auto_approve",
		PackedStringArray(["verify_generate_char"]),
		[{"tool": "image_generate", "page_id": "verify_generate_char", "path": out_path}],
		null,
		{"id": "verify_generate_model", "role": "coder", "display_name": "Verify", "kind": "local"}
	)
	var lines: PackedStringArray = SessionLogScript.read_recent_lines(5)
	var found_line := false
	for line: String in lines:
		if line.find("image_generate") >= 0 and line.find("verify_generate_char") >= 0:
			found_line = true
			if line.find("api_key") >= 0 or line.find("Authorization") >= 0:
				failures.append("session jsonl must never contain a key")
			if line.find(out_path) < 0 and line.find("studio/generated") < 0:
				failures.append("session jsonl should include output path")
	if not found_line:
		failures.append("session jsonl missing image_generate entry")

	# Restore settings
	ConfigScript.set_drawthings_cli(prev_cli)
	ConfigScript.set_drawthings_models_dir(prev_models)
	ConfigScript.set_drawthings_model(prev_model)
	ConfigScript.set_blender_path(prev_blender)

	# Cleanup verify page + generated files for this slug
	var gen_dir: String = ProjectSettings.globalize_path("res://studio/generated/verify_generate_char")
	if DirAccess.dir_exists_absolute(gen_dir):
		var da: DirAccess = DirAccess.open("res://studio/generated/verify_generate_char")
		if da != null:
			da.list_dir_begin()
			var n: String = da.get_next()
			while n != "":
				if not da.current_is_dir() and not n.begins_with("."):
					da.remove(n)
				n = da.get_next()
			da.list_dir_end()
	var abs_page: String = ProjectSettings.globalize_path(page_path)
	if FileAccess.file_exists(abs_page):
		DirAccess.remove_absolute(abs_page)

	if failures.is_empty():
		print("AgenticStudio verify_generate: OK")
		quit(0)
		return
	print("AgenticStudio verify_generate: FAILED")
	for f: String in failures:
		print("  - ", f)
	quit(1)


func _list_generated_glbs(page_slug: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var dir_path: String = "res://studio/generated/%s" % page_slug
	var abs_dir: String = ProjectSettings.globalize_path(dir_path)
	if not DirAccess.dir_exists_absolute(abs_dir):
		return out
	var da: DirAccess = DirAccess.open(dir_path)
	if da == null:
		return out
	da.list_dir_begin()
	var name: String = da.get_next()
	while name != "":
		if not da.current_is_dir() and name.ends_with(".glb"):
			out.append("%s/%s" % [dir_path, name])
		name = da.get_next()
	da.list_dir_end()
	return out
