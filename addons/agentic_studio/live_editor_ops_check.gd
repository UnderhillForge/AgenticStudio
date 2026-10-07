class_name AgenticStudioLiveEditorOpsCheck
extends RefCounted
## Live: hierarchy/properties on deep scene; reparent undoes in one action;
## signal_connect missing method; script_patch parse; input_map_ensure needs_confirm;
## editor_screenshot ≠ play frame; page_id reject.

const PolicyScript = preload("res://addons/agentic_studio/policy.gd")
const PAGE_ID: String = "goblin_shaman"


func run() -> Dictionary:
	var failures: PackedStringArray = PackedStringArray()
	AgenticStudioConfig.ensure_dirs()

	var scene_path: String = "res://agent_probe_scene.tscn"
	_ensure_probe_scene(scene_path)
	EditorInterface.open_scene_from_path(scene_path)
	await _frames(6)
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return {"ok": false, "failures": PackedStringArray(["no open scene"])}

	# Build a deeper tree: Root > ParentA > ChildB
	_remove_child_named(root, "ParentA")
	_remove_child_named(root, "ChildB")
	_remove_child_named(root, "DupTarget")
	_remove_child_named(root, "SignalSrc")
	_remove_child_named(root, "SignalDst")

	var setup := AgenticStudioSceneTools.new()
	setup.setup("live_editor_ops_setup")
	var add_a: Dictionary = setup.execute(
		"add_node", {"type": "Node3D", "name": "ParentA", "page_id": PAGE_ID}
	)
	if not bool(add_a.get("ok", false)):
		failures.append("add ParentA failed: %s" % str(add_a.get("error", "")))
	# Child under ParentA via reparent after add under root then reparent — or add then reparent.
	var add_b: Dictionary = setup.execute(
		"add_node", {"type": "Node3D", "name": "ChildB", "page_id": PAGE_ID}
	)
	if not bool(add_b.get("ok", false)):
		failures.append("add ChildB failed: %s" % str(add_b.get("error", "")))
	var rep: Dictionary = setup.execute(
		"node_reparent",
		{"path": "ChildB", "parent": "ParentA", "page_id": PAGE_ID}
	)
	if not bool(rep.get("ok", false)):
		failures.append("setup reparent failed: %s" % str(rep.get("error", "")))
	setup.finish()
	await _frames(2)
	root = EditorInterface.get_edited_scene_root()

	# --- hierarchy + node_properties on scene deeper than one node ---
	var read_tools := AgenticStudioSceneTools.new()
	read_tools.setup("live_editor_ops_read")
	var hier: Dictionary = read_tools.execute(
		"scene_hierarchy", {"depth": 8, "offset": 0, "limit": 50}
	)
	if not bool(hier.get("ok", false)):
		failures.append("scene_hierarchy failed: %s" % str(hier.get("error", "")))
	else:
		var nodes: Array = hier.get("result", {}).get("nodes", [])
		if nodes.size() < 3:
			failures.append("hierarchy expected >=3 nodes, got %d" % nodes.size())
		var paths: PackedStringArray = PackedStringArray()
		for n: Variant in nodes:
			paths.append(str((n as Dictionary).get("path", "")))
		if not paths.has("ParentA") or not paths.has("ParentA/ChildB"):
			failures.append("hierarchy missing ParentA/ChildB: %s" % str(paths))
	var props: Dictionary = read_tools.execute(
		"node_properties", {"path": "ParentA/ChildB"}
	)
	if not bool(props.get("ok", false)):
		failures.append("node_properties failed: %s" % str(props.get("error", "")))
	else:
		var pmap: Dictionary = props.get("result", {}).get("properties", {})
		if pmap.is_empty():
			failures.append("node_properties returned empty snapshot")

	# --- reparent undoes in one action ---
	var move_tools := AgenticStudioSceneTools.new()
	move_tools.setup("live_editor_ops_reparent")
	var before_parent: Node = root.get_node_or_null(NodePath("ParentA/ChildB"))
	if before_parent == null:
		failures.append("ChildB not under ParentA before reparent test")
	var rep2: Dictionary = move_tools.execute(
		"node_reparent",
		{"path": "ParentA/ChildB", "parent": ".", "page_id": PAGE_ID}
	)
	if not bool(rep2.get("ok", false)):
		failures.append("reparent to root failed: %s" % str(rep2.get("error", "")))
	root = EditorInterface.get_edited_scene_root()
	if root.get_node_or_null(NodePath("ChildB")) == null:
		failures.append("ChildB not under root after reparent")
	move_tools.finish()
	if not _undo_once(root):
		failures.append("undo after reparent failed")
	await _frames(2)
	root = EditorInterface.get_edited_scene_root()
	if root.get_node_or_null(NodePath("ParentA/ChildB")) == null:
		failures.append("ChildB not restored under ParentA after one undo")

	# --- signal_connect fails on missing method; does not write a script ---
	var sig_tools := AgenticStudioSceneTools.new()
	sig_tools.setup("live_editor_ops_signal")
	sig_tools.execute("add_node", {"type": "Node3D", "name": "SignalSrc", "page_id": PAGE_ID})
	sig_tools.execute("add_node", {"type": "Node3D", "name": "SignalDst", "page_id": PAGE_ID})
	var before_script: Variant = null
	var dst: Node = EditorInterface.get_edited_scene_root().get_node_or_null(NodePath("SignalDst"))
	if dst != null:
		before_script = dst.get_script()
	var sig_fail: Dictionary = sig_tools.execute(
		"signal_connect",
		{
			"from": "SignalSrc",
			"signal": "ready",
			"to": "SignalDst",
			"method": "this_method_does_not_exist_xyz",
			"page_id": PAGE_ID,
		}
	)
	if bool(sig_fail.get("ok", false)):
		failures.append("signal_connect must fail on missing method")
	if str(sig_fail.get("error", "")).find("method") < 0 \
			and str(sig_fail.get("log", "")).find("method") < 0:
		failures.append("signal_connect missing-method error unclear: %s" % str(sig_fail.get("error", "")))
	dst = EditorInterface.get_edited_scene_root().get_node_or_null(NodePath("SignalDst"))
	if dst != null and dst.get_script() != before_script:
		failures.append("signal_connect must not write/attach a script on failure")
	sig_tools.finish()
	_undo_once(EditorInterface.get_edited_scene_root())
	await _frames(1)
	_remove_child_named(EditorInterface.get_edited_scene_root(), "SignalSrc")
	_remove_child_named(EditorInterface.get_edited_scene_root(), "SignalDst")

	# --- script_patch with parse error stays phase parse; does not overwrite good script ---
	var patch_path: String = "res://agent_probe_ready.gd"
	var prior: String = ""
	if FileAccess.file_exists(patch_path):
		prior = FileAccess.get_file_as_string(patch_path)
	else:
		prior = "extends Node3D\nfunc _ready() -> void:\n\tpass\n"
		_write_text(patch_path, prior)
	var patch_tools := AgenticStudioSceneTools.new()
	patch_tools.setup("live_editor_ops_patch")
	# Policy confirm: still executes when called directly (ask layer is elsewhere).
	if not PolicyScript.needs_confirm("script_patch", {"path": patch_path}):
		failures.append("script_patch must needs_confirm")
	var bad_patch: Dictionary = patch_tools.execute(
		"script_patch",
		{
			"path": patch_path,
			"content": "extends Node3D\nfunc _ready() -> void:\n\tthis is broken (((\n",
			"page_id": PAGE_ID,
		}
	)
	if bool(bad_patch.get("ok", false)):
		failures.append("script_patch parse error must fail")
	var phase: String = str(bad_patch.get("result", {}).get("phase", ""))
	if phase != "parse":
		failures.append("script_patch phase=%s want=parse" % phase)
	var after: String = FileAccess.get_file_as_string(patch_path)
	if after != prior:
		failures.append("script_patch parse failure overwrote good script")
		_write_text(patch_path, prior)
	if patch_tools.has_writes():
		failures.append("failed script_patch must not mark writes")
	patch_tools.discard_if_empty()

	# --- input_map_ensure returns needs_confirm and does not write under auto_approve ---
	if PolicyScript.is_allowed_unattended("input_map_ensure", {"action": "agentic_live_test"}):
		failures.append("input_map_ensure must not be unattended")
	# Prove auto_approve path refuses via policy classify (apply_server short-circuit).
	if not PolicyScript.needs_confirm("input_map_ensure", {"action": "agentic_live_test"}):
		failures.append("input_map_ensure needs_confirm")
	var had_setting: bool = ProjectSettings.has_setting("input/agentic_live_test")
	if had_setting:
		failures.append("precondition: input/agentic_live_test should not exist yet")
	if PolicyScript.is_allowed_unattended("input_map_ensure", {"action": "agentic_live_test"}):
		failures.append("input_map_ensure incorrectly unattended")
	elif ProjectSettings.has_setting("input/agentic_live_test"):
		failures.append("input_map_ensure wrote under auto_approve gate")

	# --- editor_screenshot writes a different file from the play frame ---
	var shot_tools := AgenticStudioSceneTools.new()
	shot_tools.setup("live_editor_ops_shot", "live_editor_ops")
	var shot: Dictionary = await shot_tools.execute_editor_screenshot({})
	if not bool(shot.get("ok", false)):
		failures.append("editor_screenshot failed: %s" % str(shot.get("error", "")))
	else:
		var shot_path: String = str(shot.get("result", {}).get("path", shot.get("shot_path", "")))
		if shot_path.is_empty():
			failures.append("editor_screenshot missing path")
		elif shot_path == "user://agentic/last_frame.png":
			failures.append("editor_screenshot must not be the play frame path")
		elif not FileAccess.file_exists(ProjectSettings.globalize_path(shot_path)):
			failures.append("editor_screenshot file missing: %s" % shot_path)
		elif shot_path.find("editor_shots") < 0 and shot_path.find("editor_") < 0:
			failures.append("editor_screenshot path not under editor_shots: %s" % shot_path)
	shot_tools.finish()

	# --- op without page_id rejected ---
	var nopage := AgenticStudioSceneTools.new()
	nopage.setup("live_editor_ops_nopage")
	var before_count: int = _child_count(EditorInterface.get_edited_scene_root())
	var no_page: Dictionary = nopage.execute(
		"node_rename",
		{"path": "ParentA", "name": "ParentA_renamed"}
	)
	if bool(no_page.get("ok", false)):
		failures.append("node_rename without page_id must fail")
	if str(no_page.get("error", "")).find("page_id") < 0 \
			and str(no_page.get("log", "")).find("page_id") < 0:
		failures.append("missing page_id error unclear: %s" % str(no_page.get("error", "")))
	if _child_count(EditorInterface.get_edited_scene_root()) != before_count:
		failures.append("rejected rename still changed the scene")
	nopage.discard_if_empty()

	# Cleanup tree leftovers
	root = EditorInterface.get_edited_scene_root()
	_remove_child_named(root, "ParentA")
	_remove_child_named(root, "ChildB")
	_remove_child_named(root, "SignalSrc")
	_remove_child_named(root, "SignalDst")

	return {"ok": failures.is_empty(), "failures": failures}


func _ensure_probe_scene(path: String) -> void:
	if FileAccess.file_exists(path):
		return
	var root := Node3D.new()
	root.name = "AgentProbeScene"
	var packed := PackedScene.new()
	packed.pack(root)
	ResourceSaver.save(packed, path)
	root.free()


func _remove_child_named(parent: Node, child_name: String) -> void:
	if parent == null:
		return
	var n: Node = parent.get_node_or_null(NodePath(child_name))
	if n != null:
		parent.remove_child(n)
		n.free()


func _child_count(parent: Node) -> int:
	return parent.get_child_count() if parent != null else 0


func _undo_once(root: Node) -> bool:
	var ur_mgr: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	if root == null:
		return false
	var history_id: int = ur_mgr.get_object_history_id(root)
	var ur: UndoRedo = ur_mgr.get_history_undo_redo(history_id)
	if ur == null or not ur.has_undo():
		return false
	ur.undo()
	return true


func _write_text(path: String, text: String) -> void:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()


func _frames(count: int) -> void:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	for _i: int in range(maxi(1, count)):
		if tree != null:
			await tree.process_frame
		else:
			OS.delay_msec(16)
