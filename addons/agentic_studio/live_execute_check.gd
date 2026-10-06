class_name AgenticStudioLiveExecuteCheck
extends RefCounted
## Editor-only live check for Auto-approve / Run. Requires EditorInterface.


func run() -> Dictionary:
	var failures: PackedStringArray = PackedStringArray()
	AgenticStudioConfig.ensure_dirs()

	var selected_id: String = AgenticStudioConfig.get_selected_model_id()
	var model: Dictionary = AgenticStudioConfig.get_model(selected_id)
	if model.is_empty():
		return {"ok": false, "failures": PackedStringArray(["no selected model in config"])}

	var base_url: String = str(model.get("base_url", "")).strip_edges()
	var model_name: String = str(model.get("model_name", "")).strip_edges()
	if base_url != "http://192.168.68.55:11434/v1":
		failures.append("expected test base_url http://192.168.68.55:11434/v1, got %s" % base_url)
	if model_name != "qwen2.5-coder:7b":
		failures.append("expected test model_name qwen2.5-coder:7b, got %s" % model_name)
	if not failures.is_empty():
		return {"ok": false, "failures": failures}

	var scene_path: String = "res://agent_probe_scene.tscn"
	_ensure_probe_scene(scene_path)
	EditorInterface.open_scene_from_path(scene_path)
	# Allow the editor to settle on the open scene.
	await _editor_tree().process_frame
	await _editor_tree().process_frame

	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return {"ok": false, "failures": PackedStringArray(["failed to open probe scene"])}

	_remove_child_named(root, "AgentProbe")
	_remove_child_named(root, "BrokenProbe")

	# --- Auto-approve ---
	var auto_job := AgenticStudioJob.new("live_auto_approve")
	auto_job.prompt = (
		"add a Node3D named AgentProbe under the current scene root. "
		+ "Call add_node with page_id goblin_shaman."
	)
	auto_job.model_id = selected_id
	auto_job.mode = AgenticStudioJob.MODE_AUTO_APPROVE
	auto_job.stage = AgenticStudioJob.STAGE_RUNNING
	auto_job.append_log("Job created.")
	auto_job.save()

	var auto_tools := AgenticStudioSceneTools.new()
	auto_tools.setup(auto_job.id)
	var always_yes := func(_n: String, _a: Dictionary) -> bool: return true
	await AgenticStudioExecuteRunner.run_sync(auto_job, model, false, auto_tools, always_yes)

	var reloaded_auto: AgenticStudioJob = AgenticStudioJob.load_from_path(auto_job.file_path())
	if reloaded_auto == null or reloaded_auto.stage != AgenticStudioJob.STAGE_DONE:
		failures.append(
			"auto-approve job stage=%s want=done"
			% (reloaded_auto.stage if reloaded_auto else "missing")
		)
	if not _assert_log_selectable(reloaded_auto):
		failures.append("reloaded job log is not selectable in a read-only TextEdit")
	if reloaded_auto != null and not _log_has_play_line(reloaded_auto):
		failures.append("auto-approve log missing play_scene line")

	root = EditorInterface.get_edited_scene_root()
	if root == null or root.get_node_or_null(NodePath("AgentProbe")) == null:
		failures.append("AgentProbe missing after auto-approve")
	else:
		# One undo removes the job's writes.
		if not _undo_once(root):
			failures.append("undo API failed")
		await _editor_tree().process_frame
		root = EditorInterface.get_edited_scene_root()
		if root != null and root.get_node_or_null(NodePath("AgentProbe")) != null:
			failures.append("AgentProbe still present after one undo")

	# --- Parse-error script job: write + mandatory play must fail, game stopped ---
	_remove_child_named(EditorInterface.get_edited_scene_root(), "AgentProbe")
	_remove_child_named(EditorInterface.get_edited_scene_root(), "BrokenProbe")
	var broken_path: String = "res://agent_probe_broken.gd"
	_write_broken_script(broken_path)
	# Refresh so the resource is visible to load().
	EditorInterface.get_resource_filesystem().scan()
	await _editor_tree().process_frame
	await _editor_tree().process_frame

	var broken_job := AgenticStudioJob.new("live_play_parse_error")
	broken_job.prompt = "attach a deliberately broken script (live check, no model)"
	broken_job.model_id = selected_id
	broken_job.mode = AgenticStudioJob.MODE_AUTO_APPROVE
	broken_job.stage = AgenticStudioJob.STAGE_RUNNING
	broken_job.append_log("Job created.")
	broken_job.save()

	var broken_tools := AgenticStudioSceneTools.new()
	broken_tools.setup(broken_job.id)
	var add_out: Dictionary = broken_tools.execute(
		AgenticStudioSceneTools.TOOL_ADD_NODE,
		{"type": "Node3D", "name": "BrokenProbe", "page_id": "goblin_shaman"}
	)
	broken_job.append_log(str(add_out.get("log", "")))
	var broken_script: Script = load(broken_path) as Script
	if broken_script == null:
		# load() can return null for parse-broken scripts; attach via GDScript source.
		var gd := GDScript.new()
		gd.source_code = _broken_script_source()
		broken_script = gd
	var set_out: Dictionary = broken_tools.execute(
		AgenticStudioSceneTools.TOOL_SET_PROPERTY,
		{
			"path": "BrokenProbe",
			"property": "script",
			"value": broken_script,
			"page_id": "goblin_shaman",
		}
	)
	broken_job.append_log(str(set_out.get("log", "")))
	broken_job.save()
	await AgenticStudioExecuteRunner.finish_job(broken_job, broken_tools)

	var reloaded_broken: AgenticStudioJob = AgenticStudioJob.load_from_path(broken_job.file_path())
	if reloaded_broken == null or reloaded_broken.stage != AgenticStudioJob.STAGE_FAILED:
		failures.append(
			"parse-error job stage=%s want=failed"
			% (reloaded_broken.stage if reloaded_broken else "missing")
		)
	if reloaded_broken != null and not _log_has_play_failure(reloaded_broken):
		failures.append("parse-error job log missing play_scene failure / error lines")
	if not _assert_log_selectable(reloaded_broken):
		failures.append("parse-error job log is not selectable in a read-only TextEdit")
	if EditorInterface.is_playing_scene():
		failures.append("game still playing after parse-error play check")
		EditorInterface.stop_playing_scene()

	# Leave undo in place: one undo should remove BrokenProbe when it is still present.
	root = EditorInterface.get_edited_scene_root()
	if root != null and root.get_node_or_null(NodePath("BrokenProbe")) != null:
		if not _undo_once(root):
			failures.append("undo after parse-error job failed")
		await _editor_tree().process_frame
		await _editor_tree().process_frame
		root = EditorInterface.get_edited_scene_root()
		if root != null and root.get_node_or_null(NodePath("BrokenProbe")) != null:
			failures.append("BrokenProbe still present after one undo")

	# --- Run with No on writes ---
	_remove_child_named(EditorInterface.get_edited_scene_root(), "AgentProbe")
	_remove_child_named(EditorInterface.get_edited_scene_root(), "BrokenProbe")
	var run_job := AgenticStudioJob.new("live_run_no")
	run_job.prompt = (
		"add a Node3D named AgentProbe under the current scene root with page_id goblin_shaman"
	)
	run_job.model_id = selected_id
	run_job.mode = AgenticStudioJob.MODE_RUN
	run_job.stage = AgenticStudioJob.STAGE_RUNNING
	run_job.append_log("Job created.")
	run_job.save()
	var run_tools := AgenticStudioSceneTools.new()
	run_tools.setup(run_job.id)
	var always_no := func(_n: String, _a: Dictionary) -> bool: return false
	await AgenticStudioExecuteRunner.run_sync(run_job, model, true, run_tools, always_no)
	root = EditorInterface.get_edited_scene_root()
	if root != null and root.get_node_or_null(NodePath("AgentProbe")) != null:
		failures.append("Run with No must leave the scene unchanged")
	if _log_has_play_line(run_job):
		failures.append("Run with No (no writes) must not call play_scene")

	# --- Plan must not edit or play ---
	_remove_child_named(EditorInterface.get_edited_scene_root(), "AgentProbe")
	var before_count: int = _child_count(EditorInterface.get_edited_scene_root())
	var plan_job := AgenticStudioJob.new("live_plan_no_edit")
	plan_job.prompt = "add a Node3D named AgentProbe under the current scene root"
	plan_job.model_id = selected_id
	plan_job.mode = AgenticStudioJob.MODE_PLAN
	plan_job.stage = AgenticStudioJob.STAGE_RUNNING
	plan_job.append_log("Job created.")
	plan_job.save()
	var plan_result: Dictionary = AgenticStudioModelClient.request_plan_via_client(
		model,
		plan_job.prompt,
		120.0
	)
	if bool(plan_result.get("ok", false)):
		plan_job.append_log(str(plan_result.get("text", "")))
		plan_job.stage = AgenticStudioJob.STAGE_PLANNED
	else:
		plan_job.append_log(str(plan_result.get("error", "plan failed")))
		plan_job.stage = AgenticStudioJob.STAGE_FAILED
	plan_job.save()
	var after_count: int = _child_count(EditorInterface.get_edited_scene_root())
	if after_count != before_count:
		failures.append("Plan edited the scene")
	if EditorInterface.get_edited_scene_root() != null \
			and EditorInterface.get_edited_scene_root().get_node_or_null(NodePath("AgentProbe")) != null:
		failures.append("Plan created AgentProbe")
	if _log_has_play_line(plan_job):
		failures.append("Plan must not call play_scene")
	if EditorInterface.is_playing_scene():
		failures.append("Plan left the game playing")
		EditorInterface.stop_playing_scene()

	return {
		"ok": failures.is_empty(),
		"failures": failures,
		"auto_job": auto_job.id,
		"broken_job": broken_job.id,
		"run_job": run_job.id,
		"plan_job": plan_job.id,
	}


func _editor_tree() -> SceneTree:
	return EditorInterface.get_base_control().get_tree()


func _ensure_probe_scene(path: String) -> void:
	if FileAccess.file_exists(path):
		return
	var root := Node3D.new()
	root.name = "ProbeRoot"
	var packed := PackedScene.new()
	var pack_err: Error = packed.pack(root)
	if pack_err != OK:
		push_warning("AgenticStudio: could not pack probe scene: %d" % pack_err)
		root.free()
		return
	var save_err: Error = ResourceSaver.save(packed, path)
	root.free()
	if save_err != OK:
		push_warning("AgenticStudio: could not save probe scene: %d" % save_err)


func _remove_child_named(root: Node, child_name: String) -> void:
	if root == null:
		return
	var node: Node = root.get_node_or_null(NodePath(child_name))
	if node != null:
		root.remove_child(node)
		node.free()


func _child_count(root: Node) -> int:
	if root == null:
		return 0
	return root.get_child_count()


func _undo_once(root: Node) -> bool:
	var mgr: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	if mgr == null or root == null:
		return false
	var history_id: int = mgr.get_object_history_id(root)
	var ur: UndoRedo = mgr.get_history_undo_redo(history_id)
	if ur == null:
		return false
	if not ur.has_undo():
		return false
	ur.undo()
	return true


func _assert_log_selectable(job: AgenticStudioJob) -> bool:
	## Mirrors the dock transcript: read-only TextEdit filled from the job log.
	if job == null:
		return false
	var log_view := TextEdit.new()
	log_view.editable = false
	log_view.context_menu_enabled = true
	log_view.scroll_fit_content_height = false
	var header: String = "mode=%s  model=%s  stage=%s\n" % [
		AgenticStudioJob.mode_label(job.mode),
		job.model_id,
		job.stage,
	]
	header += "prompt: %s\n\n" % job.prompt
	log_view.text = header + ("\n".join(job.log_lines) if not job.log_lines.is_empty() else "")
	if log_view.editable:
		log_view.free()
		return false
	if log_view.text.is_empty():
		log_view.free()
		return false
	log_view.select(0, 0, 0, mini(4, log_view.text.length()))
	var selected: String = log_view.get_selected_text()
	log_view.free()
	return not selected.is_empty()


func _log_joined(job: AgenticStudioJob) -> String:
	if job == null:
		return ""
	return "\n".join(job.log_lines)


func _log_has_play_line(job: AgenticStudioJob) -> bool:
	return _log_joined(job).find("play_scene") >= 0


func _log_has_play_failure(job: AgenticStudioJob) -> bool:
	var text: String = _log_joined(job)
	if text.find("play_scene failed") >= 0:
		return true
	# Accept any play_scene line that also carries an error/parse signal.
	if text.find("play_scene") >= 0 and (
		text.findn("error") >= 0
		or text.findn("Parse Error") >= 0
		or text.findn("SCRIPT ERROR") >= 0
	):
		return true
	return false


func _broken_script_source() -> String:
	## Deliberate parse error: missing colon after func signature.
	return "extends Node3D\nfunc _ready() -> void\n\tpass\n"


func _write_broken_script(path: String) -> void:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("AgenticStudio: could not write broken script %s" % path)
		return
	f.store_string(_broken_script_source())
	f.close()
