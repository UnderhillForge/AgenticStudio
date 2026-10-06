class_name AgenticStudioConfig
extends RefCounted
## Settings for AgenticStudio. Lives in user://agentic_studio.cfg — never in git.

const CONFIG_PATH: String = "user://agentic_studio.cfg"
const JOBS_DIR: String = "user://agentic_studio/jobs/"
const LOGS_DIR: String = "user://agentic_studio/logs/"

const SECTION_GENERAL: String = "general"
const SECTION_TOOLS: String = "tools"
const SECTION_MODELS: String = "models"
const SECTION_EXTRA_TOOLS: String = "extra_tools"
const SECTION_SESSIONS: String = "sessions"

const KEY_SELECTED_MODEL: String = "selected_model_id"
const KEY_BLENDER_PATH: String = "blender_path"
const KEY_MODEL_IDS: String = "ids"
const KEY_EXTRA_IDS: String = "ids"
const KEY_OPEN_SESSION_IDS: String = "open_ids"


static func ensure_dirs() -> void:
	var abs_jobs: String = ProjectSettings.globalize_path(JOBS_DIR)
	if not DirAccess.dir_exists_absolute(abs_jobs):
		DirAccess.make_dir_recursive_absolute(abs_jobs)
	var abs_logs: String = ProjectSettings.globalize_path(LOGS_DIR)
	if not DirAccess.dir_exists_absolute(abs_logs):
		DirAccess.make_dir_recursive_absolute(abs_logs)


static func load_config() -> ConfigFile:
	ensure_dirs()
	var cfg := ConfigFile.new()
	var err: Error = cfg.load(CONFIG_PATH)
	if err != OK and err != ERR_FILE_NOT_FOUND:
		push_warning("AgenticStudio: could not load config (%s): error %d" % [CONFIG_PATH, err])
	return cfg


static func save_config(cfg: ConfigFile) -> Error:
	ensure_dirs()
	var err: Error = cfg.save(CONFIG_PATH)
	if err != OK:
		push_warning("AgenticStudio: could not save config (%s): error %d" % [CONFIG_PATH, err])
	return err


static func make_model_id() -> String:
	return "model_%d_%d" % [Time.get_unix_time_from_system(), randi() % 100000]


static func make_extra_tool_id() -> String:
	return "tool_%d_%d" % [Time.get_unix_time_from_system(), randi() % 100000]


static func get_selected_model_id(cfg: ConfigFile = null) -> String:
	var c: ConfigFile = cfg if cfg != null else load_config()
	return str(c.get_value(SECTION_GENERAL, KEY_SELECTED_MODEL, ""))


static func set_selected_model_id(model_id: String, cfg: ConfigFile = null) -> void:
	var c: ConfigFile = cfg if cfg != null else load_config()
	c.set_value(SECTION_GENERAL, KEY_SELECTED_MODEL, model_id)
	save_config(c)


static func get_blender_path(cfg: ConfigFile = null) -> String:
	var c: ConfigFile = cfg if cfg != null else load_config()
	return str(c.get_value(SECTION_TOOLS, KEY_BLENDER_PATH, ""))


static func set_blender_path(path: String, cfg: ConfigFile = null) -> void:
	var c: ConfigFile = cfg if cfg != null else load_config()
	c.set_value(SECTION_TOOLS, KEY_BLENDER_PATH, path)
	save_config(c)


static func list_models(cfg: ConfigFile = null) -> Array[Dictionary]:
	var c: ConfigFile = cfg if cfg != null else load_config()
	var ids: PackedStringArray = PackedStringArray(c.get_value(SECTION_MODELS, KEY_MODEL_IDS, PackedStringArray()))
	var out: Array[Dictionary] = []
	for id: String in ids:
		var section: String = _model_section(id)
		if not c.has_section(section):
			continue
		out.append(_read_model(c, id))
	return out


static func get_model(model_id: String, cfg: ConfigFile = null) -> Dictionary:
	var c: ConfigFile = cfg if cfg != null else load_config()
	if model_id.is_empty() or not c.has_section(_model_section(model_id)):
		return {}
	return _read_model(c, model_id)


static func upsert_model(model: Dictionary, cfg: ConfigFile = null) -> String:
	var c: ConfigFile = cfg if cfg != null else load_config()
	var id: String = str(model.get("id", ""))
	if id.is_empty():
		id = make_model_id()
		model["id"] = id

	var ids: PackedStringArray = PackedStringArray(c.get_value(SECTION_MODELS, KEY_MODEL_IDS, PackedStringArray()))
	if not ids.has(id):
		ids.append(id)
		c.set_value(SECTION_MODELS, KEY_MODEL_IDS, ids)

	var section: String = _model_section(id)
	c.set_value(section, "display_name", str(model.get("display_name", id)))
	c.set_value(section, "kind", str(model.get("kind", "local")))
	c.set_value(section, "base_url", str(model.get("base_url", "")))
	c.set_value(section, "model_name", str(model.get("model_name", "")))
	c.set_value(section, "context_length", int(model.get("context_length", 0)))
	c.set_value(section, "accepts_images", bool(model.get("accepts_images", false)))
	# API key only for external models; stored in user:// config, never in the repo.
	if str(model.get("kind", "")) == "external":
		c.set_value(section, "api_key", str(model.get("api_key", "")))
	elif c.has_section_key(section, "api_key"):
		c.erase_section_key(section, "api_key")

	save_config(c)
	return id


static func remove_model(model_id: String, cfg: ConfigFile = null) -> void:
	var c: ConfigFile = cfg if cfg != null else load_config()
	var ids: PackedStringArray = PackedStringArray(c.get_value(SECTION_MODELS, KEY_MODEL_IDS, PackedStringArray()))
	var next: PackedStringArray = PackedStringArray()
	for id: String in ids:
		if id != model_id:
			next.append(id)
	c.set_value(SECTION_MODELS, KEY_MODEL_IDS, next)
	var section: String = _model_section(model_id)
	if c.has_section(section):
		c.erase_section(section)
	if get_selected_model_id(c) == model_id:
		c.set_value(SECTION_GENERAL, KEY_SELECTED_MODEL, "")
	save_config(c)


static func list_extra_tools(cfg: ConfigFile = null) -> Array[Dictionary]:
	var c: ConfigFile = cfg if cfg != null else load_config()
	var ids: PackedStringArray = PackedStringArray(c.get_value(SECTION_EXTRA_TOOLS, KEY_EXTRA_IDS, PackedStringArray()))
	var out: Array[Dictionary] = []
	for id: String in ids:
		var section: String = _extra_section(id)
		if not c.has_section(section):
			continue
		out.append({
			"id": id,
			"name": str(c.get_value(section, "name", "")),
			"path": str(c.get_value(section, "path", "")),
		})
	return out


static func upsert_extra_tool(tool: Dictionary, cfg: ConfigFile = null) -> String:
	var c: ConfigFile = cfg if cfg != null else load_config()
	var id: String = str(tool.get("id", ""))
	if id.is_empty():
		id = make_extra_tool_id()
		tool["id"] = id

	var ids: PackedStringArray = PackedStringArray(c.get_value(SECTION_EXTRA_TOOLS, KEY_EXTRA_IDS, PackedStringArray()))
	if not ids.has(id):
		ids.append(id)
		c.set_value(SECTION_EXTRA_TOOLS, KEY_EXTRA_IDS, ids)

	var section: String = _extra_section(id)
	c.set_value(section, "name", str(tool.get("name", "")))
	# Missing paths are saved on purpose; they fail only the job that needs them.
	c.set_value(section, "path", str(tool.get("path", "")))
	save_config(c)
	return id


static func remove_extra_tool(tool_id: String, cfg: ConfigFile = null) -> void:
	var c: ConfigFile = cfg if cfg != null else load_config()
	var ids: PackedStringArray = PackedStringArray(c.get_value(SECTION_EXTRA_TOOLS, KEY_EXTRA_IDS, PackedStringArray()))
	var next: PackedStringArray = PackedStringArray()
	for id: String in ids:
		if id != tool_id:
			next.append(id)
	c.set_value(SECTION_EXTRA_TOOLS, KEY_EXTRA_IDS, next)
	var section: String = _extra_section(tool_id)
	if c.has_section(section):
		c.erase_section(section)
	save_config(c)


static func get_open_session_ids(cfg: ConfigFile = null) -> PackedStringArray:
	var c: ConfigFile = cfg if cfg != null else load_config()
	return PackedStringArray(
		c.get_value(SECTION_SESSIONS, KEY_OPEN_SESSION_IDS, PackedStringArray())
	)


static func set_open_session_ids(ids: PackedStringArray, cfg: ConfigFile = null) -> void:
	var c: ConfigFile = cfg if cfg != null else load_config()
	c.set_value(SECTION_SESSIONS, KEY_OPEN_SESSION_IDS, ids)
	save_config(c)


static func _model_section(model_id: String) -> String:
	return "model.%s" % model_id


static func _extra_section(tool_id: String) -> String:
	return "extra.%s" % tool_id


static func _read_model(c: ConfigFile, model_id: String) -> Dictionary:
	var section: String = _model_section(model_id)
	var kind: String = str(c.get_value(section, "kind", "local"))
	var model: Dictionary = {
		"id": model_id,
		"display_name": str(c.get_value(section, "display_name", model_id)),
		"kind": kind,
		"base_url": str(c.get_value(section, "base_url", "")),
		"model_name": str(c.get_value(section, "model_name", "")),
		"context_length": int(c.get_value(section, "context_length", 0)),
		"accepts_images": bool(c.get_value(section, "accepts_images", false)),
	}
	if kind == "external":
		model["api_key"] = str(c.get_value(section, "api_key", ""))
	return model
