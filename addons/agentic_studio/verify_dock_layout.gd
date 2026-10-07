extends SceneTree
## Headless: narrow-dock layout — TabBar scroll, two-row composer, body scroll.
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
	var body_scroll: ScrollContainer = dock._body_scroll
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
	if body_scroll == null:
		failures.append("missing BodyScroll")

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
				if t == "Settings":
					has_settings = true
		if not has_send:
			failures.append("Send missing from actions row")
		if not has_settings:
			failures.append("Settings missing from actions row")

	if dock._studio_planner != null:
		if not dock._studio_planner.clip_text:
			failures.append("planner clip_text")
		if dock._studio_planner.fit_to_longest_item:
			failures.append("planner fit_to_longest_item should be false")

	var pages_panel: Control = dock._studio_panel.get_child(0) as Control
	if pages_panel != null and pages_panel.custom_minimum_size.y >= 140.0:
		failures.append("pages panel still has tall custom_minimum_size")
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

	dock.size = Vector2(280, 600)
	await process_frame
	await process_frame
	if plus != null and plus.size.x < 1.0:
		failures.append("+ collapsed to zero at 280px")
	if dock._studio_send != null and dock._studio_send.size.x < 1.0:
		failures.append("Send collapsed to zero at 280px")
	if dock._studio_settings != null and dock._studio_settings.size.x < 1.0:
		failures.append("Settings collapsed to zero at 280px")
	if dock._studio_planner != null and dock._studio_planner.size.x < 1.0:
		failures.append("Planner picker collapsed to zero at 280px")
	if dock._studio_coder != null and dock._studio_coder.size.x < 1.0:
		failures.append("Coder picker collapsed to zero at 280px")
	if tab_bar != null and tab_bar.size.x < 1.0:
		failures.append("TabBar collapsed to zero at 280px")

	dock.size = Vector2(280, 220)
	await process_frame
	await process_frame
	if dock._studio_send == null or not is_instance_valid(dock._studio_send):
		failures.append("Send lost when short")

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
