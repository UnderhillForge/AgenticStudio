extends SceneTree
## Headless: pinned action row, VSplit log|prompt only, Settings/Send never clip.
## Run: godot --headless --path . --script res://addons/agentic_studio/verify_dock_layout.gd

const DockScript = preload("res://addons/agentic_studio/dock.gd")


func _initialize() -> void:
	var failures: PackedStringArray = PackedStringArray()
	var dock = DockScript.new()
	get_root().add_child(dock)
	await process_frame
	await process_frame

	var tab_bar: TabBar = dock._tab_bar
	var plus: Button = dock._plus_btn
	var body_host: MarginContainer = dock._body_host
	if tab_bar == null:
		failures.append("missing TabBar")
	else:
		if not tab_bar.scrolling_enabled:
			failures.append("TabBar.scrolling_enabled should be true")
		if tab_bar.clip_tabs:
			failures.append("TabBar.clip_tabs should be false")
		if tab_bar.tab_count < 1 or tab_bar.get_tab_title(0) != "Studio":
			failures.append("Studio tab should be first")
	if plus == null:
		failures.append("missing + button")
	else:
		if plus.get_parent() == tab_bar:
			failures.append("+ must be outside TabBar")
		if plus.custom_minimum_size.x < 28.0:
			failures.append("+ min width should be >= 28")
		if plus.size_flags_horizontal == Control.SIZE_EXPAND_FILL:
			failures.append("+ must not expand-fill")
	if body_host == null:
		failures.append("missing BodyHost")
	elif body_host.size_flags_vertical != Control.SIZE_EXPAND_FILL:
		failures.append("BodyHost must SIZE_EXPAND_FILL so panels fill the dock")
	# Action row must not live inside a ScrollContainer.
	if dock._studio_send != null:
		var walk: Node = dock._studio_send
		while walk != null and walk != dock:
			if walk is ScrollContainer:
				failures.append("ComposerActions must not be inside a ScrollContainer")
				break
			walk = walk.get_parent()

	var pickers: Node = dock._studio_planner.get_parent() if dock._studio_planner else null
	var actions: Node = dock._studio_send.get_parent() if dock._studio_send else null
	if pickers == null or actions == null:
		failures.append("missing composer rows")
	elif pickers == actions:
		failures.append("Settings/Send must not share HBox with Planner/Coder pickers")
	else:
		if str(pickers.name) != "ComposerPickers":
			failures.append("pickers row name")
		if str(actions.name) != "ComposerActions":
			failures.append("actions row name")
		if (actions as Control).custom_minimum_size.x < 160.0:
			failures.append("actions row min width < 160")
		var has_send := false
		var has_settings := false
		for c2: Node in actions.get_children():
			if c2 is Button:
				var t: String = (c2 as Button).text
				if t == "Send":
					has_send = true
					var sb: Button = c2 as Button
					if sb.clip_text:
						failures.append("Send must not clip_text")
					if sb.custom_minimum_size.x < 52.0:
						failures.append("Send min width too small for full label")
				if t == "Settings":
					has_settings = true
					var setb: Button = c2 as Button
					if setb.clip_text:
						failures.append("Settings must not clip_text")
					if setb.custom_minimum_size.x < 84.0:
						failures.append("Settings min width too small for full label")
		if not has_send:
			failures.append("Send missing from actions row")
		if not has_settings:
			failures.append("Settings missing from actions row")

	if dock._studio_planner != null:
		if not dock._studio_planner.clip_text:
			failures.append("planner clip_text")
		if dock._studio_planner.fit_to_longest_item:
			failures.append("planner fit_to_longest_item should be false")

	# Studio: VSplit children are log + PromptHost only (chrome is sibling under panel).
	var studio_split: VSplitContainer = dock._studio_split
	if studio_split == null:
		failures.append("missing studio VSplit")
	elif studio_split.get_child_count() != 2:
		failures.append("studio VSplit must have exactly log + PromptHost")
	else:
		var c0: Node = studio_split.get_child(0)
		var c1: Node = studio_split.get_child(1)
		if not (c0 is TextEdit):
			failures.append("studio VSplit first child must be log TextEdit")
		if c1 == null or str(c1.name) != "PromptHost":
			failures.append("studio VSplit second child must be PromptHost")
		if studio_split.find_child("ComposerActions", true, false) != null:
			failures.append("ComposerActions must not be inside studio VSplit")
		if studio_split.find_child("ComposerPickers", true, false) != null:
			failures.append("ComposerPickers must not be inside studio VSplit")

	var studio_panel: Control = dock._studio_panel
	if studio_panel == null:
		failures.append("missing StudioPanel")
	elif studio_panel.size_flags_vertical != Control.SIZE_EXPAND_FILL:
		failures.append("StudioPanel must SIZE_EXPAND_FILL")
	else:
		var chrome: Node = studio_panel.find_child("ComposerChrome", true, false)
		if chrome == null:
			failures.append("Studio missing ComposerChrome")
		elif (chrome as Control).size_flags_vertical == Control.SIZE_EXPAND_FILL:
			failures.append("ComposerChrome must not expand-fill")

	var pages_panel: Control = studio_panel.get_child(0) as Control if studio_panel else null
	if pages_panel != null and pages_panel.custom_minimum_size.y >= 140.0:
		failures.append("pages panel still has tall custom_minimum_size")
	var pages_scroll: ScrollContainer = dock._pages_scroll
	if pages_scroll == null:
		failures.append("missing PagesScroll")
	elif pages_scroll.get_parent() != pages_panel:
		failures.append("PagesScroll must live inside the pages panel")
	var found_char := false
	var found_asset := false
	var char_parent: Node = null
	var pages_label_parent: Node = null
	for n: Node in _walk(pages_panel):
		if n is Button:
			var bt: String = (n as Button).text
			if bt == "+ Char" or bt == "+ Character":
				found_char = true
				char_parent = n.get_parent()
			if bt == "+ Asset":
				found_asset = true
		if n is Label and (n as Label).text == "Pages":
			pages_label_parent = n.get_parent()
	if not found_char or not found_asset:
		failures.append("page add buttons missing")
	elif char_parent != null and pages_label_parent != null and char_parent == pages_label_parent:
		failures.append("+ Char/+ Asset still on same row as Pages label")

	# Tall dock: action row on the bottom edge, not floating mid-panel.
	dock.size = Vector2(360, 900)
	await process_frame
	await process_frame
	if dock._studio_send != null and body_host != null:
		var send_btn: Button = dock._studio_send
		var host_bottom: float = body_host.global_position.y + body_host.size.y
		var send_bottom: float = send_btn.global_position.y + send_btn.size.y
		if absf(host_bottom - send_bottom) > 12.0:
			failures.append(
				"tall dock: Send not near body bottom (host_bottom=%.1f send_bottom=%.1f gap=%.1f)"
				% [host_bottom, send_bottom, host_bottom - send_bottom]
			)
		# Gap under action row would mean chrome floated up.
		if send_btn.global_position.y + send_btn.size.y < host_bottom - 24.0:
			failures.append("tall dock: empty gap under action row")

	# Narrow dock: pickers may shrink; Settings and Send keep full text width.
	dock.size = Vector2(280, 600)
	await process_frame
	await process_frame
	if plus != null and plus.size.x < 1.0:
		failures.append("+ collapsed to zero at 280px")
	if dock._studio_send != null:
		if dock._studio_send.size.x < 1.0:
			failures.append("Send collapsed to zero at 280px")
		# Must be wide enough to show "Send" (not "Sen").
		if dock._studio_send.size.x + 0.5 < dock._studio_send.custom_minimum_size.x:
			failures.append("Send narrower than its min size at 280px")
		if dock._studio_send.clip_text:
			failures.append("Send clip_text true at narrow width")
	if dock._studio_settings != null:
		if dock._studio_settings.size.x < 1.0:
			failures.append("Settings collapsed to zero at 280px")
		if dock._studio_settings.size.x + 0.5 < dock._studio_settings.custom_minimum_size.x:
			failures.append("Settings narrower than its min size at 280px")
		if dock._studio_settings.clip_text:
			failures.append("Settings clip_text true at narrow width")
		# Visible label must still be the full word.
		if dock._studio_settings.text != "Settings":
			failures.append("Settings text mutated")
	if dock._studio_send != null and dock._studio_send.text != "Send":
		failures.append("Send text mutated")
	if dock._studio_planner != null and dock._studio_planner.size.x < 1.0:
		failures.append("Planner picker collapsed to zero at 280px")
	if dock._studio_coder != null and dock._studio_coder.size.x < 1.0:
		failures.append("Coder picker collapsed to zero at 280px")
	if tab_bar != null and tab_bar.size.x < 1.0:
		failures.append("TabBar collapsed to zero at 280px")

	# Session panel: VBox with split + chrome; split moves log/prompt only.
	dock._on_plus_pressed()
	await process_frame
	await process_frame
	if dock._sessions.is_empty():
		failures.append("plus did not create a session")
	else:
		var entry: Dictionary = dock._sessions[dock._sessions.size() - 1]
		var session_panel: Control = entry.get("panel") as Control
		var session_split: VSplitContainer = entry.get("split") as VSplitContainer
		if session_panel == null or not (session_panel is VBoxContainer):
			failures.append("session panel must be VBoxContainer that fills the dock")
		elif session_panel.size_flags_vertical != Control.SIZE_EXPAND_FILL:
			failures.append("session panel must SIZE_EXPAND_FILL")
		if session_split == null:
			failures.append("session missing VSplit")
		elif session_split.get_child_count() != 2:
			failures.append("session VSplit must have log + PromptHost only")
		elif session_split.find_child("ComposerActions", true, false) != null:
			failures.append("ComposerActions must not be inside session VSplit")
		var sess_send: Button = entry.get("send") as Button
		var sess_settings: Button = entry.get("settings") as Button
		if sess_send == null or sess_send.text != "Send" or sess_send.clip_text:
			failures.append("session Send must read in full without clip_text")
		if sess_settings == null or sess_settings.text != "Settings" or sess_settings.clip_text:
			failures.append("session Settings must read in full without clip_text")
		# Split drag changes offset; chrome stays outside split.
		if session_split != null:
			var before: int = session_split.split_offset
			session_split.split_offset = before + 40
			await process_frame
			if session_split.split_offset == before:
				failures.append("session split_offset did not accept drag-like change")
			session_split.split_offset = before

	dock.size = Vector2(280, 220)
	await process_frame
	await process_frame
	if dock._studio_send == null or not is_instance_valid(dock._studio_send):
		failures.append("Send lost when short")

	# Plan still uses planner; Run still uses coder — selection wiring intact.
	if dock._studio_planner == null or dock._studio_coder == null or dock._studio_mode == null:
		failures.append("role/mode pickers missing after layout change")
	elif dock._studio_mode.item_count < 3:
		failures.append("mode picker missing Plan/Run/Auto-approve")

	dock.queue_free()
	if failures.is_empty():
		print("AgenticStudio verify_dock_layout: OK")
		quit(0)
		return
	print("AgenticStudio verify_dock_layout: FAILED")
	for f: String in failures:
		print("  - ", f)
	quit(1)


func _walk(n: Node) -> Array:
	var out: Array = []
	if n == null:
		return out
	out.append(n)
	for c: Node in n.get_children():
		out.append_array(_walk(c))
	return out
