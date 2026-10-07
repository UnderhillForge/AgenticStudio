@tool
extends AcceptDialog
## Model list and tool links. Saves to user://agentic_studio.cfg.
## Keys stay masked and only in that file — never printed to logs or session jsonl.

signal settings_changed

var _model_list: ItemList
var _extra_list: ItemList
var _blender_edit: LineEdit
var _drawthings_cli_edit: LineEdit
var _drawthings_models_edit: LineEdit
var _drawthings_model_edit: LineEdit
var _planner_picker: OptionButton
var _coder_picker: OptionButton
var _models: Array[Dictionary] = []
var _extras: Array[Dictionary] = []
var _file_dialog: EditorFileDialog
var _dir_dialog: EditorFileDialog
var _browse_target: String = "" # "blender" | "drawthings_cli" | "drawthings_models" | "extra"
var _browse_extra_index: int = -1
var _suppress_role_signal: bool = false
var _ui_root: VBoxContainer = null
var _status_label: Label = null
var _saved_exclusive: bool = true
var _file_dialog_open: bool = false


func _ready() -> void:
	title = "AgenticStudio Settings"
	ok_button_text = "Done"
	dialog_hide_on_ok = true
	min_size = Vector2i(620, 640)
	_build_ui()
	_ensure_file_dialogs()


func open_settings() -> void:
	# Do not popup settings while a file dialog owns the exclusive slot.
	if _file_dialog_open:
		return
	if _file_dialog != null and is_instance_valid(_file_dialog) and _file_dialog.visible:
		return
	if _dir_dialog != null and is_instance_valid(_dir_dialog) and _dir_dialog.visible:
		return
	_reload_from_disk()
	popup_centered_ratio(0.55)


func is_file_dialog_open() -> bool:
	return _file_dialog_open


## EditorFileDialog must not be an exclusive child of this AcceptDialog.
func _ensure_file_dialogs() -> void:
	# Headless / non-editor: EditorFileDialog cannot be instantiated.
	if not Engine.is_editor_hint() or not ClassDB.can_instantiate("EditorFileDialog"):
		return
	var host: Node = self
	var base: Control = EditorInterface.get_base_control()
	if base != null:
		host = base
	if _file_dialog == null or not is_instance_valid(_file_dialog):
		_file_dialog = EditorFileDialog.new()
		_file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
		_file_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
		_file_dialog.title = "Select program"
		_file_dialog.file_selected.connect(_on_file_selected)
		_file_dialog.canceled.connect(_on_browse_finished)
		host.add_child(_file_dialog)
	elif _file_dialog.get_parent() != host:
		if _file_dialog.get_parent() != null:
			_file_dialog.get_parent().remove_child(_file_dialog)
		host.add_child(_file_dialog)
	if _dir_dialog == null or not is_instance_valid(_dir_dialog):
		_dir_dialog = EditorFileDialog.new()
		_dir_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
		_dir_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
		_dir_dialog.title = "Select models directory"
		_dir_dialog.dir_selected.connect(_on_dir_selected)
		_dir_dialog.canceled.connect(_on_browse_finished)
		host.add_child(_dir_dialog)
	elif _dir_dialog.get_parent() != host:
		if _dir_dialog.get_parent() != null:
			_dir_dialog.get_parent().remove_child(_dir_dialog)
		host.add_child(_dir_dialog)


func _popup_browse_dialog(dlg: EditorFileDialog) -> void:
	_ensure_file_dialogs()
	if dlg == null or not is_instance_valid(dlg):
		push_warning("AgenticStudio: file dialog unavailable")
		return
	# File browse owns the exclusive slot; settings must not stay exclusive.
	_saved_exclusive = exclusive
	exclusive = false
	_file_dialog_open = true
	dlg.popup_file_dialog()


func _on_browse_finished() -> void:
	_file_dialog_open = false
	exclusive = _saved_exclusive


func _build_ui() -> void:
	# Idempotent rebuild: drop prior content root, keep dialog chrome.
	if _ui_root != null and is_instance_valid(_ui_root):
		remove_child(_ui_root)
		_ui_root.queue_free()
		_ui_root = null
	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_ui_root = root
	add_child(root)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.visible = false
	root.add_child(_status_label)

	# --- Selected roles ---
	var role_label := Label.new()
	role_label.text = "Selected roles"
	root.add_child(role_label)

	var role_row := HBoxContainer.new()
	root.add_child(role_row)
	var planner_lbl := Label.new()
	planner_lbl.text = "Planner"
	role_row.add_child(planner_lbl)
	_planner_picker = OptionButton.new()
	_planner_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_planner_picker.item_selected.connect(_on_planner_picked)
	role_row.add_child(_planner_picker)

	var coder_lbl := Label.new()
	coder_lbl.text = "Coder"
	role_row.add_child(coder_lbl)
	_coder_picker = OptionButton.new()
	_coder_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_coder_picker.item_selected.connect(_on_coder_picked)
	role_row.add_child(_coder_picker)

	var sep0 := HSeparator.new()
	root.add_child(sep0)

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

	var add_grok_btn := Button.new()
	add_grok_btn.text = "Add Grok"
	add_grok_btn.tooltip_text = "Upsert cloud Grok planner (api.x.ai). Key stays in user://."
	add_grok_btn.pressed.connect(_on_add_grok)
	model_buttons.add_child(add_grok_btn)

	var add_build_btn := Button.new()
	add_build_btn.text = "Add Grok Build"
	add_build_btn.tooltip_text = "Add a local Grok Build planner row (set base_url yourself)."
	add_build_btn.pressed.connect(_on_add_grok_build)
	model_buttons.add_child(add_build_btn)

	var add_local_btn := Button.new()
	add_local_btn.text = "Add Local Coder"
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

	var sep_dt := HSeparator.new()
	root.add_child(sep_dt)

	# --- Draw Things (image generate). Paths/model name only in user:// — never hardcoded. ---
	var dt_label := Label.new()
	dt_label.text = "Draw Things CLI"
	root.add_child(dt_label)

	var cli_row := HBoxContainer.new()
	root.add_child(cli_row)
	_drawthings_cli_edit = LineEdit.new()
	_drawthings_cli_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_drawthings_cli_edit.placeholder_text = "Absolute path to draw-things-cli"
	_drawthings_cli_edit.text_submitted.connect(func(_t: String) -> void: _save_drawthings())
	_drawthings_cli_edit.focus_exited.connect(_save_drawthings)
	cli_row.add_child(_drawthings_cli_edit)
	var browse_cli := Button.new()
	browse_cli.text = "Browse…"
	browse_cli.pressed.connect(_on_browse_drawthings_cli)
	cli_row.add_child(browse_cli)

	var models_lbl := Label.new()
	models_lbl.text = "Draw Things models directory"
	root.add_child(models_lbl)
	var models_row := HBoxContainer.new()
	root.add_child(models_row)
	_drawthings_models_edit = LineEdit.new()
	_drawthings_models_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_drawthings_models_edit.placeholder_text = "Directory the CLI reads models from"
	_drawthings_models_edit.text_submitted.connect(func(_t: String) -> void: _save_drawthings())
	_drawthings_models_edit.focus_exited.connect(_save_drawthings)
	models_row.add_child(_drawthings_models_edit)
	var browse_models := Button.new()
	browse_models.text = "Browse…"
	browse_models.pressed.connect(_on_browse_drawthings_models)
	models_row.add_child(browse_models)

	var model_lbl := Label.new()
	model_lbl.text = "Draw Things model filename"
	root.add_child(model_lbl)
	_drawthings_model_edit = LineEdit.new()
	_drawthings_model_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_drawthings_model_edit.placeholder_text = "Checkpoint filename (empty until you set it)"
	_drawthings_model_edit.text_submitted.connect(func(_t: String) -> void: _save_drawthings())
	_drawthings_model_edit.focus_exited.connect(_save_drawthings)
	root.add_child(_drawthings_model_edit)

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


func _ensure_drawthings_edits() -> void:
	if (
		_drawthings_cli_edit == null
		or _drawthings_models_edit == null
		or _drawthings_model_edit == null
		or _blender_edit == null
		or _model_list == null
		or _planner_picker == null
		or _coder_picker == null
	):
		_build_ui()


func _set_status(message: String) -> void:
	if _status_label == null:
		return
	if message.is_empty():
		_status_label.visible = false
		_status_label.text = ""
		return
	_status_label.visible = true
	_status_label.text = message


func _reload_from_disk() -> void:
	_ensure_drawthings_edits()
	var nul_err: String = AgenticStudioConfig.config_nul_error()
	if not nul_err.is_empty():
		# Do not overwrite cfg; keep the previous model list on screen.
		_set_status(nul_err)
		_fill_tool_fields_safe()
		_refresh_model_list()
		_refresh_role_pickers()
		_refresh_extra_list()
		return

	var loaded_models: Array[Dictionary] = AgenticStudioConfig.list_models()
	# Models come from AgenticStudioConfig.list_models() — never cleared by Draw Things saves.
	_models = loaded_models
	_extras = AgenticStudioConfig.list_extra_tools()
	_set_status("")
	_fill_tool_fields_safe()
	_refresh_model_list()
	_refresh_role_pickers()
	_refresh_extra_list()


func _fill_tool_fields_safe() -> void:
	if _blender_edit != null:
		_blender_edit.text = AgenticStudioConfig.get_blender_path()
	if _drawthings_cli_edit != null:
		_drawthings_cli_edit.text = AgenticStudioConfig.get_drawthings_cli()
	if _drawthings_models_edit != null:
		_drawthings_models_edit.text = AgenticStudioConfig.get_drawthings_models_dir()
	if _drawthings_model_edit != null:
		_drawthings_model_edit.text = AgenticStudioConfig.get_drawthings_model()


func _refresh_model_list() -> void:
	if _model_list == null:
		return
	_model_list.clear()
	for model: Dictionary in _models:
		var kind: String = str(model.get("kind", "local"))
		var role: String = str(model.get("role", "coder"))
		var label: String = "%s  (%s · %s · %s)" % [
			str(model.get("display_name", "")),
			role,
			kind,
			str(model.get("model_name", "")),
		]
		_model_list.add_item(label)


func _refresh_role_pickers() -> void:
	if _planner_picker == null or _coder_picker == null:
		return
	_suppress_role_signal = true
	_fill_role_picker(_planner_picker, AgenticStudioConfig.ROLE_PLANNER, AgenticStudioConfig.get_selected_planner_id())
	_fill_role_picker(_coder_picker, AgenticStudioConfig.ROLE_CODER, AgenticStudioConfig.get_selected_coder_id())
	_suppress_role_signal = false


func _fill_role_picker(picker: OptionButton, role: String, selected_id: String) -> void:
	if picker == null:
		return
	picker.clear()
	picker.add_item("None", 0)
	picker.set_item_metadata(0, "")
	var select_i: int = 0
	var i: int = 1
	for model: Dictionary in _models:
		if AgenticStudioConfig.normalize_role(str(model.get("role", ""))) != role:
			continue
		var id: String = str(model.get("id", ""))
		var display: String = str(model.get("display_name", id))
		# Draw Things is a tool, never a planner/coder model row.
		if _looks_like_drawthings_tool(id, display):
			continue
		picker.add_item(display, i)
		picker.set_item_metadata(i, id)
		if id == selected_id:
			select_i = i
		i += 1
	picker.select(select_i)


func _looks_like_drawthings_tool(id: String, display: String) -> bool:
	var blob: String = ("%s %s" % [id, display]).to_lower()
	return (
		blob.find("drawthings") >= 0
		or blob.find("draw-things") >= 0
		or blob.find("draw things") >= 0
	)


func _refresh_extra_list() -> void:
	if _extra_list == null:
		return
	_extra_list.clear()
	for tool: Dictionary in _extras:
		var path: String = str(tool.get("path", ""))
		var path_note: String = path if not path.is_empty() else "(no path)"
		_extra_list.add_item("%s — %s" % [str(tool.get("name", "")), path_note])


func _save_blender() -> void:
	if _blender_edit == null:
		return
	if not AgenticStudioConfig.config_nul_error().is_empty():
		_set_status(AgenticStudioConfig.config_nul_error())
		return
	AgenticStudioConfig.set_blender_path(_blender_edit.text.strip_edges())
	settings_changed.emit()


static func resolve_binary_path(raw: String) -> String:
	return AgenticStudioConfig.resolve_binary_path(raw)


func _save_drawthings() -> void:
	## Saves Draw Things fields only. Does not clear models or planner/coder selection.
	_ensure_drawthings_edits()
	var cli_raw: String = ""
	var models_dir: String = ""
	var model_fn: String = ""
	if _drawthings_cli_edit != null:
		cli_raw = _drawthings_cli_edit.text.strip_edges()
	if _drawthings_models_edit != null:
		models_dir = _drawthings_models_edit.text.strip_edges()
	if _drawthings_model_edit != null:
		model_fn = _drawthings_model_edit.text.strip_edges()
	var keep_models: Array[Dictionary] = _models.duplicate(true)
	var saved: Dictionary = AgenticStudioConfig.save_drawthings_fields(cli_raw, models_dir, model_fn)
	if not bool(saved.get("ok", false)):
		_set_status(str(saved.get("error", "save failed")))
		_models = keep_models
		_refresh_model_list()
		_refresh_role_pickers()
		return
	var cli_abs: String = str(saved.get("cli", cli_raw))
	if _drawthings_cli_edit != null and cli_abs != cli_raw:
		_drawthings_cli_edit.text = cli_abs
	_models = keep_models
	_refresh_model_list()
	_refresh_role_pickers()
	_set_status(AgenticStudioConfig.drawthings_status_text())
	settings_changed.emit()


func _on_browse_blender() -> void:
	_browse_target = "blender"
	_browse_extra_index = -1
	_ensure_file_dialogs()
	_file_dialog.title = "Select Blender"
	_file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	_popup_browse_dialog(_file_dialog)


func _on_browse_drawthings_cli() -> void:
	_browse_target = "drawthings_cli"
	_browse_extra_index = -1
	_ensure_file_dialogs()
	_file_dialog.title = "Select draw-things-cli"
	_file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	_popup_browse_dialog(_file_dialog)


func _on_browse_drawthings_models() -> void:
	_browse_target = "drawthings_models"
	_browse_extra_index = -1
	_ensure_file_dialogs()
	_popup_browse_dialog(_dir_dialog)


func _on_dir_selected(path: String) -> void:
	_on_browse_finished()
	if _browse_target == "drawthings_models":
		if _drawthings_models_edit != null:
			_drawthings_models_edit.text = path
		_save_drawthings()


func _on_file_selected(path: String) -> void:
	_on_browse_finished()
	if _browse_target == "blender":
		if _blender_edit != null:
			_blender_edit.text = path
		_save_blender()
	elif _browse_target == "drawthings_cli":
		if _drawthings_cli_edit != null:
			_drawthings_cli_edit.text = path
		_save_drawthings()
	elif _browse_target == "extra" and _browse_extra_index >= 0 and _browse_extra_index < _extras.size():
		var tool: Dictionary = _extras[_browse_extra_index].duplicate(true)
		tool["path"] = path
		AgenticStudioConfig.upsert_extra_tool(tool)
		_reload_from_disk()
		settings_changed.emit()


func _on_planner_picked(index: int) -> void:
	if _suppress_role_signal:
		return
	var id: String = str(_planner_picker.get_item_metadata(index))
	AgenticStudioConfig.set_selected_planner_id(id)
	settings_changed.emit()


func _on_coder_picked(index: int) -> void:
	if _suppress_role_signal:
		return
	var id: String = str(_coder_picker.get_item_metadata(index))
	AgenticStudioConfig.set_selected_coder_id(id)
	settings_changed.emit()


func _on_add_grok() -> void:
	var existing: Dictionary = AgenticStudioConfig.get_model(AgenticStudioConfig.STABLE_GROK_ID)
	_edit_model({
		"id": AgenticStudioConfig.STABLE_GROK_ID,
		"display_name": "Grok",
		"kind": AgenticStudioConfig.KIND_EXTERNAL,
		"role": AgenticStudioConfig.ROLE_PLANNER,
		"provider": AgenticStudioConfig.PROVIDER_GROK,
		"base_url": AgenticStudioConfig.GROK_BASE_URL,
		"model_name": AgenticStudioConfig.GROK_MODEL_NAME,
		"context_length": int(existing.get("context_length", AgenticStudioConfig.DEFAULT_PLANNER_CONTEXT)),
		"api_key": str(existing.get("api_key", "")),
	}, existing.is_empty())


func _on_add_grok_build() -> void:
	_edit_model({
		"id": "",
		"display_name": "Mini",
		"kind": AgenticStudioConfig.KIND_LOCAL,
		"role": AgenticStudioConfig.ROLE_PLANNER,
		"provider": AgenticStudioConfig.PROVIDER_GROK_BUILD,
		"base_url": "",
		"model_name": "grok-build",
		"context_length": AgenticStudioConfig.DEFAULT_PLANNER_CONTEXT,
	}, true)


func _on_add_local() -> void:
	_edit_model({
		"id": "",
		"display_name": "Local Coder",
		"kind": AgenticStudioConfig.KIND_LOCAL,
		"role": AgenticStudioConfig.ROLE_CODER,
		"provider": AgenticStudioConfig.PROVIDER_OLLAMA,
		"base_url": AgenticStudioConfig.DEFAULT_OLLAMA_BASE,
		"model_name": "qwen2.5-coder:7b",
		"context_length": AgenticStudioConfig.DEFAULT_CODER_CONTEXT,
	}, true)


func _on_add_external() -> void:
	_edit_model({
		"id": "",
		"display_name": "",
		"kind": AgenticStudioConfig.KIND_EXTERNAL,
		"role": AgenticStudioConfig.ROLE_CODER,
		"base_url": "https://api.openai.com/v1",
		"model_name": "",
		"context_length": AgenticStudioConfig.DEFAULT_CODER_CONTEXT,
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
	dlg.min_size = Vector2i(460, 380)
	dlg.dialog_hide_on_ok = false

	var form := VBoxContainer.new()
	dlg.add_child(form)

	var name_edit := _labeled_line(form, "Display name", str(model.get("display_name", "")))
	var role_row := HBoxContainer.new()
	form.add_child(role_row)
	var role_lbl := Label.new()
	role_lbl.text = "Role"
	role_lbl.custom_minimum_size = Vector2(160, 0)
	role_row.add_child(role_lbl)
	var role_pick := OptionButton.new()
	role_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	role_pick.add_item("planner", 0)
	role_pick.add_item("coder", 1)
	role_pick.select(0 if AgenticStudioConfig.normalize_role(str(model.get("role", ""))) == AgenticStudioConfig.ROLE_PLANNER else 1)
	# Cloud Grok / Build defaults stay planner; still editable for custom rows.
	role_row.add_child(role_pick)

	var url_edit := _labeled_line(form, "Base URL", str(model.get("base_url", "")))
	if str(model.get("provider", "")) == AgenticStudioConfig.PROVIDER_GROK_BUILD:
		url_edit.placeholder_text = "Running Grok Build base URL (required before Plan)"
	var model_edit := _labeled_line(form, "Model name", str(model.get("model_name", "")))
	var default_ctx: int = AgenticStudioConfig.default_context_length(
		AgenticStudioConfig.normalize_role(str(model.get("role", "coder")))
	)
	var ctx_val: int = int(model.get("context_length", 0))
	if ctx_val <= 0:
		ctx_val = default_ctx
	var ctx_edit := _labeled_line(form, "Context length", str(ctx_val))
	var images_check := CheckBox.new()
	images_check.text = "Accepts image input (attach screenshots)"
	images_check.button_pressed = bool(model.get("accepts_images", false))
	form.add_child(images_check)
	var key_edit: LineEdit = null
	if str(model.get("kind", "")) == AgenticStudioConfig.KIND_EXTERNAL:
		key_edit = _labeled_line(form, "API key (user:// only, masked)", str(model.get("api_key", "")))
		key_edit.secret = true

	dlg.confirmed.connect(func() -> void:
		var display: String = name_edit.text.strip_edges()
		var model_name: String = model_edit.text.strip_edges()
		if display.is_empty() or model_name.is_empty():
			dlg.dialog_text = "Display name and model name are required."
			return
		model["display_name"] = display
		model["role"] = "planner" if role_pick.selected == 0 else "coder"
		model["base_url"] = url_edit.text.strip_edges()
		model["model_name"] = model_name
		model["context_length"] = int(ctx_edit.text.strip_edges()) if ctx_edit.text.strip_edges().is_valid_int() else 0
		model["accepts_images"] = images_check.button_pressed
		if key_edit != null:
			model["api_key"] = key_edit.text
		# Never print the key.
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
		_ensure_file_dialogs()
		var on_pick := func(p: String) -> void:
			path_edit.text = p
			_on_browse_finished()
		_file_dialog.file_selected.connect(on_pick, CONNECT_ONE_SHOT)
		_popup_browse_dialog(_file_dialog)
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
