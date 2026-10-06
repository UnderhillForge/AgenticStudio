class_name AgenticStudioLiveFileCheck
extends RefCounted
## Live: Auto-approve script on one session tab; turn in transcript; delete No; Plan no-write.


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

	var dock: Node = _find_dock()
	if dock == null:
		return {"ok": false, "failures": PackedStringArray(["AgenticStudio dock not found"])}

	var scene_path: String = "res://agent_probe_scene.tscn"
	_ensure_probe_scene(scene_path)
	EditorInterface.open_scene_from_path(scene_path)
	await _frames(2)

	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return {"ok": false, "failures": PackedStringArray(["failed to open probe scene"])}

	_remove_child_named(root, "AgentProbe")
	var script_path: String = "res://agent_probe_ready.gd"
	var previous_source: String = "extends Node3D\n# previous live_file_check\n"
	_write_text(script_path, previous_source)
	EditorInterface.get_resource_filesystem().scan()
	await _frames(2)

	# Ensure AgentProbe exists so the model only needs write_file + set_property.
	var prep := AgenticStudioSceneTools.new()
	prep.setup("live_file_prep")
	var add_out: Dictionary = prep.execute(
		AgenticStudioSceneTools.TOOL_ADD_NODE,
		{"type": "Node3D", "name": "AgentProbe", "page_id": "goblin_shaman"}
	)
	if not bool(add_out.get("ok", false)):
		failures.append("prep add_node failed: %s" % str(add_out.get("error", "")))
		prep.finish()
		return {"ok": false, "failures": failures}
	prep.finish()

	# One session tab for the file turn (append; do not open a new tab for Send).
	var sessions: Array = dock.get("_sessions") as Array
	if sessions.is_empty():
		var plus: Button = dock.get("_plus_btn") as Button
		if plus != null:
			plus.pressed.emit()
			await _frames(2)
		sessions = dock.get("_sessions") as Array
	if sessions.is_empty():
		return {"ok": false, "failures": PackedStringArray(["no session tab for file turn"])}
	var session_i: int = 0
	var entry: Dictionary = sessions[session_i]
	var tr: RefCounted = entry.get("transcript") as RefCounted
	var log_view: TextEdit = entry.get("log") as TextEdit
	if tr == null or log_view == null:
		return {"ok": false, "failures": PackedStringArray(["session missing transcript or log"])}
	var turns_before: int = tr.turns.size()

	# --- Auto-approve on this session tab ---
	var auto_job := AgenticStudioJob.new("live_file_script")
	auto_job.prompt = (
		"add a script on AgentProbe that sets position.x to 1 in _ready. "
		+ "Use write_file to create res://agent_probe_ready.gd with extends Node3D and "
		+ "func _ready that sets position.x = 1.0 (include page_id goblin_shaman), "
		+ "then set_property on AgentProbe property script to res://agent_probe_ready.gd "
		+ "with page_id goblin_shaman."
	)
	auto_job.model_id = selected_id
	auto_job.mode = AgenticStudioJob.MODE_AUTO_APPROVE
	auto_job.channel = AgenticStudioJob.CHANNEL_SESSION
	auto_job.stage = AgenticStudioJob.STAGE_RUNNING
	auto_job.append_log("Job created.")
	auto_job.save()

	# Mirror dock send: append a turn on this tab.
	var turn_i: int = tr.begin_turn(
		auto_job.prompt,
		auto_job.mode,
		auto_job.model_id,
		auto_job.id
	)
	entry["job"] = auto_job
	entry["transcript"] = tr
	sessions[session_i] = entry
	dock.set("_sessions", sessions)
	tr.sync_turn_from_job(turn_i, auto_job)
	tr.save()
	dock.call("_apply_transcript_to_view", log_view, tr)
	dock.call("_persist_open_session_ids")

	var auto_tools := AgenticStudioSceneTools.new()
	auto_tools.setup(auto_job.id)
	var always_yes := func(_n: String, _a: Dictionary) -> bool: return true
	await AgenticStudioExecuteRunner.run_sync(auto_job, model, false, auto_tools, always_yes)

	# Same path as dock _refresh_job_view: sync turn into scrolling history.
	dock.call("_refresh_job_view", auto_job)
	await _frames(2)

	var reloaded_auto: AgenticStudioJob = AgenticStudioJob.load_from_path(auto_job.file_path())
	if reloaded_auto == null or reloaded_auto.stage != AgenticStudioJob.STAGE_DONE:
		failures.append(
			"auto-approve file job stage=%s want=done"
			% (reloaded_auto.stage if reloaded_auto else "missing")
		)
	if reloaded_auto != null and _log_joined(reloaded_auto).find("play_scene") < 0:
		failures.append("auto-approve file job log missing play_scene line")

	var abs_script: String = ProjectSettings.globalize_path(script_path)
	if not FileAccess.file_exists(abs_script):
		failures.append("script file missing after auto-approve: %s" % script_path)
	else:
		var after: String = FileAccess.get_file_as_string(script_path)
		if after.find("position.x") < 0 and after.find("position . x") < 0:
			if after.find("position") < 0 or after.find("1") < 0:
				failures.append("script does not set position.x to 1: %s" % after.left(200))
		if after.find("_ready") < 0:
			failures.append("script missing _ready")

	root = EditorInterface.get_edited_scene_root()
	var probe: Node = root.get_node_or_null(NodePath("AgentProbe")) if root else null
	if probe == null:
		failures.append("AgentProbe missing after script job")
	elif probe.get_script() == null:
		failures.append("AgentProbe has no script attached")

	# Turn is in the scrolling history on this session tab; tool lines stay collapsible.
	sessions = dock.get("_sessions") as Array
	entry = sessions[session_i] if session_i < sessions.size() else {}
	tr = entry.get("transcript") as RefCounted
	log_view = entry.get("log") as TextEdit
	if tr == null or log_view == null:
		failures.append("session transcript missing after file job")
	else:
		if tr.turns.size() < turns_before + 1:
			failures.append(
				"file turn did not append to session transcript (before=%d after=%d)"
				% [turns_before, tr.turns.size()]
			)
		var history: String = str(log_view.text)
		if history.find("add a script on AgentProbe") < 0:
			failures.append("session log missing the file-turn prompt")
		if history.find("Running write_file") < 0 and history.find("write_file") < 0:
			failures.append("session log missing write_file tool line")
		if history.find("▶") < 0 and history.find("▼") < 0:
			failures.append("session log missing collapsible tool chevrons")

	# One undo restores the previous file contents (and scene writes).
	if not _undo_once(root):
		failures.append("undo API failed after script job")
	await _frames(2)
	if FileAccess.file_exists(abs_script):
		var restored: String = FileAccess.get_file_as_string(script_path)
		if restored.find("previous live_file_check") < 0:
			failures.append(
				"undo did not restore previous file (got: %s)" % restored.left(120)
			)
	else:
		failures.append("undo removed script file entirely; expected previous content restored")

	# --- delete_file always asks; No leaves the file ---
	var del_path: String = "res://_live_file_delete_probe.gd"
	_write_text(del_path, "extends Node\n# delete probe\n")
	var abs_del: String = ProjectSettings.globalize_path(del_path)
	var del_job := AgenticStudioJob.new("live_file_delete_no")
	del_job.prompt = "delete probe (live check)"
	del_job.model_id = selected_id
	del_job.mode = AgenticStudioJob.MODE_AUTO_APPROVE
	del_job.stage = AgenticStudioJob.STAGE_RUNNING
	del_job.append_log("Job created.")
	del_job.save()
	var del_tools := AgenticStudioSceneTools.new()
	del_tools.setup(del_job.id)
	var always_no := func(_n: String, _a: Dictionary) -> bool: return false
	var messages: Array = []
	var call: Dictionary = {
		"id": "call_del",
		"function": {
			"name": "delete_file",
			"arguments": JSON.stringify({"path": del_path}),
		},
	}
	var del_payload: Dictionary = await AgenticStudioExecuteRunner._handle_one_tool(
		del_job,
		del_tools,
		messages,
		call,
		false,
		always_no,
		false
	)
	if bool(del_payload.get("ok", false)):
		failures.append("delete_file with No must not succeed")
	if not FileAccess.file_exists(abs_del):
		failures.append("delete_file No must leave the file")
	if _log_joined(del_job).find("skipped") < 0 and _log_joined(del_job).find("delete_file") < 0:
		failures.append("delete_file No should be logged as skipped")
	del_tools.discard_if_empty()
	if FileAccess.file_exists(abs_del):
		DirAccess.remove_absolute(abs_del)

	# Refuse deleting session logs.
	var del_log: Dictionary = AgenticStudioFileSupport.delete_text_file(
		"user://agentic_studio/logs/studio.log"
	)
	if bool(del_log.get("ok", false)):
		failures.append("delete_file must refuse user://agentic_studio/logs/")

	# --- Plan still does not write ---
	var plan_job := AgenticStudioJob.new("live_file_plan")
	plan_job.prompt = (
		"Write a new script at res://_plan_must_not_write.gd using write_file. "
		+ "If you cannot write, say you are planning only."
	)
	plan_job.model_id = selected_id
	plan_job.mode = AgenticStudioJob.MODE_PLAN
	plan_job.stage = AgenticStudioJob.STAGE_RUNNING
	plan_job.append_log("Job created.")
	plan_job.save()
	var plan_tools := AgenticStudioSceneTools.new()
	plan_tools.setup(plan_job.id)
	await AgenticStudioExecuteRunner.run_plan_sync(plan_job, model, plan_tools)
	var plan_abs: String = ProjectSettings.globalize_path("res://_plan_must_not_write.gd")
	if FileAccess.file_exists(plan_abs):
		failures.append("Plan must not create files")
		DirAccess.remove_absolute(plan_abs)
	var reloaded_plan: AgenticStudioJob = AgenticStudioJob.load_from_path(plan_job.file_path())
	if reloaded_plan != null and reloaded_plan.stage == AgenticStudioJob.STAGE_FAILED:
		pass
	elif reloaded_plan != null and reloaded_plan.stage != AgenticStudioJob.STAGE_PLANNED:
		if reloaded_plan.stage == AgenticStudioJob.STAGE_RUNNING:
			failures.append("Plan job stuck in running")

	var block_msg: Array = []
	var block_payload: Dictionary = await AgenticStudioExecuteRunner._handle_one_plan_tool(
		plan_job,
		plan_tools,
		block_msg,
		{
			"id": "call_w",
			"function": {
				"name": "write_file",
				"arguments": "{\"path\":\"res://_plan_block.gd\",\"content\":\"x\"}",
			},
		},
		false
	)
	if bool(block_payload.get("ok", false)):
		failures.append("Plan handler must block write_file")
	if FileAccess.file_exists(ProjectSettings.globalize_path("res://_plan_block.gd")):
		failures.append("Plan blocked write_file still created a file")
		DirAccess.remove_absolute(ProjectSettings.globalize_path("res://_plan_block.gd"))

	return {
		"ok": failures.is_empty(),
		"failures": failures,
		"auto_job": auto_job.id if auto_job else "",
		"del_job": del_job.id if del_job else "",
		"plan_job": plan_job.id if plan_job else "",
	}


func _find_dock() -> Node:
	var base: Control = EditorInterface.get_base_control()
	if base == null:
		return null
	return base.find_child("AgenticStudio", true, false)


func _frames(n: int) -> void:
	var tree: SceneTree = _editor_tree()
	for _i: int in range(n):
		await tree.process_frame


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


func _write_text(path: String, content: String) -> void:
	var parent: String = path.get_base_dir()
	if not parent.is_empty() and parent != "res://":
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(parent))
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("AgenticStudio: could not write %s" % path)
		return
	f.store_string(content)
	f.close()


func _log_joined(job: AgenticStudioJob) -> String:
	if job == null:
		return ""
	return "\n".join(job.log_lines)
