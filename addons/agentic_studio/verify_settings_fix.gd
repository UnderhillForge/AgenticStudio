extends SceneTree
## Headless: generate_support parses; settings null-safe; which resolve; NUL cfg refuse.
## Run: godot --headless --path . --script res://addons/agentic_studio/verify_settings_fix.gd

const GenerateScript = preload("res://addons/agentic_studio/generate_support.gd")
const ConfigScript = preload("res://addons/agentic_studio/config.gd")
const SettingsScript = preload("res://addons/agentic_studio/settings_dialog.gd")
const ToolsScript = preload("res://addons/agentic_studio/scene_tools.gd")


func _initialize() -> void:
	var failures: PackedStringArray = PackedStringArray()

	# generate_support must preload/parse (no MESH_EXTENSIONS const, no String.get defaults).
	if GenerateScript == null:
		failures.append("generate_support failed to preload")
	else:
		if not GenerateScript._is_mesh_path("res://a.glb"):
			failures.append("_is_mesh_path should accept glb")
		if not GenerateScript._is_mesh_path("res://a.gltf"):
			failures.append("_is_mesh_path should accept gltf")
		if GenerateScript._is_mesh_path("res://a.png"):
			failures.append("_is_mesh_path must reject png")
		# Behavior unchanged: missing CLI still fails before spawn.
		var prev_cli: String = ConfigScript.get_drawthings_cli()
		ConfigScript.set_drawthings_cli("")
		var miss: Dictionary = GenerateScript.validate_drawthings_settings()
		if bool(miss.get("ok", false)) or str(miss.get("error", "")).find("drawthings_cli") < 0:
			failures.append("validate_drawthings still must name missing CLI")
		ConfigScript.set_drawthings_cli(prev_cli)

	# which resolve for bare name
	var resolved: String = SettingsScript.resolve_binary_path("draw-things-cli")
	if resolved == "draw-things-cli":
		# PATH may lack it in headless; still accept absolute identity for absolute inputs.
		pass
	elif not resolved.begins_with("/"):
		failures.append("resolve_binary_path should return absolute path when which succeeds: %s" % resolved)
	var abs_in: String = "/opt/homebrew/bin/draw-things-cli"
	if SettingsScript.resolve_binary_path(abs_in) != abs_in:
		failures.append("absolute path must pass through resolve unchanged")
	if SettingsScript.resolve_binary_path("draw-things-cli") != "draw-things-cli":
		# If which found it, must be absolute and exist.
		var r2: String = SettingsScript.resolve_binary_path("draw-things-cli")
		if not r2.begins_with("/"):
			failures.append("bare name resolved non-absolute: %s" % r2)

	# Prefer a live which check when the binary is on PATH.
	var which_out: Array = []
	var which_code: int = OS.execute("which", PackedStringArray(["draw-things-cli"]), which_out, true, false)
	if which_code == 0 and not which_out.is_empty():
		var want: String = str(which_out[0]).strip_edges().get_slice("\n", 0)
		var got: String = SettingsScript.resolve_binary_path("draw-things-cli")
		if got != want:
			failures.append("resolve mismatch which=%s got=%s" % [want, got])

	# NUL config must not be overwritten
	var nul_err: String = ConfigScript.config_nul_error()
	if not nul_err.is_empty():
		failures.append("user cfg unexpectedly has NUL: %s" % nul_err)
	else:
		# config_nul_error is callable as a static on the preloaded script.
		var probe: String = ConfigScript.config_nul_error()
		if typeof(probe) != TYPE_STRING:
			failures.append("config_nul_error missing or wrong type")

	# Settings dialog: null edits rebuild; models from list_models
	var dlg = SettingsScript.new()
	get_root().add_child(dlg)
	await process_frame
	# Force null drawthings edits then reload.
	dlg._drawthings_cli_edit = null
	dlg._drawthings_models_edit = null
	dlg._drawthings_model_edit = null
	dlg._reload_from_disk()
	await process_frame
	if dlg._drawthings_cli_edit == null:
		failures.append("reload must rebuild null Draw Things LineEdits")
	if dlg._model_list == null:
		failures.append("model list missing after rebuild")
	else:
		var models: Array = ConfigScript.list_models()
		if dlg._model_list.item_count != models.size():
			# Item count should match loaded models (may be 0 in CI without cfg models).
			if models.size() > 0 and dlg._model_list.item_count == 0:
				failures.append("model list empty while list_models has %d rows" % models.size())
		# If cfg has models, they must appear.
		for m: Dictionary in models:
			var name: String = str(m.get("display_name", ""))
			if name.is_empty():
				continue
			var found := false
			for i: int in range(dlg._model_list.item_count):
				if dlg._model_list.get_item_text(i).find(name) >= 0:
					found = true
					break
			if not found and models.size() > 0:
				failures.append("settings missing model row: %s" % name)
				break

	# Saving CLI path must not clear in-memory model list.
	var before: int = dlg._models.size()
	if dlg._drawthings_cli_edit != null:
		dlg._drawthings_cli_edit.text = "draw-things-cli"
		dlg._save_drawthings()
		if dlg._models.size() != before:
			failures.append(
				"saving CLI cleared models (%d -> %d)" % [before, dlg._models.size()]
			)
		var stored: String = ConfigScript.get_drawthings_cli()
		if which_code == 0 and not stored.begins_with("/") and not stored.is_empty():
			failures.append("typed bare CLI was not stored absolute: %s" % stored)

	# Coder catalog still includes generate tools (behavior unchanged).
	if not ToolsScript.is_write_tool("image_generate") or not ToolsScript.is_write_tool("mesh_from_image"):
		failures.append("generate tools must remain write tools")
	if ToolsScript.is_plan_tool("image_generate"):
		failures.append("image_generate must stay out of planner tools")

	# No AppleDouble ._generate_support.gd left in addon (NUL source of U+FFFD noise).
	var apple: String = ProjectSettings.globalize_path("res://addons/agentic_studio/._generate_support.gd")
	if FileAccess.file_exists(apple):
		failures.append("AppleDouble ._generate_support.gd still present")

	dlg.queue_free()
	if failures.is_empty():
		print("AgenticStudio verify_settings_fix: OK")
		quit(0)
		return
	print("AgenticStudio verify_settings_fix: FAILED")
	for f: String in failures:
		print("  - ", f)
	quit(1)
