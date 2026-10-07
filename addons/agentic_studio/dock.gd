@tool
extends Control
## AgenticStudio dock: Studio tab + session tabs; VSplit output / composer.

const SettingsDialogScript = preload("res://addons/agentic_studio/settings_dialog.gd")
const PageScript = preload("res://addons/agentic_studio/page.gd")
const PageStoreScript = preload("res://addons/agentic_studio/page_store.gd")
const PageDropZoneScript = preload("res://addons/agentic_studio/page_drop_zone.gd")
const TranscriptScript = preload("res://addons/agentic_studio/session_transcript.gd")
const ShotSupportScript = preload("res://addons/agentic_studio/screenshot_support.gd")

const TAB_STUDIO: int = 0
const DEFAULT_SPLIT_OFFSET: int = 220

var _status_line: Label
var _tab_bar: TabBar
var _plus_btn: Button
## Body host fills the dock under the tab row. Not a ScrollContainer — action
## rows stay pinned; pages scroll inside their own panel.
var _body_host: MarginContainer
var _settings_dialog: AcceptDialog
var _http: HTTPRequest

# Studio page tools
var _pages_list: VBoxContainer
var _pages_scroll: ScrollContainer
var _page_title: LineEdit
var _page_kind: OptionButton
var _page_notes: TextEdit
var _page_tags: LineEdit
var _page_images: ItemList
var _page_links: ItemList
var _page_drop: PanelContainer
var _page_path_label: Label
var _page_paths: PackedStringArray = PackedStringArray()
var _current_page_path: String = ""
var _loading_page: bool = false
var _tab_context_menu: PopupMenu

# Studio composer / log
var _studio_panel: Control
var _studio_log: TextEdit
var _studio_prompt: TextEdit
var _studio_planner: OptionButton
var _studio_coder: OptionButton
var _studio_mode: OptionButton
var _studio_settings: Button
var _studio_send: Button
var _studio_split: VSplitContainer
var _studio_jobs: Array[AgenticStudioJob] = []
var _studio_transcript: RefCounted = null  ## AgenticStudioSessionTranscript
# Studio-tab Draw Things tool fields (not models — never in Plan/Code pickers).
var _studio_dt_cli: LineEdit
var _studio_dt_models: LineEdit
var _studio_dt_model: LineEdit
var _studio_dt_status: Label

# Session tabs: parallel to TabBar indices 1..n
# Each entry: panel, split, log, prompt, planner, coder, mode, settings, send, job, title, transcript
var _sessions: Array[Dictionary] = []
var _planner_ids: PackedStringArray = PackedStringArray()
var _coder_ids: PackedStringArray = PackedStringArray()
var _job_running: bool = false
var _suppress_picker_signal: bool = false
var _suppress_tab_signal: bool = false
var _vsplit_offset: int = DEFAULT_SPLIT_OFFSET
var _session_seq: int = 1


func _ready() -> void:
	name = "AgenticStudio"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	_http = HTTPRequest.new()
	_http.timeout = AgenticStudioModelClient.DEFAULT_TIMEOUT_SEC
	add_child(_http)
	_settings_dialog = SettingsDialogScript.new()
	_settings_dialog.settings_changed.connect(_on_settings_changed)
	add_child(_settings_dialog)
	refresh_all()


func refresh_all() -> void:
	_reload_jobs_into_tabs()
	_refresh_all_model_pickers()
	_refresh_pages_list()
	_update_status_line()
	_update_controls_enabled()


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 4)
	add_child(root)

	_status_line = Label.new()
	_status_line.text = "No model selected"
	_status_line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_line.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_status_line.clip_text = true
	root.add_child(_status_line)

	# Tab row stays outside the body scroll so Studio / + stay reachable.
	var tab_row := HBoxContainer.new()
	tab_row.name = "TabRow"
	tab_row.add_theme_constant_override("separation", 4)
	tab_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tab_row.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	tab_row.custom_minimum_size = Vector2(0, 28)
	root.add_child(tab_row)

	_tab_bar = TabBar.new()
	_tab_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tab_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_tab_bar.scrolling_enabled = true
	_tab_bar.clip_tabs = false
	_tab_bar.tab_changed.connect(_on_tab_selected)
	# Built-in close on every tab would put an X on Studio. Use never + a
	# custom tab button only on session tabs so Studio has no close control.
	_tab_bar.tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_NEVER
	_tab_bar.tab_button_pressed.connect(_on_tab_close_pressed)
	_tab_bar.tab_close_pressed.connect(_on_tab_close_pressed)  # middle-click
	_tab_bar.gui_input.connect(_on_tab_bar_gui_input)
	tab_row.add_child(_tab_bar)

	_tab_context_menu = PopupMenu.new()
	_tab_context_menu.add_item("Close", 0)
	_tab_context_menu.id_pressed.connect(_on_tab_context_id_pressed)
	add_child(_tab_context_menu)

	# Own non-shrinking slot — never collapse to zero beside a crowded TabBar.
	_plus_btn = Button.new()
	_plus_btn.text = "+"
	_plus_btn.tooltip_text = "New session"
	_plus_btn.focus_mode = Control.FOCUS_NONE
	_plus_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	_plus_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_plus_btn.custom_minimum_size = Vector2(28, 28)
	_plus_btn.pressed.connect(_on_plus_pressed)
	tab_row.add_child(_plus_btn)

	_body_host = MarginContainer.new()
	_body_host.name = "BodyHost"
	_body_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body_host.add_theme_constant_override("margin_top", 2)
	_body_host.add_theme_constant_override("margin_bottom", 4)
	root.add_child(_body_host)

	_studio_panel = _build_studio_panel()
	_body_host.add_child(_studio_panel)

	_suppress_tab_signal = true
	_tab_bar.add_tab("Studio")
	_suppress_tab_signal = false


func _build_studio_panel() -> Control:
	## Pages (own scroll) + VSplit(log|prompt) + pinned composer chrome.
	var panel := VBoxContainer.new()
	panel.name = "StudioPanel"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_constant_override("separation", 4)

	panel.add_child(_build_pages_panel())
	panel.add_child(_build_drawthings_panel())

	_studio_split = VSplitContainer.new()
	_studio_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_studio_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_studio_split.size_flags_stretch_ratio = 1.4
	_studio_split.custom_minimum_size = Vector2(0, 120)
	_studio_split.split_offset = _vsplit_offset
	_studio_split.dragged.connect(_on_split_dragged)
	panel.add_child(_studio_split)

	_studio_transcript = TranscriptScript.new(TranscriptScript.STUDIO_SESSION_ID)
	_studio_transcript.title = "Studio"
	_studio_log = _make_log_view()
	_studio_log.name = "StudioLog"
	_studio_log.custom_minimum_size = Vector2(0, 48)
	_studio_log.gui_input.connect(_on_studio_log_gui_input)
	_studio_split.add_child(_studio_log)

	var composer := _build_composer(
		"StudioPrompt",
		Callable(self, "_on_studio_send_pressed")
	)
	_studio_prompt = composer["prompt"]
	_studio_planner = composer["planner"]
	_studio_coder = composer["coder"]
	_studio_mode = composer["mode"]
	_studio_settings = composer["settings"]
	_studio_send = composer["send"]
	var prompt_host: Control = composer["prompt_host"] as Control
	_studio_split.add_child(prompt_host)
	var chrome: Control = composer["chrome"] as Control
	panel.add_child(chrome)
	return panel


func _build_drawthings_panel() -> Control:
	## Draw Things is a tool on the Studio tab — not a planner/coder model.
	var panel := VBoxContainer.new()
	panel.name = "DrawThingsPanel"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	panel.add_theme_constant_override("separation", 2)

	var title := Label.new()
	title.text = "Draw Things (image tool)"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(title)

	_studio_dt_cli = LineEdit.new()
	_studio_dt_cli.placeholder_text = "CLI path (e.g. draw-things-cli)"
	_studio_dt_cli.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_studio_dt_cli.text_submitted.connect(func(_t: String) -> void: _save_studio_drawthings())
	_studio_dt_cli.focus_exited.connect(_save_studio_drawthings)
	panel.add_child(_studio_dt_cli)

	_studio_dt_models = LineEdit.new()
	_studio_dt_models.placeholder_text = "Models directory"
	_studio_dt_models.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_studio_dt_models.text_submitted.connect(func(_t: String) -> void: _save_studio_drawthings())
	_studio_dt_models.focus_exited.connect(_save_studio_drawthings)
	panel.add_child(_studio_dt_models)

	_studio_dt_model = LineEdit.new()
	_studio_dt_model.placeholder_text = "Checkpoint filename"
	_studio_dt_model.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_studio_dt_model.text_submitted.connect(func(_t: String) -> void: _save_studio_drawthings())
	_studio_dt_model.focus_exited.connect(_save_studio_drawthings)
	panel.add_child(_studio_dt_model)

	_studio_dt_status = Label.new()
	_studio_dt_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_studio_dt_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(_studio_dt_status)

	_reload_studio_drawthings_fields()
	return panel


func _reload_studio_drawthings_fields() -> void:
	if _studio_dt_cli != null:
		_studio_dt_cli.text = AgenticStudioConfig.get_drawthings_cli()
	if _studio_dt_models != null:
		_studio_dt_models.text = AgenticStudioConfig.get_drawthings_models_dir()
	if _studio_dt_model != null:
		_studio_dt_model.text = AgenticStudioConfig.get_drawthings_model()
	_update_studio_drawthings_status()


func _update_studio_drawthings_status() -> void:
	if _studio_dt_status == null:
		return
	var msg: String = AgenticStudioConfig.drawthings_status_text()
	_studio_dt_status.text = msg if not msg.is_empty() else "Draw Things: ready"
	_studio_dt_status.visible = true


func _save_studio_drawthings() -> void:
	if _studio_dt_cli == null or _studio_dt_models == null or _studio_dt_model == null:
		return
	var keep_planner: String = AgenticStudioConfig.get_selected_planner_id()
	var keep_coder: String = AgenticStudioConfig.get_selected_coder_id()
	var saved: Dictionary = AgenticStudioConfig.save_drawthings_fields(
		_studio_dt_cli.text,
		_studio_dt_models.text,
		_studio_dt_model.text
	)
	if not bool(saved.get("ok", false)):
		if _studio_dt_status != null:
			_studio_dt_status.text = str(saved.get("error", "Draw Things save failed"))
		return
	var cli_abs: String = str(saved.get("cli", ""))
	if _studio_dt_cli.text.strip_edges() != cli_abs:
		_studio_dt_cli.text = cli_abs
	# Saving tool fields must not clear models or selected planner/coder.
	if AgenticStudioConfig.get_selected_planner_id() != keep_planner and not keep_planner.is_empty():
		AgenticStudioConfig.set_selected_planner_id(keep_planner)
	if AgenticStudioConfig.get_selected_coder_id() != keep_coder and not keep_coder.is_empty():
		AgenticStudioConfig.set_selected_coder_id(keep_coder)
	_update_studio_drawthings_status()
	_refresh_all_model_pickers()


func _build_pages_panel() -> Control:
	## Header stays fixed; page list + form scroll inside this panel only.
	var panel := VBoxContainer.new()
	panel.name = "PagesPanel"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.size_flags_stretch_ratio = 0.9
	panel.custom_minimum_size = Vector2(0, 96)
	panel.add_theme_constant_override("separation", 4)

	var pages_label := Label.new()
	pages_label.text = "Pages"
	pages_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(pages_label)

	# Second row so + Character / + Asset stay visible under ~280px width.
	var pages_actions := HBoxContainer.new()
	pages_actions.add_theme_constant_override("separation", 4)
	pages_actions.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(pages_actions)
	var new_char := Button.new()
	new_char.text = "+ Char"
	new_char.tooltip_text = "New character page"
	new_char.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	new_char.clip_text = true
	new_char.pressed.connect(_on_new_character_pressed)
	pages_actions.add_child(new_char)
	var new_asset := Button.new()
	new_asset.text = "+ Asset"
	new_asset.tooltip_text = "New asset page"
	new_asset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	new_asset.clip_text = true
	new_asset.pressed.connect(_on_new_asset_pressed)
	pages_actions.add_child(new_asset)

	_pages_scroll = ScrollContainer.new()
	_pages_scroll.name = "PagesScroll"
	_pages_scroll.custom_minimum_size = Vector2(0, 48)
	_pages_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pages_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_pages_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_pages_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	panel.add_child(_pages_scroll)

	var pages_inner := VBoxContainer.new()
	pages_inner.name = "PagesInner"
	pages_inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pages_inner.add_theme_constant_override("separation", 4)
	_pages_scroll.add_child(pages_inner)

	_pages_list = VBoxContainer.new()
	_pages_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pages_list.add_theme_constant_override("separation", 2)
	pages_inner.add_child(_pages_list)

	_page_path_label = Label.new()
	_page_path_label.text = "No page selected"
	_page_path_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	pages_inner.add_child(_page_path_label)

	var title_row := HBoxContainer.new()
	pages_inner.add_child(title_row)
	var title_l := Label.new()
	title_l.text = "Title"
	title_row.add_child(title_l)
	_page_title = LineEdit.new()
	_page_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_page_title.text_changed.connect(func(_t: String) -> void: _mark_page_dirty())
	title_row.add_child(_page_title)

	var kind_row := HBoxContainer.new()
	pages_inner.add_child(kind_row)
	var kind_l := Label.new()
	kind_l.text = "Kind"
	kind_row.add_child(kind_l)
	_page_kind = OptionButton.new()
	_page_kind.add_item("character", 0)
	_page_kind.add_item("asset", 1)
	_page_kind.disabled = true
	kind_row.add_child(_page_kind)

	var notes_l := Label.new()
	notes_l.text = "Notes"
	pages_inner.add_child(notes_l)
	_page_notes = TextEdit.new()
	_page_notes.custom_minimum_size = Vector2(0, 48)
	_page_notes.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_page_notes.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_page_notes.text_changed.connect(_mark_page_dirty)
	pages_inner.add_child(_page_notes)

	var tags_row := HBoxContainer.new()
	pages_inner.add_child(tags_row)
	var tags_l := Label.new()
	tags_l.text = "Tags"
	tags_row.add_child(tags_l)
	_page_tags = LineEdit.new()
	_page_tags.placeholder_text = "comma,separated"
	_page_tags.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_page_tags.text_changed.connect(func(_t: String) -> void: _mark_page_dirty())
	tags_row.add_child(_page_tags)

	var images_l := Label.new()
	images_l.text = "Images (drop onto character page)"
	pages_inner.add_child(images_l)
	_page_images = ItemList.new()
	_page_images.custom_minimum_size = Vector2(0, 36)
	pages_inner.add_child(_page_images)

	_page_drop = PageDropZoneScript.new()
	_page_drop.custom_minimum_size = Vector2(0, 32)
	var drop_label := Label.new()
	drop_label.text = "Drop image files here"
	drop_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_page_drop.add_child(drop_label)
	_page_drop.images_dropped.connect(_on_images_dropped)
	pages_inner.add_child(_page_drop)

	var links_l := Label.new()
	links_l.text = "Links"
	pages_inner.add_child(links_l)
	_page_links = ItemList.new()
	_page_links.custom_minimum_size = Vector2(0, 28)
	pages_inner.add_child(_page_links)

	var save_btn := Button.new()
	save_btn.text = "Save page"
	save_btn.pressed.connect(_on_save_page_pressed)
	pages_inner.add_child(save_btn)
	return panel


func _build_composer(prompt_name: String, send_cb: Callable) -> Dictionary:
	## prompt_host goes in the VSplit. chrome (pickers + actions) stays outside
	## the split and outside any ScrollContainer so it pins to the bottom.
	var prompt_host := Control.new()
	prompt_host.name = "PromptHost"
	prompt_host.custom_minimum_size = Vector2(0, 56)
	prompt_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	prompt_host.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var prompt := TextEdit.new()
	prompt.name = prompt_name
	prompt.placeholder_text = "Describe the job…"
	prompt.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	prompt.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	prompt.scroll_fit_content_height = false
	prompt.context_menu_enabled = true
	prompt_host.add_child(prompt)

	var chrome := VBoxContainer.new()
	chrome.name = "ComposerChrome"
	chrome.add_theme_constant_override("separation", 4)
	chrome.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chrome.size_flags_vertical = Control.SIZE_SHRINK_END

	# Row 1: Planner + Coder — may shrink; clipped text + full-name tooltip.
	var pickers_row := HBoxContainer.new()
	pickers_row.name = "ComposerPickers"
	pickers_row.add_theme_constant_override("separation", 4)
	pickers_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pickers_row.size_flags_vertical = Control.SIZE_SHRINK_END
	pickers_row.custom_minimum_size = Vector2(0, 28)
	chrome.add_child(pickers_row)

	var planner_label := Label.new()
	planner_label.text = "Plan"
	planner_label.tooltip_text = "Planner"
	planner_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pickers_row.add_child(planner_label)

	var planner_picker := OptionButton.new()
	_configure_role_picker(planner_picker)
	planner_picker.item_selected.connect(_on_planner_selected)
	pickers_row.add_child(planner_picker)

	var coder_label := Label.new()
	coder_label.text = "Code"
	coder_label.tooltip_text = "Coder"
	coder_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pickers_row.add_child(coder_label)

	var coder_picker := OptionButton.new()
	_configure_role_picker(coder_picker)
	coder_picker.item_selected.connect(_on_coder_selected)
	pickers_row.add_child(coder_picker)

	# Row 2: Mode / Settings / Send — Settings and Send never clip.
	var actions_row := HBoxContainer.new()
	actions_row.name = "ComposerActions"
	actions_row.add_theme_constant_override("separation", 6)
	actions_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions_row.size_flags_vertical = Control.SIZE_SHRINK_END
	actions_row.custom_minimum_size = Vector2(200, 28)
	chrome.add_child(actions_row)

	var mode_label := Label.new()
	mode_label.text = "Mode"
	mode_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	actions_row.add_child(mode_label)

	var mode_picker := OptionButton.new()
	mode_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mode_picker.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mode_picker.custom_minimum_size = Vector2(72, 0)
	mode_picker.clip_text = true
	mode_picker.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	mode_picker.add_item("Plan", 0)
	mode_picker.add_item("Run", 1)
	mode_picker.add_item("Auto-approve", 2)
	mode_picker.select(0)
	mode_picker.item_selected.connect(func(_i: int) -> void: _update_status_line())
	actions_row.add_child(mode_picker)

	var settings_btn := Button.new()
	settings_btn.text = "Settings"
	settings_btn.tooltip_text = "Settings"
	settings_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	settings_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# Wide enough for the full word under the editor theme; never clip.
	settings_btn.custom_minimum_size = Vector2(84, 0)
	settings_btn.clip_text = false
	settings_btn.pressed.connect(_on_settings_pressed)
	actions_row.add_child(settings_btn)

	var send_btn := Button.new()
	send_btn.text = "Send"
	send_btn.tooltip_text = "Send"
	send_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	send_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	send_btn.custom_minimum_size = Vector2(52, 0)
	send_btn.clip_text = false
	send_btn.pressed.connect(send_cb)
	actions_row.add_child(send_btn)

	return {
		"prompt_host": prompt_host,
		"chrome": chrome,
		"prompt": prompt,
		"toolbar": actions_row,
		"pickers_row": pickers_row,
		"actions_row": actions_row,
		"planner": planner_picker,
		"coder": coder_picker,
		"mode": mode_picker,
		"settings": settings_btn,
		"send": send_btn,
	}


func _configure_role_picker(picker: OptionButton) -> void:
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	picker.custom_minimum_size = Vector2(48, 0)
	picker.clip_text = true
	picker.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	picker.fit_to_longest_item = false


func _make_log_view() -> TextEdit:
	var log_view := TextEdit.new()
	log_view.editable = false
	log_view.context_menu_enabled = true
	log_view.scroll_fit_content_height = false
	log_view.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	log_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	log_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_view.text = "(empty log)"
	return log_view


func _make_session_panel(
	title: String,
	transcript: RefCounted = null,
	job: AgenticStudioJob = null
) -> Dictionary:
	## Outer VBox fills the dock: VSplit(log|prompt) + pinned chrome. No gap under actions.
	var panel := VBoxContainer.new()
	panel.name = "SessionPanel"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_constant_override("separation", 4)

	var split := VSplitContainer.new()
	split.name = "SessionSplit"
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.custom_minimum_size = Vector2(0, 120)
	split.split_offset = _vsplit_offset
	split.dragged.connect(_on_split_dragged)
	panel.add_child(split)

	var log_view := _make_log_view()
	log_view.name = "Log"
	log_view.custom_minimum_size = Vector2(0, 48)
	split.add_child(log_view)

	var composer := _build_composer("SessionPrompt", func() -> void: pass)
	var prompt_host: Control = composer["prompt_host"] as Control
	split.add_child(prompt_host)
	var chrome: Control = composer["chrome"] as Control
	panel.add_child(chrome)

	var tr: RefCounted = transcript
	if tr == null:
		tr = TranscriptScript.new()
		tr.title = title

	var entry: Dictionary = {
		"panel": panel,
		"split": split,
		"log": log_view,
		"prompt": composer["prompt"],
		"planner": composer["planner"],
		"coder": composer["coder"],
		"mode": composer["mode"],
		"settings": composer["settings"],
		"send": composer["send"],
		"job": job,
		"title": title,
		"transcript": tr,
	}
	var send_btn: Button = composer["send"]
	for c: Variant in send_btn.pressed.get_connections():
		send_btn.pressed.disconnect((c as Dictionary)["callable"])
	send_btn.pressed.connect(func() -> void: _on_session_send_for_panel(panel))
	log_view.gui_input.connect(
		func(event: InputEvent) -> void: _on_session_log_gui_input(event, panel)
	)

	if not str(tr.title).is_empty():
		entry["title"] = str(tr.title)
	elif job != null:
		var jt: String = job.tab_title()
		if not jt.is_empty():
			entry["title"] = jt
	_apply_transcript_to_view(log_view, tr)
	return entry


func _apply_transcript_to_view(log_view: TextEdit, transcript: RefCounted) -> void:
	if log_view == null or transcript == null:
		return
	var scroll: int = log_view.get_v_scroll_bar().value if log_view.get_v_scroll_bar() else 0
	log_view.text = transcript.render_text()
	# Keep near previous scroll; clamp after text change.
	var bar: VScrollBar = log_view.get_v_scroll_bar()
	if bar != null:
		bar.value = mini(float(scroll), bar.max_value)


func _on_studio_log_gui_input(event: InputEvent) -> void:
	_handle_transcript_click(event, _studio_log, _studio_transcript)


func _on_session_log_gui_input(event: InputEvent, panel: Control) -> void:
	for entry: Dictionary in _sessions:
		if entry.get("panel") == panel:
			_handle_transcript_click(
				event,
				entry.get("log") as TextEdit,
				entry.get("transcript") as RefCounted
			)
			return


func _handle_transcript_click(
	event: InputEvent,
	log_view: TextEdit,
	transcript: RefCounted
) -> void:
	if log_view == null or transcript == null:
		return
	if not (event is InputEventMouseButton):
		return
	var mb: InputEventMouseButton = event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var lc: Vector2i = log_view.get_line_column_at_pos(mb.position)
	var line_text: String = log_view.get_line(lc.y) if lc.y >= 0 and lc.y < log_view.get_line_count() else ""
	if line_text.find(TranscriptScript.REMOVE_MARK) >= 0:
		if transcript.remove_shot_at_line(lc.y):
			transcript.save()
			_apply_transcript_to_view(log_view, transcript)
			log_view.accept_event()
		return
	if not transcript.toggle_at_line(lc.y):
		return
	transcript.save()
	_apply_transcript_to_view(log_view, transcript)
	log_view.accept_event()


func _persist_open_session_ids() -> void:
	var ids: PackedStringArray = PackedStringArray()
	for entry: Dictionary in _sessions:
		var tr: RefCounted = entry.get("transcript") as RefCounted
		if tr != null and not str(tr.session_id).is_empty():
			ids.append(str(tr.session_id))
	AgenticStudioConfig.set_open_session_ids(ids)


func _on_split_dragged(offset: int) -> void:
	_vsplit_offset = offset
	_apply_split_offset_all()


func _apply_split_offset_all() -> void:
	if _studio_split != null:
		_studio_split.split_offset = _vsplit_offset
	for entry: Dictionary in _sessions:
		var split: VSplitContainer = entry.get("split") as VSplitContainer
		if split != null:
			split.split_offset = _vsplit_offset


func _on_tab_selected(tab: int) -> void:
	if _suppress_tab_signal:
		return
	_show_tab_content(tab)


func _session_close_icon() -> Texture2D:
	# Headless / non-editor: EditorInterface is unavailable.
	if not Engine.is_editor_hint():
		return null
	var base: Control = EditorInterface.get_base_control()
	if base != null and base.has_theme_icon("Close", "EditorIcons"):
		return base.get_theme_icon("Close", "EditorIcons")
	if has_theme_icon("close", "TabBar"):
		return get_theme_icon("close", "TabBar")
	return null


func _apply_session_close_icons() -> void:
	## Studio (tab 0) stays without a close control; sessions get a close button.
	if _tab_bar == null:
		return
	var icon: Texture2D = _session_close_icon()
	for i: int in range(_tab_bar.tab_count):
		if i <= TAB_STUDIO:
			_tab_bar.set_tab_button_icon(i, null)
		else:
			_tab_bar.set_tab_button_icon(i, icon)


func _on_tab_close_pressed(tab: int) -> void:
	## Studio (tab 0) has no close — ignore. Sessions delete the tab and job file.
	if tab <= TAB_STUDIO:
		return
	_close_session_tab(tab)


func _on_tab_bar_gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb: InputEventMouseButton = event
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_RIGHT:
		return
	var tab: int = _tab_bar.get_tab_idx_at_point(mb.position)
	if tab <= TAB_STUDIO:
		return
	_tab_context_menu.set_meta("tab", tab)
	_tab_context_menu.position = _tab_bar.get_screen_position() + mb.position
	_tab_context_menu.popup()


func _on_tab_context_id_pressed(id: int) -> void:
	if id != 0:
		return
	var tab: int = int(_tab_context_menu.get_meta("tab", -1))
	if tab <= TAB_STUDIO:
		return
	_close_session_tab(tab)


func _close_session_tab(tab: int) -> void:
	var session_i: int = tab - 1
	if session_i < 0 or session_i >= _sessions.size():
		return
	var entry: Dictionary = _sessions[session_i]
	var job: AgenticStudioJob = entry.get("job") as AgenticStudioJob
	# Remove job file only — never pages, scene nodes, or the session log.
	if job != null:
		var abs_job: String = ProjectSettings.globalize_path(job.file_path())
		if FileAccess.file_exists(abs_job):
			DirAccess.remove_absolute(abs_job)
		for i: int in range(_studio_jobs.size() - 1, -1, -1):
			if _studio_jobs[i].id == job.id:
				_studio_jobs.remove_at(i)
	# Keep transcript log on disk; delete this session's shot directory only.
	var tr: RefCounted = entry.get("transcript") as RefCounted
	if tr != null:
		tr.save()
		ShotSupportScript.delete_session_shots_dir(str(tr.session_id))

	var panel: Node = entry.get("panel") as Node
	if panel != null:
		if panel.get_parent() != null:
			panel.get_parent().remove_child(panel)
		panel.queue_free()
	_sessions.remove_at(session_i)

	_suppress_tab_signal = true
	_tab_bar.remove_tab(tab)
	_suppress_tab_signal = false

	if _sessions.is_empty():
		var title: String = "Session 1"
		_session_seq = 2
		var blank: Dictionary = _make_session_panel(title, null, null)
		_sessions.append(blank)
		_fill_role_pickers(blank["planner"] as OptionButton, blank["coder"] as OptionButton)
		(blank["transcript"] as RefCounted).save()
		_suppress_tab_signal = true
		_tab_bar.add_tab(title)
		_tab_bar.current_tab = 1
		_suppress_tab_signal = false
		_show_tab_content(1)
	else:
		var next: int = mini(tab, _tab_bar.tab_count - 1)
		if next < TAB_STUDIO:
			next = TAB_STUDIO
		_suppress_tab_signal = true
		_tab_bar.current_tab = next
		_suppress_tab_signal = false
		_show_tab_content(next)
	_persist_open_session_ids()
	_apply_session_close_icons()
	_update_controls_enabled()


func _show_tab_content(tab: int) -> void:
	for child: Node in _body_host.get_children():
		_body_host.remove_child(child)
		# Keep panels alive; only detach.
	if tab == TAB_STUDIO:
		_body_host.add_child(_studio_panel)
		return
	var session_i: int = tab - 1
	if session_i < 0 or session_i >= _sessions.size():
		return
	var panel: Control = _sessions[session_i].get("panel") as Control
	if panel != null:
		_body_host.add_child(panel)


func _on_plus_pressed() -> void:
	var mode_idx: int = 0
	var planner_idx: int = 0
	var coder_idx: int = 0
	var current: int = _tab_bar.current_tab
	if current == TAB_STUDIO:
		mode_idx = _studio_mode.selected
		planner_idx = _studio_planner.selected
		coder_idx = _studio_coder.selected
	elif current >= 1 and current - 1 < _sessions.size():
		var src: Dictionary = _sessions[current - 1]
		mode_idx = (src["mode"] as OptionButton).selected
		planner_idx = (src["planner"] as OptionButton).selected
		coder_idx = (src["coder"] as OptionButton).selected

	var title: String = "Session %d" % _session_seq
	_session_seq += 1
	var entry: Dictionary = _make_session_panel(title, null, null)
	_sessions.append(entry)
	_fill_role_pickers(entry["planner"] as OptionButton, entry["coder"] as OptionButton)
	(entry["planner"] as OptionButton).select(planner_idx)
	(entry["coder"] as OptionButton).select(coder_idx)
	(entry["mode"] as OptionButton).select(mode_idx)
	(entry["transcript"] as RefCounted).save()

	_suppress_tab_signal = true
	_tab_bar.add_tab(title)
	var new_index: int = _tab_bar.tab_count - 1
	_tab_bar.current_tab = new_index
	_suppress_tab_signal = false
	_persist_open_session_ids()
	_apply_session_close_icons()
	_show_tab_content(new_index)
	_update_controls_enabled()


func _reload_jobs_into_tabs() -> void:
	## Restores open session tabs from transcript logs (not removed logs).
	for entry: Dictionary in _sessions:
		var panel: Node = entry.get("panel") as Node
		if panel != null:
			if panel.get_parent() != null:
				panel.get_parent().remove_child(panel)
			panel.queue_free()
	_sessions.clear()
	_studio_jobs.clear()

	_suppress_tab_signal = true
	while _tab_bar.tab_count > 1:
		_tab_bar.remove_tab(_tab_bar.tab_count - 1)
	_suppress_tab_signal = false

	# Studio transcript
	var studio_loaded: RefCounted = TranscriptScript.load_from_id(TranscriptScript.STUDIO_SESSION_ID)
	if studio_loaded != null:
		_studio_transcript = studio_loaded
	elif _studio_transcript == null:
		_studio_transcript = TranscriptScript.new(TranscriptScript.STUDIO_SESSION_ID)
		_studio_transcript.title = "Studio"
	_migrate_studio_jobs_into_transcript_if_needed()

	var open_ids: PackedStringArray = AgenticStudioConfig.get_open_session_ids()
	if open_ids.is_empty():
		open_ids = _migrate_jobs_to_open_sessions()

	_session_seq = 1
	for sid: String in open_ids:
		if sid.is_empty() or sid == TranscriptScript.STUDIO_SESSION_ID:
			continue
		var tr: RefCounted = TranscriptScript.load_from_id(sid)
		if tr == null:
			tr = TranscriptScript.new(sid)
		var title: String = str(tr.title)
		if title.is_empty():
			title = "Session %d" % _session_seq
		_session_seq += 1
		var entry: Dictionary = _make_session_panel(title, tr, null)
		_sessions.append(entry)
		_fill_role_pickers(entry["planner"] as OptionButton, entry["coder"] as OptionButton)
		_suppress_tab_signal = true
		_tab_bar.add_tab(str(entry["title"]))
		_suppress_tab_signal = false

	if _sessions.is_empty():
		var title: String = "Session 1"
		_session_seq = 2
		var blank: Dictionary = _make_session_panel(title, null, null)
		_sessions.append(blank)
		_fill_role_pickers(blank["planner"] as OptionButton, blank["coder"] as OptionButton)
		(blank["transcript"] as RefCounted).save()
		_suppress_tab_signal = true
		_tab_bar.add_tab(title)
		_suppress_tab_signal = false

	_persist_open_session_ids()
	_apply_session_close_icons()
	_refresh_studio_log()
	_suppress_tab_signal = true
	_tab_bar.current_tab = TAB_STUDIO
	_suppress_tab_signal = false
	_show_tab_content(TAB_STUDIO)


func _migrate_jobs_to_open_sessions() -> PackedStringArray:
	## One-time: seed open tabs from existing session job files.
	var ids: PackedStringArray = PackedStringArray()
	var all_jobs: Array[AgenticStudioJob] = AgenticStudioJob.load_all()
	for job: AgenticStudioJob in all_jobs:
		if job.channel == AgenticStudioJob.CHANNEL_STUDIO:
			_studio_jobs.append(job)
			continue
		var tr: RefCounted = TranscriptScript.new()
		tr.title = job.tab_title()
		var ti: int = tr.begin_turn(job.prompt, job.mode, job.model_id, job.id)
		tr.sync_turn_from_job(ti, job)
		tr.save()
		ids.append(str(tr.session_id))
	return ids


func _migrate_studio_jobs_into_transcript_if_needed() -> void:
	if _studio_transcript == null:
		return
	if not _studio_transcript.turns.is_empty():
		return
	var all_jobs: Array[AgenticStudioJob] = AgenticStudioJob.load_all()
	for job: AgenticStudioJob in all_jobs:
		if job.channel != AgenticStudioJob.CHANNEL_STUDIO:
			continue
		_studio_jobs.append(job)
		var ti: int = _studio_transcript.begin_turn(job.prompt, job.mode, job.model_id, job.id)
		_studio_transcript.sync_turn_from_job(ti, job)
	if not _studio_transcript.turns.is_empty():
		_studio_transcript.save()


func _refresh_studio_log() -> void:
	if _studio_log == null:
		return
	if _studio_transcript == null:
		_studio_log.text = "(empty log)"
		return
	_apply_transcript_to_view(_studio_log, _studio_transcript)


func _on_studio_send_pressed() -> void:
	await _send_from(
		AgenticStudioJob.CHANNEL_STUDIO,
		_studio_prompt,
		_studio_planner,
		_studio_coder,
		_studio_mode,
		-1
	)


func _on_session_send_for_panel(panel: Control) -> void:
	var session_i: int = -1
	for i: int in range(_sessions.size()):
		if _sessions[i].get("panel") == panel:
			session_i = i
			break
	if session_i < 0:
		return
	await _on_session_send_pressed(session_i)


func _on_session_send_pressed(session_i: int) -> void:
	if session_i < 0 or session_i >= _sessions.size():
		return
	var entry: Dictionary = _sessions[session_i]
	await _send_from(
		AgenticStudioJob.CHANNEL_SESSION,
		entry["prompt"] as TextEdit,
		entry["planner"] as OptionButton,
		entry["coder"] as OptionButton,
		entry["mode"] as OptionButton,
		session_i
	)


func _id_from_role_picker(picker: OptionButton, ids: PackedStringArray) -> String:
	if picker == null or picker.selected <= 0:
		return ""
	var idx: int = picker.selected - 1
	if idx < 0 or idx >= ids.size():
		return ""
	return ids[idx]


func _send_from(
	channel: String,
	prompt_edit: TextEdit,
	planner_picker: OptionButton,
	coder_picker: OptionButton,
	mode_picker: OptionButton,
	session_i: int
) -> void:
	var prompt: String = prompt_edit.text.strip_edges()
	if prompt.is_empty():
		_status_line.text = "Enter a prompt before sending. · %s" % _blender_status_fragment()
		return

	# Persist picker selections into config (no role fallback).
	var planner_id: String = _id_from_role_picker(planner_picker, _planner_ids)
	var coder_id: String = _id_from_role_picker(coder_picker, _coder_ids)
	if not planner_id.is_empty():
		AgenticStudioConfig.set_selected_planner_id(planner_id)
	if not coder_id.is_empty():
		AgenticStudioConfig.set_selected_coder_id(coder_id)

	var mode: String = AgenticStudioJob.mode_from_index(mode_picker.selected)
	var use_planner: bool = mode == AgenticStudioJob.MODE_PLAN
	var selected_id: String = planner_id if use_planner else coder_id
	var expected_role: String = (
		AgenticStudioConfig.ROLE_PLANNER if use_planner else AgenticStudioConfig.ROLE_CODER
	)
	var model: Dictionary = AgenticStudioConfig.get_model(selected_id)
	var checked: Dictionary = AgenticStudioConfig.validate_role_endpoint(model, expected_role)
	if not bool(checked.get("ok", false)):
		var err_msg: String = str(checked.get("error", "model invalid"))
		# Plan with blank Build URL: log named error, do not open a socket / hang.
		_status_line.text = "%s — nothing written. · %s" % [err_msg, _blender_status_fragment()]
		_append_send_failure_log(channel, session_i, prompt, mode, selected_id, err_msg)
		return

	_set_job_running(true)

	var job := AgenticStudioJob.new()
	job.prompt = prompt
	job.model_id = selected_id
	job.mode = mode
	job.channel = channel
	job.stage = AgenticStudioJob.STAGE_RUNNING
	job.append_log("Job created (%s: %s)." % [
		expected_role,
		str(model.get("display_name", selected_id)),
	])
	job.save()

	prompt_edit.text = ""

	if channel == AgenticStudioJob.CHANNEL_STUDIO:
		_studio_jobs.append(job)
		if _studio_transcript == null:
			_studio_transcript = TranscriptScript.new(TranscriptScript.STUDIO_SESSION_ID)
			_studio_transcript.title = "Studio"
		_studio_transcript.begin_turn(prompt, mode, selected_id, job.id)
		_studio_transcript.sync_turn_from_job(
			_studio_transcript.turns.size() - 1,
			job
		)
		_studio_transcript.save()
		_refresh_studio_log()
		# Stay on Studio — do not create a session tab.
		_suppress_tab_signal = true
		_tab_bar.current_tab = TAB_STUDIO
		_suppress_tab_signal = false
		_show_tab_content(TAB_STUDIO)
	else:
		var entry: Dictionary = _sessions[session_i]
		entry["job"] = job
		var tr: RefCounted = entry.get("transcript") as RefCounted
		if tr == null:
			tr = TranscriptScript.new()
			entry["transcript"] = tr
		tr.begin_turn(prompt, mode, selected_id, job.id)
		tr.sync_turn_from_job(tr.turns.size() - 1, job)
		tr.save()
		var title: String = str(tr.title)
		if title.is_empty():
			title = job.tab_title()
		if title.is_empty():
			title = str(entry.get("title", "Session"))
		entry["title"] = title
		_sessions[session_i] = entry
		var tab_index: int = session_i + 1
		_tab_bar.set_tab_title(tab_index, title)
		_apply_transcript_to_view(entry["log"] as TextEdit, tr)
		_persist_open_session_ids()
		_suppress_tab_signal = true
		_tab_bar.current_tab = tab_index
		_suppress_tab_signal = false
		_show_tab_content(tab_index)

	match mode:
		AgenticStudioJob.MODE_PLAN:
			await _run_plan(job, model)
		AgenticStudioJob.MODE_RUN:
			await _run_execute(job, model, true)
		AgenticStudioJob.MODE_AUTO_APPROVE:
			await _run_execute(job, model, false)

	_set_job_running(false)
	_update_status_line()
	_refresh_job_view(job)


func _refresh_job_view(job: AgenticStudioJob) -> void:
	if job.channel == AgenticStudioJob.CHANNEL_STUDIO:
		var found: bool = false
		for i: int in range(_studio_jobs.size()):
			if _studio_jobs[i].id == job.id:
				_studio_jobs[i] = job
				found = true
				break
		if not found:
			_studio_jobs.append(job)
		if _studio_transcript != null:
			var ti: int = _studio_transcript.find_turn_index_for_job(job.id)
			if ti < 0:
				ti = _studio_transcript.begin_turn(job.prompt, job.mode, job.model_id, job.id)
			_studio_transcript.sync_turn_from_job(ti, job)
			_studio_transcript.save()
		_refresh_studio_log()
		return
	for i: int in range(_sessions.size()):
		var entry: Dictionary = _sessions[i]
		var tr: RefCounted = entry.get("transcript") as RefCounted
		var bound: AgenticStudioJob = entry.get("job") as AgenticStudioJob
		var ti2: int = -1
		if tr != null:
			ti2 = tr.find_turn_index_for_job(job.id)
		if ti2 < 0 and (bound == null or bound.id != job.id):
			continue
		entry["job"] = job
		if tr == null:
			tr = TranscriptScript.new()
			entry["transcript"] = tr
			ti2 = tr.begin_turn(job.prompt, job.mode, job.model_id, job.id)
		elif ti2 < 0:
			ti2 = tr.begin_turn(job.prompt, job.mode, job.model_id, job.id)
		tr.sync_turn_from_job(ti2, job)
		tr.save()
		var title: String = str(tr.title)
		if title.is_empty():
			title = job.tab_title()
		if not title.is_empty():
			entry["title"] = title
			_tab_bar.set_tab_title(i + 1, title)
		_apply_transcript_to_view(entry["log"] as TextEdit, tr)
		_sessions[i] = entry
		return


func _on_settings_pressed() -> void:
	if _settings_dialog == null:
		return
	if _settings_dialog.has_method("is_file_dialog_open") and bool(_settings_dialog.call("is_file_dialog_open")):
		return
	_settings_dialog.open_settings()


func _on_settings_changed() -> void:
	_refresh_all_model_pickers()
	_reload_studio_drawthings_fields()
	_update_status_line()


func _refresh_pages_list() -> void:
	PageStoreScript.ensure_dirs()
	_page_paths = PackedStringArray()
	for child: Node in _pages_list.get_children():
		_pages_list.remove_child(child)
		child.queue_free()
	var selected_path: String = _current_page_path
	var pages: Array = PageStoreScript.list_pages()
	for i: int in range(pages.size()):
		var item: Variant = pages[i]
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = item
		var path: String = str(d.get("path", ""))
		var title: String = str(d.get("title", path.get_file()))
		var kind: String = str(d.get("kind", ""))
		_page_paths.append(path)
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_theme_constant_override("separation", 4)
		var select_btn := Button.new()
		select_btn.text = "%s (%s)" % [title, kind]
		select_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		select_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		select_btn.flat = true
		if path == selected_path:
			select_btn.disabled = true
			select_btn.text = "▸ %s (%s)" % [title, kind]
		var row_path: String = path
		select_btn.pressed.connect(func() -> void: _on_page_path_selected(row_path))
		row.add_child(select_btn)
		var remove_btn := Button.new()
		remove_btn.text = "✕"
		remove_btn.tooltip_text = "Remove page"
		remove_btn.custom_minimum_size = Vector2(28, 0)
		remove_btn.pressed.connect(func() -> void: _on_page_remove_pressed(row_path))
		row.add_child(remove_btn)
		_pages_list.add_child(row)


func _on_page_path_selected(path: String) -> void:
	_load_page_into_form(path)
	_refresh_pages_list()


func _on_page_remove_pressed(path: String) -> void:
	await _confirm_and_remove_page(path)


func _confirm_and_remove_page(path: String) -> void:
	var page: Resource = PageStoreScript.load_page(path)
	var title: String = path.get_file()
	if page != null:
		var t: String = str(page.get("title")).strip_edges()
		if not t.is_empty():
			title = t
	var dlg := ConfirmationDialog.new()
	dlg.title = "Remove page"
	dlg.dialog_text = (
		"Remove \"%s\"?\nThis deletes the page under res://studio/ and drops links to it.\nImported meshes and scene nodes are left alone."
		% title
	)
	dlg.ok_button_text = "Remove"
	dlg.cancel_button_text = "Cancel"
	add_child(dlg)
	dlg.popup_centered()
	var state: Dictionary = {"done": false, "ok": false}
	dlg.confirmed.connect(func() -> void:
		state["done"] = true
		state["ok"] = true
	)
	dlg.canceled.connect(func() -> void:
		state["done"] = true
		state["ok"] = false
	)
	dlg.close_requested.connect(func() -> void:
		state["done"] = true
		state["ok"] = false
	)
	while not bool(state["done"]):
		await get_tree().process_frame
	dlg.queue_free()
	if not bool(state["ok"]):
		return
	var result: Dictionary = PageStoreScript.delete_page(path)
	if not bool(result.get("ok", false)):
		_status_line.text = "Remove failed: %s" % str(result.get("error", ""))
		return
	if _current_page_path == path:
		_current_page_path = ""
		_page_path_label.text = "No page selected"
		_page_title.text = ""
		_page_notes.text = ""
		_page_tags.text = ""
		_page_images.clear()
		_page_links.clear()
	_refresh_pages_list()
	_status_line.text = "Removed %s" % path
	if EditorInterface.get_resource_filesystem() != null:
		EditorInterface.get_resource_filesystem().scan()


func _on_new_character_pressed() -> void:
	_create_blank_page(PageScript.KIND_CHARACTER)


func _on_new_asset_pressed() -> void:
	_create_blank_page(PageScript.KIND_ASSET)


func _create_blank_page(kind: String) -> void:
	var page: Resource = PageScript.new()
	page.set("kind", kind)
	page.set("title", "New %s" % kind.capitalize())
	page.set("notes", "")
	page.set("tags", PackedStringArray())
	page.set("image_paths", PackedStringArray())
	page.set("links", PackedStringArray())
	var saved: Dictionary = PageStoreScript.save_page(page)
	if not bool(saved.get("ok", false)):
		_status_line.text = "Could not create page: %s" % str(saved.get("error", ""))
		return
	_current_page_path = str(saved.get("path", ""))
	_refresh_pages_list()
	_load_page_into_form(_current_page_path)
	if EditorInterface.get_resource_filesystem() != null:
		EditorInterface.get_resource_filesystem().scan()


func _on_page_selected(index: int) -> void:
	## Kept for compatibility; pages list uses per-row buttons now.
	if index < 0 or index >= _page_paths.size():
		return
	_on_page_path_selected(_page_paths[index])


func _load_page_into_form(path: String) -> void:
	_loading_page = true
	_current_page_path = path
	var page: Resource = PageStoreScript.load_page(path)
	if page == null:
		_page_path_label.text = "Missing: %s" % path
		_loading_page = false
		return
	_page_path_label.text = path
	_page_title.text = str(page.get("title"))
	var kind: String = str(page.get("kind"))
	_page_kind.select(1 if kind == PageScript.KIND_ASSET else 0)
	_page_notes.text = str(page.get("notes"))
	_page_tags.text = ", ".join(PackedStringArray(page.get("tags")))
	_page_images.clear()
	for img: String in PackedStringArray(page.get("image_paths")):
		_page_images.add_item(img)
	_page_links.clear()
	for link: String in PackedStringArray(page.get("links")):
		_page_links.add_item(link)
	if _page_drop != null and _page_drop.has_method("set"):
		_page_drop.set("enabled", kind == PageScript.KIND_CHARACTER)
	_loading_page = false


func _mark_page_dirty() -> void:
	if _loading_page:
		return


func _on_save_page_pressed() -> void:
	if _current_page_path.is_empty():
		_status_line.text = "Select or create a page first."
		return
	var page: Resource = PageStoreScript.load_page(_current_page_path)
	if page == null:
		page = PageScript.new()
		page.set(
			"kind",
			PageScript.KIND_ASSET if _page_kind.selected == 1 else PageScript.KIND_CHARACTER
		)
	page.set("title", _page_title.text.strip_edges())
	page.set("notes", _page_notes.text)
	var tags: PackedStringArray = PackedStringArray()
	for part: String in _page_tags.text.split(",", false):
		var t: String = part.strip_edges()
		if not t.is_empty():
			tags.append(t)
	page.set("tags", tags)
	var saved: Dictionary = PageStoreScript.save_page(page, _current_page_path)
	if not bool(saved.get("ok", false)):
		_status_line.text = "Save failed: %s" % str(saved.get("error", ""))
		return
	_current_page_path = str(saved.get("path", _current_page_path))
	_refresh_pages_list()
	_load_page_into_form(_current_page_path)
	_status_line.text = "Saved %s" % _current_page_path
	if EditorInterface.get_resource_filesystem() != null:
		EditorInterface.get_resource_filesystem().scan()


func _on_images_dropped(paths: PackedStringArray) -> void:
	if _current_page_path.is_empty():
		_status_line.text = "Create or select a character page before dropping images."
		return
	var page: Resource = PageStoreScript.load_page(_current_page_path)
	if page == null:
		_status_line.text = "Page missing: %s" % _current_page_path
		return
	if str(page.get("kind")) != PageScript.KIND_CHARACTER:
		_status_line.text = "Drop images onto a character page."
		return
	page.set("title", _page_title.text.strip_edges())
	page.set("notes", _page_notes.text)
	for src: String in paths:
		var copied: Dictionary = PageStoreScript.copy_image_into_page_folder(
			_current_page_path,
			src
		)
		var img_path: String = src
		if bool(copied.get("ok", false)):
			img_path = str(copied.get("path", src))
		elif src.begins_with("res://"):
			img_path = src
		else:
			img_path = src
		PageStoreScript.add_image_path(page, img_path)
	var saved: Dictionary = PageStoreScript.save_page(page, _current_page_path)
	if not bool(saved.get("ok", false)):
		_status_line.text = "Could not save images: %s" % str(saved.get("error", ""))
		return
	_load_page_into_form(_current_page_path)
	_refresh_pages_list()
	_status_line.text = "Added %d image(s) to page" % paths.size()
	if EditorInterface.get_resource_filesystem() != null:
		EditorInterface.get_resource_filesystem().scan()


func _on_planner_selected(index: int) -> void:
	if _suppress_picker_signal:
		return
	if index <= 0 or index - 1 >= _planner_ids.size():
		AgenticStudioConfig.set_selected_planner_id("")
	else:
		AgenticStudioConfig.set_selected_planner_id(_planner_ids[index - 1])
	_sync_role_pickers_to_config()
	_refresh_all_picker_tooltips()
	_update_status_line()


func _on_coder_selected(index: int) -> void:
	if _suppress_picker_signal:
		return
	if index <= 0 or index - 1 >= _coder_ids.size():
		AgenticStudioConfig.set_selected_coder_id("")
	else:
		AgenticStudioConfig.set_selected_coder_id(_coder_ids[index - 1])
	_sync_role_pickers_to_config()
	_refresh_all_picker_tooltips()
	_update_status_line()


func _refresh_all_picker_tooltips() -> void:
	_update_role_picker_tooltip(_studio_planner)
	_update_role_picker_tooltip(_studio_coder)
	for entry: Dictionary in _sessions:
		_update_role_picker_tooltip(entry.get("planner") as OptionButton)
		_update_role_picker_tooltip(entry.get("coder") as OptionButton)


func _fill_role_pickers(planner_picker: OptionButton, coder_picker: OptionButton) -> void:
	_suppress_picker_signal = true
	_planner_ids = PackedStringArray()
	_coder_ids = PackedStringArray()
	_fill_one_role_picker(
		planner_picker,
		AgenticStudioConfig.ROLE_PLANNER,
		AgenticStudioConfig.get_selected_planner_id(),
		_planner_ids
	)
	_fill_one_role_picker(
		coder_picker,
		AgenticStudioConfig.ROLE_CODER,
		AgenticStudioConfig.get_selected_coder_id(),
		_coder_ids
	)
	_suppress_picker_signal = false


func _fill_one_role_picker(
	picker: OptionButton,
	role: String,
	selected_id: String,
	ids_out: PackedStringArray
) -> void:
	picker.clear()
	picker.add_item("None", 0)
	picker.set_item_metadata(0, "")
	var select_index: int = 0
	var models: Array[Dictionary] = AgenticStudioConfig.list_models_for_role(role)
	var item_i: int = 1
	for model: Dictionary in models:
		var id: String = str(model.get("id", ""))
		var display: String = str(model.get("display_name", id))
		# Draw Things is a tool, never a planner/coder model row.
		if _looks_like_drawthings_tool(id, display):
			continue
		ids_out.append(id)
		var kind: String = str(model.get("kind", "local"))
		var label: String = "%s (%s)" % [display, kind]
		picker.add_item(label, item_i)
		picker.set_item_metadata(item_i, display)
		if id == selected_id:
			select_index = item_i
		item_i += 1
	picker.select(select_index)
	_update_role_picker_tooltip(picker)


func _looks_like_drawthings_tool(id: String, display: String) -> bool:
	var blob: String = ("%s %s" % [id, display]).to_lower()
	return blob.find("drawthings") >= 0 or blob.find("draw-things") >= 0 or blob.find("draw things") >= 0


func _update_role_picker_tooltip(picker: OptionButton) -> void:
	if picker == null:
		return
	var idx: int = picker.selected
	if idx < 0 or idx >= picker.item_count:
		picker.tooltip_text = ""
		return
	var meta: Variant = picker.get_item_metadata(idx)
	if typeof(meta) == TYPE_STRING and not str(meta).is_empty():
		picker.tooltip_text = str(meta)
	else:
		picker.tooltip_text = picker.get_item_text(idx)


func _refresh_all_model_pickers() -> void:
	_fill_role_pickers(_studio_planner, _studio_coder)
	for entry: Dictionary in _sessions:
		_fill_role_pickers(entry["planner"] as OptionButton, entry["coder"] as OptionButton)


func _sync_role_pickers_to_config() -> void:
	var planner_id: String = AgenticStudioConfig.get_selected_planner_id()
	var coder_id: String = AgenticStudioConfig.get_selected_coder_id()
	var planner_i: int = 0
	var coder_i: int = 0
	for i: int in range(_planner_ids.size()):
		if _planner_ids[i] == planner_id:
			planner_i = i + 1
			break
	for j: int in range(_coder_ids.size()):
		if _coder_ids[j] == coder_id:
			coder_i = j + 1
			break
	_suppress_picker_signal = true
	_studio_planner.select(planner_i)
	_studio_coder.select(coder_i)
	for entry: Dictionary in _sessions:
		(entry["planner"] as OptionButton).select(planner_i)
		(entry["coder"] as OptionButton).select(coder_i)
	_suppress_picker_signal = false
	_refresh_all_picker_tooltips()


func _update_status_line() -> void:
	var planner: Dictionary = AgenticStudioConfig.get_selected_planner()
	var coder: Dictionary = AgenticStudioConfig.get_selected_coder()
	var planner_text: String = "Planner: none"
	if not planner.is_empty():
		planner_text = "Planner: %s" % str(planner.get("display_name", planner.get("id", "")))
	var coder_text: String = "Coder: none"
	if not coder.is_empty():
		coder_text = "Coder: %s" % str(coder.get("display_name", coder.get("id", "")))
	var blender: String = AgenticStudioConfig.get_blender_path()
	var blender_text: String = "Blender path set" if not blender.is_empty() else "Blender path not set"
	_status_line.text = "%s · %s · %s" % [planner_text, coder_text, blender_text]


func _update_controls_enabled() -> void:
	var disabled: bool = _job_running
	_studio_planner.disabled = disabled
	_studio_coder.disabled = disabled
	_studio_mode.disabled = disabled
	_studio_send.disabled = disabled
	_plus_btn.disabled = disabled
	for entry: Dictionary in _sessions:
		(entry["planner"] as OptionButton).disabled = disabled
		(entry["coder"] as OptionButton).disabled = disabled
		(entry["mode"] as OptionButton).disabled = disabled
		(entry["send"] as Button).disabled = disabled


func _set_job_running(running: bool) -> void:
	_job_running = running
	_update_controls_enabled()


func _session_id_for_job(job: AgenticStudioJob) -> String:
	if job.channel == AgenticStudioJob.CHANNEL_STUDIO:
		return TranscriptScript.STUDIO_SESSION_ID
	for entry: Dictionary in _sessions:
		var bound: AgenticStudioJob = entry.get("job") as AgenticStudioJob
		if bound != null and bound.id == job.id:
			var tr: RefCounted = entry.get("transcript") as RefCounted
			if tr != null:
				return str(tr.session_id)
		var tr2: RefCounted = entry.get("transcript") as RefCounted
		if tr2 != null and int(tr2.find_turn_index_for_job(job.id)) >= 0:
			return str(tr2.session_id)
	if not _sessions.is_empty():
		var tr3: RefCounted = (_sessions[0] as Dictionary).get("transcript") as RefCounted
		if tr3 != null:
			return str(tr3.session_id)
	return "session"


func _append_send_failure_log(
	channel: String,
	session_i: int,
	prompt: String,
	mode: String,
	model_id: String,
	error_msg: String
) -> void:
	## Visible dock/session log for Plan validation failures (no socket opened).
	var safe: String = _sanitize_log_text(error_msg)
	if channel == AgenticStudioJob.CHANNEL_STUDIO:
		if _studio_transcript == null:
			_studio_transcript = TranscriptScript.new(TranscriptScript.STUDIO_SESSION_ID)
			_studio_transcript.title = "Studio"
		_studio_transcript.begin_turn(prompt, mode, model_id, "")
		var job := AgenticStudioJob.new()
		job.prompt = prompt
		job.model_id = model_id
		job.mode = mode
		job.channel = channel
		job.stage = AgenticStudioJob.STAGE_FAILED
		job.append_log(safe)
		job.save()
		_studio_transcript.sync_turn_from_job(_studio_transcript.turns.size() - 1, job)
		_studio_transcript.save()
		_refresh_studio_log()
		return
	if session_i < 0 or session_i >= _sessions.size():
		return
	var entry: Dictionary = _sessions[session_i]
	var tr: RefCounted = entry.get("transcript") as RefCounted
	if tr == null:
		tr = TranscriptScript.new()
		entry["transcript"] = tr
	tr.begin_turn(prompt, mode, model_id, "")
	var job2 := AgenticStudioJob.new()
	job2.prompt = prompt
	job2.model_id = model_id
	job2.mode = mode
	job2.channel = channel
	job2.stage = AgenticStudioJob.STAGE_FAILED
	job2.append_log(safe)
	job2.save()
	tr.sync_turn_from_job(tr.turns.size() - 1, job2)
	tr.save()
	_apply_transcript_to_view(entry["log"] as TextEdit, tr)
	_sessions[session_i] = entry


func _sanitize_log_text(text: String) -> String:
	## Session and dock logs must never include an API key.
	var out: String = text
	var key_markers: PackedStringArray = PackedStringArray([
		"Authorization: Bearer ",
		"api_key",
		"api-key",
	])
	for marker: String in key_markers:
		var at: int = out.findn(marker)
		while at >= 0:
			var end: int = at
			while end < out.length() and out[end] != " " and out[end] != "\n" and out[end] != "\"":
				end += 1
			out = out.substr(0, at) + "[redacted]" + out.substr(end)
			at = out.findn(marker)
	return out


func _host_port_from_url(url: String) -> String:
	var u: String = url.strip_edges()
	if u.is_empty():
		return "unknown:0"
	var rest: String = u
	if rest.begins_with("https://"):
		rest = rest.substr(8)
	elif rest.begins_with("http://"):
		rest = rest.substr(7)
	var slash: int = rest.find("/")
	if slash >= 0:
		rest = rest.substr(0, slash)
	if rest.find(":") < 0:
		if u.begins_with("https://"):
			rest = "%s:443" % rest
		else:
			rest = "%s:80" % rest
	return rest


func _run_plan(job: AgenticStudioJob, model: Dictionary) -> void:
	## Planner only. No apply API, no scene writes. Discard any write-shaped reply.
	var tools := AgenticStudioSceneTools.new()
	tools.setup(job.id, _session_id_for_job(job))
	var budget: int = AgenticStudioContextBudget.resolve_budget(model)
	var session_lines: PackedStringArray = AgenticStudioSessionLog.read_recent_lines(40)
	var packed: Dictionary = AgenticStudioContextBudget.pack(
		{
			"system": AgenticStudioModelClient.PLAN_SYSTEM_PROMPT,
			"op_schema": "Plan fields: page_id, intended_op, play_check_done.",
			"page_id": "(planner must name page_id)",
			"last_play_error": "",
			"prompt": job.prompt,
		},
		session_lines,
		PackedStringArray(),
		budget
	)
	if not bool(packed.get("ok", false)):
		job.append_log(_sanitize_log_text(str(packed.get("error", "context budget exceeded"))))
		job.stage = AgenticStudioJob.STAGE_FAILED
		job.save()
		return
	var messages: Array = AgenticStudioModelClient.initial_plan_messages(job.prompt)
	var extra: String = str(packed.get("messages_user_extra", ""))
	if not extra.is_empty() and messages.size() >= 2:
		var user_msg: Dictionary = messages[1]
		user_msg["content"] = str(user_msg.get("content", "")) + "\n\n" + extra
		messages[1] = user_msg
	var round_i: int = 0
	var plan_ops: Array = []

	while round_i < AgenticStudioModelClient.MAX_TOOL_ROUNDS:
		job.append_log("Calling planner…")
		job.save()
		_refresh_job_view(job)
		AgenticStudioModelClient.apply_pending_shots(messages, model, tools)

		var response: Dictionary = await _http_chat(model, messages, true, true, job.mode)
		if not bool(response.get("ok", false)):
			job.append_log(_sanitize_log_text(str(response.get("error", "plan request failed"))))
			job.stage = AgenticStudioJob.STAGE_FAILED
			job.save()
			AgenticStudioSessionLog.append_plan_or_run(
				job.model_id, job.mode, tools.cited_page_ids, plan_ops, null, model
			)
			return

		var message: Dictionary = response.get("message", {})
		var text: String = str(message.get("content", "")).strip_edges()
		var tool_calls: Array = message.get("tool_calls", [])
		if AgenticStudioModelClient.planner_response_has_write(text, tool_calls):
			job.append_log("Planner write discarded — not applied.")
			job.stage = AgenticStudioJob.STAGE_FAILED
			job.save()
			AgenticStudioSessionLog.append_plan_or_run(
				job.model_id, job.mode, tools.cited_page_ids, plan_ops, null, model
			)
			return

		messages.append(AgenticStudioModelClient.assistant_message_for_history(message))
		if not text.is_empty() and tool_calls.is_empty():
			job.append_log(text)
			job.save()
			_refresh_job_view(job)
		elif not text.is_empty() and bool(message.get("from_content_tools", false)):
			job.append_log("Model requested tool(s) via content.")
			job.save()
			_refresh_job_view(job)
		elif not text.is_empty():
			job.append_log(text)
			job.save()
			_refresh_job_view(job)

		if tool_calls.is_empty():
			break

		round_i += 1
		job.append_log("Tool round %d/%d (%d call(s))" % [
			round_i,
			AgenticStudioModelClient.MAX_TOOL_ROUNDS,
			tool_calls.size(),
		])
		job.save()
		_refresh_job_view(job)

		var from_content: bool = bool(message.get("from_content_tools", false))
		var content_results: Array = []
		for call_v: Variant in tool_calls:
			if typeof(call_v) != TYPE_DICTIONARY:
				continue
			var call: Dictionary = call_v
			var call_id: String = str(call.get("id", ""))
			var fn: Dictionary = call.get("function", {})
			var tool_name: String = str(fn.get("name", ""))
			var args: Dictionary = AgenticStudioModelClient.parse_tool_arguments(
				str(fn.get("arguments", "{}"))
			)
			var result_payload: Dictionary = {"ok": false, "error": "unhandled"}
			if not AgenticStudioSceneTools.is_plan_tool(tool_name):
				job.append_log("Plan blocked tool: %s" % tool_name)
				result_payload = {
					"ok": false,
					"error": AgenticStudioSceneTools.BLOCKED_MESSAGE,
				}
			else:
				var outcome: Dictionary
				if tool_name == AgenticStudioSceneTools.TOOL_SCREENSHOT:
					outcome = await tools.execute_screenshot(args)
				elif tool_name == AgenticStudioSceneTools.TOOL_EDITOR_SCREENSHOT:
					outcome = await tools.execute_editor_screenshot(args)
				else:
					outcome = tools.execute(tool_name, args)
				job.append_log(str(outcome.get("log", "")))
				result_payload = outcome.get("result", {"ok": false})
				plan_ops.append({"tool": tool_name, "arguments": args})
			job.save()
			_refresh_job_view(job)
			if from_content:
				content_results.append(JSON.stringify(result_payload))
			else:
				messages.append(
					AgenticStudioModelClient.tool_result_message(call_id, result_payload)
				)

		if from_content and not content_results.is_empty():
			messages.append(AgenticStudioModelClient.tool_results_user_message(content_results))

		if round_i >= AgenticStudioModelClient.MAX_TOOL_ROUNDS:
			job.append_log(
				"Stopped after %d tool rounds." % AgenticStudioModelClient.MAX_TOOL_ROUNDS
			)
			job.save()
			break

	if job.stage != AgenticStudioJob.STAGE_FAILED:
		job.stage = AgenticStudioJob.STAGE_PLANNED
		job.save()
	AgenticStudioSessionLog.append_plan_or_run(
		job.model_id, job.mode, tools.cited_page_ids, plan_ops, null, model
	)


func _run_execute(job: AgenticStudioJob, model: Dictionary, ask_writes: bool) -> void:
	var tools := AgenticStudioSceneTools.new()
	tools.setup(job.id, _session_id_for_job(job))
	var messages: Array = AgenticStudioModelClient.initial_execute_messages(job.prompt)
	var round_i: int = 0

	while round_i < AgenticStudioModelClient.MAX_TOOL_ROUNDS:
		job.append_log("Calling model…")
		job.save()
		_refresh_job_view(job)
		AgenticStudioModelClient.apply_pending_shots(messages, model, tools)

		var response: Dictionary = await _http_chat(model, messages, true)
		if not bool(response.get("ok", false)):
			job.append_log(str(response.get("error", "model request failed")))
			job.stage = AgenticStudioJob.STAGE_FAILED
			job.save()
			if tools.has_writes():
				await AgenticStudioExecuteRunner.finish_job(job, tools)
			else:
				tools.discard_if_empty()
			return

		var message: Dictionary = response.get("message", {})
		messages.append(AgenticStudioModelClient.assistant_message_for_history(message))
		var text: String = str(message.get("content", "")).strip_edges()
		var tool_calls: Array = message.get("tool_calls", [])
		if not text.is_empty() and tool_calls.is_empty():
			job.append_log(text)
			job.save()
			_refresh_job_view(job)
		elif not text.is_empty() and bool(message.get("from_content_tools", false)):
			job.append_log("Model requested tool(s) via content.")
			job.save()
			_refresh_job_view(job)
		elif not text.is_empty():
			job.append_log(text)
			job.save()
			_refresh_job_view(job)

		if tool_calls.is_empty():
			break

		round_i += 1
		job.append_log("Tool round %d/%d (%d call(s))" % [
			round_i,
			AgenticStudioModelClient.MAX_TOOL_ROUNDS,
			tool_calls.size(),
		])
		job.save()
		_refresh_job_view(job)

		var from_content: bool = bool(message.get("from_content_tools", false))
		var content_results: Array = []
		for call_v: Variant in tool_calls:
			if typeof(call_v) != TYPE_DICTIONARY:
				continue
			var result_payload: Dictionary = await _handle_tool_call(
				job,
				tools,
				messages,
				call_v,
				ask_writes,
				from_content
			)
			if from_content:
				content_results.append(JSON.stringify(result_payload))
			_refresh_job_view(job)

		if from_content and not content_results.is_empty():
			messages.append(AgenticStudioModelClient.tool_results_user_message(content_results))

		if round_i >= AgenticStudioModelClient.MAX_TOOL_ROUNDS:
			job.append_log(
				"Stopped after %d tool rounds." % AgenticStudioModelClient.MAX_TOOL_ROUNDS
			)
			job.save()
			break

	await AgenticStudioExecuteRunner.finish_job(job, tools)


func _handle_tool_call(
	job: AgenticStudioJob,
	tools: AgenticStudioSceneTools,
	messages: Array,
	call: Dictionary,
	ask_writes: bool,
	from_content: bool
) -> Dictionary:
	var call_id: String = str(call.get("id", ""))
	var fn: Dictionary = call.get("function", {})
	var tool_name: String = str(fn.get("name", ""))
	var args: Dictionary = AgenticStudioModelClient.parse_tool_arguments(
		str(fn.get("arguments", "{}"))
	)
	var result_payload: Dictionary = {"ok": false, "error": "unhandled"}

	if not AgenticStudioSceneTools.is_allowed_tool(tool_name):
		var blocked: Dictionary = tools.execute(tool_name, args)
		job.append_log(str(blocked.get("log", AgenticStudioSceneTools.BLOCKED_MESSAGE)))
		job.save()
		result_payload = blocked.get(
			"result",
			{"ok": false, "error": AgenticStudioSceneTools.BLOCKED_MESSAGE}
		)
		if not from_content:
			messages.append(AgenticStudioModelClient.tool_result_message(call_id, result_payload))
		return result_payload

	var PolicyScript = preload("res://addons/agentic_studio/policy.gd")
	var needs_ask: bool = PolicyScript.should_ask(tool_name, args, ask_writes)
	if needs_ask:
		var allowed: bool = await _confirm_write(tool_name, args)
		if not allowed:
			var skipped: Dictionary = tools.execute_skipped(tool_name, args)
			job.append_log(str(skipped.get("log", "skipped")))
			job.save()
			result_payload = skipped.get("result", {"ok": false, "error": "skipped by user"})
			if not from_content:
				messages.append(
					AgenticStudioModelClient.tool_result_message(call_id, result_payload)
				)
			return result_payload

	var outcome: Dictionary
	if tool_name == AgenticStudioSceneTools.TOOL_PLAY_SCENE:
		outcome = await tools.execute_play()
	elif tool_name == AgenticStudioSceneTools.TOOL_CREATE_ASSET:
		outcome = await tools.execute_create_asset(args)
	elif tool_name == AgenticStudioSceneTools.TOOL_IMAGE_GENERATE:
		outcome = await tools.execute_image_generate(args)
	elif tool_name == AgenticStudioSceneTools.TOOL_MESH_FROM_IMAGE:
		outcome = await tools.execute_mesh_from_image(args)
	elif tool_name == AgenticStudioSceneTools.TOOL_SCREENSHOT:
		outcome = await tools.execute_screenshot(args)
	elif tool_name == AgenticStudioSceneTools.TOOL_EDITOR_SCREENSHOT:
		outcome = await tools.execute_editor_screenshot(args)
	else:
		outcome = tools.execute(tool_name, args)
	job.append_log(str(outcome.get("log", "")))
	job.save()
	result_payload = outcome.get("result", {"ok": false})
	if not from_content:
		messages.append(AgenticStudioModelClient.tool_result_message(call_id, result_payload))
	return result_payload


func _confirm_write(tool_name: String, args: Dictionary) -> bool:
	var dlg := ConfirmationDialog.new()
	dlg.title = "AgenticStudio"
	dlg.dialog_text = "Allow %s?\n%s" % [tool_name, JSON.stringify(args)]
	dlg.ok_button_text = "Yes"
	dlg.cancel_button_text = "No"
	add_child(dlg)
	dlg.popup_centered()

	var state: Dictionary = {"done": false, "ok": false}
	dlg.confirmed.connect(func() -> void:
		state["done"] = true
		state["ok"] = true
	)
	dlg.canceled.connect(func() -> void:
		state["done"] = true
		state["ok"] = false
	)
	dlg.close_requested.connect(func() -> void:
		state["done"] = true
		state["ok"] = false
	)
	while not bool(state["done"]):
		await get_tree().process_frame
	dlg.queue_free()
	return bool(state["ok"])


func _http_chat(
	model: Dictionary,
	messages: Array,
	include_tools: bool,
	plan_only_tools: bool = false,
	mode: String = ""
) -> Dictionary:
	var built: Dictionary = AgenticStudioModelClient.build_chat_request(
		model,
		messages,
		include_tools,
		plan_only_tools
	)
	if not bool(built.get("ok", false)):
		return {
			"ok": false,
			"status": 0,
			"body": "",
			"message": {},
			"error": _sanitize_log_text(str(built.get("error", "build failed"))),
		}
	var url: String = str(built.get("url", ""))
	# Strip Authorization from headers before any accidental log of the request shape.
	var headers: PackedStringArray = built.get("headers", PackedStringArray())
	var raw: Dictionary = await _http_chat_raw(url, headers, str(built.get("body", "")), mode, plan_only_tools)
	if not bool(raw.get("ok", false)):
		raw["message"] = {}
		raw["error"] = _sanitize_log_text(str(raw.get("error", "")))
		return raw
	var message: Dictionary = AgenticStudioModelClient.parse_assistant_message(
		str(raw.get("body", ""))
	)
	var text: String = str(message.get("content", "")).strip_edges()
	var tool_calls: Array = message.get("tool_calls", [])
	if text.is_empty() and tool_calls.is_empty():
		return {
			"ok": false,
			"status": int(raw.get("status", 0)),
			"body": str(raw.get("body", "")),
			"message": message,
			"error": _sanitize_log_text(
				AgenticStudioModelClient.format_failure_log(
					int(raw.get("status", 0)),
					"empty_assistant",
					str(raw.get("body", ""))
				)
			),
		}
	return {
		"ok": true,
		"status": int(raw.get("status", 0)),
		"body": str(raw.get("body", "")),
		"message": message,
		"error": "",
	}


func _http_chat_raw(
	url: String,
	headers: PackedStringArray,
	body: String,
	mode: String = "",
	plan_only: bool = false
) -> Dictionary:
	var err: Error = _http.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		if plan_only:
			return {
				"ok": false,
				"status": 0,
				"body": "",
				"error": "planner connection failed: %s · mode=%s" % [
					_host_port_from_url(url),
					mode if not mode.is_empty() else "plan",
				],
			}
		return {
			"ok": false,
			"status": 0,
			"body": "",
			"error": AgenticStudioModelClient.format_failure_log(
				0,
				"request_failed",
				"HTTPRequest.request error %d" % err
			),
		}
	var completed: Variant = await _http.request_completed
	var result: int = int(completed[0])
	var response_code: int = int(completed[1])
	var response_body: PackedByteArray = completed[3]
	var body_text: String = response_body.get_string_from_utf8()
	var result_label: String = AgenticStudioModelClient.http_request_result_label(result)
	if result != HTTPRequest.RESULT_SUCCESS:
		if plan_only and (
			result == HTTPRequest.RESULT_CANT_CONNECT
			or result == HTTPRequest.RESULT_CANT_RESOLVE
			or result == HTTPRequest.RESULT_CONNECTION_ERROR
			or result == HTTPRequest.RESULT_TIMEOUT
		):
			return {
				"ok": false,
				"status": response_code,
				"body": "",
				"error": "planner connection failed: %s · mode=%s" % [
					_host_port_from_url(url),
					mode if not mode.is_empty() else "plan",
				],
			}
		return {
			"ok": false,
			"status": response_code,
			"body": body_text,
			"error": AgenticStudioModelClient.format_failure_log(
				response_code,
				result_label,
				body_text
			),
		}
	if response_code != 200:
		return {
			"ok": false,
			"status": response_code,
			"body": body_text,
			"error": AgenticStudioModelClient.format_failure_log(
				response_code,
				result_label,
				body_text
			),
		}
	return {
		"ok": true,
		"status": response_code,
		"body": body_text,
		"error": "",
	}


func _blender_status_fragment() -> String:
	var blender: String = AgenticStudioConfig.get_blender_path()
	return "Blender path set" if not blender.is_empty() else "Blender path not set"
