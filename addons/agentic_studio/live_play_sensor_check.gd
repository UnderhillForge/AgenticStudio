class_name AgenticStudioLivePlaySensorCheck
extends RefCounted
## Live: clean play + frame; parse stays parse; add_node auto-approves with page_id;
## script-body confirms; missing page_id rejected; Plan quotes page without edit.

const PlaySupportScript = preload("res://addons/agentic_studio/play_support.gd")
const PolicyScript = preload("res://addons/agentic_studio/policy.gd")
const PAGE_ID: String = "goblin_shaman"


func run() -> Dictionary:
	var failures: PackedStringArray = PackedStringArray()
	AgenticStudioConfig.ensure_dirs()

	var selected_id: String = AgenticStudioConfig.get_selected_model_id()
	var model: Dictionary = AgenticStudioConfig.get_model(selected_id)
	if model.is_empty():
		return {"ok": false, "failures": PackedStringArray(["no selected model"])}

	# Open / ensure a clean 3D scene.
	var scene_path: String = "res://agent_probe_scene.tscn"
	_ensure_probe_scene(scene_path)
	EditorInterface.open_scene_from_path(scene_path)
	# Skip set_main_screen_editor — can trip macOS menu-thread asserts during live boots.
	await _frames(6)
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return {"ok": false, "failures": PackedStringArray(["no open scene"])}
	_remove_child_named(root, "AgentProbe")
	_remove_child_named(root, "BrokenProbe")
	_remove_child_named(root, "SensorProbe")

	# Ensure PlayProbe is not already an autoload.
	if ProjectSettings.has_setting("autoload/PlayProbe"):
		failures.append("PlayProbe already in project settings before test")

	# --- Clean play ---
	var support = PlaySupportScript.new()
	var play_res: Dictionary = await support.play_current_scene(
		PlaySupportScript.PLAY_TIMEOUT_SEC,
		PackedStringArray([PAGE_ID])
	)
	if str(play_res.get("phase", "")) != "play":
		failures.append("clean play phase=%s want=play" % str(play_res.get("phase", "")))
	if not bool(play_res.get("ok", false)):
		failures.append("clean play not ok: %s" % PlaySupportScript.format_play_log(play_res))
	var frame: String = str(play_res.get("frame", ""))
	if frame.is_empty() or not FileAccess.file_exists(ProjectSettings.globalize_path(frame)):
		failures.append("clean play missing frame file")
	if ProjectSettings.has_setting("autoload/PlayProbe"):
		failures.append("PlayProbe leaked into project settings after clean play")
	if EditorInterface.is_playing_scene():
		failures.append("game still playing after clean play")
		EditorInterface.stop_playing_scene()

	# --- Parse error: phase stays parse, no play/frame required ---
	var broken_path: String = "res://agent_probe_broken.gd"
	_write_text(broken_path, "extends Node3D\nfunc _ready() -> void:\n\tthis is not valid gdscript!!!\n")
	EditorInterface.get_resource_filesystem().scan()
	await _frames(2)
	var parse_tools := AgenticStudioSceneTools.new()
	parse_tools.setup("live_sensor_parse")
	var add_broken: Dictionary = parse_tools.execute(
		AgenticStudioSceneTools.TOOL_ADD_NODE,
		{"type": "Node3D", "name": "BrokenProbe", "page_id": PAGE_ID}
	)
	if not bool(add_broken.get("ok", false)):
		failures.append("add BrokenProbe failed: %s" % str(add_broken.get("error", "")))
	var gd := GDScript.new()
	gd.source_code = FileAccess.get_file_as_string(broken_path)
	var set_broken: Dictionary = parse_tools.execute(
		AgenticStudioSceneTools.TOOL_SET_PROPERTY,
		{"path": "BrokenProbe", "property": "script", "value": gd, "page_id": PAGE_ID}
	)
	# set_property script is CONFIRM — still executes when called directly (policy is ask-layer).
	if not bool(set_broken.get("ok", false)):
		failures.append("attach broken script failed: %s" % str(set_broken.get("error", "")))
	var parse_play: Dictionary = await parse_tools.execute_play()
	var parse_result: Dictionary = parse_play.get("result", {})
	if str(parse_result.get("phase", "")) != "parse":
		failures.append("parse job phase=%s want=parse" % str(parse_result.get("phase", "")))
	if bool(parse_result.get("ok", false)):
		failures.append("parse job must not be ok")
	# Frame not required on parse failure.
	parse_tools.finish()
	# Undo if the node is still in the edited scene; otherwise remove directly.
	root = EditorInterface.get_edited_scene_root()
	if root != null and root.get_node_or_null(NodePath("BrokenProbe")) != null:
		if not _undo_once(root):
			_remove_child_named(root, "BrokenProbe")
	await _frames(2)
	_remove_child_named(EditorInterface.get_edited_scene_root(), "BrokenProbe")

	# --- Add-child auto-approves with page_id; one undo ---
	root = EditorInterface.get_edited_scene_root()
	_remove_child_named(root, "SensorProbe")
	var auto_tools := AgenticStudioSceneTools.new()
	auto_tools.setup("live_sensor_add")
	if not PolicyScript.is_allowed_unattended("add_node", {"type": "Node3D", "name": "SensorProbe"}):
		failures.append("policy must allow add_node unattended")
	var add_out: Dictionary = auto_tools.execute(
		AgenticStudioSceneTools.TOOL_ADD_NODE,
		{"type": "Node3D", "name": "SensorProbe", "page_id": PAGE_ID}
	)
	if not bool(add_out.get("ok", false)):
		failures.append("add_node with page_id failed: %s" % str(add_out.get("error", "")))
	root = EditorInterface.get_edited_scene_root()
	var probe: Node = root.get_node_or_null(NodePath("SensorProbe")) if root else null
	if probe == null:
		failures.append("SensorProbe missing after add")
	elif not probe.has_meta("agentic_page") or str(probe.get_meta("agentic_page")) != PAGE_ID:
		failures.append("agentic_page meta missing or wrong")
	auto_tools.finish()
	if not _undo_once(root):
		failures.append("undo after add failed")
	await _frames(2)
	root = EditorInterface.get_edited_scene_root()
	if root != null and root.get_node_or_null(NodePath("SensorProbe")) != null:
		failures.append("SensorProbe still present after one undo")

	# --- Missing page_id rejected before undo-redo ---
	var reject_tools := AgenticStudioSceneTools.new()
	reject_tools.setup("live_sensor_nopage")
	var before_count: int = _child_count(EditorInterface.get_edited_scene_root())
	var no_page: Dictionary = reject_tools.execute(
		AgenticStudioSceneTools.TOOL_ADD_NODE,
		{"type": "Node3D", "name": "NoPageProbe"}
	)
	if bool(no_page.get("ok", false)):
		failures.append("add_node without page_id must fail")
	if str(no_page.get("error", "")).find("page_id") < 0 and str(no_page.get("log", "")).find("page_id") < 0:
		failures.append("missing page_id error unclear: %s" % str(no_page.get("error", "")))
	if _child_count(EditorInterface.get_edited_scene_root()) != before_count:
		failures.append("rejected add_node still changed the scene")
	if reject_tools.has_writes():
		failures.append("rejected add_node must not mark writes")

	# --- Script-body op stops for confirm under Auto-approve ask layer ---
	if not PolicyScript.should_ask("write_file", {"path": "res://_sensor_script.gd"}, false):
		failures.append("script-body write_file must ask under Auto-approve")

	# --- Plan quotes page, no scene edit ---
	var plan_before: int = _child_count(EditorInterface.get_edited_scene_root())
	var plan_job := AgenticStudioJob.new("live_sensor_plan")
	plan_job.prompt = (
		"What notes are on the Goblin Shaman page? Quote them. Do not edit the scene."
	)
	plan_job.model_id = selected_id
	plan_job.mode = AgenticStudioJob.MODE_PLAN
	plan_job.stage = AgenticStudioJob.STAGE_RUNNING
	plan_job.append_log("Job created.")
	plan_job.save()
	var plan_tools := AgenticStudioSceneTools.new()
	plan_tools.setup(plan_job.id)
	await AgenticStudioExecuteRunner.run_plan_sync(plan_job, model, plan_tools)
	if plan_tools.has_writes() or plan_tools.has_scene_writes():
		failures.append("Plan must not write")
	if _child_count(EditorInterface.get_edited_scene_root()) != plan_before:
		failures.append("Plan changed the scene")

	# Cleanup broken script file
	if FileAccess.file_exists(broken_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(broken_path))

	return {
		"ok": failures.is_empty(),
		"failures": failures,
		"auto_job": "live_sensor_add",
		"parse_job": "live_sensor_parse",
		"plan_job": plan_job.id,
	}


func _ensure_probe_scene(path: String) -> void:
	if FileAccess.file_exists(path):
		return
	var root := Node3D.new()
	root.name = "ProbeRoot"
	var packed := PackedScene.new()
	if packed.pack(root) == OK:
		ResourceSaver.save(packed, path)
	root.free()


func _write_text(path: String, content: String) -> void:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(content)
		f.close()


func _remove_child_named(root: Node, child_name: String) -> void:
	if root == null:
		return
	var n: Node = root.get_node_or_null(NodePath(child_name))
	if n != null:
		root.remove_child(n)
		n.free()


func _child_count(root: Node) -> int:
	if root == null:
		return 0
	return root.get_child_count()


func _undo_once(root: Node) -> bool:
	if root == null:
		return false
	var ur_mgr: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	var history_id: int = ur_mgr.get_object_history_id(root)
	var ur: UndoRedo = ur_mgr.get_history_undo_redo(history_id)
	if ur == null or not ur.has_undo():
		return false
	ur.undo()
	return true


func _frames(n: int) -> void:
	var tree: SceneTree = EditorInterface.get_base_control().get_tree()
	for _i: int in range(n):
		await tree.process_frame
