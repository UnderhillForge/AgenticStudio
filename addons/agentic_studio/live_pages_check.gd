class_name AgenticStudioLivePagesCheck
extends RefCounted
## Editor live check: Goblin Shaman page + Plan quotes notes. No scene edit.


func run() -> Dictionary:
	var failures: PackedStringArray = PackedStringArray()
	AgenticStudioConfig.ensure_dirs()
	AgenticStudioPageStore.ensure_dirs()

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

	var note: String = (
		"The Goblin Shaman carries a bone staff and speaks in swamp-smoke riddles."
	)
	var page_path: String = AgenticStudioPageStore.path_for_title(
		AgenticStudioPage.KIND_CHARACTER,
		"Goblin Shaman"
	)

	# Create character page with note + one image (simulates drop).
	var page: Resource = AgenticStudioPage.new()
	page.set("title", "Goblin Shaman")
	page.set("kind", AgenticStudioPage.KIND_CHARACTER)
	page.set("notes", note)
	page.set("tags", PackedStringArray(["goblin", "shaman"]))
	page.set("image_paths", PackedStringArray())
	page.set("links", PackedStringArray())
	var saved: Dictionary = AgenticStudioPageStore.save_page(page, page_path)
	if not bool(saved.get("ok", false)):
		return {
			"ok": false,
			"failures": PackedStringArray(["save Goblin Shaman failed: %s" % saved.get("error", "")]),
		}
	page_path = str(saved.get("path", page_path))

	var image_src: String = "res://addons/agentic_studio/icon.svg"
	var copied: Dictionary = AgenticStudioPageStore.copy_image_into_page_folder(
		page_path,
		image_src
	)
	if bool(copied.get("ok", false)):
		AgenticStudioPageStore.add_image_path(page, str(copied.get("path", "")))
	else:
		AgenticStudioPageStore.add_image_path(page, image_src)
	saved = AgenticStudioPageStore.save_page(page, page_path)
	if not bool(saved.get("ok", false)):
		failures.append("save with image failed: %s" % saved.get("error", ""))

	if EditorInterface.get_resource_filesystem() != null:
		EditorInterface.get_resource_filesystem().scan()
	await _editor_tree().process_frame
	await _editor_tree().process_frame

	# Reload listing must include the page (restart simulation).
	var listed: Array = AgenticStudioPageStore.list_pages()
	var listed_ok: bool = false
	for item: Variant in listed:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = item
		if str(d.get("title", "")) == "Goblin Shaman":
			listed_ok = true
			break
	if not listed_ok:
		failures.append("Goblin Shaman missing from list_pages after save")

	var reloaded: Resource = AgenticStudioPageStore.load_page(page_path)
	if reloaded == null or str(reloaded.get("notes")) != note:
		failures.append("reloaded page notes mismatch")
	var imgs: PackedStringArray = PackedStringArray(
		reloaded.get("image_paths") if reloaded else PackedStringArray()
	)
	if imgs.is_empty():
		failures.append("reloaded page has no image paths")

	# Scene snapshot before Plan
	var root: Node = EditorInterface.get_edited_scene_root()
	var before_count: int = root.get_child_count() if root != null else -1

	var job := AgenticStudioJob.new("live_pages_goblin_plan")
	job.prompt = (
		"what is on the Goblin Shaman page? "
		+ "Call get_page with path \"Goblin Shaman\" and quote the notes in your answer."
	)
	job.model_id = selected_id
	job.mode = AgenticStudioJob.MODE_PLAN
	job.stage = AgenticStudioJob.STAGE_RUNNING
	job.append_log("Job created.")
	job.save()

	var tools := AgenticStudioSceneTools.new()
	tools.setup(job.id)
	await AgenticStudioExecuteRunner.run_plan_sync(job, model, tools)

	var reloaded_job: AgenticStudioJob = AgenticStudioJob.load_from_path(job.file_path())
	if reloaded_job == null or reloaded_job.stage != AgenticStudioJob.STAGE_PLANNED:
		failures.append(
			"plan job stage=%s want=planned"
			% (reloaded_job.stage if reloaded_job else "missing")
		)

	var log_text: String = "\n".join(
		reloaded_job.log_lines if reloaded_job else PackedStringArray()
	)
	# Quote check: note fragment or distinctive words must appear.
	if (
		log_text.find("bone staff") < 0
		and log_text.find("swamp-smoke") < 0
		and log_text.find(note) < 0
	):
		failures.append("plan log does not quote Goblin Shaman notes")
	if log_text.find("Plan blocked tool") >= 0 and log_text.find("link") >= 0:
		# Blocking link is fine; blocking get_page is not.
		pass
	if log_text.to_lower().find("add_node") >= 0 and log_text.find("add_node ok") >= 0:
		failures.append("Plan must not execute add_node")

	root = EditorInterface.get_edited_scene_root()
	var after_count: int = root.get_child_count() if root != null else -1
	if before_count != after_count:
		failures.append("Plan edited the scene")

	# Restart simulation: list_pages again after reload from disk.
	var listed_again: Array = AgenticStudioPageStore.list_pages()
	var still_there: bool = false
	for item2: Variant in listed_again:
		if typeof(item2) != TYPE_DICTIONARY:
			continue
		if str((item2 as Dictionary).get("title", "")) == "Goblin Shaman":
			still_there = true
			break
	if not still_there:
		failures.append("Goblin Shaman missing after re-list (restart simulation)")

	return {
		"ok": failures.is_empty(),
		"failures": failures,
		"page_path": page_path,
		"plan_job": job.id,
	}


func _editor_tree() -> SceneTree:
	return EditorInterface.get_base_control().get_tree()
