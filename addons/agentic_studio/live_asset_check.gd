class_name AgenticStudioLiveAssetCheck
extends RefCounted
## Live Auto-approve create_asset for Goblin Shaman stand-in mesh.


func run() -> Dictionary:
	var failures: PackedStringArray = PackedStringArray()
	AgenticStudioConfig.ensure_dirs()
	AgenticStudioPageStore.ensure_dirs()
	AgenticStudioAssetSupport.ensure_inbox_dir()

	var selected_id: String = AgenticStudioConfig.get_selected_model_id()
	var model: Dictionary = AgenticStudioConfig.get_model(selected_id)
	if model.is_empty():
		return {"ok": false, "failures": PackedStringArray(["no selected model"])}
	if str(model.get("base_url", "")).strip_edges() != "http://192.168.68.55:11434/v1":
		failures.append("unexpected base_url")
	if str(model.get("model_name", "")).strip_edges() != "qwen2.5-coder:7b":
		failures.append("unexpected model_name")
	if not failures.is_empty():
		return {"ok": false, "failures": failures}

	# Ensure Goblin Shaman character page exists.
	var char_path: String = AgenticStudioPageStore.path_for_title(
		AgenticStudioPage.KIND_CHARACTER,
		"Goblin Shaman"
	)
	var char_page: Resource = AgenticStudioPageStore.load_page(char_path)
	if char_page == null:
		char_page = AgenticStudioPage.new()
		char_page.set("title", "Goblin Shaman")
		char_page.set("kind", AgenticStudioPage.KIND_CHARACTER)
		char_page.set(
			"notes",
			"The Goblin Shaman carries a bone staff and speaks in swamp-smoke riddles."
		)
		char_page.set("tags", PackedStringArray(["goblin", "shaman"]))
		char_page.set("image_paths", PackedStringArray())
		char_page.set("links", PackedStringArray())
		var saved: Dictionary = AgenticStudioPageStore.save_page(char_page, char_path)
		if not bool(saved.get("ok", false)):
			return {
				"ok": false,
				"failures": PackedStringArray(["could not create Goblin Shaman page"]),
			}
		char_path = str(saved.get("path", char_path))

	# Open / create a probe scene for instancing.
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		var scene_root := Node3D.new()
		scene_root.name = "AssetProbeRoot"
		var packed := PackedScene.new()
		packed.pack(scene_root)
		var scene_path: String = "res://agent_probe_scene.tscn"
		ResourceSaver.save(packed, scene_path)
		EditorInterface.open_scene_from_path(scene_path)
		await _editor_tree().process_frame
		await _editor_tree().process_frame
		root = EditorInterface.get_edited_scene_root()
	if root == null:
		return {"ok": false, "failures": PackedStringArray(["no edited scene root"])}

	# Remove leftover children from prior runs.
	_remove_child_matching(root, "_StandIn")
	_remove_child_named(root, "AgentProbe")
	_remove_child_named(root, "BrokenProbe")
	_remove_child_named(root, "CollisionMesh")
	_remove_child_named(root, "Shape")
	# Clear prior asset links on Goblin Shaman so this check is decisive.
	char_page = AgenticStudioPageStore.load_page(char_path)
	if char_page != null:
		char_page.set("links", PackedStringArray())
		AgenticStudioPageStore.save_page(char_page, char_path)

	var job := AgenticStudioJob.new("live_asset_create")
	job.prompt = (
		"create an asset for the Goblin Shaman page from the stand-in mesh. "
		+ "Call create_asset with character Goblin Shaman and page_id goblin_shaman."
	)
	job.model_id = selected_id
	job.mode = AgenticStudioJob.MODE_AUTO_APPROVE
	job.stage = AgenticStudioJob.STAGE_RUNNING
	job.append_log("Job created.")
	job.save()

	var tools := AgenticStudioSceneTools.new()
	tools.setup(job.id)
	var always_yes := func(_n: String, _a: Dictionary) -> bool: return true
	await AgenticStudioExecuteRunner.run_sync(job, model, false, tools, always_yes)

	var reloaded: AgenticStudioJob = AgenticStudioJob.load_from_path(job.file_path())
	if reloaded == null or reloaded.stage != AgenticStudioJob.STAGE_DONE:
		failures.append(
			"asset job stage=%s want=done"
			% (reloaded.stage if reloaded else "missing")
		)
	var log_text: String = "\n".join(
		reloaded.log_lines if reloaded else PackedStringArray()
	)
	if log_text.find("play_scene ok") < 0 and log_text.find("play_scene") < 0:
		failures.append("asset job log missing play_scene line")
	if log_text.find("play_scene failed") >= 0:
		failures.append("play_scene was not clean")
	if log_text.find("create_asset") < 0 and log_text.find("instanced") < 0:
		failures.append("create_asset did not run / instance")

	root = EditorInterface.get_edited_scene_root()
	var instance: Node = _find_stand_in(root)
	if instance == null:
		failures.append("stand-in instance missing under scene root")

	# Asset page linked from Goblin Shaman
	char_page = AgenticStudioPageStore.load_page(char_path)
	var links: PackedStringArray = PackedStringArray(
		char_page.get("links") if char_page else PackedStringArray()
	)
	var asset_linked: bool = false
	var asset_path: String = ""
	for link: String in links:
		if link.begins_with("res://studio/assets/"):
			asset_linked = true
			asset_path = link
			break
	if not asset_linked:
		failures.append("Goblin Shaman page has no link to an asset page")
	elif AgenticStudioPageStore.load_page(asset_path) == null:
		failures.append("linked asset page missing on disk: %s" % asset_path)

	# One undo removes the instance; asset page may remain.
	if instance != null:
		if not _undo_once(root):
			failures.append("undo API failed")
		await _editor_tree().process_frame
		await _editor_tree().process_frame
		root = EditorInterface.get_edited_scene_root()
		if _find_stand_in(root) != null:
			failures.append("stand-in instance still present after one undo")
		if not asset_path.is_empty() and AgenticStudioPageStore.load_page(asset_path) != null:
			pass  # expected: page may remain
		elif not asset_path.is_empty():
			failures.append("asset page disappeared unexpectedly (may remain)")

	# Plan must not import / create_asset
	var before_count: int = _child_count(EditorInterface.get_edited_scene_root())
	var plan_job := AgenticStudioJob.new("live_asset_plan_no_import")
	plan_job.prompt = "create an asset for the Goblin Shaman page from the stand-in mesh"
	plan_job.model_id = selected_id
	plan_job.mode = AgenticStudioJob.MODE_PLAN
	plan_job.stage = AgenticStudioJob.STAGE_RUNNING
	plan_job.append_log("Job created.")
	plan_job.save()
	var plan_tools := AgenticStudioSceneTools.new()
	plan_tools.setup(plan_job.id)
	await AgenticStudioExecuteRunner.run_plan_sync(plan_job, model, plan_tools)
	var after_count: int = _child_count(EditorInterface.get_edited_scene_root())
	if after_count != before_count:
		failures.append("Plan imported / edited the scene")
	var plan_log: String = "\n".join(plan_job.log_lines)
	if plan_log.find("create_asset copied") >= 0 or plan_log.find("create_asset instanced") >= 0:
		failures.append("Plan must not run create_asset")
	if plan_log.find("Plan blocked tool: create_asset") >= 0:
		pass  # fine if model tried and was blocked

	return {
		"ok": failures.is_empty(),
		"failures": failures,
		"asset_job": job.id,
		"plan_job": plan_job.id,
		"asset_path": asset_path,
	}


func _editor_tree() -> SceneTree:
	return EditorInterface.get_base_control().get_tree()


func _child_count(root: Node) -> int:
	return root.get_child_count() if root != null else -1


func _remove_child_named(root: Node, child_name: String) -> void:
	if root == null:
		return
	var node: Node = root.get_node_or_null(NodePath(child_name))
	if node != null:
		root.remove_child(node)
		node.free()


func _remove_child_matching(root: Node, suffix: String) -> void:
	if root == null:
		return
	var to_free: Array[Node] = []
	for i: int in range(root.get_child_count()):
		var c: Node = root.get_child(i)
		if str(c.name).ends_with(suffix) or str(c.name).find("StandIn") >= 0:
			to_free.append(c)
	for c2: Node in to_free:
		root.remove_child(c2)
		c2.free()


func _find_stand_in(root: Node) -> Node:
	if root == null:
		return null
	for i: int in range(root.get_child_count()):
		var c: Node = root.get_child(i)
		var n: String = str(c.name)
		if n.find("StandIn") >= 0 or n.ends_with("_StandIn"):
			return c
	return null


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
