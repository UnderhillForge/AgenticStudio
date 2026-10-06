extends SceneTree
## Live Plan against the saved selected model. Does not edit agentic_studio.cfg.
## Run: godot --headless --path . --script res://addons/agentic_studio/live_plan_check.gd

const ConfigScript = preload("res://addons/agentic_studio/config.gd")
const JobScript = preload("res://addons/agentic_studio/job.gd")
const ClientScript = preload("res://addons/agentic_studio/model_client.gd")


func _initialize() -> void:
	var failures: PackedStringArray = PackedStringArray()
	ConfigScript.ensure_dirs()

	var scene_snapshot: Dictionary = _snapshot_scenes()

	var selected_id: String = ConfigScript.get_selected_model_id()
	if selected_id.is_empty():
		print("AgenticStudio live_plan_check: FAILED")
		print("  - no selected model in user://agentic_studio.cfg")
		quit(1)
		return

	var model: Dictionary = ConfigScript.get_model(selected_id)
	if model.is_empty():
		print("AgenticStudio live_plan_check: FAILED")
		print("  - selected model missing from config")
		quit(1)
		return

	var base_url: String = str(model.get("base_url", "")).strip_edges()
	var model_name: String = str(model.get("model_name", "")).strip_edges()
	print("live_plan_check: using model id=%s name=%s base=%s" % [
		selected_id, model_name, base_url
	])

	# --- Bad base URL: job fails, no scene change ---
	var bad_model: Dictionary = model.duplicate(true)
	bad_model["base_url"] = "http://127.0.0.1:1/v1"
	var bad_job = JobScript.new("live_plan_bad_url")
	bad_job.prompt = "Should fail"
	bad_job.model_id = selected_id
	bad_job.mode = JobScript.MODE_PLAN
	bad_job.stage = JobScript.STAGE_RUNNING
	bad_job.append_log("Job created.")
	var bad_result: Dictionary = ClientScript.request_plan_via_client(
		bad_model,
		bad_job.prompt,
		5.0
	)
	if bool(bad_result.get("ok", false)):
		failures.append("bad base URL unexpectedly succeeded")
	else:
		bad_job.append_log(str(bad_result.get(
			"error",
			ClientScript.format_failure_log(
				int(bad_result.get("status", 0)),
				str(bad_result.get("result", "")),
				str(bad_result.get("body", ""))
			)
		)))
		bad_job.stage = JobScript.STAGE_FAILED
		bad_job.save()
		var bad_loaded = JobScript.load_from_path(bad_job.file_path())
		if bad_loaded == null or bad_loaded.stage != JobScript.STAGE_FAILED:
			failures.append("bad URL job did not persist as failed")

	# --- Live Plan against saved test model ---
	var job = JobScript.new("live_plan_ok")
	job.prompt = "In one short paragraph, plan how you would add a Marker3D named AgentAnchor. Do not claim you edited anything."
	job.model_id = selected_id
	job.mode = JobScript.MODE_PLAN
	job.stage = JobScript.STAGE_RUNNING
	job.append_log("Job created.")
	job.save()

	var result: Dictionary = ClientScript.request_plan_via_client(model, job.prompt, 120.0)
	if not bool(result.get("ok", false)):
		failures.append("live plan failed: %s" % str(result.get("error", result)))
		job.append_log(str(result.get("error", "unknown failure")))
		job.stage = JobScript.STAGE_FAILED
		job.save()
	else:
		var text: String = str(result.get("text", ""))
		job.append_log(text)
		job.stage = JobScript.STAGE_PLANNED
		job.save()
		print("live_plan_check: assistant text (%d chars): %s" % [
			text.length(),
			text.substr(0, 160).replace("\n", " ")
		])

		var reloaded = JobScript.load_from_path(job.file_path())
		if reloaded == null:
			failures.append("reopened job missing")
		elif reloaded.stage != JobScript.STAGE_PLANNED:
			failures.append("reopened job stage=%s want=planned" % reloaded.stage)
		elif reloaded.log_lines.is_empty() or str(reloaded.log_lines[reloaded.log_lines.size() - 1]) != text:
			# Allow multi-line: require the model text to appear in the joined log.
			var joined: String = "\n".join(reloaded.log_lines)
			if joined.find(text) < 0:
				failures.append("reopened job log missing model text")

	var scene_after: Dictionary = _snapshot_scenes()
	if not _snapshots_equal(scene_snapshot, scene_after):
		failures.append("scene files changed during Plan — must not edit scenes")

	# Leave live_plan_ok in jobs/ so the dock can show it; remove only the bad-url job.
	_remove_job_file(bad_job.file_path())

	if failures.is_empty():
		print("AgenticStudio live_plan_check: OK")
		quit(0)
	else:
		print("AgenticStudio live_plan_check: FAILED")
		for f: String in failures:
			print("  - ", f)
		quit(1)


func _snapshot_scenes() -> Dictionary:
	var out: Dictionary = {}
	_scan_scenes("res://", out)
	return out


func _scan_scenes(path: String, out: Dictionary) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full: String = path.path_join(name) if path != "res://" else "res://%s" % name
		if dir.current_is_dir():
			if name != "addons" and name != ".godot":
				_scan_scenes(full, out)
		elif name.ends_with(".tscn") or name.ends_with(".scn"):
			var abs_path: String = ProjectSettings.globalize_path(full)
			var modified: int = 0
			if FileAccess.file_exists(full):
				modified = int(FileAccess.get_modified_time(full))
			out[full] = modified
		name = dir.get_next()
	dir.list_dir_end()


func _snapshots_equal(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for key: Variant in a.keys():
		if not b.has(key):
			return false
		if int(a[key]) != int(b[key]):
			return false
	return true


func _remove_job_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
