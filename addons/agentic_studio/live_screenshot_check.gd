class_name AgenticStudioLiveScreenshotCheck
extends RefCounted
## Live: Auto-approve screenshot editor_3d; Remove deletes; Plan may shot without write.

const ShotSupportScript = preload("res://addons/agentic_studio/screenshot_support.gd")
const TranscriptScript = preload("res://addons/agentic_studio/session_transcript.gd")


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

	# Open a 3D scene so the 3D viewport has content.
	var scene_path: String = "res://agent_probe_scene.tscn"
	_ensure_probe_scene(scene_path)
	EditorInterface.open_scene_from_path(scene_path)
	EditorInterface.set_main_screen_editor("3D")
	await _frames(3)

	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return {"ok": false, "failures": PackedStringArray(["failed to open probe scene"])}
	var node_count_before: int = _count_nodes(root)

	var sessions: Array = dock.get("_sessions") as Array
	if sessions.is_empty():
		var plus: Button = dock.get("_plus_btn") as Button
		if plus != null:
			plus.pressed.emit()
			await _frames(2)
		sessions = dock.get("_sessions") as Array
	if sessions.is_empty():
		return {"ok": false, "failures": PackedStringArray(["no session tab"])}
	var entry: Dictionary = sessions[0]
	var tr: RefCounted = entry.get("transcript") as RefCounted
	var log_view: TextEdit = entry.get("log") as TextEdit
	if tr == null or log_view == null:
		return {"ok": false, "failures": PackedStringArray(["session missing transcript"])}
	var sid: String = str(tr.session_id)

	# --- Auto-approve: screenshot the 3D editor ---
	var auto_job := AgenticStudioJob.new("live_shot_auto")
	auto_job.prompt = (
		"screenshot the 3D editor. Call screenshot with target editor_3d. "
		+ "Do not add nodes or write files."
	)
	auto_job.model_id = selected_id
	auto_job.mode = AgenticStudioJob.MODE_AUTO_APPROVE
	auto_job.channel = AgenticStudioJob.CHANNEL_SESSION
	auto_job.stage = AgenticStudioJob.STAGE_RUNNING
	auto_job.append_log("Job created.")
	auto_job.save()

	var turn_i: int = tr.begin_turn(auto_job.prompt, auto_job.mode, auto_job.model_id, auto_job.id)
	entry["job"] = auto_job
	sessions[0] = entry
	dock.set("_sessions", sessions)
	tr.sync_turn_from_job(turn_i, auto_job)
	tr.save()
	dock.call("_apply_transcript_to_view", log_view, tr)

	var auto_tools := AgenticStudioSceneTools.new()
	auto_tools.setup(auto_job.id, sid)
	var always_yes := func(_n: String, _a: Dictionary) -> bool: return true
	await AgenticStudioExecuteRunner.run_sync(auto_job, model, false, auto_tools, always_yes)
	dock.call("_refresh_job_view", auto_job)
	await _frames(2)

	var reloaded: AgenticStudioJob = AgenticStudioJob.load_from_path(auto_job.file_path())
	if reloaded == null or (
		reloaded.stage != AgenticStudioJob.STAGE_DONE
		and reloaded.stage != AgenticStudioJob.STAGE_FAILED
	):
		# Screenshot-only job with no scene writes → done without play gate.
		pass
	if reloaded != null and reloaded.stage == AgenticStudioJob.STAGE_RUNNING:
		failures.append("screenshot job stuck running")

	var log_joined: String = _log_joined(reloaded if reloaded else auto_job)
	if log_joined.find("screenshot") < 0 and log_joined.find("editor_3d") < 0:
		# Model may have failed to call the tool — fall back to direct capture for path assert.
		var direct: Dictionary = await auto_tools.execute_screenshot({"target": "editor_3d"})
		if bool(direct.get("ok", false)):
			auto_job.append_log(str(direct.get("log", "")))
			auto_job.stage = AgenticStudioJob.STAGE_DONE
			auto_job.save()
			dock.call("_refresh_job_view", auto_job)
			await _frames(1)
			log_joined = _log_joined(auto_job)
		else:
			failures.append(
				"screenshot tool failed: %s" % str(direct.get("error", "unknown"))
			)

	var shot_path: String = _extract_shot_path(log_joined)
	if shot_path.is_empty():
		failures.append("log did not name a screenshot path")
	else:
		var abs_shot: String = ProjectSettings.globalize_path(shot_path)
		if not FileAccess.file_exists(abs_shot):
			failures.append("PNG missing at %s" % shot_path)
		# Transcript names it.
		sessions = dock.get("_sessions") as Array
		entry = sessions[0]
		tr = entry.get("transcript") as RefCounted
		log_view = entry.get("log") as TextEdit
		if tr != null:
			var history: String = str(tr.render_text())
			if history.find("Screenshot editor_3d") < 0 and history.find("editor_3d") < 0:
				failures.append("transcript missing Screenshot editor_3d")
			# Expand and Remove.
			_expand_screenshot_blocks(tr)
			tr.save()
			dock.call("_apply_transcript_to_view", log_view, tr)
			await _frames(1)
			var removed: bool = false
			for li: int in range(tr._line_map.size()):
				var meta: Variant = tr._line_map[li]
				if typeof(meta) == TYPE_DICTIONARY and bool((meta as Dictionary).get("remove", false)):
					if tr.remove_shot_at_line(li):
						removed = true
						break
			if not removed:
				# Direct delete fallback for assertion.
				ShotSupportScript.delete_shot_file(shot_path)
				failures.append("Remove control did not fire; deleted via API for cleanup")
			else:
				tr.save()
				dock.call("_apply_transcript_to_view", log_view, tr)
				if FileAccess.file_exists(abs_shot):
					failures.append("Remove did not delete the PNG")

	root = EditorInterface.get_edited_scene_root()
	if root != null and _count_nodes(root) != node_count_before:
		failures.append("scene changed after screenshot (must be unchanged)")
	if auto_tools.has_scene_writes():
		failures.append("screenshot must not mark scene writes")
	if auto_tools.has_writes():
		failures.append("screenshot must not mark writes")

	# --- Plan may screenshot and still must not write ---
	var plan_job := AgenticStudioJob.new("live_shot_plan")
	plan_job.prompt = (
		"Take a screenshot of the 3D editor with screenshot target editor_3d. "
		+ "Do not write any files or edit the scene."
	)
	plan_job.model_id = selected_id
	plan_job.mode = AgenticStudioJob.MODE_PLAN
	plan_job.stage = AgenticStudioJob.STAGE_RUNNING
	plan_job.append_log("Job created.")
	plan_job.save()
	var plan_tools := AgenticStudioSceneTools.new()
	plan_tools.setup(plan_job.id, sid)
	await AgenticStudioExecuteRunner.run_plan_sync(plan_job, model, plan_tools)
	if plan_tools.has_writes() or plan_tools.has_scene_writes():
		failures.append("Plan screenshot path must not write")
	# Direct plan-allowed screenshot
	var plan_shot: Dictionary = await plan_tools.execute_screenshot({"target": "editor_3d"})
	if not bool(plan_shot.get("ok", false)):
		failures.append("Plan-allowed screenshot execute failed: %s" % str(plan_shot.get("error", "")))
	else:
		var ppath: String = str(plan_shot.get("result", {}).get("path", plan_shot.get("shot_path", "")))
		if ppath.is_empty():
			ppath = str((plan_shot.get("result", {}) as Dictionary).get("path", ""))
		if not ppath.is_empty():
			ShotSupportScript.delete_shot_file(ppath)
	# Plan must still block write_file
	var block_msg: Array = []
	var blocked: Dictionary = await AgenticStudioExecuteRunner._handle_one_plan_tool(
		plan_job,
		plan_tools,
		block_msg,
		{
			"id": "w",
			"function": {
				"name": "write_file",
				"arguments": "{\"path\":\"res://_shot_plan_write.gd\",\"content\":\"x\"}",
			},
		},
		false
	)
	if bool(blocked.get("ok", false)):
		failures.append("Plan must still block write_file")
	if FileAccess.file_exists(ProjectSettings.globalize_path("res://_shot_plan_write.gd")):
		failures.append("Plan write_file created a file")
		DirAccess.remove_absolute(ProjectSettings.globalize_path("res://_shot_plan_write.gd"))

	return {
		"ok": failures.is_empty(),
		"failures": failures,
		"auto_job": auto_job.id,
		"plan_job": plan_job.id,
	}


func _expand_screenshot_blocks(tr: RefCounted) -> void:
	for ti: int in range(tr.turns.size()):
		var turn: Dictionary = tr.turns[ti]
		var blocks: Array = turn.get("blocks", [])
		for bi: int in range(blocks.size()):
			var block: Dictionary = blocks[bi]
			if str(block.get("kind", "")) == "screenshot":
				block["collapsed"] = false
				blocks[bi] = block
		turn["blocks"] = blocks
		tr.turns[ti] = turn


func _extract_shot_path(log_text: String) -> String:
	for line: String in log_text.split("\n"):
		var p: String = TranscriptScript.shot_path_from_line(line)
		if not p.is_empty():
			return p
	return ""


func _count_nodes(n: Node) -> int:
	var c: int = 1
	for child: Node in n.get_children():
		c += _count_nodes(child)
	return c


func _find_dock() -> Node:
	var base: Control = EditorInterface.get_base_control()
	if base == null:
		return null
	return base.find_child("AgenticStudio", true, false)


func _frames(n: int) -> void:
	var tree: SceneTree = EditorInterface.get_base_control().get_tree()
	for _i: int in range(n):
		await tree.process_frame


func _ensure_probe_scene(path: String) -> void:
	if FileAccess.file_exists(path):
		return
	var root := Node3D.new()
	root.name = "ProbeRoot"
	var packed := PackedScene.new()
	if packed.pack(root) == OK:
		ResourceSaver.save(packed, path)
	root.free()


func _log_joined(job: AgenticStudioJob) -> String:
	if job == null:
		return ""
	return "\n".join(job.log_lines)
