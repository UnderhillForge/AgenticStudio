@tool
extends AcceptDialog
## Model list and tool links. Saves to user://agentic_studio.cfg.

signal settings_changed

var _model_list: ItemList
var _extra_list: ItemList
var _blender_edit: LineEdit
var _models: Array[Dictionary] = []
var _extras: Array[Dictionary] = []
var _file_dialog: EditorFileDialog
var _browse_target: String = "" # "blender" | "extra"
var _browse_extra_index: int = -1


func _ready() -> void:
	title = "AgenticStudio Settings"
	ok_button_text = "Done"
	dialog_hide_on_ok = true
	min_size = Vector2i(560, 480)
	_build_ui()
	_file_dialog = EditorFileDialog.new()
	_file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
	_file_dialog.title = "Select program"
	_file_dialog.file_selected.connect(_on_file_selected)
	add_child(_file_dialog)


func open_settings() -> void:
	_reload_from_disk()
	popup_centered_ratio(0.5)


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(root)

	# --- Models ---
	var models_label := Label.new()
	models_label.text = "Models"
	root.add_child(models_label)

	_model_list = ItemList.new()
	_model_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_model_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_model_list.custom_minimum_size = Vector2(0, 140)
	root.add_child(_model_list)

	var model_buttons := HBoxContainer.new()
	root.add_child(model_buttons)

	var add_local_btn := Button.new()
	add_local_btn.text = "Add Local"
	add_local_btn.pressed.connect(_on_add_local)
	model_buttons.add_child(add_local_btn)

	var add_ext_btn := Button.new()
	add_ext_btn.text = "Add External"
	add_ext_btn.pressed.connect(_on_add_external)
	model_buttons.add_child(add_ext_btn)

	var edit_model_btn := Button.new()
	edit_model_btn.text = "Edit"
	edit_model_btn.pressed.connect(_on_edit_model)
	model_buttons.add_child(edit_model_btn)

	var remove_model_btn := Button.new()
	remove_model_btn.text = "Remove"
	remove_model_btn.pressed.connect(_on_remove_model)
	model_buttons.add_child(remove_model_btn)

	var sep1 := HSeparator.new()
	root.add_child(sep1)

	# --- Blender ---
	var blender_label := Label.new()
	blender_label.text = "Blender path"
	root.add_child(blender_label)

	var blender_row := HBoxContainer.new()
	root.add_child(blender_row)

	_blender_edit = LineEdit.new()
	_blender_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_blender_edit.placeholder_text = "Optional — missing path fails only jobs that need Blender"
	_blender_edit.text_submitted.connect(func(_t: String) -> void: _save_blender())
	_blender_edit.focus_exited.connect(_save_blender)
	blender_row.add_child(_blender_edit)

	var browse_blender := Button.new()
	browse_blender.text = "Browse…"
	browse_blender.pressed.connect(_on_browse_blender)
	blender_row.add_child(browse_blender)

	var sep2 := HSeparator.new()
	root.add_child(sep2)

	# --- Extra tools ---
	var extras_label := Label.new()
	extras_label.text = "Extra programs"
	root.add_child(extras_label)

	_extra_list = ItemList.new()
	_extra_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_extra_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_extra_list.custom_minimum_size = Vector2(0, 100)
	root.add_child(_extra_list)

	var extra_buttons := HBoxContainer.new()
	root.add_child(extra_buttons)

	var add_extra_btn := Button.new()
	add_extra_btn.text = "Add"
	add_extra_btn.pressed.connect(_on_add_extra)
	extra_buttons.add_child(add_extra_btn)

	var edit_extra_btn := Button.new()
	edit_extra_btn.text = "Edit"
	edit_extra_btn.pressed.connect(_on_edit_extra)
	extra_buttons.add_child(edit_extra_btn)

	var remove_extra_btn := Button.new()
	remove_extra_btn.text = "Remove"
	remove_extra_btn.pressed.connect(_on_remove_extra)
	extra_buttons.add_child(remove_extra_btn)


func _reload_from_disk() -> void:
	_models = AgenticStudioConfig.list_models()
	_extras = AgenticStudioConfig.list_extra_tools()
	_blender_edit.text = AgenticStudioConfig.get_blender_path()
	_refresh_model_list()
	_refresh_extra_list()


func _refresh_model_list() -> void:
	_model_list.clear()
	for model: Dictionary in _models:
		var kind: String = str(model.get("kind", "local"))
		var label: String = "%s  (%s · %s)" % [
			str(model.get("display_name", "")),
			kind,
			str(model.get("model_name", "")),
		]
		_model_list.add_item(label)


func _refresh_extra_list() -> void:
	_extra_list.clear()
	for tool: Dictionary in _extras:
		var path: String = str(tool.get("path", ""))
		var path_note: String = path if not path.is_empty() else "(no path)"
		_extra_list.add_item("%s — %s" % [str(tool.get("name", "")), path_note])


func _save_blender() -> void:
	AgenticStudioConfig.set_blender_path(_blender_edit.text.strip_edges())
	settings_changed.emit()


func _on_browse_blender() -> void:
	_browse_target = "blender"
	_browse_extra_index = -1
	_file_dialog.popup_file_dialog()


func _on_file_selected(path: String) -> void:
	if _browse_target == "blender":
		_blender_edit.text = path
		_save_blender()
	elif _browse_target == "extra" and _browse_extra_index >= 0 and _browse_extra_index < _extras.size():
		var tool: Dictionary = _extras[_browse_extra_index].duplicate(true)
		tool["path"] = path
		AgenticStudioConfig.upsert_extra_tool(tool)
		_reload_from_disk()
		settings_changed.emit()


func _on_add_local() -> void:
	_edit_model({
		"id": "",
		"display_name": "",
		"kind": "local",
		"base_url": "http://127.0.0.1:8080/v1",
		"model_name": "",
		"context_length": 0,
	}, true)


func _on_add_external() -> void:
	_edit_model({
		"id": "",
		"display_name": "",
		"kind": "external",
		"base_url": "https://api.openai.com/v1",
		"model_name": "",
		"context_length": 0,
		"api_key": "",
	}, true)


func _on_edit_model() -> void:
	var selected: PackedInt32Array = _model_list.get_selected_items()
	if selected.is_empty():
		return
	_edit_model(_models[selected[0]].duplicate(true), false)


func _on_remove_model() -> void:
	var selected: PackedInt32Array = _model_list.get_selected_items()
	if selected.is_empty():
		return
	var model: Dictionary = _models[selected[0]]
	AgenticStudioConfig.remove_model(str(model.get("id", "")))
	_reload_from_disk()
	settings_changed.emit()


func _edit_model(model: Dictionary, is_new: bool) -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "Add Model" if is_new else "Edit Model"
	dlg.min_size = Vector2i(420, 320)
	dlg.dialog_hide_on_ok = false

	var form := VBoxContainer.new()
	dlg.add_child(form)

	var name_edit := _labeled_line(form, "Display name", str(model.get("display_name", "")))
	var url_edit := _labeled_line(form, "Base URL", str(model.get("base_url", "")))
	var model_edit := _labeled_line(form, "Model name", str(model.get("model_name", "")))
	var ctx_edit := _labeled_line(form, "Context length (optional)", str(int(model.get("context_length", 0))))
	var images_check := CheckBox.new()
	images_check.text = "Accepts image input (attach screenshots)"
	images_check.button_pressed = bool(model.get("accepts_images", false))
	form.add_child(images_check)
	var key_edit: LineEdit = null
	if str(model.get("kind", "")) == "external":
		key_edit = _labeled_line(form, "API key (stored in user:// only)", str(model.get("api_key", "")))
		key_edit.secret = true

	dlg.confirmed.connect(func() -> void:
		var display: String = name_edit.text.strip_edges()
		var model_name: String = model_edit.text.strip_edges()
		if display.is_empty() or model_name.is_empty():
			dlg.dialog_text = "Display name and model name are required."
			return
		model["display_name"] = display
		model["base_url"] = url_edit.text.strip_edges()
		model["model_name"] = model_name
		model["context_length"] = int(ctx_edit.text.strip_edges()) if ctx_edit.text.strip_edges().is_valid_int() else 0
		model["accepts_images"] = images_check.button_pressed
		if key_edit != null:
			model["api_key"] = key_edit.text
		AgenticStudioConfig.upsert_model(model)
		_reload_from_disk()
		settings_changed.emit()
		dlg.hide()
		dlg.queue_free()
	)
	dlg.canceled.connect(dlg.queue_free)
	dlg.close_requested.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered()


func _on_add_extra() -> void:
	_edit_extra({"id": "", "name": "", "path": ""}, true)


func _on_edit_extra() -> void:
	var selected: PackedInt32Array = _extra_list.get_selected_items()
	if selected.is_empty():
		return
	_edit_extra(_extras[selected[0]].duplicate(true), false)


func _on_remove_extra() -> void:
	var selected: PackedInt32Array = _extra_list.get_selected_items()
	if selected.is_empty():
		return
	var tool: Dictionary = _extras[selected[0]]
	AgenticStudioConfig.remove_extra_tool(str(tool.get("id", "")))
	_reload_from_disk()
	settings_changed.emit()


func _edit_extra(tool: Dictionary, is_new: bool) -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "Add Program" if is_new else "Edit Program"
	dlg.min_size = Vector2i(420, 180)
	dlg.dialog_hide_on_ok = false

	var form := VBoxContainer.new()
	dlg.add_child(form)

	var name_edit := _labeled_line(form, "Name", str(tool.get("name", "")))
	var path_row := HBoxContainer.new()
	form.add_child(path_row)
	var path_label := Label.new()
	path_label.text = "Path"
	path_label.custom_minimum_size = Vector2(100, 0)
	path_row.add_child(path_label)
	var path_edit := LineEdit.new()
	path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_edit.text = str(tool.get("path", ""))
	path_edit.placeholder_text = "May be empty"
	path_row.add_child(path_edit)
	var browse_btn := Button.new()
	browse_btn.text = "…"
	browse_btn.pressed.connect(func() -> void:
		_browse_target = "extra_pending"
		_file_dialog.file_selected.connect(
			func(p: String) -> void: path_edit.text = p,
			CONNECT_ONE_SHOT
		)
		_file_dialog.popup_file_dialog()
	)
	path_row.add_child(browse_btn)

	dlg.confirmed.connect(func() -> void:
		var name_val: String = name_edit.text.strip_edges()
		if name_val.is_empty():
			dlg.dialog_text = "Name is required."
			return
		tool["name"] = name_val
		tool["path"] = path_edit.text.strip_edges()
		AgenticStudioConfig.upsert_extra_tool(tool)
		_reload_from_disk()
		settings_changed.emit()
		dlg.hide()
		dlg.queue_free()
	)
	dlg.canceled.connect(dlg.queue_free)
	dlg.close_requested.connect(dlg.queue_free)
	add_child(dlg)
	dlg.popup_centered()


func _labeled_line(parent: Control, label_text: String, value: String) -> LineEdit:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(160, 0)
	row.add_child(label)
	var edit := LineEdit.new()
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.text = value
	row.add_child(edit)
	return edit
