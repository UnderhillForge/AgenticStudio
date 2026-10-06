extends SceneTree
## Headless: session transcript append, collapse, log persistence, open-ids.
## Run: godot --headless --path . --script res://addons/agentic_studio/verify_transcript.gd

const TranscriptScript = preload("res://addons/agentic_studio/session_transcript.gd")
const JobScript = preload("res://addons/agentic_studio/job.gd")
const ConfigScript = preload("res://addons/agentic_studio/config.gd")


func _initialize() -> void:
	var failures: PackedStringArray = PackedStringArray()
	ConfigScript.ensure_dirs()

	# Fresh transcript with two turns survives save/load.
	var tr: RefCounted = TranscriptScript.new("verify_tx_session")
	tr.title = "Verify Session"
	var job1 := JobScript.new("verify_tx_job1")
	job1.prompt = "first prompt"
	job1.mode = JobScript.MODE_PLAN
	job1.stage = JobScript.STAGE_PLANNED
	job1.append_log("Job created.")
	job1.append_log("Here is the plan for the first prompt.")
	var t0: int = tr.begin_turn(job1.prompt, job1.mode, "model_x", job1.id)
	tr.sync_turn_from_job(t0, job1)

	var job2 := JobScript.new("verify_tx_job2")
	job2.prompt = "second prompt"
	job2.mode = JobScript.MODE_AUTO_APPROVE
	job2.stage = JobScript.STAGE_DONE
	job2.append_log("Job created.")
	job2.append_log("play_scene ok (no debugger errors)")
	job2.append_log("All set after the second prompt.")
	var t1: int = tr.begin_turn(job2.prompt, job2.mode, "model_x", job2.id)
	tr.sync_turn_from_job(t1, job2)

	if tr.turns.size() != 2:
		failures.append("expected 2 turns, got %d" % tr.turns.size())

	var rendered: String = tr.render_text()
	if rendered.find("first prompt") < 0 or rendered.find("second prompt") < 0:
		failures.append("render missing both prompts")
	if rendered.find(TranscriptScript.CHEVRON_CLOSED) < 0:
		failures.append("expected compacted chevron in render")
	# Tool line compacted summary
	if rendered.find("Running play_scene") < 0:
		failures.append("expected compacted play_scene summary")

	# Expand the play_scene block via line map.
	var expanded: bool = false
	for li: int in range(tr._line_map.size()):
		var meta: Variant = tr._line_map[li]
		if typeof(meta) != TYPE_DICTIONARY:
			continue
		var turn_i: int = int((meta as Dictionary).get("turn", -1))
		var block_i: int = int((meta as Dictionary).get("block", -1))
		if turn_i != 1:
			continue
		var blocks: Array = (tr.turns[turn_i] as Dictionary).get("blocks", [])
		if block_i < 0 or block_i >= blocks.size():
			continue
		var kind: String = str((blocks[block_i] as Dictionary).get("kind", ""))
		if kind != TranscriptScript.KIND_TOOL:
			continue
		if tr.toggle_at_line(li):
			expanded = true
			break
	if not expanded:
		failures.append("could not expand a tool block via toggle_at_line")
	var rendered2: String = tr.render_text()
	if rendered2.find(TranscriptScript.CHEVRON_OPEN) < 0:
		failures.append("expanded tool block should show open chevron")
	if rendered2.find("play_scene ok") < 0:
		failures.append("expanded tool block should show detail")

	if tr.save() != OK:
		failures.append("save transcript failed")
	var abs_log: String = ProjectSettings.globalize_path(tr.log_path())
	if not FileAccess.file_exists(abs_log):
		failures.append("log file missing after save")

	var reloaded: RefCounted = TranscriptScript.load_from_id("verify_tx_session")
	if reloaded == null:
		failures.append("reload returned null")
	elif reloaded.turns.size() != 2:
		failures.append("reloaded turns=%d want 2" % reloaded.turns.size())
	else:
		var rtext: String = reloaded.render_text()
		if rtext.find("first prompt") < 0 or rtext.find("second prompt") < 0:
			failures.append("reloaded render missing prompts")

	# Closing a tab must not delete the log — simulate by leaving file and clearing open ids.
	ConfigScript.set_open_session_ids(PackedStringArray(["verify_tx_session"]))
	var open1: PackedStringArray = ConfigScript.get_open_session_ids()
	if open1.size() != 1 or open1[0] != "verify_tx_session":
		failures.append("open session ids not persisted")
	ConfigScript.set_open_session_ids(PackedStringArray())
	if FileAccess.file_exists(abs_log):
		pass  # expected: log remains after "close"
	else:
		failures.append("log should remain after clearing open ids")

	# user:// refusal already covered elsewhere; studio id constant.
	if TranscriptScript.STUDIO_SESSION_ID != "studio":
		failures.append("studio session id should be 'studio'")
	var studio_path: String = TranscriptScript.log_path_for(TranscriptScript.STUDIO_SESSION_ID)
	if studio_path.find("logs/studio.log") < 0 and studio_path.find("logs\\studio.log") < 0:
		failures.append("studio log path unexpected: %s" % studio_path)

	# Cleanup verify artifacts (log file only — open ids already cleared).
	if FileAccess.file_exists(abs_log):
		DirAccess.remove_absolute(abs_log)
	for jid: String in ["verify_tx_job1", "verify_tx_job2"]:
		var jp: String = ProjectSettings.globalize_path(
			ConfigScript.JOBS_DIR.path_join("%s.json" % jid)
		)
		if FileAccess.file_exists(jp):
			DirAccess.remove_absolute(jp)

	if failures.is_empty():
		print("AgenticStudio verify_transcript: OK")
		quit(0)
	else:
		print("AgenticStudio verify_transcript: FAILED")
		for f: String in failures:
			print("  - ", f)
		quit(1)
