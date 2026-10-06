class_name AgenticStudioLiveDockCheck
extends RefCounted
## Live layout check: growing prompt, session close, page remove.


func run() -> Dictionary:
	var failures: PackedStringArray = PackedStringArray()
	var dock: Node = _find_dock()
	if dock == null:
		return {"ok": false, "failures": PackedStringArray(["AgenticStudio dock not found"])}

	var tab_bar: TabBar = dock.get("_tab_bar") as TabBar
	var plus: Button = dock.get("_plus_btn") as Button
	var studio_panel: Control = dock.get("_studio_panel") as Control
	var sessions: Array = dock.get("_sessions") as Array
	if tab_bar == null:
		failures.append("missing TabBar")
	if plus == null or plus.text != "+":
		failures.append("missing + control")
	if studio_panel == null:
		failures.append("missing Studio panel")
	if tab_bar != null and tab_bar.tab_count < 2:
		failures.append("expected Studio + at least one session tab")
	if tab_bar != null and tab_bar.get_tab_title(0) != "Studio":
		failures.append("first tab must be Studio")

	if dock.get("_pages_list") == null:
		failures.append("Studio missing pages list")
	if dock.get("_studio_prompt") == null or dock.get("_studio_log") == null:
		failures.append("Studio missing prompt or log")
	if dock.get("_studio_split") == null:
		failures.append("Studio missing VSplit")

	# Prompt expands via PromptHost; toolbar does not.
	var studio_prompt: TextEdit = dock.get("_studio_prompt") as TextEdit
	if studio_prompt == null:
		failures.append("studio prompt missing")
	elif studio_prompt.scroll_fit_content_height:
		failures.append("studio prompt must scroll inside, not fit content height")
	var studio_prompt_host: Control = null
	if studio_prompt != null:
		studio_prompt_host = studio_prompt.get_parent() as Control
	if studio_prompt_host == null or studio_prompt_host.size_flags_vertical != Control.SIZE_EXPAND_FILL:
		failures.append("studio PromptHost must SIZE_EXPAND_FILL so the split grows it")

	if sessions.is_empty():
		failures.append("no session entries")
	else:
		var entry: Dictionary = sessions[0]
		var panel: Node = entry.get("panel")
		if not (panel is VSplitContainer):
			failures.append("session panel must be VSplitContainer")
		var log_view: TextEdit = entry.get("log") as TextEdit
		if log_view == null or log_view.editable:
			failures.append("session log must be read-only TextEdit")
		var prompt: TextEdit = entry.get("prompt") as TextEdit
		if prompt == null:
			failures.append("session prompt missing")
		else:
			var ph: Control = prompt.get_parent() as Control
			if ph == null or ph.size_flags_vertical != Control.SIZE_EXPAND_FILL:
				failures.append("session PromptHost must SIZE_EXPAND_FILL")
		var toolbar: Control = null
		if panel != null:
			toolbar = panel.find_child("ComposerToolbar", true, false) as Control
		if toolbar == null:
			failures.append("session composer toolbar missing")
		elif toolbar.size_flags_vertical == Control.SIZE_EXPAND_FILL:
			failures.append("toolbar must not expand with the split")

	# Dragging the split should grow prompt height, not toolbar.
	var studio_split: VSplitContainer = dock.get("_studio_split") as VSplitContainer
	if studio_split != null and studio_prompt != null:
		var toolbar: Control = studio_split.find_child("ComposerToolbar", true, false) as Control
		# Ensure Studio is visible and laid out at a usable height.
		tab_bar.current_tab = 0
		await _frames(2)
		# Give the split a tall floor and leave most height to the composer pane.
		studio_split.custom_minimum_size = Vector2(0, 420)
		studio_split.split_offset = 48
		await _frames(3)
		var composer_root: Control = studio_split.get_child(1) as Control
		# Re-resolve PromptHost after any prior refresh.
		studio_prompt = dock.get("_studio_prompt") as TextEdit
		studio_prompt_host = studio_prompt.get_parent() as Control if studio_prompt else null
		var measure: Control = studio_prompt_host if studio_prompt_host != null else studio_prompt
		# Simulate a taller composer pane (user drag grows this pane; prompt must absorb it).
		var small_min := Vector2(0, 110)
		var large_min := Vector2(0, 260)
		composer_root.custom_minimum_size = small_min
		await _frames(4)
		var small_prompt_h: float = measure.size.y
		var small_toolbar_h: float = toolbar.size.y if toolbar else -1.0
		composer_root.custom_minimum_size = large_min
		await _frames(4)
		var large_prompt_h: float = measure.size.y
		var large_toolbar_h: float = toolbar.size.y if toolbar else -1.0
		if large_prompt_h <= small_prompt_h + 8.0:
			failures.append(
				"taller composer did not grow prompt (small=%.1f large=%.1f composer_min=%s split_h=%.1f)"
				% [small_prompt_h, large_prompt_h, str(large_min), studio_split.size.y]
			)
		if toolbar != null and absf(large_toolbar_h - small_toolbar_h) > 2.0:
			failures.append(
				"toolbar height changed when composer grew (small=%.1f large=%.1f)"
				% [small_toolbar_h, large_toolbar_h]
			)
		composer_root.custom_minimum_size = Vector2(0, 0)
		studio_split.custom_minimum_size = Vector2(0, 0)

	# Studio has no close control; session tabs do.
	if tab_bar != null:
		if tab_bar.get_tab_button_icon(0) != null:
			failures.append("Studio tab must have no close control")
		if tab_bar.tab_count > 1 and tab_bar.get_tab_button_icon(1) == null:
			failures.append("session tabs must show a close control")

	# Transcript: two prompts on one tab survive refresh; tool line toggles; close keeps log.
	if plus != null:
		plus.pressed.emit()
		await _frames(2)
	var sessions_tx: Array = dock.get("_sessions") as Array
	if sessions_tx.is_empty():
		failures.append("no session for transcript check")
	else:
		var entry_tx: Dictionary = sessions_tx[sessions_tx.size() - 1]
		var tr: RefCounted = entry_tx.get("transcript") as RefCounted
		var log_view: TextEdit = entry_tx.get("log") as TextEdit
		if tr == null or log_view == null:
			failures.append("session missing transcript or log")
		else:
			var sid: String = str(tr.session_id)
			var job_a := AgenticStudioJob.new("live_tx_a")
			job_a.prompt = "transcript prompt one"
			job_a.mode = AgenticStudioJob.MODE_PLAN
			job_a.stage = AgenticStudioJob.STAGE_PLANNED
			job_a.append_log("Job created.")
			job_a.append_log("Plan text for prompt one.")
			var ia: int = tr.begin_turn(job_a.prompt, job_a.mode, "m", job_a.id)
			tr.sync_turn_from_job(ia, job_a)

			var job_b := AgenticStudioJob.new("live_tx_b")
			job_b.prompt = "transcript prompt two"
			job_b.mode = AgenticStudioJob.MODE_AUTO_APPROVE
			job_b.stage = AgenticStudioJob.STAGE_DONE
			job_b.append_log("Job created.")
			job_b.append_log("play_scene ok (no debugger errors)")
			job_b.append_log("Assistant wrap-up for prompt two.")
			var ib: int = tr.begin_turn(job_b.prompt, job_b.mode, "m", job_b.id)
			tr.sync_turn_from_job(ib, job_b)
			tr.title = "Tx Live"
			tr.save()
			entry_tx["title"] = "Tx Live"
			entry_tx["transcript"] = tr
			sessions_tx[sessions_tx.size() - 1] = entry_tx
			dock.set("_sessions", sessions_tx)
			dock.call("_persist_open_session_ids")
			dock.call("_apply_transcript_to_view", log_view, tr)
			await _frames(1)

			if log_view.text.find("transcript prompt one") < 0 \
					or log_view.text.find("transcript prompt two") < 0:
				failures.append("log view missing both prompts before reload")
			if log_view.text.find("Running play_scene") < 0:
				failures.append("compacted tool line missing before toggle")

			# Expand compacted play_scene via toggle_at_line.
			var toggled: bool = false
			for li: int in range(tr._line_map.size()):
				var meta: Variant = tr._line_map[li]
				if typeof(meta) != TYPE_DICTIONARY:
					continue
				var bi: int = int((meta as Dictionary).get("block", -1))
				var ti: int = int((meta as Dictionary).get("turn", -1))
				if ti != ib:
					continue
				var blocks: Array = (tr.turns[ti] as Dictionary).get("blocks", [])
				if bi < 0 or bi >= blocks.size():
					continue
				if str((blocks[bi] as Dictionary).get("kind", "")) != "tool":
					continue
				if tr.toggle_at_line(li):
					toggled = true
					break
			if not toggled:
				failures.append("tool line did not toggle expand")
			else:
				tr.save()
				dock.call("_apply_transcript_to_view", log_view, tr)
				await _frames(1)
				if log_view.text.find("play_scene ok") < 0:
					failures.append("expanded tool line missing detail")
				# Collapse again
				for li2: int in range(tr._line_map.size()):
					var meta2: Variant = tr._line_map[li2]
					if typeof(meta2) != TYPE_DICTIONARY:
						continue
					if int((meta2 as Dictionary).get("turn", -1)) != ib:
						continue
					if tr.toggle_at_line(li2):
						break
				tr.save()
				dock.call("_apply_transcript_to_view", log_view, tr)
				await _frames(1)
				if log_view.text.find("Running play_scene") < 0:
					failures.append("re-collapsed tool line missing summary")

			# Restart-style reload keeps both prompts on the open tab.
			dock.call("refresh_all")
			await _frames(2)
			var after_reload: Array = dock.get("_sessions") as Array
			var found_tx: bool = false
			for e_rl: Variant in after_reload:
				var tr_rl: RefCounted = (e_rl as Dictionary).get("transcript") as RefCounted
				if tr_rl == null or str(tr_rl.session_id) != sid:
					continue
				found_tx = true
				var text_rl: String = str(tr_rl.render_text())
				if text_rl.find("transcript prompt one") < 0 \
						or text_rl.find("transcript prompt two") < 0:
					failures.append("after reload, both prompts must remain")
				break
			if not found_tx:
				failures.append("transcript session missing after reload")

			# Close tab: log file remains; tab not restored.
			var log_abs: String = ProjectSettings.globalize_path(
				AgenticStudioSessionTranscript.log_path_for(sid)
			)
			var close_i: int = -1
			var sessions_close: Array = dock.get("_sessions") as Array
			for i_c: int in range(sessions_close.size()):
				var tr_c: RefCounted = (sessions_close[i_c] as Dictionary).get("transcript") as RefCounted
				if tr_c != null and str(tr_c.session_id) == sid:
					close_i = i_c + 1
					break
			if close_i < 1:
				failures.append("could not find transcript tab to close")
			else:
				dock.call("_close_session_tab", close_i)
				await _frames(2)
				if not FileAccess.file_exists(log_abs):
					failures.append("closing tab must leave the log file on disk")
				dock.call("refresh_all")
				await _frames(2)
				for e_gone: Variant in dock.get("_sessions") as Array:
					var tr_gone: RefCounted = (e_gone as Dictionary).get("transcript") as RefCounted
					if tr_gone != null and str(tr_gone.session_id) == sid:
						failures.append("closed transcript tab returned after reload")
						break
			# Cleanup log file after assertions so the userdata stays tidy.
			if FileAccess.file_exists(log_abs):
				DirAccess.remove_absolute(log_abs)

	# + adds a session without sending.
	var before_tabs: int = tab_bar.tab_count if tab_bar else 0
	var before_sessions: int = (dock.get("_sessions") as Array).size()
	if plus != null:
		plus.pressed.emit()
		await _frames(2)
	var after_sessions: Array = dock.get("_sessions") as Array
	if tab_bar != null and tab_bar.tab_count != before_tabs + 1:
		failures.append(
			"+ did not add a session tab (before=%d after=%d)"
			% [before_tabs, tab_bar.tab_count if tab_bar else -1]
		)
	if after_sessions.size() != before_sessions + 1:
		failures.append(
			"+ did not append a session entry (before=%d after=%d)"
			% [before_sessions, after_sessions.size()]
		)

	# Close the new blank session tab; job file absent is fine.
	var close_tab: int = tab_bar.tab_count - 1 if tab_bar else -1
	var tabs_before_close: int = tab_bar.tab_count if tab_bar else 0
	if close_tab > 0:
		dock.call("_close_session_tab", close_tab)
		await _frames(2)
		if tab_bar.tab_count != tabs_before_close - 1 and tab_bar.tab_count < 2:
			failures.append("closing blank session tab failed")
		if tab_bar.get_tab_title(0) != "Studio":
			failures.append("Studio tab missing after blank session close")
		if tab_bar.tab_count < 2:
			failures.append("expected a fresh Session after closing last/extra session")

	# Closing Studio is a no-op.
	var studio_tabs: int = tab_bar.tab_count
	dock.call("_on_tab_close_pressed", 0)
	await _frames(1)
	if tab_bar.tab_count != studio_tabs:
		failures.append("Studio close must be ignored")

	# Page remove: create temp page, remove, confirm gone after refresh.
	var temp_path: String = AgenticStudioPageStore.path_for_title(
		AgenticStudioPage.KIND_CHARACTER,
		"Dock Remove Probe"
	)
	var page: Resource = AgenticStudioPage.new()
	page.set("title", "Dock Remove Probe")
	page.set("kind", AgenticStudioPage.KIND_CHARACTER)
	page.set("notes", "temporary")
	page.set("tags", PackedStringArray())
	page.set("image_paths", PackedStringArray())
	page.set("links", PackedStringArray())
	var saved: Dictionary = AgenticStudioPageStore.save_page(page, temp_path)
	if not bool(saved.get("ok", false)):
		failures.append("could not create temp page for remove check")
	else:
		temp_path = str(saved.get("path", temp_path))
		dock.call("_refresh_pages_list")
		await _frames(1)
		var deleted: Dictionary = AgenticStudioPageStore.delete_page(temp_path)
		if not bool(deleted.get("ok", false)):
			failures.append("delete_page failed in live check: %s" % str(deleted.get("error", "")))
		dock.call("_refresh_pages_list")
		await _frames(1)
		var abs_temp: String = ProjectSettings.globalize_path(temp_path)
		if FileAccess.file_exists(abs_temp):
			failures.append("removed page file still on disk")
		# Relist must not resurrect it.
		var still_listed: bool = false
		for item: Variant in AgenticStudioPageStore.list_pages():
			if typeof(item) == TYPE_DICTIONARY and str((item as Dictionary).get("path", "")) == temp_path:
				still_listed = true
				break
		if still_listed:
			failures.append("removed page still listed after reload of page store")
		if tab_bar.get_tab_title(0) != "Studio":
			failures.append("Studio disappeared after page remove")

	# Switching to Studio shows studio panel.
	if tab_bar != null:
		tab_bar.current_tab = 0
		await _frames(1)
		var host: Node = dock.get("_body_host") as Node
		if host != null and host.get_child_count() > 0:
			if host.get_child(0) != studio_panel:
				failures.append("selecting Studio should show studio panel")

	return {"ok": failures.is_empty(), "failures": failures}


func _frames(n: int) -> void:
	var tree: SceneTree = EditorInterface.get_base_control().get_tree()
	for _i: int in range(n):
		await tree.process_frame


func _find_dock() -> Node:
	var base: Node = EditorInterface.get_base_control()
	return _find_by_name(base, "AgenticStudio")


func _find_by_name(node: Node, want: String) -> Node:
	if node == null:
		return null
	if str(node.name) == want and node.get_script() != null:
		if node.get("_tab_bar") != null:
			return node
	for i: int in range(node.get_child_count()):
		var found: Node = _find_by_name(node.get_child(i), want)
		if found != null:
			return found
	return null
