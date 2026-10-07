extends SceneTree
## Headless: screenshot tool flags, shot dirs, prune-to-5, transcript shot line.
## Run: godot --headless --path . --script res://addons/agentic_studio/verify_screenshot.gd

const ToolsScript = preload("res://addons/agentic_studio/scene_tools.gd")
const ShotScript = preload("res://addons/agentic_studio/screenshot_support.gd")
const TranscriptScript = preload("res://addons/agentic_studio/session_transcript.gd")
const ClientScript = preload("res://addons/agentic_studio/model_client.gd")
const ConfigScript = preload("res://addons/agentic_studio/config.gd")
const JobScript = preload("res://addons/agentic_studio/job.gd")


func _initialize() -> void:
	var failures: PackedStringArray = PackedStringArray()
	ConfigScript.ensure_dirs()

	if not ToolsScript.is_allowed_tool("screenshot"):
		failures.append("screenshot must be allowed")
	if not ToolsScript.is_plan_tool("screenshot"):
		failures.append("screenshot must be a plan tool")
	if ToolsScript.is_write_tool("screenshot"):
		failures.append("screenshot must not be a write tool")
	if ToolsScript.is_always_confirm_tool("screenshot"):
		failures.append("screenshot must not ask")

	var plan_body: String = ClientScript.build_plan_body({"model_name": "x"}, "hi")
	if plan_body.find("screenshot") < 0:
		failures.append("Plan body missing screenshot")
	if ToolsScript.tool_definitions().size() != 29:
		failures.append("expected 29 tools")
	if ToolsScript.plan_tool_definitions().size() != 14:
		failures.append("expected 14 plan tools")

	if ShotScript.normalize_target("editor_3d") != ShotScript.TARGET_EDITOR_3D:
		failures.append("normalize editor_3d failed")
	if ShotScript.normalize_target("play") != ShotScript.TARGET_PLAY:
		failures.append("normalize play failed")
	if not ShotScript.normalize_target("nope").is_empty():
		failures.append("bad target should normalize empty")

	# Prune keeps 5 newest.
	var sid: String = "verify_shot_session"
	ShotScript.delete_session_shots_dir(sid)
	var dir_path: String = ShotScript.ensure_session_dir(sid)
	for i: int in range(7):
		var p: String = dir_path.path_join("shot_%d_editor_3d.png" % (1000 + i))
		var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.1 * i, 0.2, 0.3))
		img.save_png(ProjectSettings.globalize_path(p))
	var pruned: PackedStringArray = ShotScript.prune_session_shots(sid)
	if pruned.size() != 2:
		failures.append("prune should delete 2 oldest, got %d" % pruned.size())
	var left: PackedStringArray = ShotScript.list_session_pngs(sid)
	if left.size() != 5:
		failures.append("expected 5 shots after prune, got %d" % left.size())

	# Transcript screenshot block + missing file → shot removed.
	var tr: RefCounted = TranscriptScript.new(sid)
	var job := JobScript.new("verify_shot_job")
	job.prompt = "screenshot the 3D editor"
	job.mode = JobScript.MODE_AUTO_APPROVE
	job.stage = JobScript.STAGE_DONE
	job.append_log("Job created.")
	job.append_log("screenshot ok target=editor_3d path=%s" % left[0])
	var ti: int = tr.begin_turn(job.prompt, job.mode, "m", job.id)
	tr.sync_turn_from_job(ti, job)
	var rendered: String = tr.render_text()
	if rendered.find("Screenshot editor_3d") < 0:
		failures.append("transcript missing Screenshot editor_3d summary")
	# Expand screenshot block
	var expanded: bool = false
	for li: int in range(tr._line_map.size()):
		var meta: Variant = tr._line_map[li]
		if typeof(meta) != TYPE_DICTIONARY:
			continue
		var bi: int = int((meta as Dictionary).get("block", -1))
		var blocks: Array = (tr.turns[0] as Dictionary).get("blocks", [])
		if bi < 0 or bi >= blocks.size():
			continue
		if str((blocks[bi] as Dictionary).get("kind", "")) != TranscriptScript.KIND_SCREENSHOT:
			continue
		if tr.toggle_at_line(li):
			expanded = true
			break
	if not expanded:
		failures.append("could not expand screenshot block")
	var rendered2: String = tr.render_text()
	if rendered2.find(left[0]) < 0 and rendered2.find("shot removed") < 0:
		failures.append("expanded screenshot should show path")
	if rendered2.find(TranscriptScript.REMOVE_MARK) < 0:
		failures.append("expanded screenshot should show Remove")

	# Delete via remove_shot_at_line
	var removed_click: bool = false
	for li2: int in range(tr._line_map.size()):
		var meta2: Variant = tr._line_map[li2]
		if typeof(meta2) == TYPE_DICTIONARY and bool((meta2 as Dictionary).get("remove", false)):
			if tr.remove_shot_at_line(li2):
				removed_click = true
				break
	if not removed_click:
		failures.append("Remove click did not delete shot")
	var abs0: String = ProjectSettings.globalize_path(left[0])
	if FileAccess.file_exists(abs0):
		failures.append("Remove should delete the PNG file")
	var rendered3: String = tr.render_text()
	# Collapse then expand again — or already expanded shows shot removed
	for li3: int in range(tr._line_map.size()):
		var meta3: Variant = tr._line_map[li3]
		if typeof(meta3) != TYPE_DICTIONARY:
			continue
		tr.toggle_at_line(li3)
		break
	rendered3 = tr.render_text()
	# Force expand screenshot again
	for li4: int in range(tr._line_map.size()):
		var meta4: Variant = tr._line_map[li4]
		if typeof(meta4) != TYPE_DICTIONARY:
			continue
		var bi4: int = int((meta4 as Dictionary).get("block", -1))
		var blocks4: Array = (tr.turns[0] as Dictionary).get("blocks", [])
		if bi4 >= 0 and bi4 < blocks4.size():
			if str((blocks4[bi4] as Dictionary).get("kind", "")) == TranscriptScript.KIND_SCREENSHOT:
				(blocks4[bi4] as Dictionary)["collapsed"] = false
				tr.turns[0]["blocks"] = blocks4
				break
	rendered3 = tr.render_text()
	if rendered3.find("shot removed") < 0:
		failures.append("missing PNG should render as shot removed")

	# accepts_images false clears pending without attaching
	var tools = ToolsScript.new()
	tools.setup("verify_shot_tools", sid)
	tools.pending_shot_paths = PackedStringArray([left[1] if left.size() > 1 else ""])
	var messages: Array = []
	ClientScript.apply_pending_shots(messages, {"accepts_images": false}, tools)
	if not tools.pending_shot_paths.is_empty():
		failures.append("pending shots should clear when model rejects images")
	if not messages.is_empty():
		failures.append("no image message when accepts_images is false")

	ShotScript.delete_session_shots_dir(sid)
	var abs_dir: String = ProjectSettings.globalize_path(ShotScript.session_shots_dir(sid))
	if DirAccess.dir_exists_absolute(abs_dir):
		failures.append("delete_session_shots_dir left the directory")

	if failures.is_empty():
		print("AgenticStudio verify_screenshot: OK")
		quit(0)
	else:
		print("AgenticStudio verify_screenshot: FAILED")
		for f: String in failures:
			print("  - ", f)
		quit(1)
