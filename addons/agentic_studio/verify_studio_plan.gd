extends SceneTree
## Headless proofs: Studio Draw Things fields, Plan blank-URL + unreachable host,
## picker filter, exclusive dialog flag, NUL-free addon. Does not wipe user:// cfg.
## Run: godot --headless --path . --script res://addons/agentic_studio/verify_studio_plan.gd

const ConfigScript = preload("res://addons/agentic_studio/config.gd")
const SettingsScript = preload("res://addons/agentic_studio/settings_dialog.gd")
const DockScript = preload("res://addons/agentic_studio/dock.gd")
const ModelClientScript = preload("res://addons/agentic_studio/model_client.gd")


func _initialize() -> void:
	var failures: PackedStringArray = PackedStringArray()
	# FAT/exFAT volumes recreate AppleDouble ._*; delete before parse proofs.
	OS.execute("find", PackedStringArray(["addons/agentic_studio", "-name", "._*", "-delete"]), [], true, false)
	ConfigScript.ensure_dirs()

	# Preserve user://agentic_studio.cfg tool + selection state across this script.
	var prev_cli: String = ConfigScript.get_drawthings_cli()
	var prev_models_dir: String = ConfigScript.get_drawthings_models_dir()
	var prev_model: String = ConfigScript.get_drawthings_model()
	var prev_planner: String = ConfigScript.get_selected_planner_id()
	var prev_coder: String = ConfigScript.get_selected_coder_id()
	var prev_models: Array[Dictionary] = ConfigScript.list_models()

	# --- NUL scan: addon scripts + open scene must be clean; cfg NULs → report and stop ---
	var nul_cfg: String = ConfigScript.config_nul_error()
	if not nul_cfg.is_empty():
		print("AgenticStudio verify_studio_plan: STOP — user cfg has NULs")
		print("  path: ", ProjectSettings.globalize_path(ConfigScript.CONFIG_PATH))
		print("  ", nul_cfg)
		quit(1)
		return
	var nul_hits: PackedStringArray = _scan_addon_nuls()
	for hit: String in nul_hits:
		failures.append(hit)
	var open_scene: String = "res://agent_probe_scene.tscn"
	if FileAccess.file_exists(open_scene):
		var scene_bytes: PackedByteArray = FileAccess.get_file_as_bytes(open_scene)
		if scene_bytes.find(0) >= 0:
			failures.append("open scene has NUL bytes: %s" % open_scene)

	# --- Draw Things is a tool: status names missing fields ---
	ConfigScript.set_drawthings_cli("")
	ConfigScript.set_drawthings_models_dir("")
	ConfigScript.set_drawthings_model("")
	var st_all: String = ConfigScript.drawthings_status_text()
	if st_all.find("CLI path") < 0 or st_all.find("models directory") < 0 or st_all.find("checkpoint filename") < 0:
		failures.append("status should name all three missing fields: %s" % st_all)

	ConfigScript.set_drawthings_cli("/opt/homebrew/bin/draw-things-cli")
	var st_two: String = ConfigScript.drawthings_status_text()
	if st_two.find("CLI path") >= 0:
		failures.append("status should not list set CLI: %s" % st_two)
	if st_two.find("models directory") < 0 or st_two.find("checkpoint filename") < 0:
		failures.append("status should still name remaining missing: %s" % st_two)

	# --- save_drawthings_fields resolves bare name and keeps planner/coder + models ---
	ConfigScript.set_selected_planner_id(prev_planner)
	ConfigScript.set_selected_coder_id(prev_coder)
	var keep_planner: String = ConfigScript.get_selected_planner_id()
	var keep_coder: String = ConfigScript.get_selected_coder_id()
	var before_count: int = ConfigScript.list_models().size()
	var saved: Dictionary = ConfigScript.save_drawthings_fields(
		"draw-things-cli",
		"/tmp/agentic_dt_models_probe",
		"probe.ckpt"
	)
	if not bool(saved.get("ok", false)):
		failures.append("save_drawthings_fields failed: %s" % str(saved.get("error", "")))
	else:
		var cli_abs: String = str(saved.get("cli", ""))
		var which_out: Array = []
		var which_code: int = OS.execute("which", PackedStringArray(["draw-things-cli"]), which_out, true, false)
		if which_code == 0 and not which_out.is_empty():
			var want: String = str(which_out[0]).strip_edges().get_slice("\n", 0)
			if cli_abs != want:
				failures.append("bare CLI resolve mismatch which=%s got=%s" % [want, cli_abs])
		elif cli_abs != "draw-things-cli" and not cli_abs.begins_with("/"):
			failures.append("unresolved bare name should stay bare or absolute: %s" % cli_abs)
		if ConfigScript.get_selected_planner_id() != keep_planner and not keep_planner.is_empty():
			failures.append("save_drawthings cleared planner selection")
		if ConfigScript.get_selected_coder_id() != keep_coder and not keep_coder.is_empty():
			failures.append("save_drawthings cleared coder selection")
		if ConfigScript.list_models().size() != before_count:
			failures.append(
				"save_drawthings changed model count %d -> %d"
				% [before_count, ConfigScript.list_models().size()]
			)
		if ConfigScript.get_drawthings_model() != "probe.ckpt":
			failures.append("checkpoint filename not stored")

	# --- Studio tab builds Draw Things panel (fields + status); not a model picker row ---
	var dock = DockScript.new()
	get_root().add_child(dock)
	await process_frame
	await process_frame
	if dock._studio_dt_cli == null or dock._studio_dt_models == null or dock._studio_dt_model == null:
		failures.append("Studio tab missing Draw Things LineEdits")
	if dock._studio_dt_status == null:
		failures.append("Studio tab missing Draw Things status line")
	else:
		var panel_status: String = str(dock._studio_dt_status.text)
		# After save above, all three are set → ready (or still shows missing if restore raced).
		if panel_status.is_empty():
			failures.append("Studio Draw Things status should be visible text")
	# Inject a fake Draw Things "model" into picker fill path via filter helper.
	if not dock._looks_like_drawthings_tool("tool_drawthings", "DrawThings"):
		failures.append("dock filter must catch DrawThings tool id/name")
	if dock._looks_like_drawthings_tool("provider_grok", "Grok"):
		failures.append("dock filter must not catch Grok")
	# Plan/Code pickers must not list Draw Things even if a bad model row exists.
	var fake_id: String = "verify_drawthings_fake_model"
	ConfigScript.upsert_model({
		"id": fake_id,
		"display_name": "Draw Things CLI",
		"kind": ConfigScript.KIND_LOCAL,
		"role": ConfigScript.ROLE_PLANNER,
		"base_url": "http://127.0.0.1:9/v1",
		"model_name": "draw-things",
		"context_length": 1024,
	})
	dock._refresh_all_model_pickers()
	await process_frame
	for i: int in range(dock._studio_planner.item_count):
		var label: String = dock._studio_planner.get_item_text(i).to_lower()
		if label.find("draw things") >= 0 or label.find("draw-things") >= 0:
			failures.append("Plan picker listed Draw Things: %s" % dock._studio_planner.get_item_text(i))
			break
	for j: int in range(dock._studio_coder.item_count):
		var label2: String = dock._studio_coder.get_item_text(j).to_lower()
		if label2.find("draw things") >= 0 or label2.find("draw-things") >= 0:
			failures.append("Code picker listed Draw Things: %s" % dock._studio_coder.get_item_text(j))
			break
	ConfigScript.remove_model(fake_id)

	# --- Plan blank Build URL: named log, no socket ---
	var blank_planner_id: String = ConfigScript.add_grok_build_planner("VerifyBlankBuild")
	ConfigScript.set_selected_planner_id(blank_planner_id)
	var blank_model: Dictionary = ConfigScript.get_model(blank_planner_id)
	var checked: Dictionary = ConfigScript.validate_role_endpoint(
		blank_model, ConfigScript.ROLE_PLANNER
	)
	if bool(checked.get("ok", true)):
		failures.append("blank Build URL should fail validate")
	else:
		var err: String = str(checked.get("error", ""))
		if err.find("Build URL missing for VerifyBlankBuild") < 0:
			failures.append("blank URL error must include display name: %s" % err)
	# Drive dock send-failure path (no HTTP).
	dock._append_send_failure_log(
		"studio",
		-1,
		"probe blank url",
		"plan",
		blank_planner_id,
		str(checked.get("error", "Build URL missing"))
	)
	await process_frame
	var studio_log_text: String = ""
	if dock._studio_log != null:
		studio_log_text = str(dock._studio_log.text)
	if studio_log_text.find("Build URL missing") < 0:
		failures.append("Studio log missing blank-URL error after Plan send failure")
	if studio_log_text.find("Authorization:") >= 0 or studio_log_text.find("sk-") >= 0:
		failures.append("Studio log must not include API key material")

	# --- Unreachable host: planner connection failed: host:port · mode=plan ---
	var bad_id: String = ConfigScript.upsert_model({
		"id": "verify_unreachable_planner",
		"display_name": "UnreachablePlanner",
		"kind": ConfigScript.KIND_LOCAL,
		"role": ConfigScript.ROLE_PLANNER,
		# Closed port on loopback — CANT_CONNECT without a long hang.
		"base_url": "http://127.0.0.1:9",
		"model_name": "none",
		"context_length": 1024,
	})
	var bad_model: Dictionary = ConfigScript.get_model(bad_id)
	# Short timeout so the proof finishes quickly even if connect stalls.
	dock._http.timeout = 3.0
	var response: Dictionary = await dock._http_chat(
		bad_model,
		[{"role": "user", "content": "ping"}],
		false,
		true,
		"plan"
	)
	if bool(response.get("ok", true)):
		failures.append("unreachable planner should fail")
	else:
		var cerr: String = str(response.get("error", ""))
		if cerr.find("planner connection failed:") < 0:
			failures.append("connection error must be named: %s" % cerr)
		if cerr.find("127.0.0.1:9") < 0:
			failures.append("connection error must include host:port: %s" % cerr)
		if cerr.find("mode=plan") < 0:
			failures.append("connection error must include mode: %s" % cerr)
		if cerr.find("Authorization") >= 0 or cerr.to_lower().find("api_key") >= 0:
			failures.append("connection error must not include API key: %s" % cerr)
	ConfigScript.remove_model(bad_id)
	ConfigScript.remove_model(blank_planner_id)

	# --- Exclusive dialog: Browse owns slot; settings refuses while open ---
	var dlg = SettingsScript.new()
	get_root().add_child(dlg)
	await process_frame
	dlg._file_dialog_open = true
	dlg.exclusive = false
	dlg.open_settings()
	if dlg.visible:
		failures.append("open_settings must refuse while file dialog owns exclusive")
		dlg.hide()
	dlg._file_dialog_open = false
	dlg.exclusive = true
	# Simulate browse ownership handoff without EditorFileDialog (headless-safe).
	dlg._saved_exclusive = dlg.exclusive
	dlg.exclusive = false
	dlg._file_dialog_open = true
	if dlg.exclusive:
		failures.append("browse must drop settings exclusive")
	if not dlg.is_file_dialog_open():
		failures.append("is_file_dialog_open should be true during browse")
	dlg._on_browse_finished()
	if dlg._file_dialog_open:
		failures.append("browse finish must clear file-dialog flag")
	if not dlg.exclusive:
		failures.append("browse finish must restore settings exclusive")
	# Dock Settings button also refuses while browse open.
	dlg._file_dialog_open = true
	dock._on_settings_pressed()
	if dlg.visible:
		failures.append("dock Settings must not popup while browse exclusive")
		dlg.hide()
	dlg._file_dialog_open = false

	# Settings role pickers also filter Draw Things.
	var probe_models: Array[Dictionary] = []
	probe_models.append({
		"id": "dt_fake",
		"display_name": "Draw-Things",
		"role": ConfigScript.ROLE_PLANNER,
	})
	probe_models.append({
		"id": "ok_planner",
		"display_name": "Real Planner",
		"role": ConfigScript.ROLE_PLANNER,
	})
	dlg._models = probe_models
	dlg._refresh_role_pickers()
	for k: int in range(dlg._planner_picker.item_count):
		var t: String = dlg._planner_picker.get_item_text(k).to_lower()
		if t.find("draw-things") >= 0 or t.find("draw things") >= 0:
			failures.append("settings planner picker listed Draw Things")
			break

	# file_support must not embed a literal NUL escape in a string (causes editor U+FFFD noise).
	var fs_src: String = FileAccess.get_file_as_string("res://addons/agentic_studio/file_support.gd")
	var fs_code: String = ""
	for fs_line: String in fs_src.split("\n"):
		var trimmed: String = fs_line.strip_edges()
		if trimmed.begins_with("#") or trimmed.begins_with("##"):
			continue
		fs_code += fs_line + "\n"
	if fs_code.find("\"\\u0000\"") >= 0 or fs_code.find("\"\\x00\"") >= 0:
		failures.append("file_support.gd must not embed a NUL string literal")

	dlg.queue_free()
	dock.queue_free()

	# Restore user Draw Things + selections last (do not wipe cfg / models).
	ConfigScript.save_drawthings_fields(prev_cli, prev_models_dir, prev_model)
	if not prev_planner.is_empty():
		ConfigScript.set_selected_planner_id(prev_planner)
	if not prev_coder.is_empty():
		ConfigScript.set_selected_coder_id(prev_coder)
	var after_models: Array[Dictionary] = ConfigScript.list_models()
	if after_models.size() < prev_models.size():
		failures.append(
			"verify reduced model count %d -> %d" % [prev_models.size(), after_models.size()]
		)
	if ConfigScript.get_selected_planner_id() != prev_planner and not prev_planner.is_empty():
		failures.append("planner selection not restored")
	if ConfigScript.get_selected_coder_id() != prev_coder and not prev_coder.is_empty():
		failures.append("coder selection not restored")

	if failures.is_empty():
		print("AgenticStudio verify_studio_plan: OK")
		quit(0)
		return
	print("AgenticStudio verify_studio_plan: FAILED")
	for f: String in failures:
		print("  - ", f)
	quit(1)


func _scan_addon_nuls() -> PackedStringArray:
	var hits: PackedStringArray = PackedStringArray()
	var dir := DirAccess.open("res://addons/agentic_studio")
	if dir == null:
		hits.append("cannot open addons/agentic_studio")
		return hits
	_scan_dir_nuls(dir, "res://addons/agentic_studio", hits)
	return hits


func _scan_dir_nuls(dir: DirAccess, prefix: String, hits: PackedStringArray) -> void:
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while not name.is_empty():
		if name == "." or name == "..":
			name = dir.get_next()
			continue
		# AppleDouble sidecars are gitignored; flag if present (NUL source of U+FFFD).
		if name.begins_with("._"):
			hits.append("AppleDouble present: %s/%s" % [prefix, name])
			name = dir.get_next()
			continue
		var path: String = "%s/%s" % [prefix, name]
		if dir.current_is_dir():
			var sub := DirAccess.open(path)
			if sub != null:
				_scan_dir_nuls(sub, path, hits)
		elif (
			name.ends_with(".gd")
			or name.ends_with(".tscn")
			or name.ends_with(".cfg")
			or name.ends_with(".md")
		):
			var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
			if bytes.find(0) >= 0:
				hits.append("NUL bytes in %s" % path)
			var text: String = bytes.get_string_from_utf8()
			if text.find("\ufffd") >= 0:
				hits.append("U+FFFD in %s" % path)
		name = dir.get_next()
	dir.list_dir_end()
