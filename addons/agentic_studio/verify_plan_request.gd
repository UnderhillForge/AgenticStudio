extends SceneTree
## Headless check: Plan request can be built from config; no live model; no scene edits.
## Run: godot --headless --path . --script res://addons/agentic_studio/verify_plan_request.gd

const ConfigScript = preload("res://addons/agentic_studio/config.gd")
const JobScript = preload("res://addons/agentic_studio/job.gd")
const ClientScript = preload("res://addons/agentic_studio/model_client.gd")


func _initialize() -> void:
	var failures: PackedStringArray = PackedStringArray()

	ConfigScript.ensure_dirs()

	# Build a Plan request from a synthetic model — no network.
	var model: Dictionary = {
		"id": "verify_plan_model",
		"display_name": "Verify Plan Model",
		"kind": "local",
		"base_url": "http://example.invalid:9/v1",
		"model_name": "verify-model",
	}
	var built: Dictionary = ClientScript.build_plan_request(model, "Add a Marker3D named Anchor")
	if not bool(built.get("ok", false)):
		failures.append("build_plan_request should succeed for a complete model")
	else:
		var url: String = str(built.get("url", ""))
		if url != "http://example.invalid:9/v1/chat/completions":
			failures.append("unexpected completions URL: %s" % url)
		var body: String = str(built.get("body", ""))
		if body.find("verify-model") < 0:
			failures.append("request body missing model name")
		if body.find("planning only") < 0 and body.find("Planning text only") < 0:
			# System prompt is JSON-escaped inside the body.
			if body.find("planning") < 0:
				failures.append("request body missing planning system prompt")
		var headers: PackedStringArray = built.get("headers", PackedStringArray())
		for h: String in headers:
			if h.begins_with("Authorization:"):
				failures.append("local model must not send bearer token")

	# External model with key gets bearer header; key is not hardcoded into repo paths.
	var external: Dictionary = {
		"id": "verify_ext",
		"kind": "external",
		"base_url": "https://api.example.com/v1",
		"model_name": "ext",
		"api_key": "user-config-only",
	}
	var ext_built: Dictionary = ClientScript.build_plan_request(external, "plan me")
	var saw_bearer: bool = false
	for h: String in ext_built.get("headers", PackedStringArray()):
		if h == "Authorization: Bearer user-config-only":
			saw_bearer = true
	if not saw_bearer:
		failures.append("external model with key should send bearer token")

	# Empty base URL refuses to build (dock writes nothing).
	var empty_base: Dictionary = ClientScript.build_plan_request({
		"id": "empty",
		"base_url": "",
		"model_name": "x",
	}, "hi")
	if bool(empty_base.get("ok", true)):
		failures.append("empty base URL must not build a request")

	# A Plan job object can be constructed and saved without calling a model.
	var job = JobScript.new("verify_plan_job_shape")
	job.prompt = "Describe adding a node"
	job.model_id = "verify_plan_model"
	job.mode = JobScript.MODE_PLAN
	job.stage = JobScript.STAGE_RUNNING
	job.append_log("Job created.")
	# Simulate a planned result without network.
	job.append_log("1. Open the scene\n2. Add Marker3D\n(planning only — no edits performed)")
	job.stage = JobScript.STAGE_PLANNED
	var save_err: Error = job.save()
	if save_err != OK:
		failures.append("plan job save failed: %d" % save_err)
	var loaded = JobScript.load_from_path(job.file_path())
	if loaded == null or loaded.stage != JobScript.STAGE_PLANNED:
		failures.append("planned job did not reload with stage=planned")
	if loaded != null and loaded.log_lines.is_empty():
		failures.append("planned job log empty after reload")

	# Failed job shape (e.g. 503) — still no scene class.
	var failed = JobScript.new("verify_plan_job_failed")
	failed.prompt = "x"
	failed.model_id = "verify_plan_model"
	failed.mode = JobScript.MODE_PLAN
	failed.stage = JobScript.STAGE_FAILED
	failed.append_log(ClientScript.format_failure_log(
		503,
		"http_503",
		'{"error":{"code":"model_load_failed"}}'
	))
	failed.save()

	# Assert we did not pull in a scene-editing helper. This script only preloads
	# config, job, and model_client — none of which edit scenes.
	var scene_edit_names: PackedStringArray = PackedStringArray([
		"AgenticStudioSceneEdit",
		"SceneEditor",
		"EditorSceneEdit",
	])
	for class_name_str: String in scene_edit_names:
		if ClassDB.class_exists(class_name_str):
			failures.append("unexpected scene-editing class registered: %s" % class_name_str)

	# Cleanup verify jobs only (do not touch user models / agentic_studio.cfg entries).
	_remove_job_file(job.file_path())
	_remove_job_file(failed.file_path())

	if failures.is_empty():
		print("AgenticStudio verify_plan_request: OK")
		quit(0)
	else:
		print("AgenticStudio verify_plan_request: FAILED")
		for f: String in failures:
			print("  - ", f)
		quit(1)


func _remove_job_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
