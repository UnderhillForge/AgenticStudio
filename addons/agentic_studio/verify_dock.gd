extends SceneTree
## Headless: job channel field + dock script parses. No live editor UI.
## Run: godot --headless --path . --script res://addons/agentic_studio/verify_dock.gd

const JobScript = preload("res://addons/agentic_studio/job.gd")
const DockScript = preload("res://addons/agentic_studio/dock.gd")


func _initialize() -> void:
	var failures: PackedStringArray = PackedStringArray()

	if JobScript.CHANNEL_STUDIO == JobScript.CHANNEL_SESSION:
		failures.append("channel constants collided")

	var job := JobScript.new("verify_dock_channel")
	if job.channel != JobScript.CHANNEL_SESSION:
		failures.append("default channel should be session")
	job.channel = JobScript.CHANNEL_STUDIO
	job.prompt = "studio prompt"
	job.save()

	var loaded: AgenticStudioJob = JobScript.load_from_path(job.file_path())
	if loaded == null:
		failures.append("reload failed")
	elif loaded.channel != JobScript.CHANNEL_STUDIO:
		failures.append("channel not persisted")
	elif loaded.tab_title().find("studio prompt") < 0:
		failures.append("tab_title should use prompt")

	var empty := JobScript.new("verify_dock_empty")
	empty.prompt = ""
	if not empty.tab_title().is_empty():
		failures.append("empty prompt tab_title should be empty string")

	# Old jobs without channel key default to session.
	var legacy_path: String = AgenticStudioConfig.JOBS_DIR.path_join("verify_dock_legacy.json")
	var legacy := FileAccess.open(legacy_path, FileAccess.WRITE)
	if legacy != null:
		legacy.store_string(JSON.stringify({
			"id": "verify_dock_legacy",
			"prompt": "legacy",
			"model_id": "",
			"mode": "plan",
			"stage": "planned",
			"log": [],
			"created_at": 1,
			"updated_at": 1,
		}, "\t"))
		legacy.close()
		var legacy_job: AgenticStudioJob = JobScript.load_from_path(legacy_path)
		if legacy_job == null or legacy_job.channel != JobScript.CHANNEL_SESSION:
			failures.append("legacy job should default channel=session")
		DirAccess.remove_absolute(ProjectSettings.globalize_path(legacy_path))

	# Dock script must load (class parses). Instantiating needs an editor tree — skip.
	if DockScript == null:
		failures.append("dock script failed to preload")

	# Cleanup
	for path: String in [job.file_path(), empty.file_path()]:
		var abs_p: String = ProjectSettings.globalize_path(path)
		if FileAccess.file_exists(abs_p):
			DirAccess.remove_absolute(abs_p)

	if failures.is_empty():
		print("AgenticStudio verify_dock: OK")
		quit(0)
	else:
		print("AgenticStudio verify_dock: FAILED")
		for f: String in failures:
			print("  - ", f)
		quit(1)
