extends SceneTree
## Headless check for Phase 0/1 config + job persistence.
## Run: godot --headless --path . --script res://addons/agentic_studio/verify_phase1.gd
## Uses preload so --script works before global class_name registration.

const ConfigScript = preload("res://addons/agentic_studio/config.gd")
const JobScript = preload("res://addons/agentic_studio/job.gd")


func _initialize() -> void:
	var failures: PackedStringArray = PackedStringArray()

	ConfigScript.ensure_dirs()
	var previous_selected: String = ConfigScript.get_selected_model_id()

	var local_id: String = ConfigScript.upsert_model({
		"id": "verify_local",
		"display_name": "Verify Local",
		"kind": "local",
		"base_url": "http://127.0.0.1:8080/v1",
		"model_name": "test-7b",
		"context_length": 8192,
	})
	var ext_id: String = ConfigScript.upsert_model({
		"id": "verify_external",
		"display_name": "Verify External",
		"kind": "external",
		"base_url": "https://api.example.com/v1",
		"model_name": "ext-model",
		"context_length": 128000,
		"api_key": "secret-not-for-repo",
	})

	var models: Array[Dictionary] = ConfigScript.list_models()
	var found_local: bool = false
	var found_ext: bool = false
	for m: Dictionary in models:
		if str(m.get("id", "")) == local_id:
			found_local = true
			if str(m.get("kind", "")) != "local":
				failures.append("local model kind mismatch")
			if m.has("api_key"):
				failures.append("local model should not store api_key")
		if str(m.get("id", "")) == ext_id:
			found_ext = true
			if str(m.get("kind", "")) != "external":
				failures.append("external model kind mismatch")
			if str(m.get("api_key", "")) != "secret-not-for-repo":
				failures.append("external api_key not persisted in user:// config")
	if not found_local:
		failures.append("local model missing from list")
	if not found_ext:
		failures.append("external model missing from list")

	ConfigScript.set_blender_path("/Applications/Blender.app/Contents/MacOS/Blender")
	if ConfigScript.get_blender_path().is_empty():
		failures.append("blender path not saved")

	ConfigScript.upsert_extra_tool({
		"id": "verify_extra",
		"name": "Missing Tool",
		"path": "",
	})
	var extras: Array[Dictionary] = ConfigScript.list_extra_tools()
	var found_extra: bool = false
	for t: Dictionary in extras:
		if str(t.get("id", "")) == "verify_extra":
			found_extra = true
			if str(t.get("path", "")) != "":
				failures.append("empty extra path should remain empty")
	if not found_extra:
		failures.append("extra tool with empty path not saved")

	ConfigScript.set_selected_model_id(local_id)
	if ConfigScript.get_selected_model_id() != local_id:
		failures.append("selected model id not persisted")

	var job = JobScript.new("verify_job_plan")
	job.prompt = "Add a Node3D named Test"
	job.model_id = local_id
	job.mode = JobScript.MODE_PLAN
	job.stage = JobScript.STAGE_RUNNING
	job.append_log("Job created.")
	job.append_log("plan only — no scene edit (model: %s)" % local_id)
	job.stage = JobScript.STAGE_DONE
	var save_err: Error = job.save()
	if save_err != OK:
		failures.append("job save failed: %d" % save_err)

	var loaded = JobScript.load_from_path(job.file_path())
	if loaded == null:
		failures.append("job reload returned null")
	else:
		if loaded.prompt != job.prompt:
			failures.append("job prompt mismatch after reload")
		if loaded.mode != JobScript.MODE_PLAN:
			failures.append("job mode mismatch after reload")
		if loaded.model_id != local_id:
			failures.append("job model_id mismatch after reload")
		if loaded.log_lines.is_empty() or not str(loaded.log_lines[loaded.log_lines.size() - 1]).begins_with("plan only"):
			failures.append("plan log line missing after reload")

	var all_jobs: Array = JobScript.load_all()
	var found_job: bool = false
	for j in all_jobs:
		if j.id == "verify_job_plan":
			found_job = true
	if not found_job:
		failures.append("load_all did not include plan job")

	ConfigScript.remove_model(local_id)
	ConfigScript.remove_model(ext_id)
	ConfigScript.remove_extra_tool("verify_extra")
	# remove_model clears selection when it matches — restore the user's choice.
	ConfigScript.set_selected_model_id(previous_selected)
	var abs_job: String = ProjectSettings.globalize_path(job.file_path())
	if FileAccess.file_exists(job.file_path()):
		DirAccess.remove_absolute(abs_job)

	if not ConfigScript.CONFIG_PATH.begins_with("user://"):
		failures.append("config must live under user://")

	if failures.is_empty():
		print("AgenticStudio verify_phase1: OK")
		quit(0)
	else:
		print("AgenticStudio verify_phase1: FAILED")
		for f: String in failures:
			print("  - ", f)
		quit(1)
